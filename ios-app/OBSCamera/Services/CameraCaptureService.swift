import AVFoundation
import os

/// Captures frames (and optionally microphone audio) from a built-in camera,
/// and applies live camera controls (zoom, focus, exposure, white balance, torch).
final class CameraCaptureService: NSObject, VideoFrameSource, @unchecked Sendable {
    let session = AVCaptureSession()
    var frameHandler: ((CVPixelBuffer, CMTime) -> Void)?
    /// Microphone sample buffers, on the audio queue.
    var audioHandler: ((CMSampleBuffer) -> Void)?
    /// What the active camera supports; on the main queue after each configuration.
    var capabilitiesHandler: ((CameraCapabilities) -> Void)?
    /// Controls changed from outside the app UI (the Camera Control button); on the main queue.
    var controlsChangedHandler: ((CameraControls) -> Void)?

    private let sessionQueue = DispatchQueue(label: "com.obscamera.camera.session")
    private let outputQueue = DispatchQueue(label: "com.obscamera.camera.output", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "com.obscamera.camera.audio", qos: .userInteractive)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let logger = Logger(subsystem: "com.obscamera.app", category: "Camera")

    // Session queue only.
    private var currentInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private var controls = CameraControls()
    private var frameRate = 30
    private var outputPixelFormat: OSType?

    /// For `readings()`, which is called from the main queue.
    private let deviceLock = NSLock()
    private var activeDevice: AVCaptureDevice?

    private static let sdrPixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    private static let hdrPixelFormat = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange

    // MARK: - Device lookup

    static func isAvailable(for kind: VideoSourceKind) -> Bool {
        device(for: kind) != nil
    }

