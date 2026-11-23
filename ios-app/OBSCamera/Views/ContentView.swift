import SwiftUI

/// One portrait screen: the preview fills it, a tool bar on top, the camera
/// values over its bottom, and the connection, profiles, start/stop and settings
/// at the very bottom. The interface never turns; a landscape stream shows as a
/// wide frame (hold the iPhone with the charging port to the right).
struct ContentView: View {
    @ObservedObject var viewModel: CameraViewModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var sheet: Sheet?
    @State private var activeControl: CameraControlKind?
    /// The profiles sheet opens straight into "save current setup".
    @State private var savesProfileOnOpen = false
    @AppStorage(DisplayOptions.showGridKey) private var showGrid = false
    @AppStorage(DisplayOptions.showLevelKey) private var showLevel = false
    @AppStorage(DisplayOptions.autoBlackScreenKey) private var autoBlackScreen = true

    private enum Sheet: String, Identifiable {
        case connection, profiles, settings
        var id: String { rawValue }
    }

    private var isCameraPreview: Bool {
        viewModel.effectiveSource != .testPattern && !viewModel.cameraAccessDenied
    }

    private var visibleControls: [CameraControlKind] {
        CameraControlKind.allCases.filter { $0 != .zoom || viewModel.capabilities.maxZoom > viewModel.capabilities.minZoom }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                previewArea
                bottomBar
            }

