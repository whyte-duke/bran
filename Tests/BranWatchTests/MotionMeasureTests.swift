import Foundation
import Testing
@testable import BranWatch

/// **Le verdict de tout le produit tient dans ce ratio.**
///
/// Quand aucun capteur certain ne parle — un onglet `claude.ai`, une application
/// de bureau, un terminal sans transcription — « travaille » et « vous attend »
/// n'ont pas d'autre source que la part de blocs qui ont bougé. Une erreur
/// d'indice d'un pixel ne planterait rien : elle fausserait une journée entière
/// de mesure en affichant des états parfaitement plausibles.
///
/// Les images sont fabriquées en mémoire, bloc par bloc, avec des valeurs
/// choisies — donc chaque moyenne attendue est connue à l'avance.
@Suite("Mesure du mouvement")
struct MotionMeasureTests {

    private let size = 16

    /// Une trame de `colonnes × lignes` blocs, chaque bloc rempli d'une valeur
    /// uniforme. `values[n]` remplit le bloc `n`, parcouru en lignes.
    private func frame(columns: Int, rows: Int, values: [UInt8]) -> [UInt8] {
        let width = columns * size
        let height = rows * size
        var pixels = [UInt8](repeating: 0, count: width * height)

        for y in 0 ..< height {
            for x in 0 ..< width {
                let block = (y / size) * columns + (x / size)
                pixels[y * width + x] = values[block]
            }
        }
        return pixels
    }

    private func means(columns: Int, rows: Int, _ values: [UInt8]) -> [Double] {
        MotionMeasure.blockMeans(
            frame(columns: columns, rows: rows, values: values),
            width: columns * size,
            height: rows * size,
            size: size
        )
    }

    // MARK: - Les trois cas du plan

    @Test("Une image immobile ne bouge pas du tout")
    func imageImmobile() {
        let before = means(columns: 4, rows: 2, Array(repeating: 40, count: 8))
        #expect(before.count == 8)
        #expect(MotionMeasure.movementRatio(before, before, delta: 0.02) == 0)
    }

    @Test("La moitié des blocs inversés donne exactement 0,5")
    func moitieDesBlocs() {
        let before = means(columns: 4, rows: 2, Array(repeating: 0, count: 8))
        // Quatre blocs sur huit passent du noir au blanc.
        let after = means(columns: 4, rows: 2, [255, 255, 255, 255, 0, 0, 0, 0])

        #expect(MotionMeasure.movementRatio(before, after, delta: 0.02) == 0.5)
    }

    @Test("Un seul bloc modifié donne 1/n")
    func unSeulBloc() {
        var values = [UInt8](repeating: 0, count: 8)
        let before = means(columns: 4, rows: 2, values)
        values[5] = 255
        let after = means(columns: 4, rows: 2, values)

        #expect(MotionMeasure.movementRatio(before, after, delta: 0.02) == 1.0 / 8.0)
    }

    // MARK: - L'indexation, là où se cache l'erreur d'un pixel

    /// Le test qui vaut tous les autres : un seul bloc allumé, à une position
    /// connue, doit ressortir **à l'indice attendu**. Une transposition
    /// lignes/colonnes ou un décalage de un passerait inaperçue partout ailleurs.
    @Test("Le bloc (colonne 2, ligne 1) sort à l'indice 6")
    func indexationDesBlocs() {
        var values = [UInt8](repeating: 0, count: 8)
        values[1 * 4 + 2] = 255

        let result = means(columns: 4, rows: 2, values)

        #expect(result.count == 8)
        #expect(result[6] == 1)
        #expect(result.enumerated().filter { $0.element > 0 }.map(\.offset) == [6])
    }

    @Test("Les moyennes sont ramenées sur 0…1")
    func moyennesNormalisees() {
        let result = means(columns: 2, rows: 1, [0, 255])
        #expect(result == [0, 1])
    }

    @Test("Un bloc à moitié noir, à moitié blanc, tombe au milieu")
    func moyenneInterne() {
        let width = size
        let height = size
        var pixels = [UInt8](repeating: 0, count: width * height)
        for y in 0 ..< (size / 2) {
            for x in 0 ..< width { pixels[y * width + x] = 255 }
        }

        let result = MotionMeasure.blockMeans(pixels, width: width, height: height, size: size)
        #expect(result.count == 1)
        #expect(abs(result[0] - 0.5) < 0.0001)
    }

