import CoreMedia
import Foundation
import os
import VideoToolbox

struct EncodedFrame {
    /// Access unit in Annex-B form.
    let annexB: Data
    /// SPS + PPS in Annex-B form; present on keyframes.
    let parameterSets: Data?
    let ptsMicros: UInt64
    let isKeyframe: Bool
}

/// Low-latency hardware H.264 encoder (VideoToolbox).
final class H264Encoder: @unchecked Sendable {
    var outputHandler: ((EncodedFrame) -> Void)?

    private let lock = NSLock()
    private var session: VTCompressionSession?
    private var sessionSize: (width: Int32, height: Int32) = (0, 0)
    private var settings = StreamSettings()
    private var forceKeyframe = true
    private let logger = Logger(subsystem: "com.obscamera.app", category: "Encoder")

    deinit {
        invalidate()
    }

    func update(settings: StreamSettings) {
        lock.lock()
        defer { lock.unlock() }
        guard settings != self.settings else { return }
        self.settings = settings
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
        if session == nil || sessionSize != (width, height) {
            invalidateLocked()
            session = makeSession(width: width, height: height)
            sessionSize = (width, height)
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

    private func makeSession(width: Int32, height: Int32) -> VTCompressionSession? {
        var newSession: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: width, height: height, codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &newSession
        )
        guard status == noErr, let newSession else {
            logger.error("VTCompressionSessionCreate failed: \(status)")
            return nil
        }

        let bitrate = settings.bitrateBitsPerSecond
        let fps = settings.frameRate
        let properties: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: kCFBooleanTrue!,
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_High_AutoLevel,
            kVTCompressionPropertyKey_AllowFrameReordering: kCFBooleanFalse!, // no B-frames
            kVTCompressionPropertyKey_AverageBitRate: bitrate,
            kVTCompressionPropertyKey_DataRateLimits: [Double(bitrate) * 1.5 / 8, 1.0] as CFArray,
            kVTCompressionPropertyKey_ExpectedFrameRate: fps,
            kVTCompressionPropertyKey_MaxKeyFrameInterval: fps * 2,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 2,
            kVTCompressionPropertyKey_ColorPrimaries: kCVImageBufferColorPrimaries_ITU_R_709_2,
            kVTCompressionPropertyKey_TransferFunction: kCVImageBufferTransferFunction_ITU_R_709_2,
            kVTCompressionPropertyKey_YCbCrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2
        ]
        for (key, value) in properties {
            let result = VTSessionSetProperty(newSession, key: key, value: value as CFTypeRef)
            if result != noErr {
                logger.warning("VTSessionSetProperty \(key as String, privacy: .public) failed: \(result)")
            }
        }
        VTCompressionSessionPrepareToEncodeFrames(newSession)
        logger.info("Encoder ready: \(width)x\(height)@\(fps) \(bitrate / 1000) kbps")
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

        var nalLengthSize: Int32 = 4
        var parameterSets: Data?
        if isKeyframe {
            parameterSets = Self.parameterSets(of: format, nalLengthSize: &nalLengthSize)
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
            annexB: Self.annexB(fromAVCC: avcc, nalLengthSize: Int(nalLengthSize)),
            parameterSets: parameterSets,
            ptsMicros: ptsMicros,
            isKeyframe: isKeyframe
        ))
    }

    private static func parameterSets(of format: CMFormatDescription, nalLengthSize: inout Int32) -> Data? {
        var count = 0
        let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
            parameterSetCountOut: &count, nalUnitHeaderLengthOut: &nalLengthSize
        )
        guard status == noErr else { return nil }

        var data = Data()
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
            ) == noErr, let pointer else { continue }
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
