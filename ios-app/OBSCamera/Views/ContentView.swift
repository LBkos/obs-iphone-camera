import SwiftUI

/// One screen, laid out like the iPhone Camera app: a top bar, the preview,
/// a row with the computers (or the camera controls), and the live button.
/// The interface turns with the stream orientation (see `InterfaceOrientation`),
/// so landscape puts the bars on the sides.
struct ContentView: View {
    @ObservedObject var viewModel: CameraViewModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var showsSettings = false
    @State private var controlsOpen = false
    @State private var activeControl: CameraControlKind?
    @FocusState private var addressFocused: Bool
    @AppStorage(DisplayOptions.showGridKey) private var showGrid = false
    @AppStorage(DisplayOptions.showLevelKey) private var showLevel = false

    private var isLandscape: Bool { verticalSizeClass == .compact }

    private var isCameraPreview: Bool {
        viewModel.effectiveSource != .testPattern && !viewModel.cameraAccessDenied
    }

    /// Bars run along the long edge in portrait, along the short edges in landscape.
    private var barLayout: AnyLayout {
        isLandscape ? AnyLayout(VStackLayout(spacing: 14)) : AnyLayout(HStackLayout(spacing: 14))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if isLandscape {
                HStack(spacing: 12) {
                    topBar
                        .padding(.vertical, 8)
                    previewArea
                    targetRow
                        .frame(width: 112)
                    bottomBar
                        .padding(.vertical, 8)
                }
                .padding(.horizontal, 8)
            } else {
                VStack(spacing: 0) {
                    topBar
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                    previewArea
                    targetRow
                        .frame(height: 56)
                    bottomBar
                        .padding(.horizontal, 32)
                    caption
                        .padding(.top, 6)
                        .padding(.bottom, 4)
                }
            }

            if viewModel.isScreenBlack {
                BlackScreenView(onExit: viewModel.exitBlackScreen)
            }
        }
        .task { await viewModel.onAppear() }
        .onChange(of: scenePhase) { _, phase in viewModel.scenePhaseChanged(phase) }
        .sheet(isPresented: $showsSettings) {
            SettingsView(viewModel: viewModel)
                .presentationDetents([.medium, .large])
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        barLayout {
            if isCameraPreview && viewModel.capabilities.hasTorch {
                circleButton(viewModel.controls.torch ? "flashlight.on.fill" : "flashlight.off.fill",
                             label: viewModel.controls.torch ? "Выключить фонарик" : "Включить фонарик",
                             isOn: viewModel.controls.torch, action: viewModel.toggleTorch)
                    .disabled(viewModel.isRemoteControlled)
            }
            circleButton("moon.fill", label: "Выключить экран", action: viewModel.enterBlackScreen)
            Spacer(minLength: 0)
            if isCameraPreview {
                circleButton(controlsOpen ? "chevron.down" : "chevron.up",
                             label: "Фокус, экспозиция, баланс белого", isOn: controlsOpen) {
                    controlsOpen.toggle()
                    activeControl = nil
                }
            }
            Spacer(minLength: 0)
            formatPill
        }
    }

