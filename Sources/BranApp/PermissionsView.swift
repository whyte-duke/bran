import Combine
import SwiftUI

/// L'accueil.
///
/// **Organisé par capacité, pas par autorisation.** La version précédente
/// listait trois cases à cocher système et ne disait nulle part ce que
/// l'application savait faire. Quelqu'un qui l'ouvrait apprenait que bran
/// voulait son micro ; il n'apprenait pas qu'il pouvait dicter dans Slack ou
/// récupérer le texte d'une erreur de compilation en traçant un rectangle.
///
/// ```
/// ┌──────────────────────────────────────────────┐
/// │  bran                                        │
/// │  Trois choses, entièrement sur ce Mac.       │
/// │  ┌────────────────────────────────────────┐  │
/// │  │ ⏺ Enregistrer vos réunions      ● prêt │  │
/// │  │   Écran · Micro                        │  │
/// │  ├────────────────────────────────────────┤  │
/// │  │ ⌘ droite → vous parlez → c'est collé   │  │
/// │  │   Accessibilité              ○ à faire │  │
/// │  ├────────────────────────────────────────┤  │
/// │  │ ⧉ ⌘⇧2 → un rectangle → presse-papiers  │  │
/// │  │   Rien de plus à autoriser           ✓ │  │
/// │  └────────────────────────────────────────┘  │
/// └──────────────────────────────────────────────┘
/// ```
///
/// Le troisième bloc est le plus important de l'écran : la capture de texte
/// réutilise l'autorisation d'enregistrement d'écran déjà accordée pour les
/// réunions. Le dire explicitement transforme une fonction qu'on n'aurait pas
/// cherchée en une fonction déjà disponible.
struct PermissionsView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private var permissions: PermissionsService { model.permissions }

    /// Relu à chaque apparition **et à chaque retour dans l'application** :
    /// l'Accessibilité se donne dans les Réglages système, sans que
    /// l'application en soit informée. Sans la seconde relecture, l'utilisateur
    /// cochait la case, revenait, et l'écran continuait à lui demander de la
    /// cocher.
    @State private var isAccessibilityTrusted = HotkeyMonitor.isTrusted

    var body: some View {
        VStack(alignment: .leading, spacing: Space.gutter) {
            header

            VStack(spacing: Space.small) {
                meetings
                dictation
                textCapture
            }

            // **Le conseil n'a de sens qu'une fois la question posée.**
            //
            // Il s'affichait dès que l'écran n'était pas accordé, donc aussi sur
            // une installation neuve où macOS n'a encore rien demandé : « quittez
            // et relancez après l'avoir accordée » y désigne un geste qui n'a pas
            // eu lieu. Il apparaît maintenant exactement quand il est vrai — après
            // le passage par la fenêtre système ou par les Réglages, moment où
            // `CGPreflightScreenCaptureAccess()` continue de répondre non
            // jusqu'au prochain démarrage du processus.
            if permissions.nextStep(forScreenRecording: ()) == .systemSettings {
                Label(
                    "L'autorisation d'enregistrement d'écran n'est prise en compte qu'au prochain démarrage. Quittez et relancez bran après l'avoir accordée.",
                    systemImage: "arrow.clockwise"
                )
                .font(Type.cardBody)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            launchAtLogin

            Spacer(minLength: 0)

            footer
        }
        .padding(Space.gutter)
        .frame(minWidth: 470)
        .onAppear(perform: refresh)
        // Les autorisations se donnent ailleurs. Le seul instant où l'on peut
        // être sûr d'une réponse fraîche, c'est le retour dans l'application.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
    }

    /// Le démarrage automatique, **déjà activé**, et affiché pour qu'on le sache.
    ///
    /// bran l'enregistre au tout premier lancement — voir
    /// `LoginItemService.adoptDefaultOnFirstLaunch()`. Toutes ses fonctions sont
    /// actives par défaut, et celle-ci les conditionne : bran observe pour
    /// proposer d'enregistrer une réunion, et un observateur qu'il faut penser à
    /// lancer n'observe rien le jour où on l'oublie.
    ///
    /// **L'interrupteur est ici, et pas seulement dans les réglages.** Activer
    /// quelque chose au nom de quelqu'un sans le lui montrer est une inscription
    /// silencieuse, quelles que soient les bonnes raisons qu'on ait. Le montrer
    /// sur l'écran d'accueil, allumé, avec de quoi l'éteindre sur place, en fait
    /// une décision qu'on peut défaire en un clic sans aller la chercher.
    ///
    /// Pas de `CapabilityCard` : les trois cartes du dessus demandent une
    /// autorisation au système, celle-ci n'en demande aucune. Leur donner la même
    /// forme laisserait croire qu'il reste une quatrième case à cocher quelque
    /// part.
    private var launchAtLogin: some View {
        Toggle(isOn: Binding(
            get: { model.loginItem.isEnabled },
            set: { model.setLaunchAtLogin($0) }
        )) {
            VStack(alignment: .leading, spacing: Space.tight) {
                Text("Lancer bran à l'ouverture de session")
                    .font(Type.cardTitle)
                Text("bran veille en arrière-plan et propose d'enregistrer quand il reconnaît une réunion. Il ne démarre jamais un enregistrement tout seul.")
                    .font(Type.cardBody)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.switch)
    }

    /// La sortie.
    ///
    /// Une fois tout en place, l'écran ne le disait pas et ne se refermait pas :
    /// il restait ouvert à répéter que tout allait bien, sans porte.
    @ViewBuilder
    private var footer: some View {
        if model.isFullyReady {
            HStack {
                Label("Tout est prêt", systemImage: "checkmark.circle.fill")
                    .font(Type.cardTitle)
                    .foregroundStyle(Palette.done)
                Spacer()
                Button("Commencer") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        } else {
            HStack {
                // **La promesse était absolue, et elle est fausse depuis que
                // bran sait envoyer.** La sauvegarde chiffrée et l'envoi au CRM
                // font tous deux sortir des données de la machine. Ils sont
                // éteints tant qu'on ne les configure pas — c'est ce que la
                // phrase dit maintenant, au lieu de promettre ce que le code ne
                // tient plus.
                Text("Ces trois fonctions restent sur cette machine. Aucun compte. La sauvegarde et l'envoi au CRM, eux, sortent des données — et restent éteints tant que vous ne les configurez pas.")
                    .font(Type.cardBody)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Revérifier") { refresh() }
            }
        }
    }

    private func refresh() {
        permissions.refresh()
        isAccessibilityTrusted = HotkeyMonitor.isTrusted
        model.dictation.host.refreshAvailability()
    }

    // MARK: - Haut

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.small) {
            HStack(spacing: Space.small) {
                Image(systemName: "bird.fill")
                    .font(Type.sheetTitle)
                    .foregroundStyle(.tint)
                Text("bran")
                    .font(.title.weight(.semibold))
            }
            Text("Trois choses, entièrement sur ce Mac.")
                .foregroundStyle(.secondary)
        }
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: - Les trois capacités

    private var meetings: some View {
        CapabilityCard(
            index: 0,
            symbol: "record.circle",
            title: "Enregistrer vos réunions",
            gesture: "bran repère une fenêtre Meet et propose — il ne démarre jamais tout seul.",
            state: meetingsState
        ) {
            // **Le libellé dit où le clic mène, parce que le clic ne mène pas
            // toujours au même endroit.**
            //
            // macOS ne pose chaque question qu'une fois. Après un refus, rappeler
            // l'API ne fait plus rien du tout — aucune fenêtre, aucune erreur, un
            // bouton mort. `PermissionsService.nextStep` distingue les deux cas ;
            // ici on ne fait qu'en tirer le mot juste, et « Ouvrir les Réglages
            // système » est le seul qui ne mente pas dans le second.
            if permissions.nextStep(forScreenRecording: ()) != .nothingToDo {
                Button(
                    label(
                        asking: "Autoriser l'écran",
                        step: permissions.nextStep(forScreenRecording: ())
                    )
                ) {
                    permissions.requestScreenRecording()
                }
            }
            if permissions.nextStep(forMicrophone: ()) != .nothingToDo {
                Button(
                    label(asking: "Autoriser le micro", step: permissions.nextStep(forMicrophone: ()))
                ) {
                    Task { await permissions.requestMicrophone() }
                }
            }
            if permissions.nextStep(forCalendar: ()) != .nothingToDo, permissions.canRecord {
                Button(
                    label(
                        asking: "Calendrier (facultatif)",
                        step: permissions.nextStep(forCalendar: ())
                    )
                ) {
                    Task { await permissions.requestCalendar() }
                }
                .controlSize(.small)
            }
        }
    }

    /// Le libellé d'un bouton d'autorisation : ce qu'on demande, ou le détour
    /// qu'il faut désormais prendre.
    private func label(asking: String, step: PermissionsService.NextStep) -> String {
        step == .systemSettings ? "Ouvrir les Réglages système" : asking
    }

    /// La dictée demande **deux** choses, et l'accueil doit les montrer
    /// ensemble : l'Accessibilité, et le modèle à télécharger.
    ///
    /// Le téléchargement est proposé ici et pas seulement dans les réglages :
    /// une fonction dont le moteur n'est pas installé n'existe pas pour
    /// quelqu'un qui vient d'ouvrir l'application, et il n'ira pas le chercher
    /// dans un écran qu'il ne sait pas devoir ouvrir.
    private var dictation: some View {
        CapabilityCard(
            index: 1,
            symbol: "waveform",
            title: "Dicter dans n'importe quelle application",
            gesture: "⌘ droite → vous parlez → le texte est collé là où était le curseur.",
            state: dictationState
        ) {
            if isAccessibilityTrusted == false {
                Button("Autoriser") { HotkeyMonitor.requestTrust() }
            }

            switch model.dictation.host.availability {
            case .absent, .failed:
                Button("Télécharger le modèle") { model.dictation.host.warmUp() }
            case .downloading(let fraction):
                // La progression réelle, pas un tourniquet : 483 Mo sans chiffre
                // en face, c'est une attente qu'on ne sait pas mesurer.
                VStack(alignment: .trailing, spacing: Space.tight) {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .frame(width: 130)
                    Text("\(Int(fraction * 100)) % de 483 Mo")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()

                    // **483 Mo sans porte de sortie.**
                    //
                    // Le téléchargement partait au premier clic et ne pouvait
                    // plus s'arrêter : ni bouton, ni raccourci, ni fermeture de
                    // la fenêtre. Sur un partage de connexion, sur une ligne
                    // lente, ou simplement quand on s'est trompé de bouton,
                    // la seule sortie était de quitter l'application — ce qui
                    // laisse le téléchargement à moitié fait sur le disque.
                    //
                    // `cancelLoad()` remet l'état sur `.installed` ou `.absent`
                    // selon ce qui est déjà là, donc le bouton « Télécharger »
                    // revient tout seul et le geste est reprenable.
                    Button("Annuler") { model.dictation.host.cancelLoad() }
                        .buttonStyle(.plain)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            case .loading:
                ProgressView().controlSize(.small)
            case .installed, .ready:
                EmptyView()
            }
        }
    }

    private var dictationState: CapabilityState {
        guard isAccessibilityTrusted else { return .todo("Demande l'Accessibilité") }

        switch model.dictation.host.availability {
        case .installed, .ready:
            return .ready("Parakeet TDT 0.6B v3 · français")
        case .downloading(let fraction):
            return .todo("Téléchargement — \(Int(fraction * 100)) % de 483 Mo")
        case .loading:
            return .todo("Chargement du modèle…")
        case .failed(let reason):
            return .todo(reason)
        case .absent:
            // La taille annoncée avant le clic : c'est la question qu'on se pose
            // toujours, et ne pas y répondre fait hésiter.
            return .todo("Modèle à télécharger — 483 Mo, une seule fois")
        }
    }

    private var textCapture: some View {
        CapabilityCard(
            index: 2,
            symbol: "text.viewfinder",
            title: "Récupérer le texte affiché à l'écran",
            gesture: "⌘⇧2 → vous tracez un rectangle → le texte part dans le presse-papiers.",
            state: textCaptureState
        ) {
            if permissions.screenRecording == .granted, isAccessibilityTrusted == false {
                Button("Autoriser") { HotkeyMonitor.requestTrust() }
            }
        }
    }

    /// **La carte annonçait « prêt » sur une fonction qui ne démarrait pas.**
    ///
    /// Elle ne regardait que l'autorisation d'écran — vraie pour Vision, qui lit
    /// bien l'image sans rien d'autre. Mais le geste que la carte décrit est un
    /// **raccourci global**, et un raccourci global passe par l'event tap
    /// d'Accessibilité : sans elle, `HotkeyMonitor.install()` échoue et
    /// `AppModel` éteint la capture. Écran accordé, Accessibilité refusée
    /// donnait donc une pastille verte « Aucune autorisation supplémentaire » et
    /// un ⌘⇧2 qui ne fait rien.
    ///
    /// La distinction est dite au lieu d'être gommée : l'Accessibilité sert au
    /// raccourci, pas à la lecture de l'écran.
    private var textCaptureState: CapabilityState {
        guard permissions.screenRecording == .granted else {
            return .todo("Utilise l'autorisation d'écran ci-dessus")
        }
        guard isAccessibilityTrusted else {
            return .todo("Le raccourci demande l'Accessibilité")
        }
        guard model.snapshotSettings.isEnabled else {
            return .todo("Capture désactivée — à rallumer dans les Réglages")
        }
        // Le message qui compte sur cet écran : c'est déjà disponible.
        return .ready("Aucune autorisation supplémentaire")
    }

    private var meetingsState: CapabilityState {
        guard permissions.canRecord else {
            return .todo("Écran et micro requis")
        }
        return .ready(permissions.calendar == .granted ? "Écran · Micro · Calendrier" : "Écran · Micro")
    }
}

#Preview("Accueil") {
    PermissionsView(model: AppModel())
}
