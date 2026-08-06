import BranWatch
import SwiftUI

/// Les réglages du veilleur.
///
/// Deux décisions structurantes seulement — observer les fenêtres ou non, et le
/// seuil de mouvement — et les deux méritent une explication complète parce que
/// l'une coûte une autorisation et l'autre est un nombre que personne ne peut
/// deviner. Le reste a un défaut qui marche.
struct WatchSettingsSection: View {
    @Bindable var model: AppModel

    private var settings: WatchSettings { model.watchSettings }

    var body: some View {
        Section("Veille des sessions parallèles") {
            Toggle("Surveiller mes sessions en cours", isOn: Binding(
                get: { settings.isEnabled },
                set: { model.watch.setEnabled($0) }
            ))

            Text("bran lit lesquelles de vos sessions d'agents ont fini leur tour et vous attendent. Les transcriptions sont lues **sans jamais charger une ligne de conversation** : trois champs — le dossier, la branche, le marqueur de fin de tour — et rien d'autre.")
                .font(Type.meta)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Observer aussi les fenêtres", isOn: Binding(
                get: { settings.watchesWindows },
                set: { settings.watchesWindows = $0 }
            ))
            .disabled(settings.isEnabled == false)

            Text("Ajoute les tribus qui n'ont pas de transcription — un onglet claude.ai, une compilation dans un terminal — en comparant des vignettes de 320 pixels en niveaux de gris. Aucune image n'est conservée : bran ne garde qu'une liste de moyennes. Demande l'autorisation d'enregistrement de l'écran, et consomme un peu de batterie.")
                .font(Type.meta)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if settings.watchesWindows, ScreenAccess.isUsable == false {
                screenWarning
            }

            if settings.watchesWindows {
                sensitivity
            }

            Picker("Prévenir après", selection: Binding(
                get: { settings.waitingAfterMinutes },
                set: { settings.waitingAfterMinutes = $0 }
            )) {
                ForEach([1, 2, 3, 5, 10], id: \.self) { minutes in
                    Text("\(minutes) min").tag(minutes)
                }
            }
            .disabled(settings.isEnabled == false)

            Text("Durée d'immobilité au-delà de laquelle une voie sans capteur certain est réputée vous attendre. Les sessions d'agents, elles, ne dépendent pas de ce seuil : leur fin de tour est un fait, pas une supposition.")
                .font(Type.meta)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Afficher la voie à reprendre au-dessus de tout", isOn: Binding(
                get: { settings.showsOverlay },
                set: { settings.showsOverlay = $0 }
            ))
            .disabled(settings.isEnabled == false)

            Text("La pilule n'apparaît que lorsque quelque chose vous attend **et** que vous ne faites rien : c'est le seul moment où interrompre ne coûte rien. Elle disparaît pendant une réunion.")
                .font(Type.meta)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Conserver le journal", selection: Binding(
                get: { settings.retentionDays },
                set: {
                    settings.retentionDays = $0
                    model.watch.applySettings()
                }
            )) {
                ForEach(WatchRetention.offeredDays, id: \.self) { days in
                    Text(WatchRetention(days: days).label).tag(days)
                }
            }

            Text(retentionHint)
                .font(Type.meta)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: -

    /// Le seuil de mouvement, et **l'aveu qui va avec**.
    ///
    /// La valeur de départ vient d'un unique relevé du spike, sur une machine
    /// qui n'est pas celle de l'utilisateur, avec ses fenêtres à lui. La
    /// présenter comme un réglage réglé serait un mensonge poli ; on dit d'où
    /// elle sort et on laisse la corriger.
    private var sensitivity: some View {
        VStack(alignment: .leading, spacing: Space.small) {
            HStack {
                Text("Seuil de mouvement")
                Spacer()
                // La chasse fixe, ici, n'est pas décorative : le nombre change à
                // chaque pixel de glissement du curseur, et trois décimales en
                // largeur variable le font gigoter sous le doigt.
                Text(settings.busyRatio.formatted(.number.precision(.fractionLength(3))))
                    .font(Type.code)
                    .foregroundStyle(.secondary)
            }

            Slider(
                value: Binding(
                    get: { settings.busyRatio },
                    set: {
                        settings.busyRatio = $0
                        settings.busyRatioMeasured = true
                    }
                ),
                in: 0.002 ... 0.05
            )

            if settings.busyRatioMeasured == false {
                Label(
                    "Valeur non mesurée sur ce Mac : elle vient d'un seul relevé — ratio 0,036 sur un terminal en travail, 0,000 sur des fenêtres immobiles. Si des voies sont annoncées actives alors qu'elles ne le sont pas, montez-la.",
                    systemImage: "ruler"
                )
                .font(Type.meta)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var retentionHint: String {
        let size = ByteCountFormatStyle(style: .file).format(model.watch.store.journalBytes)
        guard settings.retentionDays > 0 else {
            return "Aucun fichier n'est écrit. La veille fonctionne, elle ne laisse simplement aucune trace — et la dette d'attente du jour repart de zéro à chaque lancement."
        }
        return "Un fichier par jour dans le dossier Veille, une ligne par changement d'état. Le journal occupe \(size). C'est aussi ce qui permet de dire combien de temps vos sessions vous ont attendu cette semaine."
    }

    private var screenWarning: some View {
        HStack(alignment: .top, spacing: Space.small) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Palette.attention)
            VStack(alignment: .leading, spacing: Space.tight) {
                Text("bran ne peut pas observer les fenêtres : l'autorisation d'enregistrement de l'écran manque ou a été accordée à une version antérieure.")
                    .font(Type.cardBody)
                Button("Ouvrir les Réglages") { SystemSettings.open(.screenRecording) }
                    .controlSize(.small)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
