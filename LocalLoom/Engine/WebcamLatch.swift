import Foundation
import CoreVideo
import os

/// Lock-protected latest-frame latch for the webcam.
///
/// The `AVCaptureSession` delegate writes every incoming frame here; the
/// compositor reads whatever is currently latched when a screen frame arrives.
/// No queue, no timestamp matching, no wait — webcam is never a clock source
/// (TRD §1.2).
final class WebcamLatch: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<CVPixelBuffer?>(initialState: nil)

    /// Store the newest webcam frame (retains the pixel buffer).
    func store(_ buffer: CVPixelBuffer) {
        lock.withLock { slot in
            slot = buffer
        }
    }

    /// Current latched frame, or `nil` if none yet / cleared.
    func current() -> CVPixelBuffer? {
        lock.withLock { $0 }
    }

    /// Drop the latched frame (e.g. on stop / webcam disabled).
    func clear() {
        lock.withLock { slot in
            slot = nil
        }
    }
}
