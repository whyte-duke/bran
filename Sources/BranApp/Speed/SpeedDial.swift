import BranCore
import SwiftUI

/// **Le cadran**, et ce qu'il montre pendant qu'on mesure.
///
/// ```
///        ·  ·  ·  ·  ·          ← la piste, en pointillé
///     ·                 ·
///   ▓▓▓▓▓▓▓                     ← l'arc, plein, jusqu'à l'aiguille
///   ·        21,5       ·
///    ·       Mo/s      ·
///        ·  ·  ·  ·
/// ```
///
/// **Pourquoi un arc ouvert et pas l'anneau de `Ring`.** `Ring` répond à
/// « combien par rapport au tout », et le cercle *est* le tout : il est fermé,
/// il a une fin, et dépasser cette fin se voit. Un débit n'a pas de tout — il
/// n'y a pas de « cent pour cent de la ligne » — d'où un cadran ouvert en bas,
/// qui est la forme qu'ont tous les compteurs de vitesse depuis un siècle, et
/// qui dit « ça peut monter » au lieu de « il en reste tant ».
///
/// **Pourquoi la piste est en pointillé.** Elle porte deux informations à la
/// fois : la graduation — on compte les points — et l'idée que la mesure est en
/// train de se faire. Un trait plein aurait fait une jauge de progression, ce
/// que ce cadran n'est pas : il ne va nulle part, il montre un débit instantané
/// qui monte et descend.
///
/// **Le mouvement perpétuel est `branLoop` et non `branAnimation`.** C'est la
/// distinction que `Design` documente : une transition qu'on raccourcit reste
/// lisible, une boucle qu'on raccourcit bat plus vite. Sous « Réduire les
/// animations », la rotation de la piste ne joue pas du tout — l'aiguille, elle,
/// continue de bouger, parce qu'elle porte la mesure et non la décoration.
struct SpeedDial: View {

    /// La position de l'aiguille, de 0 à 1. Voir `SpeedController.needle` pour
    /// la racine carrée qui l'espace.
    let needle: Double
    /// Ce qui s'écrit au centre. Déjà formaté : le cadran ne sait pas ce qu'est
    /// un mégaoctet.
    let caption: String
    let unit: String
    var tint: Color = .accentColor
    /// La piste tourne tant que la mesure court.
    var isMeasuring: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// L'ouverture, en bas. 270° de course : au-delà, l'aiguille passe derrière
    /// le chiffre ; en deçà, un demi-cercle rend les petits débits illisibles.
    private static let sweep: Double = 0.75
    private static let start: Double = 135

    var body: some View {
        ZStack {
            // La piste. Le pointillé est calculé en points de contour, donc il
            // suit le diamètre sans qu'on ait à le régler à la main.
            Circle()
                .trim(from: 0, to: Self.sweep)
                .stroke(
                    Palette.trough,
                    style: StrokeStyle(lineWidth: Metric.track, lineCap: .round, dash: [1.5, 5])
                )
                .rotationEffect(.degrees(Self.start))
                // Deux degrés de dérive : assez pour qu'on voie que ça vit, trop
                // peu pour que l'œil essaie de suivre un point en particulier.
                .rotationEffect(.degrees(isMeasuring && reduceMotion == false ? 2 : 0))
                .branLoop(Motion.breathe, value: isMeasuring)

            // L'arc mesuré.
            Circle()
                .trim(from: 0, to: Self.sweep * max(0, min(1, needle)))
                .stroke(
                    tint.gradient,
                    style: StrokeStyle(lineWidth: Metric.arc, lineCap: .round)
                )
                .rotationEffect(.degrees(Self.start))
                // `.smooth` et pas un ressort : l'aiguille est rafraîchie dix
                // fois par seconde, et un ressort n'aurait jamais le temps de se
                // stabiliser avant la valeur suivante — il ajouterait un
                // tremblement qui ne vient pas de la ligne.
                .branAnimation(Motion.state, value: needle)

            VStack(spacing: 0) {
                Text(caption)
                    .font(Type.metric)
                    .monospacedDigit()
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                Text(unit)
                    .font(Type.metaFaint)
                    .foregroundStyle(.secondary)
            }
            // **Le creux, pas le diamètre.** Sur un arc de 270°, le carré
            // inscrit fait environ 70 % du diamètre : rembourrer de l'épaisseur
            // du trait laissait « 124,0 » toucher l'arc des deux côtés — visible
            // au rendu, et c'est un chiffre qu'une fibre affiche vraiment.
            .padding(.horizontal, Metric.arc * 2 + Space.tight)
        }
        .frame(width: Metric.diameter, height: Metric.diameter)
        .accessibilityHidden(true)
    }

    enum Metric {
        /// Assez grand pour que cinq caractères — « 124,0 » — tiennent dans le
        /// creux sans se réduire, et assez petit pour laisser au panneau la place
        /// de deux lignes en dessous.
        static let diameter: CGFloat = 104
        static let track: CGFloat = 4
        static let arc: CGFloat = 7
    }
}

#Preview("Cadran") {
    HStack(spacing: Space.gutter) {
        SpeedDial(needle: 0, caption: "—", unit: "Mo/s", isMeasuring: false)
        SpeedDial(needle: 0.42, caption: "7,1", unit: "Mo/s", isMeasuring: true)
        SpeedDial(needle: 0.73, caption: "21,5", unit: "Mo/s", isMeasuring: true)
        SpeedDial(needle: 1, caption: "124,0", unit: "Mo/s", isMeasuring: false)
    }
    .padding(Space.section)
}
