import Foundation
import CoreImage
import CoreVideo
import Metal

/// Metal-backed compositor: screen frame + optional latched webcam → PiP composite.
///
/// Webcam is **center-cropped to square before** any circular mask (TRD §1.3 /
/// M4) so round PiP never becomes an oval.
final class Compositor: @unchecked Sendable {

    private let ciContext: CIContext
    private var pixelBufferPool: CVPixelBufferPool?
    private var poolWidth: Int = 0
    private var poolHeight: Int = 0

    var pipSettings: PiPSettings

    /// Border color when `pipSettings.showBorder` is true.
    var borderColor: CIColor = CIColor(red: 1, green: 1, blue: 1, alpha: 0.9)
    var borderWidthFraction: CGFloat = 0.04 // relative to PiP size

    init(pipSettings: PiPSettings = PiPSettings()) {
        self.pipSettings = pipSettings

        if let device = MTLCreateSystemDefaultDevice() {
            ciContext = CIContext(mtlDevice: device, options: [
                .cacheIntermediates: false,
                .priorityRequestLow: false
            ])
        } else {
            ciContext = CIContext(options: [.useSoftwareRenderer: false])
        }
    }

    // MARK: - Public API

    /// Composite `screen` with optional `webcam` PiP. Returns a buffer from the
    /// internal `CVPixelBufferPool` (no per-frame allocation after warm-up).
    func composite(screen: CVPixelBuffer, webcam: CVPixelBuffer?) throws -> CVPixelBuffer {
        let width = CVPixelBufferGetWidth(screen)
        let height = CVPixelBufferGetHeight(screen)
        try ensurePool(width: width, height: height)

        guard let pool = pixelBufferPool else {
            throw CompositorError.poolUnavailable
        }

        var output: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &output)
        guard status == kCVReturnSuccess, let output else {
            throw CompositorError.pixelBufferAllocationFailed
        }

        let screenImage = CIImage(cvPixelBuffer: screen)
        var result = screenImage

        if let webcam {
            result = overlayPiP(webcam: webcam, onto: result, frameWidth: width, frameHeight: height)
        }

        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        ciContext.render(
            result,
            to: output,
            bounds: bounds,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        return output
    }

    /// Tear down the pool (e.g. on resolution change between sessions).
    func resetPool() {
        pixelBufferPool = nil
        poolWidth = 0
        poolHeight = 0
    }

    // MARK: - PiP geometry

    private func overlayPiP(
        webcam: CVPixelBuffer,
        onto screen: CIImage,
        frameWidth: Int,
        frameHeight: Int
    ) -> CIImage {
        let settings = pipSettings
        let frameW = CGFloat(frameWidth)
        let frameH = CGFloat(frameHeight)

        // Sized off frame height, not width: on an ultra-wide capture (e.g. a
        // 3440×1440 display) 20% of width is ~48% of height, so the webcam
        // bubble ballooned far past the intended size. Height keeps it a
        // consistent fraction of the visible picture regardless of aspect ratio.
        let pipSize = frameH * CGFloat(settings.sizePercent / 100)
        let inset = frameH * CGFloat(settings.edgeInsetFraction)

        // Center-crop webcam to square *before* circular mask.
        let cropped = centerCropToSquare(CIImage(cvPixelBuffer: webcam))
        let scaled = cropped.transformed(
            by: CGAffineTransform(
                scaleX: pipSize / cropped.extent.width,
                y: pipSize / cropped.extent.height
            )
        )

        var pip = scaled.transformed(
            by: CGAffineTransform(
                translationX: -scaled.extent.origin.x,
                y: -scaled.extent.origin.y
            )
        )

        // Mask
        if settings.circularMask {
            pip = applyCircularMask(to: pip, size: pipSize)
        } else if settings.cornerRadius > 0 {
            pip = applyRoundedRectMask(to: pip, size: pipSize, radius: CGFloat(settings.cornerRadius))
        }

        if settings.showBorder {
            pip = applyBorder(to: pip, size: pipSize, circular: settings.circularMask)
        }

        let origin = pipOrigin(
            corner: settings.corner,
            pipSize: pipSize,
            frameWidth: frameW,
            frameHeight: frameH,
            inset: inset
        )

        let placed = pip.transformed(by: CGAffineTransform(translationX: origin.x, y: origin.y))
        return placed.composited(over: screen)
    }

    /// Center-crop to the largest square contained in the image.
    func centerCropToSquare(_ image: CIImage) -> CIImage {
        let extent = image.extent
        let side = min(extent.width, extent.height)
        let x = extent.midX - side / 2
        let y = extent.midY - side / 2
        let square = CGRect(x: x, y: y, width: side, height: side)
        return image.cropped(to: square)
            .transformed(by: CGAffineTransform(translationX: -square.origin.x, y: -square.origin.y))
    }

