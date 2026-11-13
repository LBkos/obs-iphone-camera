import Foundation
import Network

/// A computer running OBS with the iPhone Camera source, found via Bonjour
/// or entered manually.
struct OBSHost: Identifiable, Hashable {
    let id: String
    let name: String
    let endpoint: NWEndpoint

    init(name: String, endpoint: NWEndpoint) {
        self.id = "\(endpoint)"
        self.name = name
        self.endpoint = endpoint
    }

    /// Parses "192.168.1.10" or "192.168.1.10:47100" (or a host name).
    static func manual(_ address: String) -> OBSHost? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var host = trimmed
        var port = WireProtocol.defaultPort
        if let colon = trimmed.lastIndex(of: ":"), trimmed.filter({ $0 == ":" }).count == 1 {
            host = String(trimmed[..<colon])
            guard let parsed = UInt16(trimmed[trimmed.index(after: colon)...]) else { return nil }
            port = parsed
        }
        guard !host.isEmpty, let nwPort = NWEndpoint.Port(rawValue: port) else { return nil }
        return OBSHost(name: trimmed, endpoint: .hostPort(host: NWEndpoint.Host(host), port: nwPort))
    }
}
