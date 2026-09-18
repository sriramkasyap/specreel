import SwiftUI
import AppKit
import AVFoundation

// MARK: - SwiftUI content

/// Floating post-recording panel content (hosted in its own NSWindow).
struct PostRecordingPanel: View {
    let result: RecordingResult
    let thumbnail: NSImage?
    var onSave: (_ title: String, _ description: String, _ openAfter: Bool) -> Void
    var onDiscard: () -> Void

    @State private var title: String
    @State private var descriptionText: String = ""
    @FocusState private var titleFocused: Bool

    init(
        result: RecordingResult,
        thumbnail: NSImage?,
        onSave: @escaping (_ title: String, _ description: String, _ openAfter: Bool) -> Void,
        onDiscard: @escaping () -> Void
    ) {
        self.result = result
        self.thumbnail = thumbnail
        self.onSave = onSave
        self.onDiscard = onDiscard
        _title = State(initialValue: Self.inferredTitle(from: result))
    }

    /// Build a sensible default title from the capture source + timestamp.
    private static func inferredTitle(from result: RecordingResult) -> String {
        let base = result.sourceDescription
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return "\(base) — \(formatter.string(from: Date()))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Save recording")
                .font(.title3.weight(.semibold))

            ZStack(alignment: .bottomTrailing) {
                thumbnailView
                    .frame(maxWidth: .infinity)
                    .frame(height: 180)
                    .clipShape(RoundedRectangle(cornerRadius: LoomTheme.previewRadius, style: .continuous))

                if result.hasWebcam {
                    Circle()
                        .fill(Color.black.opacity(0.4))
                        .frame(width: 56, height: 56)
                        .overlay(
                            Image(systemName: "person.fill")
                                .foregroundStyle(.white.opacity(0.9))
                        )
                        .padding(12)
                }

                Text(LoomTheme.duration(result.duration))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(.white)
                    .padding(10)
            }

            Text("\(result.width) × \(result.height) · \(result.fps) fps")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                if result.hasWebcam { Text("Camera") }
                if result.hasMic { Text("Microphone") }
                if result.hasSystemAudio { Text("System audio") }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            TextField("Title", text: $title)
                .textFieldStyle(.roundedBorder)
                .focused($titleFocused)

            TextEditor(text: $descriptionText)
                .font(.body)
                .frame(minHeight: 64, maxHeight: 96)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(.quaternary)
                )
                .overlay(alignment: .topLeading) {
                    if descriptionText.isEmpty {
                        Text("Description (optional)")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                }

            HStack {
                Button("Discard", role: .destructive) {
                    onDiscard()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Save & Open") {
                    commit(openAfter: true)
                }
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button("Save") {
                    commit(openAfter: false)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 420)
        .onAppear { titleFocused = true }
        .onExitCommand { onDiscard() }
    }

    private func commit(openAfter: Bool) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSave(trimmed, descriptionText, openAfter)
    }

    @ViewBuilder
    private var thumbnailView: some View {
        if let thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                Color.secondary.opacity(0.15)
                Image(systemName: "film")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
            }
        }
    }

}

// MARK: - Own floating NSWindow (never a sheet on MainWindow)

@MainActor
final class PostRecordingPanelController: NSObject {
    private let store: RecordingStore
    private var window: NSWindow?
    private var onDismiss: (() -> Void)?
    private var result: RecordingResult?

    init(store: RecordingStore) {
        self.store = store
        super.init()
    }

    func present(result: RecordingResult, onDismiss: @escaping () -> Void) {
        self.result = result
        self.onDismiss = onDismiss

        let thumbnail = loadThumbnail(from: result.fileURL)
            ?? generateFallbackThumbnail(from: result.fileURL)

        let root = PostRecordingPanel(
            result: result,
            thumbnail: thumbnail,
            onSave: { [weak self] title, description, openAfter in
                self?.save(title: title, description: description, openAfter: openAfter)
            },
            onDiscard: { [weak self] in
                self?.discard()
            }
        )

        let hosting = NSHostingController(rootView: root)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 520),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Save Recording"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // Trap #8 / M7: never appear inside the screen recording.
        panel.sharingType = .none
        panel.contentViewController = hosting
        panel.center()
        panel.delegate = self

        window = panel
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func save(title: String, description: String, openAfter: Bool) {
        guard let result else { return }
        Task { @MainActor in
            do {
                let entry = try await store.save(RecordingSaveRequest(
                tempVideoURL: result.fileURL,
                meta: RecordingMeta(
                    id: RecordingStore.makeRecordingID(),
                    title: title,
                    description: description,
                    createdAt: Date(),
                    duration: result.duration,
                    width: result.width,
                    height: result.height,
                    fps: result.fps,
                    fileSize: 0,
                    source: RecordingMeta.Source(type: .display, app: nil, title: nil),
                    hasWebcam: result.hasWebcam,
                    hasMic: result.hasMic,
                    hasSystemAudio: result.hasSystemAudio
                )
            ))
            if openAfter {
                try? store.revealInFinder(id: entry.id)
                NSWorkspace.shared.open(entry.videoURL)
            }
            closeAndDismiss()
            } catch {
                let alert = NSAlert(error: error)
                alert.runModal()
            }
        }
    }

    private func discard() {
        guard let result else {
            closeAndDismiss()
            return
        }
        try? FileManager.default.removeItem(at: result.fileURL)
        // Also drop sibling thumbnail if engine wrote one next to the temp mp4.
        let thumb = result.fileURL.deletingLastPathComponent()
            .appendingPathComponent("thumbnail.jpg")
        try? FileManager.default.removeItem(at: thumb)
        closeAndDismiss()
    }

    private func closeAndDismiss() {
        window?.delegate = nil
        window?.close()
        window = nil
        let done = onDismiss
        onDismiss = nil
        result = nil
        done?()
    }

    private func loadThumbnail(from fileURL: URL) -> NSImage? {
        let sibling = fileURL.deletingLastPathComponent()
            .appendingPathComponent("thumbnail.jpg")
        if let img = NSImage(contentsOf: sibling) { return img }
        return nil
    }

    private func generateFallbackThumbnail(from fileURL: URL) -> NSImage? {
        let box = ThumbnailBox()
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            defer { sem.signal() }
            let asset = AVURLAsset(url: fileURL)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 640, height: 360)
            let duration = asset.duration.seconds
            let target = max(0.1, duration * 0.1)
            let time = CMTime(seconds: target, preferredTimescale: 600)
            guard let cg = try? generator.copyCGImage(at: time, actualTime: nil) else { return }
            box.image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }
        // copyCGImage can hang on a file that never finished writing.
        _ = sem.wait(timeout: .now() + 1.5)
        return box.image
    }
}

private final class ThumbnailBox: @unchecked Sendable {
    var image: NSImage?
}

extension PostRecordingPanelController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        // Title-bar close ≡ Discard.
        if result != nil {
            discard()
        }
    }
}
