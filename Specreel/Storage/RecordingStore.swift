import AppKit
import AVFoundation
import Combine
import Foundation
import Security

/// One library entry: folder URL + decoded `meta.json`.
public struct RecordingEntry: Identifiable, Hashable, Sendable {
    public var id: String { meta.id }
    public let folderURL: URL
    public var meta: RecordingMeta

    public var videoURL: URL {
        folderURL.appendingPathComponent(RecordingStore.videoFileName)
    }

    public var thumbnailURL: URL {
        folderURL.appendingPathComponent(RecordingStore.thumbnailFileName)
    }

    public var metaURL: URL {
        folderURL.appendingPathComponent(RecordingStore.metaFileName)
    }

    public init(folderURL: URL, meta: RecordingMeta) {
        self.folderURL = folderURL
        self.meta = meta
    }
}

/// Inputs required to persist a finished recording into the library.
public struct RecordingSaveRequest: Sendable {
    public var tempVideoURL: URL
    public var meta: RecordingMeta

    public init(tempVideoURL: URL, meta: RecordingMeta) {
        self.tempVideoURL = tempVideoURL
        self.meta = meta
    }
}

/// Folder-per-recording library under an injectable root
/// (default `~/Movies/Specreel/`). Notifies observers on every mutation so
/// `GalleryView` updates live without relaunch.
@MainActor
@Observable
public final class RecordingStore {

    public static let videoFileName = "recording.mp4"
    public static let thumbnailFileName = "thumbnail.jpg"
    public static let metaFileName = "meta.json"

