import Foundation
import CoreGraphics
import Observation

// MARK: - Capture source

/// What ScreenCaptureKit should capture. Display-mode agnostic — the same
/// value drives both the compact popover and the expanded main-window UI.
enum CaptureSourceKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case display
    case window
    case region

    var id: String { rawValue }
}

/// Concrete capture target selected by the user (or restored from UserDefaults).
struct CaptureSource: Codable, Equatable, Sendable {
    var kind: CaptureSourceKind

    /// `CGDirectDisplayID` for `.display` / `.region`.
    var displayID: UInt32?

    /// `CGWindowID` for `.window`.
    var windowID: UInt32?

    /// Region in **NSScreen point space** (bottom-left origin, main-relative).
    /// Converted to `SCStreamConfiguration.sourceRect` via `CoordinateConversion`
    /// at stream-start time — never store the SCK rect here.
    var regionInNSScreenPoints: CGRect?

    /// Human-readable bits for `RecordingResult` / `meta.json`.
    var appName: String?
    var windowTitle: String?
    var displayName: String?

    static func display(id: UInt32, name: String? = nil) -> CaptureSource {
        CaptureSource(
            kind: .display,
            displayID: id,
            windowID: nil,
            regionInNSScreenPoints: nil,
            appName: nil,
            windowTitle: nil,
            displayName: name
        )
    }

    static func window(id: UInt32, appName: String?, title: String?, displayID: UInt32? = nil) -> CaptureSource {
        CaptureSource(
            kind: .window,
            displayID: displayID,
            windowID: id,
            regionInNSScreenPoints: nil,
            appName: appName,
            windowTitle: title,
            displayName: nil
        )
    }

    static func region(displayID: UInt32, rectInNSScreenPoints: CGRect, displayName: String? = nil) -> CaptureSource {
        CaptureSource(
            kind: .region,
            displayID: displayID,
            windowID: nil,
            regionInNSScreenPoints: rectInNSScreenPoints,
            appName: nil,
            windowTitle: nil,
            displayName: displayName
        )
    }

    var description: String {
        switch kind {
        case .display:
            return displayName.map { "Display: \($0)" } ?? "Display \(displayID.map(String.init) ?? "?")"
        case .window:
            let app = appName ?? "App"
            if let title = windowTitle, !title.isEmpty {
                return "\(app) — \(title)"
            }
            return app
        case .region:
            let name = displayName ?? displayID.map { "Display \($0)" } ?? "Display"
            if let r = regionInNSScreenPoints {
                return String(
                    format: "Region on %@ (%.0f×%.0f)",
                    name,
                    r.width,
                    r.height
                )
            }
            return "Region on \(name)"
        }
    }
}

// MARK: - PiP

enum PiPCorner: String, Codable, Sendable, CaseIterable, Identifiable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    var id: String { rawValue }
}

struct PiPSettings: Codable, Equatable, Sendable {
    /// Corner of the frame where the webcam PiP is anchored.
    var corner: PiPCorner = .bottomRight

    /// PiP width as a percentage of the composited frame width. Default 20%.
    var sizePercent: Double = 20

    /// Corner radius in points (ignored when `circularMask` is true).
    var cornerRadius: Double = 16

    /// When true, webcam is center-cropped to square then masked to a circle.
    var circularMask: Bool = true

    /// Thin border around the PiP.
    var showBorder: Bool = true

    /// Inset from frame edges as a fraction of frame width (e.g. 0.02 = 2%).
    var edgeInsetFraction: Double = 0.02
}

// MARK: - Resolution

enum ResolutionCap: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Cap longest edge so the frame fits within 2560×1440 (default).
    case p1440
    /// Capture at the display's native pixel dimensions.
    case native

    var id: String { rawValue }
}

// MARK: - Shared config model

/// Shared observable recording configuration. One instance is owned by the app
/// and bound from both compact (popover) and expanded (main window) hosts.
@Observable
final class RecordingConfig: Codable, @unchecked Sendable {
    var source: CaptureSource
    var cameraDeviceID: String?
    var microphoneDeviceID: String?
    var pip: PiPSettings
    /// System-audio gain in dB. Default −6 so mic isn't buried (Trap 7).
    var systemAudioGainDb: Float
    /// Mic gain in dB. Default 0.
    var micGainDb: Float
    var includeSystemAudio: Bool
    var includeMic: Bool
    var includeWebcam: Bool
    var resolutionCap: ResolutionCap
    var fps: Int

    enum CodingKeys: String, CodingKey {
        case source
        case cameraDeviceID
        case microphoneDeviceID
        case pip
        case systemAudioGainDb
        case micGainDb
        case includeSystemAudio
        case includeMic
        case includeWebcam
        case resolutionCap
        case fps
    }

