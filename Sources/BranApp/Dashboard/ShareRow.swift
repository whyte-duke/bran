import SwiftUI

/// **Le motif de ligne du tableau de bord, écrit une fois.**
///
/// ```
///  45 %  crm · feat/api   ▬▬▬▬▬▬▬▬░░░░░░░   2 h 46
///  15 %  bran · main      ▬▬▬░░░░░░░░░░░░     55 min
/// ```
///
/// Quatre colonnes, toujours dans cet ordre, et chacune répond à une question
/// différente : **quelle part** (le pourcentage, aligné à droite dans une
/// gouttière fixe, donc comparable d'une ligne à l'autre sans les lire), **de
/// quoi** (le nom), **par rapport aux autres** (la barre, qui donne le rapport
/// d'un coup d'œil là où deux nombres demandent une division), et **combien**
/// (la valeur absolue, celle qu'on cite).
///
/// **Pourquoi la barre est à droite du nom et non dessous.** La version
/// précédente empilait le nom au-dessus de sa barre, pour éviter une colonne de
/// noms de largeur fixe qui tronquerait « castral-crm-backend ». Le prix était
/// une hauteur double et, surtout, des barres qui ne commencent pas au même
/// endroit d'une ligne à l'autre : on ne peut plus les comparer, ce qui est leur
/// seule raison d'être. La gouttière fixe est la bonne réponse, et un nom trop
/// long se tronque avec son infobulle.
///
/// **Deux parts dans une seule barre**, jamais deux barres. Comparer deux
/// longueurs pour un seul projet est un travail qu'on ne devrait pas demander.
struct ShareRow: View {
    let name: String
    /// Les segments, dans l'ordre de peinture. Leur somme définit le remplissage.
    let segments: [Segment]
    /// La valeur affichée à droite.
    let value: String
    /// Le dénominateur commun à toutes les lignes du groupe : c'est **le plus
    /// long**, pas le total. Une barre pleine veut dire « c'est le plus gros
    /// d'ici », ce qui est la comparaison utile ; rapportée au total, la
    /// première barre ferait 12 % et toutes les autres seraient invisibles.
    let longest: TimeInterval
    /// La part, écrite. `nil` quand elle n'a pas de sens — une voie dont on ne
    /// connaît pas le tout.
    var share: Double?
    /// Une précision discrète après le nom : « 3 voies », « en attente ».
    var note: String?

    struct Segment: Equatable {
        let seconds: TimeInterval
        let tint: Color
        /// Ce que ce segment représente, pour VoiceOver. Une couleur ne se lit
        /// pas à voix haute.
        let label: String
    }

    private var total: TimeInterval { segments.reduce(0) { $0 + $1.seconds } }

    var body: some View {
        HStack(alignment: .center, spacing: Space.small) {
            Text(share.map { "\(($0 * 100).formatted(.number.precision(.fractionLength(0)))) %" } ?? "")
                .font(Type.meta.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: ShareMetric.shareGutter, alignment: .trailing)

            Text(name)
                .font(Type.cardBody)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(name)
                .frame(width: ShareMetric.nameGutter, alignment: .leading)

            if let note {
                Text(note)
                    .font(Type.metaFaint)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            GeometryReader { proxy in
                HStack(spacing: 0) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                        Rectangle()
                            .fill(segment.tint)
                            .frame(width: width(segment.seconds, in: proxy.size.width))
                    }
                    Spacer(minLength: 0)
                }
                .clipShape(.capsule)
                .background(Palette.trough, in: .capsule)
            }
            .frame(height: ShareMetric.barHeight)

            Text(value)
                .font(Type.meta.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: ShareMetric.valueGutter, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityValue(spoken)
    }

    private func width(_ seconds: TimeInterval, in available: CGFloat) -> CGFloat {
        guard longest > 0, seconds > 0 else { return 0 }
        // Un plancher, comme sur la timeline : un segment de deux minutes sur
        // une barre de huit heures fait moins d'un pixel et disparaîtrait.
        return max(available * CGFloat(seconds / longest), ShareMetric.minimumSegment)
    }

    /// La barre est muette. Sa version lue énumère les parts avec leur nom,
    /// parce que c'est la couleur — donc rien — qui les distingue à l'écran.
    private var spoken: String {
        var parts = [value]
        if segments.count > 1 {
            parts.append(contentsOf: segments.filter { $0.seconds > 0 }.map { segment in
                "\(WatchPane.duration(segment.seconds)) \(segment.label)"
            })
        }
        if let note { parts.append(note) }
        if total > 0, let share {
            parts.append("\((share * 100).formatted(.number.precision(.fractionLength(0)))) pour cent")
        }
        return parts.joined(separator: ", ")
    }
}

enum ShareMetric {
    /// La colonne du pourcentage. « 100 % » est le plus large qu'elle porte.
    static let shareGutter: CGFloat = 42
    /// La colonne des noms. Assez large pour « castral-crm-backend », assez
    /// étroite pour laisser à la barre la moitié de la ligne — c'est la barre
    /// qui porte la comparaison.
    static let nameGutter: CGFloat = 150
    /// La colonne des valeurs. « 12 h 40 » est le plus large.
    static let valueGutter: CGFloat = 58
    static let barHeight: CGFloat = 8
    static let minimumSegment: CGFloat = 3
}
