import AppKit
import CoreGraphics
import Foundation
import QuartzCore
import ScreenCaptureKit

/// Transient region picker: borderless `.screenSaver`-level overlay spanning all
/// screens, crosshair cursor, drag-select with dimension readout.
/// Esc cancels; Enter confirms. Sets `NSWindow.sharingType = .none` so the overlay
/// never appears in the capture itself.
///
/// Output rect is in `SCStreamConfiguration.sourceRect` space: top-left origin,
/// relative to the landed-on display, in points — compatible with the Engine
/// `CoordinateConversion` utility.
@MainActor
public final class RegionSelector {

    public struct Result {
        /// Selection in `SCStreamConfiguration.sourceRect` coordinates
        /// (top-left origin, display-relative, points).
        public let sourceRect: CGRect
        public let display: SCDisplay

        public init(sourceRect: CGRect, display: SCDisplay) {
            self.sourceRect = sourceRect
            self.display = display
        }
    }

    public enum SelectionError: Error, LocalizedError, Sendable {
        case cancelled
        case noDisplayMatched

        public var errorDescription: String? {
            switch self {
            case .cancelled: return "Region selection cancelled"
            case .noDisplayMatched: return "Could not match selection to a display"
            }
        }
    }

    private var overlayWindow: RegionOverlayWindow?
    private var continuation: CheckedContinuation<Result, Error>?

    public init() {}

    /// Presents the overlay and suspends until the user confirms or cancels.
    public func selectRegion() async throws -> Result {
        if continuation != nil {
            tearDown()
        }

        let displays: [SCDisplay]
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            displays = content.displays
        } catch {
            throw error
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let window = RegionOverlayWindow()
            window.onConfirm = { [weak self] cocoaRect in
                self?.handleConfirm(cocoaRect: cocoaRect, displays: displays)
            }
            window.onCancel = { [weak self] in
                self?.handleCancel()
            }
            self.overlayWindow = window
            window.present()
        }
    }

    /// Cancels an in-flight selection if any.
    public func cancel() {
        handleCancel()
    }

    // MARK: - Completion

    private func handleConfirm(cocoaRect: CGRect, displays: [SCDisplay]) {
        defer { tearDown() }
        guard let continuation else { return }
        self.continuation = nil

        let normalized = cocoaRect.standardized
        guard normalized.width >= 1, normalized.height >= 1 else {
            continuation.resume(throwing: SelectionError.cancelled)
            return
        }

        guard let match = Self.matchDisplay(for: normalized, displays: displays) else {
            continuation.resume(throwing: SelectionError.noDisplayMatched)
            return
        }

        let sourceRect = Self.cocoaRectToSourceRect(normalized, displayFrame: match.nsScreen.frame)
        // Clip to the display bounds in sourceRect space.
        let displayBounds = CGRect(x: 0, y: 0, width: match.nsScreen.frame.width, height: match.nsScreen.frame.height)
        let clipped = sourceRect.intersection(displayBounds).integral
        guard clipped.width >= 1, clipped.height >= 1 else {
            continuation.resume(throwing: SelectionError.cancelled)
            return
        }

        continuation.resume(returning: Result(sourceRect: clipped, display: match.scDisplay))
    }

    private func handleCancel() {
        defer { tearDown() }
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(throwing: SelectionError.cancelled)
    }

    private func tearDown() {
        overlayWindow?.dismiss()
        overlayWindow = nil
    }

    // MARK: - Coordinate conversion (Cocoa global → sourceRect)

    /// Converts a rect in global Cocoa coordinates (bottom-left origin, main-display-relative)
    /// into `SCStreamConfiguration.sourceRect` space for the given display frame
    /// (top-left origin, display-relative, points).
    public static func cocoaRectToSourceRect(_ cocoaRect: CGRect, displayFrame: CGRect) -> CGRect {
        let r = cocoaRect.standardized
        let localX = r.origin.x - displayFrame.origin.x
        let localBottomY = r.origin.y - displayFrame.origin.y
        let topLeftY = displayFrame.height - (localBottomY + r.height)
        return CGRect(x: localX, y: topLeftY, width: r.width, height: r.height)
    }

    private struct DisplayMatch {
        let scDisplay: SCDisplay
        let nsScreen: NSScreen
    }

    private static func matchDisplay(for cocoaRect: CGRect, displays: [SCDisplay]) -> DisplayMatch? {
        let center = CGPoint(x: cocoaRect.midX, y: cocoaRect.midY)
        let screens = NSScreen.screens

        // Prefer the screen containing the selection center.
        let preferredScreen = screens.first { $0.frame.contains(center) }
            ?? screens.max(by: { $0.frame.intersection(cocoaRect).area < $1.frame.intersection(cocoaRect).area })

        guard let preferredScreen else { return nil }
        guard let screenID = preferredScreen.displayID else { return nil }

        guard let scDisplay = displays.first(where: { $0.displayID == screenID }) else {
            // Fall back: match by frame proximity if CGDirectDisplayID lookup fails.
            if let byFrame = displays.first(where: {
                abs($0.frame.origin.x - preferredScreen.frame.origin.x) < 1
                    && abs($0.frame.origin.y - preferredScreen.frame.origin.y) < 1
            }) {
                return DisplayMatch(scDisplay: byFrame, nsScreen: preferredScreen)
            }
            return nil
        }
        return DisplayMatch(scDisplay: scDisplay, nsScreen: preferredScreen)
    }
}

