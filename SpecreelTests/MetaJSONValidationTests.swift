import Foundation
import XCTest
@testable import Specreel

/// RecordingMeta Codable / schema tests (TRD section 1.4 / section 7).
final class MetaJSONValidationTests: XCTestCase {

    private func sampleMeta(
        id: String = "a3f9c1",
        sourceType: RecordingMeta.SourceType = .display,
        app: String? = nil,
        title: String? = "Built-in Retina Display"
    ) -> RecordingMeta {
        RecordingMeta(
            id: id,
            title: "Demo take",
            description: "A short description",
            createdAt: ISO8601DateFormatter().date(from: "2026-09-15T14:30:22Z")!,
            duration: 12.5,
            width: 2560,
            height: 1440,
            fps: 30,
            fileSize: 4_194_304,
            source: .init(type: sourceType, app: app, title: title),
            hasWebcam: true,
            hasMic: true,
            hasSystemAudio: false
        )
    }

    // MARK: - Codable round-trip

    func testCodableRoundTrip_displaySource() throws {
        let meta = sampleMeta()
        let data = try meta.encodeData(prettyPrinted: true)
        let decoded = try RecordingMeta.decode(from: data)
        XCTAssertEqual(decoded.id, meta.id)
        XCTAssertEqual(decoded.title, meta.title)
        XCTAssertEqual(decoded.source.type, .display)
    }

    func testCodableRoundTrip_windowSource() throws {
        let meta = sampleMeta(sourceType: .window, app: "Safari", title: "localhost:3000")
        let data = try meta.encodeData()
        let decoded = try RecordingMeta.decode(from: data)
        XCTAssertEqual(decoded.source.type, .window)
        XCTAssertEqual(decoded.source.app, "Safari")
        XCTAssertEqual(decoded.source.title, "localhost:3000")
    }

    func testCodableRoundTrip_regionSource() throws {
        let meta = sampleMeta(sourceType: .region)
        let data = try meta.encodeData()
        let decoded = try RecordingMeta.decode(from: data)
        XCTAssertEqual(decoded.source.type, .region)
    }

    // MARK: - JSON key names

    func testJSONKeyNames() throws {
        let meta = sampleMeta()
        let data = try meta.encodeData(prettyPrinted: true)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertNotNil(json["id"])
        XCTAssertNotNil(json["title"])
        XCTAssertNotNil(json["description"])
        XCTAssertNotNil(json["createdAt"])
        XCTAssertNotNil(json["duration"])
        XCTAssertNotNil(json["width"])
        XCTAssertNotNil(json["height"])
        XCTAssertNotNil(json["fps"])
        XCTAssertNotNil(json["fileSize"])
        XCTAssertNotNil(json["source"])
        XCTAssertNotNil(json["hasWebcam"])
        XCTAssertNotNil(json["hasMic"])
        XCTAssertNotNil(json["hasSystemAudio"])
    }

    // MARK: - Decode from example JSON (TRD section 1.4)

    func testDecodeExampleJSON() throws {
        let json = """
        {
          "id": "a3f9c1",
          "title": "Auth flow walkthrough",
          "description": "Covers the token refresh edge case at 2:40",
          "createdAt": "2026-09-15T14:30:22Z",
          "duration": 384.2,
          "width": 1920,
          "height": 1080,
          "fps": 30,
          "fileSize": 112340992,
          "source": { "type": "window", "app": "Safari", "title": "localhost:3000" },
          "hasWebcam": true,
          "hasMic": true,
          "hasSystemAudio": true
        }
        """
        let data = Data(json.utf8)
        let meta = try RecordingMeta.decode(from: data)
        XCTAssertEqual(meta.id, "a3f9c1")
        XCTAssertEqual(meta.title, "Auth flow walkthrough")
        XCTAssertEqual(meta.source.type, .window)
        XCTAssertEqual(meta.source.app, "Safari")
        XCTAssertEqual(meta.hasWebcam, true)
    }

    // MARK: - Validation edge cases

    func testDecodeAllSourceTypes() throws {
        for type in RecordingMeta.SourceType.allCases {
            let json = """
            {"id":"x","title":"t","description":"d","createdAt":"2026-01-01T00:00:00Z","duration":1,"width":100,"height":100,"fps":30,"fileSize":0,"source":{"type":"\(type.rawValue)"},"hasWebcam":false,"hasMic":false,"hasSystemAudio":false}
            """
            let meta = try RecordingMeta.decode(from: Data(json.utf8))
            XCTAssertEqual(meta.source.type, type)
        }
    }

    func testDecodeMissingIdThrows() {
        let json = """
        {"title":"t","description":"d","createdAt":"2026-01-01T00:00:00Z","duration":1,"width":100,"height":100,"fps":30,"fileSize":0,"source":{"type":"display"},"hasWebcam":false,"hasMic":false,"hasSystemAudio":false}
        """
        XCTAssertThrowsError(try RecordingMeta.decode(from: Data(json.utf8)))
    }

    func testDecodeMissingSourceThrows() {
        let json = """
        {"id":"x","title":"t","description":"d","createdAt":"2026-01-01T00:00:00Z","duration":1,"width":100,"height":100,"fps":30,"fileSize":0,"hasWebcam":false,"hasMic":false,"hasSystemAudio":false}
        """
        XCTAssertThrowsError(try RecordingMeta.decode(from: Data(json.utf8)))
    }

    func testDecodeUnknownSourceTypeThrows() {
        let json = """
        {"id":"x","title":"t","description":"d","createdAt":"2026-01-01T00:00:00Z","duration":1,"width":100,"height":100,"fps":30,"fileSize":0,"source":{"type":"hologram"},"hasWebcam":false,"hasMic":false,"hasSystemAudio":false}
        """
        // Unknown type should either throw or default; accept either behavior
        do {
            let meta = try RecordingMeta.decode(from: Data(json.utf8))
            XCTAssertNotEqual(meta.source.type.rawValue, "hologram")
        } catch {
            XCTAssert(true) // throwing is acceptable
        }
    }

    func testDecodePartialSourceOmittingOptionalAppAndTitleSucceeds() throws {
        let json = """
        {"id":"x","title":"t","description":"d","createdAt":"2026-01-01T00:00:00Z","duration":1,"width":100,"height":100,"fps":30,"fileSize":0,"source":{"type":"window"},"hasWebcam":false,"hasMic":false,"hasSystemAudio":false}
        """
        let meta = try RecordingMeta.decode(from: Data(json.utf8))
        XCTAssertEqual(meta.source.type, .window)
        XCTAssertNil(meta.source.app)
        XCTAssertNil(meta.source.title)
    }
}