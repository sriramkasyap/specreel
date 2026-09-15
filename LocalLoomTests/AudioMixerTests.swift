import AVFoundation
import XCTest
@testable import LocalLoom

/// Unit tests for `AudioMixer` (TRD section 1.3 / section 7).
/// Covers default gain, format, per-source gain application, summing, clamping, and CMSampleBuffer conversion.
final class AudioMixerTests: XCTestCase {

    private let frameCount: AVAudioFrameCount = 256
    private let epsilon: Float = 1e-5

    // MARK: - Helpers

    private func makeFloat32StereoBuffer(
        sampleRate: Double = 48_000,
        frames: AVAudioFrameCount? = nil,
        fill: (UnsafeMutablePointer<Float>, UnsafeMutablePointer<Float>, AVAudioFrameCount) -> Void
    ) throws -> AVAudioPCMBuffer {
        let fmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 2,
            interleaved: false
        )!
        let cap = frames ?? frameCount
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: cap) else {
            XCTFail("Buffer allocation failed")
            throw TestError.bufferAllocFailed
        }
        buf.frameLength = cap
        guard let ch0 = buf.floatChannelData?[0], let ch1 = buf.floatChannelData?[1] else {
            throw TestError.noChannelData
        }
        fill(ch0, ch1, cap)
        return buf
    }

    private func constantBuffer(value: Float) throws -> AVAudioPCMBuffer {
        try makeFloat32StereoBuffer { c0, c1, count in
            for i in 0..<Int(count) { c0[i] = value; c1[i] = value }
        }
    }

    private func assertSamples(
        _ buffer: AVAudioPCMBuffer,
        equalTo expected: Float,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let ch0 = buffer.floatChannelData?[0],
              let ch1 = buffer.floatChannelData?[1] else {
            XCTFail("No channel data", file: file, line: line)
            return
        }
        for i in 0..<Int(buffer.frameLength) {
            XCTAssertEqual(ch0[i], expected, accuracy: epsilon, file: file, line: line)
            XCTAssertEqual(ch1[i], expected, accuracy: epsilon, file: file, line: line)
        }
    }

    private enum TestError: Error { case bufferAllocFailed, noChannelData }

    // MARK: - Defaults

    func testDefaultSystemGainIsMinusSixDecibelsRelativeToUnityMic() {
        let mixer = AudioMixer()
        let expectedSystemLinear = AudioMixer.linearGain(fromDb: -6) // approx 0.501
        XCTAssertEqual(mixer.systemGainDb, -6, accuracy: epsilon)
        XCTAssertEqual(mixer.micGainDb, 0, accuracy: epsilon)
        // Verify the linear value matches: linearGain(fromDb: -6)
        XCTAssertEqual(AudioMixer.linearGain(fromDb: -6), expectedSystemLinear, accuracy: epsilon)
    }

    func testTargetFormatIs48kStereoFloat32() {
        let format = AudioMixer.mixFormat
        XCTAssertEqual(format.sampleRate, 48_000, accuracy: 0.1)
        XCTAssertEqual(format.channelCount, 2)
        XCTAssertEqual(format.commonFormat, .pcmFormatFloat32)
        XCTAssertFalse(format.isInterleaved)
    }

    // MARK: - Gain

    func testApplyGainScalesAllSamples() throws {
        let input = try constantBuffer(value: 0.5)
        AudioMixer.applyGain(input, gainDb: -6) // -6 dB = ~0.5 linear
        let expected = Float(0.5 * AudioMixer.linearGain(fromDb: -6))
        assertSamples(input, equalTo: expected)
    }

    func testApplyUnityGainIsIdentity() throws {
        let input = try constantBuffer(value: 0.42)
        AudioMixer.applyGain(input, gainDb: 0) // 0 dB = 1.0 linear
        assertSamples(input, equalTo: 0.42)
    }

    func testApplyZeroLinearGainSilencesBuffer() throws {
        let input = try constantBuffer(value: 0.9)
        AudioMixer.applyGain(input, gainDb: -80) // -80 dB = linear ~0.0001
        // Expect near-zero output (not exactly 0 due to float rounding)
        let expected: Float = 0.9 * AudioMixer.linearGain(fromDb: -80)
        assertSamples(input, equalTo: expected)
    }

    // MARK: - Format conversion

    func testConvertResamplesTo48kStereoFloat32() throws {
        let mixer = AudioMixer()
        // 24 kHz mono float -> should become 48 kHz stereo float32
        let mono24 = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 24_000,
            channels: 1,
            interleaved: false
        )!
        guard let input = AVAudioPCMBuffer(pcmFormat: mono24, frameCapacity: 128) else {
            XCTFail("Failed to create input buffer")
            return
        }
        input.frameLength = 128
        if let ch = input.floatChannelData?[0] {
            for i in 0..<128 { ch[i] = 0.3 }
        }
        let result = try mixer.mix(systemPCM: input, micPCM: nil)
        XCTAssertNotNil(result)
        let sampleRate = result?.format.sampleRate ?? 0
        XCTAssertEqual(sampleRate, 48_000, accuracy: 0.1)
        XCTAssertEqual(result?.format.channelCount ?? 0, 2)
    }

    // MARK: - Mixing

    func testMixBothSourcesSummedAndClamped() throws {
        let mixer = AudioMixer()
        mixer.systemGainDb = 0 // Unity gain for predictable math
        mixer.micGainDb = 0
        let sys = try constantBuffer(value: 0.7)
        let mic = try constantBuffer(value: 0.5)
        let result = try mixer.mix(systemPCM: sys, micPCM: mic)
        XCTAssertNotNil(result)
        // sum = 0.7 + 0.5 = 1.2, clamped to 1.0
        assertSamples(result!, equalTo: 1.0)
    }

    func testMixSystemOnly() throws {
        let mixer = AudioMixer()
        let sys = try constantBuffer(value: 0.4)
        let result = try mixer.mix(systemPCM: sys, micPCM: nil)
        XCTAssertNotNil(result)
    }

    func testMixMicOnly() throws {
        let mixer = AudioMixer()
        let mic = try constantBuffer(value: 0.4)
        let result = try mixer.mix(systemPCM: nil, micPCM: mic)
        XCTAssertNotNil(result)
    }

    func testMixBothNilReturnsNil() throws {
        let mixer = AudioMixer()
        let result = try mixer.mix(systemPCM: nil, micPCM: nil)
        XCTAssertNil(result)
    }
}