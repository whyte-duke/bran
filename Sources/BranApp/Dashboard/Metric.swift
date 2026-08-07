import SwiftUI

/// **Le chiffre qu'on est venu chercher.**
///
/// ```
///  Travail aujourd'hui          ╭────╮
///  4 h 08                      │ 68% │
///  68 % d'une journée de 6 h    ╰────╯
/// ```
///
/// Un par écran. La règle est simple et elle tient tout le dessin : s'il y en a
/// deux, il n'y en a aucun — l'œil ne sait plus lequel est la réponse, et il
/// retombe à lire de haut en bas, ce qu'un tableau de bord existe pour éviter.
struct HeroMetric<Trailing: View>: View {
    let label: String
    let value: String
    var detail: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: Space.inset) {
            VStack(alignment: .leading, spacing: Space.hair) {
                Text(label)
                    .font(Type.metricLabel)
                    .foregroundStyle(.secondary)

                Text(value)
                    .font(Type.metric)
                    .monospacedDigit()
                    // Le chiffre principal ne se coupe jamais en deux lignes :
                    // « 4 h » au-dessus de « 08 » ne se lit plus comme une
                    // durée. À l'étroit, il rétrécit.
                    .lineLimit(1)
                    .minimumScaleFactor(MetricLayout.floor)

                if let detail {
                    Text(detail)
                        .font(Type.meta)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: Space.small)

            trailing
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue([value, detail].compactMap { $0 }.joined(separator: ", "))
    }
}

extension HeroMetric where Trailing == EmptyView {
    init(label: String, value: String, detail: String? = nil) {
        self.init(label: label, value: value, detail: detail) { EmptyView() }
    }
}

/// Une mesure secondaire : un libellé, un chiffre, une précision.
///
/// **Elles vont par trois ou par quatre, jamais par sept.** Une rangée de tuiles
/// est une hiérarchie plate : tout y a le même poids. Passé quatre, plus rien
/// n'a de poids du tout, et il faut une liste — c'est `ShareRow` qui prend le
/// relais, parce qu'une liste sait être longue.
struct MetricTile: View {
    let label: String
    let value: String
    var detail: String?
    var tint: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.hair) {
            Text(label)
                .font(Type.metricLabel)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Text(value)
                .font(Type.metricSmall)
                .monospacedDigit()
                .foregroundStyle(tint ?? .primary)
                .lineLimit(1)
                .minimumScaleFactor(MetricLayout.floor)

            if let detail {
                Text(detail)
                    .font(Type.metaFaint)
                    .foregroundStyle(.secondary)
                    .lineLimit(MetricLayout.detailLines)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .branWell()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue([value, detail].compactMap { $0 }.joined(separator: ", "))
    }
}

/// Une rangée de tuiles qui **se replie** au lieu de s'écraser.
///
/// `HStack` seul rétrécit ses enfants jusqu'à ce que « 1 h 24 » devienne
/// « 1 h… ». En colonne étroite — la fenêtre à moitié réduite, ou une
/// préférence de taille de texte élevée — les tuiles passent sur deux rangs.
struct MetricRow<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: Space.small) { content }
            Grid(horizontalSpacing: Space.small, verticalSpacing: Space.small) {
                content
            }
        }
    }
}

enum MetricLayout {
    /// Jusqu'où un chiffre a le droit de rétrécir avant qu'on préfère le
    /// tronquer. En dessous de 0,7 il devient plus petit que son propre
    /// libellé, ce qui inverse la hiérarchie qu'on essayait de poser.
    static let floor: CGFloat = 0.7
    static let detailLines = 2
}
