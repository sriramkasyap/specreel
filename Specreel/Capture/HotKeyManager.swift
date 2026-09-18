import Foundation
import KeyboardShortcuts

// MARK: - Shortcut names

public extension KeyboardShortcuts.Name {
    /// Global toggle for start / stop recording.
    static let startStopRecording = Self("startStopRecording")
}

// MARK: - Manager

/// Registers the global start/stop hotkey via the KeyboardShortcuts SPM package.
/// Does **not** use `NSEvent.addGlobalMonitorForEvents` (that path requires
/// Accessibility permission; KeyboardShortcuts / Carbon do not).
@MainActor
public final class HotKeyManager {

    /// Invoked on key-up of the registered start/stop shortcut.
    public var onStartStopRecording: (() -> Void)?

    private var isRegistered = false

    public init() {}

    /// Begin listening for the start/stop shortcut.
    /// Safe to call multiple times; subsequent calls are no-ops until `unregister()`.
    public func register() {
        guard !isRegistered else { return }
        isRegistered = true

        KeyboardShortcuts.onKeyUp(for: .startStopRecording) { [weak self] in
            Task { @MainActor in
                guard let self, self.isRegistered else { return }
                self.onStartStopRecording?()
            }
        }
    }

    /// Stop invoking `onStartStopRecording`. The user's chosen key combination
    /// is preserved in KeyboardShortcuts' storage; callbacks are ignored until
    /// `register()` is called again.
    public func unregister() {
        isRegistered = false
    }

    /// Whether a key combination is currently assigned for start/stop.
    public var hasShortcut: Bool {
        KeyboardShortcuts.getShortcut(for: .startStopRecording) != nil
    }

    /// Current shortcut, if the user has assigned one.
    public var shortcut: KeyboardShortcuts.Shortcut? {
        KeyboardShortcuts.getShortcut(for: .startStopRecording)
    }

    /// Assign or clear the start/stop shortcut programmatically.
    public func setShortcut(_ shortcut: KeyboardShortcuts.Shortcut?) {
        KeyboardShortcuts.setShortcut(shortcut, for: .startStopRecording)
    }
}
