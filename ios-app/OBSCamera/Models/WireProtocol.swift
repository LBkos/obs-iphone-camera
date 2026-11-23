import Foundation

/// Wire protocol shared with the OBS plugin.
/// Keep in sync with obs-plugin/src/protocol.h.
///
/// Every message: `[type: u8][length: u32 BE][payload]`
/// Mostly phone → OBS; OBS sends only `controls`.
enum WireProtocol {
    static let serviceType = "_obsiphonecam._tcp"
    /// Wi‑Fi: the OBS plugin listens here, the app connects.
    static let defaultPort: UInt16 = 47100
    /// USB: the app listens here (loopback), the plugin connects via usbmuxd.
    static let usbDevicePort: UInt16 = 47101

    enum MessageType: UInt8 {
        case hello = 0x01   // UTF-8 device name
        case config = 0x02  // parameter sets, Annex-B: SPS + PPS (H.264) or VPS + SPS + PPS (HEVC)
        case frame = 0x03   // [pts_us: u64 BE][flags: u8][access unit, Annex-B]
        case ping = 0x04    // keep-alive
        case codec = 0x05   // [codec: u8], sent before every config
        case audio = 0x06   // [pts_us: u64 BE][sample_rate: u32 BE][channels: u8][PCM s16le interleaved]
        case capabilities = 0x07 // UTF-8 JSON (see `capabilitiesMessage`)
        case controls = 0x08     // OBS → phone: UTF-8 JSON camera controls, empty = OBS released control
    }

    enum Codec: UInt8 {
        case h264 = 0
        case hevc = 1
    }

    static let keyframeFlag: UInt8 = 0x01
    static let headerSize = 5
    /// Messages from OBS are small JSON; anything bigger is a broken stream.
    static let maxIncomingPayload = 64 * 1024
    static let annexBStartCode: [UInt8] = [0, 0, 0, 1]

    static func message(_ type: MessageType, payload: Data = Data()) -> Data {
        var data = Data(capacity: 5 + payload.count)
        data.append(type.rawValue)
        data.appendBigEndian(UInt32(payload.count))
        data.append(payload)
        return data
    }

    static func frameMessage(ptsMicros: UInt64, isKeyframe: Bool, annexB: Data) -> Data {
        var payload = Data(capacity: 9 + annexB.count)
        payload.appendBigEndian(ptsMicros)
        payload.append(isKeyframe ? keyframeFlag : 0)
        payload.append(annexB)
        return message(.frame, payload: payload)
    }

    /// The plugin parses JSON with obs_data, which skips plain numbers inside
    /// arrays, so shutter speeds go as `{"value": n}` objects.
    /// `profiles`: `{"id", "name", "controls"}`, controls with the same keys as a
    /// `controls` message (no torch). OBS applies only these camera values, never
    /// the format or encoding, so picking a profile there doesn't restart the video.
    static func capabilitiesMessage(_ caps: CameraCapabilities, profiles: [CameraProfile]) -> Data {
        let json: [String: Any] = [
            "profiles": profiles.map { profile -> [String: Any] in
                let controls = (try? JSONEncoder().encode(profile.controls))
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? [String: Any]()
                return ["id": profile.id.uuidString, "name": profile.name, "controls": controls]
            },
            "minZoom": caps.minZoom,
            "maxZoom": caps.maxZoom,
            "supportsFocusLock": caps.supportsFocusLock,
            "supportsManualFocus": caps.supportsManualFocus,
            "supportsExposureLock": caps.supportsExposureLock,
            "supportsManualExposure": caps.supportsManualExposure,
            "minISO": caps.minISO,
            "maxISO": caps.maxISO,
            "minExposureBias": caps.minExposureBias,
            "maxExposureBias": caps.maxExposureBias,
            "shutterDenominators": caps.shutterDenominators.map { ["value": $0] },
            "supportsWhiteBalanceLock": caps.supportsWhiteBalanceLock,
            "supportsManualWhiteBalance": caps.supportsManualWhiteBalance,
            "hasTorch": caps.hasTorch,
        ]
        let payload = (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])) ?? Data()
        return message(.capabilities, payload: payload)
    }

    /// Payload of a `controls` message. nil means OBS gave control back to the app.
    static func decodeControls(_ payload: Data) throws -> CameraControls? {
        guard !payload.isEmpty else { return nil }
        return try JSONDecoder().decode(RemoteControls.self, from: payload).controls
    }

    static func audioMessage(ptsMicros: UInt64, sampleRate: UInt32, channels: UInt8, pcm: Data) -> Data {
        var payload = Data(capacity: 13 + pcm.count)
        payload.appendBigEndian(ptsMicros)
        payload.appendBigEndian(sampleRate)
        payload.append(channels)
        payload.append(pcm)
        return message(.audio, payload: payload)
    }
}

/// `CameraControls` doesn't encode the torch (it is never restored at launch),
/// but OBS sends it along with the rest.
private struct RemoteControls: Decodable {
    var controls: CameraControls

    private enum CodingKeys: String, CodingKey { case torch }

    init(from decoder: Decoder) throws {
        controls = try CameraControls(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        controls.torch = (try? container.decodeIfPresent(Bool.self, forKey: .torch)) ?? false
    }
}

extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { append(contentsOf: $0) }
    }
}
