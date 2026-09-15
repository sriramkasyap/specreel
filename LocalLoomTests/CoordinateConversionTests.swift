import CoreGraphics
import XCTest
@testable import LocalLoom

/// Exhaustive coordinate-space tests (TRD Trap 3 / §7).
///
/// Three spaces:
/// 1. **NSScreen** — bottom-left origin, global (main-display-relative) points
/// 2. **sourceRect** (`SCStreamConfiguration`) — top-left origin, display-local points
/// 3. **Pixels** — top-left origin, display-local, × backingScaleFactor
///
/// Expected production API:
/// ```
/// enum CoordinateConversion {
///   struct DisplayGeometry: Equatable {
///     var frame: CGRect          // NSScreen.frame (global points, bottom-left origin)
///     var scaleFactor: CGFloat   // backingScaleFactor
///   }
///
///   static func sourceRect(
///     fromNSScreenRegion region: CGRect,
///     on display: DisplayGeometry
///   ) -> CGRect
///
///   static func nsScreenRegion(
///     fromSourceRect sourceRect: CGRect,
///     on display: DisplayGeometry
///   ) -> CGRect
///
///   static func pixelRect(
///     fromSourceRect sourceRect: CGRect,
///     scaleFactor: CGFloat
///   ) -> CGRect
///
///   static func sourceRect(
///     fromPixelRect pixelRect: CGRect,
///     scaleFactor: CGFloat
///   ) -> CGRect
/// }
/// ```
final class CoordinateConversionTests: XCTestCase {

    private let accuracy: CGFloat = 0.001

    // MARK: - Fixtures

    /// Main display: origin (0,0), 1920×1080 points, 1×.
    private let main1x = CoordinateConversion.DisplayGeometry(
        frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        scaleFactor: 1.0
    )

    /// Main display: origin (0,0), 1440×900 points, 2× (typical Retina laptop).
    private let main2x = CoordinateConversion.DisplayGeometry(
        frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        scaleFactor: 2.0
    )

    /// Non-main to the right of main1x: origin (1920, 0), 1920×1080, 1×.
    private let secondaryRight1x = CoordinateConversion.DisplayGeometry(
        frame: CGRect(x: 1920, y: 0, width: 1920, height: 1080),
        scaleFactor: 1.0
    )

    /// Non-main above main2x: origin (0, 900), 1280×800, 1× (non-2× secondary).
    private let secondaryAbove1x = CoordinateConversion.DisplayGeometry(
        frame: CGRect(x: 0, y: 900, width: 1280, height: 800),
        scaleFactor: 1.0
    )

    /// Non-main to the left of main, partially below: origin (−1680, −200), 1680×1050, 1×.
    private let secondaryLeft1x = CoordinateConversion.DisplayGeometry(
        frame: CGRect(x: -1680, y: -200, width: 1680, height: 1050),
        scaleFactor: 1.0
    )

