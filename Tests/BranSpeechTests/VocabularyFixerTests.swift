import Testing
@testable import BranSpeech

@Suite("Dictionnaire de corrections")
struct VocabularyFixerTests {

    private func fixer(_ pairs: (String, String)...) -> VocabularyFixer {
        VocabularyFixer(rules: pairs.map { .init(heard: $0.0, written: $0.1) })
    }

    @Test("Corrige la casse d'un nom propre")
    func fixesProperNoun() {
        let subject = fixer(("castral", "Castral"))
        #expect(subject.apply(to: "j'ai vu castral hier") == "j'ai vu Castral hier")
    }

    @Test("Corrige en début et en fin de phrase")
    func fixesAtBoundariesOfString() {
        let subject = fixer(("castral", "Castral"))
        #expect(subject.apply(to: "castral") == "Castral")
        #expect(subject.apply(to: "chez castral") == "chez Castral")
        #expect(subject.apply(to: "castral arrive") == "Castral arrive")
    }

    /// Le test qui justifie de ne pas faire un simple `replacingOccurrences`.
    @Test("Ne touche pas au milieu d'un mot")
    func respectsWordBoundaries() {
        let subject = fixer(("sdr", "SDR"))
        #expect(subject.apply(to: "sdrastvouitie") == "sdrastvouitie")
        #expect(subject.apply(to: "le sdr appelle") == "le SDR appelle")
    }

    @Test("La ponctuation compte comme une frontière")
    func punctuationIsABoundary() {
        let subject = fixer(("crm", "CRM"))
        #expect(subject.apply(to: "dans le crm, hier.") == "dans le CRM, hier.")
        #expect(subject.apply(to: "(crm)") == "(CRM)")
    }

    @Test("Corrige toutes les occurrences, pas seulement la première")
    func fixesEveryOccurrence() {
        let subject = fixer(("crm", "CRM"))
        #expect(subject.apply(to: "crm puis crm et crm") == "CRM puis CRM et CRM")
    }

    @Test("La règle la plus longue gagne")
    func longestRuleWins() {
        let subject = fixer(("meet", "Meet"), ("google meet", "Google Meet"))
        #expect(subject.apply(to: "sur google meet") == "sur Google Meet")
    }

    @Test("Les accents ne font pas rater la correspondance")
    func matchesAcrossDiacritics() {
        let subject = fixer(("resume", "compte-rendu"))
        #expect(subject.apply(to: "envoie le résumé") == "envoie le compte-rendu")
    }

    @Test("Les expressions de plusieurs mots sont prises en charge")
    func handlesMultiWordPhrases() {
        let subject = fixer(("opa ventures", "Opah Ventures"))
        #expect(subject.apply(to: "chez opa ventures") == "chez Opah Ventures")
    }

    @Test("Un dictionnaire vide laisse le texte intact")
    func emptyDictionaryIsIdentity() {
        #expect(VocabularyFixer().apply(to: "rien ne change") == "rien ne change")
    }

    @Test("Une règle incomplète est ignorée plutôt que d'effacer du texte")
    func ignoresIncompleteRules() {
        let subject = VocabularyFixer(rules: [
            .init(heard: "castral", written: "   "),
            .init(heard: "  ", written: "Castral"),
        ])
        #expect(subject.apply(to: "castral") == "castral")
    }

    @Test("Un texte vide ne provoque rien")
    func emptyTextIsFine() {
        #expect(fixer(("a", "b")).apply(to: "") == "")
    }

    @Test("Le dictionnaire de départ corrige les termes courants")
    func starterDictionaryWorks() {
        let subject = VocabularyFixer.starter
        #expect(subject.apply(to: "on se voit sur google meet") == "on se voit sur Google Meet")
        #expect(subject.apply(to: "regarde dans le crm") == "regarde dans le CRM")
    }

    /// La phrase exacte rendue par Parakeet lors de la première mesure réelle
    /// sur un M2 Pro. Le modèle entend « Meet » au milieu d'une phrase française
    /// et le rabat sur « mais est ». Ce test fige la correction : si quelqu'un
    /// nettoie le dictionnaire de départ, la régression se voit tout de suite.
    @Test("La faute réellement observée sur « Google Meet » est rattrapée")
    func fixesTheErrorMeasuredInProduction() {
        let heard = """
        On se voit sur Google, mais est à 14h, et je mettrai le compte rendu \
        dans le CRM juste après.
        """
        let fixed = VocabularyFixer.starter.apply(to: heard)

        #expect(fixed.contains("Google Meet"))
        #expect(fixed.contains("mais est") == false)
        #expect(fixed.contains("CRM"))
    }

    /// Une aiguille qui ne consomme rien bouclerait à l'infini. Le test existe
    /// pour que ça ne compile plus jamais autrement.
    @Test("Une aiguille vide ne fait pas boucler")
    func emptyNeedleTerminates() {
        #expect(VocabularyFixer.replace("", with: "x", in: "abc") == "abc")
    }
}
