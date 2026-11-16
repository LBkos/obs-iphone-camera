import SwiftUI

/// Focus, exposure and white balance: chips under the preview (opened with ^),
/// the selected one shows its controls over the preview.
enum CameraControlKind: String, CaseIterable, Identifiable {
    case focus
    case exposure
    case whiteBalance

    var id: String { rawValue }

    var title: String {
        switch self {
        case .focus: "Фокус"
        case .exposure: "Экспозиция"
        case .whiteBalance: "Баланс белого"
        }
    }

    var chipTitle: String {
        switch self {
        case .focus: "ФОКУС"
        case .exposure: "ЭКСПОЗИЦИЯ"
        case .whiteBalance: "БАЛАНС"
        }
    }

    func value(of controls: CameraControls) -> String {
        switch self {
        case .focus:
            controls.focusMode == .manual ? String(format: "%.2f", controls.lensPosition) : controls.focusMode.title
        case .exposure:
            switch controls.exposureMode {
            case .auto: String(format: "%+.1f EV", controls.exposureBias)
            case .locked: controls.exposureMode.title
            case .manual: "ISO \(Int(controls.iso)) · 1/\(controls.shutterDenominator)"
            }
        case .whiteBalance:
            controls.whiteBalanceMode == .manual ? "\(Int(controls.temperature)) K" : controls.whiteBalanceMode.title
        }
    }
}

struct ControlChip: View {
    let kind: CameraControlKind
    let value: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Text(kind.chipTitle)
                    .font(.system(size: 10, weight: .semibold))
                    .opacity(0.85)
                Text(value)
                    .font(.footnote.weight(.bold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .padding(.horizontal, 8)
            .frame(width: 104, height: 44)
            .foregroundStyle(isSelected ? Color.black : Color.white)
            .background(isSelected ? Color.brand : Color.white.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(kind.title): \(value)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct CameraControlPanel: View {
    @ObservedObject var viewModel: CameraViewModel
    let kind: CameraControlKind

    private var caps: CameraCapabilities { viewModel.capabilities }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(kind.title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(kind.value(of: viewModel.controls))
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundStyle(Color.brand)
            }
            content
            if viewModel.isRemoteControlled {
                Text("Камерой управляет OBS. Изменить можно в свойствах источника «iPhone Camera».")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .disabled(viewModel.isRemoteControlled)
    }

    @ViewBuilder
    private var content: some View {
        switch kind {
        case .focus:
            modePicker(selection: Binding(get: { viewModel.controls.focusMode }, set: { viewModel.setFocusMode($0) }),
                       lock: caps.supportsFocusLock, manual: caps.supportsManualFocus)
            if viewModel.controls.focusMode == .manual {
                labeledSlider(value: $viewModel.controls.lensPosition, in: 0...1, step: 0.01,
                              minLabel: "Близко", maxLabel: "Далеко")
            } else if viewModel.controls.focusMode == .auto {
                Text("Коснитесь превью, чтобы сфокусироваться на точке.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .exposure:
            modePicker(selection: Binding(get: { viewModel.controls.exposureMode }, set: { viewModel.setExposureMode($0) }),
                       lock: caps.supportsExposureLock, manual: caps.supportsManualExposure)
            switch viewModel.controls.exposureMode {
            case .auto:
                if caps.maxExposureBias > caps.minExposureBias {
                    labeledSlider(value: $viewModel.controls.exposureBias,
                                  in: max(caps.minExposureBias, -3)...min(caps.maxExposureBias, 3), step: 0.1,
                                  minLabel: "−3 EV", maxLabel: "+3 EV")
                }
            case .locked:
                EmptyView()
            case .manual:
                if caps.maxISO > caps.minISO {
                    labeledSlider(value: $viewModel.controls.iso, in: caps.minISO...caps.maxISO, step: 1,
                                  minLabel: "ISO \(Int(caps.minISO))", maxLabel: "ISO \(Int(caps.maxISO))")
                }
                if !caps.shutterDenominators.isEmpty {
                    Picker("Выдержка", selection: $viewModel.controls.shutterDenominator) {
                        ForEach(caps.shutterDenominators, id: \.self) { Text("1/\($0)").tag($0) }
                    }
                    .pickerStyle(.menu)
                    .tint(Color.brand)
                }
            }
        case .whiteBalance:
            modePicker(selection: Binding(get: { viewModel.controls.whiteBalanceMode },
                                          set: { viewModel.setWhiteBalanceMode($0) }),
                       lock: caps.supportsWhiteBalanceLock, manual: caps.supportsManualWhiteBalance)
            if viewModel.controls.whiteBalanceMode == .manual {
                labeledSlider(value: $viewModel.controls.temperature, in: CameraControls.temperatureRange, step: 50,
                              minLabel: "2500 K", maxLabel: "8000 K")
                labeledSlider(value: $viewModel.controls.tint, in: CameraControls.tintRange, step: 1,
                              minLabel: "Зелёный", maxLabel: "Пурпурный")
            }
        }
    }

    @ViewBuilder
    private func modePicker(selection: Binding<ControlMode>, lock: Bool, manual: Bool) -> some View {
        let modes: [ControlMode] = [.auto] + (lock ? [.locked] : []) + (manual ? [.manual] : [])
        if modes.count > 1 {
            Picker(kind.title, selection: selection) {
                ForEach(modes) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
        } else {
            Text("Только автоматически на этой камере")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func labeledSlider(value: Binding<Float>, in range: ClosedRange<Float>, step: Float,
                               minLabel: String, maxLabel: String) -> some View {
        VStack(spacing: 2) {
            Slider(value: value, in: range, step: step)
                .tint(Color.brand)
            HStack {
                Text(minLabel)
                Spacer()
                Text(maxLabel)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }
}
