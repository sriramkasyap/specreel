import SwiftUI
import AppKit
import AVKit

/// Right-hand inspector for a selected library clip.
struct RecordingInspector: View {
    @Environment(RecordingStore.self) private var store
    let entry: RecordingEntry

    @State private var title: String = ""
    @State private var descriptionText: String = ""
    @State private var player: AVPlayer?
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            preview
                .padding(16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    TextField("Title", text: $title)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { persistMeta() }

                    TextEditor(text: $descriptionText)
                        .font(.body)
                        .frame(minHeight: 72, maxHeight: 120)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(.quaternary)
                        )
                        .overlay(alignment: .topLeading) {
                            if descriptionText.isEmpty {
                                Text("Description")
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 8)
                                    .allowsHitTesting(false)
                            }
                        }

                    metaBlock

                    HStack(spacing: 8) {
                        Button("Reveal") { try? store.revealInFinder(id: entry.id) }
                        Button("Copy Path") { try? store.copyPath(id: entry.id) }
                        Spacer()
                        Button("Trash", role: .destructive) { confirmDelete = true }
                    }
                    .controlSize(.small)
                }
                .padding(16)
            }
        }
        .background(LoomTheme.inspectorBackground)
        .onAppear { load(entry) }
        .onChange(of: entry.id) { _, _ in
            player?.pause()
            load(entry)
        }
        .onDisappear {
            player?.pause()
            persistMeta()
        }
        .confirmationDialog(
            "Move this recording to Trash?",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                try? store.delete(id: entry.id)
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var preview: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
                    .frame(minHeight: 160)
                    .clipShape(RoundedRectangle(cornerRadius: LoomTheme.cardRadius, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: LoomTheme.cardRadius, style: .continuous)
                    .fill(LoomTheme.canvas)
                    .frame(minHeight: 160)
                    .overlay { ProgressView().tint(.white) }
            }
        }
    }

    private var metaBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            metaRow("Duration", LoomTheme.duration(entry.meta.duration))
            metaRow("Size", "\(entry.meta.width)×\(entry.meta.height)")
            metaRow("FPS", "\(entry.meta.fps)")
            metaRow("File", LoomTheme.fileSize(entry.meta.fileSize))
            metaRow("Source", sourceLabel)
            HStack(spacing: 6) {
                if entry.meta.hasWebcam { chip("Camera") }
                if entry.meta.hasMic { chip("Mic") }
                if entry.meta.hasSystemAudio { chip("System") }
            }
        }
        .font(.caption)
    }

    private var sourceLabel: String {
        switch entry.meta.source.type {
        case .display: return entry.meta.source.title ?? "Display"
        case .window:
            let app = entry.meta.source.app ?? "Window"
            if let title = entry.meta.source.title, !title.isEmpty {
                return "\(app) — \(title)"
            }
            return app
        case .region: return entry.meta.source.title ?? "Region"
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

    private func chip(_ title: String) -> some View {
        Text(title)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.quaternary.opacity(0.5), in: Capsule())
    }

    private func load(_ entry: RecordingEntry) {
        title = entry.meta.title
        descriptionText = entry.meta.description
        player = AVPlayer(url: entry.videoURL)
    }

    private func persistMeta() {
        _ = try? store.updateMeta(
            id: entry.id,
            title: title,
            description: descriptionText
        )
    }
}

struct EmptyInspector: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "play.rectangle")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
            Text("Select a recording")
                .font(.headline)
            Text("Choose a clip from the gallery to play and edit details.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LoomTheme.inspectorBackground)
    }
}
