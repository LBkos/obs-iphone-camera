import AVFoundation
import Foundation
import os

enum VideoSourceKind: String, CaseIterable, Identifiable, Codable {
    case backCamera
    case backUltraWide
    case backTelephoto
    case frontCamera
    case testPattern

    var id: String { rawValue }

    var title: String {
        switch self {
        case .backCamera: "Основная камера"
        case .backUltraWide: "Сверхширокая камера"
        case .backTelephoto: "Телекамера"
        case .frontCamera: "Фронтальная камера"
        case .testPattern: "Тестовая картинка"
        }
    }
}

enum VideoResolution: String, CaseIterable, Identifiable, Codable {
    case hd720 = "720p"
    case hd1080 = "1080p"
    case uhd4K = "4K"

    var id: String { rawValue }

    /// Sensor (landscape) dimensions.
    var landscapeSize: (width: Int32, height: Int32) {
        switch self {
        case .hd720: (1280, 720)
        case .hd1080: (1920, 1080)
        case .uhd4K: (3840, 2160)
        }
    }

    var sessionPreset: AVCaptureSession.Preset {
        switch self {
        case .hd720: .hd1280x720
        case .hd1080: .hd1920x1080
        case .uhd4K: .hd4K3840x2160
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

enum VideoCodec: String, CaseIterable, Identifiable, Codable {
    case h264
    case hevc

    var id: String { rawValue }

    var title: String {
        switch self {
        case .h264: "H.264"
        case .hevc: "HEVC (H.265)"
        }
    }
}

enum H264Profile: String, CaseIterable, Identifiable, Codable {
    case baseline
    case main
    case high

    var id: String { rawValue }

    var title: String {
        switch self {
        case .baseline: "Baseline"
        case .main: "Main"
        case .high: "High"
        }
    }
}

enum StabilizationMode: String, CaseIterable, Identifiable, Codable {
    case off
    case standard
    case cinematic
    case auto

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: "Выкл."
        case .standard: "Стандартная"
        case .cinematic: "Кинематографическая"
        case .auto: "Авто"
        }
    }

    var avMode: AVCaptureVideoStabilizationMode {
        switch self {
        case .off: .off
        case .standard: .standard
        case .cinematic: .cinematic
        case .auto: .auto
        }
    }
}

struct StreamSettings: Codable, Equatable {
    var source: VideoSourceKind = .backCamera
    var resolution: VideoResolution = .hd1080
    var frameRate: Int = 30
    var bitrateMbps: Double = 8
    var orientation: VideoOrientation = .landscape
    var codec: VideoCodec = .h264
    var h264Profile: H264Profile = .high
    /// Seconds between keyframes.
    var keyframeInterval: Double = 2
    /// HLG, 10-bit. Only with HEVC and a camera format that supports it.
    var hdr = false
    /// Mirrors the video sent to OBS (and the preview, so it matches).
    var mirror = false
    /// Adds latency, so it is off by default.
    var stabilization: StabilizationMode = .off
    var lowLightBoost = false
    var audioEnabled = false

    static let supportedFrameRates = [24, 30, 60, 120, 240]
    static let keyframeIntervals: [Double] = [0.5, 1, 2, 4]
    static let bitrateRange: ClosedRange<Double> = 2...50

    /// HDR is only produced with HEVC (H.264 has no 10-bit hardware encoding on iPhone).
    var isHDRActive: Bool { hdr && codec == .hevc }

    /// Output frame size after rotation.
    var outputSize: (width: Int32, height: Int32) {
        let size = resolution.landscapeSize
        return orientation == .landscape ? size : (size.height, size.width)
    }

    var bitrateBitsPerSecond: Int { Int(bitrateMbps * 1_000_000) }

    init() {}

    // Settings saved by an older version miss the newer keys: fall back to defaults per key.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = StreamSettings()
        source = (try? container.decodeIfPresent(VideoSourceKind.self, forKey: .source)) ?? defaults.source
        resolution = (try? container.decodeIfPresent(VideoResolution.self, forKey: .resolution)) ?? defaults.resolution
        frameRate = (try? container.decodeIfPresent(Int.self, forKey: .frameRate)) ?? defaults.frameRate
        bitrateMbps = (try? container.decodeIfPresent(Double.self, forKey: .bitrateMbps)) ?? defaults.bitrateMbps
        orientation = (try? container.decodeIfPresent(VideoOrientation.self, forKey: .orientation)) ?? defaults.orientation
        codec = (try? container.decodeIfPresent(VideoCodec.self, forKey: .codec)) ?? defaults.codec
        h264Profile = (try? container.decodeIfPresent(H264Profile.self, forKey: .h264Profile)) ?? defaults.h264Profile
        keyframeInterval = (try? container.decodeIfPresent(Double.self, forKey: .keyframeInterval))
            ?? defaults.keyframeInterval
        hdr = (try? container.decodeIfPresent(Bool.self, forKey: .hdr)) ?? defaults.hdr
        mirror = (try? container.decodeIfPresent(Bool.self, forKey: .mirror)) ?? defaults.mirror
        stabilization = (try? container.decodeIfPresent(StabilizationMode.self, forKey: .stabilization))
            ?? defaults.stabilization
        lowLightBoost = (try? container.decodeIfPresent(Bool.self, forKey: .lowLightBoost)) ?? defaults.lowLightBoost
        audioEnabled = (try? container.decodeIfPresent(Bool.self, forKey: .audioEnabled)) ?? defaults.audioEnabled
    }
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
