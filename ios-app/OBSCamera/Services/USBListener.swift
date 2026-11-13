import Foundation
import Network
import os

/// Listens for the OBS plugin connecting through the USB cable.
///
/// Over USB the computer can't be reached from the phone, so the direction is
/// reversed: usbmuxd on the computer tunnels the plugin's TCP connection to
/// this port on the device's loopback interface. Binding to loopback only
/// keeps the port invisible on Wi‑Fi.
final class USBListener: @unchecked Sendable {
    /// Called on the listener's queue for every accepted connection.
    var connectionHandler: ((NWConnection) -> Void)?

    private let queue = DispatchQueue(label: "com.obscamera.usb-listener")
    private var listener: NWListener?
    private var isActive = false
    private let logger = Logger(subsystem: "com.obscamera.app", category: "USB")

    func start() {
        queue.async { [self] in
            isActive = true
            startListener()
        }
    }

    func stop() {
        queue.async { [self] in
            isActive = false
            listener?.cancel()
            listener = nil
        }
    }

    // MARK: - Private (queue)

    private func startListener() {
        guard isActive, listener == nil,
              let port = NWEndpoint.Port(rawValue: WireProtocol.usbDevicePort) else { return }

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            logger.error("Failed to create USB listener: \(error.localizedDescription, privacy: .public)")
            retryLater()
            return
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.logger.info("OBS connected over USB")
            self?.connectionHandler?(connection)
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.logger.info("Waiting for OBS on loopback port \(WireProtocol.usbDevicePort)")
            case .failed(let error):
                self.logger.error("USB listener failed: \(error.localizedDescription, privacy: .public)")
                listener?.cancel()
                if self.listener === listener { self.listener = nil }
                self.retryLater()
            default:
                break
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    private func retryLater() {
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.startListener() }
    }
}
