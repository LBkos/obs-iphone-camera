import SwiftUI

/// Live camera adjustments: zoom, focus, exposure, white balance, torch.
/// Shown at half height so the preview stays visible.
struct CameraControlsView: View {
    @ObservedObject var viewModel: CameraViewModel
    @Environment(\.dismiss) private var dismiss

    private var caps: CameraCapabilities { viewModel.capabilities }

    var body: some View {
        NavigationStack {
            Form {
                if caps.maxZoom > caps.minZoom {
                    Section("Зум") {
                        VStack(alignment: .leading) {
                            Text(String(format: "%.1f×", viewModel.controls.zoom))
                            Slider(value: $viewModel.controls.zoom, in: caps.minZoom...caps.maxZoom)
                        }
                    }
                }

                Section {
                    modePicker("Режим", selection: focusModeBinding,
                               modes: modes(lock: caps.supportsFocusLock, manual: caps.supportsManualFocus))
                    if viewModel.controls.focusMode == .manual {
                        VStack(alignment: .leading) {
                            Text("Дистанция: \(viewModel.controls.lensPosition, specifier: "%.2f")")
                            Slider(value: $viewModel.controls.lensPosition, in: 0...1) {
                                Text("Дистанция")
                            } minimumValueLabel: {
                                Image(systemName: "flower")
                            } maximumValueLabel: {
                                Image(systemName: "mountain.2")
                            }
                        }
                    }
                } header: {
                    Text("Фокус")
                } footer: {
                    if viewModel.controls.focusMode == .auto {
                        Text("Коснитесь превью, чтобы сфокусироваться на точке.")
                    }
                }

                Section("Экспозиция") {
                    modePicker("Режим", selection: exposureModeBinding,
                               modes: modes(lock: caps.supportsExposureLock, manual: caps.supportsManualExposure))
                    switch viewModel.controls.exposureMode {
                    case .auto:
                        if caps.maxExposureBias > caps.minExposureBias {
                            VStack(alignment: .leading) {
                                Text("Коррекция: \(viewModel.controls.exposureBias, specifier: "%+.1f") EV")
                                Slider(value: $viewModel.controls.exposureBias,
                                       in: max(caps.minExposureBias, -3)...min(caps.maxExposureBias, 3), step: 0.1)
                            }
                        }
                    case .locked:
                        EmptyView()
                    case .manual:
                        if caps.maxISO > caps.minISO {
                            VStack(alignment: .leading) {
                                Text("ISO: \(Int(viewModel.controls.iso))")
                                Slider(value: $viewModel.controls.iso, in: caps.minISO...caps.maxISO, step: 1)
                            }
                        }
                        if !caps.shutterDenominators.isEmpty {
                            Picker("Выдержка", selection: $viewModel.controls.shutterDenominator) {
                                ForEach(caps.shutterDenominators, id: \.self) { Text("1/\($0)").tag($0) }
                            }
                        }
                    }
                }

                Section("Баланс белого") {
                    modePicker("Режим", selection: whiteBalanceModeBinding,
                               modes: modes(lock: caps.supportsWhiteBalanceLock, manual: caps.supportsManualWhiteBalance))
                    if viewModel.controls.whiteBalanceMode == .manual {
                        VStack(alignment: .leading) {
                            Text("Температура: \(Int(viewModel.controls.temperature)) K")
                            Slider(value: $viewModel.controls.temperature, in: CameraControls.temperatureRange, step: 50)
                        }
                        VStack(alignment: .leading) {
                            Text("Оттенок: \(Int(viewModel.controls.tint))")
                            Slider(value: $viewModel.controls.tint, in: CameraControls.tintRange, step: 1)
                        }
                    }
                }

                if caps.hasTorch {
                    Section {
                        Toggle("Фонарик", isOn: $viewModel.controls.torch)
                    }
                }

                Section {
                    Button("Сбросить всё на авто", role: .destructive, action: viewModel.resetControls)
                }
            }
            .navigationTitle("Камера")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
    }

    // MARK: - Helpers

    private func modes(lock: Bool, manual: Bool) -> [ControlMode] {
        [.auto] + (lock ? [.locked] : []) + (manual ? [.manual] : [])
    }

    @ViewBuilder
    private func modePicker(_ title: String, selection: Binding<ControlMode>, modes: [ControlMode]) -> some View {
        if modes.count > 1 {
            Picker(title, selection: selection) {
                ForEach(modes) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
        } else {
            Text("Только автоматически на этой камере")
                .foregroundStyle(.secondary)
        }
    }

    // Mode changes go through the view model, which seeds manual values from the camera.

    private var focusModeBinding: Binding<ControlMode> {
        Binding(get: { viewModel.controls.focusMode }, set: { viewModel.setFocusMode($0) })
    }

    private var exposureModeBinding: Binding<ControlMode> {
        Binding(get: { viewModel.controls.exposureMode }, set: { viewModel.setExposureMode($0) })
    }

    private var whiteBalanceModeBinding: Binding<ControlMode> {
        Binding(get: { viewModel.controls.whiteBalanceMode }, set: { viewModel.setWhiteBalanceMode($0) })
    }
}

#Preview {
    CameraControlsView(viewModel: CameraViewModel())
}
