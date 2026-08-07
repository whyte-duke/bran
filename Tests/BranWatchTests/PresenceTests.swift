import Foundation
import Testing
@testable import BranWatch

@Suite("La présence de l'humain")
struct PresenceTests {

    private let t0 = Date(timeIntervalSince1970: 1_754_438_400)

    // MARK: - La règle

    /// Le défaut du produit : quelqu'un tape, il est là.
    @Test("Une activité récente vaut présent")
    func activiteRecenteVautPresent() {
        #expect(Presence.resolve(PresenceInput(idleSeconds: 0)) == .present)
        #expect(Presence.resolve(PresenceInput(idleSeconds: 119)) == .present)
    }

    @Test("Une immobilité longue vaut sans activité")
    func immobiliteLongueVautIdle() {
        #expect(Presence.resolve(PresenceInput(idleSeconds: 120)) == .idle)
        #expect(Presence.resolve(PresenceInput(idleSeconds: 3600)) == .idle)
    }

    /// **Le cœur du correctif.** Les trois certitudes passent devant la mesure
    /// d'inactivité, y compris quand celle-ci dit « il vient de taper » — ce
    /// qu'elle fait forcément à la seconde où l'on verrouille son écran, puisque
    /// verrouiller est un geste.
    @Test("Le verrou l'emporte sur une activité à l'instant")
    func verrouLEmporte() {
        let input = PresenceInput(isScreenLocked: true, idleSeconds: 0)
        #expect(Presence.resolve(input) == .away)
    }

    @Test("L'écran éteint et la veille machine valent absent")
    func ecranEteintEtVeilleValentAway() {
        #expect(Presence.resolve(PresenceInput(isDisplayAsleep: true, idleSeconds: 0)) == .away)
        #expect(Presence.resolve(PresenceInput(machineSlept: true, idleSeconds: 0)) == .away)
    }

    /// CR-1 appliqué à la présence : un capteur muet ne se remplace pas par une
    /// supposition. C'est le seul cas qui n'écrit rien.
    @Test("Un capteur d'inactivité muet ne conclut rien")
    func capteurMuetNeConclutRien() {
        #expect(Presence.resolve(PresenceInput(idleSeconds: nil)) == nil)
    }

    /// …sauf si une certitude s'est déjà prononcée. Un écran verrouillé est une
    /// absence, que le compteur d'inactivité réponde ou non.
    @Test("Une certitude conclut même sans compteur d'inactivité")
    func certitudeConclutSansCompteur() {
        #expect(Presence.resolve(PresenceInput(isScreenLocked: true, idleSeconds: nil)) == .away)
    }

    @Test("Le seuil d'immobilité est réglable")
    func seuilReglable() {
        let input = PresenceInput(idleSeconds: 60)
        #expect(Presence.resolve(input, idleAfter: 30) == .idle)
        #expect(Presence.resolve(input, idleAfter: 300) == .present)
    }

    // MARK: - La fusion

    @Test("Une présence qui dure n'écrit aucune ligne")
    func presenceQuiDureNEcritRien() {
        var ledger = PresenceLedger(tickInterval: 4)

        for tick in 0 ..< 10 {
            let written = ledger.beat(.present, at: t0.addingTimeInterval(Double(tick) * 4), elapsed: 4)
            #expect(written == nil)
        }

        let closed = ledger.flush()
        #expect(closed?.presence == .present)
        // Le premier battement ouvre l'intervalle sans y verser sa durée : neuf
        // extensions de quatre secondes.
        #expect(closed?.d == 36)
    }

    @Test("Un changement de présence ferme l'intervalle précédent")
    func changementFermeLIntervalle() {
        var ledger = PresenceLedger(tickInterval: 4)

        #expect(ledger.beat(.present, at: t0, elapsed: 4) == nil)
        #expect(ledger.beat(.present, at: t0.addingTimeInterval(4), elapsed: 4) == nil)

        let closed = ledger.beat(.idle, at: t0.addingTimeInterval(8), elapsed: 4)
        #expect(closed?.presence == .present)
        // Le battement de la transition revient à l'intervalle qui se ferme :
        // deux extensions de quatre secondes. Ici la règle compte double —
        // une pause de cinq minutes pile ne doit pas rater son seuil pour un
        // tic manquant.
        #expect(closed?.d == 8)
    }

    /// Un battement en retard coupe l'intervalle : sans ça, une application
    /// suspendue pendant une heure écrirait une heure de présence continue que
    /// personne n'a observée.
    @Test("Un battement trop tardif coupe l'intervalle")
    func battementTardifCoupe() {
        var ledger = PresenceLedger(tickInterval: 4)

        #expect(ledger.beat(.present, at: t0, elapsed: 4) == nil)
        let closed = ledger.beat(.present, at: t0.addingTimeInterval(600), elapsed: 4)
        #expect(closed != nil)
        #expect(closed?.d == 0)
    }

    // MARK: - La veille machine

    /// Une nuit de veille laissait un trou dans le journal exactement là où
    /// l'absence est la mieux connue de toute la journée.
    @Test("Une veille machine écrit une absence à ses deux bornes")
    func veilleEcritUneAbsence() {
        var ledger = PresenceLedger(tickInterval: 4)
        _ = ledger.beat(.present, at: t0, elapsed: 4)
        _ = ledger.beat(.present, at: t0.addingTimeInterval(4), elapsed: 4)

        let nuit: TimeInterval = 8 * 3600
        let reveil = t0.addingTimeInterval(4 + nuit)
        let written = ledger.slept(for: nuit, endingAt: reveil)

        #expect(written.count == 2)

        // L'intervalle courant s'arrête au **début** de la veille, pas au
        // réveil : sinon la présence de la veille au soir engloberait la nuit.
        let avant = written[0]
        #expect(avant.presence == .present)
        #expect(avant.to == t0.addingTimeInterval(4))

        let absence = written[1]
        #expect(absence.presence == .away)
        #expect(absence.from == t0.addingTimeInterval(4))
        #expect(absence.to == reveil)
        #expect(absence.d == nuit)
    }

    @Test("Une veille sans intervalle ouvert n'écrit que l'absence")
    func veilleSansIntervalleOuvert() {
        var ledger = PresenceLedger(tickInterval: 4)
        let written = ledger.slept(for: 3600, endingAt: t0)
        #expect(written.count == 1)
        #expect(written[0].presence == .away)
        #expect(written[0].d == 3600)
    }

    // MARK: - Les deux formes dans un fichier

    /// La cohabitation ne repose sur aucun aiguillage : chaque décodeur rejette
    /// les lignes de l'autre. Si cette propriété tombe, un journal se lirait à
    /// moitié sans que rien ne le signale.
    @Test("Une ligne de voie ne se décode pas en présence, et réciproquement")
    func lesDeuxFormesNeSeConfondentPas() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        let presence = PresenceEvent(presence: .idle, from: t0, to: t0.addingTimeInterval(60), d: 60)
        let lane = WatchEvent(
            lane: "cc:/p/crm", name: "crm", p: 2, state: .working,
            from: t0, to: t0.addingTimeInterval(60), d: 60,
            src: .certain, why: "pour le test"
        )

        let presenceData = try encoder.encode(presence)
        let laneData = try encoder.encode(lane)

        #expect((try? decoder.decode(PresenceEvent.self, from: presenceData)) == presence)
        #expect((try? decoder.decode(WatchEvent.self, from: laneData)) == lane)

        #expect((try? decoder.decode(WatchEvent.self, from: presenceData)) == nil)
        #expect((try? decoder.decode(PresenceEvent.self, from: laneData)) == nil)
    }
}
