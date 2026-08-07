import Foundation
import Testing
@testable import BranWatch

@Suite("Les pauses")
struct BreakSummaryTests {

    private let t0 = Date(timeIntervalSince1970: 1_754_438_400)

    private func event(_ presence: Presence, at offset: TimeInterval, lasting seconds: TimeInterval) -> PresenceEvent {
        PresenceEvent(
            presence: presence,
            from: t0.addingTimeInterval(offset),
            to: t0.addingTimeInterval(offset + seconds),
            d: seconds
        )
    }

    @Test("Sans intervalle, il n'y a rien à raconter")
    func sansIntervalle() {
        let summary = BreakSummary.make(events: [], now: t0)
        #expect(summary.isEmpty)
        #expect(summary.sinceLastBreak == nil)
        #expect(summary.workPerBreak == nil)
    }

    /// Le seuil est ce qui empêche le ratio de flatter : aller chercher un café
    /// n'est pas une pause, et compter chaque micro-absence donnerait « une
    /// pause pour deux minutes de travail ».
    @Test("Une absence trop courte ne compte pas comme une pause")
    func absenceTropCourteNeComptePas() {
        let summary = BreakSummary.make(
            events: [
                event(.present, at: 0, lasting: 1800),
                event(.idle, at: 1800, lasting: 120),
                event(.present, at: 1920, lasting: 1800),
            ],
            now: t0.addingTimeInterval(3720)
        )

        #expect(summary.breaks.isEmpty)
        #expect(summary.presentSeconds == 3600)
        #expect(summary.pausedSeconds == 0)
        #expect(summary.workPerBreak == nil)
    }

    @Test("Une absence assez longue compte, et garde sa nature")
    func absenceLongueCompte() {
        let summary = BreakSummary.make(
            events: [
                event(.present, at: 0, lasting: 3600),
                event(.away, at: 3600, lasting: 1800),
                event(.present, at: 5400, lasting: 3600),
            ],
            now: t0.addingTimeInterval(9000)
        )

        #expect(summary.breaks.count == 1)
        #expect(summary.breaks[0].seconds == 1800)
        #expect(summary.breaks[0].presence == .away)
        #expect(summary.presentSeconds == 7200)
        #expect(summary.pausedSeconds == 1800)
    }

    /// « Il y a 42 min » veut dire « ça fait 42 minutes que j'ai repris », pas
    /// « ça fait 42 minutes que je me suis arrêté ». C'est la fin de la pause
    /// qui compte, et se tromper de borne rassure exactement au mauvais moment.
    @Test("Le chrono part de la fin de la pause, pas de son début")
    func chronoPartDeLaFin() {
        let summary = BreakSummary.make(
            events: [
                event(.present, at: 0, lasting: 3600),
                event(.away, at: 3600, lasting: 1800),
            ],
            now: t0.addingTimeInterval(5400 + 600)
        )

        #expect(summary.sinceLastBreak == 600)
    }

    @Test("Le ratio se lit « une de pause pour N de travail »")
    func ratio() throws {
        let summary = BreakSummary.make(
            events: [
                event(.present, at: 0, lasting: 3600),
                event(.idle, at: 3600, lasting: 600),
                event(.present, at: 4200, lasting: 2400),
            ],
            now: t0.addingTimeInterval(6600)
        )

        let ratio = try #require(summary.workPerBreak)
        #expect(abs(ratio - 10) < 0.001)
    }

    /// Un ratio sur zéro n'est pas l'infini : c'est une absence de mesure, et
    /// l'écrire « ∞ » serait mentir avec un symbole mathématique.
    @Test("Sans pause, il n'y a pas de ratio")
    func sansPausePasDeRatio() {
        let summary = BreakSummary.make(
            events: [event(.present, at: 0, lasting: 3600)],
            now: t0.addingTimeInterval(3600)
        )
        #expect(summary.workPerBreak == nil)
        #expect(summary.sinceLastBreak == nil)
    }

    /// **Le piège de la veille.** Un intervalle qui traverse une nuit a huit
    /// heures d'écart entre ses bornes murales. Pour une absence, c'est la
    /// bonne durée — mais elle doit venir de `d`, pas d'une soustraction faite
    /// ici : le jour où les deux divergeront, c'est `d` qui aura raison.
    @Test("La durée lue est celle mesurée, pas l'écart des bornes")
    func dureeLueEstCelleMesuree() {
        // Des bornes qui annoncent une heure, une durée mesurée de dix minutes.
        let bancal = PresenceEvent(
            presence: .idle,
            from: t0,
            to: t0.addingTimeInterval(3600),
            d: 600
        )

        let summary = BreakSummary.make(events: [bancal], now: t0.addingTimeInterval(3600))
        #expect(summary.breaks.count == 1)
        #expect(summary.pausedSeconds == 600)
    }

    @Test("Les intervalles sont remis en ordre avant d'être lus")
    func intervallesRemisEnOrdre() {
        let summary = BreakSummary.make(
            events: [
                event(.away, at: 7200, lasting: 900),
                event(.present, at: 0, lasting: 3600),
                event(.away, at: 3600, lasting: 600),
            ],
            now: t0.addingTimeInterval(8100 + 300)
        )

        #expect(summary.breaks.count == 2)
        // La dernière pause est celle de 7200, pas celle de 3600.
        #expect(summary.sinceLastBreak == 300)
    }

    @Test("Un chrono ne repart jamais en arrière")
    func chronoJamaisNegatif() {
        let summary = BreakSummary.make(
            events: [event(.away, at: 3600, lasting: 1800)],
            // Lu **pendant** la pause : la fin est dans le futur.
            now: t0.addingTimeInterval(4200)
        )
        #expect(summary.sinceLastBreak == 0)
    }
}
