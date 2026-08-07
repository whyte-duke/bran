import Foundation
import Testing
@testable import BranWatch

@Suite("Fusion des intervalles")
struct WatchLedgerTests {

    private let voie = LaneIdentity.claudeCode(
        sessionID: "s", workingDirectory: "/p/crm", branch: "main"
    )

    private func lane(_ state: LaneState, _ identity: LaneIdentity? = nil) -> Lane {
        Lane(identity: identity ?? voie, state: state, waitingFor: 0, because: "pour le test")
    }

    private let t0 = Date(timeIntervalSince1970: 1_754_438_400)

    /// La raison d'être de la fusion, chiffrée : une ligne par tic donnerait
    /// 216 000 lignes par jour à 2 s et cinq voies. Ici, dix battements du même
    /// état n'écrivent rien du tout.
    @Test("Un état qui dure n'écrit aucune ligne")
    func etatQuiDureNEcritRien() {
        var ledger = WatchLedger(tickInterval: 2)

        for tick in 0 ..< 10 {
            let written = ledger.beat(
                lane: lane(.working),
                at: t0.addingTimeInterval(Double(tick) * 2),
                elapsed: 2,
                source: .certain
            )
            #expect(written == nil)
        }
    }

    @Test("Le changement d'état ferme l'intervalle précédent")
    func changementDEtatFerme() {
        var ledger = WatchLedger(tickInterval: 2)
        _ = ledger.beat(lane: lane(.working), at: t0, elapsed: 2, source: .certain)
        _ = ledger.beat(lane: lane(.working), at: t0.addingTimeInterval(2), elapsed: 2, source: .certain)

        let ferme = ledger.beat(
            lane: lane(.waiting), at: t0.addingTimeInterval(4), elapsed: 2, source: .certain
        )

        #expect(ferme?.state == .working)
        // **Le battement de la transition appartient à l'intervalle qui se
        // ferme.** Ce test verrouillait l'inverse — `d == 2`, borne haute à
        // t0+2 — c'est-à-dire la perte d'un tic à chaque changement d'état. Sur
        // deux cents intervalles par jour, un quart d'heure évaporé ; et un état
        // qui ne durait qu'un battement s'écrivait avec une durée de zéro.
        #expect(ferme?.d == 4)
        #expect(ferme?.to == t0.addingTimeInterval(4))
    }

    /// **La propriété qui manquait, et qui aurait attrapé le défaut seule.**
    ///
    /// Rien ne se perd : la somme des durées écrites vaut la somme des durées
    /// fournies. Un test qui vérifie un intervalle à la fois ne peut pas voir
    /// une fuite qui vit exactement entre deux intervalles.
    @Test("Rien ne se perd entre deux intervalles")
    func rienNeSePerd() {
        var ledger = WatchLedger(tickInterval: 2)
        let etats: [LaneState] = [.working, .working, .waiting, .working, .waiting, .waiting]

        var ecrit: TimeInterval = 0
        var fourni: TimeInterval = 0

        for (index, etat) in etats.enumerated() {
            // Le tout premier battement ouvre l'intervalle : il n'y a pas
            // encore d'intervalle à qui verser son temps, et c'est la seule
            // exception admise.
            let elapsed: TimeInterval = 2
            if index > 0 { fourni += elapsed }
            if let ferme = ledger.beat(
                lane: lane(etat), at: t0.addingTimeInterval(Double(index) * 2),
                elapsed: elapsed, source: .certain
            ) {
                ecrit += ferme.d
            }
        }

        ecrit += ledger.flush().reduce(0) { $0 + $1.d }
        #expect(ecrit == fourni)
    }

    /// Sans tolérance, une capture lente couperait une seule période de travail
    /// en deux lignes et fausserait toutes les statistiques.
    @Test("Un tic sauté ne coupe pas l'intervalle en deux")
    func ticSauteNeCoupePas() {
        var ledger = WatchLedger(tickInterval: 2)
        _ = ledger.beat(lane: lane(.working), at: t0, elapsed: 2, source: .certain)

        // 4 s plus tard : sous la tolérance de 2,5 × 2 = 5 s.
        let written = ledger.beat(
            lane: lane(.working), at: t0.addingTimeInterval(4), elapsed: 4, source: .certain
        )

        #expect(written == nil)
    }

