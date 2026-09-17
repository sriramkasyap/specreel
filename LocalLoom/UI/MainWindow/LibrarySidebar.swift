import SwiftUI

enum LibraryDestination: Hashable, Identifiable {
    case newRecording
    case all
    case recents
    case camera

    var id: String {
        switch self {
        case .newRecording: return "new"
        case .all: return "all"
        case .recents: return "recents"
        case .camera: return "camera"
        }
    }

    var title: String {
        switch self {
        case .newRecording: return "New Recording"
        case .all: return "All Recordings"
        case .recents: return "Recents"
        case .camera: return "Camera"
        }
    }

    var systemImage: String {
        switch self {
        case .newRecording: return "plus.rectangle.on.rectangle"
        case .all: return "film.stack"
        case .recents: return "clock"
        case .camera: return "video"
        }
    }
}

struct LibrarySidebar: View {
    @Environment(RecordingStore.self) private var store
    @Binding var destination: LibraryDestination

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(selection: $destination) {
                Section {
                    sidebarRow(.newRecording)
                }

                Section("Library") {
                    sidebarRow(.all)
                    sidebarRow(.recents)
                    sidebarRow(.camera)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 4) {
                Text("\(store.recordings.count) recordings")
                    .font(.caption.weight(.medium))
                Text(store.rootURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(12)
        }
        .frame(minWidth: 168, idealWidth: LoomTheme.sidebarWidth, maxWidth: 220)
        .background(LoomTheme.sidebarBackground)
    }

    private func sidebarRow(_ destination: LibraryDestination) -> some View {
        Label(destination.title, systemImage: destination.systemImage)
            .tag(destination)
    }
}
