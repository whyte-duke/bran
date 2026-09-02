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
///
/// **Le repli était annoncé et n'existait pas.** Le corps était un
/// `ViewThatFits` entre `HStack { content }` et `Grid { content }`, où `content`
/// est toujours un unique `GridRow` : les deux candidats portaient donc
/// exactement le même nombre de colonnes. Mesuré le 02/09/2026 en recompilant
/// `Design.swift` et ce fichier avec le vrai moteur de disposition, sur les
/// quatre tuiles de la section « Débit » :
///
/// ```
///   largeur │ HStack(GridRow) │ Grid(GridRow) │ ViewThatFits
///      1 200│      1 200 × 75 │    1 200 × 75 │   1 200 × 75
///        320│        320 × 88 │      320 × 88 │     320 × 88
///          1│          1 × 81 │        1 × 81 │       1 × 81
/// ```
///
/// Les deux candidats rendent la **même** hauteur à toutes les largeurs : le
/// second n'a donc jamais été choisi, et à 320 points les quatre tuiles
/// restaient sur une rangée de 80 points de large chacune, où « 21,5 » finit de
/// rétrécir à `MetricLayout.floor` et où la précision se rogne.
///
/// Un `ViewThatFits` ne pouvait pas être réparé sur place : ses candidats
/// reçoivent le contenu déjà emballé dans un `GridRow`, et une vue ne sait pas
/// le découper. Un `Layout`, si — ses `Subviews` sont les tuiles elles-mêmes,
/// `GridRow` étant transparent hors d'un `Grid` (mesuré : un `VStack` qui en
/// contient un empile bien ses enfants). D'où `MetricFlow`, qui compte les
/// colonnes au lieu de choisir entre deux dispositions figées.
struct MetricRow<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        MetricFlow(spacing: Space.small) { content }
    }
}

/// La disposition qui replie une rangée de tuiles, colonne par colonne.
///
/// Toutes les colonnes ont la même largeur — c'est ce qui alignait déjà les
/// tuiles dans le `HStack` précédent, et le perdre ferait onduler les libellés
/// d'une rangée à l'autre. L'ordre de placement est celui de la déclaration,
/// ligne par ligne : **l'ordre de lecture de VoiceOver ne change donc pas**
/// quand le nombre de colonnes change, ce qui était le seul risque de
/// régression du repli.
struct MetricFlow: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.isEmpty == false else { return .zero }
        let columns = columnCount(for: proposal.width, subviews)
        // Largeur non proposée (ou infinie, ce que `ViewThatFits` et les barres
        // d'outils envoient) : on rend la rangée entière, c'est-à-dire la taille
        // idéale au sens habituel.
        let width = usableWidth(proposal.width) ?? idealWidth(of: subviews, columns: columns)
        return CGSize(width: width, height: height(of: subviews, columns: columns, in: width))
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        guard subviews.isEmpty == false else { return }
        let columns = columnCount(for: bounds.width, subviews)
        let column = columnWidth(bounds.width, columns: columns)
        var y = bounds.minY
        var index = 0
        while index < subviews.count {
            let end = min(index + columns, subviews.count)
            let line = rowHeight(subviews, index..<end, column: column)
            for position in index..<end {
                subviews[position].place(
                    at: CGPoint(
                        x: bounds.minX + CGFloat(position - index) * (column + spacing),
                        y: y
                    ),
                    proposal: ProposedViewSize(width: column, height: line)
                )
            }
            y += line + spacing
            index = end
        }
    }

    // MARK: - Le compte des colonnes

    /// Combien de tuiles tiennent côte à côte dans la largeur proposée.
    ///
    /// La largeur exigée par une colonne est la plus large des tuiles idéales,
    /// **plafonnée** par `MetricLayout.columnCap`. Sans ce plafond, une seule
    /// précision bavarde décide pour toute la rangée : « Écart entre ces
    /// allers-retours » demande 157 points sur une ligne, ce qui ferait tomber
    /// les quatre tuiles de « Débit » à une colonne dès 320 points — alors que
    /// `MetricTile` accepte déjà deux lignes de précision et que la même tuile
    /// se lit très bien à 156.
    private func columnCount(for width: CGFloat?, _ subviews: Subviews) -> Int {
        let count = subviews.count
        guard count > 1 else { return max(count, 1) }
        guard let width = usableWidth(width), width > 0 else { return count }
        let needed = min(widest(of: subviews), MetricLayout.columnCap)
        guard needed > 0 else { return count }
        let fitting = Int(((width + spacing) / (needed + spacing)).rounded(.down))
        return max(1, min(count, fitting))
    }

    /// `nil` quand la largeur ne contraint rien : non proposée, ou infinie —
    /// auquel cas `Int(_:)` sur le quotient planterait.
    private func usableWidth(_ width: CGFloat?) -> CGFloat? {
        guard let width, width.isFinite else { return nil }
        return width
    }

    private func widest(of subviews: Subviews) -> CGFloat {
        subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
    }

    private func idealWidth(of subviews: Subviews, columns: Int) -> CGFloat {
        widest(of: subviews) * CGFloat(columns) + spacing * CGFloat(columns - 1)
    }

    private func columnWidth(_ width: CGFloat, columns: Int) -> CGFloat {
        max(0, (width - spacing * CGFloat(columns - 1)) / CGFloat(columns))
    }

    private func height(of subviews: Subviews, columns: Int, in width: CGFloat) -> CGFloat {
        let column = columnWidth(width, columns: columns)
        var total: CGFloat = 0
        var index = 0
        while index < subviews.count {
            let end = min(index + columns, subviews.count)
            total += rowHeight(subviews, index..<end, column: column)
            if end < subviews.count { total += spacing }
            index = end
        }
        return total
    }

    private func rowHeight(_ subviews: Subviews, _ range: Range<Int>, column: CGFloat) -> CGFloat {
        range.reduce(0) { highest, index in
            max(highest, subviews[index].sizeThatFits(ProposedViewSize(width: column, height: nil)).height)
        }
    }
}

enum MetricLayout {
    /// Jusqu'où un chiffre a le droit de rétrécir avant qu'on préfère le
    /// tronquer. En dessous de 0,7 il devient plus petit que son propre
    /// libellé, ce qui inverse la hiérarchie qu'on essayait de poser.
    static let floor: CGFloat = 0.7
    static let detailLines = 2

    /// Ce qu'une colonne de tuiles a le droit d'exiger, au plus.
    ///
    /// **Mesuré, pas choisi.** Les tuiles de l'application demandent 75 points
    /// en largeur idéale quand leur précision est courte (« 172 Mbit/s »,
    /// « 3 pauses ») et 157 quand elle ne l'est pas (« Écart entre ces
    /// allers-retours »). Prendre l'exigence telle quelle laisserait la plus
    /// bavarde décider du repli de toutes les autres. À 140, les quatre tuiles
    /// de « Débit » passent à deux colonnes de 156 points à 320 de large, à
    /// trois à 480, et reviennent sur une rangée dès 600 — la précision longue
    /// s'y écrit sur les deux lignes que `detailLines` lui accorde déjà.
    static let columnCap: CGFloat = 140
}
