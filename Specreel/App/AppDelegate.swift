import AppKit

/// Keeps the process alive when the main window is closed so the menu-bar
/// recorder (and popover “Recordings…”) remain available.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ensure we appear in Dock (Info.plist LSUIElement must be false / absent).
        NSApp.setActivationPolicy(.regular)
    }
}
