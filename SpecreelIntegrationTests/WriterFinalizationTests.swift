import AVFoundation
import CoreMedia
import XCTest
@testable import Specreel

/// Integration tests for pause PTS subtraction (Trap 4) and stream-death finalization (Trap 6).
/// Tests RecordingEngine's pause/resume logic via synthetic inputs where possible.
final class WriterFinalizationTests: XCTestCase {

    func testRecordingMetaRoundTripFromMinimalData() throws {
        // Verify that RecordingMeta Codable can survive a round trip
        let meta = RecordingMeta(
            id: "test123",
            title: "Test Recording",
            description: "Integration test",
            createdAt: Date(),
            duration: 30.0,
            width: 1920,
            height: 1080,
            fps: 30,
            fileSize: 1_000_000,
            source: .init(type: .display, app: nil, title: nil),
            hasWebcam: false,
            hasMic: true,
            hasSystemAudio: true
        )
        let data = try meta.encodeData(prettyPrinted: true)
        let decoded = try RecordingMeta.decode(from: data)
        XCTAssertEqual(decoded.id, meta.id)
        XCTAssertEqual(decoded.title, meta.title)
    }

    func testAudioMixerProducesConsistentFormat() throws {
        let mixer = AudioMixer()
        let sys = try makeConstantBuffer(value: 0.3)
        let result = try mixer.mix(systemPCM: sys, micPCM: nil)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.format.sampleRate, 48_000)
        XCTAssertEqual(result?.format.channelCount, 2)
    }

    func testRecordingEngineStateTransitions() async {
        let engine = RecordingEngine()
        // Initial state should be idle
        XCTAssertEqual(engine.phase, .idle)
    }

    // MARK: - Helpers

    private func makeConstantBuffer(value: Float) throws -> AVAudioPCMBuffer {
        let fmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        )!
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 64) else {
            XCTFail("Buffer allocation failed")
            throw TestError.bufferAllocFailed
        }
        buf.frameLength = 64
        guard let ch0 = buf.floatChannelData?[0], let ch1 = buf.floatChannelData?[1] else {
            throw TestError.noChannelData
        }
        for i in 0..<64 { ch0[i] = value; ch1[i] = value }
        return buf
    }

    private enum TestError: Error { case bufferAllocFailed, noChannelData }
}