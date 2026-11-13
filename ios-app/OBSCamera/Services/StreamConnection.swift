import Foundation
import Network
import os

/// TCP connection to the OBS plugin. Frames are dropped (until the next
/// keyframe) when the network can't keep up, so latency stays low.
final class StreamConnection: @unchecked Sendable {
    enum State: Equatable {
        case connecting
        case waiting(String)
        case ready
        case failed(String)
        case closed
    }

    var stateHandler: ((State) -> Void)?
    /// Called when frames were dropped and a fresh keyframe is needed.
    var keyframeNeededHandler: (() -> Void)?
    /// Called for every sent byte count (for statistics).
    var bytesSentHandler: ((Int) -> Void)?

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.obscamera.connection", qos: .userInteractive)
    private let logger = Logger(subsystem: "com.obscamera.app", category: "Connection")
    private let deviceName: String

    // Accessed on `queue` only.
    private var isReady = false
    private var bytesInFlight = 0
    private var droppingUntilKeyframe = false
    private var lastSendTime = DispatchTime.now()
    private var pingTimer: DispatchSourceTimer?

    private let maxBytesInFlight = 2_000_000

    init(endpoint: NWEndpoint, deviceName: String) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 5
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 2
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.serviceClass = .interactiveVideo
        parameters.includePeerToPeer = true
        self.connection = NWConnection(to: endpoint, using: parameters)
        self.deviceName = deviceName
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            self?.handle(state)
        }
        stateHandler?(.connecting)
        connection.start(queue: queue)
    }

    func cancel() {
        queue.async { [self] in
            pingTimer?.cancel()
            pingTimer = nil
            isReady = false
        }
        connection.cancel()
    }

    func send(_ frame: EncodedFrame) {
        queue.async { [self] in
            guard isReady else { return }

            if bytesInFlight > maxBytesInFlight && !frame.isKeyframe {
                if !droppingUntilKeyframe {
                    logger.warning("Network congested (\(self.bytesInFlight) bytes queued), dropping frames")
                    droppingUntilKeyframe = true
                    keyframeNeededHandler?()
                }
                return
            }
            if droppingUntilKeyframe {
                guard frame.isKeyframe else { return }
                droppingUntilKeyframe = false
            }

            var message = Data()
            if let parameterSets = frame.parameterSets {
                message.append(WireProtocol.message(.config, payload: parameterSets))
            }
            message.append(WireProtocol.frameMessage(ptsMicros: frame.ptsMicros, isKeyframe: frame.isKeyframe,
                                                     annexB: frame.annexB))
            write(message)
        }
    }

    // MARK: - Private (queue)

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .setup, .preparing:
            break
        case .waiting(let error):
            logger.warning("Connection waiting: \(error.localizedDescription, privacy: .public)")
            stateHandler?(.waiting(error.localizedDescription))
        case .ready:
            isReady = true
            bytesInFlight = 0
            droppingUntilKeyframe = false
            write(WireProtocol.message(.hello, payload: Data(deviceName.utf8)))
            startPing()
            logger.info("Connected to \(String(describing: self.connection.endpoint), privacy: .public)")
            stateHandler?(.ready)
        case .failed(let error):
            isReady = false
            logger.error("Connection failed: \(error.localizedDescription, privacy: .public)")
            stateHandler?(.failed(error.localizedDescription))
        case .cancelled:
            isReady = false
            stateHandler?(.closed)
        @unknown default:
            break
        }
    }

    private func write(_ data: Data) {
        bytesInFlight += data.count
        lastSendTime = .now()
        let size = data.count
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.bytesInFlight -= size
            if let error {
                self.logger.error("Send failed: \(error.localizedDescription, privacy: .public)")
                return
            }
            self.bytesSentHandler?(size)
        })
    }

    private func startPing() {
        pingTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self, self.isReady else { return }
            if DispatchTime.now().uptimeNanoseconds - self.lastSendTime.uptimeNanoseconds > 1_000_000_000 {
                self.write(WireProtocol.message(.ping))
            }
        }
        timer.resume()
        pingTimer = timer
    }
}
