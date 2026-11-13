import CoreMedia
import CoreVideo

/// Anything that produces raw video frames for the encoder.
protocol VideoFrameSource: AnyObject {
    /// Called on the source's own background queue.
    var frameHandler: ((CVPixelBuffer, CMTime) -> Void)? { get set }
    func start(with settings: StreamSettings)
    func stop()
}
