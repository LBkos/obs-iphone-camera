import AVFoundation
import os

/// Captures frames from a built-in camera.
final class CameraCaptureService: NSObject, VideoFrameSource, @unchecked Sendable {
    let session = AVCaptureSession()
    var frameHandler: ((CVPixelBuffer, CMTime) -> Void)?

    private let sessionQueue = DispatchQueue(label: "com.obscamera.camera.session")
    private let outputQueue = DispatchQueue(label: "com.obscamera.camera.output", qos: .userInteractive)
    private let videoOutput = AVCaptureVideoDataOutput()
    private var currentInput: AVCaptureDeviceInput?
    private let logger = Logger(subsystem: "com.obscamera.app", category: "Camera")

    static func isAvailable(for kind: VideoSourceKind) -> Bool {
        device(for: kind) != nil
    }

    private static func device(for kind: VideoSourceKind) -> AVCaptureDevice? {
        switch kind {
        case .backCamera:
            AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        case .frontCamera:
            AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
        case .testPattern:
            nil
        }
    }

    func start(with settings: StreamSettings) {
        sessionQueue.async { [self] in
            configure(settings)
            if !session.isRunning {
                session.startRunning()
            }
        }
    }

    func stop() {
        sessionQueue.async { [self] in
            if session.isRunning {
                session.stopRunning()
            }
        }
    }

    // MARK: - Configuration (session queue)

    private func configure(_ settings: StreamSettings) {
        guard let device = Self.device(for: settings.source) else {
            logger.error("No camera for source \(settings.source.rawValue, privacy: .public)")
            return
        }

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        if currentInput?.device != device {
            if let currentInput {
                session.removeInput(currentInput)
            }
            do {
                let input = try AVCaptureDeviceInput(device: device)
                if session.canAddInput(input) {
                    session.addInput(input)
                    currentInput = input
                }
            } catch {
                logger.error("Failed to create camera input: \(error.localizedDescription, privacy: .public)")
                return
            }
        }

        if !session.outputs.contains(videoOutput) {
            videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            ]
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.setSampleBufferDelegate(self, queue: outputQueue)
            if session.canAddOutput(videoOutput) {
                session.addOutput(videoOutput)
            }
        }

        if !applyFormat(device: device, settings: settings) {
            // Fallback: preset at the device's default frame rate.
            session.sessionPreset = session.canSetSessionPreset(settings.resolution.sessionPreset)
                ? settings.resolution.sessionPreset : .high
        }

        if let connection = videoOutput.connection(with: .video) {
            if connection.isVideoRotationAngleSupported(settings.orientation.rotationAngle) {
                connection.videoRotationAngle = settings.orientation.rotationAngle
            }
            if connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = .off // stabilization adds latency
            }
        }
    }

    /// Picks a device format matching resolution and frame rate.
    private func applyFormat(device: AVCaptureDevice, settings: StreamSettings) -> Bool {
        let target = settings.resolution.landscapeSize
        let fps = Double(settings.frameRate)
        let format = device.formats.first { format in
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let subtype = CMFormatDescriptionGetMediaSubType(format.formatDescription)
            return dims.width == target.width && dims.height == target.height
                && subtype == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                && format.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= fps }
        }
        guard let format else {
            logger.warning("No camera format for \(target.width)x\(target.height)@\(settings.frameRate)")
            return false
        }

        session.sessionPreset = .inputPriority
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.activeFormat = format
            let duration = CMTime(value: 1, timescale: CMTimeScale(settings.frameRate))
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            return true
        } catch {
            logger.error("Failed to lock camera for configuration: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}

extension CameraCaptureService: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        frameHandler?(pixelBuffer, CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }
}