    // MARK: - Les bords

    /// La vignette fait 320 px de large mais sa hauteur suit le rapport de la
    /// fenêtre : elle n'est presque jamais un multiple de 16. Les pixels qui
    /// dépassent sont ignorés — un bloc partiel aurait une moyenne calculée sur
    /// moins de pixels, donc plus bruyante que ses voisins, et il déclencherait
    /// tout seul.
    @Test("Les pixels qui ne remplissent pas un bloc entier sont ignorés")
    func blocsPartielsIgnores() {
        let result = MotionMeasure.blockMeans(
            [UInt8](repeating: 200, count: 70 * 40),
            width: 70, height: 40, size: size
        )
        #expect(result.count == 4 * 2)
    }

    @Test("Une trame plus petite qu'annoncée ne fait rien tomber")
    func tamponTropCourt() {
        #expect(MotionMeasure.blockMeans([1, 2, 3], width: 320, height: 200, size: size).isEmpty)
    }

    @Test("Une image plus petite qu'un bloc ne rend rien")
    func imageMinuscule() {
        #expect(MotionMeasure.blockMeans([UInt8](repeating: 0, count: 25), width: 5, height: 5, size: size).isEmpty)
        #expect(MotionMeasure.blockMeans([], width: 0, height: 0, size: size).isEmpty)
        #expect(MotionMeasure.blockMeans([1], width: 1, height: 1, size: 0).isEmpty)
    }

    // MARK: - Le seuil

    /// Écrit avec des valeurs exactes en binaire — 0,5 et 0,25 — et non avec le
    /// δ réel de 0,02 : `0.52 - 0.5` vaut `0.020000000000000018` en `Double`, et
    /// le test « égal au seuil » passerait ou échouerait selon la valeur choisie
    /// plutôt que selon le code.
    @Test("δ est un seuil strict : un écart égal à δ ne compte pas")
    func seuilStrict() {
        #expect(MotionMeasure.movementRatio([0.5], [0.75], delta: 0.25) == 0)
        #expect(MotionMeasure.movementRatio([0.5], [0.8], delta: 0.25) == 1)
    }

    @Test("Le seuil est symétrique : s'assombrir bouge autant que s'éclaircir")
    func seuilSymetrique() {
        #expect(MotionMeasure.movementRatio([0.5], [0.9], delta: 0.02) == 1)
        #expect(MotionMeasure.movementRatio([0.9], [0.5], delta: 0.02) == 1)
    }

    /// Le cas de la fenêtre redimensionnée. Rendre autre chose que 0 conclurait
    /// au mouvement sur une comparaison qui n'a pas de sens.
    @Test("Deux relevés de tailles différentes ne concluent à rien")
    func taillesDifferentes() {
        #expect(MotionMeasure.movementRatio([0, 0, 0], [1, 1], delta: 0.02) == 0)
        #expect(MotionMeasure.movementRatio([], [], delta: 0.02) == 0)
    }

    // MARK: - Richesse

    @Test("Une capture uniforme est pauvre, une capture contrastée est riche")
    func richesse() {
        #expect(MotionMeasure.standardDeviation([0.4, 0.4, 0.4, 0.4]) == 0)
        #expect(MotionMeasure.standardDeviation([0.5]) == 0)
        #expect(MotionMeasure.standardDeviation([]) == 0)
        // Le seuil d'occultation de la sonde est 0,02 : une image mi-noire
        // mi-blanche doit le dépasser très largement.
        #expect(MotionMeasure.standardDeviation([0, 1, 0, 1]) > 0.02)
    }

    @Test("L'écart-type d'un couple connu vaut ce qu'il doit valoir")
    func ecartTypeConnu() {
        // Moyenne 0,5 ; écart 0,5 de part et d'autre.
        #expect(abs(MotionMeasure.standardDeviation([0, 1]) - 0.5) < 1e-12)
    }
}
