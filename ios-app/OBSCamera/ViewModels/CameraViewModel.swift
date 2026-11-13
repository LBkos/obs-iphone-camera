import AVFoundation
import SwiftUI
import UIKit

@MainActor
final class CameraViewModel: ObservableObject {
    @Published private(set) var hosts: [OBSHost] = []
    @Published private(set) var status: StreamingEngine.Status = .idle
    @Published private(set) var stats = StreamingEngine.Stats()
    @Published private(set) var discoveryError: String?
    @Published private(set) var cameraAccessDenied = false
    @Published private(set) var microphoneAccessDenied = false
    @Published private(set) var capabilities = CameraCapabilities()
    /// Preview point of the last tap-to-focus, shown briefly.
    @Published private(set) var focusIndicator: CGPoint?
    /// Black screen while streaming: the phone's display is not needed then.
    @Published private(set) var isScreenBlack = false
    /// Last connection error while auto-reconnecting.
    @Published private(set) var reconnectError: String?
    @Published var settings: StreamSettings {
        didSet {
            guard settings != oldValue else { return }
            settings.save()
            applySettings()
        }
    }
    /// Live camera adjustments: applied without restarting capture.
    @Published var controls: CameraControls {
        didSet {
            guard controls != oldValue else { return }
            controls.save()
            engine.camera.apply(controls)
        }
    }
    @Published var manualAddress: String {
        didSet { UserDefaults.standard.set(manualAddress, forKey: Self.manualAddressKey) }
    }
    @Published var connectionMode: ConnectionMode {
        didSet {
            guard connectionMode != oldValue else { return }
            connectionMode.save()
            applyConnectionMode()
        }
    }

    let engine = StreamingEngine()
    private let browser = HostBrowser()
    private var lastHost: OBSHost?
    private var reconnectTask: Task<Void, Never>?
    private var didStart = false
    private var zoomAtPinchStart: Double?
    private var focusIndicatorTask: Task<Void, Never>?
    private var brightnessBeforeBlack: CGFloat?
    private static let manualAddressKey = "manualAddress"

    init() {
        settings = StreamSettings.load()
        controls = CameraControls.load()
        manualAddress = UserDefaults.standard.string(forKey: Self.manualAddressKey) ?? ""
        connectionMode = ConnectionMode.load()

        engine.statusHandler = { [weak self] status in
            Task { @MainActor in self?.handle(status) }
        }
        engine.statsHandler = { [weak self] stats in
            Task { @MainActor in self?.stats = stats }
        }
        browser.hostsHandler = { [weak self] hosts in
            Task { @MainActor in self?.hosts = hosts }
        }
        browser.errorHandler = { [weak self] message in
            Task { @MainActor in self?.discoveryError = message }
        }
        engine.camera.capabilitiesHandler = { [weak self] capabilities in
            Task { @MainActor in self?.capabilities = capabilities }
        }
        engine.camera.controlsChangedHandler = { [weak self] controls in
            Task { @MainActor in self?.controls = controls }
        }
    }

    // MARK: - Derived state

    var captureSession: AVCaptureSession { engine.camera.session }

    var effectiveSource: VideoSourceKind { StreamingEngine.effectiveSource(for: settings) }

    var isConnectedOrConnecting: Bool {
        switch status {
        case .connecting, .streaming: true
        case .idle, .waitingForUSB, .failed: false
        }
    }

    var statusText: String {
        switch status {
        case .idle: "Не подключено"
        case .waitingForUSB: "Ожидание OBS по кабелю…"
        case .connecting(let host): "Подключение к \(host)…"
        case .streaming(let host): "В эфире: \(host)"
        case .failed(let reason): "Ошибка: \(Self.friendlyError(reason))"
        }
    }

    var statsText: String? {
        if case .connecting = status { return reconnectError }
        guard case .streaming = status else { return nil }
        let size = settings.outputSize
        let mbps = Double(stats.kilobitsPerSecond) / 1000
        return "\(size.width)×\(size.height) · \(stats.framesPerSecond) fps · \(String(format: "%.1f", mbps)) Мбит/с"
    }

    var canConnectManually: Bool { OBSHost.manual(manualAddress) != nil }

    // MARK: - Intents

    func onAppear() async {
        guard !didStart else { return }
        didStart = true
        await requestCameraAccessIfNeeded()
        await requestMicrophoneAccessIfNeeded()
        engine.camera.apply(controls)
        engine.startCapture(with: settings)
        applyConnectionMode()
    }

    func connect(to host: OBSHost) {
        reconnectTask?.cancel()
        reconnectError = nil
        lastHost = host
        engine.connect(to: host, deviceName: UIDevice.current.name)
    }

    func connectManually() {
        guard let host = OBSHost.manual(manualAddress) else { return }
        connect(to: host)
    }

    func retry() {
        if let lastHost { connect(to: lastHost) }
    }

    func disconnect() {
        lastHost = nil
        reconnectTask?.cancel()
        reconnectError = nil
        engine.disconnect()
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        guard didStart else { return }
        switch phase {
        case .active:
            engine.startCapture(with: settings)
            if connectionMode == .wifi { browser.start() }
        case .background:
            // The camera is unavailable in the background; the connection
            // stays open (keep-alive pings) and resumes on return.
            engine.stopCapture()
            browser.stop()
            exitBlackScreen() // brightness is system-wide: give it back
            // The torch turns off with the camera; don't switch it on again by surprise.
            controls.torch = false
        default:
            break
        }
    }

    // MARK: - Camera controls