    private static func device(for kind: VideoSourceKind) -> AVCaptureDevice? {
        switch kind {
        case .backCamera:
            AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        case .backUltraWide:
            AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back)
        case .backTelephoto:
            AVCaptureDevice.default(.builtInTelephotoCamera, for: .video, position: .back)
        case .frontCamera:
            AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
        case .testPattern:
            nil
        }
    }

    /// Whether the camera has a format for the chosen resolution and frame rate
    /// (and HLG, when HDR is on). Without one the session falls back to a preset.
    static func supportsFormat(for settings: StreamSettings) -> Bool {
        guard let device = device(for: settings.source) else { return true }
        return bestFormat(device: device, settings: settings, hdr: settings.isHDRActive) != nil
    }

    /// Whether HDR would work with the chosen camera, resolution and frame rate.
    static func supportsHDR(for settings: StreamSettings) -> Bool {
        guard let device = device(for: settings.source) else { return false }
        return bestFormat(device: device, settings: settings, hdr: true) != nil
    }

    private static func bestFormat(device: AVCaptureDevice, settings: StreamSettings,
                                   hdr: Bool) -> AVCaptureDevice.Format? {
        let target = settings.resolution.landscapeSize
        let fps = Double(settings.frameRate)
        let candidates = device.formats.filter { format in
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let subtype = CMFormatDescriptionGetMediaSubType(format.formatDescription)
            guard dims.width == target.width, dims.height == target.height,
                  subtype == (hdr ? hdrPixelFormat : sdrPixelFormat),
                  format.videoSupportedFrameRateRanges.contains(where: {
                      $0.minFrameRate <= fps && fps <= $0.maxFrameRate
                  }) else { return false }
            return !hdr || format.supportedColorSpaces.contains(.HLG_BT2020)
        }
        // Prefer full-sensor (not binned) formats, then the lowest max frame rate
        // that still fits: high-speed formats often have lower image quality.
        return candidates.min { a, b in
            if a.isVideoBinned != b.isVideoBinned { return !a.isVideoBinned }
            return maxFrameRate(a) < maxFrameRate(b)
        }
    }

    private static func maxFrameRate(_ format: AVCaptureDevice.Format) -> Double {
        format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
    }

    // MARK: - VideoFrameSource

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

    // MARK: - Live controls

    func apply(_ controls: CameraControls) {
        sessionQueue.async { [self] in
            self.controls = controls
            applyControls()
        }
    }

    /// Tap to focus / expose at a point in device coordinates ((0,0) top-left, (1,1) bottom-right
    /// of the unrotated sensor image). Only affects the parts that are in auto mode.
    func focus(atDevicePoint devicePoint: CGPoint) {
        // Taps on the letterbox bars land outside the image.
        let point = CGPoint(x: min(max(devicePoint.x, 0), 1), y: min(max(devicePoint.y, 0), 1))
        sessionQueue.async { [self] in
            guard let device = currentInput?.device else { return }
            do {
                try device.lockForConfiguration()
            } catch {
                logger.error("Failed to lock camera for focus: \(error.localizedDescription, privacy: .public)")
                return
            }
            defer { device.unlockForConfiguration() }
            // The point of interest must be set before the mode for it to take effect.
            if controls.focusMode == .auto, device.isFocusPointOfInterestSupported,
               device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusPointOfInterest = point
                device.focusMode = .continuousAutoFocus
            }
            if controls.exposureMode == .auto, device.isExposurePointOfInterestSupported,
               device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposurePointOfInterest = point
                device.exposureMode = .continuousAutoExposure
            }
        }
    }

    /// Current automatic values of the active camera (to start manual mode from them).
    func readings() -> CameraReadings? {
        deviceLock.lock()
        let device = activeDevice
        deviceLock.unlock()
        guard let device else { return nil }
        let gains = device.deviceWhiteBalanceGains
        // temperatureAndTintValues(for:) needs gains in the valid range.
        let maxGain = device.maxWhiteBalanceGain
        let clamped = AVCaptureDevice.WhiteBalanceGains(
            redGain: min(max(gains.redGain, 1), maxGain),
            greenGain: min(max(gains.greenGain, 1), maxGain),
            blueGain: min(max(gains.blueGain, 1), maxGain))
        let whiteBalance = device.temperatureAndTintValues(for: clamped)
        return CameraReadings(
            lensPosition: device.lensPosition,
            iso: device.iso,
            exposureSeconds: CMTimeGetSeconds(device.exposureDuration),
            temperature: whiteBalance.temperature,
            tint: whiteBalance.tint)
    }

    // MARK: - Configuration (session queue)

    private func configure(_ settings: StreamSettings) {
        guard let device = Self.device(for: settings.source) else {
            logger.error("No camera for source \(settings.source.rawValue, privacy: .public)")
            return
        }

        session.beginConfiguration()
        defer {
            session.commitConfiguration()
            // Format changes reset zoom and exposure: re-apply the user's controls.
            applyControls()
            publishCapabilities(device: device)
        }

        // We pick the color space ourselves (sRGB or HLG).
        session.automaticallyConfiguresCaptureDeviceForWideColor = false

        if currentInput?.device != device {
            if let currentInput {
                session.removeInput(currentInput)
                self.currentInput = nil
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
            deviceLock.lock()
            activeDevice = currentInput?.device
            deviceLock.unlock()
        }

        if !session.outputs.contains(videoOutput) {
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.setSampleBufferDelegate(self, queue: outputQueue)
            if session.canAddOutput(videoOutput) {
                session.addOutput(videoOutput)
            }
        }

        configureAudio(enabled: settings.audioEnabled)

        frameRate = settings.frameRate
        let hdr = applyFormat(device: device, settings: settings)
        var pixelFormat = hdr ? Self.hdrPixelFormat : Self.sdrPixelFormat
        if !videoOutput.availableVideoPixelFormatTypes.contains(pixelFormat) {
            // Setting an unsupported pixel format raises an exception.
            logger.warning("Video output can't deliver pixel format \(pixelFormat), using 8-bit")
            pixelFormat = Self.sdrPixelFormat
        }
        if outputPixelFormat != pixelFormat {
            videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat]
            outputPixelFormat = pixelFormat
        }

        if let connection = videoOutput.connection(with: .video) {
            if connection.isVideoRotationAngleSupported(settings.orientation.rotationAngle) {
                connection.videoRotationAngle = settings.orientation.rotationAngle
            }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = settings.mirror
            }
            if connection.isVideoStabilizationSupported {
                let mode = settings.stabilization.avMode
                connection.preferredVideoStabilizationMode =
                    device.activeFormat.isVideoStabilizationModeSupported(mode) ? mode : .off
            }
        }

        do {
            try device.lockForConfiguration()
            if device.isLowLightBoostSupported {
                device.automaticallyEnablesLowLightBoostWhenAvailable = settings.lowLightBoost
            }
            device.unlockForConfiguration()
        } catch {
            logger.error("Failed to lock camera for configuration: \(error.localizedDescription, privacy: .public)")
        }

        if #available(iOS 18.0, *) {
            configureCameraControlButton(device: device)
        }
    }

    /// Picks a device format matching resolution, frame rate and HDR.
    /// Returns whether the camera now delivers 10-bit HLG.
    private func applyFormat(device: AVCaptureDevice, settings: StreamSettings) -> Bool {
        var hdr = settings.isHDRActive
        var format = Self.bestFormat(device: device, settings: settings, hdr: hdr)
        if format == nil && hdr {
            logger.warning("No HDR format for \(settings.resolution.rawValue, privacy: .public)@\(settings.frameRate), using SDR")
            hdr = false
            format = Self.bestFormat(device: device, settings: settings, hdr: false)
        }
        guard let format else {
            let target = settings.resolution.landscapeSize
            logger.warning("No camera format for \(target.width)x\(target.height)@\(settings.frameRate)")
            // Fallback: preset at the device's default frame rate.
            session.sessionPreset = session.canSetSessionPreset(settings.resolution.sessionPreset)
                ? settings.resolution.sessionPreset : .high
            return false
        }

        session.sessionPreset = .inputPriority
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            // Setting the same format again would still make the camera reconfigure (a visible hitch).
            if device.activeFormat != format {
                device.activeFormat = format
            }
            let duration = CMTime(value: 1, timescale: CMTimeScale(settings.frameRate))
            if device.activeVideoMinFrameDuration != duration || device.activeVideoMaxFrameDuration != duration {
                device.activeVideoMinFrameDuration = duration
                device.activeVideoMaxFrameDuration = duration
            }
            let colorSpace: AVCaptureColorSpace = hdr ? .HLG_BT2020 : .sRGB
            if format.supportedColorSpaces.contains(colorSpace), device.activeColorSpace != colorSpace {
                device.activeColorSpace = colorSpace
            }
            return hdr
        } catch {
            logger.error("Failed to lock camera for configuration: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func configureAudio(enabled: Bool) {
        let authorized = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        guard enabled && authorized else {
            if let audioInput {
                session.removeInput(audioInput)
                self.audioInput = nil
            }
            if session.outputs.contains(audioOutput) {
                session.removeOutput(audioOutput)
            }
            return
        }

        if audioInput == nil {
            guard let microphone = AVCaptureDevice.default(for: .audio) else {
                logger.error("No microphone")
                return
            }
            do {
                let input = try AVCaptureDeviceInput(device: microphone)
                if session.canAddInput(input) {
                    session.addInput(input)
                    audioInput = input
                }
            } catch {
                logger.error("Failed to create microphone input: \(error.localizedDescription, privacy: .public)")
                return
            }
        }
        if !session.outputs.contains(audioOutput) {
            audioOutput.setSampleBufferDelegate(self, queue: audioQueue)
            if session.canAddOutput(audioOutput) {
                session.addOutput(audioOutput)
            }
        }
    }

    /// Applies `controls` to the active camera. Every value is clamped to what
    /// the device allows: out-of-range values raise an exception (crash).
    private func applyControls() {
        guard let device = currentInput?.device else { return }
        do {
            try device.lockForConfiguration()
        } catch {
            logger.error("Failed to lock camera for controls: \(error.localizedDescription, privacy: .public)")
            return
        }
        defer { device.unlockForConfiguration() }

        let format = device.activeFormat

        let maxZoom = min(device.maxAvailableVideoZoomFactor, CGFloat(CameraControls.maxZoom))
        let zoom = min(max(CGFloat(controls.zoom), device.minAvailableVideoZoomFactor), maxZoom)
        if device.videoZoomFactor != zoom {
            device.videoZoomFactor = zoom
        }

        switch controls.focusMode {
        case .auto:
            if device.isFocusModeSupported(.continuousAutoFocus), device.focusMode != .continuousAutoFocus {
                device.focusMode = .continuousAutoFocus
            }
        case .locked:
            if device.isFocusModeSupported(.locked), device.focusMode != .locked {
                device.focusMode = .locked
            }
        case .manual:
            if device.isLockingFocusWithCustomLensPositionSupported {
                device.setFocusModeLocked(lensPosition: min(max(controls.lensPosition, 0), 1), completionHandler: nil)
            }
        }

        switch controls.exposureMode {
        case .auto:
            if device.isExposureModeSupported(.continuousAutoExposure),
               device.exposureMode != .continuousAutoExposure {
                device.exposureMode = .continuousAutoExposure
            }
            let bias = min(max(controls.exposureBias, device.minExposureTargetBias), device.maxExposureTargetBias)
            if device.exposureTargetBias != bias {
                device.setExposureTargetBias(bias, completionHandler: nil)
            }
        case .locked:
            if device.isExposureModeSupported(.locked), device.exposureMode != .locked {
                device.exposureMode = .locked
            }
        case .manual:
            if device.isExposureModeSupported(.custom) {
                let iso = min(max(controls.iso, format.minISO), format.maxISO)
                // Longer than one frame would lower the frame rate.
                let longest = CMTimeMinimum(format.maxExposureDuration,
                                            CMTime(value: 1, timescale: CMTimeScale(frameRate)))
                let requested = CMTime(value: 1, timescale: CMTimeScale(max(1, controls.shutterDenominator)))
                let duration = CMTimeMaximum(CMTimeMinimum(requested, longest), format.minExposureDuration)
                device.setExposureModeCustom(duration: duration, iso: iso, completionHandler: nil)
            }
        }

        switch controls.whiteBalanceMode {
        case .auto:
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance),
               device.whiteBalanceMode != .continuousAutoWhiteBalance {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }
        case .locked:
            if device.isWhiteBalanceModeSupported(.locked), device.whiteBalanceMode != .locked {
                device.whiteBalanceMode = .locked
            }
        case .manual:
            if device.isLockingWhiteBalanceWithCustomDeviceGainsSupported {
                let values = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(
                    temperature: min(max(controls.temperature, CameraControls.temperatureRange.lowerBound),
                                     CameraControls.temperatureRange.upperBound),
                    tint: min(max(controls.tint, CameraControls.tintRange.lowerBound),
                              CameraControls.tintRange.upperBound))
                let gains = device.deviceWhiteBalanceGains(for: values)
                let maxGain = device.maxWhiteBalanceGain
                let clamped = AVCaptureDevice.WhiteBalanceGains(
                    redGain: min(max(gains.redGain, 1), maxGain),
                    greenGain: min(max(gains.greenGain, 1), maxGain),
                    blueGain: min(max(gains.blueGain, 1), maxGain))
                device.setWhiteBalanceModeLocked(with: clamped, completionHandler: nil)
            }
        }

        let torchMode: AVCaptureDevice.TorchMode = controls.torch ? .on : .off
        if device.hasTorch, device.isTorchModeSupported(torchMode), device.torchMode != torchMode {
            device.torchMode = torchMode
        }
    }

    private func publishCapabilities(device: AVCaptureDevice) {
        let format = device.activeFormat
        var caps = CameraCapabilities()
        caps.minZoom = Double(device.minAvailableVideoZoomFactor)
        caps.maxZoom = Double(min(device.maxAvailableVideoZoomFactor, CGFloat(CameraControls.maxZoom)))
        caps.supportsFocusLock = device.isFocusModeSupported(.locked)
        caps.supportsManualFocus = device.isLockingFocusWithCustomLensPositionSupported
        caps.supportsExposureLock = device.isExposureModeSupported(.locked)
        caps.supportsManualExposure = device.isExposureModeSupported(.custom)
        caps.minISO = format.minISO
        caps.maxISO = format.maxISO
        caps.minExposureBias = device.minExposureTargetBias
        caps.maxExposureBias = device.maxExposureTargetBias
        let shortest = CMTimeGetSeconds(format.minExposureDuration)
        let longest = min(CMTimeGetSeconds(format.maxExposureDuration), 1 / Double(frameRate))
        caps.shutterDenominators = CameraControls.shutterDenominators.filter {
            let seconds = 1 / Double($0)
            return seconds >= shortest && seconds <= longest + 1e-6
        }
        caps.supportsWhiteBalanceLock = device.isWhiteBalanceModeSupported(.locked)
        caps.supportsManualWhiteBalance = device.isLockingWhiteBalanceWithCustomDeviceGainsSupported
        caps.hasTorch = device.hasTorch
        caps.supportsLowLightBoost = device.isLowLightBoostSupported
        DispatchQueue.main.async { [weak self] in self?.capabilitiesHandler?(caps) }
    }

    // MARK: - Camera Control button (iPhone 16 and later)

    @available(iOS 18.0, *)
    private func configureCameraControlButton(device: AVCaptureDevice) {
        guard session.supportsControls else { return }
        for control in session.controls {
            session.removeControl(control)
        }
        // A delegate is required before adding controls.
        session.setControlsDelegate(self, queue: sessionQueue)

        let zoom = AVCaptureSystemZoomSlider(device: device) { [weak self] factor in
            self?.cameraControlChanged { $0.zoom = Double(factor) }
        }
        let exposure = AVCaptureSystemExposureBiasSlider(device: device) { [weak self] bias in
            self?.cameraControlChanged { $0.exposureBias = bias }
        }
        for control in [zoom, exposure] as [AVCaptureControl] where session.canAddControl(control) {
            session.addControl(control)
        }
    }

    /// The system already changed the device; keep `controls` and the UI in sync.
    private func cameraControlChanged(_ change: @escaping (inout CameraControls) -> Void) {
        sessionQueue.async { [self] in
            change(&controls)
            let controls = self.controls
            DispatchQueue.main.async { [weak self] in self?.controlsChangedHandler?(controls) }
        }
    }
}

extension CameraCaptureService: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        if output === audioOutput {
            audioHandler?(sampleBuffer)
            return
        }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        frameHandler?(pixelBuffer, CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }
}

@available(iOS 18.0, *)
extension CameraCaptureService: AVCaptureSessionControlsDelegate {
    func sessionControlsDidBecomeActive(_ session: AVCaptureSession) {}
    func sessionControlsWillEnterFullscreenAppearance(_ session: AVCaptureSession) {}
    func sessionControlsWillExitFullscreenAppearance(_ session: AVCaptureSession) {}
    func sessionControlsDidBecomeInactive(_ session: AVCaptureSession) {}
}
