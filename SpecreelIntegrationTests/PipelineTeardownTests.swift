import AVFoundation
import CoreMedia
import Foundation
import XCTest
@testable import Specreel

/// Pipeline teardown / state-machine tests (TRD section 1.2-1.3 / section 7).
/// Covers RecordingEngine state transitions, AudioMixer pipeline steps,
/// and coordinate conversion invariants.
final class PipelineTeardownTests: XCTestCase {

    // MARK: - RecordingEngine state

    func testEngineStartsIdle() {
        let engine = RecordingEngine()
        XCTAssertEqual(engine.phase, .idle)
    }

    func testEngineStateTransitionsViaPause() async {
        let engine = RecordingEngine()
        XCTAssertEqual(engine.phase, .idle)

        await engine.pause()
        // Pause from idle should be a no-op
        XCTAssertEqual(engine.phase, .idle)
    }

    // MARK: - Coordinate conversion

    func testCoordinateConversionMain1xRoundTrip() {
        let display = CoordinateConversion.DisplayGeometry(
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            scaleFactor: 1.0
        )
        let source = CoordinateConversion.sourceRect(fromNSScreenRegion: display.frame, on: display)
        let back = CoordinateConversion.nsScreenRegion(fromSourceRect: source, on: display)
        XCTAssertEqual(display.frame.origin.x, back.origin.x, accuracy: 0.001)
        XCTAssertEqual(display.frame.origin.y, back.origin.y, accuracy: 0.001)
        XCTAssertEqual(display.frame.width, back.width, accuracy: 0.001)
        XCTAssertEqual(display.frame.height, back.height, accuracy: 0.001)
    }

    func testCoordinateConversionSecondary2xRoundTrip() {
        let display = CoordinateConversion.DisplayGeometry(
            frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080),
            scaleFactor: 2.0
        )
        let region = CGRect(x: 10, y: 20, width: 300, height: 200)
        let source = CoordinateConversion.sourceRect(fromNSScreenRegion: CGRect(
            x: 1450, y: 860, width: 300, height: 200
        ), on: display)
        let pixels = CoordinateConversion.pixelRect(fromSourceRect: source, scaleFactor: display.scaleFactor)
        XCTAssertEqual(pixels.width, 600, accuracy: 0.001)
        XCTAssertEqual(pixels.height, 400, accuracy: 0.001)
    }

    func testPixelRect2x() {
        let source = CGRect(x: 10, y: 20, width: 100, height: 50)
        let pixels = CoordinateConversion.pixelRect(fromSourceRect: source, scaleFactor: 2.0)
        XCTAssertEqual(pixels, CGRect(x: 20, y: 40, width: 200, height: 100))
    }

    func testPixelRectRoundTrip2x() {
        let source = CGRect(x: 12.5, y: 7.5, width: 100, height: 50)
        let pixels = CoordinateConversion.pixelRect(fromSourceRect: source, scaleFactor: 2.0)
        let back = CoordinateConversion.sourceRect(fromPixelRect: pixels, scaleFactor: 2.0)
        XCTAssertEqual(back.origin.x, source.origin.x, accuracy: 0.001)
        XCTAssertEqual(back.origin.y, source.origin.y, accuracy: 0.001)
    }

    // MARK: - AudioMixer pipeline

    func testAudioMixerSumAndClamp() throws {
        let mixer = AudioMixer()
        mixer.systemGainDb = 0 // 0 dB = unity (no attenuation)
        mixer.micGainDb = 0

        let sys = try makeBuffer(value: 0.8)
        let mic = try makeBuffer(value: 0.8)
        let result = try mixer.mix(systemPCM: sys, micPCM: mic)
        // sum = 1.6, clamped to 1.0
        assertSamples(result!, equalTo: 1.0)
    }

    func testAudioMixerClampNegative() throws {
        let mixer = AudioMixer()
        mixer.systemGainDb = 0
        mixer.micGainDb = 0

        let sys = try makeBuffer(value: -0.9)
        let mic = try makeBuffer(value: -0.9)
        let result = try mixer.mix(systemPCM: sys, micPCM: mic)
        // sum = -1.8, clamped to -1.0
        assertSamples(result!, equalTo: -1.0)
    }

    // MARK: - Helpers

    private func makeBuffer(value: Float) throws -> AVAudioPCMBuffer {
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

    private func assertSamples(_ buf: AVAudioPCMBuffer, equalTo expected: Float,
                               file: StaticString = #filePath, line: UInt = #line) {
        guard let ch0 = buf.floatChannelData?[0], let ch1 = buf.floatChannelData?[1] else {
            XCTFail("No channel data", file: file, line: line)
            return
        }
        for i in 0..<Int(buf.frameLength) {
            XCTAssertEqual(ch0[i], expected, accuracy: 1e-5, file: file, line: line)
            XCTAssertEqual(ch1[i], expected, accuracy: 1e-5, file: file, line: line)
        }
    }

    private enum TestError: Error { case bufferAllocFailed, noChannelData }
}