import SwiftUI

/// Une capacité : ce qu'on fait, par quel geste, et si c'est prêt.
///
/// **Extrait de `PermissionsView` pour être partagé.** L'accueil savait déjà
/// dessiner un état d'autorisation avec le bouton qui le débloque ; les réglages
/// se contentaient d'une ligne « accordée / manquante » sans bouton. Deux vues du
/// même sujet, dont une seule agissait. Le composant vit désormais dans un
/// fichier neutre pour que les deux écrans disent la même chose.
enum CapabilityState {
    case ready(String)
    /// Rien n'a encore été demandé : un clic suffit, le système répondra.
    case todo(String)
    /// L'utilisateur a répondu non. **Un troisième état, pas un `todo`
    /// déguisé** : le système ne redemandera plus rien, et le seul recours
    /// passe par les Réglages système. Les confondre, c'est proposer un bouton
    /// qui ne peut plus rien faire.
    case refused(String)

    var isReady: Bool { if case .ready = self { true } else { false } }

    var label: String {
        switch self {
        case .ready(let text), .todo(let text), .refused(let text): text
        }
    }

    var symbol: String {
        switch self {
        case .ready: "checkmark.circle.fill"
        case .todo: "circle.dashed"
        case .refused: "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .ready: Palette.done
        case .todo: Palette.asleep
        case .refused: Palette.attention
        }
    }
}

struct CapabilityCard<Actions: View>: View {

    /// Le rang de la carte, uniquement pour décaler la cascade de pastilles.
    let index: Int
    let symbol: String
    let title: String
    /// Le geste, écrit comme une phrase. C'est la ligne qui fait comprendre la
    /// fonction sans avoir à la lire deux fois.
    let gesture: String
    let state: CapabilityState
    @ViewBuilder var actions: () -> Actions

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bounce = 0

    var body: some View {
        HStack(alignment: .top, spacing: Space.inset) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(state.isReady ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 22)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Space.tight) {
                Text(title).font(.headline)

                Text(gesture)
                    .font(Type.cardBody)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: Space.tight) {
                    Image(systemName: state.symbol)
                        .font(Type.meta)
                        .foregroundStyle(state.tint)
                        .symbolEffect(.bounce, value: bounce)
                    Text(state.label)
                        .font(Type.meta)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 1)
            }

            Spacer(minLength: Space.small)

            VStack(alignment: .trailing, spacing: Space.tight) { actions() }
        }
        .padding(Space.card)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card(hover: state.isReady == false), in: .rect(cornerRadius: Radius.card))
        .accessibilityElement(children: .contain)
        // La cascade — 0,08 s par rang — lit l'écran de haut en bas à la place
        // de l'utilisateur : elle dit « ça, puis ça, puis ça, c'est fait ».
        .task(id: state.isReady) { await celebrate() }
    }

    private func celebrate() async {
        guard state.isReady, reduceMotion == false else { return }
        try? await Task.sleep(for: .seconds(0.08 * Double(index)))
        guard Task.isCancelled == false else { return }
        bounce += 1
    }
}
