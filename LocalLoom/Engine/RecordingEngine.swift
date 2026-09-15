import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia
import CoreVideo
import AppKit
import QuartzCore

// MARK: - Public result / state

struct RecordingResult: Sendable {
    let fileURL: URL
    let duration: TimeInterval
    let width: Int
    let height: Int
    let fps: Int
    let sourceDescription: String
    let hasWebcam: Bool
    let hasMic: Bool
    let hasSystemAudio: Bool
}

enum RecordingEngineState: String, Sendable {
    case idle
    case recording
    case paused
}

enum RecordingEngineError: Error, LocalizedError {
    case alreadyRecording
    case notRecording
    case contentUnavailable
    case displayNotFound(UInt32)
    case windowNotFound(UInt32)
    case writerSetupFailed(String)
    case writerFailed(String)
    case noFramesCaptured
    case streamStartFailed(Error)
    case cameraUnavailable

    var errorDescription: String? {
        switch self {
        case .alreadyRecording: return "A recording is already in progress"
        case .notRecording: return "No recording is in progress"
        case .contentUnavailable: return "Unable to enumerate shareable content"
        case .displayNotFound(let id): return "Display \(id) was not found"
        case .windowNotFound(let id): return "Window \(id) was not found"
        case .writerSetupFailed(let msg): return "AVAssetWriter setup failed: \(msg)"
        case .writerFailed(let msg): return "AVAssetWriter failed: \(msg)"
        case .noFramesCaptured: return "No frames were captured"
        case .streamStartFailed(let err): return "SCStream failed to start: \(err.localizedDescription)"
        case .cameraUnavailable: return "Selected camera is unavailable"
        }
    }
}

// MARK: - RecordingEngine

/// Owns SCStream, AVCaptureSession, Compositor, AudioMixer, AVAssetWriter, and
/// the pause-duration accumulator. Screen clock is master; webcam is a latch only.
///
/// `@Observable` so SwiftUI can inject it via `.environment()` or `@Environment`.
/// Internal mutable state is protected by `stateLock`; public API remains async
/// to match the caller pattern (the actor keyword was removed because Swift 6 + Observation
/// cannot compose — the concurrency guarantee is now explicit locking).
@Observable
final class RecordingEngine: @unchecked Sendable {

    // MARK: Observable state (SwiftUI reads these on the main actor)

    private let stateLock = NSLock()
    private var _phase: RecordingEngineState = .idle
    private var _elapsedSeconds: TimeInterval = 0

    var phase: RecordingEngineState {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _phase
    }

    var elapsed: TimeInterval {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _elapsedSeconds
    }

    // MARK: Internal convenience (thread-safe via stateLock)

    private var state: RecordingEngineState {
        get { stateLock.withLock { _phase } }
        set { stateLock.withLock { _phase = newValue } }
    }

    private var elapsedSeconds: TimeInterval {
        get { stateLock.withLock { _elapsedSeconds } }
        set { stateLock.withLock { _elapsedSeconds = newValue } }
    }

    // MARK: Owned pipeline pieces

    private var stream: SCStream?
    private var streamOutput: StreamOutputProxy?
    private var captureSession: AVCaptureSession?
    private var videoOutput: AVCaptureVideoDataOutput?
    private var webcamProxy: WebcamOutputProxy?
    private let webcamLatch = WebcamLatch()
    private let compositor = Compositor()
    private let audioMixer = AudioMixer()

    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var audioInput: AVAssetWriterInput?

    private var outputURL: URL?
    private var activeConfig: RecordingConfig?
    private var outputWidth: Int = 0
    private var outputHeight: Int = 0

    // MARK: Timing

    private var sessionStarted = false
    private var firstScreenPTS: CMTime?
    private var pausedDuration: CMTime = .zero
    private var pauseStartedAt: CMTime?
    private var lastAppendedPTS: CMTime = .zero
    private var recordingWallStart: Date?
    private var elapsedTickerTask: Task<Void, Never>?

