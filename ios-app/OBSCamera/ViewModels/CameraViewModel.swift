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
    /// Last connection error while auto-reconnecting.
    @Published private(set) var reconnectError: String?
    @Published var settings: StreamSettings {
        didSet {
            guard settings != oldValue else { return }
            settings.save()
            applySettings()
        }
    }
    @Published var manualAddress: String {
        didSet { UserDefaults.standard.set(manualAddress, forKey: Self.manualAddressKey) }
    }

    let engine = StreamingEngine()
    private let browser = HostBrowser()
    private var lastHost: OBSHost?
    private var reconnectTask: Task<Void, Never>?
    private var didStart = false
    private static let manualAddressKey = "manualAddress"

    init() {
        settings = StreamSettings.load()
        manualAddress = UserDefaults.standard.string(forKey: Self.manualAddressKey) ?? ""

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

    var statusText: String {
        switch status {
        case .idle: "Не подключено"
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
        browser.start()
        await requestCameraAccessIfNeeded()
        engine.startCapture(with: settings)
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
            browser.start()
        case .background:
            // The camera is unavailable in the background; the connection
            // stays open (keep-alive pings) and resumes on return.
            engine.stopCapture()
            browser.stop()
        default:
            break
        }
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

    private func applySettings() {
        guard didStart else { return }
        Task {
            // Switching from the test pattern to a camera may need permission first.
            await requestCameraAccessIfNeeded()
            engine.startCapture(with: settings)
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
