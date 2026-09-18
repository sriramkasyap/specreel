import SwiftUI
import AppKit
import AVFoundation

/// Live `AVCaptureSession` preview for the selected camera.
/// Any hosting window must use `sharingType = .none` so the preview never
/// appears inside the recording (Trap #8).
struct WebcamPreviewView: View {
    var deviceID: String?

    var body: some View {
        WebcamPreviewRepresentable(deviceID: deviceID)
            .background(WindowSharingTypeNoneSetter())
    }
}

// MARK: - AppKit preview layer

private struct WebcamPreviewRepresentable: NSViewRepresentable {
    var deviceID: String?

    func makeNSView(context: Context) -> WebcamPreviewNSView {
        let view = WebcamPreviewNSView()
        view.configure(deviceID: deviceID)
        return view
    }

    func updateNSView(_ nsView: WebcamPreviewNSView, context: Context) {
        nsView.configure(deviceID: deviceID)
    }

    static func dismantleNSView(_ nsView: WebcamPreviewNSView, coordinator: ()) {
        nsView.teardown()
    }
}

final class WebcamPreviewNSView: NSView {
    private let session = AVCaptureSession()
    private let previewLayer = AVCaptureVideoPreviewLayer()
    private var currentDeviceID: String?
    private var isConfigured = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.session = session
        layer = previewLayer
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(deviceID: String?) {
        if deviceID == currentDeviceID, isConfigured { return }
        currentDeviceID = deviceID

        session.beginConfiguration()
        for input in session.inputs {
            session.removeInput(input)
        }

        let device: AVCaptureDevice? = {
            if let deviceID,
               let match = AVCaptureDevice(uniqueID: deviceID)
            {
                return match
            }
            return AVCaptureDevice.default(for: .video)
        }()

        if let device,
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input)
        {
            session.addInput(input)
            isConfigured = true
        } else {
            isConfigured = false
        }

        session.commitConfiguration()

        if isConfigured, !session.isRunning {
            DispatchQueue.global(qos: .userInitiated).async { [session] in
                session.startRunning()
            }
        }
    }

    func teardown() {
        if session.isRunning {
            session.stopRunning()
        }
        session.beginConfiguration()
        for input in session.inputs {
            session.removeInput(input)
        }
        session.commitConfiguration()
        isConfigured = false
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.sharingType = .none
    }
}

// MARK: - Ensure hosting window is excluded from ScreenCaptureKit

private struct WindowSharingTypeNoneSetter: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = SharingTypeProbeView()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.window?.sharingType = .none
    }
}

private final class SharingTypeProbeView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.sharingType = .none
    }
}
