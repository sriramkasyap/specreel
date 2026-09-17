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
    @Environment(RecordingSessionController.self) private var session
    @Environment(\.openWindow) private var openWindow

    @State private var didHandleClickToStop = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if engine.phase == .idle {
                RecordingConfigView(mode: .compact)
                RecordActionButton(isBusy: session.isBusy) {
                    Task { await session.start(engine: engine, config: config, store: store) }
                }
                .keyboardShortcut(.defaultAction)
            } else {
                activeControls
            }

            if let errorMessage = session.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            Divider()

            Button {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("Recordings", systemImage: "film.stack")
            }
            .buttonStyle(.borderless)
        }
        .padding(16)
        .frame(width: 300)
        .onAppear {
            // M7: click status item while recording/paused → stop immediately.
            guard !didHandleClickToStop else { return }
            if engine.phase == .recording || engine.phase == .paused {
                didHandleClickToStop = true
                Task { await session.stop(engine: engine, store: store) }
            }
        }
        .onChange(of: engine.phase) { _, phase in
            if phase == .idle { didHandleClickToStop = false }
        }
    }

    private var header: some View {
        HStack {
            Text(engine.phase == .idle ? "New Recording" : "Local Loom")
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
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(LoomTheme.record)
        case .paused:
            Text("Paused \(MenuBarStatusLabel.elapsedString(engine.elapsed))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.orange)
        }
    }

    private var activeControls: some View {
        VStack(spacing: 8) {
            RecordActionButton(title: "Stop recording", isBusy: session.isBusy) {
                Task { await session.stop(engine: engine, store: store) }
            }

            if engine.phase == .recording {
                Button {
                    Task { await engine.pause() }
                } label: {
                    Label("Pause", systemImage: "pause.fill")
                        .frame(maxWidth: .infinity)
                }
                .disabled(session.isBusy)
            } else if engine.phase == .paused {
                Button {
                    Task { await engine.resume() }
                } label: {
                    Label("Resume", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .disabled(session.isBusy)
            }
        }
    }
}
