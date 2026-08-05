import SwiftUI

struct SettingsPane: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Réglages")
                .font(.title2.weight(.semibold))
                .padding(20)

            Divider()

            Form {
                Section("Qualité d'enregistrement") {
                    Picker("Qualité", selection: $model.quality) {
                        ForEach(QualityPreset.allCases) { preset in
                            VStack(alignment: .leading) {
                                Text(preset.label)
                                Text(preset.estimatedRate).foregroundStyle(.secondary)
                            }
                            .tag(preset)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    .disabled(model.isRecording)

                    Text("Le débit dépend du contenu : un écran figé coûte presque rien, une visio animée coûte le maximum. Ces valeurs sont des ordres de grandeur mesurés sur une vraie réunion.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if model.isRecording {
                        Text("Modification impossible pendant un enregistrement : changer la configuration d'un flux actif l'interrompt.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                Section("Démarrage") {
                    Toggle("Lancer bran à l'ouverture de session", isOn: Binding(
                        get: { model.loginItem.isEnabled },
                        set: { model.setLaunchAtLogin($0) }
                    ))
                    Text("bran démarre sans fenêtre ni icône du Dock, et se contente d'observer.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                DictationSettingsSection(model: model)

                CRMSettingsSection(configuration: model.uploads.configuration, uploads: model.uploads)

                Section("Autorisations") {
                    PermissionsSummary(permissions: model.permissions)
                }

                Section("Dossier des enregistrements") {
                    HStack(spacing: 10) {
                        Image(systemName: "folder")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)

                        Text(model.storage.root.path(percentEncoded: false))
                            .lineLimit(1)
                            .truncationMode(.head)
                            .textSelection(.enabled)
                            .help(model.storage.root.path(percentEncoded: false))

                        Spacer(minLength: 8)

                        Button("Modifier…") { model.chooseStorageFolder() }
                            .disabled(model.isRecording)
                    }

                    if let problem = model.storage.problem {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.callout)
                    }

                    HStack {
                        Button("Ouvrir le dossier") {
                            NSWorkspace.shared.open(model.storage.root)
                        }
                        if model.storage.isDefault == false {
                            Button("Revenir au dossier par défaut") { model.resetStorageFolder() }
                                .disabled(model.isRecording)
                        }
                    }

                    Text("Les enregistrements déjà réalisés restent où ils sont — bran ne déplace aucun fichier. Seuls les suivants iront dans le nouveau dossier, et c'est lui que la bibliothèque affichera.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Terminé") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 560, height: 620)
    }
}

private struct PermissionsSummary: View {
    @Bindable var permissions: PermissionsService

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            row("Enregistrement de l'écran", permissions.screenRecording)
            row("Microphone", permissions.microphone)
            row("Calendrier", permissions.calendar)
        }
        .onAppear { permissions.refresh() }
    }

    private func row(_ title: String, _ access: PermissionsService.Access) -> some View {
        HStack(spacing: 8) {
            Image(systemName: access == .granted ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(access == .granted ? Color.green : .secondary)
            Text(title)
            Spacer()
            Text(access == .granted ? "accordée" : "manquante")
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
