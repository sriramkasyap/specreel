import AppKit
import Foundation
import ScreenCaptureKit

// MARK: - Model types

/// Clean display model returned by `CaptureSourcePicker`. Holds the live `SCDisplay`
/// for immediate `SCContentFilter` use; never cached across picker opens.
public struct CaptureDisplay: Identifiable, Hashable {
    public let scDisplay: SCDisplay

    public var id: CGDirectDisplayID { scDisplay.displayID }
    public var width: Int { scDisplay.width }
    public var height: Int { scDisplay.height }
    public var frame: CGRect { scDisplay.frame }

    public var name: String {
        let screenNumberKey = NSDeviceDescriptionKey("NSScreenNumber")
        if let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[screenNumberKey] as? NSNumber)?.uint32Value == scDisplay.displayID
        }) {
            return screen.localizedName
        }
        return "Display \(scDisplay.displayID)"
    }

    public init(scDisplay: SCDisplay) {
        self.scDisplay = scDisplay
    }

    public static func == (lhs: CaptureDisplay, rhs: CaptureDisplay) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// Clean window model returned by `CaptureSourcePicker`.
public struct CaptureWindow: Identifiable, Hashable {
    public let scWindow: SCWindow

    public var id: CGWindowID { scWindow.windowID }
    public var title: String { scWindow.title ?? "" }
    public var frame: CGRect { scWindow.frame }
    public var isOnScreen: Bool { scWindow.isOnScreen }
    public var owningApplication: CaptureApp? {
        guard let app = scWindow.owningApplication else { return nil }
        return CaptureApp(scApplication: app)
    }

    public var displayName: String {
        let appName = owningApplication?.applicationName ?? "Unknown"
        let windowTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if windowTitle.isEmpty { return appName }
        return "\(appName) — \(windowTitle)"
    }

    public init(scWindow: SCWindow) {
        self.scWindow = scWindow
    }

    public static func == (lhs: CaptureWindow, rhs: CaptureWindow) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// Clean running-application model returned by `CaptureSourcePicker`.
public struct CaptureApp: Identifiable, Hashable {
    public let scApplication: SCRunningApplication

    public var id: pid_t { scApplication.processID }
    public var bundleIdentifier: String { scApplication.bundleIdentifier }
    public var applicationName: String { scApplication.applicationName }

    public init(scApplication: SCRunningApplication) {
        self.scApplication = scApplication
    }

    public static func == (lhs: CaptureApp, rhs: CaptureApp) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// Snapshot of shareable content from a single enumeration pass.
public struct CaptureSources {
    public let displays: [CaptureDisplay]
    public let windows: [CaptureWindow]
    public let applications: [CaptureApp]

    public init(
        displays: [CaptureDisplay],
        windows: [CaptureWindow],
        applications: [CaptureApp]
    ) {
        self.displays = displays
        self.windows = windows
        self.applications = applications
    }
}

// MARK: - Picker

/// Wraps `SCShareableContent` enumeration. Owns nothing persistent —
/// refreshes on every call; the window list goes stale fast.
public enum CaptureSourcePicker {

    /// Bundle IDs treated as system UI chrome (menu bar, Dock, Window Server, etc.).
    public static let systemUIBundleIdentifiers: Set<String> = [
        "com.apple.dock",
        "com.apple.controlcenter",
        "com.apple.notificationcenterui",
        "com.apple.systemuiserver",
        "com.apple.WindowServer",
        "com.apple.loginwindow",
        "com.apple.Spotlight",
        "com.apple.TextInputUI.xpc.CursorUIViewService",
        "com.apple.AccessibilityVisualsAgent",
        "com.apple.wallpaper.agent",
    ]

    /// Process / app names used when bundle ID is missing or unreliable.
    public static let systemUIApplicationNames: Set<String> = [
        "Dock",
        "Control Centre",
        "Control Center",
        "Notification Centre",
        "Notification Center",
        "SystemUIServer",
        "Window Server",
        "WindowServer",
        "loginwindow",
        "Spotlight",
    ]

    public enum PickerError: Error, LocalizedError, Sendable {
        case contentUnavailable(underlying: Error)

        public var errorDescription: String? {
            switch self {
            case .contentUnavailable(let underlying):
                return "Unable to enumerate shareable content: \(underlying.localizedDescription)"
            }
        }
    }

    /// Enumerate displays, windows, and apps. Always hits `SCShareableContent` —
    /// no caching across opens.
    ///
    /// - Parameters:
    ///   - includeSystemUI: When `false` (default), excludes menu bar / Dock / Window Server chrome.
    ///   - excludeOwnWindows: When `true` (default), excludes this process's windows.
    public static func loadSources(
        includeSystemUI: Bool = false,
        excludeOwnWindows: Bool = true
    ) async throws -> CaptureSources {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
        } catch {
            throw PickerError.contentUnavailable(underlying: error)
        }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownBundleID = Bundle.main.bundleIdentifier

        let displays = content.displays.map(CaptureDisplay.init(scDisplay:))

        let windows = content.windows.compactMap { window -> CaptureWindow? in
            guard isValidWindowFrame(window.frame) else { return nil }

            if excludeOwnWindows {
                if window.owningApplication?.processID == ownPID { return nil }
                if let bid = window.owningApplication?.bundleIdentifier,
                   let ownBundleID,
                   bid == ownBundleID {
                    return nil
                }
            }

            if !includeSystemUI, isSystemUI(window.owningApplication) {
                return nil
            }

            return CaptureWindow(scWindow: window)
        }

        let applications = content.applications.compactMap { app -> CaptureApp? in
            if excludeOwnWindows {
                if app.processID == ownPID { return nil }
                if let ownBundleID, app.bundleIdentifier == ownBundleID { return nil }
            }
            if !includeSystemUI, isSystemUI(app) { return nil }
            return CaptureApp(scApplication: app)
        }

        return CaptureSources(
            displays: displays,
            windows: windows,
            applications: applications
        )
    }

    // MARK: - Filters

    public static func isValidWindowFrame(_ frame: CGRect) -> Bool {
        frame.width > 0 && frame.height > 0 && !frame.isNull && !frame.isInfinite
    }

    public static func isSystemUI(_ application: SCRunningApplication?) -> Bool {
        guard let application else { return false }
        return isSystemUI(application)
    }

    public static func isSystemUI(_ application: SCRunningApplication) -> Bool {
        let bundleID = application.bundleIdentifier
        if !bundleID.isEmpty, systemUIBundleIdentifiers.contains(bundleID) {
            return true
        }
        let name = application.applicationName
        if systemUIApplicationNames.contains(name) {
            return true
        }
        // Window Server often reports an empty or opaque bundle ID.
        if name.localizedCaseInsensitiveContains("Window Server") {
            return true
        }
        return false
    }
}
