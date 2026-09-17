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
        case screenRecordingDenied

        public var errorDescription: String? {
            switch self {
            case .cancelled: return "Region selection cancelled"
            case .noDisplayMatched: return "Could not match selection to a display"
            case .screenRecordingDenied:
                return "Screen Recording permission is required to select a region."
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

        // Region pick is user-initiated — request once if needed, never silently
        // spam the system sheet from a background refresh.
        if !ScreenCaptureAccess.isGranted {
            let granted = ScreenCaptureAccess.request()
            guard granted else {
                throw SelectionError.screenRecordingDenied
            }
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
    private let handleLayers: [CALayer] = (0..<8).map { _ in
        let layer = CALayer()
        layer.backgroundColor = NSColor.white.cgColor
        layer.borderColor = NSColor.black.withAlphaComponent(0.35).cgColor
        layer.borderWidth = 0.5
        layer.cornerRadius = 1
        layer.isHidden = true
        return layer
    }
    private let hintLabel = NSTextField(labelWithString: "Click and drag to select a region")
    private let toolbar = NSStackView()
    private let sizeLabel = NSTextField(labelWithString: "0 × 0")
    private let cancelButton = NSButton()
    private let confirmButton = NSButton()

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

        dimmingLayer.backgroundColor = NSColor.black.withAlphaComponent(0.5).cgColor
        layer?.addSublayer(dimmingLayer)

        borderLayer.fillColor = NSColor.clear.cgColor
        borderLayer.strokeColor = NSColor.white.cgColor
        borderLayer.lineWidth = 2
        layer?.addSublayer(borderLayer)

        for handle in handleLayers {
            layer?.addSublayer(handle)
        }

        hintLabel.font = NSFont.systemFont(ofSize: 15, weight: .medium)
        hintLabel.textColor = .white
        hintLabel.backgroundColor = NSColor.black.withAlphaComponent(0.45)
        hintLabel.drawsBackground = true
        hintLabel.isBordered = false
        hintLabel.isEditable = false
        hintLabel.alignment = .center
        addSubview(hintLabel)

        sizeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        sizeLabel.textColor = .white
        sizeLabel.backgroundColor = .clear
        sizeLabel.isBordered = false
        sizeLabel.isEditable = false
        sizeLabel.alignment = .center

        cancelButton.title = "Cancel"
        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(handleCancel)

        confirmButton.title = "Confirm"
        confirmButton.bezelStyle = .rounded
        confirmButton.contentTintColor = .white
        confirmButton.bezelColor = NSColor(red: 0.89, green: 0.16, blue: 0.18, alpha: 1)
        confirmButton.target = self
        confirmButton.action = #selector(handleConfirm)
        confirmButton.keyEquivalent = "\r"

        toolbar.orientation = .horizontal
        toolbar.spacing = 10
        toolbar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        toolbar.wantsLayer = true
        toolbar.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
        toolbar.layer?.cornerRadius = 10
        toolbar.addArrangedSubview(cancelButton)
        toolbar.addArrangedSubview(sizeLabel)
        toolbar.addArrangedSubview(confirmButton)
        toolbar.isHidden = true
        addSubview(toolbar)

        layoutChrome()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func reset() {
        dragStart = nil
        dragCurrent = nil
        toolbar.isHidden = true
        hintLabel.isHidden = false
        for handle in handleLayers { handle.isHidden = true }
        updateLayers()
        layoutChrome()
    }

    func confirmCurrent() {
        guard let rect = currentSelection, rect.width >= 1, rect.height >= 1 else { return }
        onConfirm?(rect.integral)
    }

    @objc private func handleCancel() {
        onCancel?()
    }

    @objc private func handleConfirm() {
        confirmCurrent()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func layout() {
        super.layout()
        dimmingLayer.frame = bounds
        layoutChrome()
        updateLayers()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if !toolbar.isHidden, toolbar.frame.contains(point) {
            return toolbar.hitTest(convert(point, to: toolbar)) ?? toolbar
        }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if !toolbar.isHidden, toolbar.frame.contains(point) { return }
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
    }

    private func layoutChrome() {
        hintLabel.sizeToFit()
        let hintSize = NSSize(width: hintLabel.bounds.width + 24, height: hintLabel.bounds.height + 10)
        hintLabel.frame = NSRect(
            x: bounds.midX - hintSize.width / 2,
            y: bounds.maxY - hintSize.height - 36,
            width: hintSize.width,
            height: hintSize.height
        )
        hintLabel.layer?.cornerRadius = 8

        toolbar.layoutSubtreeIfNeeded()
        let toolbarSize = NSSize(width: max(280, toolbar.fittingSize.width), height: 44)
        toolbar.frame = NSRect(
            x: bounds.midX - toolbarSize.width / 2,
            y: 28,
            width: toolbarSize.width,
            height: toolbarSize.height
        )
    }

    private func updateLayers() {
        guard let rect = currentSelection, rect.width > 0, rect.height > 0 else {
            dimmingLayer.mask = nil
            dimmingLayer.backgroundColor = NSColor.black.withAlphaComponent(0.5).cgColor
            borderLayer.path = nil
            toolbar.isHidden = true
            hintLabel.isHidden = false
            for handle in handleLayers { handle.isHidden = true }
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
        dimmingLayer.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor

        borderLayer.path = CGPath(rect: rect, transform: nil)

        let handleSize: CGFloat = 8
        let points: [CGPoint] = [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.midX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.midY),
            CGPoint(x: rect.maxX, y: rect.midY),
            CGPoint(x: rect.minX, y: rect.maxY),
            CGPoint(x: rect.midX, y: rect.maxY),
            CGPoint(x: rect.maxX, y: rect.maxY)
        ]
        for (index, point) in points.enumerated() {
            let handle = handleLayers[index]
            handle.isHidden = false
            handle.frame = CGRect(
                x: point.x - handleSize / 2,
                y: point.y - handleSize / 2,
                width: handleSize,
                height: handleSize
            )
        }

        let w = Int(rect.width.rounded())
        let h = Int(rect.height.rounded())
        sizeLabel.stringValue = "\(w) × \(h)"
        toolbar.isHidden = false
        hintLabel.isHidden = true
        layoutChrome()
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
