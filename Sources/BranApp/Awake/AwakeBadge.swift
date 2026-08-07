import BranCore
import SwiftUI

/// **Le signe que le Mac est tenu éveillé, dans la fenêtre.**
///
/// ```
///   ┌────────────────────────────┐
///   │  ☕︎  Éveil                  │
///   │     sans limite   Arrêter  │
///   └────────────────────────────┘
/// ```
///
/// L'icône de la barre de menus dit déjà l'état, mais elle le dit dans seize
/// points de large, au milieu de quinze autres icônes, et hors de l'application.
/// Cette pastille-ci répond à l'autre question : « j'ai ouvert bran, est-ce que
/// c'est toujours actif, et jusqu'à quand ». Elle **n'apparaît que lorsque
/// l'éveil est allumé** — même doctrine que les lignes du moniteur : une ligne
/// permanente qui dit « rien ne se passe » cesse d'être lue en une semaine.
///
/// **Le battement du symbole est la seule animation perpétuelle hors de
/// l'encoche**, et il est conditionné à « Réduire les animations » comme les
/// trois autres. `.symbolEffect(.pulse)` est joué par SwiftUI et non par nous :
/// `branLoop` ne peut pas l'atteindre, il faut donc l'éteindre à la main. C'est
/// exactement le cas de `NotchView` au chargement du moteur.
struct AwakeBadge: View {
    let awake: AwakeController

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: Space.small) {
            Image(systemName: AppModel.awakeSymbol)
                .foregroundStyle(.tint)
                .symbolEffect(.pulse, options: .repeating, isActive: reduceMotion == false)
                .frame(width: SidebarItem.iconWidth)

            VStack(alignment: .leading, spacing: 0) {
                Text("Éveil")
                    .font(Type.meta.weight(.medium))
                Text(detail)
                    .font(Type.metaFaint)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }

            Spacer(minLength: Space.tight)

            Button("Arrêter") { awake.stop() }
                .buttonStyle(.link)
                .font(Type.metaFaint)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Éveil actif — \(detail)")
    }

    /// « sans limite », ou ce qu'il reste. Le décompte vient de la boucle du
    /// contrôleur, pas d'un `Date.now` relu à chaque rendu.
    private var detail: String {
        awake.countdown.map { "encore \($0)" } ?? "sans limite"
    }
}