    /// Non-main Retina secondary: origin (1440, 0), 1920×1080 points @ 2×.
    private let secondaryRight2x = CoordinateConversion.DisplayGeometry(
        frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080),
        scaleFactor: 2.0
    )

    private func assertRectEqual(
        _ actual: CGRect,
        _ expected: CGRect,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.origin.x, expected.origin.x, accuracy: accuracy, "origin.x", file: file, line: line)
        XCTAssertEqual(actual.origin.y, expected.origin.y, accuracy: accuracy, "origin.y", file: file, line: line)
        XCTAssertEqual(actual.size.width, expected.size.width, accuracy: accuracy, "width", file: file, line: line)
        XCTAssertEqual(actual.size.height, expected.size.height, accuracy: accuracy, "height", file: file, line: line)
    }

    // MARK: - NSScreen → sourceRect (main, 1×)

    func testMain1x_fullDisplay_nsScreenToSourceRect() {
        let ns = main1x.frame
        let source = CoordinateConversion.sourceRect(fromNSScreenRegion: ns, on: main1x)
        assertRectEqual(source, CGRect(x: 0, y: 0, width: 1920, height: 1080))
    }

    func testMain1x_topLeft100x100_nsScreenToSourceRect() {
        // NSScreen: bottom-left origin. Top-left 100×100 region starts at y = 1080−100 = 980.
        let ns = CGRect(x: 0, y: 980, width: 100, height: 100)
        let source = CoordinateConversion.sourceRect(fromNSScreenRegion: ns, on: main1x)
        assertRectEqual(source, CGRect(x: 0, y: 0, width: 100, height: 100))
    }

    func testMain1x_bottomLeft100x100_nsScreenToSourceRect() {
        let ns = CGRect(x: 0, y: 0, width: 100, height: 100)
        let source = CoordinateConversion.sourceRect(fromNSScreenRegion: ns, on: main1x)
        assertRectEqual(source, CGRect(x: 0, y: 980, width: 100, height: 100))
    }

    func testMain1x_centerRegion_nsScreenToSourceRect() {
        let ns = CGRect(x: 460, y: 290, width: 1000, height: 500)
        let source = CoordinateConversion.sourceRect(fromNSScreenRegion: ns, on: main1x)
        // Flip Y: sourceY = displayHeight − (nsY − displayOriginY) − height
        //        = 1080 − 290 − 500 = 290
        assertRectEqual(source, CGRect(x: 460, y: 290, width: 1000, height: 500))
    }

    // MARK: - NSScreen → sourceRect (main, 2×)

    func testMain2x_fullDisplay_nsScreenToSourceRect() {
        let source = CoordinateConversion.sourceRect(fromNSScreenRegion: main2x.frame, on: main2x)
        assertRectEqual(source, CGRect(x: 0, y: 0, width: 1440, height: 900))
    }

    func testMain2x_topLeftRegion_nsScreenToSourceRect() {
        // Top-left 200×100 in points: NS y = 900 − 100 = 800
        let ns = CGRect(x: 0, y: 800, width: 200, height: 100)
        let source = CoordinateConversion.sourceRect(fromNSScreenRegion: ns, on: main2x)
        assertRectEqual(source, CGRect(x: 0, y: 0, width: 200, height: 100))
    }

    // MARK: - NSScreen → sourceRect (non-main)

    func testSecondaryRight1x_fullDisplay_nsScreenToSourceRect() {
        let source = CoordinateConversion.sourceRect(
            fromNSScreenRegion: secondaryRight1x.frame,
            on: secondaryRight1x
        )
        assertRectEqual(source, CGRect(x: 0, y: 0, width: 1920, height: 1080))
    }

    func testSecondaryRight1x_localTopLeft_nsScreenToSourceRect() {
        // Global NS region for top-left 80×60 on secondary: x=1920, y=1080−60=1020
        let ns = CGRect(x: 1920, y: 1020, width: 80, height: 60)
        let source = CoordinateConversion.sourceRect(fromNSScreenRegion: ns, on: secondaryRight1x)
        assertRectEqual(source, CGRect(x: 0, y: 0, width: 80, height: 60))
    }

    func testSecondaryAbove1x_region_nsScreenToSourceRect() {
        // Region mid-display: local (100, 200, 400, 300) in sourceRect (top-left).
        // NS: x = 0+100 = 100
        //     y = 900 + (800 − 200 − 300) = 1200
        let ns = CGRect(x: 100, y: 1200, width: 400, height: 300)
        let source = CoordinateConversion.sourceRect(fromNSScreenRegion: ns, on: secondaryAbove1x)
        assertRectEqual(source, CGRect(x: 100, y: 200, width: 400, height: 300))
    }

    func testSecondaryLeft1x_region_nsScreenToSourceRect() {
        // Local sourceRect (50, 100, 200, 150)
        // NS x = −1680 + 50 = −1630
        // NS y = −200 + (1050 − 100 − 150) = 600
        let ns = CGRect(x: -1630, y: 600, width: 200, height: 150)
        let source = CoordinateConversion.sourceRect(fromNSScreenRegion: ns, on: secondaryLeft1x)
        assertRectEqual(source, CGRect(x: 50, y: 100, width: 200, height: 150))
    }

    func testSecondaryRight2x_region_nsScreenToSourceRect() {
        // Local sourceRect (10, 20, 300, 200) on 2× secondary
        // NS x = 1440 + 10 = 1450
        // NS y = 0 + (1080 − 20 − 200) = 860
        let ns = CGRect(x: 1450, y: 860, width: 300, height: 200)
        let source = CoordinateConversion.sourceRect(fromNSScreenRegion: ns, on: secondaryRight2x)
        assertRectEqual(source, CGRect(x: 10, y: 20, width: 300, height: 200))
    }

    // MARK: - sourceRect → NSScreen (round-trip)

    func testRoundTrip_main1x() {
        let regions = [
            CGRect(x: 0, y: 0, width: 1920, height: 1080),
            CGRect(x: 10, y: 20, width: 100, height: 50),
            CGRect(x: 500, y: 400, width: 800, height: 600),
        ]
        for source in regions {
            let ns = CoordinateConversion.nsScreenRegion(fromSourceRect: source, on: main1x)
            let back = CoordinateConversion.sourceRect(fromNSScreenRegion: ns, on: main1x)
            assertRectEqual(back, source)
        }
    }

    func testRoundTrip_main2x() {
        let source = CGRect(x: 100, y: 50, width: 640, height: 360)
        let ns = CoordinateConversion.nsScreenRegion(fromSourceRect: source, on: main2x)
        let back = CoordinateConversion.sourceRect(fromNSScreenRegion: ns, on: main2x)
        assertRectEqual(back, source)
    }

    func testRoundTrip_secondaryRight1x() {
        let source = CGRect(x: 200, y: 150, width: 400, height: 300)
        let ns = CoordinateConversion.nsScreenRegion(fromSourceRect: source, on: secondaryRight1x)
        let back = CoordinateConversion.sourceRect(fromNSScreenRegion: ns, on: secondaryRight1x)
        assertRectEqual(back, source)
    }

    func testRoundTrip_secondaryLeft1x() {
        let source = CGRect(x: 0, y: 0, width: 1680, height: 1050)
        let ns = CoordinateConversion.nsScreenRegion(fromSourceRect: source, on: secondaryLeft1x)
        assertRectEqual(ns, secondaryLeft1x.frame)
        let back = CoordinateConversion.sourceRect(fromNSScreenRegion: ns, on: secondaryLeft1x)
        assertRectEqual(back, source)
    }

    func testRoundTrip_secondaryAbove1x_non2xScale() {
        // Explicit non-main + non-2× fixture — the M2 trap case.
        let source = CGRect(x: 40, y: 60, width: 320, height: 240)
        let ns = CoordinateConversion.nsScreenRegion(fromSourceRect: source, on: secondaryAbove1x)
        let back = CoordinateConversion.sourceRect(fromNSScreenRegion: ns, on: secondaryAbove1x)
        assertRectEqual(back, source)
    }

    // MARK: - sourceRect → pixels

    func testPixelRect_1x_identityScale() {
        let source = CGRect(x: 10, y: 20, width: 100, height: 50)
        let pixels = CoordinateConversion.pixelRect(fromSourceRect: source, scaleFactor: 1.0)
        assertRectEqual(pixels, source)
    }

    func testPixelRect_2x_doublesAllAxes() {
        let source = CGRect(x: 10, y: 20, width: 100, height: 50)
        let pixels = CoordinateConversion.pixelRect(fromSourceRect: source, scaleFactor: 2.0)
        assertRectEqual(pixels, CGRect(x: 20, y: 40, width: 200, height: 100))
    }

    func testPixelRect_main2x_fullDisplay() {
        let source = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let pixels = CoordinateConversion.pixelRect(
            fromSourceRect: source,
            scaleFactor: main2x.scaleFactor
        )
        assertRectEqual(pixels, CGRect(x: 0, y: 0, width: 2880, height: 1800))
    }

    func testPixelRect_secondary1x_unchanged() {
        let source = CGRect(x: 100, y: 200, width: 400, height: 300)
        let pixels = CoordinateConversion.pixelRect(
            fromSourceRect: source,
            scaleFactor: secondaryAbove1x.scaleFactor
        )
        assertRectEqual(pixels, source)
    }

    func testPixelRect_secondary2x() {
        let source = CGRect(x: 10, y: 20, width: 300, height: 200)
        let pixels = CoordinateConversion.pixelRect(
            fromSourceRect: source,
            scaleFactor: secondaryRight2x.scaleFactor
        )
        assertRectEqual(pixels, CGRect(x: 20, y: 40, width: 600, height: 400))
    }

    // MARK: - pixels → sourceRect (round-trip)

    func testPixelRoundTrip_1x() {
        let source = CGRect(x: 5, y: 10, width: 200, height: 100)
        let pixels = CoordinateConversion.pixelRect(fromSourceRect: source, scaleFactor: 1.0)
        let back = CoordinateConversion.sourceRect(fromPixelRect: pixels, scaleFactor: 1.0)
        assertRectEqual(back, source)
    }

    func testPixelRoundTrip_2x() {
        let source = CGRect(x: 12.5, y: 7.5, width: 100, height: 50)
        let pixels = CoordinateConversion.pixelRect(fromSourceRect: source, scaleFactor: 2.0)
        let back = CoordinateConversion.sourceRect(fromPixelRect: pixels, scaleFactor: 2.0)
        assertRectEqual(back, source)
    }

    // MARK: - Full pipeline: NSScreen → sourceRect → pixels

    func testFullPipeline_main1x() {
        let ns = CGRect(x: 100, y: 200, width: 400, height: 300)
        let source = CoordinateConversion.sourceRect(fromNSScreenRegion: ns, on: main1x)
        let pixels = CoordinateConversion.pixelRect(fromSourceRect: source, scaleFactor: main1x.scaleFactor)
        // source Y flip: 1080 − 200 − 300 = 580
        assertRectEqual(source, CGRect(x: 100, y: 580, width: 400, height: 300))
        assertRectEqual(pixels, source) // 1×
    }

    func testFullPipeline_main2x() {
        // Top-left 200×100 region on Retina main
        let ns = CGRect(x: 0, y: 800, width: 200, height: 100)
        let source = CoordinateConversion.sourceRect(fromNSScreenRegion: ns, on: main2x)
        let pixels = CoordinateConversion.pixelRect(fromSourceRect: source, scaleFactor: main2x.scaleFactor)
        assertRectEqual(source, CGRect(x: 0, y: 0, width: 200, height: 100))
        assertRectEqual(pixels, CGRect(x: 0, y: 0, width: 400, height: 200))
    }

    func testFullPipeline_secondaryNonMainNon2x() {
        let ns = CGRect(x: 100, y: 1200, width: 400, height: 300)
        let source = CoordinateConversion.sourceRect(fromNSScreenRegion: ns, on: secondaryAbove1x)
        let pixels = CoordinateConversion.pixelRect(
            fromSourceRect: source,
            scaleFactor: secondaryAbove1x.scaleFactor
        )
        assertRectEqual(source, CGRect(x: 100, y: 200, width: 400, height: 300))
        assertRectEqual(pixels, CGRect(x: 100, y: 200, width: 400, height: 300))
    }

    func testFullPipeline_secondaryRight2x() {
        let ns = CGRect(x: 1450, y: 860, width: 300, height: 200)
        let source = CoordinateConversion.sourceRect(fromNSScreenRegion: ns, on: secondaryRight2x)
        let pixels = CoordinateConversion.pixelRect(
            fromSourceRect: source,
            scaleFactor: secondaryRight2x.scaleFactor
        )
        assertRectEqual(source, CGRect(x: 10, y: 20, width: 300, height: 200))
        assertRectEqual(pixels, CGRect(x: 20, y: 40, width: 600, height: 400))
    }
}
