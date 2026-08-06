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

            if permissions.screenRecording != .granted {
                Label(
                    "L'autorisation d'enregistrement d'écran n'est prise en compte qu'au prochain démarrage. Quittez et relancez bran après l'avoir accordée.",
                    systemImage: "arrow.clockwise"
                )
                .font(Type.cardBody)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

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
                Text("Rien ne quitte cette machine. Aucun compte, aucun envoi.")
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
                    .font(.title2.weight(.semibold))
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
            if permissions.screenRecording != .granted {
                Button("Autoriser l'écran") { permissions.requestScreenRecording() }
            }
            if permissions.microphone != .granted {
                Button("Autoriser le micro") { Task { await permissions.requestMicrophone() } }
            }
            if permissions.calendar != .granted, permissions.canRecord {
                Button("Calendrier (facultatif)") { Task { await permissions.requestCalendar() } }
                    .controlSize(.small)
            }
        }
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
                VStack(alignment: .trailing, spacing: 3) {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .frame(width: 130)
                    Text("\(Int(fraction * 100)) % de 483 Mo")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
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
            // Le message qui compte sur cet écran : c'est déjà disponible.
            state: permissions.screenRecording == .granted
                ? .ready("Aucune autorisation supplémentaire")
                : .todo("Utilise l'autorisation d'écran ci-dessus")
        ) {
            EmptyView()
        }
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
