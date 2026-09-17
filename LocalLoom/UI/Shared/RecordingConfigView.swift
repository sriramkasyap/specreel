import SwiftUI
import AVFoundation
import AppKit
import ScreenCaptureKit

/// One config UI for popover (compact) and main window (expanded).
struct RecordingConfigView: View {
    /// Local alias; Engine also defines `RecordingConfigDisplayMode`.
    enum DisplayMode {
        case compact
        case expanded

        var engineMode: RecordingConfigDisplayMode {
            switch self {
            case .compact: return .compact
            case .expanded: return .expanded
            }
        }
    }

    let mode: DisplayMode

    @Environment(RecordingConfig.self) private var config

    @State private var displays: [CaptureDisplay] = []
    @State private var windows: [CaptureWindow] = []
    @State private var cameras: [AVCaptureDevice] = []
    @State private var microphones: [AVCaptureDevice] = []
    @State private var isLoadingSources = false
    @State private var loadError: String?
    @State private var isPermissionError = false
    @State private var regionSelector = RegionSelector()

    var body: some View {
        @Bindable var config = config

        Group {
            switch mode {
            case .compact:
                compactBody(config: config)
            case .expanded:
                expandedBody(config: config)
            }
        }
        .task { await refreshDevicesAndSources() }
    }

    // MARK: - Compact

    @ViewBuilder
    private func compactBody(config: RecordingConfig) -> some View {
        @Bindable var config = config
        Form {
            sourceSection(config: config)
            permissionErrorBanner
            Toggle("Camera", isOn: $config.includeWebcam)
            if config.includeWebcam {
                cameraPicker(config: config)
                pipCornerPicker(config: config)
            }
            Toggle("Microphone", isOn: $config.includeMic)
            if config.includeMic {
                micPicker(config: config)
            }
            Toggle("System Audio", isOn: $config.includeSystemAudio)
        }
        .formStyle(.grouped)
    }

    // MARK: - Expanded

