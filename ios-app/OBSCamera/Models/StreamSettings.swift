import AVFoundation
import Foundation
import os

enum VideoSourceKind: String, CaseIterable, Identifiable, Codable {
    case backCamera
    case frontCamera
    case testPattern

    var id: String { rawValue }

    var title: String {
        switch self {
        case .backCamera: "Основная камера"
        case .frontCamera: "Фронтальная камера"
        case .testPattern: "Тестовая картинка"
        }
    }
}

enum VideoResolution: String, CaseIterable, Identifiable, Codable {
    case hd720 = "720p"
    case hd1080 = "1080p"

    var id: String { rawValue }

    /// Sensor (landscape) dimensions.
    var landscapeSize: (width: Int32, height: Int32) {
        switch self {
        case .hd720: (1280, 720)
        case .hd1080: (1920, 1080)
        }
    }

    var sessionPreset: AVCaptureSession.Preset {
        switch self {
        case .hd720: .hd1280x720
        case .hd1080: .hd1920x1080
        }
    }
}

enum VideoOrientation: String, CaseIterable, Identifiable, Codable {
    case landscape
    case portrait

    var id: String { rawValue }

    var title: String {
        switch self {
        case .landscape: "Горизонтально"
        case .portrait: "Вертикально"
        }
    }

    /// `AVCaptureConnection.videoRotationAngle` for this orientation.
    var rotationAngle: CGFloat {
        switch self {
        case .landscape: 0
        case .portrait: 90
        }
    }
}

struct StreamSettings: Codable, Equatable {
    var source: VideoSourceKind = .backCamera
    var resolution: VideoResolution = .hd1080
    var frameRate: Int = 30
    var bitrateMbps: Double = 8
    var orientation: VideoOrientation = .landscape

    static let supportedFrameRates = [24, 30, 60]

    /// Output frame size after rotation.
    var outputSize: (width: Int32, height: Int32) {
        let size = resolution.landscapeSize
        return orientation == .landscape ? size : (size.height, size.width)
    }

    var bitrateBitsPerSecond: Int { Int(bitrateMbps * 1_000_000) }
}

extension StreamSettings {
    private static let defaultsKey = "streamSettings"
    private static let logger = Logger(subsystem: "com.obscamera.app", category: "Settings")

    static func load(from defaults: UserDefaults = .standard) -> StreamSettings {
        guard let data = defaults.data(forKey: defaultsKey) else { return StreamSettings() }
        do {
            return try JSONDecoder().decode(StreamSettings.self, from: data)
        } catch {
            logger.error("Failed to decode saved settings: \(error.localizedDescription, privacy: .public)")
            return StreamSettings()
        }
    }

    func save(to defaults: UserDefaults = .standard) {
        do {
            defaults.set(try JSONEncoder().encode(self), forKey: Self.defaultsKey)
        } catch {
            Self.logger.error("Failed to save settings: \(error.localizedDescription, privacy: .public)")
        }
    }
}
