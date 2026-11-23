import SwiftUI

/// Settings in three tabs: the camera, what goes to OBS, and help.
struct SettingsView: View {
    @ObservedObject var viewModel: CameraViewModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage(DisplayOptions.showGridKey) private var showGrid = false
    @AppStorage(DisplayOptions.showLevelKey) private var showLevel = false
    @AppStorage(DisplayOptions.autoBlackScreenKey) private var autoBlackScreen = true
    @State private var tab = Tab.camera

    private enum Tab: String, CaseIterable, Identifiable {
        case camera = "Камера"
        case output = "Вывод"
        case help = "Помощь"
        var id: String { rawValue }
    }

    private var settings: StreamSettings { viewModel.settings }
    private var isCamera: Bool { settings.source != .testPattern }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Раздел", selection: $tab) {
                        ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())

                switch tab {
                case .camera: cameraTab
                case .output: outputTab
                case .help: helpTab
                }
            }
            .tint(Color.brand)
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
    }

    // MARK: - Camera

    @ViewBuilder
    private var cameraTab: some View {
        Section {
            Picker("Ориентация", selection: $viewModel.settings.orientation) {
                ForEach(VideoOrientation.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Ориентация видео")
        } footer: {
            Text("Приложение всегда вертикальное, это меняет только видео в OBS. Горизонтально: держите iPhone разъёмом зарядки вправо.")
        }

        Section("Камера") {
            Picker("Камера", selection: $viewModel.settings.source) {
                ForEach(viewModel.availableSources) { Text($0.title).tag($0) }
            }
            if isCamera {
                Toggle("Отразить изображение", isOn: $viewModel.settings.mirror)
                if viewModel.capabilities.supportsLowLightBoost {
                    Toggle("Усиление при слабом свете", isOn: $viewModel.settings.lowLightBoost)
                }
                Button("Сбросить фокус, экспозицию и баланс на авто", action: viewModel.resetControls)
                    .disabled(viewModel.isRemoteControlled)
            }
        }

        if isCamera {
            Section {
                Picker("Стабилизация", selection: $viewModel.settings.stabilization) {
                    ForEach(StabilizationMode.allCases) { Text($0.title).tag($0) }
                }
            } footer: {
                Text("Стабилизация добавляет задержку, на штативе лучше выключить.")
            }

            Section {
                Toggle("Звук с микрофона iPhone", isOn: $viewModel.settings.audioEnabled)
                if settings.audioEnabled && viewModel.microphoneAccessDenied {
                    Button("Разрешить доступ к микрофону", action: viewModel.openSystemSettings)
                }
            } header: {
                Text("Звук")
            } footer: {
                Text(settings.audioEnabled && viewModel.microphoneAccessDenied
                     ? "Нет доступа к микрофону. Разрешите его в Настройках iOS."
                     : "Звук появится в микшере OBS у источника «iPhone Camera».")
            }
        }

        Section {
            Toggle("Сетка", isOn: $showGrid)
            Toggle("Уровень горизонта", isOn: $showLevel)
            Toggle("Гасить экран через \(CameraViewModel.autoBlackSeconds) с в эфире", isOn: $autoBlackScreen)
        } header: {
            Text("Экран")
        } footer: {
            Text("Для штатива: видео продолжает идти, а экран не греется и не тратит батарею. Вернуть экран: двойное касание.")
        }
    }

    // MARK: - Output

    @ViewBuilder
    private var outputTab: some View {
        Section {
            Picker("Разрешение", selection: $viewModel.settings.resolution) {
                ForEach(VideoResolution.allCases) { Text($0.rawValue).tag($0) }
            }
            Picker("Кадров в секунду", selection: $viewModel.settings.frameRate) {
                ForEach(StreamSettings.supportedFrameRates, id: \.self) { Text("\($0)").tag($0) }
            }
            VStack(alignment: .leading) {
                Text("Битрейт: \(settings.bitrateMbps, specifier: "%.0f") Мбит/с")
                Slider(value: $viewModel.settings.bitrateMbps, in: StreamSettings.bitrateRange, step: 1)
            }
        } header: {
            Text("Качество")
        } footer: {
            if !viewModel.isFormatSupported {
                Text("Эта камера не снимает \(settings.resolution.rawValue) при \(settings.frameRate) к/с. Будет использован ближайший стандартный режим.")
                    .foregroundStyle(.orange)
            } else {
                Text("Если сеть не справляется (оранжевая или красная точка внизу), уменьшите битрейт или разрешение.")
            }
        }

        Section {
            Picker("Кодек", selection: $viewModel.settings.codec) {
                ForEach(VideoCodec.allCases) { Text($0.title).tag($0) }
            }
            if settings.codec == .h264 {
                Picker("Профиль H.264", selection: $viewModel.settings.h264Profile) {
                    ForEach(H264Profile.allCases) { Text($0.title).tag($0) }
                }
            }
            Picker("Ключевой кадр", selection: $viewModel.settings.keyframeInterval) {
                ForEach(StreamSettings.keyframeIntervals, id: \.self) { seconds in
                    Text(Self.keyframeLabel(seconds)).tag(seconds)
                }
            }
            if settings.codec == .hevc && isCamera {
                Toggle("HDR (HLG, 10 бит)", isOn: $viewModel.settings.hdr)
            }
        } header: {
            Text("Кодирование")
        } footer: {
            encodingFooter
        }
    }

    private static func keyframeLabel(_ seconds: Double) -> String {
        seconds < 1 ? String(format: "каждые %.1f с", seconds) : "каждые \(Int(seconds)) с"
    }

    @ViewBuilder
    private var encodingFooter: some View {
        if settings.codec == .hevc && settings.hdr && isCamera && !CameraCaptureService.supportsHDR(for: settings) {
            Text("Эта камера не снимает HDR при \(settings.resolution.rawValue) и \(settings.frameRate) к/с. Видео будет обычным (SDR).")
                .foregroundStyle(.orange)
        } else if settings.codec == .hevc {
            Text("HEVC даёт лучшее качество при том же битрейте. HDR работает только с HEVC.")
        } else {
            Text("HDR работает только с HEVC.")
        }
    }

    // MARK: - Help

    @ViewBuilder
    private var helpTab: some View {
        Section("Wi‑Fi") {
            Text("Добавьте в OBS источник «iPhone Camera». iPhone найдёт компьютер сам: выберите его внизу экрана и нажмите «Старт». iPhone и компьютер должны быть в одной сети.")
        }
        Section("USB-кабель") {
            Text("Подключите iPhone кабелем и выберите «USB-кабель» в свойствах источника «iPhone Camera». Видео пойдёт по кабелю само, без «Старт».")
        }
        Section("Значения камеры") {
            Text("Нажмите на значение над нижней панелью, чтобы изменить его. Пустой кружок: авто, заполненный: вручную. Долгое нажатие: сбросить на авто или сохранить профиль.")
        }
        Section("Управление из OBS") {
            Text("В свойствах источника включите «Управлять камерой из OBS»: там же можно выбрать профиль. Пока OBS управляет камерой, её значения в приложении только для просмотра.")
        }
    }
}

#Preview {
    SettingsView(viewModel: CameraViewModel())
}
