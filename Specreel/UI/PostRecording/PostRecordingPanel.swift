import SwiftUI
import AppKit
import AVFoundation

// MARK: - SwiftUI content

/// Floating post-recording panel content (hosted in its own NSWindow).
struct PostRecordingPanel: View {
    let result: RecordingResult
    var onSave: (_ title: String, _ description: String, _ openAfter: Bool) -> Void
    var onDiscard: () -> Void

    @State private var title: String
    @State private var descriptionText: String = ""
    @State private var thumbnail: NSImage?
    @FocusState private var titleFocused: Bool

    init(
        result: RecordingResult,
        onSave: @escaping (_ title: String, _ description: String, _ openAfter: Bool) -> Void,
        onDiscard: @escaping () -> Void
    ) {
        self.result = result
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
                    .clipShape(RoundedRectangle(cornerRadius: SpecreelTheme.previewRadius, style: .continuous))

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

                Text(SpecreelTheme.duration(result.duration))
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
        .task { await loadThumbnail() }
    }

    /// Loads the sibling thumbnail if the engine wrote one, else generates one
    /// from the video off the main thread. Runs entirely inside this `Task`, so
    /// there's no shared mutable box and no risk of blocking the UI.
    private func loadThumbnail() async {
        if let sibling = Self.loadSiblingThumbnail(fileURL: result.fileURL) {
            thumbnail = sibling
            return
        }
        thumbnail = await Self.generateFallbackThumbnail(from: result.fileURL)
    }

    private static func loadSiblingThumbnail(fileURL: URL) -> NSImage? {
        let sibling = fileURL.deletingLastPathComponent().appendingPathComponent("thumbnail.jpg")
        return NSImage(contentsOf: sibling)
    }

    /// `copyCGImage` can hang on a file that never finished writing — race it
    /// against a timeout task instead of blocking a thread with a semaphore.
    private static func generateFallbackThumbnail(from fileURL: URL) async -> NSImage? {
        await withTaskGroup(of: NSImage?.self) { group in
            group.addTask {
                let asset = AVURLAsset(url: fileURL)
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 640, height: 360)
                let duration = asset.duration.seconds
                let target = max(0.1, duration * 0.1)
                let time = CMTime(seconds: target, preferredTimescale: 600)
                guard let cg = try? generator.copyCGImage(at: time, actualTime: nil) else { return nil }
                return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    private func commit(openAfter: Bool) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSave(trimmed, descriptionText, openAfter)
    }

    @ViewBuilder
    private var thumbnailView: some View {
        // GeometryReader hands the image a concrete, bounded size before it fills —
        // without it, `.aspectRatio(contentMode: .fill)` reports its own oversized
        // ideal size upward through `.frame(maxWidth: .infinity)` uncapped, which is
        // what let ultra-wide recordings (e.g. 3440×1440) blow the panel out sideways.
        GeometryReader { geo in
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
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

        let root = PostRecordingPanel(
            result: result,
            onSave: { [weak self] title, description, openAfter in
                self?.save(title: title, description: description, openAfter: openAfter)
            },
            onDiscard: { [weak self] in
                self?.discard()
            }
        )

        let hosting = NSHostingController(rootView: root)
        // Let AppKit track the SwiftUI content's real size instead of guessing
        // a fixed contentRect — a mismatch there (previously 460×520 vs the
        // view's actual ~420-wide intrinsic size) is what let content overflow
        // the window bounds, most visibly on non-standard display scales.
        hosting.sizingOptions = [.intrinsicContentSize]
        let panel = NSPanel(contentViewController: hosting)
        panel.styleMask = [.titled, .closable, .fullSizeContentView]
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

}

extension PostRecordingPanelController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        // Title-bar close ≡ Discard.
        if result != nil {
            discard()
        }
    }
}
