import Foundation
import AppKit
import CoreGraphics

/// Pure coordinate conversion between the three frames of reference involved in
/// region capture (TRD Trap 3).
///
/// # The three spaces
///
/// 1. **NSScreen point space**
///    - Origin: **bottom-left** of the **main** display
///    - Unit: points (not pixels)
///    - Global across the desktop: secondary displays sit to the left/right/above/below
///      of main, so their `NSScreen.frame.origin` can be negative or > main width.
///    - This is what `NSEvent`, drag-selection overlays, and `RegionSelector` produce.
///
/// 2. **SCStreamConfiguration.sourceRect space**
///    - Origin: **top-left** of the **captured display** (that display alone — not global)
///    - Unit: points (logical points of that display, same as `SCDisplay.width/height`)
///    - Local to the display being captured. A region on a secondary display must be
///      expressed relative to *that* display's top-left, never relative to main.
///
/// 3. **Pixel space**
///    - Origin: top-left of the captured content (same as SCK after scale)
///    - Unit: physical pixels = points × `backingScaleFactor`
///    - Used when reasoning about encoded frame dimensions / cropping in pixel buffers.
///
/// # Why this matters
///
/// A conversion that "looks right" on a single main Retina (2×) display will silently
/// mis-crop on a secondary 1× display or any non-main arrangement. Always convert
/// through this utility; never hand-roll Y-flips inline at call sites.
///
/// # Typical pipeline for region capture
///
/// ```
/// NSScreen drag rect  →  sourceRectInDisplayPoints(...)  →  SCStreamConfiguration.sourceRect
///                     →  pixelRect(...)                  →  (debug / pixel assertions)
/// ```
enum CoordinateConversion {

    // MARK: - DisplayGeometry

    /// Fixture-friendly description of a display for conversion purposes.
    struct DisplayGeometry: Equatable {
        /// The display's `NSScreen.frame` in global bottom-left points.
        var frame: CGRect
        /// Backing scale factor (1.0 for standard, 2.0 for Retina).
        var scaleFactor: CGFloat

        public init(frame: CGRect, scaleFactor: CGFloat) {
            self.frame = frame
            self.scaleFactor = scaleFactor
        }
    }

    // MARK: - NSScreen → SCStream sourceRect

    /// Convert a rectangle from global NSScreen point space into an
    /// `SCStreamConfiguration.sourceRect` for a specific display.
    ///
    /// - Parameters:
    ///   - rectInNSScreenPoints: Selection in bottom-left / main-relative points
    ///     (e.g. from `RegionSelector`).
    ///   - displayBoundsInNSScreenPoints: That display's `NSScreen.frame` (also
    ///     bottom-left / main-relative). Use the `NSScreen` matching the
    ///     `SCDisplay` you will capture — **not** necessarily `NSScreen.main`.
    /// - Returns: Top-left / display-relative rect in points, ready for
    ///   `SCStreamConfiguration.sourceRect`.
    static func sourceRectInDisplayPoints(
        rectInNSScreenPoints: CGRect,
        displayBoundsInNSScreenPoints: CGRect
    ) -> CGRect {
        // 1. Make the rect relative to the display's bottom-left (still bottom-left origin).
        let localBottomLeft = CGRect(
            x: rectInNSScreenPoints.origin.x - displayBoundsInNSScreenPoints.origin.x,
            y: rectInNSScreenPoints.origin.y - displayBoundsInNSScreenPoints.origin.y,
            width: rectInNSScreenPoints.width,
            height: rectInNSScreenPoints.height
        )

        // 2. Flip Y into top-left origin within the display.
        //    topY = displayHeight - (bottomY + height)
        let flippedY = displayBoundsInNSScreenPoints.height
            - (localBottomLeft.origin.y + localBottomLeft.height)

        return CGRect(
            x: localBottomLeft.origin.x,
            y: flippedY,
            width: localBottomLeft.width,
            height: localBottomLeft.height
        )
    }

    // MARK: - SCStream sourceRect → NSScreen

    /// Inverse of `sourceRectInDisplayPoints` — useful for drawing a highlight
    /// of the active capture region back onto an overlay in NSScreen space.
    static func rectInNSScreenPoints(
        sourceRectInDisplayPoints: CGRect,
        displayBoundsInNSScreenPoints: CGRect
    ) -> CGRect {
        // sourceRect is top-left / display-relative → flip back to bottom-left local,
        // then offset by the display's global origin.
        let localBottomY = displayBoundsInNSScreenPoints.height
            - (sourceRectInDisplayPoints.origin.y + sourceRectInDisplayPoints.height)

        return CGRect(
            x: sourceRectInDisplayPoints.origin.x + displayBoundsInNSScreenPoints.origin.x,
            y: localBottomY + displayBoundsInNSScreenPoints.origin.y,
            width: sourceRectInDisplayPoints.width,
            height: sourceRectInDisplayPoints.height
        )
    }