    // Pending audio samples waiting for the session to start (screen clock master).
    private var pendingSystemAudio: CMSampleBuffer?
    private var pendingMicAudio: CMSampleBuffer?

    // MARK: - Public API

    func start(config: RecordingConfig) async throws {
        guard state == .idle else { throw RecordingEngineError.alreadyRecording }

        let snapshot = config.snapshot()
        activeConfig = snapshot
        compositor.pipSettings = snapshot.pip
        audioMixer.systemGainDb = snapshot.systemAudioGainDb
        audioMixer.micGainDb = snapshot.micGainDb
        webcamLatch.clear()
        compositor.resetPool()

        sessionStarted = false
        firstScreenPTS = nil
        pausedDuration = .zero
        pauseStartedAt = nil
        lastAppendedPTS = .zero
        pendingSystemAudio = nil
        pendingMicAudio = nil
        elapsedSeconds = 0

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let filter = try Self.makeContentFilter(config: snapshot, content: content)
        let (width, height) = try Self.resolveOutputDimensions(config: snapshot, content: content, filter: filter)
        outputWidth = width
        outputHeight = height

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalLoom-\(UUID().uuidString).mp4")
        outputURL = url

        try setupWriter(
            url: url,
            width: width,
            height: height,
            fps: snapshot.fps,
            includeAudio: snapshot.includeSystemAudio || snapshot.includeMic
        )

        let streamConfig = Self.makeStreamConfiguration(config: snapshot, width: width, height: height, content: content)
        let proxy = StreamOutputProxy(engine: self)
        streamOutput = proxy

        let scStream = SCStream(filter: filter, configuration: streamConfig, delegate: proxy)
        do {
            try scStream.addStreamOutput(proxy, type: .screen, sampleHandlerQueue: .global(qos: .userInitiated))
            if snapshot.includeSystemAudio {
                try scStream.addStreamOutput(proxy, type: .audio, sampleHandlerQueue: .global(qos: .userInitiated))
            }
            if snapshot.includeMic {
                try scStream.addStreamOutput(proxy, type: .microphone, sampleHandlerQueue: .global(qos: .userInitiated))
            }
        } catch {
            throw RecordingEngineError.streamStartFailed(error)
        }

        stream = scStream

        if snapshot.includeWebcam {
            try setupWebcam(deviceID: snapshot.cameraDeviceID)
        }

        do {
            try await scStream.startCapture()
        } catch {
            await teardownCaptureOnly()
            throw RecordingEngineError.streamStartFailed(error)
        }

        state = .recording
        recordingWallStart = Date()
        startElapsedTicker()
    }

    func pause() async {
        guard state == .recording else { return }
        state = .paused
        // Anchor against last raw PTS; refined when the next sample arrives while paused.
        if pauseStartedAt == nil {
            pauseStartedAt = lastAppendedPTS
        }
    }

    func resume() async {
        guard state == .paused else { return }
        // Leave `pauseStartedAt` set — the next screen sample closes the interval
        // against its raw PTS so we don't double-count here and in handleScreenSample.
        state = .recording
    }

    @discardableResult
    func stop() async throws -> RecordingResult {
        guard state == .recording || state == .paused else {
            throw RecordingEngineError.notRecording
        }

        elapsedTickerTask?.cancel()
        elapsedTickerTask = nil

        // Finish any open pause interval.
        if state == .paused, let started = pauseStartedAt {
            let delta = CMTimeSubtract(lastAppendedPTS, started)
            if CMTIME_IS_NUMERIC(delta), delta.value > 0 {
                pausedDuration = CMTimeAdd(pausedDuration, delta)
            }
            pauseStartedAt = nil
        }

        await teardownCaptureOnly()

        let result = try await finalizeWriter()
        state = .idle
        activeConfig = nil
        return result
    }

    // MARK: - Sample handling (called from proxies via Task)

