import SwiftUI
import AppKit
import AVKit

/// Library grid matching the layout mock: 16:9 cards, min 240pt, 16pt spacing.
struct GalleryView: View {
    @Environment(RecordingStore.self) private var store

    @Binding var selection: RecordingEntry.ID?
    var filter: LibraryFilter
    @Binding var searchText: String
    var sort: SortKey

    enum SortKey: String, CaseIterable, Identifiable {
        case dateNewest, dateOldest, durationLongest, durationShortest

        var id: String { rawValue }

        var title: String {
            switch self {
            case .dateNewest: return "Newest first"
            case .dateOldest: return "Oldest first"
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
        case .all:
            break
        case .recents:
            let cutoff = Date().addingTimeInterval(-14 * 24 * 60 * 60)
            items = items.filter { $0.meta.createdAt >= cutoff }
        case .screen:
            items = items.filter { $0.meta.source.type == .display }
        case .window:
            items = items.filter { $0.meta.source.type == .window }
        case .region:
            items = items.filter { $0.meta.source.type == .region }
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

    private var totalBytes: Int64 {
        filtered.reduce(0) { $0 + $1.meta.fileSize }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)

            Group {
                if filtered.isEmpty {
                    ContentUnavailableView {
                        Label(emptyTitle, systemImage: "film.stack")
                    } description: {
                        Text(emptyDescription)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 240), spacing: 16)],
                            spacing: 16
                        ) {
                            ForEach(filtered) { entry in
                                GalleryThumbnailCell(
                                    entry: entry,
                                    isSelected: selection == entry.id
                                )
                                .onTapGesture(count: 2) { NSWorkspace.shared.open(entry.videoURL) }
                                .onTapGesture { selection = entry.id }
                                .contextMenu { contextMenu(for: entry) }
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 20)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(filter.title)
                .font(.title2.weight(.bold))
            Text("\(filtered.count) items · \(SpecreelTheme.fileSize(totalBytes))")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var emptyTitle: String {
        if !searchText.isEmpty { return "No Matches" }
        switch filter {
        case .recents: return "Nothing Recent"
        case .screen: return "No Screen Recordings"
        case .window: return "No Window Recordings"
        case .region: return "No Region Recordings"
        case .all: return "No Recordings"
        }
    }

    private var emptyDescription: String {
        if !searchText.isEmpty {
            return "No recordings match your search."
        }
        return "Click New Recording in the toolbar to capture your screen."
    }

    @ViewBuilder
    private func contextMenu(for entry: RecordingEntry) -> some View {
        ShareLink(item: entry.videoURL) {
            Text("Share…")
        }
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
            ZStack(alignment: .bottomLeading) {
                thumbnail
                    .frame(maxWidth: .infinity)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: SpecreelTheme.cardRadius, style: .continuous))

                Text(SpecreelTheme.duration(entry.meta.duration))
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(.white)
                    .padding(8)

                if entry.meta.hasWebcam {
                    Circle()
                        .fill(.black.opacity(0.35))
                        .frame(width: 36, height: 36)
                        .overlay(
                            Image(systemName: "person.fill")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(.white.opacity(0.9))
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(10)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: SpecreelTheme.cardRadius, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: isSelected ? 2 : 1)
            )

            Text(entry.meta.title.isEmpty ? "Untitled" : entry.meta.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)

            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var caption: String {
        let date = entry.meta.createdAt.formatted(.dateTime.day().month(.abbreviated))
        return "\(date) · \(SpecreelTheme.fileSize(entry.meta.fileSize))"
    }

    @ViewBuilder
    private var thumbnail: some View {
        // GeometryReader hands the image a concrete, bounded size before it fills —
        // without it, `.aspectRatio(contentMode: .fill)` reports its own oversized
        // ideal size upward through `.frame(maxWidth: .infinity)` uncapped, which is
        // what let an ultra-wide recording (e.g. 3440×1440) blow the card past the
        // grid column and off the left edge of the window.
        GeometryReader { geo in
            if let image = NSImage(contentsOf: entry.thumbnailURL) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
            } else {
                ZStack {
                    SpecreelTheme.canvas
                    Image(systemName: "film")
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
        }
    }
}
