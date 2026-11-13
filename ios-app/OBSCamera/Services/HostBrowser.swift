import Foundation
import Network
import os

/// Finds OBS instances advertising `_obsiphonecam._tcp` on the local network.
final class HostBrowser: @unchecked Sendable {
    /// Called on the main queue.
    var hostsHandler: (([OBSHost]) -> Void)?
    /// Called on the main queue; nil when browsing works.
    var errorHandler: ((String?) -> Void)?

    private var browser: NWBrowser?
    private let logger = Logger(subsystem: "com.obscamera.app", category: "Discovery")

    func start() {
        guard browser == nil else { return }
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: WireProtocol.serviceType, domain: nil), using: parameters)

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let hosts = results.compactMap { result -> OBSHost? in
                guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                return OBSHost(name: name, endpoint: result.endpoint)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            self?.hostsHandler?(hosts)
        }
        browser.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed(let error), .waiting(let error):
                self.logger.error("Bonjour browsing problem: \(error.localizedDescription, privacy: .public)")
                if case .dns(let code) = error, code == -65570 { // kDNSServiceErr_PolicyDenied
                    self.errorHandler?("Нет доступа к локальной сети. Разрешите его в Настройках → Конфиденциальность → Локальная сеть.")
                } else {
                    self.errorHandler?(error.localizedDescription)
                }
                if case .failed = state {
                    self.restart()
                }
            case .ready:
                self.errorHandler?(nil)
            default:
                break
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }

    private func restart() {
        stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.start() }
    }
}
