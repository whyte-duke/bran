import Foundation

/// **L'arithmétique du capteur de pixels**, séparée de la capture.
///
/// ```
///   vignette grise ──▶ blocs 16×16 ──▶ moyenne par bloc
///                                            │
///                      tic précédent ────────┤
///                                            ▼
///                              ratio = part des blocs qui ont
///                                      bougé de plus de δ
/// ```
///
/// **Pourquoi ces trois fonctions vivent ici et pas à côté de la capture.**
/// C'est ce ratio qui porte le verdict de tout le produit : « travaille » et
/// « vous attend » n'ont pas d'autre source quand aucun capteur certain ne
/// parle. Une erreur d'un pixel dans l'indexation des blocs fausserait une
/// journée entière de mesure, silencieusement — le veilleur continuerait
/// d'afficher des états parfaitement plausibles. Tant que le calcul était
/// enfermé dans un `actor` qui appelle ScreenCaptureKit, rien ne pouvait le
/// vérifier. Ici, il se teste sur des tableaux d'octets fabriqués à la main.
public enum MotionMeasure {

    /// La moyenne de luminance de chaque bloc, ramenée sur 0…1.
    ///
    /// Les blocs sont parcourus en lignes, de haut en bas : l'indice `n` du
    /// résultat correspond au bloc `(n % colonnes, n / colonnes)`. Les pixels
    /// restants à droite et en bas, quand la largeur n'est pas un multiple de
    /// `size`, sont ignorés — un bloc partiel aurait une moyenne calculée sur
    /// moins de pixels, donc plus bruyante que ses voisins.
    public static func blockMeans(
        _ pixels: [UInt8],
        width: Int,
        height: Int,
        size: Int
    ) -> [Double] {
        guard size > 0, width > 0, height > 0 else { return [] }
        let columns = width / size
        let rows = height / size
        guard columns > 0, rows > 0 else { return [] }
        // Un tampon plus court que la trame annoncée sortirait du tableau. Le
        // contexte Core Graphics n'en produit jamais, mais cette fonction est
        // publique : mieux vaut ne rien mesurer que faire tomber le veilleur.
        guard pixels.count >= width * height else { return [] }

        var means: [Double] = []
        means.reserveCapacity(columns * rows)

        for blockY in 0 ..< rows {
            for blockX in 0 ..< columns {
                var total = 0
                for y in 0 ..< size {
                    let rowStart = (blockY * size + y) * width + blockX * size
                    for x in 0 ..< size { total += Int(pixels[rowStart + x]) }
                }
                means.append(Double(total) / Double(size * size) / 255)
            }
        }
        return means
    }

    /// La part des blocs qui ont bougé de plus de `delta`.
    ///
    /// Rend 0 — et non `nil` — quand les deux relevés n'ont pas la même taille :
    /// la fenêtre a été redimensionnée, il n'y a rien à comparer. L'appelant
    /// remplace alors ses moyennes sans conclure au mouvement, ce qui est le
    /// choix prudent : une fenêtre qu'on redimensionne est déjà touchée par un
    /// humain, le capteur de présence s'en occupe.
    public static func movementRatio(
        _ before: [Double],
        _ after: [Double],
        delta: Double
    ) -> Double {
        guard before.count == after.count, before.isEmpty == false else { return 0 }
        var moved = 0
        for index in before.indices where abs(before[index] - after[index]) > delta { moved += 1 }
        return Double(moved) / Double(before.count)
    }

    /// L'écart-type des moyennes de blocs — la « richesse » d'une capture.
    ///
    /// Sert au diagnostic d'occultation : une capture ratée ou vide est
    /// uniforme, donc proche de zéro. Une capture réelle ne l'est jamais.
    public static func standardDeviation(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        return variance.squareRoot()
    }
}
