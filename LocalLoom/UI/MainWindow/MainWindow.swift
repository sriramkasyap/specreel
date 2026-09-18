import SwiftUI

/// Full-window three-column library matching the layout mock:
/// 200pt sidebar, flexible gallery/canvas, 320pt inspector that collapses
/// when nothing is selected.
struct MainWindow: View {
    @Environment(RecordingConfig.self) private var config
    @Environment(RecordingEngine.self) private var engine
    @Environment(RecordingStore.self) private var store
    @Environment(RecordingSessionController.self) private var session

    @State private var filter: LibraryFilter = .all
    @State private var isNewRecording = false
    @State private var sidebarVisible = true
    @State private var selection: RecordingEntry.ID?
    @State private var searchText = ""
    @State private var sort: GalleryView.SortKey = .dateNewest

    var body: some View {
        GeometryReader { geo in
            HSplitView {
                if sidebarVisible {
                    LibrarySidebar(filter: $filter) {
                        isNewRecording = false
                    }
                    .frame(minWidth: 180, idealWidth: 200, maxWidth: 240)
                    .frame(maxHeight: .infinity)
                }

                contentColumn
                    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)

                if showsInspector {
                    inspectorColumn
                        .frame(minWidth: 300, idealWidth: 320, maxWidth: 380)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .frame(minWidth: 1000, minHeight: 640)
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    sidebarVisible.toggle()
                } label: {
                    Image(systemName: "sidebar.leading")
                }
                .help("Toggle sidebar")
            }

            ToolbarItem(placement: .automatic) {
                if !isNewRecording {
                    TextField("Search", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 140, idealWidth: 180)
                        .help("Search title or description")
                }
            }

            ToolbarItem(placement: .automatic) {
                if !isNewRecording {
                    Picker("Sort", selection: $sort) {
                        ForEach(GalleryView.SortKey.allCases) { key in
                            Text(key.title).tag(key)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 120)
                }
            }

            ToolbarItem(placement: .primaryAction) {
                toolbarPrimaryButton
            }
        }
        .navigationTitle(isNewRecording ? "New Recording" : filter.title)
        .task {
            store.scan()
        }
    }

    @ViewBuilder
    private var contentColumn: some View {
        if isNewRecording {
            CapturePreviewCanvas { id in
                selection = id
                isNewRecording = false
                filter = .all
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            GalleryView(
                selection: $selection,
                filter: filter,
                searchText: $searchText,
                sort: sort
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var showsInspector: Bool {
        isNewRecording || selectedEntry != nil
    }

    @ViewBuilder
    private var inspectorColumn: some View {
        if isNewRecording {
            newRecordingInspector
        } else if let entry = selectedEntry {
            RecordingInspector(entry: entry)
                .id(entry.id)
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
                } else if session.isBusy {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Saving recording…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder
    private var toolbarPrimaryButton: some View {
        if engine.phase != .idle {
            Button {
                Task { await session.stop(engine: engine, store: store) }
            } label: {
                Label(LoomTheme.duration(engine.elapsed), systemImage: "stop.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(LoomTheme.record)
        } else if isNewRecording {
            Button {
                Task { await session.start(engine: engine, config: config, store: store) }
            } label: {
                Label("Start recording", systemImage: "record.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(LoomTheme.record)
            .disabled(session.isBusy)
        } else {
            Button {
                isNewRecording = true
            } label: {
                Label("New Recording", systemImage: "plus")
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
