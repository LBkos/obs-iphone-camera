import AVFoundation
import SwiftUI

/// Live camera preview backed by `AVCaptureVideoPreviewLayer`.
/// Tap focuses, pinch zooms.
struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    let rotationAngle: CGFloat
    /// Matches the video sent to OBS, so the preview shows exactly what is streamed.
    var isMirrored = false
    /// False stops drawing the preview (black screen) without stopping the capture.
    var isEnabled = true
    /// Device point (for the camera) and view point (for the indicator).
    var onTap: ((CGPoint, CGPoint) -> Void)?
    /// Pinch scale relative to its start; nil when the pinch ends.
    var onPinch: ((CGFloat?) -> Void)?

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspect
        view.backgroundColor = .black
        view.addGestureRecognizer(UITapGestureRecognizer(target: view, action: #selector(PreviewUIView.handleTap)))
        view.addGestureRecognizer(UIPinchGestureRecognizer(target: view, action: #selector(PreviewUIView.handlePinch)))
        return view
    }

    func updateUIView(_ view: PreviewUIView, context: Context) {
        view.rotationAngle = rotationAngle
        view.isMirrored = isMirrored
        view.isPreviewEnabled = isEnabled
        view.onTap = onTap
        view.onPinch = onPinch
        view.applyConnectionSettings()
    }

    final class PreviewUIView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        var rotationAngle: CGFloat = 0
        var isMirrored = false
        var isPreviewEnabled = true
        var onTap: ((CGPoint, CGPoint) -> Void)?
        var onPinch: ((CGFloat?) -> Void)?

        override func layoutSubviews() {
            super.layoutSubviews()
            applyConnectionSettings() // the connection appears once the session starts
        }

        func applyConnectionSettings() {
            guard let connection = previewLayer.connection else { return }
            if connection.isVideoRotationAngleSupported(rotationAngle) {
                connection.videoRotationAngle = rotationAngle
            }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                if connection.isVideoMirrored != isMirrored {
                    connection.isVideoMirrored = isMirrored
                }
            }
            if connection.isEnabled != isPreviewEnabled {
                connection.isEnabled = isPreviewEnabled
            }
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            let point = recognizer.location(in: self)
            onTap?(previewLayer.captureDevicePointConverted(fromLayerPoint: point), point)
        }

        @objc func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            switch recognizer.state {
            case .began, .changed:
                onPinch?(recognizer.scale)
            default:
                onPinch?(nil)
            }
        }
    }
}
