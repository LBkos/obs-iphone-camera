import CoreGraphics
import CoreMedia
import CoreText
import CoreVideo
import Foundation
import os

/// Generates animated color bars. Used in the Simulator (no camera) and to
/// check the network/OBS side without pointing a camera at anything.
final class TestPatternSource: VideoFrameSource, @unchecked Sendable {
    var frameHandler: ((CVPixelBuffer, CMTime) -> Void)?

    private let queue = DispatchQueue(label: "com.obscamera.testpattern", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var pool: CVPixelBufferPool?
    private var size: (width: Int32, height: Int32) = (0, 0)
    private var frameIndex: Int64 = 0
    private let logger = Logger(subsystem: "com.obscamera.app", category: "TestPattern")
    private let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    func start(with settings: StreamSettings) {
        queue.async { [self] in
            timer?.cancel()
            size = settings.outputSize
            pool = makePool(width: size.width, height: size.height)

            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: 1.0 / Double(settings.frameRate), leeway: .milliseconds(1))
            timer.setEventHandler { [weak self] in self?.renderFrame() }
            timer.resume()
            self.timer = timer
        }
    }

    func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
        }
    }

    private func makePool(width: Int32, height: Int32) -> CVPixelBufferPool? {
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ]
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
        if status != kCVReturnSuccess {
            logger.error("CVPixelBufferPoolCreate failed: \(status)")
        }
        return pool
    }

    private func renderFrame() {
        guard let pool else { return }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { return }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return }

        draw(in: context, width: CGFloat(size.width), height: CGFloat(size.height))
        frameIndex += 1

        let pts = CMClockGetTime(CMClockGetHostTimeClock())
        frameHandler?(buffer, pts)
    }

    private func draw(in ctx: CGContext, width: CGFloat, height: CGFloat) {
        // CoreGraphics origin is bottom-left; the top 2/3 are color bars.
        let bars: [(CGFloat, CGFloat, CGFloat)] = [
            (0.75, 0.75, 0.75), (0.75, 0.75, 0), (0, 0.75, 0.75), (0, 0.75, 0),
            (0.75, 0, 0.75), (0.75, 0, 0), (0, 0, 0.75)
        ]
        let barWidth = width / CGFloat(bars.count)
        let barsBottom = height / 3
        for (index, color) in bars.enumerated() {
            ctx.setFillColor(red: color.0, green: color.1, blue: color.2, alpha: 1)
            ctx.fill(CGRect(x: CGFloat(index) * barWidth, y: barsBottom, width: barWidth + 1, height: height - barsBottom))
        }
        ctx.setFillColor(red: 0.08, green: 0.08, blue: 0.1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: barsBottom))

        // Moving square shows motion smoothness and latency.
        let side = barsBottom * 0.5
        let period: Int64 = 120
        let phase = CGFloat(frameIndex % period) / CGFloat(period)
        let x = (width - side) * (phase < 0.5 ? phase * 2 : (1 - phase) * 2)
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: x, y: barsBottom * 0.1, width: side, height: side))

        let text = "OBS Camera • \(Int(width))x\(Int(height)) • #\(frameIndex) • \(timeFormatter.string(from: Date()))"
        let font = CTFontCreateWithName("Menlo-Bold" as CFString, height * 0.04, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 1, green: 0.8, blue: 0.2, alpha: 1)
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        ctx.textPosition = CGPoint(x: width * 0.03, y: barsBottom * 0.75)
        CTLineDraw(line, ctx)
    }
}
