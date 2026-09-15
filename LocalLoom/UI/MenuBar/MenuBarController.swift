import SwiftUI
import AppKit

// MARK: - Status item label (idle / recording+timer / paused)

struct MenuBarStatusLabel: View {
    @Environment(RecordingEngine.self) private var engine

    var body: some View {
        Label {
            if engine.phase == .recording || engine.phase == .paused {
                Text(Self.elapsedString(engine.elapsed))
                    .monospacedDigit()
            }
        } icon: {
            Image(systemName: glyphName)
        }
        .help(helpText)
    }

    static func elapsedString(_ t: TimeInterval) -> String {
        let total = Int(t.rounded(.down))
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }

    private var glyphName: String {
        switch engine.phase {
        case .idle: return "record.circle"
        case .recording: return "record.circle.fill"
        case .paused: return "pause.circle.fill"
        }
    }

    private var helpText: String {
        switch engine.phase {
        case .idle: return "Local Loom — Idle"
        case .recording: return "Local Loom — Recording (click to stop)"
        case .paused: return "Local Loom — Paused (click to stop)"
        }
    }
}

// MARK: - Popover content

struct MenuBarPopover: View {
    @Environment(RecordingConfig.self) private var config
    @Environment(RecordingEngine.self) private var engine
    @Environment(RecordingStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    @State private var showOptions = false
    @State private var isBusy = false
    @State private var errorMessage: String?
    @State private var countdownController: CountdownOverlayController?
    @State private var controlPillController: FloatingControlPillController?
    @State private var postPanelController: PostRecordingPanelController?
    @State private var didHandleClickToStop = false

    var body: some View {
        @Bindable var config = config

        VStack(alignment: .leading, spacing: 12) {
            header

            if engine.phase == .idle {
                idleControls
            } else {
                activeControls
            }

            Divider()

            Button("Recordings…") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            .buttonStyle(.borderless)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(width: 320)
        .onAppear {
            // M7: click status item while recording/paused → stop immediately.
            guard !didHandleClickToStop else { return }
            if engine.phase == .recording || engine.phase == .paused {
                didHandleClickToStop = true
                Task { await stopRecordingFlow() }
            }
        }
        .onChange(of: engine.phase) { _, phase in
            if phase == .idle { didHandleClickToStop = false }
        }
    }

    private var header: some View {
        HStack {
            Text("Local Loom")
                .font(.headline)
            Spacer()
            phaseBadge
        }
    }

    @ViewBuilder
    private var phaseBadge: some View {
        switch engine.phase {
        case .idle:
            Text("Idle")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .recording:
            Text(MenuBarStatusLabel.elapsedString(engine.elapsed))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.red)
        case .paused:
            Text("Paused \(MenuBarStatusLabel.elapsedString(engine.elapsed))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.orange)
        }
    }

    private var idleControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                Task { await startRecordingFlow() }
            } label: {
                Label("Record", systemImage: "record.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(isBusy)
            .keyboardShortcut(.defaultAction)

            DisclosureGroup("Options", isExpanded: $showOptions) {
                RecordingConfigView(mode: .compact)
                    .padding(.top, 4)
            }
        }
    }

    private var activeControls: some View {
        VStack(spacing: 8) {
            Button(role: .destructive) {
                Task { await stopRecordingFlow() }
            } label: {
                Label("Stop Recording", systemImage: "stop.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(isBusy)

            HStack {
                if engine.phase == .recording {
                    Button {
                        Task { await engine.pause() }
                    } label: {
                        Label("Pause", systemImage: "pause.fill")
                            .frame(maxWidth: .infinity)
                    }
                } else if engine.phase == .paused {
                    Button {
                        Task { await engine.resume() }
                    } label: {
                        Label("Resume", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .disabled(isBusy)
        }
    }

    // MARK: - Flows

    @MainActor
    private func startRecordingFlow() async {
        errorMessage = nil
        isBusy = true
        defer { isBusy = false }

        config.save()

        let countdown = CountdownOverlayController()
        countdownController = countdown
        let proceeded = await countdown.run(seconds: 3)
        countdownController = nil
        guard proceeded else { return }

        do {
            try await engine.start(config: config.snapshot())
            let pill = FloatingControlPillController(
                onStop: { Task { await stopRecordingFlow() } },
                onPauseResume: {
                    Task {
                        if engine.phase == .paused {
                            await engine.resume()
                        } else {
                            await engine.pause()
                        }
                    }
                }
            )
            pill.show(engine: engine)
            controlPillController = pill
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func stopRecordingFlow() async {
        errorMessage = nil
        isBusy = true
        defer { isBusy = false }

        controlPillController?.close()
        controlPillController = nil

        do {
            let result = try await engine.stop()
            let panel = PostRecordingPanelController(store: store)
            postPanelController = panel
            panel.present(result: result) {
                postPanelController = nil
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
