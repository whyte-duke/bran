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

    /// Le diamètre du cadran.
    ///
    /// **Deux tailles existent, et elles ne font pas le même métier.** Celle par
    /// défaut est celle du panneau flottant : un afficheur d'état, posé dans un
    /// coin, qu'on regarde du coin de l'œil pendant qu'on fait autre chose.
    /// `Metric.heroDiameter` est celle de la section « Débit », où le cadran
    /// **est** ce qu'on est venu voir — et où un cadran de la taille d'une pièce
    /// de monnaie au milieu d'une fenêtre de mille points aurait l'air d'un
    /// oubli.
    ///
    /// Le trait suit le diamètre au lieu d'être réglé à la main : un arc de sept
    /// points sur un cadran de deux cents ressemble à un fil, et c'est ce qui
    /// arrive quand on agrandit une figure sans agrandir son encre.
    var diameter: CGFloat = Metric.diameter

    /// Le chiffre du centre, et son unité. Ils ne suivent pas le diamètre —
    /// voir `Type.dial` pour ce que « proportionnel » donnerait sur un texte.
    var captionFont: Font = Type.metric
    var unitFont: Font = Type.metaFaint

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
                    style: StrokeStyle(lineWidth: track, lineCap: .round, dash: [1.5 * scale, 5 * scale])
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
                    style: StrokeStyle(lineWidth: arc, lineCap: .round)
                )
                .rotationEffect(.degrees(Self.start))
                // `.smooth` et pas un ressort : l'aiguille est rafraîchie dix
                // fois par seconde, et un ressort n'aurait jamais le temps de se
                // stabiliser avant la valeur suivante — il ajouterait un
                // tremblement qui ne vient pas de la ligne.
                .branAnimation(Motion.state, value: needle)

            VStack(spacing: 0) {
                Text(caption)
                    .font(captionFont)
                    .monospacedDigit()
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                Text(unit)
                    .font(unitFont)
                    .foregroundStyle(.secondary)
            }
            // **Le creux, pas le diamètre.** Sur un arc de 270°, le carré
            // inscrit fait environ 70 % du diamètre : rembourrer de l'épaisseur
            // du trait laissait « 124,0 » toucher l'arc des deux côtés — visible
            // au rendu, et c'est un chiffre qu'une fibre affiche vraiment.
            .padding(.horizontal, arc * 2 + Space.tight)
        }
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
    }

    /// Tout ce qui est dessiné suit le diamètre, dans le rapport où la petite
    /// taille a été réglée. Rien à re-régler quand une troisième taille
    /// apparaîtra.
    private var scale: CGFloat { diameter / Metric.diameter }
    private var track: CGFloat { Metric.track * scale }
    private var arc: CGFloat { Metric.arc * scale }

    enum Metric {
        /// Assez grand pour que cinq caractères — « 124,0 » — tiennent dans le
        /// creux sans se réduire, et assez petit pour laisser au panneau la place
        /// de deux lignes en dessous.
        static let diameter: CGFloat = 104
        static let track: CGFloat = 4
        static let arc: CGFloat = 7

        /// Le cadran de la section « Débit ».
        ///
        /// 216 points : c'est la taille à partir de laquelle le chiffre du
        /// centre se lit depuis l'autre bout du bureau, c'est-à-dire depuis là
        /// où on est vraiment pendant les neuf secondes que dure le test — on
        /// lance la mesure et on regarde ailleurs. Un compteur qu'il faut venir
        /// lire de près n'a aucune raison d'être un compteur.
        static let heroDiameter: CGFloat = 216
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