    @Test("Une absence trop longue ferme quand même l'intervalle")
    func absenceTropLongueFerme() {
        var ledger = WatchLedger(tickInterval: 2)
        _ = ledger.beat(lane: lane(.working), at: t0, elapsed: 2, source: .certain)

        let ferme = ledger.beat(
            lane: lane(.working), at: t0.addingTimeInterval(60), elapsed: 2, source: .certain
        )

        #expect(ferme?.state == .working)
    }

    /// La durée journalisée est la **somme des temps réellement écoulés**
    /// fournis par l'appelant, pas une soustraction de dates. C'est ce qui la
    /// rend insensible à la veille : l'appelant mesure sur `SuspendingClock`,
    /// qui s'arrête quand la machine dort.
    @Test("La durée est accumulée, jamais déduite des dates")
    func dureeAccumuleeJamaisDeduite() {
        var ledger = WatchLedger(tickInterval: 2)
        _ = ledger.beat(lane: lane(.working), at: t0, elapsed: 2, source: .certain)
        _ = ledger.beat(lane: lane(.working), at: t0.addingTimeInterval(2), elapsed: 2, source: .certain)
        _ = ledger.beat(lane: lane(.working), at: t0.addingTimeInterval(4), elapsed: 2, source: .certain)

        let ferme = ledger.flush().first
        // Ouverture à d = 0, puis deux battements de 2 s.
        #expect(ferme?.d == 4)
        #expect(ferme?.to == t0.addingTimeInterval(4))
    }

    /// Le cas de tous les matins : la machine dort huit heures. L'écart de dates
    /// dépasse largement la tolérance, donc l'intervalle se ferme sur sa
    /// dernière observation réelle au lieu de s'étirer sur toute la nuit.
    @Test("Une nuit de veille ferme l'intervalle au lieu de l'étirer")
    func nuitDeVeilleFerme() {
        var ledger = WatchLedger(tickInterval: 2)
        _ = ledger.beat(lane: lane(.working), at: t0, elapsed: 2, source: .certain)
        _ = ledger.beat(lane: lane(.working), at: t0.addingTimeInterval(2), elapsed: 2, source: .certain)

        let ferme = ledger.beat(
            lane: lane(.working), at: t0.addingTimeInterval(28_800), elapsed: 2, source: .certain
        )

        #expect(ferme?.to == t0.addingTimeInterval(2), "l'intervalle s'arrête à la dernière observation")
        #expect(ferme?.d == 2, "et il ne compte pas les huit heures dormies")
    }

    @Test("Une voie qui disparaît de l'observation voit son intervalle se fermer")
    func voieDisparueSeFerme() {
        var ledger = WatchLedger(tickInterval: 2)
        _ = ledger.beat(lane: lane(.working), at: t0, elapsed: 2, source: .certain)

        let fermes = ledger.closeMissing(keeping: [])

        #expect(fermes.count == 1)
        #expect(fermes.first?.lane == voie.key)
    }

    @Test("Une voie toujours observée n'est pas fermée par erreur")
    func voieObserveeNestPasFermee() {
        var ledger = WatchLedger(tickInterval: 2)
        _ = ledger.beat(lane: lane(.working), at: t0, elapsed: 2, source: .certain)

        #expect(ledger.closeMissing(keeping: [voie.key]).isEmpty)
    }

    @Test("Le vidage rend tous les intervalles ouverts et n'en garde aucun")
    func vidageRendToutEtNeGardeRien() {
        let autre = LaneIdentity.claudeCode(sessionID: "s2", workingDirectory: "/p/bran", branch: "main")
        var ledger = WatchLedger(tickInterval: 2)
        _ = ledger.beat(lane: lane(.working), at: t0, elapsed: 2, source: .certain)
        _ = ledger.beat(lane: lane(.waiting, autre), at: t0, elapsed: 2, source: .pixels)

        #expect(ledger.flush().count == 2)
        #expect(ledger.flush().isEmpty)
    }

    /// Un trou doit rester visible dans le journal : c'est la règle de tout le
    /// projet, un échec silencieux est pire qu'un trou nommé.
    @Test("L'état inconnu s'écrit comme les autres")
    func inconnuSEcritAussi() {
        var ledger = WatchLedger(tickInterval: 2)
        _ = ledger.beat(lane: lane(.unknown), at: t0, elapsed: 2, source: .aucun)

        #expect(ledger.flush().first?.state == .unknown)
    }
}