    // MARK: - Points ↔ pixels

    /// Convert a display-local points rect (either top-left or bottom-left —
    /// scale alone doesn't care about origin) into pixel space.
    static func pixelRect(
        pointRect: CGRect,
        backingScaleFactor: CGFloat
    ) -> CGRect {
        CGRect(
            x: pointRect.origin.x * backingScaleFactor,
            y: pointRect.origin.y * backingScaleFactor,
            width: pointRect.width * backingScaleFactor,
            height: pointRect.height * backingScaleFactor
        )
    }

    /// Convert a pixel-space rect back to points.
    static func pointRect(
        pixelRect: CGRect,
        backingScaleFactor: CGFloat
    ) -> CGRect {
        guard backingScaleFactor > 0 else { return .zero }
        return CGRect(
            x: pixelRect.origin.x / backingScaleFactor,
            y: pixelRect.origin.y / backingScaleFactor,
            width: pixelRect.width / backingScaleFactor,
            height: pixelRect.height / backingScaleFactor
        )
    }

    // MARK: - Display lookup helpers

    /// Find the `NSScreen` whose `deviceDescription["NSScreenNumber"]` matches
    /// a `CGDirectDisplayID` / `SCDisplay.displayID`.
    static func nsScreen(forDisplayID displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { screen in
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            return number?.uint32Value == displayID
        }
    }

    /// Convenience: NSScreen-space rect → SCK `sourceRect` given only a display ID.
    /// Returns `nil` if no matching `NSScreen` is attached (e.g. display unplugged).
    static func sourceRectInDisplayPoints(
        rectInNSScreenPoints: CGRect,
        displayID: CGDirectDisplayID
    ) -> CGRect? {
        guard let screen = nsScreen(forDisplayID: displayID) else { return nil }
        return sourceRectInDisplayPoints(
            rectInNSScreenPoints: rectInNSScreenPoints,
            displayBoundsInNSScreenPoints: screen.frame
        )
    }

    /// Pixel dimensions of a points rect on a given display (uses that screen's scale).
    static func pixelSize(
        pointSize: CGSize,
        displayID: CGDirectDisplayID
    ) -> CGSize {
        let scale = nsScreen(forDisplayID: displayID)?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        return CGSize(width: pointSize.width * scale, height: pointSize.height * scale)
    }

    // MARK: - Clamp

    /// Clamp a display-local top-left sourceRect so it stays inside the display.
    static func clampSourceRect(
        _ rect: CGRect,
        displayWidthPoints: CGFloat,
        displayHeightPoints: CGFloat
    ) -> CGRect {
        var r = rect
        r.origin.x = max(0, min(r.origin.x, displayWidthPoints))
        r.origin.y = max(0, min(r.origin.y, displayHeightPoints))
        r.size.width = max(0, min(r.size.width, displayWidthPoints - r.origin.x))
        r.size.height = max(0, min(r.size.height, displayHeightPoints - r.origin.y))
        return r
    }

    // MARK: - Test API (wraps existing, matches TRD test contract)

    /// NSScreen region → sourceRect, given a `DisplayGeometry`.
    static func sourceRect(fromNSScreenRegion region: CGRect, on display: DisplayGeometry) -> CGRect {
        sourceRectInDisplayPoints(
            rectInNSScreenPoints: region,
            displayBoundsInNSScreenPoints: display.frame
        )
    }

    /// sourceRect → NSScreen region, given a `DisplayGeometry`.
    static func nsScreenRegion(fromSourceRect sourceRect: CGRect, on display: DisplayGeometry) -> CGRect {
        rectInNSScreenPoints(
            sourceRectInDisplayPoints: sourceRect,
            displayBoundsInNSScreenPoints: display.frame
        )
    }

    /// sourceRect → pixels, given a `DisplayGeometry` (uses its scale).
    static func pixelRect(fromSourceRect sourceRect: CGRect, scaleFactor: CGFloat) -> CGRect {
        pixelRect(pointRect: sourceRect, backingScaleFactor: scaleFactor)
    }

    /// pixels → sourceRect.
    static func sourceRect(fromPixelRect pixelRect: CGRect, scaleFactor: CGFloat) -> CGRect {
        pointRect(pixelRect: pixelRect, backingScaleFactor: scaleFactor)
    }
}
