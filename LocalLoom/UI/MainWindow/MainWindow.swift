import SwiftUI

/// Three-column Local Loom window: library sidebar, gallery or capture canvas, inspector.
struct MainWindow: View {
    @Environment(RecordingConfig.self) private var config
    @Environment(RecordingEngine.self) private var engine
    @Environment(RecordingStore.self) private var store
    @Environment(RecordingSessionController.self) private var session

    @State private var destination: LibraryDestination = .all
    @State private var selection: RecordingEntry.ID?
    @State private var searchText = ""
    @State private var sort: GalleryView.SortKey = .dateNewest

    var body: some View {
        NavigationStack {
            HSplitView {
                LibrarySidebar(destination: $destination)

                contentColumn
                    .frame(minWidth: 440)

                inspectorColumn
                    .frame(minWidth: 280, idealWidth: LoomTheme.inspectorWidth, maxWidth: 380)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .navigationTitle(destination.title)
        .searchable(text: $searchText, prompt: "Search title or description")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                if destination != .newRecording {
                    Picker("Sort", selection: $sort) {
                        ForEach(GalleryView.SortKey.allCases) { key in
                            Text(key.title).tag(key)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                toolbarRecordButton
            }
        }
        .onChange(of: destination) { _, newValue in
            if newValue == .newRecording {
                searchText = ""
            }
        }
        .task {
            store.scan()
        }
    }

    @ViewBuilder
    private var contentColumn: some View {
        if destination == .newRecording {
            CapturePreviewCanvas { id in
                selection = id
                destination = .all
            }
        } else {
            GalleryView(
                selection: $selection,
                filter: destination,
                searchText: $searchText,
                sort: sort
            )
        }
    }

    @ViewBuilder
    private var inspectorColumn: some View {
        if destination == .newRecording {
            newRecordingInspector
        } else if let entry = selectedEntry {
            RecordingInspector(entry: entry)
                .id(entry.id)
        } else {
            EmptyInspector()
        }
    }

    private var newRecordingInspector: some View {
        VStack(spacing: 0) {
            RecordingConfigView(mode: .expanded)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                if let errorMessage = session.errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }

                if engine.phase == .idle {
                    RecordActionButton(isBusy: session.isBusy) {
                        Task {
                            await session.start(engine: engine, config: config, store: store)
                        }
                    }
                } else {
                    HStack(spacing: 8) {
                        if engine.phase == .recording {
                            Button("Pause") {
                                Task { await engine.pause() }
                            }
                        } else {
                            Button("Resume") {
                                Task { await engine.resume() }
                            }
                        }
                        Button("Stop", role: .destructive) {
                            Task { await session.stop(engine: engine, store: store) }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(LoomTheme.record)
                    }
                    .disabled(session.isBusy)
                }
            }
            .padding(16)
        }
        .background(LoomTheme.inspectorBackground)
    }

    @ViewBuilder
    private var toolbarRecordButton: some View {
        if engine.phase == .idle {
            Button {
                if destination == .newRecording {
                    Task { await session.start(engine: engine, config: config, store: store) }
                } else {
                    destination = .newRecording
                }
            } label: {
                Label("Record", systemImage: "record.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(LoomTheme.record)
        } else {
            Button {
                Task { await session.stop(engine: engine, store: store) }
            } label: {
                Label(LoomTheme.duration(engine.elapsed), systemImage: "stop.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(LoomTheme.record)
        }
    }

    private var selectedEntry: RecordingEntry? {
        if let selection,
           let match = store.recordings.first(where: { $0.id == selection }) {
            return match
        }
        return nil
    }
}
