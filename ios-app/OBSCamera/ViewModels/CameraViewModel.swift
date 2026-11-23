import AVFoundation
import SwiftUI
import UIKit

@MainActor
final class CameraViewModel: ObservableObject {
    /// Dot in the connection line at the bottom.
    enum ConnectionQuality {
        case none, good, weak, bad
    }

    static let manualTargetID = "manual"
    /// The screen turns black this long after going live (if the option is on).
    static let autoBlackSeconds = 30

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
    /// OBS controls the camera (its source has "Control the camera from OBS" on):
    /// the app's own camera controls are read-only meanwhile.
    @Published private(set) var isRemoteControlled = false
    /// When the current stream started (for the timer).
    @Published private(set) var liveSince: Date?
    /// OBS can connect through the cable. Off after the user stops the stream,
    /// so the USB source doesn't restart it right away.
    @Published private(set) var isUSBListening = false
    /// Computer to stream to over Wi‑Fi: an `OBSHost.id` or `manualTargetID`.
    @Published var selectedTargetID: String?
    @Published private(set) var profiles: [CameraProfile] {
        didSet {
            CameraProfile.saveAll(profiles)
            engine.updateProfiles(profiles)
        }
    }
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

    let engine = StreamingEngine()
    private let browser = HostBrowser()
    private var lastHost: OBSHost?
    private var reconnectTask: Task<Void, Never>?
    private var autoBlackTask: Task<Void, Never>?
    private var didStart = false
    private var zoomAtPinchStart: Double?
    private var focusIndicatorTask: Task<Void, Never>?
    private var brightnessBeforeBlack: CGFloat?
    private static let manualAddressKey = "manualAddress"
    private static let lastHostNameKey = "lastHostName"

    init() {
        settings = StreamSettings.load()
        controls = CameraControls.load()
        manualAddress = UserDefaults.standard.string(forKey: Self.manualAddressKey) ?? ""
        profiles = CameraProfile.loadAll()
        engine.updateProfiles(profiles)

        engine.statusHandler = { [weak self] status in
            Task { @MainActor in self?.handle(status) }
        }
        engine.statsHandler = { [weak self] stats in
            Task { @MainActor in self?.stats = stats }
        }
        browser.hostsHandler = { [weak self] hosts in
            Task { @MainActor in self?.updateHosts(hosts) }
        }
        browser.errorHandler = { [weak self] message in
            Task { @MainActor in self?.discoveryError = message }
        }
        engine.camera.capabilitiesHandler = { [weak self] capabilities in
            Task { @MainActor in
                self?.capabilities = capabilities
                self?.engine.updateCapabilities(capabilities)
            }
        }
        engine.camera.controlsChangedHandler = { [weak self] controls in
            Task { @MainActor in self?.cameraControlButtonChanged(controls) }
        }
        engine.remoteControlsHandler = { [weak self] controls in
            Task { @MainActor in self?.handleRemoteControls(controls) }
        }
    }

    // MARK: - Derived state

    var captureSession: AVCaptureSession { engine.camera.session }

    var effectiveSource: VideoSourceKind { StreamingEngine.effectiveSource(for: settings) }

    var isConnectedOrConnecting: Bool {
        switch status {
        case .connecting, .streaming: true
        case .idle, .failed: false
        }
    }

    /// Not streaming and not trying to: the computer can be chosen.
    var isIdle: Bool { !isConnectedOrConnecting }

    var isLive: Bool {
        if case .streaming = status { return true }
        return false
    }

    var isManualTarget: Bool { selectedTargetID == Self.manualTargetID }

    var selectedHost: OBSHost? { hosts.first { $0.id == selectedTargetID } }

    var isStreamingViaUSB: Bool {
        if case .streaming(_, true) = status { return true }
        return false
    }

    /// Cameras this iPhone has, plus the test pattern.
    var availableSources: [VideoSourceKind] {
        VideoSourceKind.allCases.filter { $0 == .testPattern || CameraCaptureService.isAvailable(for: $0) }
    }

    /// The profile that matches the current setup, if any.
    var activeProfileID: UUID? {
        profiles.first { $0.matches(settings: settings, controls: controls) }?.id
    }

    var canConnectManually: Bool { OBSHost.manual(manualAddress) != nil }

