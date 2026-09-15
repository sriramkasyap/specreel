import SwiftUI
import AppKit
import AVKit

/// Library grid: newest first, live updates via `RecordingStore`, inline playback,
/// title/description write-through to meta.json (never folder rename).
struct GalleryView: View {
    @Environment(RecordingStore.self) private var store

    @State private var searchText = ""
    @State private var sort: SortKey = .dateNewest
    @State private var selection: RecordingEntry.ID?
    @State private var confirmDelete: RecordingEntry?

    enum SortKey: String, CaseIterable, Identifiable {
        case dateNewest, dateOldest, durationLongest, durationShortest

        var id: String { rawValue }

        var title: String {
            switch self {
            case .dateNewest: return "Newest"
            case .dateOldest: return "Oldest"
            case .durationLongest: return "Longest"
            case .durationShortest: return "Shortest"
            }
        }
    }

    private var filtered: [RecordingEntry] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var items = store.recordings
        if !q.isEmpty {
            items = items.filter {
                $0.meta.title.lowercased().contains(q)
                    || $0.meta.description.lowercased().contains(q)
            }
        }
        switch sort {
        case .dateNewest:       items.sort { $0.meta.createdAt > $1.meta.createdAt }
        case .dateOldest:       items.sort { $0.meta.createdAt < $1.meta.createdAt }
        case .durationLongest:  items.sort { $0.meta.duration > $1.meta.duration }
        case .durationShortest: items.sort { $0.meta.duration < $1.meta.duration }
        }
        return items
    }

    var body: some View {
        HSplitView {
            libraryColumn
                .frame(minWidth: 320)

            detailColumn
                .frame(minWidth: 360)
        }
        .navigationTitle("Recordings")
        .searchable(text: $searchText, prompt: "Search title or description")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Picker("Sort", selection: $sort) {
                    ForEach(SortKey.allCases) { key in
                        Text(key.title).tag(key)
                    }
                }
                .pickerStyle(.menu)
            }
        }
        .confirmationDialog(
            "Move this recording to Trash?",
            isPresented: Binding(
                get: { confirmDelete != nil },
                set: { if !$0 { confirmDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                if let entry = confirmDelete {
                    try? store.delete(id: entry.id)
                    if selection == entry.id { selection = nil }
                }
                confirmDelete = nil
            }
            Button("Cancel", role: .cancel) {
                confirmDelete = nil
            }
        }
        .task {
            store.scan()
        }
    }

    // MARK: - Library

    private var libraryColumn: some View {
        Group {
            if filtered.isEmpty {
                ContentUnavailableView {
                    Label("No Recordings", systemImage: "film.stack")
                } description: {
                    Text(
                        searchText.isEmpty
                            ? "Record from the menu bar to get started."
                            : "No recordings match your search."
                    )
                }
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 160), spacing: 12)],
                        spacing: 12
                    ) {
                        ForEach(filtered) { entry in
                            GalleryThumbnailCell(
                                entry: entry,
                                isSelected: selection == entry.id
                            )
                            .onTapGesture { selection = entry.id }
                            .contextMenu { contextMenu(for: entry) }
                        }
                    }
                    .padding()
                }
            }
        }
    }

    // MARK: - Detail / playback

    @ViewBuilder
    private var detailColumn: some View {
        if let entry = store.recordings.first(where: { $0.id == selection })
            ?? filtered.first
        {
            GalleryDetailView(entry: entry)
                .id(entry.id)
        } else {
            ContentUnavailableView(
                "Select a Recording",
                systemImage: "play.rectangle",
                description: Text("Choose a clip from the gallery to play and edit.")
            )
        }
    }

    @ViewBuilder
    private func contextMenu(for entry: RecordingEntry) -> some View {
        Button("Reveal in Finder") {
            try? store.revealInFinder(id: entry.id)
        }
        Button("Copy Path") {
            try? store.copyPath(id: entry.id)
        }
        Divider()
        Button("Move to Trash", role: .destructive) {
            confirmDelete = entry
        }
    }
}

// MARK: - Thumbnail cell

private struct GalleryThumbnailCell: View {
    let entry: RecordingEntry
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                thumbnail
                    .frame(maxWidth: .infinity)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
                    )

                Text(formatDuration(entry.meta.duration))
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(.white)
                    .padding(6)
            }

            Text(entry.meta.title.isEmpty ? "Untitled" : entry.meta.title)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)

            Text(entry.meta.createdAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(6)
        .background(isSelected ? Color.accentColor.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let image = NSImage(contentsOf: entry.thumbnailURL) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                Color.secondary.opacity(0.12)
                Image(systemName: "film")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func formatDuration(_ t: TimeInterval) -> String {
        let total = Int(t.rounded())
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - Detail + inline player + editable meta

private struct GalleryDetailView: View {
    @Environment(RecordingStore.self) private var store
    let entry: RecordingEntry

    @State private var title: String = ""
    @State private var descriptionText: String = ""
    @State private var player: AVPlayer?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let player {
                VideoPlayer(player: player)
                    .frame(minHeight: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.12))
                    .frame(minHeight: 240)
                    .overlay {
                        ProgressView()
                    }
            }

            TextField("Title", text: $title)
                .textFieldStyle(.roundedBorder)
                .onSubmit { persistMeta() }

            TextEditor(text: $descriptionText)
                .font(.body)
                .frame(minHeight: 64, maxHeight: 120)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(.quaternary)
                )

            HStack {
                Button("Save Details") { persistMeta() }
                    .keyboardShortcut("s", modifiers: .command)

                Spacer()

                Button("Reveal in Finder") { try? store.revealInFinder(id: entry.id) }
                Button("Copy Path") { try? store.copyPath(id: entry.id) }
            }

            Spacer(minLength: 0)
        }
        .padding()
        .onAppear {
            title = entry.meta.title
            descriptionText = entry.meta.description
            player = AVPlayer(url: entry.videoURL)
        }
        .onChange(of: entry.id) { _, _ in
            player?.pause()
            title = entry.meta.title
            descriptionText = entry.meta.description
            player = AVPlayer(url: entry.videoURL)
        }
        .onDisappear {
            player?.pause()
            persistMeta()
        }
    }

    private func persistMeta() {
        try? store.updateMeta(
            id: entry.id,
            title: title,
            description: descriptionText
        )
    }
}