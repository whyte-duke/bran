import Testing
@testable import BranSpeech

@Suite("Barre de téléchargement")
struct DownloadTallyTests {

    /// La seule propriété qui compte, et celle que la version naïve viole :
    /// FluidAudio rapporte 0→1 pour chaque fichier, donc la barre reculait six
    /// fois de suite.
    @Test("La barre ne recule jamais")
    func neverGoesBackwards() {
        var tally = DownloadTally(expectedFiles: 3)
        var previous = 0.0

        for file in 0..<3 {
            for step in stride(from: 0.0, through: 1.0, by: 0.25) {
                let value = tally.advance(to: step)
                #expect(value >= previous, "recul au fichier \(file), étape \(step)")
                previous = value
            }
        }
    }

    @Test("Elle progresse vraiment d'un fichier à l'autre")
    func actuallyProgresses() {
        var tally = DownloadTally(expectedFiles: 4)
        let afterFirst = advanceOneFile(&tally)
        let afterSecond = advanceOneFile(&tally)

        #expect(afterSecond > afterFirst)
    }

    @Test("Elle n'atteint pas 100 % avant la fin annoncée")
    func staysBelowOneUntilFinished() {
        var tally = DownloadTally(expectedFiles: 2)
        _ = advanceOneFile(&tally)
        _ = advanceOneFile(&tally)

        #expect(tally.advance(to: 1) < 1)
        #expect(tally.finish() == 1)
    }

    /// Le cas qui bloquait la version précédente à 100 % pendant que le
    /// téléchargement continuait.
    @Test("Plus de fichiers que prévu : l'échelle s'étire au lieu de coincer")
    func stretchesWhenUnderestimated() {
        var tally = DownloadTally(expectedFiles: 2)
        var last = 0.0
        for _ in 0..<6 { last = advanceOneFile(&tally) }

        #expect(last < 1)
        #expect(last > 0.5)
    }

    @Test("Une fraction hors bornes ne casse rien")
    func clampsOutOfRange() {
        var tally = DownloadTally(expectedFiles: 2)
        #expect(tally.advance(to: -3) >= 0)
        #expect(tally.advance(to: 42) <= 1)
    }

    @Test("Un seul fichier se comporte normalement")
    func singleFile() {
        var tally = DownloadTally(expectedFiles: 1)
        #expect(tally.advance(to: 0.5) > 0)
        #expect(tally.finish() == 1)
    }

    private func advanceOneFile(_ tally: inout DownloadTally) -> Double {
        var value = 0.0
        for step in [0.0, 0.5, 1.0] { value = tally.advance(to: step) }
        return value
    }
}
