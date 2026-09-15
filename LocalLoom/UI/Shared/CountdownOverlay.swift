import SwiftUI
import AppKit

/// Full-screen countdown before recording starts. Excluded from capture
/// via `NSWindow.sharingType = .none`.
struct CountdownOverlay: View {
    let remaining: Int
    var onCancel: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()

            VStack(spacing: 24) {
                Text("\(remaining)")
                    .font(.system(size: 120, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                    .animation(.easeInOut(duration: 0.2), value: remaining)

                Text("Recording starts…")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.85))

                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.bordered)
                    .tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@MainActor
final class CountdownOverlayController {
    private var window: NSWindow?
    private var continuation: CheckedContinuation<Bool, Never>?

    /// Counts down from `seconds`, then returns `true`. Cancel / Esc → `false`.
    func run(seconds: Int = 3) async -> Bool {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            present(startingAt: seconds)
        }
    }

    private func present(startingAt seconds: Int) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let frame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)

        let binding = CountdownHost(
            remaining: seconds,
            onCancel: { [weak self] in self?.finish(proceed: false) },
            onFinished: { [weak self] in self?.finish(proceed: true) }
        )

        let hosting = NSHostingController(rootView: binding)
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.setFrame(frame, display: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        // Trap #8 / M7: countdown must not be captured.
        panel.sharingType = .none
        panel.contentViewController = hosting
        panel.ignoresMouseEvents = false

        window = panel
        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func finish(proceed: Bool) {
        window?.close()
        window = nil
        continuation?.resume(returning: proceed)
        continuation = nil
    }
}

/// Owns the ticking state for the overlay window.
private struct CountdownHost: View {
    @State var remaining: Int
    var onCancel: () -> Void
    var onFinished: () -> Void

    var body: some View {
        CountdownOverlay(remaining: remaining, onCancel: onCancel)
            .onAppear { tick() }
            .onExitCommand(perform: onCancel)
    }

    private func tick() {
        guard remaining > 0 else {
            onFinished()
            return
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            remaining -= 1
            if remaining <= 0 {
                onFinished()
            } else {
                tick()
            }
        }
    }
}