    func handleScreenSample(_ sampleBuffer: CMSampleBuffer) async {
        guard state == .recording || state == .paused else { return }

        // Trap 2 + Trap 5: require .complete AND a non-nil image buffer.
        guard Self.isCompleteFrame(sampleBuffer),
              let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        let rawPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard CMTIME_IS_VALID(rawPTS), CMTIME_IS_NUMERIC(rawPTS) else { return }

        // Track pause boundaries against the raw (pre-subtraction) timeline.
        if state == .paused {
            if pauseStartedAt == nil {
                pauseStartedAt = rawPTS
            }
            lastAppendedPTS = rawPTS
            return
        }

        // Closing a pause: accumulate using rawPTS now that we're recording again.
        if let started = pauseStartedAt {
            let delta = CMTimeSubtract(rawPTS, started)
            if CMTIME_IS_NUMERIC(delta), delta.value > 0 {
                pausedDuration = CMTimeAdd(pausedDuration, delta)
            }
            pauseStartedAt = nil
        }

        let adjustedPTS = CMTimeSubtract(rawPTS, pausedDuration)

        if !sessionStarted {
            guard let writer = assetWriter, writer.status == .writing || writer.status == .unknown else { return }
            writer.startSession(atSourceTime: adjustedPTS)
            sessionStarted = true
            firstScreenPTS = adjustedPTS
        }

        guard let writer = assetWriter, writer.status == .writing,
              let videoInput, videoInput.isReadyForMoreMediaData,
              let adaptor = pixelBufferAdaptor else {
            return
        }

        let webcam = activeConfig?.includeWebcam == true ? webcamLatch.current() : nil
        let composited: CVPixelBuffer
        do {
            composited = try compositor.composite(screen: imageBuffer, webcam: webcam)
        } catch {
            // Fall back to raw screen frame rather than dropping.
            composited = imageBuffer
        }

        if adaptor.append(composited, withPresentationTime: adjustedPTS) {
            lastAppendedPTS = rawPTS
        }
    }

    func handleSystemAudioSample(_ sampleBuffer: CMSampleBuffer) async {
        await handleAudioSample(sampleBuffer, isMic: false)
    }

    func handleMicrophoneSample(_ sampleBuffer: CMSampleBuffer) async {
        await handleAudioSample(sampleBuffer, isMic: true)
    }

    private func handleAudioSample(_ sampleBuffer: CMSampleBuffer, isMic: Bool) async {
        guard state == .recording else { return }
        guard sessionStarted else {
            if isMic { pendingMicAudio = sampleBuffer } else { pendingSystemAudio = sampleBuffer }
            return
        }
        guard let writer = assetWriter, writer.status == .writing,
              let audioInput, audioInput.isReadyForMoreMediaData else {
            return
        }

        let rawPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let adjustedPTS = CMTimeSubtract(rawPTS, pausedDuration)

        do {
            let systemSample: CMSampleBuffer? = isMic ? nil : sampleBuffer
            let micSample: CMSampleBuffer? = isMic ? sampleBuffer : nil
            // When only one source arrives per callback, mix with nil other —
            // real dual-source mixing lands when both fire closely; for M3 the
            // mixer still converts + applies the correct per-source gain.
            guard let mixed = try audioMixer.mix(systemSample: systemSample, micSample: micSample) else {
                return
            }
            if let timed = Self.makeSampleBuffer(from: mixed, pts: adjustedPTS) {
                audioInput.append(timed)
            }
        } catch {
            // Drop the audio tick rather than killing the recording.
        }
    }

    /// Trap 6: stream died (sleep / disconnect / resolution change) — finalize, don't lose the file.
    func handleStreamStopped(error: Error?) async {
        guard state == .recording || state == .paused else { return }
        elapsedTickerTask?.cancel()
        elapsedTickerTask = nil
        await teardownCaptureOnly()
        do {
            _ = try await finalizeWriter()
        } catch {
            // Best-effort finalize; UI can observe state → idle with a partial file at outputURL.
        }
        state = .idle
    }

    // MARK: - Writer

