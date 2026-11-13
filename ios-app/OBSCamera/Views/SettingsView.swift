import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: CameraViewModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage(DisplayOptions.showGridKey) private var showGrid = false
    @AppStorage(DisplayOptions.showLevelKey) private var showLevel = false

    private var settings: StreamSettings { viewModel.settings }

    /// Cameras this iPhone has, plus the test pattern.
    private var sources: [VideoSourceKind] {
        VideoSourceKind.allCases.filter { $0 == .testPattern || CameraCaptureService.isAvailable(for: $0) }
    }

    private var isCamera: Bool { settings.source != .testPattern }

    var body: some View {
        NavigationStack {
            Form {
                Section("Источник") {
                    Picker("Камера", selection: $viewModel.settings.source) {
                        ForEach(sources) { Text($0.title).tag($0) }
                    }
                    Picker("Ориентация", selection: $viewModel.settings.orientation) {
                        ForEach(VideoOrientation.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if isCamera {
                        Toggle("Отразить изображение", isOn: $viewModel.settings.mirror)
                    }
                }

                Section {
                    Picker("Разрешение", selection: $viewModel.settings.resolution) {
                        ForEach(VideoResolution.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Частота кадров", selection: $viewModel.settings.frameRate) {
                        ForEach(StreamSettings.supportedFrameRates, id: \.self) { Text("\($0) fps").tag($0) }
                    }
                    VStack(alignment: .leading) {
                        Text("Битрейт: \(settings.bitrateMbps, specifier: "%.0f") Мбит/с")
                        Slider(value: $viewModel.settings.bitrateMbps, in: StreamSettings.bitrateRange, step: 1)
                    }
                } header: {
                    Text("Видео")
                } footer: {
                    if isCamera && !CameraCaptureService.supportsFormat(for: settings) {
                        Text("Эта камера не снимает \(settings.resolution.rawValue) при \(settings.frameRate) fps. Будет использован ближайший стандартный режим.")
                            .foregroundStyle(.orange)
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

                if isCamera {
                    Section {
                        Picker("Стабилизация", selection: $viewModel.settings.stabilization) {
                            ForEach(StabilizationMode.allCases) { Text($0.title).tag($0) }
                        }
                        if viewModel.capabilities.supportsLowLightBoost {
                            Toggle("Усиление при слабом свете", isOn: $viewModel.settings.lowLightBoost)
                        }
                    } header: {
                        Text("Камера")
                    } footer: {
                        if settings.stabilization != .off {
                            Text("Стабилизация добавляет задержку.")
                        }
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
                             : "Звук появится в микшере OBS у источника «iPhone Camera». Нужен обновлённый плагин.")
                    }
                }

                Section("Превью") {
                    Toggle("Сетка", isOn: $showGrid)
                    Toggle("Уровень горизонта", isOn: $showLevel)
                }

                Section {
                    Text("Горизонтальная ориентация: держите iPhone боком, разъёмом зарядки вправо. Если сеть не справляется, уменьшите битрейт или разрешение. Кнопка с луной выключает экран, видео при этом продолжает идти.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
    }

    private static func keyframeLabel(_ seconds: Double) -> String {
        seconds < 1 ? String(format: "каждые %.1f с", seconds) : "каждые \(Int(seconds)) с"
    }

    @ViewBuilder
    private var encodingFooter: some View {
        if settings.codec == .hevc && settings.hdr && isCamera && !CameraCaptureService.supportsHDR(for: settings) {
            Text("Эта камера не снимает HDR при \(settings.resolution.rawValue) и \(settings.frameRate) fps. Видео будет обычным (SDR).")
                .foregroundStyle(.orange)
        } else if settings.codec == .hevc {
            Text("HEVC даёт лучшее качество при том же битрейте. Нужен обновлённый плагин OBS.")
        }
    }
}

#Preview {
    SettingsView(viewModel: CameraViewModel())
}