    /// Default library root: `~/Movies/Specreel/`.
    public static var defaultRootURL: URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Movies")
        return movies.appendingPathComponent("Specreel", isDirectory: true)
    }

    public let rootURL: URL

    /// Current library listing, newest-first by `createdAt`.
    public private(set) var recordings: [RecordingEntry] = []

    /// Fires after any scan / save / update / delete that changes the library.
    public let libraryDidChange = PassthroughSubject<Void, Never>()

    private let fileManager: FileManager

    public init(rootURL: URL = RecordingStore.defaultRootURL, fileManager: FileManager = .default) {
        self.rootURL = rootURL
        self.fileManager = fileManager
    }

    // MARK: - Scan

    /// Rescan the library root and publish results.
    @discardableResult
    public func scan() -> [RecordingEntry] {
        ensureRootExists()

        let contents: [URL]
        do {
            contents = try fileManager.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            recordings = []
            notifyChange()
            return []
        }

        var entries: [RecordingEntry] = []
        for folder in contents {
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            let metaURL = folder.appendingPathComponent(Self.metaFileName)
            guard fileManager.fileExists(atPath: metaURL.path) else { continue }
            do {
                let meta = try RecordingMeta.load(from: metaURL)
                entries.append(RecordingEntry(folderURL: folder, meta: meta))
            } catch {
                // Skip malformed folders; gallery stays usable.
                continue
            }
        }

        entries.sort { $0.meta.createdAt > $1.meta.createdAt }
        recordings = entries
        notifyChange()
        return entries
    }

    // MARK: - Save

    /// Writes `recording.mp4`, `thumbnail.jpg`, and `meta.json` into a new
    /// folder named `<yyyy-MM-dd-HHmmss>-<id>/`. Moves (or copies) the temp
    /// video into place, generates a thumbnail from ~10% into the video, and
    /// refreshes the published listing.
    @discardableResult
    public func save(_ request: RecordingSaveRequest) async throws -> RecordingEntry {
        ensureRootExists()

        var meta = request.meta
        if meta.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            meta.id = Self.makeRecordingID()
        }

        let folderName = Self.folderName(for: meta)
        let folderURL = rootURL.appendingPathComponent(folderName, isDirectory: true)

        if fileManager.fileExists(atPath: folderURL.path) {
            throw StoreError.folderAlreadyExists(folderURL)
        }

        try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)

        let videoURL = folderURL.appendingPathComponent(Self.videoFileName)
        let thumbnailURL = folderURL.appendingPathComponent(Self.thumbnailFileName)
        let metaURL = folderURL.appendingPathComponent(Self.metaFileName)

        do {
            try moveOrCopy(from: request.tempVideoURL, to: videoURL)

            if meta.fileSize <= 0 {
                meta.fileSize = fileSize(of: videoURL)
            }

            // Thumbnail generation is best-effort — non-fatal on failure (test data may lack real video content).
            do {
                try await generateThumbnail(from: videoURL, to: thumbnailURL, duration: meta.duration)
            } catch {
                // Thumbnail missing is acceptable; recording is still saved.
            }

            let data = try meta.encodeData(prettyPrinted: true)
            try data.write(to: metaURL, options: .atomic)

            let entry = RecordingEntry(folderURL: folderURL, meta: meta)
            // Insert / refresh listing without requiring a full relaunch.
            if let idx = recordings.firstIndex(where: { $0.id == entry.id }) {
                recordings[idx] = entry
            } else {
                recordings.insert(entry, at: 0)
            }
            recordings.sort { $0.meta.createdAt > $1.meta.createdAt }
            notifyChange()
            return entry
        } catch {
            // Best-effort cleanup of a partial folder.
            try? fileManager.removeItem(at: folderURL)
            throw error
        }
    }

    // MARK: - Update meta (title / description only)

    /// Updates `title` and/or `description` in `meta.json`. Never renames the folder.
    @discardableResult
    public func updateMeta(
        id: String,
        title: String? = nil,
        description: String? = nil
    ) throws -> RecordingEntry {
        guard let index = recordings.firstIndex(where: { $0.id == id }) else {
            throw StoreError.recordingNotFound(id)
        }
        var entry = recordings[index]
        if let title { entry.meta.title = title }
        if let description { entry.meta.description = description }

        let data = try entry.meta.encodeData(prettyPrinted: true)
        try data.write(to: entry.metaURL, options: .atomic)

        recordings[index] = entry
        notifyChange()
        return entry
    }

    // MARK: - Delete (Trash)

    /// Moves the recording folder to Trash via `FileManager.trashItem`.
    public func delete(id: String) throws {
        guard let index = recordings.firstIndex(where: { $0.id == id }) else {
            throw StoreError.recordingNotFound(id)
        }
        let entry = recordings[index]
        var resultingURL: NSURL?
        try fileManager.trashItem(at: entry.folderURL, resultingItemURL: &resultingURL)
        recordings.remove(at: index)
        notifyChange()
    }

    // MARK: - Finder / pasteboard

    /// Reveals the recording folder in Finder.
    public func revealInFinder(id: String) throws {
        let entry = try entry(id: id)
        NSWorkspace.shared.activateFileViewerSelecting([entry.folderURL])
    }

    /// Copies the recording folder path to the general pasteboard.
    public func copyPath(id: String) throws {
        let entry = try entry(id: id)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(entry.folderURL.path, forType: .string)
    }

    /// Looks up a loaded entry by id.
    public func entry(id: String) throws -> RecordingEntry {
        guard let entry = recordings.first(where: { $0.id == id }) else {
            throw StoreError.recordingNotFound(id)
        }
        return entry
    }

    // MARK: - Folder naming / IDs

    /// `yyyy-MM-dd-HHmmss-<id>`
    public static func folderName(for meta: RecordingMeta) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return "\(formatter.string(from: meta.createdAt))-\(meta.id)"
    }

    /// Six hex characters, matching the TRD example (`a3f9c1`).
    public static func makeRecordingID() -> String {
        var bytes = [UInt8](repeating: 0, count: 3)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status == errSecSuccess {
            return bytes.map { String(format: "%02x", $0) }.joined()
        }
        return String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(6)).lowercased()
    }

    // MARK: - Thumbnail (~10% into video)

    /// Extracts a JPEG frame from ~10% into the video (never the first frame).
    public static func generateThumbnail(
        from videoURL: URL,
        to destinationURL: URL,
        duration hintedDuration: Double = 0
    ) async throws {
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 720)

        let total: Double
        if hintedDuration > 0 {
            total = hintedDuration
        } else {
            let assetDuration = try await asset.load(.duration)
            total = CMTimeGetSeconds(assetDuration)
        }

        // ~10% in; clamp away from 0 so idle/black first frames are avoided.
        let fraction = 0.10
        var seconds = max(total * fraction, 0.1)
        if total > 0 {
            seconds = min(seconds, max(total - 0.05, 0.1))
        }
        let time = CMTime(seconds: seconds, preferredTimescale: 600)

        let cgImage: CGImage
        if #available(macOS 13.0, *) {
            let result = try await generator.image(at: time)
            cgImage = result.image
        } else {
            var actual = CMTime.zero
            cgImage = try generator.copyCGImage(at: time, actualTime: &actual)
        }

        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.82]) else {
            throw StoreError.thumbnailEncodingFailed
        }
        try jpeg.write(to: destinationURL, options: .atomic)
    }

    // MARK: - Internals

    private func ensureRootExists() {
        if !fileManager.fileExists(atPath: rootURL.path) {
            try? fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        }
    }

    private func moveOrCopy(from source: URL, to destination: URL) throws {
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        do {
            try fileManager.moveItem(at: source, to: destination)
        } catch {
            // Cross-volume move falls back to copy + remove.
            try fileManager.copyItem(at: source, to: destination)
            try? fileManager.removeItem(at: source)
        }
    }

    private func fileSize(of url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        if let size = values?.fileSize {
            return Int64(size)
        }
        return 0
    }

    private func notifyChange() {
        libraryDidChange.send(())
    }

    public enum StoreError: Error, LocalizedError, Sendable {
        case folderAlreadyExists(URL)
        case recordingNotFound(String)
        case thumbnailEncodingFailed
        case thumbnailGenerationFailed(String)

        public var errorDescription: String? {
            switch self {
            case .folderAlreadyExists(let url):
                return "Recording folder already exists: \(url.lastPathComponent)"
            case .recordingNotFound(let id):
                return "Recording not found: \(id)"
            case .thumbnailEncodingFailed:
                return "Failed to encode thumbnail JPEG"
            case .thumbnailGenerationFailed(let detail):
                return "Failed to generate thumbnail: \(detail)"
            }
        }
    }
}

// Instance convenience matching the static thumbnail API.
public extension RecordingStore {
    func generateThumbnail(
        from videoURL: URL,
        to destinationURL: URL,
        duration: Double
    ) async throws {
        try await Self.generateThumbnail(from: videoURL, to: destinationURL, duration: duration)
    }
}
