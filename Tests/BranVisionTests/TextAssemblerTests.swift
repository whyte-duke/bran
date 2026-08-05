import Testing
@testable import BranVision

/// Les régions sont écrites à la main, en coordonnées normalisées, comme Vision
/// les rend : origine en bas à gauche, `y` qui monte.
///
/// Écrire les cas à la main plutôt que de rejouer une capture est délibéré :
/// un test qui dépend d'une image dépend aussi du moteur, de la version de
/// macOS et de la police. Celui-ci teste l'assemblage, et rien d'autre.
@Suite("Assemblage des lignes")
struct TextAssemblerTests {

    /// Fabrique une région d'une hauteur standard sur la ligne `line`
    /// (0 = en haut), à la colonne `column`, en chasse fixe.
    private func region(
        _ text: String,
        line: Int,
        column: Int,
        charWidth: Double = 0.01,
        lineHeight: Double = 0.05
    ) -> TextRegion {
        TextRegion(
            x: Double(column) * charWidth,
            // `y` descend quand `line` monte : Vision compte depuis le bas.
            y: 1 - Double(line + 1) * lineHeight,
            width: Double(text.count) * charWidth,
            height: lineHeight * 0.7,
            text: text
        )
    }

    // MARK: - Le cas qui motive tout le reste

