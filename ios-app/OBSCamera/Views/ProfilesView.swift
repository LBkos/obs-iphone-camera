import SwiftUI

/// Saved setups: tap to apply, swipe to delete, "+" saves the current one.
struct ProfilesView: View {
    @ObservedObject var viewModel: CameraViewModel
    /// Opened from "Сохранить как профиль…": ask for the name right away.
    var savesOnAppear = false
    @Environment(\.dismiss) private var dismiss
    @State private var asksName = false
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if viewModel.profiles.isEmpty {
                        Text("Сохраните текущие настройки камеры как профиль, чтобы быстро вернуться к ним.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(viewModel.profiles) { profile in
                        Button {
                            viewModel.applyProfile(profile)
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(profile.name)
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(Color.primary)
                                    Text(profile.summary)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if viewModel.activeProfileID == profile.id {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Color.brand)
                                }
                            }
                        }
                    }
                    .onDelete(perform: viewModel.deleteProfiles)
                } footer: {
                    Text(footer)
                }
            }
            .tint(Color.brand)
            .navigationTitle("Профили")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Готово") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        newName = ""
                        asksName = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Сохранить текущие настройки как профиль")
                }
            }
            .alert("Новый профиль", isPresented: $asksName) {
                TextField("Название, например «Стол»", text: $newName)
                Button("Сохранить") { viewModel.saveProfile(named: newName) }
                Button("Отмена", role: .cancel) {}
            } message: {
                Text("Сохранятся камера, формат, кодирование и значения: зум, фокус, экспозиция, баланс белого.")
            }
            .onAppear {
                if savesOnAppear { asksName = true }
            }
        }
    }

    private var footer: String {
        var text = "Смахните влево, чтобы удалить. Профили можно выбрать и в OBS: свойства источника «iPhone Camera», "
            + "«Управлять камерой из OBS». Из OBS меняются только значения камеры, видео не перезапускается."
        if viewModel.isRemoteControlled {
            text = "Сейчас камерой управляет OBS: профиль поменяет только формат и кодирование. " + text
        }
        return text
    }
}
