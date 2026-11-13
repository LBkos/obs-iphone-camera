import SwiftUI

struct SettingsView: View {
    @Binding var settings: StreamSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Источник") {
                    Picker("Камера", selection: $settings.source) {
                        ForEach(VideoSourceKind.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Ориентация", selection: $settings.orientation) {
                        ForEach(VideoOrientation.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Видео") {
                    Picker("Разрешение", selection: $settings.resolution) {
                        ForEach(VideoResolution.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Частота кадров", selection: $settings.frameRate) {
                        ForEach(StreamSettings.supportedFrameRates, id: \.self) { Text("\($0) fps").tag($0) }
                    }
                    VStack(alignment: .leading) {
                        Text("Битрейт: \(settings.bitrateMbps, specifier: "%.0f") Мбит/с")
                        Slider(value: $settings.bitrateMbps, in: 2...30, step: 1)
                    }
                }

                Section {
                    Text("Горизонтальная ориентация: держите iPhone боком, разъёмом зарядки вправо. Если сеть не справляется, уменьшите битрейт или разрешение.")
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
}

#Preview {
    SettingsView(settings: .constant(StreamSettings()))
}