    /// "1080p · 30": each part changes on tap, like "HD · 30" in the Camera app.
    private var formatPill: some View {
        let layout = isLandscape ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
        return layout {
            Button(viewModel.settings.resolution.rawValue, action: viewModel.cycleResolution)
                .frame(minWidth: 36, minHeight: 36)
                .accessibilityLabel("Разрешение \(viewModel.settings.resolution.rawValue)")
            if !isLandscape {
                Text("·")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            Button("\(viewModel.settings.frameRate)", action: viewModel.cycleFrameRate)
                .frame(minWidth: 36, minHeight: 36)
                .accessibilityLabel("\(viewModel.settings.frameRate) кадров в секунду")
        }
        .buttonStyle(.plain)
        .font(.footnote.weight(.bold).monospacedDigit())
        // Orange: this camera can't do it, a standard mode is used instead.
        .foregroundStyle(viewModel.isFormatSupported ? Color.white : Color.orange)
        .padding(.horizontal, 6)
        .padding(.vertical, isLandscape ? 4 : 0)
        .overlay(Capsule().stroke(Color.white.opacity(0.7), lineWidth: 1.5))
    }

    private func circleButton(_ systemImage: String, label: String, isOn: Bool = false,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 40, height: 40)
                .foregroundStyle(isOn ? Color.black : Color.white)
                .background(isOn ? Color.brand : Color.white.opacity(0.14), in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: - Preview

    private var previewArea: some View {
        ZStack {
            preview

            if isCameraPreview && !viewModel.isScreenBlack {
                if showGrid {
                    GridOverlay(aspectRatio: displayAspectRatio)
                }
                if showLevel {
                    LevelOverlay(orientation: viewModel.settings.orientation)
                }
            }

            VStack(spacing: 8) {
                VStack(spacing: 6) {
                    StatusPill(title: viewModel.statusTitle, isLive: viewModel.livePhase == .live,
                               isWaiting: viewModel.livePhase == .waiting,
                               liveSince: viewModel.liveSince, detail: viewModel.statsText)
                    if viewModel.isRemoteControlled {
                        OBSControlBadge()
                    }
                }
                Spacer(minLength: 0)
                previewBottom
            }
            .padding(12)
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

    /// Width / height of the video as shown on screen (the interface turns with it).
    private var displayAspectRatio: CGFloat {
        let size = viewModel.settings.resolution.landscapeSize
        let landscape = CGFloat(size.width) / CGFloat(size.height)
        return viewModel.settings.orientation == .landscape ? landscape : 1 / landscape
    }

    @ViewBuilder
    private var previewBottom: some View {
        if controlsOpen, isCameraPreview, let activeControl {
            CameraControlPanel(viewModel: viewModel, kind: activeControl)
                .frame(maxWidth: 420)
        } else {
            VStack(spacing: 10) {
                if viewModel.isManualTarget && viewModel.isIdle && !controlsOpen {
                    addressField
                }
                if isLandscape && viewModel.isIdle {
                    caption
                }
                if !viewModel.lensOptions.isEmpty {
                    zoomBubbles
                }
            }
        }
    }

    private var addressField: some View {
        TextField("IP, например 192.168.1.10", text: $viewModel.manualAddress)
            .keyboardType(.numbersAndPunctuation)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focused($addressFocused)
            .submitLabel(.go)
            .onSubmit(viewModel.goLive)
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(Color.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(0.3)))
            .frame(maxWidth: 360)
    }

    private var zoomBubbles: some View {
        HStack(spacing: 6) {
            ForEach(viewModel.lensOptions) { option in
                Button {
                    viewModel.selectLens(option)
                } label: {
                    Text(option.label)
                        .font(.system(size: option.isSelected ? 13 : 11, weight: .bold))
                        .foregroundStyle(option.isSelected ? Color.brand : Color.white)
                        .frame(width: option.isSelected ? 44 : 36, height: option.isSelected ? 44 : 36)
                        .background(Color.black.opacity(0.6), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Зум \(option.label)")
                .accessibilityAddTraits(option.isSelected ? .isSelected : [])
            }
        }
        .padding(4)
        .background(Color.black.opacity(0.35), in: Capsule())
        .disabled(viewModel.isRemoteControlled)
    }

    // MARK: - Computers / camera controls

    @ViewBuilder
    private var targetRow: some View {
        if controlsOpen && isCameraPreview {
            scrollRow(spacing: 8) {
                ForEach(CameraControlKind.allCases) { kind in
                    ControlChip(kind: kind, value: kind.value(of: viewModel.controls),
                                isSelected: activeControl == kind) {
                        activeControl = activeControl == kind ? nil : kind
                    }
                }
            }
        } else if viewModel.isIdle {
            scrollRow(spacing: isLandscape ? 6 : 22) {
                if viewModel.hosts.isEmpty {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("ПОИСК OBS")
                    }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                }
                ForEach(viewModel.hosts) { host in
                    targetButton(host.name.uppercased(), isSelected: viewModel.selectedTargetID == host.id) {
                        viewModel.selectedTargetID = host.id
                    }
                }
                targetButton("IP-АДРЕС", isSelected: viewModel.isManualTarget) {
                    viewModel.selectedTargetID = CameraViewModel.manualTargetID
                    addressFocused = true
                }
            }
        } else {
            Text(viewModel.activeTargetLabel)
                .font(.subheadline.weight(.semibold))
                .tracking(0.8)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .foregroundStyle(Color.brand)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Scrolls when the items don't fit, centered when they do.
    private func scrollRow<Content: View>(spacing: CGFloat, @ViewBuilder content: () -> Content) -> some View {
        let layout = isLandscape ? AnyLayout(VStackLayout(spacing: spacing)) : AnyLayout(HStackLayout(spacing: spacing))
        let items = layout { content() }
        return GeometryReader { proxy in
            ScrollView(isLandscape ? .vertical : .horizontal, showsIndicators: false) {
                items
                    .padding(isLandscape ? .vertical : .horizontal, 16)
                    .frame(minWidth: isLandscape ? nil : proxy.size.width,
                           minHeight: isLandscape ? proxy.size.height : nil)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private func targetButton(_ title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .tracking(0.8)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .foregroundStyle(isSelected ? Color.brand : Color.white)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        barLayout {
            Button {
                showsSettings = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.title3)
                    .foregroundStyle(Color.white)
                    .frame(width: 52, height: 52)
                    .background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Дополнительные настройки")

            Spacer(minLength: 0)

            LiveButton(phase: viewModel.livePhase, action: viewModel.liveButtonTapped)
                .disabled(!viewModel.canPressLiveButton)

            Spacer(minLength: 0)

            Button(action: viewModel.flipCamera) {
                Image(systemName: "arrow.triangle.2.circlepath.camera")
                    .font(.title3)
                    .foregroundStyle(Color.white)
                    .frame(width: 52, height: 52)
                    .background(Color.white.opacity(0.14), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!isCameraPreview)
            .opacity(isCameraPreview ? 1 : 0.4)
            .accessibilityLabel("Сменить камеру")
        }
        .frame(minWidth: isLandscape ? 96 : nil, minHeight: isLandscape ? nil : 100)
    }

    private var caption: some View {
        Text(viewModel.captionText)
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .padding(.horizontal, 16)
            .padding(.vertical, isLandscape ? 6 : 0)
            .background(isLandscape ? Color.black.opacity(0.55) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - Subviews

/// "Не в эфире" / "Подключение…" / red timer while live, plus a details line.
private struct StatusPill: View {
    let title: String
    let isLive: Bool
    let isWaiting: Bool
    let liveSince: Date?
    let detail: String?

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 7) {
                Circle()
                    .fill(isLive ? Color.white : (isWaiting ? Color.orange : Color.gray))
                    .frame(width: 8, height: 8)
                titleText
            }
            .font(.subheadline.weight(.semibold).monospacedDigit())
            .foregroundStyle(Color.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(isLive ? Color.red : Color.black.opacity(0.55),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            if let detail {
                Text(detail)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color.white.opacity(0.85))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }

    @ViewBuilder
    private var titleText: some View {
        if isLive, let liveSince {
            TimelineView(.periodic(from: liveSince, by: 1)) { context in
                Text(Self.elapsed(from: liveSince, to: context.date))
            }
            .accessibilityLabel(title)
        } else {
            Text(title)
        }
    }

    private static func elapsed(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        let (h, m, s) = (seconds / 3600, seconds / 60 % 60, seconds % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}

private struct OBSControlBadge: View {
    var body: some View {
        Label("Камерой управляет OBS", systemImage: "lock.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.brand)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(Color.black.opacity(0.6), in: Capsule())
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
