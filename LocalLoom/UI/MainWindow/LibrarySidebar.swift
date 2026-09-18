import SwiftUI

enum LibraryFilter: Hashable, Identifiable {
    case all
    case recents
    case screen
    case window
    case region

    var id: String {
        switch self {
        case .all: return "all"
        case .recents: return "recents"
        case .screen: return "screen"
        case .window: return "window"
        case .region: return "region"
        }
    }

    var title: String {
        switch self {
        case .all: return "All Recordings"
        case .recents: return "Recent"
        case .screen: return "Screen"
        case .window: return "Window"
        case .region: return "Region"
        }
    }

    var systemImage: String {
        switch self {
        case .all: return "film.stack"
        case .recents: return "clock"
        case .screen: return "display"
        case .window: return "macwindow"
        case .region: return "rectangle.dashed"
        }
    }
}

/// 200pt sidebar from the layout mock: Library + Source, with counts.
struct LibrarySidebar: View {
    @Environment(RecordingStore.self) private var store
    @Binding var filter: LibraryFilter
    var onSelectFilter: () -> Void

    var body: some View {
        List(selection: $filter) {
            Section("Library") {
                sidebarRow(.all, badge: store.recordings.count)
                sidebarRow(.recents, badge: nil)
            }
            Section("Source") {
                sidebarRow(.screen, badge: count(for: .display))
                sidebarRow(.window, badge: count(for: .window))
                sidebarRow(.region, badge: count(for: .region))
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .onChange(of: filter) { _, _ in
            onSelectFilter()
        }
    }

    private func sidebarRow(_ filter: LibraryFilter, badge: Int?) -> some View {
        HStack {
            Label(filter.title, systemImage: filter.systemImage)
            Spacer()
            if let badge {
                Text("\(badge)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .tag(filter)
        .contentShape(Rectangle())
    }

    private func count(for type: RecordingMeta.SourceType) -> Int {
        store.recordings.filter { $0.meta.source.type == type }.count
    }
}
