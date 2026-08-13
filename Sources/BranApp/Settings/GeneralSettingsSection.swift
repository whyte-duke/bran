import AppKit
import BranCore
import SwiftUI

/// Ce qui ne relève d'aucune fonction en particulier : le démarrage et l'endroit
/// où les fichiers atterrissent.
///
/// Les deux vivaient aux extrémités opposées d'un formulaire de huit sections —
/// le démarrage en deuxième position, le dossier tout en bas — alors qu'ils
/// répondent à la même question : comment bran s'installe sur cette machine.
struct GeneralSettingsSection: View {
    @Bindable var model: AppModel

    /// La même clé que `DockPresence`, mais observée : `@AppStorage` se réabonne
    /// aux changements de `UserDefaults`, y compris ceux qui viennent du
    /// rattrapage d'échec.
    @AppStorage(DockPresence.defaultsKey) private var showsDockIcon = true

    var body: some View {
        Section("Démarrage") {
            Toggle("Lancer bran à l'ouverture de session", isOn: Binding(
                get: { model.loginItem.isEnabled },
                set: { model.setLaunchAtLogin($0) }
            ))
            Text("bran ouvre sa fenêtre au démarrage, puis se contente d'observer.")
                .font(Type.meta)
                .foregroundStyle(.secondary)

            // **`@AppStorage` et pas une lecture directe.** Le `Binding`
            // précédent lisait `UserDefaults` à chaque rendu, sans rien observer :
            // quand `DockPresence.apply()` remet la préférence sur la réalité
            // parce que le système a refusé le changement, rien n'invalidait la
            // vue et l'interrupteur restait sur la position demandée. Il mentait
            // exactement dans le cas que le rattrapage existe pour couvrir.
            Toggle("Afficher bran dans le Dock", isOn: Binding(
                get: { showsDockIcon },
                set: { showsDockIcon = $0; DockPresence.apply() }
            ))
            Text(DockPresence.explanation)
                .font(Type.meta)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        AwakeSettingsSection(model: model)

        Section("Consommation") {
            Toggle("Afficher la consommation dans la barre de menus", isOn: Binding(
                get: { model.meter.showsInMenuBar },
                set: { model.meter.showsInMenuBar = $0 }
            ))
            Text("Deux lignes dans le menu de bran — « processeur » et « mémoire » —, et le même chiffre dans le libellé chaque fois que rien d'autre ne s'y montre. Éteint, bran ne mesure plus rien : la boucle s'arrête aussi.")
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

            // **Cette phrase parle du changement de dossier, et elle reste
            // vraie.** Elle disait « bran ne déplace aucun fichier », ce qui se
            // lisait comme une promesse générale — et le bouton de rangement,
            // quelques lignes plus bas, l'aurait alors contredite. Son sujet est
            // maintenant écrit en tête : c'est *changer de dossier* qui ne
            // déplace rien, et c'est ce qui compte ici, puisque la crainte que
            // cette phrase apaise est celle de voir quarante réunions partir
            // toutes seules sur un autre volume.
            Text("Changer de dossier ne déplace aucun fichier : les enregistrements déjà réalisés restent où ils sont. Seuls les suivants iront dans le nouveau dossier, et c'est lui que la bibliothèque affichera.")
                .font(Type.meta)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Chaque rendez-vous a son dossier, daté et nommé, et tout ce qui le concerne y tient — la vidéo, l'audio préparé pour le CRM, et la fiche :")
                .font(Type.meta)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            folderExample

            if model.legacyRecordingCount > 0 {
                tidying
            }

            // **Hors du `if`, et c'est le point.** Le compte rendu d'un rangement
            // arrive une fraction de seconde après que le compteur est retombé à
            // zéro : rangé à l'intérieur du bloc, il aurait disparu avec le
            // bouton, au moment exact où il devient lisible. On n'aurait jamais
            // vu que le travail avait abouti — seulement que le bouton n'était
            // plus là, ce qui est aussi ce que ferait un échec silencieux.
            if let notice = model.lastNotice {
                HStack(alignment: .firstTextBaseline, spacing: Space.small) {
                    Label(notice, systemImage: "checkmark.circle")
                        .foregroundStyle(Palette.done)
                        .font(Type.cardBody)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: Space.small)

                    // Une information neutre ne s'impose pas : elle se referme.
                    // Sans ce bouton, elle resterait jusqu'au prochain lancement
                    // et se lirait, une semaine plus tard, comme l'état courant.
                    Button("Fermer") { model.lastNotice = nil }
                        .buttonStyle(.link)
                }
            }
        }
    }

    // MARK: - L'arborescence, montrée

