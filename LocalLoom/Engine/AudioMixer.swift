import Foundation
import AVFoundation
import CoreMedia

/// Converts system-audio and mic PCM to a common format (48 kHz, stereo, float32),
/// applies independent per-source gain, sums, and clamps.
///
/// Unit-testable with synthetic `AVAudioPCMBuffer`s — no real devices required.
final class AudioMixer: @unchecked Sendable {

    // MARK: - Public format

    static let sampleRate: Double = 48_000
    static let channelCount: AVAudioChannelCount = 2

    /// Canonical mix format: 48 kHz stereo non-interleaved float32.
    static var mixFormat: AVAudioFormat {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channelCount,
            interleaved: false
        ) else {
            preconditionFailure("Failed to create AudioMixer mix format")
        }
        return format
    }

    // MARK: - Gain (dB)

    /// System-audio gain. Default −6 dB so a hot desktop mix doesn't bury the mic (Trap 7).
    var systemGainDb: Float = -6 {
        didSet { systemLinearGain = Self.linearGain(fromDb: systemGainDb) }
    }

    /// Mic gain. Default 0 dB.
    var micGainDb: Float = 0 {
        didSet { micLinearGain = Self.linearGain(fromDb: micGainDb) }
    }

    private var systemLinearGain: Float
    private var micLinearGain: Float

    // MARK: - Converters (lazily rebuilt when input formats change)

    private var systemConverter: AVAudioConverter?
    private var systemInputFormat: AVAudioFormat?

    private var micConverter: AVAudioConverter?
    private var micInputFormat: AVAudioFormat?

    // MARK: - Init

    init(systemGainDb: Float = -6, micGainDb: Float = 0) {
        self.systemGainDb = systemGainDb
        self.micGainDb = micGainDb
        self.systemLinearGain = Self.linearGain(fromDb: systemGainDb)
        self.micLinearGain = Self.linearGain(fromDb: micGainDb)
    }

    // MARK: - Public API

    /// Mix optional system + mic PCM buffers into one 48 kHz stereo float32 buffer.
    ///
    /// Either input may be `nil`. When both are nil, returns `nil`.
    /// When lengths differ, the longer buffer wins and the shorter is zero-padded for the mix.
    func mix(
        systemPCM: AVAudioPCMBuffer?,
        micPCM: AVAudioPCMBuffer?
    ) throws -> AVAudioPCMBuffer? {
        let convertedSystem = try systemPCM.map { try convertSystem($0) }
        let convertedMic = try micPCM.map { try convertMic($0) }

        guard convertedSystem != nil || convertedMic != nil else { return nil }

        let frameCount = max(
            convertedSystem?.frameLength ?? 0,
            convertedMic?.frameLength ?? 0
        )
        guard frameCount > 0 else { return nil }

        guard let output = AVAudioPCMBuffer(pcmFormat: Self.mixFormat, frameCapacity: frameCount) else {
            throw AudioMixerError.bufferAllocationFailed
        }
        output.frameLength = frameCount

        guard let outChannels = output.floatChannelData else {
            throw AudioMixerError.missingChannelData
        }

        let sysGain = systemLinearGain
        let micGain = micLinearGain
        let channels = Int(Self.channelCount)

        for ch in 0..<channels {
            let out = outChannels[ch]
            let sysPtr = convertedSystem?.floatChannelData?[ch]
            let micPtr = convertedMic?.floatChannelData?[ch]
            let sysLen = Int(convertedSystem?.frameLength ?? 0)
            let micLen = Int(convertedMic?.frameLength ?? 0)

            for i in 0..<Int(frameCount) {
                var sample: Float = 0
                if let sysPtr, i < sysLen {
                    sample += sysPtr[i] * sysGain
                }
                if let micPtr, i < micLen {
                    sample += micPtr[i] * micGain
                }
                // Clamp to [-1, 1] to avoid hard clipping in the AAC encoder.
                out[i] = max(-1, min(1, sample))
            }
        }

        return output
    }

    /// Convenience: convert `CMSampleBuffer` PCM into the mix format for one source,
    /// apply that source's gain, and return a mono-source buffer (no summing).
    /// Useful when the engine wants to feed sources independently then call `mix`.
    func convertSystemSample(_ sampleBuffer: CMSampleBuffer) throws -> AVAudioPCMBuffer? {
        guard let pcm = try Self.pcmBuffer(from: sampleBuffer) else { return nil }
        return try convertSystem(pcm)
    }

    func convertMicSample(_ sampleBuffer: CMSampleBuffer) throws -> AVAudioPCMBuffer? {
        guard let pcm = try Self.pcmBuffer(from: sampleBuffer) else { return nil }
        return try convertMic(pcm)
    }

    /// Mix two `CMSampleBuffer`s (system + mic) in one call.
    func mix(
        systemSample: CMSampleBuffer?,
        micSample: CMSampleBuffer?
    ) throws -> AVAudioPCMBuffer? {
        let systemPCM = try systemSample.flatMap { try Self.pcmBuffer(from: $0) }
        let micPCM = try micSample.flatMap { try Self.pcmBuffer(from: $0) }
        return try mix(systemPCM: systemPCM, micPCM: micPCM)
    }

    /// Apply linear gain in-place to a non-interleaved float32 buffer (test helper / post path).
    static func applyGain(_ buffer: AVAudioPCMBuffer, gainDb: Float) {
        let linear = linearGain(fromDb: gainDb)
        guard let channels = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        for ch in 0..<channelCount {
            let ptr = channels[ch]
            for i in 0..<frameCount {
                ptr[i] = max(-1, min(1, ptr[i] * linear))
            }
        }
    }

    static func linearGain(fromDb db: Float) -> Float {
        pow(10, db / 20)
    }

    // MARK: - Conversion

    private func convertSystem(_ input: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        try convert(input, converter: &systemConverter, cachedFormat: &systemInputFormat)
    }

    private func convertMic(_ input: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        try convert(input, converter: &micConverter, cachedFormat: &micInputFormat)
    }

    private func convert(
        _ input: AVAudioPCMBuffer,
        converter: inout AVAudioConverter?,
        cachedFormat: inout AVAudioFormat?
    ) throws -> AVAudioPCMBuffer {
        let inFormat = input.format
        if inFormat.sampleRate == Self.sampleRate,
           inFormat.channelCount == Self.channelCount,
           inFormat.commonFormat == .pcmFormatFloat32,
           !inFormat.isInterleaved {
            return input
        }

        if cachedFormat != inFormat || converter == nil {
            guard let fresh = AVAudioConverter(from: inFormat, to: Self.mixFormat) else {
                throw AudioMixerError.converterCreationFailed
            }
            converter = fresh
            cachedFormat = inFormat
        }

        guard let converter else { throw AudioMixerError.converterCreationFailed }

        let ratio = Self.mixFormat.sampleRate / inFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: Self.mixFormat, frameCapacity: max(outCapacity, 1)) else {
            throw AudioMixerError.bufferAllocationFailed
        }

        var error: NSError?
        var consumedInput = false
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if consumedInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumedInput = true
            outStatus.pointee = .haveData
            return input
        }

        if let error { throw AudioMixerError.conversionFailed(error) }
        if status == .error { throw AudioMixerError.conversionFailed(nil) }
        return output
    }

    // MARK: - CMSampleBuffer → PCM

    static func pcmBuffer(from sampleBuffer: CMSampleBuffer) throws -> AVAudioPCMBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return nil
        }

        var asbd = asbdPtr.pointee
        guard let absFormat = AVAudioFormat(streamDescription: &asbd) else {
            throw AudioMixerError.unsupportedFormat
        }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: absFormat, frameCapacity: frameCount) else {
            return nil
        }
        buffer.frameLength = frameCount

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return nil
        }

        var lengthAtOffset = 0
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: &lengthAtOffset,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )
        guard status == kCMBlockBufferNoErr, let dataPointer else {
            throw AudioMixerError.blockBufferReadFailed
        }

        let audioBufferList = buffer.mutableAudioBufferList
        let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)

        if absFormat.isInterleaved {
            guard ablPointer.count >= 1, let dest = ablPointer[0].mData else {
                throw AudioMixerError.missingChannelData
            }
            memcpy(dest, dataPointer, min(Int(ablPointer[0].mDataByteSize), totalLength))
        } else {
            // Non-interleaved: copy sequentially into each channel buffer.
            var offset = 0
            for i in 0..<ablPointer.count {
                guard let dest = ablPointer[i].mData else { continue }
                let size = Int(ablPointer[i].mDataByteSize)
                let available = max(0, totalLength - offset)
                memcpy(dest, dataPointer.advanced(by: offset), min(size, available))
                offset += size
            }
        }

        return buffer
    }
}

// MARK: - Errors

enum AudioMixerError: Error, LocalizedError {
    case bufferAllocationFailed
    case missingChannelData
    case converterCreationFailed
    case conversionFailed(Error?)
    case unsupportedFormat
    case blockBufferReadFailed

    var errorDescription: String? {
        switch self {
        case .bufferAllocationFailed: return "AudioMixer could not allocate a PCM buffer"
        case .missingChannelData: return "AudioMixer buffer has no float channel data"
        case .converterCreationFailed: return "AudioMixer could not create AVAudioConverter"
        case .conversionFailed(let err):
            return "AudioMixer conversion failed: \(err?.localizedDescription ?? "unknown")"
        case .unsupportedFormat: return "AudioMixer received an unsupported audio format"
        case .blockBufferReadFailed: return "AudioMixer could not read CMBlockBuffer data"
        }
    }
}
