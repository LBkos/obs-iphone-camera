import CoreMotion
import SwiftUI

/// Preview-only options (not part of the stream), stored with @AppStorage.
enum DisplayOptions {
    static let showGridKey = "showGrid"
    static let showLevelKey = "showLevel"
}

/// Rule-of-thirds grid over the video area of the preview.
struct GridOverlay: View {
    /// Width / height of the video as shown on screen.
    let aspectRatio: CGFloat

    var body: some View {
        Canvas { context, size in
            var path = Path()
            for i in 1...2 {
                let x = size.width * CGFloat(i) / 3
                let y = size.height * CGFloat(i) / 3
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(path, with: .color(.white.opacity(0.5)), lineWidth: 1)
        }
        .aspectRatio(aspectRatio, contentMode: .fit)
        .allowsHitTesting(false)
    }
}

/// Horizon line that turns green when the phone is level for the chosen orientation.
struct LevelOverlay: View {
    let orientation: VideoOrientation
    @StateObject private var monitor = LevelMonitor()

    var body: some View {
        Group {
            if let roll = monitor.roll {
                // Level when the screen's "down" points straight down: 0° in portrait,
                // -90° held sideways (charging port to the right).
                let target = orientation == .portrait ? 0 : -Double.pi / 2
                let isLevel = abs(roll - target) < 1 * .pi / 180
                Capsule()
                    .fill(isLevel ? Color.green : Color.white.opacity(0.8))
                    .frame(width: 160, height: 3)
                    // The line stays parallel to the real horizon.
                    .rotationEffect(.radians(-roll))
                    .animation(.linear(duration: 0.1), value: roll)
            }
        }
        .allowsHitTesting(false)
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop() }
    }
}

@MainActor
private final class LevelMonitor: ObservableObject {
    /// Phone rotation around the screen axis (0 = upright portrait), nil when lying flat.
    @Published private(set) var roll: Double?
    private let motion = CMMotionManager()

    func start() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 15
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let gravity = data?.gravity else { return }
            // Lying (almost) flat: no meaningful horizon.
            self?.roll = abs(gravity.z) > 0.9 ? nil : atan2(gravity.x, -gravity.y)
        }
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
        roll = nil
    }
}

/// Yellow square where the user tapped to focus.
struct FocusIndicator: View {
    let point: CGPoint

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .stroke(Color.yellow, lineWidth: 1.5)
            .frame(width: 70, height: 70)
            .position(point)
            .allowsHitTesting(false)
    }
}

/// Fully black screen (OLED pixels off) while streaming. Double tap to leave.
struct BlackScreenView: View {
    let onExit: () -> Void
    @State private var showsHint = true

    var body: some View {
        ZStack {
            Color.black
            if showsHint {
                Text("Экран выключен. Видео продолжает идти.\nДважды коснитесь, чтобы вернуться.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.4))
                    .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onExit)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .task {
            try? await Task.sleep(for: .seconds(3))
            withAnimation { showsHint = false }
        }
    }
}
