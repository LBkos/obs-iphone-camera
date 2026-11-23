import SwiftUI

/// Zoom, focus, exposure and white balance: a row of values over the bottom of
/// the preview. Tapping one opens its controls above the row; a long press
/// offers to reset it (or everything) to auto.
enum CameraControlKind: String, CaseIterable, Identifiable {
    case zoom
    case focus
    case exposure
    case whiteBalance

    var id: String { rawValue }

    var title: String {
        switch self {
        case .zoom: "Зум"
        case .focus: "Фокус"
        case .exposure: "Экспозиция"
        case .whiteBalance: "Баланс белого"
        }
    }

    func value(of controls: CameraControls) -> String {
        switch self {
        case .zoom:
            String(format: "%.1f×", controls.zoom)
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

    /// Short text on the chip: "Зум 1.0", "EV +0.3", "ISO 400 · 1/60", "ББ 5000K".
    func chipLabel(of controls: CameraControls) -> String {
        switch self {
        case .zoom:
            String(format: "Зум %.1f", controls.zoom)
        case .focus:
            controls.focusMode == .manual ? String(format: "Фокус %.2f", controls.lensPosition)
                                          : "Фокус \(controls.focusMode.title.lowercased())"
        case .exposure:
            switch controls.exposureMode {
            case .auto: String(format: "EV %+.1f", controls.exposureBias)
            case .locked: "Эксп. фикс."
            case .manual: "ISO \(Int(controls.iso)) · 1/\(controls.shutterDenominator)"
            }
        case .whiteBalance:
            controls.whiteBalanceMode == .manual ? "ББ \(Int(controls.temperature))K"
                                                 : "ББ \(controls.whiteBalanceMode.title.lowercased())"
        }
    }

    /// Not automatic: the chip's dot is filled.
    func isAdjusted(in controls: CameraControls) -> Bool {
        switch self {
        case .zoom: abs(controls.zoom - 1) > 0.01
        case .focus: controls.focusMode != .auto
        case .exposure: controls.exposureMode != .auto || abs(controls.exposureBias) > 0.05
        case .whiteBalance: controls.whiteBalanceMode != .auto
        }
    }
}

/// One value in the row. Empty dot: automatic; filled: set by hand.
struct ControlChip: View {
    let label: String
    let isAdjusted: Bool
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Circle()
                    .strokeBorder(isSelected ? Color.black : Color.white, lineWidth: 1.5)
                    .background(Circle().fill(isAdjusted ? (isSelected ? Color.black : Color.brand) : Color.clear))
                    .frame(width: 10, height: 10)
                Text(label)
                    .lineLimit(1)
            }
            .font(.system(size: 14, weight: .medium, design: .monospaced))
            .padding(.horizontal, 10)
            .frame(height: 40)
            .foregroundStyle(isSelected ? Color.black : Color.white)
            .background(isSelected ? Color.brand : Color.black.opacity(0.6),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isAdjusted && !isSelected ? Color.brand : Color.white.opacity(0.85), lineWidth: 1.5))
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
        case .zoom:
            if caps.maxZoom > caps.minZoom {
                VStack(spacing: 2) {
                    Slider(value: $viewModel.controls.zoom, in: caps.minZoom...caps.maxZoom, step: 0.1)
                        .tint(Color.brand)
                    HStack {
                        Text(String(format: "%.0f×", caps.minZoom))
                        Spacer()
                        Text(String(format: "%.0f×", caps.maxZoom))
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            } else {
                Text("У этой камеры нет зума. Сменить камеру: кнопка справа.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