    /// Pinch on the preview. `scale` is relative to the pinch start; nil ends the pinch.
    func pinchZoom(scale: CGFloat?) {
        guard let scale else {
            zoomAtPinchStart = nil
            return
        }
        let start = zoomAtPinchStart ?? controls.zoom
        zoomAtPinchStart = start
        controls.zoom = min(max(start * Double(scale), capabilities.minZoom), capabilities.maxZoom)
    }

    /// Tap on the preview: focus/expose there (for the parts in auto mode).
    func tapToFocus(devicePoint: CGPoint, previewPoint: CGPoint) {
        guard controls.focusMode == .auto || controls.exposureMode == .auto else { return }
        engine.camera.focus(atDevicePoint: devicePoint)
        focusIndicator = previewPoint
        focusIndicatorTask?.cancel()
        focusIndicatorTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.focusIndicator = nil
        }
    }

    // Switching to manual starts from the camera's current automatic values,
    // so the picture doesn't jump.

    func setFocusMode(_ mode: ControlMode) {
        var updated = controls
        if mode == .manual, controls.focusMode != .manual, let readings = engine.camera.readings() {
            updated.lensPosition = readings.lensPosition
        }
        updated.focusMode = mode
        controls = updated
    }

    func setExposureMode(_ mode: ControlMode) {
        var updated = controls
        if mode == .manual, controls.exposureMode != .manual, let readings = engine.camera.readings() {
            updated.iso = min(max(readings.iso, capabilities.minISO), max(capabilities.minISO, capabilities.maxISO))
            if readings.exposureSeconds > 0, let nearest = capabilities.shutterDenominators.min(by: {
                abs(log(1 / Double($0) / readings.exposureSeconds)) < abs(log(1 / Double($1) / readings.exposureSeconds))
            }) {
                updated.shutterDenominator = nearest
            }
        }
        updated.exposureMode = mode
        controls = updated
    }

    func setWhiteBalanceMode(_ mode: ControlMode) {
        var updated = controls
        if mode == .manual, controls.whiteBalanceMode != .manual, let readings = engine.camera.readings() {
            updated.temperature = min(max(readings.temperature, CameraControls.temperatureRange.lowerBound),
                                      CameraControls.temperatureRange.upperBound)
            updated.tint = min(max(readings.tint, CameraControls.tintRange.lowerBound),
                               CameraControls.tintRange.upperBound)
        }
        updated.whiteBalanceMode = mode
        controls = updated
    }

    func resetControls() {
        var reset = CameraControls()
        reset.torch = controls.torch
        controls = reset
    }

    // MARK: - Black screen

    func enterBlackScreen() {
        guard !isScreenBlack else { return }
        isScreenBlack = true
        if let screen = Self.currentScreen {
            brightnessBeforeBlack = screen.brightness
            screen.brightness = 0
        }
    }

    func exitBlackScreen() {
        guard isScreenBlack else { return }
        isScreenBlack = false
        if let brightness = brightnessBeforeBlack {
            Self.currentScreen?.brightness = brightness
        }
        brightnessBeforeBlack = nil
    }

    private static var currentScreen: UIScreen? {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }.first
    }

    func openSystemSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    // MARK: - Private

    private func handle(_ status: StreamingEngine.Status) {
        reconnectTask?.cancel()
        if case .failed(let reason) = status, let host = lastHost {
            // OBS restarted, Wi-Fi blip, etc.: keep trying until the user taps "Disconnect".
            self.status = .connecting(host: host.name)
            reconnectError = Self.friendlyError(reason)
            reconnectTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self, self.lastHost == host else { return }
                self.engine.connect(to: host, deviceName: UIDevice.current.name)
            }
        } else {
            if case .streaming = status { reconnectError = nil }
            self.status = status
        }
        UIApplication.shared.isIdleTimerDisabled = isConnectedOrConnecting
    }

    private static func friendlyError(_ reason: String) -> String {
        let lowered = reason.lowercased()
        if lowered.contains("refused") {
            return "OBS не принимает подключение. Проверьте, что источник «iPhone Camera» добавлен."
        }
        if lowered.contains("reset") || lowered.contains("closed") || lowered.contains("broken pipe") {
            return "Соединение с OBS разорвано."
        }
        if lowered.contains("timed out") || lowered.contains("unreachable") || lowered.contains("no route") {
            return "Компьютер недоступен. Проверьте, что iPhone и компьютер в одной сети."
        }
        return reason
    }

    private func applyConnectionMode() {
        guard didStart else { return }
        lastHost = nil
        reconnectTask?.cancel()
        reconnectError = nil
        switch connectionMode {
        case .wifi:
            engine.stopUSBMode()
            browser.start()
        case .usb:
            browser.stop()
            hosts = []
            engine.startUSBMode(deviceName: UIDevice.current.name)
        }
    }

    private func applySettings() {
        guard didStart else { return }
        Task {
            // Switching from the test pattern to a camera may need permission first.
            await requestCameraAccessIfNeeded()
            await requestMicrophoneAccessIfNeeded()
            engine.startCapture(with: settings)
        }
    }

    private func requestMicrophoneAccessIfNeeded() async {
        guard settings.audioEnabled else {
            microphoneAccessDenied = false
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            microphoneAccessDenied = !granted
        case .denied, .restricted:
            microphoneAccessDenied = true
        default:
            microphoneAccessDenied = false
        }
    }

    private func requestCameraAccessIfNeeded() async {
        guard effectiveSource != .testPattern else { return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            cameraAccessDenied = !granted
        case .denied, .restricted:
            cameraAccessDenied = true
        default:
            cameraAccessDenied = false
        }
    }
}
