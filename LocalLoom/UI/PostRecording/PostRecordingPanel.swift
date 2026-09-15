import SwiftUI
import AppKit
import AVFoundation

// MARK: - SwiftUI content

/// Floating post-recording panel content (hosted in its own NSWindow).
struct PostRecordingPanel: View {
    let result: RecordingResult
    let thumbnail: NSImage?
    var onSave: (_ title: String, _ description: String) -> Void
    var onDiscard: () -> Void

    @State private var title: String
    @State private var descriptionText: String = ""
    @FocusState private var titleFocused: Bool

    init(
        result: RecordingResult,
        thumbnail: NSImage?,
        onSave: @escaping (_ title: String, _ description: String) -> Void,
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
        VStack(alignment: .leading, spacing: 16) {
            Text("Save Recording")
                .font(.title2.weight(.semibold))

            HStack(alignment: .top, spacing: 16) {
                thumbnailView
                    .frame(width: 200, height: 112)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(.quaternary)
                    )

                VStack(alignment: .leading, spacing: 6) {
                    metaRow("Duration", formatDuration(result.duration))
                    metaRow("Size", "\(result.width)×\(result.height)")
                    metaRow("FPS", "\(result.fps)")
                    metaRow("Source", result.sourceDescription)
                }
                .font(.caption)
            }

            TextField("Title", text: $title)
                .textFieldStyle(.roundedBorder)
                .focused($titleFocused)

            TextEditor(text: $descriptionText)
                .font(.body)
                .frame(minHeight: 72, maxHeight: 120)
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
                Button("Discard", role: .cancel) {
                    onDiscard()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Save") {
                    onSave(title.trimmingCharacters(in: .whitespacesAndNewlines), descriptionText)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear { titleFocused = true }
        .onExitCommand { onDiscard() }
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

    private func metaRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
        }
    }

    private func formatDuration(_ t: TimeInterval) -> String {
        let total = Int(t.rounded())
        let m = total / 60
        let s = total % 60
        if m >= 60 {
            let h = m / 60
            return String(format: "%d:%02d:%02d", h, m % 60, s)
        }
        return String(format: "%d:%02d", m, s)
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
            onSave: { [weak self] title, description in
                self?.save(title: title, description: description)
            },
            onDiscard: { [weak self] in
                self?.discard()
            }
        )

        let hosting = NSHostingController(rootView: root)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 380),
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

    private func save(title: String, description: String) {
        guard let result else { return }
        Task { @MainActor in
            do {
                try await store.save(RecordingSaveRequest(
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
        let asset = AVURLAsset(url: fileURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 360)
        // Prefer ~10% into the clip (M5 acceptance).
        let duration = asset.duration.seconds
        let target = max(0.1, duration * 0.1)
        let time = CMTime(seconds: target, preferredTimescale: 600)
        guard let cg = try? generator.copyCGImage(at: time, actualTime: nil) else {
            return nil
        }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

extension PostRecordingPanelController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        // Title-bar close ≡ Discard.
        if result != nil {
            discard()
        }
    }
}
