import Combine
import SwiftUI

/// L'en-tête d'une section : grand titre, sous-titre, et une barre d'outils.
///
/// Toujours la même forme d'une section à l'autre — c'est ce qui fait qu'on sait
/// où regarder avant même d'avoir lu.
struct PaneHeader<Trailing: View>: View {
    let title: String
    let subtitle: String

    /// **Optionnel, pour la seule section qui n'a rien à chercher.**
    ///
    /// Les six autres listent des choses — des réunions, des dictées, des voies —
    /// et un champ de recherche y répond à « laquelle ». « Débit » n'affiche pas
    /// une liste : elle affiche un état, celui de la ligne maintenant. Un champ
    /// qui filtrerait quatre nombres serait un contrôle qu'on ne peut pas
    /// utiliser, posé exactement là où l'œil a appris qu'il y en a un — donc
    /// pire qu'une absence.
    ///
    /// La forme, elle, ne bouge pas : grand titre, sous-titre, barre d'outils à
    /// droite, filet en dessous. C'est ce qui fait qu'on sait où regarder, et
    /// c'est ce que la régularité protégeait vraiment.
    var query: Binding<String>?
    var searchPrompt: String = ""
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        VStack(alignment: .leading, spacing: Space.stack) {
            HStack(alignment: .firstTextBaseline) {
                // **Le même défaut que les bandeaux, sans `fixedSize` pour le
                // trahir.**
                //
                // `NoticeRow` a payé la découverte : un texte qui s'enroule
                // répond à une largeur quasi nulle par une hauteur idéale
                // gigantesque, et cette hauteur devient le plancher de
                // redimensionnement de la fenêtre entière. Le correctif de
                // l'époque a visé `fixedSize(vertical:)` en le croyant coupable ;
                // mesuré le 02/09/2026 sur une phrase de 130 caractères, un
                // `Text` **nu** rend exactement la même hauteur idéale :
                //
                // ```
                //   largeur │ Text nu │ Text + fixedSize
                //       900 │   16 pt │            16 pt
                //       260 │   64 pt │            64 pt
                //         1 │ 1 744 pt│         1 744 pt
                // ```
                //
                // `fixedSize` change ce qui arrive quand on **contraint** la
                // hauteur ; il ne change pas la hauteur idéale annoncée, et
                // c'est cette dernière que macOS interroge. Ce sous-titre fait
                // 50 à 80 caractères et vit hors du `ScrollView` de sa section,
                // dans les huit sections.
                //
                // **Deux bornes de lignes plutôt qu'un `TextWidthFloor`.** Le
                // plancher de largeur est le remède des bandeaux parce qu'un
                // bandeau est une phrase qu'il faut lire en entier ; ici le
                // titre tient sur un mot et le sous-titre sur deux lignes à
                // toute largeur utilisable. Et `TextWidthFloor` est un
                // `Layout` : posé dans ce `HStack` en `.firstTextBaseline`, il
                // ne publierait plus la ligne de base du grand titre, dont
                // dépend l'alignement de la pastille d'état à droite — le
                // réglage que `SnapshotStatusChip` documente.
                //
                // Mesuré sur le bloc titre + sous-titre le plus long, avec
                // `Type.paneTitle` et `Type.paneLead` :
                //
                // ```
                //   largeur │ sans bornes │ avec bornes
                //     1 080 │       50 pt │       50 pt
                //       400 │       50 pt │       50 pt
                //       320 │       65 pt │       65 pt
                //        60 │      266 pt │       65 pt
                //         1 │    1 238 pt │       65 pt
                // ```
                //
                // Rien ne change au-dessus de 320 : c'est exactement la même
                // colonne de chiffres.
                VStack(alignment: .leading, spacing: Space.tight) {
                    Text(title)
                        .font(Type.paneTitle)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(Type.paneLead)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: Space.inset)
                trailing()
            }

            if let query {
                SearchField(text: query, prompt: searchPrompt)
            }
        }
        .padding(.horizontal, Space.gutter)
        .padding(.top, Space.gutter)
        .padding(.bottom, Space.stack)
    }
}

/// Le champ de recherche.
///
/// Écrit à la main plutôt que `.searchable` : ce dernier se pose dans la barre
/// d'outils ou dans la colonne, jamais au milieu du contenu, et c'est justement
/// là qu'on le cherche du regard.
///
/// Le prix de ce choix, c'est que le clavier ne vient pas tout seul : il fallait
/// donc lui rendre à la main ⌘F pour venir s'y poser et Échap pour en repartir,
/// et un intitulé, faute de quoi VoiceOver ne lisait que le texte d'invite.
struct SearchField: View {
    @Binding var text: String
    let prompt: String

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: Space.small) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(Type.meta)
                .accessibilityHidden(true)

            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .accessibilityLabel("Rechercher")
                .accessibilityHint(prompt)
                // Échap vide le champ, **puis rend le clavier au contenu**. Le
                // commentaire d'origine promettait déjà les deux gestes ; le
                // second n'était pas écrit, si bien qu'on restait prisonnier du
                // champ de recherche et qu'il fallait la souris pour en sortir.
                // C'est exactement le geste que quelqu'un qui n'utilise pas la
                // souris attend d'Échap.
                //
                // Deux frappes, dans cet ordre : la première vide, la seconde
                // rend le focus. Tout faire d'un coup enlèverait la liste
                // filtrée sous les yeux de qui voulait seulement la garder.
                .onKeyPress(.escape) {
                    if text.isEmpty == false {
                        text = ""
                        return .handled
                    }
                    guard isFocused else { return .ignored }
                    isFocused = false
                    return .handled
                }

            if text.isEmpty == false {
                Button("Effacer", systemImage: "xmark.circle.fill") { text = "" }
                    .buttonStyle(.plain)
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
                    .help("Effacer la recherche (Échap)")
            }
        }
        .padding(.horizontal, Space.inset)
        .padding(.vertical, Space.small)
        .background {
            RoundedRectangle(cornerRadius: Radius.field, style: .continuous)
                .fill(Palette.well)
                .overlay {
                    RoundedRectangle(cornerRadius: Radius.field, style: .continuous)
                        .stroke(isFocused ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 1.5)
                }
        }
        .branAnimation(Motion.hover, value: isFocused)
        .branAnimation(Motion.hover, value: text.isEmpty)
        .onReceive(NotificationCenter.default.publisher(for: .branFocusSearch)) { _ in
            isFocused = true
        }
    }
}

extension View {
    /// Le fond d'une carte de la liste, avec son survol.
    ///
    /// Ce n'est plus qu'un renvoi vers `branCard` : le fond dessinait un contour
    /// blanc à 9 %, invisible en thème clair, et une carte n'a aucune raison
    /// d'avoir deux implémentations. Le nom survit parce que deux sections
    /// l'appellent encore.
    func cardBackground(isHovering: Bool) -> some View {
        branCard(isHovering: isHovering)
    }
}