    /// L'arborescence **montrée**, et pas seulement décrite.
    ///
    /// Une phrase — « un dossier par réunion, avec la vidéo, l'audio et la
    /// fiche » — demande de se figurer le résultat ; quatre lignes de listing
    /// l'exposent, et on y reconnaît immédiatement ce qu'on verra dans le
    /// Finder. C'est la réponse à « que l'arborescence se voie bien mieux » :
    /// pour une structure de fichiers, montrer est plus court que décrire.
    ///
    /// Les extensions et le nom de la fiche viennent de `MeetingFolder`, jamais
    /// d'une chaîne recopiée : un exemple faux est pire qu'une absence d'exemple,
    /// et c'est exactement ce qui arrive à un exemple écrit à la main le jour où
    /// la convention change. Seuls la date et le titre sont inventés — ils le
    /// sont ouvertement, ce sont ceux du commentaire de `MeetingFolder`.
    private var folderExample: some View {
        let base = "2026-08-11 09h57 — SA SERMATEC"

        return Grid(alignment: .leading, horizontalSpacing: Space.stack, verticalSpacing: Space.tight) {
            exampleRow(base + "/", "le rendez-vous", indented: false)
            exampleRow("\(base).\(MeetingFolder.videoExtension)", "la vidéo, compressée")
            exampleRow("\(base).\(MeetingFolder.audioExtension)", "l'audio préparé pour le CRM")
            exampleRow(MeetingFolder.sidecarName, "la fiche : titre, participants, notes")
        }
        .branWell()
        // Un listing se lit comme un tout ; VoiceOver le donne donc en une seule
        // phrase, au lieu de huit fragments dont quatre sont des noms de
        // fichiers épelés hors contexte.
        .accessibilityElement(children: .combine)
    }

    /// Une ligne du listing : le nom en chasse fixe, son rôle en clair.
    ///
    /// La chasse fixe n'est pas décorative — c'est elle qui aligne les trois
    /// enfants sous leur dossier et fait voir l'emboîtement. Le retrait est un
    /// vrai rembourrage et non des espaces dans la chaîne : des espaces se
    /// sélectionneraient avec le texte, et se copieraient avec lui.
    private func exampleRow(_ name: String, _ role: String, indented: Bool = true) -> some View {
        GridRow {
            Text(name)
                .font(Type.code)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.leading, indented ? Space.inset : .zero)

            Text(role)
                .font(Type.meta)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Le rangement des anciens

    /// Ranger ce qui a été enregistré avant cette arborescence.
    ///
    /// N'apparaît que s'il reste quelque chose à ranger, et disparaît de
    /// lui-même une fois le travail fait : un bouton qui ne ferait plus rien
    /// resterait sinon à vie dans les réglages, et il faudrait le lire à chaque
    /// passage pour se rappeler qu'il ne sert plus.
    @ViewBuilder
    private var tidying: some View {
        HStack(spacing: Space.small) {
            Button(tidyLabel) { model.tidyRecordingFolders() }
                // Pendant une session, la racine est un dossier dans lequel
                // `replayd` écrit : déplacer des fichiers pendant ce temps-là,
                // c'est déplacer le sol sous ses pieds.
                //
                // `hasOpenSession` et pas `isRecording`, parce que c'est la
                // condition que `tidyRecordingFolders()` s'impose à lui-même.
                // Avec `isRecording`, le bouton serait resté cliquable en pause
                // et pendant la finalisation, et le clic n'aurait rien fait du
                // tout — un bouton qui ne répond pas est pire qu'un bouton grisé,
                // qui, lui, dit pourquoi.
                .disabled(model.isTidying || model.hasOpenSession)
                .help(model.hasOpenSession
                    ? "Impossible pendant un enregistrement : bran écrit dans ce dossier."
                    : "Chaque enregistrement rangé à plat rejoint un dossier à son nom.")

            if model.isTidying {
                ProgressView().controlSize(.small)
                Text("Rangement en cours…")
                    .font(Type.meta)
                    .foregroundStyle(.secondary)
            }
        }

        Text("Les fichiers sont déplacés à l'intérieur du dossier des enregistrements, chacun dans un dossier à son nom. Rien n'est supprimé, rien n'est réencodé, rien ne quitte ce dossier — et la bibliothèque continue de tout afficher, pendant comme après.")
            .font(Type.meta)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Le libellé du bouton, au singulier quand il n'en reste qu'un.
    ///
    /// « Ranger les 1 anciens enregistrements » est le genre de phrase qui fait
    /// douter du reste de l'application, et le cas n'a rien de rare : c'est
    /// l'état dans lequel finit toute bibliothèque qu'on range — le dernier.
    private var tidyLabel: String {
        model.legacyRecordingCount == 1
            ? "Ranger l'ancien enregistrement dans son dossier"
            : "Ranger les \(model.legacyRecordingCount) anciens enregistrements en dossiers"
    }
}
