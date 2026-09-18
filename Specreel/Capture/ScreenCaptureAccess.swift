import AppKit
import CoreGraphics
import Foundation

/// Screen Recording TCC helpers.
///
/// `SCShareableContent` / `SCStream` will themselves trigger the system permission
/// sheet when unauthorized. Calling them on every window appear is what made
/// Specreel re-prompt each time "Recordings…" was opened.
///
/// Use `isGranted` (preflight) to decide whether enumeration is safe. Only call
/// `request()` from an explicit user action (Grant button or Record).
enum ScreenCaptureAccess {
    /// `true` if this running binary is already authorized for screen capture.
    /// Does **not** show a prompt.
    static var isGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Shows the system Screen Recording permission UI (once per denial cycle).
    /// Returns whether access is granted after the user responds.
    @discardableResult
    static func request() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// Opens System Settings → Privacy & Security → Screen Recording.
    @MainActor
    static func openSystemSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.preference.security?Privacy"
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    /// Copy shown when Settings may list the app but this process is still denied
    /// (common after rebuild / another copy on disk / grant without relaunch).
    static let staleGrantHint =
        "If Specreel is already enabled in System Settings, quit the app fully from the menu bar and reopen so macOS can apply the grant to this build."
}