            if viewModel.isScreenBlack {
                BlackScreenView(onExit: viewModel.exitBlackScreen)
            }
        }
        .task { await viewModel.onAppear() }
        .onChange(of: scenePhase) { _, phase in viewModel.scenePhaseChanged(phase) }
        .onChange(of: isCameraPreview) { _, isCamera in
            if !isCamera { activeControl = nil }
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .connection:
                ConnectionView(viewModel: viewModel)
                    .presentationDetents([.medium, .large])
            case .profiles:
                ProfilesView(viewModel: viewModel, savesOnAppear: savesProfileOnOpen)
                    .presentationDetents([.medium, .large])
            case .settings:
                SettingsView(viewModel: viewModel)
            }
        }
    }

    // MARK: - Preview

    private var previewArea: some View {
        ZStack {
            preview
                .ignoresSafeArea(edges: .top)

            if isCameraPreview && !viewModel.isScreenBlack {
                if showGrid {
                    GridOverlay(aspectRatio: displayAspectRatio)
                }
                if showLevel {
                    LevelOverlay(orientation: viewModel.settings.orientation)
                }
            }

            VStack(spacing: 10) {
                toolBar
                badges
                Spacer(minLength: 0)
                if viewModel.settings.orientation == .landscape && viewModel.isIdle {
                    landscapeHint
                }
                HStack {
                    Spacer()
                    lensMenu
                }
                .padding(.horizontal, 14)
                if isCameraPreview {
                    if let activeControl {
                        CameraControlPanel(viewModel: viewModel, kind: activeControl)
                            .frame(maxWidth: 420)
                            .padding(.horizontal, 12)
                    }
                    controlRow
                }
            }
            .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    @ViewBuilder
    private var preview: some View {
        if viewModel.effectiveSource == .testPattern {
            TestPatternPlaceholder(isSimulatorFallback: viewModel.settings.source != .testPattern)
        } else if viewModel.cameraAccessDenied {
            CameraDeniedView(openSettings: viewModel.openSystemSettings)
        } else {
            CameraPreviewView(session: viewModel.captureSession,
                              rotationAngle: viewModel.settings.orientation.rotationAngle,
                              isMirrored: viewModel.settings.mirror,
                              isEnabled: !viewModel.isScreenBlack,
                              onTap: { devicePoint, viewPoint in
                                  activeControl = nil
                                  viewModel.tapToFocus(devicePoint: devicePoint, previewPoint: viewPoint)
                              },
                              onPinch: { scale in viewModel.pinchZoom(scale: scale) })
                .overlay {
                    if let point = viewModel.focusIndicator {
                        FocusIndicator(point: point)
                    }
                }
        }
    }

    /// Width / height of the video on the (always portrait) screen.
    private var displayAspectRatio: CGFloat {
        let size = viewModel.settings.resolution.landscapeSize
        let landscape = CGFloat(size.width) / CGFloat(size.height)
        return viewModel.settings.orientation == .landscape ? landscape : 1 / landscape
    }

    // MARK: - Top

    private var toolBar: some View {
        HStack(spacing: 0) {
            toolButton("grid", label: showGrid ? "Скрыть сетку" : "Показать сетку", isOn: showGrid) {
                showGrid.toggle()
            }
            toolButton("arrow.triangle.2.circlepath.camera", label: "Сменить камеру",
                       action: viewModel.flipCamera)
                .disabled(!isCameraPreview)
            toolButton(viewModel.settings.audioEnabled ? "mic.fill" : "mic.slash",
                       label: viewModel.settings.audioEnabled ? "Выключить звук" : "Включить звук",
                       isOn: viewModel.settings.audioEnabled, action: viewModel.toggleMicrophone)
            toolButton(viewModel.controls.torch ? "flashlight.on.fill" : "flashlight.off.fill",
                       label: viewModel.controls.torch ? "Выключить фонарик" : "Включить фонарик",
                       isOn: viewModel.controls.torch, action: viewModel.toggleTorch)
                .disabled(!isCameraPreview || !viewModel.capabilities.hasTorch || viewModel.isRemoteControlled)
            toolButton("moon.fill", label: "Выключить экран", action: viewModel.enterBlackScreen)
        }
        .frame(height: 52)
        .background(Color.black.opacity(0.55).ignoresSafeArea(edges: .top))
    }

    private func toolButton(_ systemImage: String, label: String, isOn: Bool = false,
                            action: @escaping () -> Void) -> some View {
        ToolButton(systemImage: systemImage, isOn: isOn, action: action)
            .accessibilityLabel(label)
    }

    /// Format menu when idle; live timer (and the OBS lock) while streaming.
    @ViewBuilder
    private var badges: some View {
        VStack(spacing: 6) {
            if viewModel.isLive, let liveSince = viewModel.liveSince {
                LiveTimer(since: liveSince,
                          blackScreenIn: autoBlackScreen ? CameraViewModel.autoBlackSeconds : nil)
            } else {
                formatMenu
            }
            if viewModel.isRemoteControlled {
                Label("Камерой управляет OBS", systemImage: "lock.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.brand)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.75), in: Capsule())
            }
        }
    }

    private var formatMenu: some View {
        Menu {
            Picker("Разрешение", selection: $viewModel.settings.resolution) {
                ForEach(VideoResolution.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.inline)
            Picker("Кадров в секунду", selection: $viewModel.settings.frameRate) {
                ForEach(StreamSettings.supportedFrameRates, id: \.self) { Text("\($0) к/с").tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            Text("\(viewModel.settings.resolution.rawValue) · \(viewModel.settings.frameRate)")
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(Color.black)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                // Orange: this camera can't do it, a standard mode is used instead.
                .background(viewModel.isFormatSupported ? Color.brand : Color.orange,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .frame(minHeight: 44)
        }
        .accessibilityLabel("Формат: \(viewModel.settings.resolution.rawValue), \(viewModel.settings.frameRate) кадров в секунду")
    }

    private var landscapeHint: some View {
        Label("Держите iPhone горизонтально, разъёмом зарядки вправо", systemImage: "iphone.landscape")
            .font(.caption)
            .foregroundStyle(Color.white.opacity(0.85))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: - Camera values

    private var lensMenu: some View {
        Menu {
            Picker("Камера", selection: Binding(get: { viewModel.settings.source },
                                                set: { viewModel.selectSource($0) })) {
                ForEach(viewModel.availableSources) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            Label(viewModel.settings.source.shortTitle, systemImage: "camera")
                .font(.body.weight(.medium))
                .foregroundStyle(Color.white)
                .padding(.horizontal, 16)
                .frame(height: 44)
                .background(Color.black.opacity(0.7), in: Capsule())
        }
        .accessibilityLabel("Камера: \(viewModel.settings.source.title)")
    }

    private var controlRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(visibleControls) { kind in
                    ControlChip(label: kind.chipLabel(of: viewModel.controls),
                                isAdjusted: kind.isAdjusted(in: viewModel.controls),
                                isSelected: activeControl == kind) {
                        activeControl = activeControl == kind ? nil : kind
                    }
                    .accessibilityLabel("\(kind.title): \(kind.value(of: viewModel.controls))")
                    .contextMenu { resetMenu(for: kind) }
                }
            }
            .padding(.horizontal, 12)
        }
        .opacity(viewModel.isRemoteControlled ? 0.5 : 1)
    }

    @ViewBuilder
    private func resetMenu(for kind: CameraControlKind) -> some View {
        Button {
            viewModel.resetControls()
        } label: {
            Label("Сбросить всё на авто", systemImage: "arrow.counterclockwise")
        }
        .disabled(viewModel.isRemoteControlled)
        Button("Сбросить: \(kind.title.lowercased())") {
            viewModel.resetControl(kind)
        }
        .disabled(viewModel.isRemoteControlled || !kind.isAdjusted(in: viewModel.controls))
        Button {
            savesProfileOnOpen = true
            sheet = .profiles
        } label: {
            Label("Сохранить как профиль…", systemImage: "bookmark")
        }
    }

    // MARK: - Bottom

    private var bottomBar: some View {
        HStack(spacing: 10) {
            Button {
                sheet = .connection
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: viewModel.isStreamingViaUSB ? "cable.connector" : "wifi")
                        .font(.title3)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(viewModel.connectionTitle)
                            .font(.body.weight(.medium))
                            .lineLimit(1)
                        HStack(spacing: 5) {
                            if let color = qualityColor {
                                Circle().fill(color).frame(width: 7, height: 7)
                            }
                            Text(viewModel.connectionDetail)
                                .lineLimit(1)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Color.white)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Выбрать компьютер")

            Button {
                savesProfileOnOpen = false
                sheet = .profiles
            } label: {
                Image(systemName: viewModel.activeProfileID == nil ? "bookmark" : "bookmark.fill")
                    .font(.title3)
                    .foregroundStyle(Color.white)
                    .frame(width: 40, height: 44)
            }
            .accessibilityLabel("Профили")

            liveButton

            Button {
                sheet = .settings
            } label: {
                Image(systemName: "gearshape")
                    .font(.title3)
                    .foregroundStyle(Color.white)
                    .frame(width: 40, height: 44)
            }
            .accessibilityLabel("Настройки")
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background(Color.black)
    }

    private var qualityColor: Color? {
        switch viewModel.connectionQuality {
        case .none: nil
        case .good: .green
        case .weak: .orange
        case .bad: .red
        }
    }

    private var liveButton: some View {
        let idle = viewModel.isIdle
        return Button(action: viewModel.liveButtonTapped) {
            HStack(spacing: 8) {
                if idle {
                    Circle().frame(width: 10, height: 10)
                } else {
                    RoundedRectangle(cornerRadius: 2).frame(width: 10, height: 10)
                }
                Text(idle ? "Старт" : "Стоп")
            }
            .font(.body.weight(.bold))
            .foregroundStyle(idle ? Color.black : Color.white)
            .padding(.horizontal, 18)
            .frame(height: 44)
            .background(idle ? Color.brand : Color.red, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!viewModel.canPressLiveButton)
        .opacity(viewModel.canPressLiveButton ? 1 : 0.4)
        .accessibilityLabel(idle ? "Начать эфир" : "Остановить эфир")
    }
}

// MARK: - Subviews

/// Icon in the top bar; violet when its option is on, dimmed when unavailable.
private struct ToolButton: View {
    let systemImage: String
    let isOn: Bool
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(isOn ? Color.brand : Color.white)
                .opacity(isEnabled ? 1 : 0.35)
                .frame(maxWidth: .infinity, minHeight: 52)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Red "12:47" while live, plus a countdown to the automatic black screen.
private struct LiveTimer: View {
    let since: Date
    /// Seconds after going live when the screen turns black; nil if that is off.
    let blackScreenIn: Int?

    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            let seconds = max(0, Int(context.date.timeIntervalSince(since)))
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    Circle().fill(Color.white).frame(width: 8, height: 8)
                    Text(Self.elapsed(seconds))
                }
                .font(.system(size: 15, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Color.red, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityLabel("В эфире \(Self.elapsed(seconds))")

                if let blackScreenIn, seconds < blackScreenIn {
                    Text("Экран погаснет через \(blackScreenIn - seconds) с")
                        .font(.caption)
                        .foregroundStyle(Color.white.opacity(0.9))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }
        }
    }

    private static func elapsed(_ seconds: Int) -> String {
        let (h, m, s) = (seconds / 3600, seconds / 60 % 60, seconds % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}

private struct TestPatternPlaceholder: View {
    let isSimulatorFallback: Bool

    var body: some View {
        ZStack {
            LinearGradient(colors: [.purple, .blue, .teal], startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 8) {
                Image(systemName: "testtube.2").font(.system(size: 48))
                Text("Тестовая картинка").font(.title2.bold())
                if isSimulatorFallback {
                    Text("Камера недоступна (симулятор)").font(.footnote)
                }
            }
            .foregroundStyle(.white)
        }
    }
}

private struct CameraDeniedView: View {
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "video.slash.fill").font(.system(size: 44))
            Text("Нет доступа к камере").font(.title3.bold())
            Button("Открыть Настройки", action: openSettings)
                .buttonStyle(.borderedProminent)
                .tint(Color.brand)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
    }
}

#Preview {
    ContentView(viewModel: CameraViewModel())
}