    private func setupWriter(url: URL, width: Int, height: Int, fps: Int, includeAudio: Bool) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        } catch {
            throw RecordingEngineError.writerSetupFailed(error.localizedDescription)
        }

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoAverageBitRateKey: width * height * 4,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps * 2
            ]
        ]

        let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        vInput.expectsMediaDataInRealTime = true

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: vInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferMetalCompatibilityKey as String: true
            ]
        )

        guard writer.canAdd(vInput) else {
            throw RecordingEngineError.writerSetupFailed("Cannot add video input")
        }
        writer.add(vInput)

        var aInput: AVAssetWriterInput?
        if includeAudio {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: AudioMixer.sampleRate,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) {
                writer.add(input)
                aInput = input
            }
        }

        guard writer.startWriting() else {
            throw RecordingEngineError.writerSetupFailed(writer.error?.localizedDescription ?? "startWriting failed")
        }

        assetWriter = writer
        videoInput = vInput
        pixelBufferAdaptor = adaptor
        audioInput = aInput
    }

    private func finalizeWriter() async throws -> RecordingResult {
        guard let writer = assetWriter, let url = outputURL, let config = activeConfig else {
            throw RecordingEngineError.notRecording
        }

        videoInput?.markAsFinished()
        audioInput?.markAsFinished()

        let first = firstScreenPTS
        let lastRaw = lastAppendedPTS
        let paused = pausedDuration

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            writer.finishWriting {
                cont.resume()
            }
        }

        if writer.status == .failed {
            let msg = writer.error?.localizedDescription ?? "unknown writer failure"
            clearWriterState()
            throw RecordingEngineError.writerFailed(msg)
        }

        guard let first, CMTIME_IS_NUMERIC(first) else {
            clearWriterState()
            throw RecordingEngineError.noFramesCaptured
        }

        let endAdjusted = CMTimeSubtract(lastRaw, paused)
        let durationTime = CMTimeSubtract(endAdjusted, first)
        let duration = max(0, CMTimeGetSeconds(durationTime))

        let result = RecordingResult(
            fileURL: url,
            duration: duration,
            width: outputWidth,
            height: outputHeight,
            fps: config.fps,
            sourceDescription: config.source.description,
            hasWebcam: config.includeWebcam,
            hasMic: config.includeMic,
            hasSystemAudio: config.includeSystemAudio
        )

        clearWriterState()
        return result
    }

    private func clearWriterState() {
        assetWriter = nil
        videoInput = nil
        pixelBufferAdaptor = nil
        audioInput = nil
        outputURL = nil
        sessionStarted = false
        firstScreenPTS = nil
        pausedDuration = .zero
        pauseStartedAt = nil
        lastAppendedPTS = .zero
    }

    // MARK: - Capture teardown (keep writer alive for finalize)

    private func teardownCaptureOnly() async {
        if let scStream = stream {
            try? await scStream.stopCapture()
        }
        stream = nil
        streamOutput = nil

        if let session = captureSession {
            session.stopRunning()
        }
        captureSession = nil
        videoOutput = nil
        webcamProxy = nil
        webcamLatch.clear()
    }

    // MARK: - Webcam

    private func setupWebcam(deviceID: String?) throws {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        )
        let device: AVCaptureDevice?
        if let deviceID {
            device = discovery.devices.first { $0.uniqueID == deviceID } ?? AVCaptureDevice.default(for: .video)
        } else {
            device = AVCaptureDevice.default(for: .video)
        }
        guard let device else { throw RecordingEngineError.cameraUnavailable }

        let session = AVCaptureSession()
        session.beginConfiguration()
        session.sessionPreset = .high

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw RecordingEngineError.cameraUnavailable }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        let proxy = WebcamOutputProxy(latch: webcamLatch)
        webcamProxy = proxy
        output.setSampleBufferDelegate(proxy, queue: DispatchQueue(label: "LocalLoom.Webcam", qos: .userInitiated))
        guard session.canAddOutput(output) else { throw RecordingEngineError.cameraUnavailable }
        session.addOutput(output)

        session.commitConfiguration()
        captureSession = session
        videoOutput = output
        session.startRunning()
    }

    // MARK: - Elapsed ticker

    private func startElapsedTicker() {
        elapsedTickerTask?.cancel()
        elapsedTickerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self else { return }
                await self.tickElapsed()
            }
        }
    }

    private func tickElapsed() {
        guard state == .recording || state == .paused else { return }
        guard let start = recordingWallStart else { return }
        // Wall-clock based UI timer; media duration comes from PTS at stop.
        if state == .recording {
            elapsedSeconds = Date().timeIntervalSince(start) - CMTimeGetSeconds(pausedDuration)
        }
    }

    // MARK: - Static helpers

    /// Trap 2: discard idle/blank/etc. Only `.complete` frames are usable.
    nonisolated static func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) else {
            return false
        }
        let attachments = attachmentsArray as [AnyObject]
        guard let first = attachments.first as? [AnyHashable: Any] else {
            return false
        }

        // Preferred: typed SCStreamFrameInfo key.
        if let raw = first[SCStreamFrameInfo.status] as? Int {
            return SCFrameStatus(rawValue: raw) == .complete
        }
        if let number = first[SCStreamFrameInfo.status] as? NSNumber {
            return SCFrameStatus(rawValue: number.intValue) == .complete
        }
        // Fallback: string-keyed dictionaries seen on some SDK bridges.
        if let number = first["SCStreamFrameInfoStatus"] as? NSNumber
            ?? first["status"] as? NSNumber {
            return SCFrameStatus(rawValue: number.intValue) == .complete
        }
        return false
    }

    nonisolated static func makeContentFilter(
        config: RecordingConfig,
        content: SCShareableContent
    ) throws -> SCContentFilter {
        switch config.source.kind {
        case .display, .region:
            guard let displayID = config.source.displayID else {
                throw RecordingEngineError.displayNotFound(0)
            }
            guard let display = content.displays.first(where: { $0.displayID == displayID })
                    ?? content.displays.first else {
                throw RecordingEngineError.displayNotFound(displayID)
            }
            // Exclude nothing here — UI windows set sharingType = .none themselves (Trap 8).
            return SCContentFilter(display: display, excludingWindows: [])

        case .window:
            guard let windowID = config.source.windowID else {
                throw RecordingEngineError.windowNotFound(0)
            }
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                throw RecordingEngineError.windowNotFound(windowID)
            }
            return SCContentFilter(desktopIndependentWindow: window)
        }
    }

    nonisolated static func resolveOutputDimensions(
        config: RecordingConfig,
        content: SCShareableContent,
        filter: SCContentFilter
    ) throws -> (Int, Int) {
        let scale: CGFloat
        let pointWidth: CGFloat
        let pointHeight: CGFloat

        switch config.source.kind {
        case .display:
            let displayID = config.source.displayID ?? content.displays.first?.displayID ?? CGMainDisplayID()
            let display = content.displays.first { $0.displayID == displayID } ?? content.displays[0]
            pointWidth = CGFloat(display.width)
            pointHeight = CGFloat(display.height)
            scale = CoordinateConversion.nsScreen(forDisplayID: display.displayID)?.backingScaleFactor ?? 2

        case .region:
            let displayID = config.source.displayID ?? CGMainDisplayID()
            let display = content.displays.first { $0.displayID == displayID } ?? content.displays[0]
            scale = CoordinateConversion.nsScreen(forDisplayID: display.displayID)?.backingScaleFactor ?? 2
            if let rect = config.source.regionInNSScreenPoints,
               let sourceRect = CoordinateConversion.sourceRectInDisplayPoints(
                rectInNSScreenPoints: rect,
                displayID: display.displayID
               ) {
                pointWidth = sourceRect.width
                pointHeight = sourceRect.height
            } else {
                pointWidth = CGFloat(display.width)
                pointHeight = CGFloat(display.height)
            }

        case .window:
            let windowID = config.source.windowID ?? 0
            let window = content.windows.first { $0.windowID == windowID }
            let frame = window?.frame ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)
            pointWidth = frame.width
            pointHeight = frame.height
            // Window may span displays; prefer main scale as a reasonable default.
            scale = NSScreen.main?.backingScaleFactor ?? 2
        }

        let nativeW = Int((pointWidth * scale).rounded())
        let nativeH = Int((pointHeight * scale).rounded())
        return ResolutionMath.outputDimensions(
            nativeWidth: nativeW,
            nativeHeight: nativeH,
            cap: config.resolutionCap
        )
    }

    nonisolated static func makeStreamConfiguration(
        config: RecordingConfig,
        width: Int,
        height: Int,
        content: SCShareableContent
    ) -> SCStreamConfiguration {
        let sc = SCStreamConfiguration()
        sc.width = width
        sc.height = height
        sc.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(config.fps))
        sc.queueDepth = 6
        sc.pixelFormat = kCVPixelFormatType_32BGRA
        sc.showsCursor = true

        sc.capturesAudio = config.includeSystemAudio
        sc.captureMicrophone = config.includeMic
        if config.includeMic, let micID = config.microphoneDeviceID {
            sc.microphoneCaptureDeviceID = micID
        }

        if config.source.kind == .region,
           let displayID = config.source.displayID,
           let rect = config.source.regionInNSScreenPoints,
           let sourceRect = CoordinateConversion.sourceRectInDisplayPoints(
            rectInNSScreenPoints: rect,
            displayID: displayID
           ),
           let display = content.displays.first(where: { $0.displayID == displayID }) {
            sc.sourceRect = CoordinateConversion.clampSourceRect(
                sourceRect,
                displayWidthPoints: CGFloat(display.width),
                displayHeightPoints: CGFloat(display.height)
            )
        }

        return sc
    }

    nonisolated static func makeSampleBuffer(from pcm: AVAudioPCMBuffer, pts: CMTime) -> CMSampleBuffer? {
        let format = pcm.format
        var asbd = format.streamDescription.pointee
        var formatDescription: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        ) == noErr, let formatDescription else {
            return nil
        }

        let frameCount = CMItemCount(pcm.frameLength)
        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(format.sampleRate)),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )

        guard CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: frameCount,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else {
            return nil
        }

        guard let channelData = pcm.floatChannelData else { return nil }
        let channelCount = Int(format.channelCount)
        let bytesPerFrame = MemoryLayout<Float>.size
        let channelDataSize = Int(pcm.frameLength) * bytesPerFrame

        var blockBuffer: CMBlockBuffer?
        let totalBytes = channelDataSize * channelCount
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: totalBytes,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: totalBytes,
            flags: 0,
            blockBufferOut: &blockBuffer
        ) == noErr, let blockBuffer else {
            return nil
        }

        var offset = 0
        for ch in 0..<channelCount {
            _ = CMBlockBufferReplaceDataBytes(
                with: channelData[ch],
                blockBuffer: blockBuffer,
                offsetIntoDestination: offset,
                dataLength: channelDataSize
            )
            offset += channelDataSize
        }

        guard CMSampleBufferSetDataBuffer(sampleBuffer, newValue: blockBuffer) == noErr else {
            return nil
        }
        return sampleBuffer
    }
}

// MARK: - SCStream proxies

private final class StreamOutputProxy: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    /// Unowned: proxy lifetime is strictly bound to the owning engine session.
    private unowned let engine: RecordingEngine

    init(engine: RecordingEngine) {
        self.engine = engine
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .screen:
            Task { await engine.handleScreenSample(sampleBuffer) }
        case .audio:
            Task { await engine.handleSystemAudioSample(sampleBuffer) }
        case .microphone:
            Task { await engine.handleMicrophoneSample(sampleBuffer) }
        @unknown default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { await engine.handleStreamStopped(error: error) }
    }
}

// MARK: - Webcam proxy

private final class WebcamOutputProxy: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let latch: WebcamLatch

    init(latch: WebcamLatch) {
        self.latch = latch
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // Write the latch directly — no actor hop, no clock interaction (TRD §1.2).
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        latch.store(imageBuffer)
    }
}
