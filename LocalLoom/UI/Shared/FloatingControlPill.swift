import SwiftUI
import AppKit

/// Floating stop/pause pill shown while recording. Excluded from capture
/// via `NSWindow.sharingType = .none`.
struct FloatingControlPill: View {
    let engine: RecordingEngine
    var onStop: () -> Void
    var onPauseResume: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(engine.phase == .paused ? Color.orange : LoomTheme.record)
                .frame(width: 8, height: 8)
                .opacity(engine.phase == .recording ? 1 : 0.85)

            Text(MenuBarStatusLabel.elapsedString(engine.elapsed))
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .frame(minWidth: 44, alignment: .leading)

            Button(action: onPauseResume) {
                Image(systemName: engine.phase == .paused ? "play.fill" : "pause.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help(engine.phase == .paused ? "Resume" : "Pause")

            Button(action: onStop) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(LoomTheme.record, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("Stop")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(LoomTheme.pillFill, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
    }
}

@MainActor
final class FloatingControlPillController {
    private var window: NSWindow?
    private let onStop: () -> Void
    private let onPauseResume: () -> Void

    init(onStop: @escaping () -> Void, onPauseResume: @escaping () -> Void) {
        self.onStop = onStop
        self.onPauseResume = onPauseResume
    }

    func show(engine: RecordingEngine) {
        close()

        let root = FloatingControlPill(
            engine: engine,
            onStop: onStop,
            onPauseResume: onPauseResume
        )
        let hosting = NSHostingController(rootView: root)
        hosting.view.wantsLayer = true

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 48),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        // Trap #8 / M7: must not appear in the recording.
        panel.sharingType = .none
        panel.contentViewController = hosting

        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            let size = hosting.view.fittingSize
            let origin = NSPoint(
                x: frame.midX - size.width / 2,
                y: frame.minY + 28
            )
            panel.setContentSize(size)
            panel.setFrameOrigin(origin)
        }

        window = panel
        panel.orderFrontRegardless()
    }

    func close() {
        window?.close()
        window = nil
    }
}