// MARK: - Overlay window

@MainActor
private final class RegionOverlayWindow: NSWindow {
    var onConfirm: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?

    private let selectionView: RegionSelectionView

    init() {
        let unionFrame = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        selectionView = RegionSelectionView(frame: CGRect(origin: .zero, size: unionFrame.size))

        super.init(
            contentRect: unionFrame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        isReleasedWhenClosed = false
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        sharingType = .none
        contentView = selectionView

        selectionView.onConfirm = { [weak self] rectInView in
            guard let self else { return }
            let frame = self.frame
            // View coords → global Cocoa: view origin is at window frame origin.
            let cocoa = CGRect(
                x: rectInView.origin.x + frame.origin.x,
                y: rectInView.origin.y + frame.origin.y,
                width: rectInView.width,
                height: rectInView.height
            )
            self.onConfirm?(cocoa)
        }
        selectionView.onCancel = { [weak self] in
            self?.onCancel?()
        }
    }

    func present() {
        // Recompute frame in case screen arrangement changed.
        let unionFrame = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        setFrame(unionFrame, display: true)
        selectionView.frame = CGRect(origin: .zero, size: unionFrame.size)
        selectionView.reset()
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        invalidateCursorRects(for: selectionView)
        resetCursorRects()
    }

    func dismiss() {
        orderOut(nil)
        selectionView.reset()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // Esc
            onCancel?()
        case 36, 76: // Return / keypad Enter
            if let rect = selectionView.currentSelection, rect.width >= 1, rect.height >= 1 {
                selectionView.confirmCurrent()
            }
        default:
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

// MARK: - Selection view

@MainActor
private final class RegionSelectionView: NSView {
    var onConfirm: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?

    private var dragStart: CGPoint?
    private var dragCurrent: CGPoint?
    private let dimmingLayer = CALayer()
    private let borderLayer = CAShapeLayer()
    private let readoutLabel = NSTextField(labelWithString: "")

    var currentSelection: CGRect? {
        guard let start = dragStart, let current = dragCurrent else { return nil }
        return CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        dimmingLayer.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor
        layer?.addSublayer(dimmingLayer)

        borderLayer.fillColor = NSColor.clear.cgColor
        borderLayer.strokeColor = NSColor.systemRed.cgColor
        borderLayer.lineWidth = 2
        borderLayer.lineDashPattern = [6, 4]
        layer?.addSublayer(borderLayer)

        readoutLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        readoutLabel.textColor = .white
        readoutLabel.backgroundColor = NSColor.black.withAlphaComponent(0.7)
        readoutLabel.drawsBackground = true
        readoutLabel.isBordered = false
        readoutLabel.isEditable = false
        readoutLabel.alignment = .center
        readoutLabel.isHidden = true
        addSubview(readoutLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func reset() {
        dragStart = nil
        dragCurrent = nil
        readoutLabel.isHidden = true
        updateLayers()
    }

    func confirmCurrent() {
        guard let rect = currentSelection, rect.width >= 1, rect.height >= 1 else { return }
        onConfirm?(rect.integral)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func layout() {
        super.layout()
        dimmingLayer.frame = bounds
        updateLayers()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        dragStart = point
        dragCurrent = point
        updateLayers()
    }

    override func mouseDragged(with event: NSEvent) {
        dragCurrent = convert(event.locationInWindow, from: nil)
        updateLayers()
    }

    override func mouseUp(with event: NSEvent) {
        dragCurrent = convert(event.locationInWindow, from: nil)
        updateLayers()
        // Confirm on mouse-up if the drag produced a usable rect; Enter also works.
        if let rect = currentSelection, rect.width >= 4, rect.height >= 4 {
            confirmCurrent()
        }
    }

    private func updateLayers() {
        guard let rect = currentSelection, rect.width > 0, rect.height > 0 else {
            dimmingLayer.mask = nil
            dimmingLayer.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor
            borderLayer.path = nil
            readoutLabel.isHidden = true
            return
        }

        let holePath = CGMutablePath()
        holePath.addRect(bounds)
        holePath.addRect(rect)
        let mask = CAShapeLayer()
        mask.fillRule = .evenOdd
        mask.path = holePath
        dimmingLayer.mask = mask
        dimmingLayer.frame = bounds
        dimmingLayer.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor

        borderLayer.path = CGPath(rect: rect, transform: nil)

        let w = Int(rect.width.rounded())
        let h = Int(rect.height.rounded())
        readoutLabel.stringValue = "  \(w) × \(h)  "
        readoutLabel.sizeToFit()
        var labelOrigin = CGPoint(x: rect.midX - readoutLabel.bounds.width / 2, y: rect.maxY + 8)
        // Keep readout on-screen within the overlay.
        labelOrigin.x = max(8, min(labelOrigin.x, bounds.width - readoutLabel.bounds.width - 8))
        if labelOrigin.y + readoutLabel.bounds.height > bounds.height - 8 {
            labelOrigin.y = rect.minY - readoutLabel.bounds.height - 8
        }
        readoutLabel.setFrameOrigin(labelOrigin)
        readoutLabel.isHidden = false
    }
}

// MARK: - Helpers

private extension CGRect {
    var area: CGFloat { max(0, width) * max(0, height) }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID? {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(number.uint32Value)
    }
}
