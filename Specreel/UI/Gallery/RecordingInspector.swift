import SwiftUI
import AppKit
import AVKit

/// 320pt inspector from the layout mock. Hidden by the parent when nothing is selected.
struct RecordingInspector: View {
    @Environment(RecordingStore.self) private var store
    let entry: RecordingEntry

    @State private var title: String = ""
    @State private var descriptionText: String = ""
    @State private var player: AVPlayer?
    @State private var confirmDelete = false
    @FocusState private var titleFocused: Bool
    @FocusState private var descriptionFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            preview
                .padding(16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("Title", text: $title)
                        .textFieldStyle(.roundedBorder)
                        .focused($titleFocused)
                        .onSubmit { persistMeta(id: entry.id) }

                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $descriptionText)
                            .font(.body)
                            .focused($descriptionFocused)
                            .frame(minHeight: 72, maxHeight: 120)
                        if descriptionText.isEmpty {
                            Text("Description")
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 8)
                                .allowsHitTesting(false)
                        }
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(.quaternary)
                    )

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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .controlBackgroundColor))
        .onAppear { load(entry) }
        .onChange(of: entry.id) { oldID, _ in
            // Persist under the *old* id before loading the new entry's text —
            // `entry` itself already points at the new selection here, so using
            // entry.id would write the previous recording's unsaved edits onto
            // whatever is newly selected.
            player?.pause()
            persistMeta(id: oldID)
            load(entry)
        }
        .onChange(of: titleFocused) { _, focused in
            if !focused { persistMeta(id: entry.id) }
        }
        .onChange(of: descriptionFocused) { _, focused in
            if !focused { persistMeta(id: entry.id) }
        }
        .onDisappear {
            player?.pause()
            persistMeta(id: entry.id)
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
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: SpecreelTheme.cardRadius, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: SpecreelTheme.cardRadius, style: .continuous)
                    .fill(SpecreelTheme.canvas)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .overlay { ProgressView().tint(.white) }
            }
        }
    }

    private var metaBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            metaRow("Recorded", entry.meta.createdAt.formatted(date: .abbreviated, time: .shortened))
            metaRow("Duration", SpecreelTheme.duration(entry.meta.duration))
            metaRow("Resolution", "\(entry.meta.width) × \(entry.meta.height)")
            metaRow("Size", SpecreelTheme.fileSize(entry.meta.fileSize))
            metaRow("Source", sourceLabel)
            metaRow("Audio", audioLabel)
        }
        .font(.caption)
    }

    private var sourceLabel: String {
        switch entry.meta.source.type {
        case .display:
            return entry.meta.source.title.map { "Screen · \($0)" } ?? "Screen"
        case .window:
            let app = entry.meta.source.app ?? "Window"
            if let title = entry.meta.source.title, !title.isEmpty {
                return "Window · \(title)"
            }
            return "Window · \(app)"
        case .region:
            return "Region"
        }
    }

    private var audioLabel: String {
        var parts: [String] = []
        if entry.meta.hasMic { parts.append("Mic") }
        if entry.meta.hasSystemAudio { parts.append("System") }
        return parts.isEmpty ? "None" : parts.joined(separator: " · ")
    }

    private func metaRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 78, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func load(_ entry: RecordingEntry) {
        title = entry.meta.title
        descriptionText = entry.meta.description
        player = AVPlayer(url: entry.videoURL)
    }

    private func persistMeta(id: RecordingEntry.ID) {
        _ = try? store.updateMeta(
            id: id,
            title: title,
            description: descriptionText
        )
    }
}