    /// Idle, the button connects to the chosen computer, or turns USB back on after a stop.
    var canPressLiveButton: Bool {
        guard isIdle else { return true }
        return (isManualTarget ? canConnectManually : selectedHost != nil) || !isUSBListening
    }

    /// The camera can't deliver the chosen resolution / frame rate (falls back to a preset).
    var isFormatSupported: Bool {
        effectiveSource == .testPattern || CameraCaptureService.supportsFormat(for: settings)
    }

    /// First line of the connection status at the bottom.
    var connectionTitle: String {
        switch status {
        case .streaming(_, true): return "USB-кабель"
        case .streaming(let host, false): return "Wi‑Fi: \(host)"
        case .connecting(let host): return "Подключение: \(host)"
        case .idle, .failed:
            if isManualTarget {
                return canConnectManually ? "IP: \(manualAddress)" : "IP-адрес не введён"
            }
            if let selectedHost { return "Wi‑Fi: \(selectedHost.name)" }
            return hosts.isEmpty ? "Поиск OBS…" : "Выберите компьютер"
        }
    }

    /// Second line: what is going on and what to do.
    var connectionDetail: String {
        switch status {
        case .streaming:
            let mbps = String(format: "%.1f", Double(stats.kilobitsPerSecond) / 1000).replacingOccurrences(of: ".", with: ",")
            let quality = switch connectionQuality {
            case .bad: "Связь плохая"
            case .weak: "Связь нестабильная"
            default: "Связь хорошая"
            }
            return "\(quality) · \(mbps) Мбит/с · \(stats.framesPerSecond) к/с"
        case .connecting:
            return reconnectError ?? "Нажмите «Стоп», чтобы отменить"
        case .failed(let reason):
            return Self.friendlyError(reason)
        case .idle:
            if isManualTarget {
                return canConnectManually ? "Нажмите «Старт»" : "Нажмите, чтобы ввести IP"
            }
            if selectedHost != nil { return "OBS готов · нажмите, чтобы сменить" }
            if let discoveryError { return discoveryError }
            if !isUSBListening { return "USB ждёт до следующего «Старт»" }
            return "Подключите кабель или введите IP"
        }
    }

    var connectionQuality: ConnectionQuality {
        switch status {
        case .streaming:
            // Share of frames the network couldn't take in the last second.
            let dropped = Double(stats.droppedFrames) / Double(max(stats.framesPerSecond, 1))
            if dropped == 0 { return .good }
            return dropped < 0.2 ? .weak : .bad
        case .connecting:
            return .weak
        case .failed:
            return .bad
        case .idle:
            let ready = isManualTarget ? canConnectManually : selectedHost != nil
            return ready ? .good : .none
        }
    }

    // MARK: - Intents

    func onAppear() async {
        guard !didStart else { return }
        didStart = true
        await requestCameraAccessIfNeeded()
        await requestMicrophoneAccessIfNeeded()
        engine.camera.apply(controls)
        engine.startCapture(with: settings)
        browser.start()
        startUSB()
    }

    func liveButtonTapped() {
        if isIdle {
            goLive()
        } else {
            stopLive()
        }
    }

    func goLive() {
        startUSB()
        if isManualTarget {
            guard let host = OBSHost.manual(manualAddress) else { return }
            connect(to: host, remember: false)
        } else if let host = selectedHost {
            connect(to: host, remember: true)
        }
    }

    func stopLive() {
        lastHost = nil
        reconnectTask?.cancel()
        reconnectError = nil
        engine.disconnect()
        engine.stopUSB()
        isUSBListening = false
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        guard didStart else { return }
        switch phase {
        case .active:
            engine.startCapture(with: settings)
            browser.start()
        case .background:
            // The camera is unavailable in the background; the connection
            // stays open (keep-alive pings) and resumes on return.
            engine.stopCapture()
            browser.stop()
            exitBlackScreen() // brightness is system-wide: give it back
            // The torch turns off with the camera; don't switch it on again by surprise.
            // Under OBS control it follows OBS instead.
            if !isRemoteControlled { controls.torch = false }
        default:
            break
        }
    }

    // MARK: - Camera controls

    func flipCamera() {
        let next: VideoSourceKind = settings.source == .frontCamera ? .backCamera : .frontCamera
        guard CameraCaptureService.isAvailable(for: next) else { return }
        settings.source = next
    }

