import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel: CameraViewModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var activeSheet: Sheet?
    @FocusState private var addressFocused: Bool
    @AppStorage(DisplayOptions.showGridKey) private var showGrid = false
    @AppStorage(DisplayOptions.showLevelKey) private var showLevel = false

    private enum Sheet: String, Identifiable {
        case settings
        case cameraControls
        var id: String { rawValue }
    }

    private var isCameraPreview: Bool {
        viewModel.effectiveSource != .testPattern && !viewModel.cameraAccessDenied
    }

    var body: some View {
        ZStack {
            preview
                .ignoresSafeArea()

            if isCameraPreview && !viewModel.isScreenBlack {
                if showGrid {
                    GridOverlay(aspectRatio: displayAspectRatio)
                        .ignoresSafeArea()
                }
                if showLevel {
                    LevelOverlay(orientation: viewModel.settings.orientation)
                }
            }

            VStack(spacing: 12) {
                StatusBadge(text: viewModel.statusText, detail: viewModel.statsText, status: viewModel.status)
                Spacer()
                controlPanel
            }
            .padding()

            if viewModel.isScreenBlack {
                BlackScreenView(onExit: viewModel.exitBlackScreen)
            }
        }
        .task { await viewModel.onAppear() }
        .onChange(of: scenePhase) { _, phase in viewModel.scenePhaseChanged(phase) }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .settings:
                SettingsView(viewModel: viewModel)
                    .presentationDetents([.medium, .large])
            case .cameraControls:
                CameraControlsView(viewModel: viewModel)
                    // Medium keeps the preview visible while adjusting.
                    .presentationDetents([.medium, .large])
                    .presentationBackgroundInteraction(.enabled(upThrough: .medium))
            }
        }
    }

    /// "Main camera · 1080p · 30 fps · 2.0×"
    private var summaryText: String {
        let settings = viewModel.settings
        var parts = [settings.source.title, settings.resolution.rawValue, "\(settings.frameRate) fps"]
        if viewModel.controls.zoom > 1.01 {
            parts.append(String(format: "%.1f×", viewModel.controls.zoom))
        }
        return parts.joined(separator: " · ")
    }

    /// Width / height of the video as shown on the portrait screen.
    private var displayAspectRatio: CGFloat {
        let size = viewModel.settings.resolution.landscapeSize
        let landscape = CGFloat(size.width) / CGFloat(size.height)
        // Landscape video is shown sideways (rotation 0), so it is wide on screen.
        return viewModel.settings.orientation == .landscape ? landscape : 1 / landscape
    }

    // MARK: - Preview

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

    // MARK: - Controls

    private var controlPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Подключение", selection: $viewModel.connectionMode) {
                ForEach(ConnectionMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            if viewModel.connectionMode == .usb {
                usbInstructions
            } else if viewModel.isConnectedOrConnecting {
                Button(role: .destructive, action: viewModel.disconnect) {
                    Label("Отключиться", systemImage: "stop.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
            } else {
                hostList
                manualEntry
                if case .failed = viewModel.status {
                    Button("Повторить", action: viewModel.retry)
                        .buttonStyle(.bordered)
                }
            }

            HStack(spacing: 18) {
                Text(summaryText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                if isCameraPreview {
                    if viewModel.capabilities.hasTorch {
                        Button {
                            viewModel.controls.torch.toggle()
                        } label: {
                            Image(systemName: viewModel.controls.torch ? "flashlight.on.fill" : "flashlight.off.fill")
                                .font(.title3)
                        }
                        .accessibilityLabel(viewModel.controls.torch ? "Выключить фонарик" : "Включить фонарик")
                    }
                    Button {
                        activeSheet = .cameraControls
                    } label: {
                        Image(systemName: "camera.aperture")
                            .font(.title3)
                    }
                    .accessibilityLabel("Камера: фокус, экспозиция, баланс белого")
                }
                Button(action: viewModel.enterBlackScreen) {
                    Image(systemName: "moon.fill")
                        .font(.title3)
                }
                .accessibilityLabel("Выключить экран")
                Button {
                    activeSheet = .settings
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.title3)
                }
                .accessibilityLabel("Настройки")
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    @ViewBuilder
    private var usbInstructions: some View {
        if case .streaming = viewModel.status {
            Label("Видео идёт по кабелю. Чтобы остановить, переключитесь на Wi‑Fi.", systemImage: "cable.connector")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "cable.connector")
                    .font(.title2)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Подключите iPhone кабелем к компьютеру")
                        .font(.headline)
                    Text("В OBS откройте свойства источника «iPhone Camera» и выберите подключение «USB-кабель». Если iPhone спросит, нажмите «Доверять».")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var hostList: some View {
        Text("Компьютеры с OBS")
            .font(.headline)
        if viewModel.hosts.isEmpty {
            HStack(spacing: 8) {
                ProgressView()
                Text(viewModel.discoveryError ?? "Поиск в сети… Добавьте в OBS источник «iPhone Camera».")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } else {
            ForEach(viewModel.hosts) { host in
                Button {
                    viewModel.connect(to: host)
                } label: {
                    HStack {
                        Image(systemName: "desktopcomputer")
                        Text(host.name)
                            .lineLimit(1)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var manualEntry: some View {
        HStack {
            TextField("IP-адрес, например 192.168.1.10", text: $viewModel.manualAddress)
                .keyboardType(.numbersAndPunctuation)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($addressFocused)
                .submitLabel(.go)
                .onSubmit(viewModel.connectManually)
                .textFieldStyle(.roundedBorder)
            Button("Подключить") {
                addressFocused = false
                viewModel.connectManually()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!viewModel.canConnectManually)
        }
    }
}

// MARK: - Subviews

private struct StatusBadge: View {
    let text: String
    let detail: String?
    let status: StreamingEngine.Status

    private var color: Color {
        switch status {
        case .idle: .gray
        case .waitingForUSB, .connecting: .orange
        case .streaming: .red
        case .failed: .yellow
        }
    }

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 10, height: 10)
                Text(text).font(.subheadline.weight(.semibold)).lineLimit(2)
            }
            if let detail {
                Text(detail).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
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
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
    }
}

#Preview {
    ContentView(viewModel: CameraViewModel())
}
