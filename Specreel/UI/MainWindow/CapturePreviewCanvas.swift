import SwiftUI
import AppKit
import ScreenCaptureKit

/// New Recording canvas: snapshot of the selected source plus a circular webcam PiP.
struct CapturePreviewCanvas: View {
    @Environment(RecordingConfig.self) private var config
    @Environment(RecordingStore.self) private var store

    var onOpenRecording: (RecordingEntry.ID) -> Void

    @State private var snapshot: NSImage?
    @State private var isLoading = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: pipAlignment) {
                SpecreelTheme.canvas

                if let snapshot {
                    Image(nsImage: snapshot)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if isLoading {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "display")
                            .font(.system(size: 36, weight: .light))
                        Text(placeholderCopy)
                            .font(.callout)
                    }
                    .foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
                    .padding()
                }

                VStack {
                    HStack {
                        sourceChip
                        Spacer()
                    }
                    .padding(16)
                    Spacer()
                }

                if config.includeWebcam {
                    WebcamPreviewView(deviceID: config.cameraDeviceID)
                        .frame(width: pipSize, height: pipSize)
                        .clipShape(Circle())
                        .overlay(
                            Circle().strokeBorder(.white, lineWidth: config.pip.showBorder ? 3 : 0)
                        )
                        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
                        .padding(24)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            if !store.recordings.isEmpty {
                filmstrip
            }
        }
        .background(SpecreelTheme.canvas)
        .task(id: previewIdentity) {
            await refreshSnapshot()
        }
    }

    private var previewIdentity: String {
        [
            config.source.kind.rawValue,
            String(config.source.displayID ?? 0),
            String(config.source.windowID ?? 0),
            config.source.regionInNSScreenPoints.map { "\($0.origin.x),\($0.origin.y),\($0.size.width),\($0.size.height)" } ?? "",
            config.includeWebcam ? "cam" : "nocam"
        ].joined(separator: "|")
    }

    private var placeholderCopy: String {
        if !ScreenCaptureAccess.isGranted {
            return "Grant Screen Recording to preview this source."
        }
        switch config.source.kind {
        case .region:
            return "Select a region to preview it here."
        case .window:
            return "Choose a window to preview it here."
        case .display:
            return "Select a display to preview it here."
        }
    }

    private var sourceChip: some View {
        Text(config.source.description)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.black.opacity(0.45), in: Capsule())
            .foregroundStyle(.white)
    }

    private var pipAlignment: Alignment {
        switch config.pip.corner {
        case .topLeft: return .topLeading
        case .topRight: return .topTrailing
        case .bottomLeft: return .bottomLeading
        case .bottomRight: return .bottomTrailing
        }
    }

    private var pipSize: CGFloat {
        max(96, min(180, 140 * (config.pip.sizePercent / 20)))
    }

    private var filmstrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(store.recordings.prefix(10)) { entry in
                    Button {
                        onOpenRecording(entry.id)
                    } label: {
                        thumbnail(for: entry)
                            .frame(width: 112, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(.white.opacity(0.12))
                            )
                    }
                    .buttonStyle(.plain)
                    .help(entry.meta.title.isEmpty ? "Untitled" : entry.meta.title)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(.black.opacity(0.35))
    }

    @ViewBuilder
    private func thumbnail(for entry: RecordingEntry) -> some View {
        if let image = NSImage(contentsOf: entry.thumbnailURL) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                Color.white.opacity(0.08)
                Image(systemName: "film")
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    @MainActor
    private func refreshSnapshot() async {
        guard ScreenCaptureAccess.isGranted else {
            snapshot = nil
            return
        }
        isLoading = snapshot == nil
        defer { isLoading = false }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let filter = try Self.makeFilter(config: config, content: content)
            let streamConfig = SCStreamConfiguration()
            streamConfig.showsCursor = true
            streamConfig.capturesAudio = false

            if config.source.kind == .region,
               let rect = config.source.regionInNSScreenPoints,
               rect.width > 1,
               let displayID = config.source.displayID,
               let sourceRect = CoordinateConversion.sourceRectInDisplayPoints(
                    rectInNSScreenPoints: rect,
                    displayID: displayID
               )
            {
                streamConfig.sourceRect = sourceRect
                streamConfig.width = max(2, Int(sourceRect.width))
                streamConfig.height = max(2, Int(sourceRect.height))
            } else {
                let contentRect = filter.contentRect
                let scale = CGFloat(max(1, filter.pointPixelScale))
                streamConfig.width = max(2, Int(contentRect.width * scale))
                streamConfig.height = max(2, Int(contentRect.height * scale))
            }

            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: streamConfig
            )
            snapshot = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        } catch {
            snapshot = nil
        }
    }

    private static func makeFilter(config: RecordingConfig, content: SCShareableContent) throws -> SCContentFilter {
        switch config.source.kind {
        case .display, .region:
            let displayID = config.source.displayID ?? CGMainDisplayID()
            guard let display = content.displays.first(where: { $0.displayID == displayID })
                    ?? content.displays.first else {
                throw RecordingEngineError.displayNotFound(displayID)
            }
            return SCContentFilter(display: display, excludingWindows: [])
        case .window:
            guard let windowID = config.source.windowID,
                  let window = content.windows.first(where: { $0.windowID == windowID }) else {
                throw RecordingEngineError.windowNotFound(config.source.windowID ?? 0)
            }
            return SCContentFilter(desktopIndependentWindow: window)
        }
    }
}
