import Foundation
import Testing
@testable import BranWatch

@Suite("Les pauses")
struct BreakSummaryTests {

    private let t0 = Date(timeIntervalSince1970: 1_754_438_400)

    /// Par défaut le travail a commencé à `t0` : la plupart des cas testent le
    /// comportement des pauses, pas la règle de la nuit, qui a ses tests à elle.
    private func summary(
        _ events: [PresenceEvent],
        workStartedAt: Date? = nil,
        at now: Date
    ) -> BreakSummary {
        BreakSummary.make(events: events, workStartedAt: workStartedAt ?? t0, now: now)
    }

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
        let summary = summary([], at: t0)
        #expect(summary.isEmpty)
        #expect(summary.sinceLastBreak == nil)
        #expect(summary.workPerBreak == nil)
    }

    /// Le seuil est ce qui empêche le ratio de flatter : aller chercher un café
    /// n'est pas une pause, et compter chaque micro-absence donnerait « une
    /// pause pour deux minutes de travail ».
    @Test("Une absence trop courte ne compte pas comme une pause")
    func absenceTropCourteNeComptePas() {
        let summary = summary([
                event(.present, at: 0, lasting: 1800),
                event(.idle, at: 1800, lasting: 120),
                event(.present, at: 1920, lasting: 1800),
            ], at: t0.addingTimeInterval(3720)
        )

        #expect(summary.breaks.isEmpty)
        #expect(summary.presentSeconds == 3600)
        #expect(summary.pausedSeconds == 0)
        #expect(summary.workPerBreak == nil)
    }

    @Test("Une absence assez longue compte, et garde sa nature")
    func absenceLongueCompte() {
        let summary = summary([
                event(.present, at: 0, lasting: 3600),
                event(.away, at: 3600, lasting: 1800),
                event(.present, at: 5400, lasting: 3600),
            ], at: t0.addingTimeInterval(9000)
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
        let summary = summary([
                event(.present, at: 0, lasting: 3600),
                event(.away, at: 3600, lasting: 1800),
            ], at: t0.addingTimeInterval(5400 + 600)
        )

        #expect(summary.sinceLastBreak == 600)
    }

    @Test("Le ratio se lit « une de pause pour N de travail »")
    func ratio() throws {
        let summary = summary([
                event(.present, at: 0, lasting: 3600),
                event(.idle, at: 3600, lasting: 600),
                event(.present, at: 4200, lasting: 2400),
            ], at: t0.addingTimeInterval(6600)
        )

        let ratio = try #require(summary.workPerBreak)
        #expect(abs(ratio - 10) < 0.001)
    }

    /// Un ratio sur zéro n'est pas l'infini : c'est une absence de mesure, et
    /// l'écrire « ∞ » serait mentir avec un symbole mathématique.
    @Test("Sans pause, il n'y a pas de ratio")
    func sansPausePasDeRatio() {
        let summary = summary([event(.present, at: 0, lasting: 3600)], at: t0.addingTimeInterval(3600)
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

        let summary = summary([bancal], at: t0.addingTimeInterval(3600))
        #expect(summary.breaks.count == 1)
        #expect(summary.pausedSeconds == 600)
    }

    @Test("Les intervalles sont remis en ordre avant d'être lus")
    func intervallesRemisEnOrdre() {
        let summary = summary([
                event(.away, at: 7200, lasting: 900),
                event(.present, at: 0, lasting: 3600),
                event(.away, at: 3600, lasting: 600),
            ], at: t0.addingTimeInterval(8100 + 300)
        )

        #expect(summary.breaks.count == 2)
        // La dernière pause est celle de 7200, pas celle de 3600.
        #expect(summary.sinceLastBreak == 300)
    }

    // MARK: - Le raccommodage

    /// **Le défaut que seul un vrai journal pouvait montrer.** Sur une journée
    /// réelle, trois absences se suivaient — 405 s, 46 s, 900 s — là où
    /// l'utilisateur avait vécu une seule absence. Chaque veille machine rouvre
    /// une ligne, parce que la boucle ne tourne pas pendant que la machine dort.
    @Test("Trois absences que l'observation a coupées n'en font qu'une")
    func absencesRecousues() {
        let summary = summary([
                event(.away, at: 0, lasting: 405),
                event(.away, at: 410, lasting: 46),
                event(.away, at: 460, lasting: 900),
            ], at: t0.addingTimeInterval(1360)
        )

        #expect(summary.breaks.count == 1)
        // De bout en bout, trous compris : c'est le temps passé loin de la
        // machine, et les cinq secondes non observées en font partie.
        #expect(summary.breaks[0].seconds == 1360)
    }

    /// **La conséquence qui comptait.** Une absence d'une heure coupée en
    /// fragments de deux minutes disparaissait entièrement : chaque morceau
    /// tombait sous le seuil des cinq minutes. « Quand ai-je pris ma dernière
    /// pause » répondait « aucune » un jour où l'on avait déjeuné.
    @Test("Une absence fragmentée sous le seuil ne disparaît plus")
    func absenceFragmenteeNeDisparaitPlus() {
        let fragments = (0..<20).map { index in
            event(.away, at: Double(index) * 130, lasting: 120)
        }

        let summary = summary(fragments, at: t0.addingTimeInterval(3000))

        #expect(summary.breaks.count == 1)
        #expect(summary.breaks[0].seconds > 2400)
    }

    /// …mais deux vraies pauses séparées par un vrai retour au travail restent
    /// deux pauses. Sans cette limite, la journée entière deviendrait une seule
    /// absence dès le premier trou.
    @Test("Deux pauses séparées par du travail restent deux pauses")
    func deuxVraiesPausesRestentDeux() {
        let summary = summary([
                event(.away, at: 0, lasting: 600),
                event(.present, at: 600, lasting: 3600),
                event(.away, at: 4200, lasting: 600),
            ], at: t0.addingTimeInterval(4800)
        )

        #expect(summary.breaks.count == 2)
        #expect(summary.presentSeconds == 3600)
    }

    /// Une absence certaine reste certaine une fois recousue à une immobilité
    /// qui ne l'était pas : `away` l'emporte sur `idle`.
    @Test("Le recoud garde la nature la plus certaine")
    func recoudGardeLaPlusCertaine() {
        let summary = summary([
                event(.idle, at: 0, lasting: 200),
                event(.away, at: 210, lasting: 200),
            ], at: t0.addingTimeInterval(500)
        )

        #expect(summary.breaks.count == 1)
        #expect(summary.breaks[0].presence == .away)
    }

    @Test("Un chrono ne repart jamais en arrière")
    func chronoJamaisNegatif() {
        let summary = summary(
            [event(.away, at: 3600, lasting: 1800)],
            // Lu **pendant** la pause : la fin est dans le futur.
            at: t0.addingTimeInterval(4200)
        )
        #expect(summary.sinceLastBreak == 0)
    }

    // MARK: - La nuit n'est pas une pause

    /// **Mesuré sur un vrai journal, et ça n'est venu que de là.** Une absence
    /// de 13 h 20 partant de 00 h 08 : parfaitement réelle, personne n'était
    /// devant la machine. Comptée comme pause, elle donnait « une de pause pour
    /// 0,01 de travail » — un chiffre qui décrit un sommeil.
    ///
    /// Ce qui sépare les deux n'est pas la durée : une sieste de trois heures
    /// est une pause, une nuit de six heures n'en est pas une. C'est la place.
    @Test("Une absence avant le premier travail de la journée n'est pas une pause")
    func laNuitNEstPasUnePause() {
        let nuit = [
            event(.away, at: 0, lasting: 28800),
            event(.present, at: 28800, lasting: 3600),
        ]

        let summary = BreakSummary.make(
            events: nuit,
            workStartedAt: t0.addingTimeInterval(28800),
            now: t0.addingTimeInterval(32400)
        )

        #expect(summary.breaks.isEmpty)
        #expect(summary.sinceLastBreak == nil)
        #expect(summary.workPerBreak == nil)
    }

    /// La même absence, à la même durée, **après** avoir travaillé : c'est une
    /// pause. La règle porte sur la place, pas sur la longueur.
    @Test("La même absence après le premier travail en est une")
    func lameAbsenceApresLeTravailEnEstUne() {
        let summary = BreakSummary.make(
            events: [
                event(.present, at: 0, lasting: 3600),
                event(.away, at: 3600, lasting: 10800),
            ],
            workStartedAt: t0,
            now: t0.addingTimeInterval(14400)
        )

        #expect(summary.breaks.count == 1)
        #expect(summary.breaks[0].seconds == 10800)
    }

    /// Rien n'a encore été travaillé : il ne peut y avoir aucune pause, quelle
    /// que soit l'absence observée.
    @Test("Sans travail commencé, aucune pause")
    func sansTravailAucunePause() {
        let summary = BreakSummary.make(
            events: [event(.away, at: 0, lasting: 7200)],
            workStartedAt: nil,
            now: t0.addingTimeInterval(7200)
        )

        #expect(summary.breaks.isEmpty)
    }
}
