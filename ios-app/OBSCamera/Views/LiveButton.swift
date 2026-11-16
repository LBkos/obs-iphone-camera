import SwiftUI

extension Color {
    /// Accent: the lens ring color of the app icon's dark variant.
    static let brand = Color(red: 0x8E / 255, green: 0x90 / 255, blue: 0xFF / 255)

    fileprivate init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

/// The big button: the lens from the app icon. Waiting and live show the
/// icon's dot and broadcast waves (fast blinking while connecting, slow pulse live).
/// Sizes are the icon's (tools/make-icon.swift) scaled from 428 to 84 pt.
struct LiveButton: View {
    let phase: CameraViewModel.LivePhase
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            ZStack {
                if phase != .idle {
                    BroadcastWaves()
                        .phaseAnimator([1.0, 0.35]) { content, opacity in
                            content.opacity(opacity)
                        } animation: { _ in
                            .easeInOut(duration: phase == .live ? 0.9 : 0.35)
                        }
                }
                lens
            }
            .frame(width: 84, height: 84)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.5)
        .accessibilityLabel(accessibilityTitle)
    }

    private var lens: some View {
        ZStack {
            Circle().fill(Color.white)
            Circle().fill(Color(hex: 0x1A1C3A)).frame(width: 69, height: 69)
            Circle()
                .fill(LinearGradient(colors: [Color(hex: 0x4A4FA8), Color(hex: 0x0D0E22)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 61, height: 61)
            Circle().fill(Color(hex: 0x23266A)).frame(width: 27, height: 27)
            Circle().fill(Color.white.opacity(0.35)).frame(width: 14, height: 14).offset(x: -11.4, y: -11.4)
            Circle().fill(Color.white.opacity(0.18)).frame(width: 6, height: 6).offset(x: 9.8, y: 11.8)
            if phase != .idle {
                ZStack {
                    Circle().fill(Color.white)
                    Circle().fill(phase == .live ? Color(hex: 0xFF3B30) : Color(hex: 0xFF9F0A)).padding(2.5)
                }
                .frame(width: 20, height: 20)
                .offset(x: 27.5, y: -27.5)
            }
        }
        .frame(width: 84, height: 84)
    }

    private var accessibilityTitle: String {
        switch phase {
        case .idle: "Выйти в эфир"
        case .waiting: "Отменить подключение"
        case .live: "Остановить эфир"
        }
    }
}

/// Two arcs on each side of the lens, like the app icon.
private struct BroadcastWaves: View {
    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            for (radius, alpha) in [(57.0, 1.0), (72.5, 0.55)] {
                for side in [0.0, Double.pi] {
                    // A polyline avoids any doubt about arc direction in flipped coordinates.
                    var path = Path()
                    for step in 0...24 {
                        let angle = side + (Double(step) / 24 - 0.5) * 0.4 * Double.pi
                        let point = CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
                        if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
                    }
                    context.stroke(path, with: .color(.white.opacity(alpha)),
                                   style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))
                }
            }
        }
        .frame(width: 170, height: 170)
        .allowsHitTesting(false)
    }
}
