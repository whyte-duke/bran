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

    private var permissions: PermissionsService { model.permissions }

    /// Relu à chaque apparition : l'Accessibilité se donne dans les Réglages
    /// système, sans que l'application en soit informée.
    @State private var isAccessibilityTrusted = HotkeyMonitor.isTrusted

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            header

            VStack(spacing: 10) {
                meetings
                dictation
                textCapture
            }

            if permissions.screenRecording != .granted {
                Label(
                    "L'autorisation d'enregistrement d'écran n'est prise en compte qu'au prochain démarrage. Quittez et relancez bran après l'avoir accordée.",
                    systemImage: "arrow.clockwise"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            HStack {
                Text("Rien ne quitte cette machine. Aucun compte, aucun envoi.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Revérifier") { refresh() }
            }
        }
        .padding(26)
        .frame(minWidth: 470)
        .onAppear(perform: refresh)
    }

    private func refresh() {
        permissions.refresh()
        isAccessibilityTrusted = HotkeyMonitor.isTrusted
        model.dictation.host.refreshAvailability()
    }

    // MARK: - Haut

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 9) {
                Image(systemName: "bird.fill")
                    .font(.system(size: 19, weight: .semibold))
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

/// Une capacité : ce qu'on fait, par quel geste, et si c'est prêt.
private enum CapabilityState {
    case ready(String)
    case todo(String)

    var isReady: Bool { if case .ready = self { true } else { false } }
    var label: String {
        switch self {
        case .ready(let text), .todo(let text): text
        }
    }
}

private struct CapabilityCard<Actions: View>: View {

    let symbol: String
    let title: String
    /// Le geste, écrit comme une phrase. C'est la ligne qui fait comprendre la
    /// fonction sans avoir à la lire deux fois.
    let gesture: String
    let state: CapabilityState
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: symbol)
                .font(.system(size: 17))
                .foregroundStyle(state.isReady ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 22)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)

                Text(gesture)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 5) {
                    Image(systemName: state.isReady ? "checkmark.circle.fill" : "circle.dashed")
                        .font(.caption)
                        .foregroundStyle(state.isReady ? .green : .secondary)
                    Text(state.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 1)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 5) { actions() }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            state.isReady ? AnyShapeStyle(.quaternary.opacity(0.22)) : AnyShapeStyle(.quaternary.opacity(0.4)),
            in: .rect(cornerRadius: 11)
        )
        .accessibilityElement(children: .contain)
    }
}

#Preview("Accueil") {
    PermissionsView(model: AppModel())
}
