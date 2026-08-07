import Foundation
import Testing
@testable import BranWatch

/// La journée est l'écran qu'on regarde tous les jours, donc celui dont les
/// chiffres se croient le plus vite. Les mêmes précautions que
/// `WeekSummaryTests` : calendrier fixe, `now` fourni, aucun disque.
@Suite("Résumé de la journée")
struct DaySummaryTests {

    private var paris: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris") ?? .gmt
        return calendar
    }

    private func at(_ h: Int, _ m: Int = 0) -> Date {
        paris.date(from: DateComponents(year: 2026, month: 8, day: 7, hour: h, minute: m)) ?? .distantPast
    }

    private func event(
        lane: String = "cc:/x/crm",
        name: String = "crm",
        state: LaneState = .working,
        cwd: String? = "/x/crm",
        from: Date,
        to: Date,
        src: WatchEvent.Source = .certain,
        fg: Bool? = true
    ) -> WatchEvent {
        WatchEvent(
            lane: lane, name: name, p: 2, state: state,
            from: from, to: to, d: to.timeIntervalSince(from),
            src: src, why: "test", cwd: cwd, branch: "main", fg: fg
        )
    }

    private func day(
        _ events: [WatchEvent],
        presence: [PresenceEvent] = [],
        now: Date? = nil
    ) -> DaySummary {
        DaySummary.make(
            events: events, presence: presence,
            now: now ?? at(18), calendar: paris
        )
    }

    // MARK: - Les blocs

    @Test("Une journée vide n'invente pas de bloc")
    func journeeVide() {
        let summary = day([])
        #expect(summary.isEmpty)
        #expect(summary.blocks.isEmpty)
    }

    /// Deux voies qui travaillent en même temps font **un** bloc. C'est ce qui
    /// permet de lire « j'ai travaillé de 9 h à 10 h » au lieu d'une pile de
    /// segments à recomposer à l'œil.
    @Test("Deux voies simultanées font un seul bloc")
    func deuxVoiesUnSeulBloc() {
        let summary = day([
            event(lane: "a", name: "a", from: at(9), to: at(10)),
            event(lane: "b", name: "b", from: at(9, 15), to: at(10, 30)),
        ])

        #expect(summary.blocks.count == 1)
        #expect(summary.blocks[0].from == at(9))
        #expect(summary.blocks[0].to == at(10, 30))
        #expect(summary.blocks[0].laneCount == 2)
    }

    /// Le seuil de coupure est celui de `Presence.idleAfter`, et c'est
    /// délibéré : un trou qui ne fait pas s'absenter l'humain ne doit pas
    /// couper son bloc de travail.
    @Test("Un trou court ne coupe pas le bloc, un trou long si")
    func trouCourtNeCoupePas() {
        let court = day([
            event(from: at(9), to: at(10)),
            event(from: at(10, 1), to: at(11)),
        ])
        #expect(court.blocks.count == 1)

        let long = day([
            event(from: at(9), to: at(10)),
            event(from: at(10, 30), to: at(11)),
        ])
        #expect(long.blocks.count == 2)
    }

    /// Le titre est la voie qui a le plus occupé le bloc. Prendre la première
    /// venue donnerait le nom d'un passage de trente secondes pour une heure.
    @Test("Le titre du bloc est la voie qui l'a le plus occupé")
    func titreDuBloc() {
        let summary = day([
            event(lane: "a", name: "court", cwd: "/x/court", from: at(9), to: at(9, 5)),
            event(lane: "b", name: "long", cwd: "/x/long", from: at(9, 5), to: at(10)),
        ])

        #expect(summary.blocks.count == 1)
        #expect(summary.blocks[0].title == "long")
    }

    /// Le travail qui n'est pas le vôtre ne fabrique pas de bloc : un lecteur
    /// vidéo ouvert toute la journée dessinerait sinon une journée pleine.
    @Test("Ce qui avance sans vous ne fait pas de bloc")
    func sansVousPasDeBloc() {
        let summary = day([
            event(lane: "win:x:video", name: "video", cwd: nil,
                  from: at(9), to: at(18), src: .pixels, fg: false)
        ])

        #expect(summary.blocks.isEmpty)
        // Mais la voie existe : elle est visible dans la piste, en retrait.
        #expect(summary.lanes.count == 1)
        #expect(summary.lanes[0].seconds == 0)
    }

    // MARK: - Le multitâche

    /// **Le chiffre que personne d'autre ne donne.** Quatre séjours de deux
    /// minutes sur deux voies, ce n'est pas huit minutes de travail : c'est huit
    /// minutes où l'on n'est jamais resté assez longtemps pour entrer dans quoi
    /// que ce soit.
    @Test("Des séjours trop courts comptent comme du temps fragmenté")
    func sejoursCourtsSontFragmentes() {
        let summary = day([
            event(lane: "a", name: "a", from: at(9, 0), to: at(9, 2)),
            event(lane: "b", name: "b", from: at(9, 2), to: at(9, 4)),
            event(lane: "a", name: "a", from: at(9, 4), to: at(9, 6)),
            event(lane: "b", name: "b", from: at(9, 6), to: at(9, 8)),
        ])

        #expect(summary.switching.count == 3)
        #expect(summary.switching.fragmentedSeconds == 480)
    }

    /// Rester deux heures sur la même voie ne fabrique aucun changement, même
    /// si le journal la coupe en plusieurs intervalles — ce qu'il fait à chaque
    /// changement de raison.
    @Test("Deux intervalles de la même voie ne font pas un changement")
    func memeVoiePasDeChangement() {
        let summary = day([
            event(lane: "a", name: "a", from: at(9), to: at(10)),
            event(lane: "a", name: "a", from: at(10), to: at(11)),
        ])

        #expect(summary.switching.count == 0)
        #expect(summary.switching.fragmentedSeconds == 0)
    }

    /// Le parallélisme machine n'est pas du multitâche : trois agents qui
    /// compilent pendant qu'on lit ne coûtent rien à l'attention. Seul ce qui
    /// porte `fg` compte.
    @Test("Les voies qui tournent sans vous ne comptent pas comme du multitâche")
    func parallelismeNEstPasMultitache() {
        let summary = day([
            event(lane: "a", name: "a", from: at(9), to: at(12)),
            event(lane: "b", name: "b", from: at(9), to: at(12), src: .pixels, fg: false),
            event(lane: "c", name: "c", from: at(9), to: at(12), src: .pixels, fg: false),
        ])

        #expect(summary.switching.count == 0)
    }

    @Test("Une fréquence sur zéro travail n'existe pas")
    func frequenceSurZero() {
        #expect(DaySummary.Switching.none.perHour == nil)
    }

    // MARK: - Les bornes de l'axe

    /// Une règle figée de 6 h à 21 h coupe les nuits de qui travaille tard.
    @Test("L'axe suit ce qui a été observé")
    func axeSuitLObservation() {
        let summary = day([event(from: at(14), to: at(23, 30))])
        #expect(summary.firstHour == 14)
        #expect(summary.lastHour == 24)
    }

    /// …mais une journée de vingt minutes ne doit pas s'étaler sur toute la
    /// largeur : l'amplitude minimale l'en empêche, et elle s'étale des deux
    /// côtés pour rester centrée.
    @Test("Une journée courte garde une amplitude minimale, centrée")
    func journeeCourteResteCentree() {
        let summary = day([event(from: at(14), to: at(14, 20))])
        #expect(summary.lastHour - summary.firstHour >= 8)
        #expect(summary.firstHour < 14)
        #expect(summary.lastHour > 15)
    }

    @Test("Une journée sans rien a quand même un axe")
    func journeeSansRienAUnAxe() {
        let summary = day([])
        #expect(summary.lastHour > summary.firstHour)
    }

    // MARK: - Les voies

    @Test("Les voies sont triées sur votre travail, pas sur leur durée totale")
    func voiesTrieesSurVotreTravail() {
        let summary = day([
            event(lane: "fond", name: "fond", cwd: nil, from: at(8), to: at(18), src: .pixels, fg: false),
            event(lane: "vrai", name: "vrai", cwd: "/x/vrai", from: at(9), to: at(10)),
        ])

        #expect(summary.lanes.first?.name == "vrai")
    }

    // MARK: - Les pauses

    @Test("Les pauses de la journée arrivent jusqu'ici")
    func pausesArriventJusquIci() {
        let presence = [
            PresenceEvent(presence: .present, from: at(9), to: at(12), d: 10800),
            PresenceEvent(presence: .away, from: at(12), to: at(13), d: 3600),
            PresenceEvent(presence: .present, from: at(13), to: at(18), d: 18000),
        ]

        let summary = day([event(from: at(9), to: at(12))], presence: presence, now: at(14))

        #expect(summary.breaks.breaks.count == 1)
        #expect(summary.breaks.sinceLastBreak == 3600)
    }
}
