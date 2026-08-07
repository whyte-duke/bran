import SwiftUI

/// **Un panneau : une surface, une barre de titre, un contenu.**
///
/// ```
/// ┌────────────────────────────────────┐
/// │ LA JOURNÉE                         │ ← barre, plus claire
/// ├────────────────────────────────────┤
/// │                                    │
/// │   ███████░░████████    ▒▒▒▒▒████   │ ← contenu
/// │                                    │
/// └────────────────────────────────────┘
/// ```
///
/// **Pourquoi ça change quelque chose.** Le journal de bord empilait ses
/// sections sur un fond plat, séparées par un titre gris et un paragraphe
/// d'explication. C'est la forme d'un document : elle se lit de haut en bas, une
/// fois. Un tableau de bord se consulte — on y revient dix fois par jour pour
/// aller chercher une chose précise, et l'œil doit pouvoir sauter directement au
/// bloc qui l'intéresse sans relire les titres.
///
/// Une surface distincte fait ce saut possible ; un titre seul ne le fait pas.
/// C'est la même raison qui met un cadre autour d'un tableau plutôt qu'une
/// ligne blanche au-dessus.
///
/// **La barre porte le titre, et rien d'autre.** Pas de phrase d'explication :
/// elles vivent maintenant dans le contenu, près de ce qu'elles expliquent, ou
/// dans une infobulle. Une barre de titre qui grossit cesse d'être un repère.
struct Panel<Content: View>: View {
    let title: String
    /// Ce qui se pose à droite de la barre : une valeur totale, un compteur, un
    /// bouton. Rare, et c'est voulu — une barre de titre encombrée redevient
    /// une ligne de texte.
    var trailing: String?
    /// L'explication, quand il en faut une. Elle vit dans l'infobulle du titre
    /// plutôt que sous lui : « 1,6 voie en parallèle » a besoin qu'on dise sur
    /// quoi la moyenne est prise, mais pas à chaque fois qu'on ouvre l'écran.
    var help: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            head
            Divider()
            content
                .padding(Space.inset)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Palette.panel, in: .rect(cornerRadius: Radius.panel))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.panel, style: .continuous)
                .strokeBorder(.separator, lineWidth: PanelMetric.edge)
        }
        // Le titre est un en-tête pour VoiceOver, et le contenu reste
        // explorable : `children: .contain` garde la hiérarchie au lieu de
        // fondre tout le panneau en une seule annonce illisible.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    private var head: some View {
        HStack(spacing: Space.small) {
            Text(title.localizedUppercase)
                .font(Type.panelHead)
                .kerning(PanelMetric.kerning)
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)

            if let help {
                Image(systemName: "info.circle")
                    .font(Type.metaFaint)
                    .foregroundStyle(.tertiary)
                    .help(help)
                    // L'infobulle est une aide de souris. Son texte doit
                    // exister aussi pour qui n'en a pas.
                    .accessibilityLabel("À propos de \(title)")
                    .accessibilityValue(help)
            }

            Spacer(minLength: Space.small)

            if let trailing {
                Text(trailing)
                    .font(Type.meta.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, Space.inset)
        .padding(.vertical, Space.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.panelHead)
    }
}

enum PanelMetric {
    /// Le liseré du panneau. Un point : il sépare, il ne dessine pas.
    static let edge: CGFloat = 1
    /// L'écartement des petites capitales. Sans lui elles se collent et
    /// deviennent moins lisibles que des bas-de-casse, ce qui annule tout
    /// l'intérêt de les mettre en capitales.
    static let kerning: CGFloat = 0.6
}
