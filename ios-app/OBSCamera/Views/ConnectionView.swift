import SwiftUI

/// "Куда отправлять": OBS computers found on Wi‑Fi, a typed IP, and the USB cable.
struct ConnectionView: View {
    @ObservedObject var viewModel: CameraViewModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var addressFocused: Bool

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if viewModel.hosts.isEmpty {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Ищем OBS в сети…")
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(viewModel.hosts) { host in
                        Button {
                            viewModel.selectedTargetID = host.id
                            dismiss()
                        } label: {
                            checkRow(host.name, isSelected: viewModel.selectedTargetID == host.id)
                        }
                    }
                    HStack {
                        TextField("Другой: IP-адрес", text: $viewModel.manualAddress)
                            .keyboardType(.numbersAndPunctuation)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($addressFocused)
                            .submitLabel(.done)
                            .onSubmit { if viewModel.canConnectManually { dismiss() } }
                        if viewModel.isManualTarget {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.brand)
                        }
                    }
                    .onChange(of: addressFocused) { _, focused in
                        if focused { viewModel.selectedTargetID = CameraViewModel.manualTargetID }
                    }
                } header: {
                    Text("Wi‑Fi")
                } footer: {
                    if !viewModel.isIdle {
                        Text("Новый компьютер будет использован после «Стоп» и «Старт».")
                    } else if let error = viewModel.discoveryError {
                        Text(error)
                    }
                }

                Section {
                    NavigationLink {
                        USBHelpView(viewModel: viewModel)
                    } label: {
                        LabeledContent("USB-кабель", value: usbStatus)
                    }
                } header: {
                    Text("Кабель")
                } footer: {
                    Text("Wi‑Fi и USB работают одновременно. Если в OBS выбрать «USB-кабель», видео пойдёт по кабелю.")
                }

                if case .failed = viewModel.status {
                    errorSection
                } else if viewModel.reconnectError != nil {
                    errorSection
                }
            }
            .tint(Color.brand)
            .navigationTitle("Куда отправлять")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
    }

    private var usbStatus: String {
        if viewModel.isStreamingViaUSB { return "подключён" }
        return viewModel.isUSBListening ? "ждёт OBS" : "после «Старт»"
    }

    private var errorSection: some View {
        Section {
            Label(viewModel.connectionDetail, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    private func checkRow(_ title: String, isSelected: Bool) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(Color.primary)
            Spacer()
            if isSelected {
                Image(systemName: "checkmark")
                    .foregroundStyle(Color.brand)
            }
        }
    }
}

/// "Подключите кабель": what to do on the computer for USB.
private struct USBHelpView: View {
    @ObservedObject var viewModel: CameraViewModel

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "cable.connector")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text(viewModel.isStreamingViaUSB ? "Кабель подключён" : "Подключите кабель")
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
            Text(statusLine)
                .font(.headline)
                .foregroundStyle(viewModel.isStreamingViaUSB ? Color.green : Color.yellow)
            Text("В OBS откройте свойства источника «iPhone Camera» и выберите «USB-кабель». Если iPhone спросит, нажмите «Доверять».")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
            Spacer()
        }
        .padding(.horizontal, 32)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var statusLine: String {
        if viewModel.isStreamingViaUSB { return "Видео идёт по кабелю" }
        return viewModel.isUSBListening ? "Ждём подключения" : "Нажмите «Старт», чтобы снова ждать OBS"
    }
}
