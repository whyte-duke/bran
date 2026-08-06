import AppKit
import SwiftUI

/// Ce qui ne relève d'aucune fonction en particulier : le démarrage et l'endroit
/// où les fichiers atterrissent.
///
/// Les deux vivaient aux extrémités opposées d'un formulaire de huit sections —
/// le démarrage en deuxième position, le dossier tout en bas — alors qu'ils
/// répondent à la même question : comment bran s'installe sur cette machine.
struct GeneralSettingsSection: View {
    @Bindable var model: AppModel

    var body: some View {
        Section("Démarrage") {
            Toggle("Lancer bran à l'ouverture de session", isOn: Binding(
                get: { model.loginItem.isEnabled },
                set: { model.setLaunchAtLogin($0) }
            ))
            Text("bran démarre sans fenêtre ni icône du Dock, et se contente d'observer.")
                .font(Type.meta)
                .foregroundStyle(.secondary)
        }

        Section("Consommation") {
            Toggle("Afficher la consommation dans la barre de menus", isOn: Binding(
                get: { model.meter.showsInMenuBar },
                set: { model.meter.showsInMenuBar = $0 }
            ))
            Text("Un second élément, séparé de celui de bran : « processeur·mémoire », en pourcentage. Éteint, il ne mesure plus rien — la boucle s'arrête aussi.")
                .font(Type.meta)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        Section("Dossier des enregistrements") {
            HStack(spacing: Space.small) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                Text(model.storage.root.path(percentEncoded: false))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .textSelection(.enabled)
                    .help(model.storage.root.path(percentEncoded: false))

                Spacer(minLength: Space.small)

                Button("Modifier…") { model.chooseStorageFolder() }
                    .disabled(model.isRecording)
            }

            if let problem = model.storage.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Palette.attention)
                    .font(Type.cardBody)
                    .fixedSize(horizontal: false, vertical: true)
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
                .font(Type.meta)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
