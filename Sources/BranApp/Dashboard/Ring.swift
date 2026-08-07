import SwiftUI

/// **Un anneau de proportion**, avec sa valeur au centre.
///
/// ```
///    ╭───╮
///   │ 68% │   ← la part, écrite, parce qu'un arc ne se lit pas au degré près
///    ╰───╯
/// ```
///
/// **Pourquoi un anneau et pas une barre.** Une barre répond à « combien par
/// rapport aux autres » — c'est le bon outil pour comparer sept projets, et
/// c'est ce que fait `ShareRow`. Un anneau répond à « combien par rapport au
/// tout », parce que le cercle *est* le tout : il est fermé, il a une fin
/// visible, et dépasser cette fin se voit immédiatement. C'est exactement la
/// question d'une journée par rapport à son objectif.
///
/// **Et le dépassement se montre au lieu de se tronquer.** Une journée à 140 %
/// est l'information la plus intéressante de la semaine ; un anneau plafonné à
/// 100 % la ferait disparaître. Au-delà du tour complet, un second arc se
/// superpose au premier, plus clair — on voit qu'on a fait le tour, et de
/// combien.
struct Ring: View {
    /// La part, où 1 vaut le tour complet. Peut dépasser 1.
    let share: Double
    /// Ce qui s'écrit au centre. Vide pour un anneau purement décoratif — mais
    /// il n'y en a aucun dans bran, et c'est volontaire.
    var caption: String?
    var tint: Color = .accentColor
    var thickness: CGFloat = RingMetric.thickness

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var full: Double { min(share, 1) }
    private var overflow: Double { min(max(share - 1, 0), 1) }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Palette.trough, lineWidth: thickness)

            Circle()
                .trim(from: 0, to: full)
                .stroke(tint, style: StrokeStyle(lineWidth: thickness, lineCap: .round))
                .rotationEffect(.degrees(RingMetric.startAngle))

            if overflow > 0 {
                Circle()
                    .trim(from: 0, to: overflow)
                    .stroke(
                        tint.opacity(RingMetric.overflowInk),
                        style: StrokeStyle(lineWidth: thickness, lineCap: .round)
                    )
                    .rotationEffect(.degrees(RingMetric.startAngle))
            }

            if let caption {
                Text(caption)
                    .font(Type.metaFaint.monospacedDigit())
                    .foregroundStyle(.secondary)
                    // La légende ne rétrécit pas l'anneau : elle se réduit
                    // elle-même si la préférence de taille de texte la fait
                    // déborder du trou central.
                    .minimumScaleFactor(RingMetric.captionFloor)
                    .padding(thickness)
            }
        }
        // L'arc se remplit à l'arrivée des données, une fois. Ce n'est pas une
        // boucle : `branAnimation` suffit, et « Réduire les animations » le
        // raccourcit sans le supprimer — un anneau qui apparaît plein d'un coup
        // reste parfaitement lisible.
        .branAnimation(Motion.state, value: share)
        .accessibilityHidden(true)
    }
}

enum RingMetric {
    /// L'épaisseur du trait. Assez pour se voir à trente-deux points de
    /// diamètre, assez fine pour laisser un trou où écrire.
    static let thickness: CGFloat = 5
    /// L'épaisseur d'un grand anneau, celui du chiffre principal.
    static let heroThickness: CGFloat = 8
    /// Le diamètre d'un anneau de tuile, et celui du héros.
    static let diameter: CGFloat = 34
    static let heroDiameter: CGFloat = 64
    /// Midi plutôt que trois heures : un cadran commence en haut. `trim` part
    /// de la droite, d'où ce quart de tour.
    static let startAngle: Double = -90
    /// L'encre du second tour. Assez pâle pour qu'on distingue les deux, assez
    /// franche pour qu'on la voie.
    static let overflowInk: Double = 0.4
    static let captionFloor: CGFloat = 0.6
}
