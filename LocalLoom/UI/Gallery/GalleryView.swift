import SwiftUI
import AppKit
import AVKit

/// Library grid: newest first, live updates via `RecordingStore`.
struct GalleryView: View {
    @Environment(RecordingStore.self) private var store

    @Binding var selection: RecordingEntry.ID?
    var filter: LibraryDestination
    @Binding var searchText: String
    var sort: SortKey

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

    @State private var confirmDelete: RecordingEntry?

    var filtered: [RecordingEntry] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var items = store.recordings
        switch filter {
        case .newRecording:
            break
        case .all:
            break
        case .recents:
            let cutoff = Date().addingTimeInterval(-14 * 24 * 60 * 60)
            items = items.filter { $0.meta.createdAt >= cutoff }
        case .camera:
            items = items.filter(\.meta.hasWebcam)
        }
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
        Group {
            if filtered.isEmpty {
                ContentUnavailableView {
                    Label(emptyTitle, systemImage: "film.stack")
                } description: {
                    Text(emptyDescription)
                }
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 220), spacing: 16)],
                        spacing: 18
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
                    .padding(20)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
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

    private var emptyTitle: String {
        if !searchText.isEmpty { return "No Matches" }
        switch filter {
        case .camera: return "No Camera Recordings"
        case .recents: return "Nothing Recent"
        default: return "No Recordings"
        }
    }

    private var emptyDescription: String {
        if !searchText.isEmpty {
            return "No recordings match your search."
        }
        switch filter {
        case .camera:
            return "Recordings that include the webcam will show up here."
        case .recents:
            return "Clips from the last 14 days will appear here."
        default:
            return "Start a recording from the menu bar or New Recording."
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
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                thumbnail
                    .frame(maxWidth: .infinity)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: LoomTheme.cardRadius, style: .continuous))

                if entry.meta.hasWebcam {
                    Circle()
                        .fill(Color.black.opacity(0.35))
                        .frame(width: 36, height: 36)
                        .overlay(
                            Image(systemName: "person.fill")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(.white.opacity(0.9))
                        )
                        .padding(10)
                }

                Text(LoomTheme.duration(entry.meta.duration))
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(.white)
                    .padding(8)
            }
            .overlay(
                RoundedRectangle(cornerRadius: LoomTheme.cardRadius, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : .black.opacity(0.06), lineWidth: isSelected ? 2 : 1)
            )

            Text(entry.meta.title.isEmpty ? "Untitled" : entry.meta.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)

            Text(entry.meta.createdAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(4)
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let image = NSImage(contentsOf: entry.thumbnailURL) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                LoomTheme.canvas
                Image(systemName: "film")
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
    }
}