    func selectSource(_ source: VideoSourceKind) {
        guard source != settings.source else { return }
        settings.source = source
    }

    func toggleMicrophone() {
        settings.audioEnabled.toggle()
    }

    func toggleTorch() {
        guard !isRemoteControlled else { return }
        controls.torch.toggle()
    }

    /// Pinch on the preview. `scale` is relative to the pinch start; nil ends the pinch.
    func pinchZoom(scale: CGFloat?) {
        guard !isRemoteControlled else { return }
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
        guard !isRemoteControlled, controls.focusMode == .auto || controls.exposureMode == .auto else { return }
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
        guard !isRemoteControlled else { return }
        var reset = CameraControls()
        reset.torch = controls.torch
        controls = reset
    }

    /// Back to automatic for one control (long press on its value).
    func resetControl(_ kind: CameraControlKind) {
        guard !isRemoteControlled else { return }
        let defaults = CameraControls()
        var updated = controls
        switch kind {
        case .zoom:
            updated.zoom = defaults.zoom
        case .focus:
            updated.focusMode = .auto
        case .exposure:
            updated.exposureMode = .auto
            updated.exposureBias = defaults.exposureBias
        case .whiteBalance:
            updated.whiteBalanceMode = .auto
        }
        controls = updated
    }

    // MARK: - Profiles

    /// Saves the current setup (the torch is left out).
    func saveProfile(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var saved = controls
        saved.torch = false
        profiles.append(CameraProfile(name: trimmed, settings: settings, controls: saved))
    }

    func applyProfile(_ profile: CameraProfile) {
        settings = profile.settings
        // Under OBS control the camera values stay OBS's (OBS has its own profile picker).
        guard !isRemoteControlled else { return }
        var applied = profile.controls
        applied.torch = controls.torch
        controls = applied
    }

    func deleteProfiles(at offsets: IndexSet) {
        profiles.remove(atOffsets: offsets)
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

    /// `remember`: preselect this computer next time (found ones, not a typed IP).
    private func connect(to host: OBSHost, remember: Bool) {
        reconnectTask?.cancel()
        reconnectError = nil
        lastHost = host
        if remember {
            UserDefaults.standard.set(host.name, forKey: Self.lastHostNameKey)
        }
        engine.connect(to: host, deviceName: UIDevice.current.name)
    }

    private func startUSB() {
        engine.startUSB(deviceName: UIDevice.current.name)
        isUSBListening = true
    }

    private func updateHosts(_ hosts: [OBSHost]) {
        self.hosts = hosts
        guard !isManualTarget, selectedHost == nil else { return }
        // Preselect the computer used last time.
        let lastName = UserDefaults.standard.string(forKey: Self.lastHostNameKey)
        selectedTargetID = (hosts.first { $0.name == lastName } ?? hosts.first)?.id
    }

    private func handleRemoteControls(_ remote: CameraControls?) {
        guard let remote else {
            isRemoteControlled = false
            return
        }
        isRemoteControlled = true
        controls = remote
    }

    /// The Camera Control button (iPhone 16+) changes the camera directly.
    private func cameraControlButtonChanged(_ changed: CameraControls) {
        if isRemoteControlled {
            engine.camera.apply(controls) // OBS decides: undo the change
        } else {
            controls = changed
        }
    }

    private func handle(_ status: StreamingEngine.Status) {
        reconnectTask?.cancel()
        // Control returns to the app as soon as OBS is gone.
        switch status {
        case .streaming: break
        default: isRemoteControlled = false
        }
        if case .failed(let reason) = status, let host = lastHost {
            // OBS restarted, Wi-Fi blip, etc.: keep trying until the user taps stop.
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
        updateLiveTimer()
        UIApplication.shared.isIdleTimerDisabled = isConnectedOrConnecting
    }

    /// Starts the timer (and the automatic black screen) when the stream starts.
    private func updateLiveTimer() {
        guard case .streaming = status else {
            liveSince = nil
            autoBlackTask?.cancel()
            return
        }
        guard liveSince == nil else { return }
        liveSince = Date()
        autoBlackTask?.cancel()
        guard DisplayOptions.autoBlackScreen else { return }
        autoBlackTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.autoBlackSeconds))
            guard !Task.isCancelled, let self, case .streaming = self.status else { return }
            self.enterBlackScreen()
        }
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
