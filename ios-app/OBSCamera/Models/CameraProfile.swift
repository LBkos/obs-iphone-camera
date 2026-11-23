import Foundation
import os

/// A saved setup: the stream settings plus the camera values (the torch is not saved).
/// OBS can apply the camera values of a profile (see `WireProtocol.capabilitiesMessage`).
struct CameraProfile: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var settings: StreamSettings
    var controls: CameraControls

    /// "Основная · 1080p 30 · ISO 800 · 1/50 · ББ 4300K"
    var summary: String {
        var parts = [settings.source.shortTitle, "\(settings.resolution.rawValue) \(settings.frameRate)"]
        if settings.codec == .hevc { parts.append("HEVC") }
        if controls.zoom > 1.01 { parts.append(String(format: "%.1f×", controls.zoom)) }
        switch controls.exposureMode {
        case .manual: parts.append("ISO \(Int(controls.iso)) · 1/\(controls.shutterDenominator)")
        case .locked: parts.append("экспозиция фикс.")
        case .auto: if abs(controls.exposureBias) > 0.05 { parts.append(String(format: "EV %+.1f", controls.exposureBias)) }
        }
        switch controls.whiteBalanceMode {
        case .manual: parts.append("ББ \(Int(controls.temperature))K")
        case .locked: parts.append("ББ фикс.")
        case .auto: break
        }
        if controls.focusMode != .auto { parts.append("фокус \(controls.focusMode.title.lowercased())") }
        return parts.joined(separator: " · ")
    }

    /// Same setup as this profile (the torch doesn't count).
    func matches(settings: StreamSettings, controls: CameraControls) -> Bool {
        var current = controls
        current.torch = self.controls.torch
        return self.settings == settings && self.controls == current
    }
}

extension CameraProfile {
    private static let defaultsKey = "cameraProfiles"
    private static let logger = Logger(subsystem: "com.obscamera.app", category: "Settings")

    static func loadAll(from defaults: UserDefaults = .standard) -> [CameraProfile] {
        guard let data = defaults.data(forKey: defaultsKey) else { return [] }
        do {
            return try JSONDecoder().decode([CameraProfile].self, from: data)
        } catch {
            logger.error("Failed to decode saved profiles: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    static func saveAll(_ profiles: [CameraProfile], to defaults: UserDefaults = .standard) {
        do {
            defaults.set(try JSONEncoder().encode(profiles), forKey: defaultsKey)
        } catch {
            logger.error("Failed to save profiles: \(error.localizedDescription, privacy: .public)")
        }
    }
}
