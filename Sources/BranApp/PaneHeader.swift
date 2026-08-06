import Combine
import SwiftUI

/// L'en-tête d'une section : grand titre, sous-titre, et une barre d'outils.
///
/// Toujours la même forme d'une section à l'autre — c'est ce qui fait qu'on sait
/// où regarder avant même d'avoir lu.
struct PaneHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    @Binding var query: String
    var searchPrompt: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        VStack(alignment: .leading, spacing: Space.stack) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: Space.tight) {
                    Text(title)
                        .font(Type.paneTitle)
                    Text(subtitle)
                        .font(Type.paneLead)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: Space.inset)
                trailing()
            }

            SearchField(text: $query, prompt: searchPrompt)
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
                // Échap vide le champ, puis rend le clavier au contenu. Deux
                // gestes en un, dans l'ordre où on les veut : une recherche
                // qu'on abandonne laisse une liste filtrée, sinon.
                .onKeyPress(.escape) {
                    guard text.isEmpty == false else { return .ignored }
                    text = ""
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
