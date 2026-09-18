import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia
import CoreVideo
import AppKit
import QuartzCore
import os.log

private let engineLog = Logger(subsystem: "com.localloom.app", category: "RecordingEngine")

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
    case screenRecordingDenied
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
        case .screenRecordingDenied:
            return "Screen Recording permission is required. Enable LocalLoom in System Settings, then quit and reopen the app."
        case .displayNotFound(let id): return "Display \(id) was not found"
        case .windowNotFound(let id): return "Window \(id) was not found"
        case .writerSetupFailed(let msg): return "AVAssetWriter setup failed: \(msg)"
        case .writerFailed(let msg): return "AVAssetWriter failed: \(msg)"
        case .noFramesCaptured:
            return "No frames were captured. ScreenCaptureKit only sends frames when the screen changes — move the cursor during the recording, then stop."
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

    /// Serial queue for SCStream callbacks + writer mutation. Never spawn per-frame
    /// `Task`s from the stream output — that unbounded concurrency froze the app
    /// within seconds of hitting Record.
    fileprivate let pipelineQueue = DispatchQueue(label: "com.localloom.pipeline", qos: .userInitiated)

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

    /// Latest screen frame waiting to be drained (coalesce under load).
    private var pendingScreenSample: CMSampleBuffer?
    private var screenDrainScheduled = false

    /// Prevents double `finishWriting` (user Stop + stream-death) and blocks
    /// appends once teardown begins. Backed by `stateLock` — `stop()` sets this
    /// off `pipelineQueue` (a hung compositor must not block teardown from
    /// starting), so it needs real synchronization with the queue's readers.
    private var _isStopping = false
    private var isStopping: Bool {
        get { stateLock.withLock { _isStopping } }
        set { stateLock.withLock { _isStopping = newValue } }
    }
    private var writerFinalized = false
    /// pipelineQueue-confined: true once at least one audio sample has been
    /// appended. Used at finalize time to avoid the empty-audio-track hang.
    private var didAppendAudio = false
    /// pipelineQueue-confined diagnostic counters, logged at finalize time.
    private var appendedVideoFrameCount = 0
    private var appendedAudioSampleCount = 0
    private var compositedFrameCount = 0

    /// Bumped on every `start()`. Sample/delegate callbacks carry the generation
    /// they were registered under so a zombie `SCStream` still draining from a
    /// prior session (its `stopCapture()` is fire-and-forget and can hang) can't
    /// feed stale frames into a newer recording.
    private var _currentGeneration: UInt64 = 0
    private var currentGeneration: UInt64 {
        get { stateLock.withLock { _currentGeneration } }
        set { stateLock.withLock { _currentGeneration = newValue } }
    }

    /// Single-flight stop so the pill and the window can't both finalize.
    private let stopLock = NSLock()
    private var inFlightStop: Task<RecordingResult, Error>?

    // MARK: - Public API

    func start(config: RecordingConfig) async throws {
        guard state == .idle else { throw RecordingEngineError.alreadyRecording }

        // Record is an explicit user action — request once if needed, then fail clearly
        // instead of letting SCShareableContent surface a confusing TCC sheet mid-setup.
        if !ScreenCaptureAccess.isGranted {
            let granted = await MainActor.run { ScreenCaptureAccess.request() }
            guard granted else {
                throw RecordingEngineError.screenRecordingDenied
            }
        }

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
        pendingScreenSample = nil
        screenDrainScheduled = false
        isStopping = false
        writerFinalized = false
        didAppendAudio = false
        appendedVideoFrameCount = 0
        appendedAudioSampleCount = 0
        compositedFrameCount = 0
        let generation = currentGeneration + 1
        currentGeneration = generation
        await publishElapsed(0)

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
        let proxy = StreamOutputProxy(engine: self, generation: generation)
        streamOutput = proxy

        let scStream = SCStream(filter: filter, configuration: streamConfig, delegate: proxy)
        do {
            // All outputs share `pipelineQueue` so sample handling stays serial.
            try scStream.addStreamOutput(proxy, type: .screen, sampleHandlerQueue: pipelineQueue)
            if snapshot.includeSystemAudio {
                try scStream.addStreamOutput(proxy, type: .audio, sampleHandlerQueue: pipelineQueue)
            }
            if snapshot.includeMic {
                try scStream.addStreamOutput(proxy, type: .microphone, sampleHandlerQueue: pipelineQueue)
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

        recordingWallStart = Date()
        await publishPhase(.recording)
        startElapsedTicker()
    }

    func pause() async {
        guard phase == .recording else { return }
        await publishPhase(.paused)
        pipelineQueue.async { [weak self] in
            guard let self else { return }
            if self.pauseStartedAt == nil {
                self.pauseStartedAt = self.lastAppendedPTS
            }
        }
    }

    func resume() async {
        guard phase == .paused else { return }
        // Leave `pauseStartedAt` set — next screen sample closes the interval.
        await publishPhase(.recording)
    }

    @discardableResult
    func stop() async throws -> RecordingResult {
        stopLock.lock()
        if let inFlight = inFlightStop {
            stopLock.unlock()
            return try await inFlight.value
        }
        let task = Task { try await self.performStop() }
        inFlightStop = task
        stopLock.unlock()
        do {
            let result = try await task.value
            stopLock.lock()
            inFlightStop = nil
            stopLock.unlock()
            return result
        } catch {
            stopLock.lock()
            inFlightStop = nil
            stopLock.unlock()
            throw error
        }
    }

    private func performStop() async throws -> RecordingResult {
        guard phase == .recording || phase == .paused else {
            throw RecordingEngineError.notRecording
        }

        elapsedTickerTask?.cancel()
        elapsedTickerTask = nil

        // Set this without waiting on pipelineQueue — a hung compositor on that
        // queue must not block Stop from starting teardown.
        isStopping = true

        await Self.resumeOnce(seconds: 1.0) { resume in
            self.pipelineQueue.async {
                if let started = self.pauseStartedAt {
                    let delta = CMTimeSubtract(self.lastAppendedPTS, started)
                    if CMTIME_IS_NUMERIC(delta), delta.value > 0 {
                        self.pausedDuration = CMTimeAdd(self.pausedDuration, delta)
                    }
                    self.pauseStartedAt = nil
                }
                self.pendingScreenSample = nil
                self.screenDrainScheduled = false
                resume()
            }
        }

        // 2) Stop capture producers (bounded — SCStream.stopCapture can hang).
        await teardownCaptureOnly()

        // 3) Barrier: wait briefly for in-flight appends; don't hang if the queue is stuck.
        await Self.resumeOnce(seconds: 1.0) { resume in
            self.pipelineQueue.async { resume() }
        }

        // 4) Finalize writer (bounded — finishWriting can hang with an unused audio track).
        do {
            let result = try await finalizeWriter()
            activeConfig = nil
            await publishPhase(.idle)
            return result
        } catch {
            activeConfig = nil
            await publishPhase(.idle)
            throw error
        }
    }

    // MARK: - UI state (must publish on main — @Observable + SwiftUI)

    private func publishPhase(_ newPhase: RecordingEngineState) async {
        await MainActor.run { self.state = newPhase }
    }

    private func publishElapsed(_ value: TimeInterval) async {
        await MainActor.run { self.elapsedSeconds = value }
    }

    // MARK: - Sample handling (pipelineQueue only)

    /// Coalesce screen frames: keep only the latest while draining.
    fileprivate func enqueueScreenSample(_ sampleBuffer: CMSampleBuffer, generation: UInt64) {
        guard generation == currentGeneration, !isStopping else { return }
        pendingScreenSample = sampleBuffer
        guard !screenDrainScheduled else { return }
        screenDrainScheduled = true
        drainPendingScreenSamples()
    }

    private func drainPendingScreenSamples() {
        while let sampleBuffer = pendingScreenSample {
            pendingScreenSample = nil
            processScreenSample(sampleBuffer)
        }
        screenDrainScheduled = false
    }

    private func processScreenSample(_ sampleBuffer: CMSampleBuffer) {
        guard !isStopping else { return }
        let current = phase
        guard current == .recording || current == .paused else { return }

        guard Self.isCompleteFrame(sampleBuffer),
              let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        let rawPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard CMTIME_IS_VALID(rawPTS), CMTIME_IS_NUMERIC(rawPTS) else { return }

        if current == .paused {
            if pauseStartedAt == nil {
                pauseStartedAt = rawPTS
            }
            lastAppendedPTS = rawPTS
            return
        }

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

        // Skip Metal/CI compositor when webcam is off — CIContext every frame
        // was a major backlog/freeze source for the default recording path.
        let frameToWrite: CVPixelBuffer
        if activeConfig?.includeWebcam == true, let webcam = webcamLatch.current() {
            do {
                frameToWrite = try compositor.composite(screen: imageBuffer, webcam: webcam)
                compositedFrameCount += 1
            } catch {
                frameToWrite = imageBuffer
            }
        } else {
            frameToWrite = imageBuffer
        }

        if adaptor.append(frameToWrite, withPresentationTime: adjustedPTS) {
            appendedVideoFrameCount += 1
            lastAppendedPTS = rawPTS
        }
    }

    fileprivate func processSystemAudioSample(_ sampleBuffer: CMSampleBuffer, generation: UInt64) {
        processAudioSample(sampleBuffer, isMic: false, generation: generation)
    }

    fileprivate func processMicrophoneSample(_ sampleBuffer: CMSampleBuffer, generation: UInt64) {
        processAudioSample(sampleBuffer, isMic: true, generation: generation)
    }

    private func processAudioSample(_ sampleBuffer: CMSampleBuffer, isMic: Bool, generation: UInt64) {
        guard generation == currentGeneration, !isStopping else { return }
        guard phase == .recording else { return }
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
            guard let mixed = try audioMixer.mix(systemSample: systemSample, micSample: micSample) else {
                return
            }
            if let timed = Self.makeSampleBuffer(from: mixed, pts: adjustedPTS) {
                if audioInput.append(timed) {
                    didAppendAudio = true
                    appendedAudioSampleCount += 1
                }
            }
        } catch {
            // Drop the audio tick rather than killing the recording.
        }
    }

    /// Trap 6: stream died — reuse stop() so finalize rules stay in one place.
    fileprivate func handleStreamStopped(error: Error?, generation: UInt64) {
        Task { [weak self] in
            guard let self else { return }
            guard generation == self.currentGeneration else { return }
            guard self.phase == .recording || self.phase == .paused else { return }
            do {
                _ = try await self.stop()
            } catch {
                await self.publishPhase(.idle)
            }
        }
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

    /// Status 1 (`.writing`) without `startSession` makes `finishWriting` throw
    /// NSInternalInconsistencyException — cancel instead when no frames arrived.
    private func finalizeWriter() async throws -> RecordingResult {
        struct FinishRequest {
            let writer: AVAssetWriter
            let url: URL
            let config: RecordingConfig
            let first: CMTime
            let lastRaw: CMTime
            let paused: CMTime
            let width: Int
            let height: Int
            let videoFrames: Int
            let audioSamples: Int
            let compositedFrames: Int
        }

        enum Prep {
            case missing
            case alreadyFinalized
            case noSession(url: URL)
            case ready(FinishRequest)
            case timedOut
        }

        let prep: Prep = await withCheckedContinuation { cont in
            let gate = OnceGate()
            pipelineQueue.async {
                var value: Prep = .missing
                defer { gate.go { cont.resume(returning: value) } }

                guard let writer = self.assetWriter,
                      let url = self.outputURL,
                      let config = self.activeConfig else {
                    return
                }
                if self.writerFinalized {
                    value = .alreadyFinalized
                    return
                }

                let first = self.firstScreenPTS
                let lastRaw = self.lastAppendedPTS
                let paused = self.pausedDuration
                let width = self.outputWidth
                let height = self.outputHeight
                let didStartSession = self.sessionStarted && first != nil

                // No startSession → cancelWriting. Calling finishWriting here crashes
                // with: "Cannot call method when status is 1".
                if !didStartSession || writer.status != .writing {
                    self.writerFinalized = true
                    if writer.status == .writing {
                        writer.cancelWriting()
                    }
                    self.clearWriterState()
                    value = .noSession(url: url)
                    return
                }

                self.writerFinalized = true
                // Known AVAssetWriter gotcha: finishWriting can hang forever when an
                // audio input was added but never received a single sample. Feed one
                // silent buffer so the track isn't empty before marking it finished.
                if let audioInput = self.audioInput, !self.didAppendAudio,
                   let silent = Self.makeSilentAudioSampleBuffer(pts: first!) {
                    audioInput.append(silent)
                }
                self.videoInput?.markAsFinished()
                self.audioInput?.markAsFinished()

                let request = FinishRequest(
                    writer: writer,
                    url: url,
                    config: config,
                    first: first!,
                    lastRaw: lastRaw,
                    paused: paused,
                    width: width,
                    height: height,
                    videoFrames: self.appendedVideoFrameCount,
                    audioSamples: self.appendedAudioSampleCount,
                    compositedFrames: self.compositedFrameCount
                )
                // Detach inputs/adaptor; keep writer alive for finishWriting.
                self.videoInput = nil
                self.audioInput = nil
                self.pixelBufferAdaptor = nil
                self.assetWriter = nil
                self.outputURL = nil
                value = .ready(request)
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2.0) {
                gate.go { cont.resume(returning: .timedOut) }
            }
        }

        switch prep {
        case .missing, .alreadyFinalized:
            throw RecordingEngineError.notRecording
        case .noSession(let url):
            try? FileManager.default.removeItem(at: url)
            throw RecordingEngineError.noFramesCaptured
        case .timedOut:
            // pipelineQueue never answered inside the prep window, so the writer/
            // timing fields (confined to that queue) can't be safely read here and
            // finishWriting was never even invoked. Fail closed instead of guessing
            // from raced state — the queued prep block still runs to completion on
            // its own once the queue frees up and quietly finalizes/cancels there.
            throw RecordingEngineError.writerFailed("Timed out finalizing the recording")
        case .ready(let request):
            // Widened from 8s: Console logging (see finishWritingBounded) showed
            // finishWriting's completion consistently landing right at/after an 8s
            // bound, which reads as "slow" rather than a true hang. Give it more
            // room while we confirm the real completion time.
            engineLog.notice("finalize: calling finishWriting, status=\(request.writer.status.rawValue, privacy: .public), videoFrames=\(request.videoFrames, privacy: .public), audioSamples=\(request.audioSamples, privacy: .public), compositedFrames=\(request.compositedFrames, privacy: .public), webcam=\(request.config.includeWebcam, privacy: .public), mic=\(request.config.includeMic, privacy: .public), sysAudio=\(request.config.includeSystemAudio, privacy: .public), size=\(request.width, privacy: .public)x\(request.height, privacy: .public)")
            let finished = await Self.finishWritingBounded(request.writer, seconds: 25)
            if !finished {
                // Don't cancelWriting while finishWriting is still in flight — that
                // can crash. The file may still be missing its moov atom even if it
                // has bytes, so verify it's actually readable before trusting it.
                guard Self.isFinishedAsset(at: request.url) else {
                    await clearWriterStateBounded()
                    throw RecordingEngineError.writerFailed("Timed out finishing the video file")
                }
            } else if request.writer.status == .failed {
                let msg = request.writer.error?.localizedDescription ?? "unknown writer failure"
                try? FileManager.default.removeItem(at: request.url)
                await clearWriterStateBounded()
                throw RecordingEngineError.writerFailed(msg)
            }

            let result = Self.makeResult(
                url: request.url,
                config: request.config,
                first: request.first,
                lastRaw: request.lastRaw,
                paused: request.paused,
                width: request.width,
                height: request.height
            )
            await clearWriterStateBounded()
            return result
        }
    }

    private static func makeResult(
        url: URL,
        config: RecordingConfig,
        first: CMTime,
        lastRaw: CMTime,
        paused: CMTime,
        width: Int,
        height: Int
    ) -> RecordingResult {
        let endAdjusted = CMTimeSubtract(lastRaw, paused)
        let durationTime = CMTimeSubtract(endAdjusted, first)
        let duration = max(0, CMTimeGetSeconds(durationTime))
        return RecordingResult(
            fileURL: url,
            duration: duration,
            width: width,
            height: height,
            fps: config.fps,
            sourceDescription: config.source.description,
            hasWebcam: config.includeWebcam,
            hasMic: config.includeMic,
            hasSystemAudio: config.includeSystemAudio
        )
    }

    /// A moved/truncated mp4 without a moov atom reports a non-numeric or zero
    /// duration — this is a cheap, real check that finishWriting actually landed,
    /// unlike trusting byte count alone.
    nonisolated static func isFinishedAsset(at url: URL) -> Bool {
        let asset = AVURLAsset(url: url)
        guard asset.isReadable else { return false }
        let duration = asset.duration
        return CMTIME_IS_NUMERIC(duration) && duration.seconds > 0
    }

    private func clearWriterStateBounded() async {
        await Self.resumeOnce(seconds: 1.0) { resume in
            self.pipelineQueue.async {
                self.clearWriterState()
                resume()
            }
        }
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
        isStopping = false
        // writerFinalized stays true until the next start() resets it
    }

    // MARK: - Capture teardown (keep writer alive for finalize)

    private func teardownCaptureOnly() async {
        let scStream = stream
        stream = nil
        streamOutput = nil
        // Do not await stopCapture — it has been observed to never return, and
        // structured timeouts still join the hung child. isStopping already drops samples.
        if let scStream {
            engineLog.notice("teardown: calling stopCapture (fire-and-forget)")
            Task {
                let start = DispatchTime.now()
                do {
                    try await scStream.stopCapture()
                    let ms = (DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
                    engineLog.notice("teardown: stopCapture completed after \(ms, privacy: .public)ms")
                } catch {
                    let ms = (DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
                    engineLog.notice("teardown: stopCapture threw after \(ms, privacy: .public)ms: \(String(describing: error), privacy: .public)")
                }
            }
        }

        let session = captureSession
        captureSession = nil
        videoOutput = nil
        webcamProxy = nil
        webcamLatch.clear()
        if let session {
            await Self.resumeOnce(seconds: 1.5) { resume in
                DispatchQueue.global(qos: .userInitiated).async {
                    session.stopRunning()
                    resume()
                }
            }
        }
    }

    /// Completes when `kickoff` calls `resume`, or when `seconds` elapse.
    /// Unlike TaskGroup, this does **not** join hung work after the timeout.
    private static func resumeOnce(seconds: TimeInterval, kickoff: (@escaping @Sendable () -> Void) -> Void) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let gate = OnceGate()
            kickoff {
                gate.go { cont.resume() }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) {
                gate.go { cont.resume() }
            }
        }
    }

    /// `finishWriting` is async and has been observed never to call back (especially
    /// when an audio input was added but received no samples). Bound the wait without
    /// joining the hung callback. Logs whichever side wins — including a late
    /// completion after the bound already gave up — so Console shows the real
    /// elapsed time instead of us guessing at it.
    private static func finishWritingBounded(_ writer: AVAssetWriter, seconds: TimeInterval) async -> Bool {
        let start = DispatchTime.now()
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let gate = OnceGate()
            writer.finishWriting {
                let elapsedMs = (DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
                let won = gate.go { cont.resume(returning: true) }
                engineLog.notice("finishWriting completion fired after \(elapsedMs, privacy: .public)ms, status=\(writer.status.rawValue, privacy: .public), boundWon=\(won, privacy: .public)")
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) {
                let won = gate.go { cont.resume(returning: false) }
                if won {
                    engineLog.notice("finishWriting bound (\(seconds, privacy: .public)s) expired first, status=\(writer.status.rawValue, privacy: .public)")
                }
            }
        }
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

    private func tickElapsed() async {
        let current = phase
        guard current == .recording else { return }
        guard let start = recordingWallStart else { return }
        let paused = CMTimeGetSeconds(pausedDuration)
        let value = Date().timeIntervalSince(start) - paused
        await publishElapsed(max(0, value))
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

    /// A short zero-filled buffer for the empty-audio-track finishWriting hang
    /// workaround — `AVAudioPCMBuffer` is zeroed on allocation, so no explicit fill.
    nonisolated static func makeSilentAudioSampleBuffer(pts: CMTime) -> CMSampleBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: AudioMixer.mixFormat, frameCapacity: 1024) else {
            return nil
        }
        buffer.frameLength = 1024
        return makeSampleBuffer(from: buffer, pts: pts)
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
    /// The engine session this proxy was registered under — lets the engine drop
    /// callbacks from a zombie stream whose fire-and-forget `stopCapture()` never
    /// returned before a new recording started.
    private let generation: UInt64

    init(engine: RecordingEngine, generation: UInt64) {
        self.engine = engine
        self.generation = generation
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // Invoked on `engine.pipelineQueue` — process synchronously, no per-frame Task.
        switch type {
        case .screen:
            engine.enqueueScreenSample(sampleBuffer, generation: generation)
        case .audio:
            engine.processSystemAudioSample(sampleBuffer, generation: generation)
        case .microphone:
            engine.processMicrophoneSample(sampleBuffer, generation: generation)
        @unknown default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        engine.handleStreamStopped(error: error, generation: generation)
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

/// Resume-once latch so a timeout and a late callback cannot double-resume a continuation.
private final class OnceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    @discardableResult
    func go(_ body: () -> Void) -> Bool {
        lock.lock()
        let shouldRun = !done
        if shouldRun { done = true }
        lock.unlock()
        if shouldRun { body() }
        return shouldRun
    }
}
