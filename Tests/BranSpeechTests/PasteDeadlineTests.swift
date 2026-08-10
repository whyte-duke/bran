import Foundation
import Testing

@testable import BranSpeech

/// Ce que ces tests protègent : **l'appelant reçoit exactement une réponse.**
///
/// Le défaut d'origine était l'absence de réponse — une machine à états figée en
/// `.pasting` tant que l'application source restait coincée. Le remède introduit
/// un second coureur, et le défaut d'en face avec lui : deux réponses pour un
/// seul collage, donc deux transitions pour une seule dictée. Les deux sont ici.
@Suite("Délai de renoncement au presse-papiers")
struct PasteDeadlineTests {

    @Test("La première prise gagne, la seconde perd")
    func firstClaimWins() {
        let deadline = PasteDeadline()
        #expect(deadline.claim() == true)
        #expect(deadline.claim() == false)
        #expect(deadline.claim() == false)
    }

    @Test("Un jeton neuf n'est pas pris")
    func startsUnsettled() {
        let deadline = PasteDeadline()
        #expect(deadline.isSettled == false)
        _ = deadline.claim()
        #expect(deadline.isSettled == true)
    }

    /// Le cas réel : le minuteur du main actor et l'écriture sur la file série
    /// se réveillent au même instant. Un `Bool` sans verrou perdrait la course
    /// ici, et l'appelant recevrait deux réponses.
    @Test("Sous assaut concurrent, un seul vainqueur")
    func exactlyOneWinnerUnderContention() async {
        for _ in 0..<200 {
            let deadline = PasteDeadline()
            let winners = await withTaskGroup(of: Bool.self) { group in
                for _ in 0..<16 {
                    group.addTask { deadline.claim() }
                }
                return await group.reduce(into: 0) { $0 += $1 ? 1 : 0 }
            }
            #expect(winners == 1)
        }
    }

    /// Le délai doit rester dans son créneau, et le créneau est le sujet du
    /// commentaire de `grace` : très au-dessus d'une écriture saine — quelques
    /// microsecondes —, très en dessous de ce qu'un humain accepte de regarder
    /// sans comprendre.
    @Test("Le délai reste entre une écriture saine et la patience humaine")
    func graceIsInTheRightNeighbourhood() {
        #expect(PasteDeadline.grace > .milliseconds(50))
        #expect(PasteDeadline.grace <= .seconds(1))
    }

    /// Le délai est aligné sur le budget que la machine du presse-papiers
    /// accorde déjà à `pasteboardd`. Ce test existe pour que le jour où l'un des
    /// deux bouge, on décide si l'autre doit suivre au lieu de le découvrir.
    @Test("Le délai vaut les 500 ms du budget presse-papiers")
    func graceMatchesTheClipboardBudget() {
        #expect(PasteDeadline.grace == .milliseconds(500))
    }

    /// La conversion contient une division par 10¹⁸. Une erreur d'un facteur
    /// mille y donnerait soit un délai qui expire avant toute écriture, soit un
    /// délai qui n'expire jamais — c'est-à-dire le défaut d'origine, restauré
    /// en silence.
    @Test("La conversion en secondes ne se trompe pas d'échelle")
    func secondsConversion() {
        #expect(PasteDeadline.graceInSeconds == 0.5)
        #expect(PasteDeadline.seconds(.milliseconds(80)) == 0.08)
        #expect(PasteDeadline.seconds(.seconds(2)) == 2)
        #expect(PasteDeadline.seconds(.zero) == 0)
    }
}
