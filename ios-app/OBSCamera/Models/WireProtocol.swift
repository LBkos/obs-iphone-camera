import Foundation

/// Wire protocol shared with the OBS plugin.
/// Keep in sync with obs-plugin/src/protocol.h.
///
/// Every message: `[type: u8][length: u32 BE][payload]`
enum WireProtocol {
    static let serviceType = "_obsiphonecam._tcp"
    /// Wi‑Fi: the OBS plugin listens here, the app connects.
    static let defaultPort: UInt16 = 47100
    /// USB: the app listens here (loopback), the plugin connects via usbmuxd.
    static let usbDevicePort: UInt16 = 47101

    enum MessageType: UInt8 {
        case hello = 0x01   // UTF-8 device name
        case config = 0x02  // SPS + PPS, Annex-B
        case frame = 0x03   // [pts_us: u64 BE][flags: u8][access unit, Annex-B]
        case ping = 0x04    // keep-alive
    }

    static let keyframeFlag: UInt8 = 0x01
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
}

extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { append(contentsOf: $0) }
    }
}
