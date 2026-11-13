import Foundation

/// How the app reaches OBS.
enum ConnectionMode: String, CaseIterable, Identifiable {
    /// The app connects to OBS over the local network (found via Bonjour or by IP).
    case wifi
    /// The app listens on the device; OBS connects through the USB cable (usbmuxd).
    case usb

    var id: String { rawValue }

    var title: String {
        switch self {
        case .wifi: "Wi‑Fi"
        case .usb: "USB-кабель"
        }
    }

    private static let defaultsKey = "connectionMode"

    static func load(from defaults: UserDefaults = .standard) -> ConnectionMode {
        defaults.string(forKey: defaultsKey).flatMap(ConnectionMode.init(rawValue:)) ?? .wifi
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }
}
