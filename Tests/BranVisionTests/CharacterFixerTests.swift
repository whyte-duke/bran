import Testing
@testable import BranVision

@Suite("Substitutions typographiques")
struct CharacterFixerTests {

    @Test("La puce redevient un point — l'erreur mesurée sur du Swift réel")
    func puceVersPoint() {
        // Observé mot pour mot sur une capture de DictationMachine.swift.
        // Cette seule confusion représentait 70 % des erreurs restantes.
        let lu = "case •idle, •failed: false"
        #expect(CharacterFixer.fix(lu, layout: .monospaced) == "case .idle, .failed: false")
    }

    @Test("Les guillemets typographiques redeviennent droits")
    func guillemets() {
        let lu = "print(“bonjour”)"
        #expect(CharacterFixer.fix(lu, layout: .monospaced) == "print(\"bonjour\")")
    }

    @Test("Le tiret cadratin redevient un double tiret d'option")
    func tiretCadratin() {
        #expect(CharacterFixer.fix("git log —oneline", layout: .monospaced)
            == "git log --oneline")
    }

    @Test("L'espace insécable redevient un espace")
    func espaceInsecable() {
        let lu = "swift\u{00A0}build"
        #expect(CharacterFixer.fix(lu, layout: .monospaced) == "swift build")
    }

    // MARK: - Le verrou qui compte

    @Test("En prose, rien n'est touché")
    func proseIntacte() {
        // Corriger ici abîmerait un texte correct : l'apostrophe typographique
        // et le tiret cadratin sont la bonne orthographe française.
        let texte = "L’échéance — fixée au 14 février — approche…"
        #expect(CharacterFixer.fix(texte, layout: .prose) == texte)
        #expect(CharacterFixer.repairCount(texte, layout: .prose) == 0)
    }

    @Test("Un texte sans caractère à réparer est rendu tel quel")
    func texteSain() {
        let texte = "let x = compute(a, b) // rien à faire"
        #expect(CharacterFixer.fix(texte, layout: .monospaced) == texte)
        #expect(CharacterFixer.repairCount(texte, layout: .monospaced) == 0)
    }

    @Test("Le compteur de réparations reflète ce qui a été changé")
    func compteur() {
        let lu = "case •idle, •failed: “x”"
        #expect(CharacterFixer.repairCount(lu, layout: .monospaced) == 4)
    }

    @Test("Une chaîne vide ne pose pas de problème")
    func chaineVide() {
        #expect(CharacterFixer.fix("", layout: .monospaced).isEmpty)
        #expect(CharacterFixer.repairCount("", layout: .monospaced) == 0)
    }

    // MARK: - Ce qu'on refuse délibérément de corriger

    @Test("Les confusions de glyphes ne sont PAS corrigées")
    func glyphesNonCorriges() {
        // `1s` est un nom de fichier valide et `wc -1` une option plausible.
        // Une correction qui se trompe produit du texte faux mais crédible,
        // qu'on collerait sans le voir. On préfère l'erreur visible.
        let lu = "$ 1s -la | wc -1"
        #expect(CharacterFixer.fix(lu, layout: .monospaced) == lu)
    }

    @Test("Chaque règle a une raison écrite")
    func chaqueRegleEstJustifiee() {
        // Le critère d'admission d'une règle : le caractère de gauche n'a aucune
        // raison d'exister dans du code. Sans justification, pas de règle.
        for rule in CharacterFixer.rules {
            #expect(rule.why.isEmpty == false, "règle sans raison : \(rule.wrong)")
            #expect(rule.right.isEmpty == false)
        }
    }

    @Test("Aucune règle ne se contredit")
    func reglesCoherentes() {
        let sources = CharacterFixer.rules.map(\.wrong)
        #expect(Set(sources).count == sources.count)
        // Et aucune règle ne produit un caractère qu'une autre règle réparerait,
        // ce qui rendrait le résultat dépendant de l'ordre d'application.
        for rule in CharacterFixer.rules {
            #expect(rule.right.contains(where: { sources.contains($0) }) == false)
        }
    }
}
