import CoreMedia
import Foundation
import os
import VideoToolbox

struct EncodedFrame {
    let codec: WireProtocol.Codec
    /// Access unit in Annex-B form.
    let annexB: Data
    /// Parameter sets in Annex-B form (SPS + PPS, or VPS + SPS + PPS for HEVC); present on keyframes.
    let parameterSets: Data?
    let ptsMicros: UInt64
    let isKeyframe: Bool
}

/// The `StreamSettings` fields the encoder uses. Other settings changes
/// (mirror, stabilization, ...) don't recreate the encoder.
struct EncoderConfig: Equatable {
    var codec: VideoCodec = .h264
    var h264Profile: H264Profile = .high
    var bitrate = 8_000_000
    var frameRate = 30
    var keyframeInterval: Double = 2

    init() {}

    init(_ settings: StreamSettings) {
        codec = settings.codec
        h264Profile = settings.h264Profile
        bitrate = settings.bitrateBitsPerSecond
        frameRate = settings.frameRate
        keyframeInterval = settings.keyframeInterval
    }
}

/// Low-latency hardware H.264 / HEVC encoder (VideoToolbox).
/// 10-bit input (HDR camera formats) is encoded as HEVC Main10 with HLG tags.
final class VideoEncoder: @unchecked Sendable {
    var outputHandler: ((EncodedFrame) -> Void)?

    private let lock = NSLock()
    private var session: VTCompressionSession?
    private var sessionSize: (width: Int32, height: Int32) = (0, 0)
    private var sessionTenBit = false
    private var config = EncoderConfig()
    private var forceKeyframe = true
    private let logger = Logger(subsystem: "com.obscamera.app", category: "Encoder")

    deinit {
        invalidate()
    }

    func update(settings: StreamSettings) {
        let config = EncoderConfig(settings)
        lock.lock()
        defer { lock.unlock() }
        guard config != self.config else { return }
        self.config = config
        invalidateLocked() // recreated on the next frame
    }

    func requestKeyframe() {
        lock.lock()
        forceKeyframe = true
        lock.unlock()
    }

    func invalidate() {
        lock.lock()
        invalidateLocked()
        lock.unlock()
    }