    @ViewBuilder
    private func expandedBody(config: RecordingConfig) -> some View {
        @Bindable var config = config
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Recording Setup")
                    .font(.title2.weight(.semibold))

                permissionErrorBanner

                GroupBox("Source") {
                    VStack(alignment: .leading, spacing: 10) {
                        sourceSection(config: config)

                        Button {
                            Task { await refreshDevicesAndSources() }
                        } label: {
                            Label(
                                isLoadingSources ? "Refreshing…" : "Refresh Sources",
                                systemImage: "arrow.clockwise"
                            )
                        }
                        .disabled(isLoadingSources)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }

                GroupBox("Camera & PiP") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Include webcam", isOn: $config.includeWebcam)
                        if config.includeWebcam {
                            cameraPicker(config: config)
                            WebcamPreviewView(deviceID: config.cameraDeviceID)
                                .frame(height: 180)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            pipSection(config: config)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }

                GroupBox("Audio") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Microphone", isOn: $config.includeMic)
                        if config.includeMic {
                            micPicker(config: config)
                            gainSlider(
                                title: "Mic gain",
                                value: $config.micGainDb,
                                range: -24...12
                            )
                        }
                        Toggle("System audio", isOn: $config.includeSystemAudio)
                        if config.includeSystemAudio {
                            gainSlider(
                                title: "System gain",
                                value: $config.systemAudioGainDb,
                                range: -24...12
                            )
                            Text("Default −6 dB relative to mic (system runs hotter).")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }

                GroupBox("Quality") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Resolution")
                            .font(.subheadline)
                        Picker("Resolution", selection: $config.resolutionCap) {
                            Text("1440p").tag(ResolutionCap.p1440)
                            Text("Native").tag(ResolutionCap.native)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()

                        Text("Default 30 fps. Native uses the display’s pixel size.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.background)
    }

    // MARK: - Permission / load error

    @ViewBuilder
    private var permissionErrorBanner: some View {
        if let loadError {
            VStack(alignment: .leading, spacing: 8) {
                Label(loadError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                if isPermissionError {
                    Text(ScreenCaptureAccess.staleGrantHint)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        Button("Grant Access…") {
                            requestScreenRecordingAccess()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)

                        Button("Open Settings") {
                            ScreenCaptureAccess.openSystemSettings()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - Shared sections

    @ViewBuilder
    private func sourceSection(config: RecordingConfig) -> some View {
        @Bindable var config = config

        VStack(alignment: .leading, spacing: 8) {
            Text("Capture")
                .font(.subheadline)
            Picker("Capture", selection: Binding(
                get: { config.source.kind },
                set: { newKind in
                    switch newKind {
                    case .display:
                        config.source = .display(
                            id: config.source.displayID ?? CGMainDisplayID(),
                            name: config.source.displayName
                        )
                    case .window:
                        config.source = .window(
                            id: config.source.windowID ?? 0,
                            appName: config.source.appName,
                            title: config.source.windowTitle,
                            displayID: config.source.displayID
                        )
                    case .region:
                        config.source = .region(
                            displayID: config.source.displayID ?? CGMainDisplayID(),
                            rectInNSScreenPoints: config.source.regionInNSScreenPoints ?? .zero,
                            displayName: config.source.displayName
                        )
                    }
                }
            )) {
                Text("Display").tag(CaptureSourceKind.display)
                Text("Window").tag(CaptureSourceKind.window)
                Text("Region").tag(CaptureSourceKind.region)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }

        switch config.source.kind {
        case .display:
            Picker("Display", selection: Binding(
                get: { config.source.displayID },
                set: { id in
                    let name = displays.first(where: { $0.id == id })?.name
                    config.source = .display(id: id ?? CGMainDisplayID(), name: name)
                }
            )) {
                Text("Select…").tag(UInt32?.none)
                ForEach(displays) { display in
                    Text(display.name).tag(Optional(display.id))
                }
            }
        case .window:
            Picker("Window", selection: Binding(
                get: { config.source.windowID },
                set: { id in
                    guard let id,
                          let window = windows.first(where: { $0.id == id })
                    else { return }
                    config.source = .window(
                        id: id,
                        appName: window.owningApplication?.applicationName,
                        title: window.title.isEmpty ? nil : window.title,
                        displayID: config.source.displayID
                    )
                }
            )) {
                Text("Select…").tag(UInt32?.none)
                ForEach(windows) { window in
                    Text(window.displayName).tag(Optional(window.id))
                }
            }
        case .region:
            HStack {
                if let rect = config.source.regionInNSScreenPoints, rect.width > 0 {
                    Text("\(Int(rect.width))×\(Int(rect.height))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Text("No region selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Select Region…") {
                    Task { await selectRegion(config: config) }
                }
            }
        }
    }

    private func cameraPicker(config: RecordingConfig) -> some View {
        @Bindable var config = config
        return Picker("Camera", selection: $config.cameraDeviceID) {
            Text("Default").tag(String?.none)
            ForEach(cameras, id: \.uniqueID) { device in
                Text(device.localizedName).tag(Optional(device.uniqueID))
            }
        }
    }

    private func micPicker(config: RecordingConfig) -> some View {
        @Bindable var config = config
        return Picker("Microphone", selection: $config.microphoneDeviceID) {
            Text("Default").tag(String?.none)
            ForEach(microphones, id: \.uniqueID) { device in
                Text(device.localizedName).tag(Optional(device.uniqueID))
            }
        }
    }

    private func pipCornerPicker(config: RecordingConfig) -> some View {
        @Bindable var config = config
        return Picker("PiP corner", selection: $config.pip.corner) {
            ForEach(PiPCorner.allCases) { corner in
                Text(corner.displayTitle).tag(corner)
            }
        }
    }

    private func pipSection(config: RecordingConfig) -> some View {
        @Bindable var config = config
        return VStack(alignment: .leading, spacing: 10) {
            pipCornerPicker(config: config)

            gainSlider(
                title: "Size",
                value: Binding(
                    get: { Float(config.pip.sizePercent) },
                    set: { config.pip.sizePercent = Double($0) }
                ),
                range: 10...40,
                format: { "\(Int($0))%" }
            )

            gainSlider(
                title: "Corner radius",
                value: Binding(
                    get: { Float(config.pip.cornerRadius) },
                    set: { config.pip.cornerRadius = Double($0) }
                ),
                range: 0...48,
                format: { "\(Int($0))" }
            )

            Toggle("Circular mask", isOn: $config.pip.circularMask)
            Toggle("Border", isOn: $config.pip.showBorder)
        }
    }

    /// Vertical label + slider so narrow columns don't clip `LabeledContent`.
    private func gainSlider(
        title: String,
        value: Binding<Float>,
        range: ClosedRange<Float>,
        format: ((Float) -> String)? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.subheadline)
                Spacer()
                Text(format?(value.wrappedValue) ?? String(format: "%+.0f dB", value.wrappedValue))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
        }
    }

    // MARK: - Actions

    @MainActor
    private func selectRegion(config: RecordingConfig) async {
        do {
            let result = try await regionSelector.selectRegion()
            // RegionSelector returns SCK sourceRect; config stores NSScreen points.
            let bounds = CoordinateConversion.nsScreen(forDisplayID: result.display.displayID)?.frame
                ?? CGRect(x: 0, y: 0, width: result.display.width, height: result.display.height)
            let nsRect = CoordinateConversion.rectInNSScreenPoints(
                sourceRectInDisplayPoints: result.sourceRect,
                displayBoundsInNSScreenPoints: bounds
            )
            let name = "Display \(result.display.displayID)"
            config.source = .region(
                displayID: result.display.displayID,
                rectInNSScreenPoints: nsRect,
                displayName: name
            )
        } catch is RegionSelector.SelectionError {
            // Cancelled — leave existing region.
        } catch {
            applyLoadError(error)
        }
    }

    @MainActor
    private func refreshDevicesAndSources() async {
        isLoadingSources = true
        loadError = nil
        isPermissionError = false
        defer { isLoadingSources = false }

        // Cameras / mics never need Screen Recording — always refresh them.
        cameras = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        ).devices

        microphones = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        ).devices

        // Critical: do NOT call SCShareableContent when unauthorized.
        // That API surfaces the system TCC sheet; running it on every
        // Recordings-window open was the re-prompt loop.
        guard ScreenCaptureAccess.isGranted else {
            displays = []
            windows = []
            isPermissionError = true
            loadError = "Screen Recording permission is required to list displays and windows."
            return
        }

        do {
            let sources = try await CaptureSourcePicker.loadSources()
            displays = sources.displays
            windows = sources.windows
        } catch {
            applyLoadError(error)
        }
    }

    @MainActor
    private func requestScreenRecordingAccess() {
        // User-initiated only — may show the system sheet once.
        let granted = ScreenCaptureAccess.request()
        if granted {
            Task { await refreshDevicesAndSources() }
        } else {
            isPermissionError = true
            loadError = "Screen Recording permission was not granted. Enable LocalLoom in System Settings, then quit and reopen the app."
            ScreenCaptureAccess.openSystemSettings()
        }
    }

    private func applyLoadError(_ error: Error) {
        let raw = error.localizedDescription
        if Self.isScreenRecordingPermissionError(raw) {
            isPermissionError = true
            loadError = "Screen Recording permission is required. Enable LocalLoom in System Settings → Privacy & Security → Screen Recording, then quit and reopen the app."
        } else {
            isPermissionError = false
            loadError = raw
        }
    }

    private static func isScreenRecordingPermissionError(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("tcc")
            || lower.contains("declined")
            || lower.contains("screen capture")
            || lower.contains("screen recording")
            || lower.contains("not authorized")
            || lower.contains("permission")
    }
}

private extension PiPCorner {
    var displayTitle: String {
        switch self {
        case .topLeft: return "Top Left"
        case .topRight: return "Top Right"
        case .bottomLeft: return "Bottom Left"
        case .bottomRight: return "Bottom Right"
        }
    }
}
