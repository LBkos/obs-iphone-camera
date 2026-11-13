import AVFoundation
import Network
import os

/// Wires frame source → H.264 encoder → network connection.
/// Thread-safe; all handlers are delivered on the main queue.
final class StreamingEngine: @unchecked Sendable {
    enum Status: Equatable {
        case idle
        case connecting(host: String)
        case streaming(host: String)
        case failed(String)
    }

    struct Stats: Equatable {
        var framesPerSecond = 0
        var kilobitsPerSecond = 0
    }

    var statusHandler: ((Status) -> Void)?
    var statsHandler: ((Stats) -> Void)?

    let camera = CameraCaptureService()
    private let testPattern = TestPatternSource()
    private let encoder = H264Encoder()
    private let logger = Logger(subsystem: "com.obscamera.app", category: "Engine")

    private let lock = NSLock()
    private var activeSource: VideoFrameSource?
    private var connection: StreamConnection?
    private var isStreaming = false
    private var settings = StreamSettings()
    private var framesSent = 0
    private var bytesSent = 0
    private var statsTimer: Timer?

    init() {
        encoder.outputHandler = { [weak self] frame in
            guard let self else { return }
            self.lock.lock()
            let connection = self.isStreaming ? self.connection : nil
            if connection != nil { self.framesSent += 1 }
            self.lock.unlock()
            connection?.send(frame)
        }
        let frameHandler: (CVPixelBuffer, CMTime) -> Void = { [weak self] pixelBuffer, pts in
            guard let self else { return }
            self.lock.lock()
            let streaming = self.isStreaming
            self.lock.unlock()
            if streaming {
                self.encoder.encode(pixelBuffer, pts: pts)
            }
        }
        camera.frameHandler = frameHandler
        testPattern.frameHandler = frameHandler
    }

    /// The source actually used (camera falls back to the test pattern when
    /// unavailable, e.g. in the Simulator).
    static func effectiveSource(for settings: StreamSettings) -> VideoSourceKind {
        if settings.source != .testPattern && !CameraCaptureService.isAvailable(for: settings.source) {
            return .testPattern
        }
        return settings.source
    }

    /// Starts the frame source (also used for the on-screen preview).
    func startCapture(with settings: StreamSettings) {
        lock.lock()
        self.settings = settings
        let newSource: VideoFrameSource = Self.effectiveSource(for: settings) == .testPattern ? testPattern : camera
        let oldSource = activeSource
        activeSource = newSource
        lock.unlock()

        if let oldSource, oldSource !== newSource {
            oldSource.stop()
        }
        encoder.update(settings: settings)
        newSource.start(with: settings)
    }

    func stopCapture() {
        lock.lock()
        let source = activeSource
        activeSource = nil
        lock.unlock()
        source?.stop()
    }

    func connect(to host: OBSHost, deviceName: String) {
        disconnect()

        let connection = StreamConnection(endpoint: host.endpoint, deviceName: deviceName)
        connection.keyframeNeededHandler = { [weak self] in self?.encoder.requestKeyframe() }
        connection.bytesSentHandler = { [weak self] bytes in
            guard let self else { return }
            self.lock.lock()
            self.bytesSent += bytes
            self.lock.unlock()
        }
        connection.stateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            self.handle(state, of: connection, host: host)
        }

        lock.lock()
        self.connection = connection
        lock.unlock()

        publish(.connecting(host: host.name))
        connection.start()
        startStatsTimer()
    }

    func disconnect() {
        lock.lock()
        let connection = self.connection
        self.connection = nil
        isStreaming = false
        lock.unlock()

        connection?.cancel()
        encoder.invalidate()
        stopStatsTimer()
        publish(.idle)
    }

    // MARK: - Private

    private func handle(_ state: StreamConnection.State, of connection: StreamConnection, host: OBSHost) {
        lock.lock()
        let isCurrent = self.connection === connection
        lock.unlock()
        guard isCurrent else { return }

        switch state {
        case .connecting:
            publish(.connecting(host: host.name))
        case .waiting(let reason):
            logger.warning("Waiting for \(host.name, privacy: .public): \(reason, privacy: .public)")
            publish(.connecting(host: host.name))
        case .ready:
            lock.lock()
            isStreaming = true
            lock.unlock()
            encoder.requestKeyframe()
            publish(.streaming(host: host.name))
        case .failed(let reason):
            lock.lock()
            isStreaming = false
            self.connection = nil
            lock.unlock()
            connection.cancel()
            stopStatsTimer()
            publish(.failed(reason))
        case .closed:
            break
        }
    }

    private func publish(_ status: Status) {
        DispatchQueue.main.async { [weak self] in self?.statusHandler?(status) }
    }

    private func startStatsTimer() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.statsTimer?.invalidate()
            self.statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                let stats = Stats(framesPerSecond: self.framesSent, kilobitsPerSecond: self.bytesSent * 8 / 1000)
                self.framesSent = 0
                self.bytesSent = 0
                self.lock.unlock()
                self.statsHandler?(stats)
            }
        }
    }

    private func stopStatsTimer() {
        DispatchQueue.main.async { [weak self] in
            self?.statsTimer?.invalidate()
            self?.statsTimer = nil
            self?.statsHandler?(Stats())
        }
    }
}