    private func applyCircularMask(to image: CIImage, size: CGFloat) -> CIImage {
        let radius = size / 2
        let center = CIVector(x: radius, y: radius)
        guard let filter = CIFilter(name: "CIRadialGradient") else { return image }
        filter.setValue(center, forKey: kCIInputCenterKey)
        filter.setValue(radius - 0.5, forKey: "inputRadius0")
        filter.setValue(radius, forKey: "inputRadius1")
        filter.setValue(CIColor(red: 1, green: 1, blue: 1, alpha: 1), forKey: "inputColor0")
        filter.setValue(CIColor(red: 0, green: 0, blue: 0, alpha: 0), forKey: "inputColor1")

        guard let mask = filter.outputImage?.cropped(to: CGRect(x: 0, y: 0, width: size, height: size)) else {
            return image
        }
        return image.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(),
            kCIInputMaskImageKey: mask
        ])
    }

    private func applyRoundedRectMask(to image: CIImage, size: CGFloat, radius: CGFloat) -> CIImage {
        // Approximate rounded rect with a generated mask via CIRoundedRectangleGenerator if available,
        // otherwise fall back to a soft radial for very large radius.
        if let generator = CIFilter(name: "CIRoundedRectangleGenerator") {
            generator.setValue(CIVector(x: 0, y: 0, z: size, w: size), forKey: "inputExtent")
            generator.setValue(radius, forKey: "inputRadius")
            generator.setValue(CIColor.white, forKey: "inputColor")
            if let mask = generator.outputImage {
                return image.applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputBackgroundImageKey: CIImage.empty(),
                    kCIInputMaskImageKey: mask
                ])
            }
        }
        return image
    }

    private func applyBorder(to image: CIImage, size: CGFloat, circular: Bool) -> CIImage {
        let borderW = max(2, size * borderWidthFraction)
        let outerSize = size
        // Draw a slightly larger solid shape behind the PiP as a border ring.
        let expand = borderW
        if circular {
            let diameter = outerSize
            let radius = diameter / 2
            let center = CIVector(x: radius, y: radius)
            // Solid disc the same size as the (already circularly-masked) pip, sitting
            // behind it. CIRadialGradient's output isn't transparent past inputRadius1 —
            // it keeps painting inputColor1 to infinity — so without masking that away
            // ourselves, this "disc" filled the entire square canvas with opaque
            // borderColor, i.e. the white rectangle behind the webcam bubble.
            guard let gradient = CIFilter(name: "CIRadialGradient") else { return image }
            gradient.setValue(center, forKey: kCIInputCenterKey)
            gradient.setValue(radius - 0.5, forKey: "inputRadius0")
            gradient.setValue(radius, forKey: "inputRadius1")
            gradient.setValue(CIColor(red: 1, green: 1, blue: 1, alpha: 1), forKey: "inputColor0")
            gradient.setValue(CIColor(red: 0, green: 0, blue: 0, alpha: 0), forKey: "inputColor1")
            guard let discMask = gradient.outputImage?.cropped(to: CGRect(x: 0, y: 0, width: diameter, height: diameter)) else {
                return image
            }
            let solidColor = CIImage(color: borderColor).cropped(to: CGRect(x: 0, y: 0, width: diameter, height: diameter))
            let disc = solidColor.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: CIImage.empty(),
                kCIInputMaskImageKey: discMask
            ])
            return image.composited(over: disc)
        } else {
            let rect = CIImage(color: borderColor)
                .cropped(to: CGRect(x: -expand, y: -expand, width: size + expand * 2, height: size + expand * 2))
                .transformed(by: CGAffineTransform(translationX: expand, y: expand))
            let insetImage = image.transformed(by: CGAffineTransform(translationX: expand, y: expand))
            return insetImage.composited(over: rect)
                .cropped(to: CGRect(x: 0, y: 0, width: size + expand * 2, height: size + expand * 2))
                .transformed(by: CGAffineTransform(translationX: -expand, y: -expand))
        }
    }

    /// CIImage uses bottom-left origin; `PiPCorner` is expressed in that space
    /// (top* = high Y, bottom* = low Y).
    func pipOrigin(
        corner: PiPCorner,
        pipSize: CGFloat,
        frameWidth: CGFloat,
        frameHeight: CGFloat,
        inset: CGFloat
    ) -> CGPoint {
        switch corner {
        case .bottomLeft:
            return CGPoint(x: inset, y: inset)
        case .bottomRight:
            return CGPoint(x: frameWidth - pipSize - inset, y: inset)
        case .topLeft:
            return CGPoint(x: inset, y: frameHeight - pipSize - inset)
        case .topRight:
            return CGPoint(x: frameWidth - pipSize - inset, y: frameHeight - pipSize - inset)
        }
    }

    // MARK: - Pool

    private func ensurePool(width: Int, height: Int) throws {
        if pixelBufferPool != nil, poolWidth == width, poolHeight == height {
            return
        }

        pixelBufferPool = nil
        poolWidth = width
        poolHeight = height

        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]

        let poolAttrs: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: 3
        ]

        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttrs as CFDictionary,
            attrs as CFDictionary,
            &pool
        )
        guard status == kCVReturnSuccess, let pool else {
            throw CompositorError.poolCreationFailed(status)
        }
        pixelBufferPool = pool
    }
}

enum CompositorError: Error, LocalizedError {
    case poolUnavailable
    case poolCreationFailed(CVReturn)
    case pixelBufferAllocationFailed

    var errorDescription: String? {
        switch self {
        case .poolUnavailable:
            return "Compositor pixel buffer pool is unavailable"
        case .poolCreationFailed(let code):
            return "Compositor failed to create CVPixelBufferPool (CVReturn \(code))"
        case .pixelBufferAllocationFailed:
            return "Compositor failed to allocate a pixel buffer from the pool"
        }
    }
}