    @Test("Les colonnes d'un ls -la se recollent en lignes")
    func recollePlusieursColonnes() {
        // Vision rend chaque colonne séparément. Empilées verticalement, elles
        // produiraient un texte qui n'a jamais existé à l'écran. Mesuré sur une
        // vraie capture : 34,6 % d'erreur sans regroupement, 3,7 % avec.
        let regions = [
            region("drwxr-xr-x", line: 0, column: 0),
            region("10", line: 0, column: 12),
            region("whyteduke", line: 0, column: 16),
            region(".", line: 0, column: 28),
            region("-rw-r--r--", line: 1, column: 0),
            region("1", line: 1, column: 13),
            region("whyteduke", line: 1, column: 16),
            region("DictationMachine.swift", line: 1, column: 28),
        ]

        let out = TextAssembler.assemble(regions.shuffled(), layout: .monospaced)
        let lines = out.split(separator: "\n", omittingEmptySubsequences: false)

        #expect(lines.count == 2)
        #expect(lines[0].contains("drwxr-xr-x"))
        #expect(lines[0].contains("whyteduke"))
        #expect(lines[0].hasSuffix("."))
        #expect(lines[1].contains("DictationMachine.swift"))
        // Les colonnes restent alignées d'une ligne à l'autre.
        let a = lines[0].range(of: "whyteduke")!
        let b = lines[1].range(of: "whyteduke")!
        #expect(lines[0].distance(from: lines[0].startIndex, to: a.lowerBound)
            == lines[1].distance(from: lines[1].startIndex, to: b.lowerBound))
    }

    @Test("L'indentation du code est reconstruite depuis la géométrie")
    func reconstruitIndentation() {
        let regions = [
            region("public struct DictationMachine: Sendable {", line: 0, column: 0),
            region("public enum Phase: Equatable, Sendable {", line: 1, column: 4),
            region("case idle", line: 2, column: 8),
            region("case capturing", line: 3, column: 8),
            region("}", line: 4, column: 4),
        ]

        let lines = TextAssembler.assemble(regions, layout: .monospaced)
            .split(separator: "\n", omittingEmptySubsequences: false)

        #expect(lines[0].hasPrefix("public struct"))
        #expect(lines[1].hasPrefix("    public enum"))
        #expect(lines[2].hasPrefix("        case idle"))
        #expect(lines[3].hasPrefix("        case capturing"))
        #expect(lines[4].hasPrefix("    }"))
    }

    // MARK: - Prose

    @Test("En prose, les écarts horizontaux ne deviennent pas des espaces")
    func proseIgnoreLesEcarts() {
        // Un texte justifié a des écarts entre mots qui ne veulent rien dire.
        // Les transformer en espaces produirait un texte troué.
        let regions = [
            region("Bonjour,", line: 0, column: 0),
            region("je vous appelle", line: 0, column: 30),
        ]

        #expect(TextAssembler.assemble(regions, layout: .prose)
            == "Bonjour, je vous appelle")
    }

    @Test("En prose, les lignes restent séparées")
    func proseGardeLesLignes() {
        let regions = [
            region("première ligne", line: 0, column: 0),
            region("seconde ligne", line: 1, column: 0),
        ]
        #expect(TextAssembler.assemble(regions, layout: .prose)
            == "première ligne\nseconde ligne")
    }

    // MARK: - Regroupement vertical

    @Test("Deux morceaux au même niveau restent sur la même ligne malgré un jambage")
    func jambageNeCassePasLaLigne() {
        // « apparu » descend sous la ligne de base, « TOTAL » non. Comparer les
        // `y` bruts les séparerait ; comparer les centres les garde ensemble.
        let haut = TextRegion(x: 0, y: 0.500, width: 0.06, height: 0.035, text: "TOTAL")
        let bas = TextRegion(x: 0.10, y: 0.492, width: 0.06, height: 0.043, text: "apparu")

        let rows = TextAssembler.group([haut, bas])
        #expect(rows.count == 1)
    }

    @Test("Deux lignes distinctes ne fusionnent pas")
    func lignesDistinctesRestentSeparees() {
        let regions = [
            region("ligne du haut", line: 0, column: 0),
            region("ligne du bas", line: 1, column: 0),
        ]
        #expect(TextAssembler.group(regions).count == 2)
    }

    @Test("Un titre deux fois plus grand ne fausse pas la tolérance")
    func medianeResisteAuTitre() {
        // Avec une moyenne, un seul titre géant élargirait la tolérance au point
        // de fusionner les lignes du corps. La médiane l'ignore.
        var regions = [TextRegion(x: 0, y: 0.9, width: 0.4, height: 0.09, text: "TITRE")]
        for line in 2..<8 {
            regions.append(region("corps \(line)", line: line, column: 0))
        }
        // Une ligne par région : rien ne doit fusionner.
        #expect(TextAssembler.group(regions).count == regions.count)
    }

    // MARK: - Cas limites

    @Test("Aucune région donne une chaîne vide")
    func aucuneRegion() {
        #expect(TextAssembler.assemble([], layout: .monospaced).isEmpty)
        #expect(TextAssembler.assemble([], layout: .prose).isEmpty)
    }

    @Test("Les régions vides ou en blanc sont écartées")
    func regionsVides() {
        let regions = [
            region("réel", line: 0, column: 0),
            TextRegion(x: 0.5, y: 0.95, width: 0.02, height: 0.035, text: "   "),
            TextRegion(x: 0.6, y: 0.95, width: 0.02, height: 0.035, text: ""),
        ]
        #expect(TextAssembler.assemble(regions, layout: .monospaced) == "réel")
    }

    @Test("Une région de hauteur nulle ne provoque pas de division par zéro")
    func hauteurNulle() {
        let regions = [
            TextRegion(x: 0, y: 0.5, width: 0.1, height: 0, text: "dégénérée"),
            region("valide", line: 0, column: 0),
        ]
        #expect(TextAssembler.assemble(regions, layout: .monospaced) == "valide")
    }

    @Test("Des régions qui se chevauchent ne produisent pas d'espaces négatifs")
    func chevauchement() {
        let a = TextRegion(x: 0.10, y: 0.5, width: 0.10, height: 0.03, text: "avant")
        // Commence avant la fin de la précédente.
        let b = TextRegion(x: 0.15, y: 0.5, width: 0.10, height: 0.03, text: "après")
        let out = TextAssembler.assemble([a, b], layout: .monospaced)
        #expect(out == "avantaprès")
        #expect(out.contains("  ") == false)
    }

    @Test("Le seuil de confiance écarte les régions douteuses")
    func seuilDeConfiance() {
        let sure = TextRegion(x: 0, y: 0.5, width: 0.1, height: 0.03, text: "sûr", confidence: 0.9)
        let doubtful = TextRegion(x: 0.2, y: 0.5, width: 0.1, height: 0.03, text: "douteux", confidence: 0.2)

        #expect(TextAssembler.assemble([sure, doubtful], layout: .prose, minimumConfidence: 0.5) == "sûr")
        // Par défaut on ne jette rien : perdre du texte est pire qu'un mot douteux.
        #expect(TextAssembler.assemble([sure, doubtful], layout: .prose).contains("douteux"))
    }

    @Test("L'ordre d'entrée n'a aucune influence")
    func ordreSansInfluence() {
        let regions = [
            region("un", line: 0, column: 0),
            region("deux", line: 0, column: 5),
            region("trois", line: 1, column: 0),
            region("quatre", line: 2, column: 2),
        ]
        let reference = TextAssembler.assemble(regions, layout: .monospaced)
        for _ in 0..<20 {
            #expect(TextAssembler.assemble(regions.shuffled(), layout: .monospaced) == reference)
        }
    }

    @Test("L'indentation est comptée depuis la marge, pas depuis le bord de l'image")
    func margeEtPasBordDImage() {
        // Une capture cadrée serrée sur un bloc déjà indenté ne doit pas hériter
        // de huit espaces parasites sur toutes ses lignes.
        let regions = [
            region("case idle", line: 0, column: 8),
            region("case capturing", line: 1, column: 8),
            region("}", line: 2, column: 4),
        ]
        let lines = TextAssembler.assemble(regions, layout: .monospaced)
            .split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines[0] == "    case idle")
        #expect(lines[1] == "    case capturing")
        #expect(lines[2] == "}")
    }
}
