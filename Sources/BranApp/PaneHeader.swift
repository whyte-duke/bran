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
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 26, weight: .semibold))
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                trailing()
            }

            SearchField(text: $query, prompt: searchPrompt)
        }
        .padding(.horizontal, 26)
        .padding(.top, 22)
        .padding(.bottom, 14)
    }
}

/// Le champ de recherche.
///
/// Écrit à la main plutôt que `.searchable` : ce dernier se pose dans la barre
/// d'outils ou dans la colonne, jamais au milieu du contenu, et c'est justement
/// là qu'on le cherche du regard.
struct SearchField: View {
    @Binding var text: String
    let prompt: String

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))

            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .focused($isFocused)

            if text.isEmpty == false {
                Button("Effacer", systemImage: "xmark.circle.fill") { text = "" }
                    .buttonStyle(.plain)
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.quaternary.opacity(0.45))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(isFocused ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 1.5)
                }
        }
        .animation(.easeOut(duration: 0.15), value: isFocused)
        .animation(.easeOut(duration: 0.15), value: text.isEmpty)
    }
}

/// Le fond d'une carte de la liste, avec son survol.
///
/// Le survol n'est pas de la décoration : dans une liste de cartes sans
/// séparateur, c'est lui qui dit « cet élément est cliquable, et c'est
/// celui-là ».
struct CardBackground: ViewModifier {
    var isHovering: Bool

    func body(content: Content) -> some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.quaternary.opacity(isHovering ? 0.55 : 0.32))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(.white.opacity(isHovering ? 0.09 : 0), lineWidth: 1)
            }
            .contentShape(.rect)
            .animation(.easeOut(duration: 0.14), value: isHovering)
    }
}

extension View {
    func cardBackground(isHovering: Bool) -> some View {
        modifier(CardBackground(isHovering: isHovering))
    }
}