    func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        lock.lock()
        let width = Int32(CVPixelBufferGetWidth(pixelBuffer))
        let height = Int32(CVPixelBufferGetHeight(pixelBuffer))
        let tenBit = CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        if session == nil || sessionSize != (width, height) || sessionTenBit != tenBit {
            invalidateLocked()
            session = makeSession(width: width, height: height, tenBit: tenBit)
            sessionSize = (width, height)
            sessionTenBit = tenBit
            forceKeyframe = true
        }
        guard let session else {
            lock.unlock()
            return
        }
        let properties: CFDictionary? = forceKeyframe
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary
            : nil
        forceKeyframe = false
        lock.unlock()

        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer, presentationTimeStamp: pts, duration: .invalid,
            frameProperties: properties, infoFlagsOut: nil
        ) { [weak self] status, _, sampleBuffer in
            self?.handleOutput(status: status, sampleBuffer: sampleBuffer)
        }
        if status != noErr {
            logger.error("VTCompressionSessionEncodeFrame failed: \(status)")
            requestKeyframe()
        }
    }

    // MARK: - Session

    private func invalidateLocked() {
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
        session = nil
    }

    private func makeSession(width: Int32, height: Int32, tenBit: Bool) -> VTCompressionSession? {
        // 10-bit frames only come with HEVC selected (see CameraCaptureService); H.264 can't take them.
        let hevc = config.codec == .hevc || tenBit
        var newSession: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: width, height: height,
            codecType: hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
            encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &newSession
        )
        guard status == noErr, let newSession else {
            logger.error("VTCompressionSessionCreate failed: \(status)")
            return nil
        }

        let bitrate = config.bitrate
        let fps = config.frameRate
        let keyframeSeconds = config.keyframeInterval
        let profile: CFString
        if hevc {
            profile = tenBit ? kVTProfileLevel_HEVC_Main10_AutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel
        } else {
            switch config.h264Profile {
            case .baseline: profile = kVTProfileLevel_H264_Baseline_AutoLevel
            case .main: profile = kVTProfileLevel_H264_Main_AutoLevel
            case .high: profile = kVTProfileLevel_H264_High_AutoLevel
            }
        }
        // 10-bit camera formats are HLG (BT.2100), everything else BT.709.
        let colorPrimaries = tenBit ? kCVImageBufferColorPrimaries_ITU_R_2020 : kCVImageBufferColorPrimaries_ITU_R_709_2
        let transferFunction = tenBit ? kCVImageBufferTransferFunction_ITU_R_2100_HLG
            : kCVImageBufferTransferFunction_ITU_R_709_2
        let matrix = tenBit ? kCVImageBufferYCbCrMatrix_ITU_R_2020 : kCVImageBufferYCbCrMatrix_ITU_R_709_2
        let properties: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: kCFBooleanTrue!,
            kVTCompressionPropertyKey_ProfileLevel: profile,
            kVTCompressionPropertyKey_AllowFrameReordering: kCFBooleanFalse!, // no B-frames
            kVTCompressionPropertyKey_AverageBitRate: bitrate,
            kVTCompressionPropertyKey_DataRateLimits: [Double(bitrate) * 1.5 / 8, 1.0] as CFArray,
            kVTCompressionPropertyKey_ExpectedFrameRate: fps,
            kVTCompressionPropertyKey_MaxKeyFrameInterval: max(1, Int((Double(fps) * keyframeSeconds).rounded())),
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: keyframeSeconds,
            kVTCompressionPropertyKey_ColorPrimaries: colorPrimaries,
            kVTCompressionPropertyKey_TransferFunction: transferFunction,
            kVTCompressionPropertyKey_YCbCrMatrix: matrix
        ]
        for (key, value) in properties {
            let result = VTSessionSetProperty(newSession, key: key, value: value as CFTypeRef)
            if result != noErr {
                logger.warning("VTSessionSetProperty \(key as String, privacy: .public) failed: \(result)")
            }
        }
        VTCompressionSessionPrepareToEncodeFrames(newSession)
        logger.info("Encoder ready: \(hevc ? "HEVC" : "H.264", privacy: .public)\(tenBit ? " 10-bit HLG" : "", privacy: .public) \(width)x\(height)@\(fps) \(bitrate / 1000) kbps")
        return newSession
    }

    // MARK: - Output

    private func handleOutput(status: OSStatus, sampleBuffer: CMSampleBuffer?) {
        guard status == noErr, let sampleBuffer, CMSampleBufferDataIsReady(sampleBuffer) else {
            if status != noErr {
                logger.error("Encoder output error: \(status)")
                requestKeyframe()
            }
            return
        }

        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[CFString: Any]]
        let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        let isKeyframe = !notSync

        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        // From the frame itself, not `config`: settings may have changed while it was in flight.
        let codec: WireProtocol.Codec = CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_HEVC
            ? .hevc : .h264
        var nalLengthSize: Int32 = 4
        var parameterSets: Data?
        if isKeyframe {
            parameterSets = Self.parameterSets(of: format, codec: codec, nalLengthSize: &nalLengthSize)
        }

        let length = CMBlockBufferGetDataLength(dataBuffer)
        var avcc = Data(count: length)
        let copyStatus = avcc.withUnsafeMutableBytes { bytes in
            CMBlockBufferCopyDataBytes(dataBuffer, atOffset: 0, dataLength: length, destination: bytes.baseAddress!)
        }
        guard copyStatus == kCMBlockBufferNoErr else {
            logger.error("CMBlockBufferCopyDataBytes failed: \(copyStatus)")
            return
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let ptsMicros = pts.isValid ? UInt64(max(0, CMTimeConvertScale(pts, timescale: 1_000_000, method: .default).value)) : 0
        outputHandler?(EncodedFrame(
            codec: codec,
            annexB: Self.annexB(fromAVCC: avcc, nalLengthSize: Int(nalLengthSize)),
            parameterSets: parameterSets,
            ptsMicros: ptsMicros,
            isKeyframe: isKeyframe
        ))
    }

    /// H.264 and HEVC have the same accessor shape; this picks the right one.
    private static func parameterSet(
        of format: CMFormatDescription, codec: WireProtocol.Codec, index: Int,
        pointer: UnsafeMutablePointer<UnsafePointer<UInt8>?>?, size: UnsafeMutablePointer<Int>?,
        count: UnsafeMutablePointer<Int>?, nalLengthSize: UnsafeMutablePointer<Int32>?
    ) -> OSStatus {
        switch codec {
        case .h264:
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: index, parameterSetPointerOut: pointer, parameterSetSizeOut: size,
                parameterSetCountOut: count, nalUnitHeaderLengthOut: nalLengthSize)
        case .hevc:
            CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                format, parameterSetIndex: index, parameterSetPointerOut: pointer, parameterSetSizeOut: size,
                parameterSetCountOut: count, nalUnitHeaderLengthOut: nalLengthSize)
        }
    }

    private static func parameterSets(of format: CMFormatDescription, codec: WireProtocol.Codec,
                                      nalLengthSize: inout Int32) -> Data? {
        var count = 0
        let status = parameterSet(of: format, codec: codec, index: 0, pointer: nil, size: nil, count: &count,
                                  nalLengthSize: &nalLengthSize)
        guard status == noErr else { return nil }

        var data = Data()
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            guard parameterSet(of: format, codec: codec, index: index, pointer: &pointer, size: &size, count: nil,
                               nalLengthSize: nil) == noErr, let pointer else { continue }
            data.append(contentsOf: WireProtocol.annexBStartCode)
            data.append(pointer, count: size)
        }
        return data
    }

    /// Replaces AVCC length prefixes with Annex-B start codes.
    static func annexB(fromAVCC avcc: Data, nalLengthSize: Int) -> Data {
        var output = Data(capacity: avcc.count + 16)
        avcc.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            var offset = 0
            while offset + nalLengthSize <= bytes.count {
                var nalLength = 0
                for i in 0..<nalLengthSize {
                    nalLength = (nalLength << 8) | Int(bytes[offset + i])
                }
                offset += nalLengthSize
                guard nalLength > 0, offset + nalLength <= bytes.count else { break }
                output.append(contentsOf: WireProtocol.annexBStartCode)
                output.append(bytes.baseAddress! + offset, count: nalLength)
                offset += nalLength
            }
        }
        return output
    }
}
