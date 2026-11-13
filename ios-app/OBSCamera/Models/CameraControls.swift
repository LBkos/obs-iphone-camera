import Foundation
import os

/// Auto / locked at the current value / set by hand.
enum ControlMode: String, CaseIterable, Identifiable, Codable {
    case auto
    case locked
    case manual

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: "Авто"
        case .locked: "Фикс."
        case .manual: "Вручную"
        }
    }
}

/// Live camera adjustments. Unlike `StreamSettings`, changing these never
/// restarts the capture session or the encoder.
struct CameraControls: Codable, Equatable {
    var zoom: Double = 1

    var focusMode: ControlMode = .auto
    /// 0 = closest, 1 = farthest.
    var lensPosition: Float = 0.5

    var exposureMode: ControlMode = .auto
    /// EV, used in auto mode.
    var exposureBias: Float = 0
    var iso: Float = 100
    /// Shutter speed is 1/shutterDenominator s.
    var shutterDenominator: Int = 60

    var whiteBalanceMode: ControlMode = .auto
    /// Kelvin.
    var temperature: Float = 5000
    var tint: Float = 0

    /// Not saved: the flashlight should never turn on by itself at launch.
    var torch = false

    static let temperatureRange: ClosedRange<Float> = 2500...8000
    static let tintRange: ClosedRange<Float> = -150...150
    static let maxZoom: Double = 10
    static let shutterDenominators = [24, 25, 30, 48, 50, 60, 100, 120, 125, 180, 240, 250, 500, 1000, 2000, 4000, 8000]

    private enum CodingKeys: String, CodingKey {
        case zoom, focusMode, lensPosition, exposureMode, exposureBias, iso, shutterDenominator
        case whiteBalanceMode, temperature, tint
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = CameraControls()
        zoom = (try? container.decodeIfPresent(Double.self, forKey: .zoom)) ?? defaults.zoom
        focusMode = (try? container.decodeIfPresent(ControlMode.self, forKey: .focusMode)) ?? defaults.focusMode
        lensPosition = (try? container.decodeIfPresent(Float.self, forKey: .lensPosition)) ?? defaults.lensPosition
        exposureMode = (try? container.decodeIfPresent(ControlMode.self, forKey: .exposureMode)) ?? defaults.exposureMode
        exposureBias = (try? container.decodeIfPresent(Float.self, forKey: .exposureBias)) ?? defaults.exposureBias
        iso = (try? container.decodeIfPresent(Float.self, forKey: .iso)) ?? defaults.iso
        shutterDenominator = (try? container.decodeIfPresent(Int.self, forKey: .shutterDenominator))
            ?? defaults.shutterDenominator
        whiteBalanceMode = (try? container.decodeIfPresent(ControlMode.self, forKey: .whiteBalanceMode))
            ?? defaults.whiteBalanceMode
        temperature = (try? container.decodeIfPresent(Float.self, forKey: .temperature)) ?? defaults.temperature
        tint = (try? container.decodeIfPresent(Float.self, forKey: .tint)) ?? defaults.tint
    }
}

/// What the active camera supports. Published after each (re)configuration.
struct CameraCapabilities: Equatable {
    var minZoom: Double = 1
    var maxZoom: Double = 1
    var supportsFocusLock = false
    var supportsManualFocus = false
    var supportsExposureLock = false
    var supportsManualExposure = false
    var minISO: Float = 0
    var maxISO: Float = 0
    var minExposureBias: Float = 0
    var maxExposureBias: Float = 0
    /// Shutter speeds (1/x s) the active format and frame rate allow.
    var shutterDenominators: [Int] = []
    var supportsWhiteBalanceLock = false
    var supportsManualWhiteBalance = false
    var hasTorch = false
    var supportsLowLightBoost = false
}

/// Current automatic values, used to start manual mode from where auto was.
struct CameraReadings {
    var lensPosition: Float
    var iso: Float
    var exposureSeconds: Double
    var temperature: Float
    var tint: Float
}

extension CameraControls {
    private static let defaultsKey = "cameraControls"
    private static let logger = Logger(subsystem: "com.obscamera.app", category: "Settings")

    static func load(from defaults: UserDefaults = .standard) -> CameraControls {
        guard let data = defaults.data(forKey: defaultsKey) else { return CameraControls() }
        do {
            return try JSONDecoder().decode(CameraControls.self, from: data)
        } catch {
            logger.error("Failed to decode saved camera controls: \(error.localizedDescription, privacy: .public)")
            return CameraControls()
        }
    }

    func save(to defaults: UserDefaults = .standard) {
        do {
            defaults.set(try JSONEncoder().encode(self), forKey: Self.defaultsKey)
        } catch {
            Self.logger.error("Failed to save camera controls: \(error.localizedDescription, privacy: .public)")
        }
    }
}