    init(
        source: CaptureSource = .display(id: CGMainDisplayID()),
        cameraDeviceID: String? = nil,
        microphoneDeviceID: String? = nil,
        pip: PiPSettings = PiPSettings(),
        systemAudioGainDb: Float = -6,
        micGainDb: Float = 0,
        includeSystemAudio: Bool = true,
        includeMic: Bool = true,
        includeWebcam: Bool = false,
        resolutionCap: ResolutionCap = .p1440,
        fps: Int = 30
    ) {
        self.source = source
        self.cameraDeviceID = cameraDeviceID
        self.microphoneDeviceID = microphoneDeviceID
        self.pip = pip
        self.systemAudioGainDb = systemAudioGainDb
        self.micGainDb = micGainDb
        self.includeSystemAudio = includeSystemAudio
        self.includeMic = includeMic
        self.includeWebcam = includeWebcam
        self.resolutionCap = resolutionCap
        self.fps = fps
    }

    required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decode(CaptureSource.self, forKey: .source)
        cameraDeviceID = try c.decodeIfPresent(String.self, forKey: .cameraDeviceID)
        microphoneDeviceID = try c.decodeIfPresent(String.self, forKey: .microphoneDeviceID)
        pip = try c.decodeIfPresent(PiPSettings.self, forKey: .pip) ?? PiPSettings()
        systemAudioGainDb = try c.decodeIfPresent(Float.self, forKey: .systemAudioGainDb) ?? -6
        micGainDb = try c.decodeIfPresent(Float.self, forKey: .micGainDb) ?? 0
        includeSystemAudio = try c.decodeIfPresent(Bool.self, forKey: .includeSystemAudio) ?? true
        includeMic = try c.decodeIfPresent(Bool.self, forKey: .includeMic) ?? true
        includeWebcam = try c.decodeIfPresent(Bool.self, forKey: .includeWebcam) ?? false
        resolutionCap = try c.decodeIfPresent(ResolutionCap.self, forKey: .resolutionCap) ?? .p1440
        fps = try c.decodeIfPresent(Int.self, forKey: .fps) ?? 30
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(source, forKey: .source)
        try c.encodeIfPresent(cameraDeviceID, forKey: .cameraDeviceID)
        try c.encodeIfPresent(microphoneDeviceID, forKey: .microphoneDeviceID)
        try c.encode(pip, forKey: .pip)
        try c.encode(systemAudioGainDb, forKey: .systemAudioGainDb)
        try c.encode(micGainDb, forKey: .micGainDb)
        try c.encode(includeSystemAudio, forKey: .includeSystemAudio)
        try c.encode(includeMic, forKey: .includeMic)
        try c.encode(includeWebcam, forKey: .includeWebcam)
        try c.encode(resolutionCap, forKey: .resolutionCap)
        try c.encode(fps, forKey: .fps)
    }
}

// MARK: - UserDefaults persistence

extension RecordingConfig {
    static let userDefaultsKey = "LocalLoom.RecordingConfig"

    func save(to defaults: UserDefaults = .standard) {
        do {
            let data = try JSONEncoder().encode(self)
            defaults.set(data, forKey: Self.userDefaultsKey)
        } catch {
            // Persistence is best-effort; recording still works with in-memory config.
        }
    }

    static func load(from defaults: UserDefaults = .standard) -> RecordingConfig {
        guard let data = defaults.data(forKey: userDefaultsKey) else {
            return RecordingConfig()
        }
        do {
            return try JSONDecoder().decode(RecordingConfig.self, from: data)
        } catch {
            return RecordingConfig()
        }
    }

    /// Snapshot suitable for handing to `RecordingEngine.start` (value copy of fields).
    func snapshot() -> RecordingConfig {
        RecordingConfig(
            source: source,
            cameraDeviceID: cameraDeviceID,
            microphoneDeviceID: microphoneDeviceID,
            pip: pip,
            systemAudioGainDb: systemAudioGainDb,
            micGainDb: micGainDb,
            includeSystemAudio: includeSystemAudio,
            includeMic: includeMic,
            includeWebcam: includeWebcam,
            resolutionCap: resolutionCap,
            fps: fps
        )
    }
}

// MARK: - Display mode (UI only — not part of persisted capture state)

/// Hosts choose compact vs expanded; the config model itself stays agnostic.
enum RecordingConfigDisplayMode: String, Sendable, CaseIterable {
    case compact
    case expanded
}

// MARK: - Resolution helpers

enum ResolutionMath {
    /// Maximum pixel dimensions for the 1440p cap (2560×1440).
    static let p1440MaxWidth = 2560
    static let p1440MaxHeight = 1440

    /// Returns even width/height suitable for H.264, optionally capped to 1440p.
    static func outputDimensions(
        nativeWidth: Int,
        nativeHeight: Int,
        cap: ResolutionCap
    ) -> (width: Int, height: Int) {
        guard nativeWidth > 0, nativeHeight > 0 else {
            return (1920, 1080)
        }

        var w = nativeWidth
        var h = nativeHeight

        if cap == .p1440 {
            let scale = min(
                Double(p1440MaxWidth) / Double(w),
                Double(p1440MaxHeight) / Double(h),
                1.0
            )
            w = Int((Double(w) * scale).rounded())
            h = Int((Double(h) * scale).rounded())
        }

        // H.264 prefers even dimensions.
        w -= w % 2
        h -= h % 2
        return (max(w, 2), max(h, 2))
    }
}
