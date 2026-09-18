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

    // MARK: - Timeline mixing

    // System and mic arrive as separate callbacks with overlapping timestamps.
    // Appending each straight to the writer serialises them (2s of recording →
    // 4s of choppy audio), so each source is laid onto one shared 48 kHz
    // timeline by its PTS and only spans both sources cover are emitted.

    /// Jitter tolerated before a source is padded with silence or trimmed (10 ms).
    static let jitterFrames = 480
    /// A source this far behind the other is treated as silent (0.5 s).
    static let maxLagFrames = 24_000

    private var expectsSystem = false
    private var expectsMic = false
    private var anchor: CMTime?
    /// Timeline frames already emitted; both FIFOs start at this frame.
    private var emitted: Int64 = 0
    private var systemFIFO: [[Float]] = [[], []]
    private var micFIFO: [[Float]] = [[], []]

    /// Call once per recording, before the first `push`.
    func reset(expectsSystem: Bool, expectsMic: Bool) {
        self.expectsSystem = expectsSystem
        self.expectsMic = expectsMic
        anchor = nil
        emitted = 0
        systemFIFO = [[], []]
        micFIFO = [[], []]
    }

    /// Queue one source's audio at `pts`; returns whatever is now mixable, with its PTS.
    func push(_ sampleBuffer: CMSampleBuffer, pts: CMTime, isMic: Bool) throws -> (AVAudioPCMBuffer, CMTime)? {
        guard let pcm = try Self.pcmBuffer(from: sampleBuffer) else { return nil }
        return try push(pcm: pcm, pts: pts, isMic: isMic)
    }

    func push(pcm: AVAudioPCMBuffer, pts: CMTime, isMic: Bool) throws -> (AVAudioPCMBuffer, CMTime)? {
        let converted = isMic ? try convertMic(pcm) : try convertSystem(pcm)
        let anchor = self.anchor ?? pts
        self.anchor = anchor
        let start = Int64((CMTimeGetSeconds(CMTimeSubtract(pts, anchor)) * Self.sampleRate).rounded())
        if isMic {
            Self.place(converted, at: start, into: &micFIFO, emitted: emitted)
        } else {
            Self.place(converted, at: start, into: &systemFIFO, emitted: emitted)
        }
        return try drain(flush: false)
    }

    /// Emits everything still queued (the lagging source padded with silence). Call at stop.
    func flush() throws -> (AVAudioPCMBuffer, CMTime)? {
        try drain(flush: true)
    }

    /// Appends `pcm` so it lands at timeline frame `start`: pads a gap with silence,
    /// trims overlap, so each source stays locked to its own timestamps.
    private static func place(_ pcm: AVAudioPCMBuffer, at start: Int64, into fifo: inout [[Float]], emitted: Int64) {
        guard let data = pcm.floatChannelData else { return }
        let end = emitted + Int64(fifo[0].count)
        let frames = Int(pcm.frameLength)
        var skip = 0
        if start - end > jitterFrames {
            let gap = Int(start - end)
            for ch in 0..<fifo.count { fifo[ch].append(contentsOf: repeatElement(0, count: gap)) }
        } else if end - start > jitterFrames {
            skip = min(frames, Int(end - start))
        }
        for ch in 0..<fifo.count {
            fifo[ch].append(contentsOf: UnsafeBufferPointer(start: data[ch] + skip, count: frames - skip))
        }
    }

    private func drain(flush: Bool) throws -> (AVAudioPCMBuffer, CMTime)? {
        let sysCount = systemFIFO[0].count
        let micCount = micFIFO[0].count
        let count: Int
        if expectsSystem && expectsMic && !flush {
            let lead = max(sysCount, micCount)
            // A stalled source (e.g. no system audio playing) must not hold the mic hostage.
            count = lead - min(sysCount, micCount) > Self.maxLagFrames ? lead : min(sysCount, micCount)
        } else {
            count = max(sysCount, micCount)
        }
        guard count > 0, let anchor else { return nil }

        let sys = expectsSystem ? try Self.takeFrames(count, from: &systemFIFO) : nil
        let mic = expectsMic ? try Self.takeFrames(count, from: &micFIFO) : nil
        guard let mixed = try mix(systemPCM: sys, micPCM: mic) else { return nil }
        let pts = CMTimeAdd(anchor, CMTime(value: emitted, timescale: CMTimeScale(Self.sampleRate)))
        emitted += Int64(count)
        return (mixed, pts)
    }

    /// Removes `count` frames from `fifo` into a mix-format buffer, zero-padding a short FIFO.
    private static func takeFrames(_ count: Int, from fifo: inout [[Float]]) throws -> AVAudioPCMBuffer {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: mixFormat, frameCapacity: AVAudioFrameCount(count)) else {
            throw AudioMixerError.bufferAllocationFailed
        }
        buffer.frameLength = AVAudioFrameCount(count)
        guard let out = buffer.floatChannelData else { throw AudioMixerError.missingChannelData }
        for ch in 0..<fifo.count {
            let n = min(count, fifo[ch].count)
            fifo[ch].withUnsafeBufferPointer { out[ch].update(from: $0.baseAddress!, count: n) }
            (out[ch] + n).initialize(repeating: 0, count: count - n)
            fifo[ch].removeFirst(n)
        }
        return buffer
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
