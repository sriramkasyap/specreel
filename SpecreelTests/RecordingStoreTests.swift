import Foundation
import XCTest
@testable import Specreel

/// RecordingStore persistence tests against an injected temp root (TRD section 1.3 / section 1.4 / section 7).
@MainActor
final class RecordingStoreTests: XCTestCase {

    private var tempRoot: URL!
    private var store: RecordingStore!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("SpecreelStoreTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        store = RecordingStore(rootURL: tempRoot)
    }

    override func tearDownWithError() throws {
        if let tempRoot, fileManager.fileExists(atPath: tempRoot.path) {
            try? fileManager.removeItem(at: tempRoot)
        }
        store = nil
        tempRoot = nil
    }

    private func makeMeta(
        id: String = "a3f9c1",
        title: String = "Take one",
        description: String = "desc"
    ) -> RecordingMeta {
        RecordingMeta(
            id: id,
            title: title,
            description: description,
            createdAt: Date(timeIntervalSince1970: 1_779_000_000),
            duration: 5.0,
            width: 1920,
            height: 1080,
            fps: 30,
            fileSize: 1024,
            source: .init(type: .display, app: nil, title: "Main"),
            hasWebcam: false,
            hasMic: true,
            hasSystemAudio: true
        )
    }

    private func writeTempMedia(named name: String = "clip.mp4") throws -> URL {
        let url = tempRoot.appendingPathComponent("scratch-\(UUID().uuidString)-\(name)")
        let bytes = Data("fake-mp4-bytes".utf8)
        try bytes.write(to: url)
        return url
    }

    // MARK: - Scan

    func testScanEmptyRootReturnsEmptyList() {
        store.scan()
        XCTAssertTrue(store.recordings.isEmpty)
    }

    func testScanFindsSavedRecording() async throws {
        let req = RecordingSaveRequest(
            tempVideoURL: try writeTempMedia(),
            meta: makeMeta(id: "scan01")
        )
        try await store.save(req)
        store.scan()
        XCTAssertEqual(store.recordings.count, 1)
        XCTAssertEqual(store.recordings.first?.meta.id, "scan01")
    }

    func testScanSkipsIncompleteFoldersMissingMeta() throws {
        let orphan = tempRoot.appendingPathComponent("2026-09-15-120000-orphan", isDirectory: true)
        try fileManager.createDirectory(at: orphan, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: orphan.appendingPathComponent("recording.mp4"))
        store.scan()
        XCTAssertTrue(store.recordings.isEmpty)
    }

    func testScanReturnsMultipleRecordings() async throws {
        try await store.save(RecordingSaveRequest(tempVideoURL: try writeTempMedia(), meta: makeMeta(id: "aaa111", title: "A")))
        try await store.save(RecordingSaveRequest(tempVideoURL: try writeTempMedia(), meta: makeMeta(id: "bbb222", title: "B")))
        store.scan()
        let ids = store.recordings.map(\.meta.id).sorted()
        XCTAssertEqual(ids, ["aaa111", "bbb222"])
    }

    // MARK: - Save

    func testSaveWritesFiles() async throws {
        let meta = makeMeta(id: "save01")
        try await store.save(RecordingSaveRequest(tempVideoURL: try writeTempMedia(), meta: meta))
        store.scan()
        guard let entry = store.recordings.first(where: { $0.meta.id == "save01" }) else {
            XCTFail("Recording not found")
            return
        }
        XCTAssertTrue(fileManager.fileExists(atPath: entry.videoURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: entry.metaURL.path))
    }

    // MARK: - Update

    func testUpdateMetaInPlace() async throws {
        try await store.save(RecordingSaveRequest(tempVideoURL: try writeTempMedia(), meta: makeMeta(id: "upd01", title: "Old")))
        store.scan()
        try store.updateMeta(id: "upd01", title: "New title", description: "edited")
        store.scan()
        XCTAssertEqual(store.recordings.first?.meta.title, "New title")
    }

    // MARK: - Delete

    func testDeleteRemovesFromListing() async throws {
        try await store.save(RecordingSaveRequest(tempVideoURL: try writeTempMedia(), meta: makeMeta(id: "del01")))
        store.scan()
        XCTAssertEqual(store.recordings.count, 1)
        try store.delete(id: "del01")
        store.scan()
        XCTAssertTrue(store.recordings.isEmpty)
    }

    func testDeleteUnknownIdThrows() {
        XCTAssertThrowsError(try store.delete(id: "no-such-id"))
    }
}