@Suite("Horloge et détection de veille")
struct WatchClockTests {

    @Test("Sans veille, le temps écoulé est celui des deux horloges")
    func sansVeille() {
        let clock = WatchClock(tickInterval: 2)
        let step = clock.step(from: .now, to: .now)

        #expect(step.slept < 0.5)
        #expect(step.jumped == false)
    }

    @Test("La conversion d'une durée en secondes tient la fraction")
    func conversionDeDuree() {
        #expect(abs(WatchClock.seconds(.milliseconds(1500)) - 1.5) < 0.0001)
        #expect(abs(WatchClock.seconds(.seconds(90)) - 90) < 0.0001)
    }

    /// La soustraction que le veilleur fait le plus souvent : depuis combien de
    /// temps une voie est immobile, depuis combien de temps l'humain ne l'a pas
    /// touchée, quel âge a le dernier prélèvement. Trois appelants s'en
    /// servaient chacun avec leur copie.
    @Test("L'écart entre deux instants est rendu en secondes entières")
    func ecartEntreDeuxInstants() {
        #expect(WatchClock.seconds(from: .seconds(10), to: .seconds(190)) == 180)
        #expect(WatchClock.seconds(from: .zero, to: .zero) == 0)
    }

    /// Deux instants relevés dans le désordre entre deux tâches concurrentes
    /// donneraient une durée négative, qui se lirait comme « à l'instant » —
    /// c'est-à-dire comme un mouvement qui n'a pas eu lieu.
    @Test("Un écart négatif est ramené à zéro, jamais rendu tel quel")
    func jamaisNegatif() {
        #expect(WatchClock.seconds(from: .seconds(200), to: .seconds(10)) == 0)
    }

    /// Tronqué et non arrondi : 179,9 s ne doit pas franchir un seuil de 180.
    @Test("Les fractions de seconde sont tronquées vers le bas")
    func fractionsTronquees() {
        #expect(WatchClock.seconds(from: .zero, to: .milliseconds(179_900)) == 179)
        #expect(WatchClock.seconds(from: .zero, to: .milliseconds(999)) == 0)
    }
}

@Suite("Rétention du journal")
struct WatchRetentionTests {

    @Test("Le fichier du jour n'est jamais purgé")
    func fichierDuJourJamaisPurge() {
        let retention = WatchRetention(days: 0)
        #expect(retention.filesToPurge(from: ["2026-08-06.jsonl"], today: "2026-08-06").isEmpty)
    }

    @Test("Au-delà de la durée gardée, le fichier part")
    func auDelaLeFichierPart() {
        let retention = WatchRetention(days: 30)
        let noms = ["2026-08-05.jsonl", "2026-06-01.jsonl", "2026-08-06.jsonl"]

        #expect(retention.filesToPurge(from: noms, today: "2026-08-06") == ["2026-06-01.jsonl"])
    }

    /// Un fichier étranger déposé dans le dossier ne doit pas être supprimé par
    /// une purge — la rétention n'a pas à décider du sort de ce qu'elle n'a pas
    /// écrit.
    @Test("Un fichier au nom inattendu n'est jamais touché")
    func fichierEtrangerIntact() {
        let retention = WatchRetention(days: 0)
        let noms = ["notes.txt", "2026.jsonl", "sauvegarde-2026-01-01.jsonl"]

        #expect(retention.filesToPurge(from: noms, today: "2026-08-06").isEmpty)
    }

    @Test("Zéro jour ne garde que le journal du jour")
    func zeroJourNeGardeQueAujourdhui() {
        let retention = WatchRetention(days: 0)
        let noms = ["2026-08-05.jsonl", "2026-08-06.jsonl"]

        #expect(retention.filesToPurge(from: noms, today: "2026-08-06") == ["2026-08-05.jsonl"])
        #expect(retention.keepsNothing)
    }

    @Test("Les libellés se lisent en français")
    func libelles() {
        #expect(WatchRetention(days: 0).label == "Aucun journal conservé")
        #expect(WatchRetention(days: 1).label == "1 jour")
        #expect(WatchRetention(days: 30).label == "30 jours")
        #expect(WatchRetention(days: 365).label == "1 an")
    }
}
