import Foundation
import Testing
@testable import BranWatch

/// **Le journal de bord est la seule vue de bran dont les chiffres se croient
/// au lieu de se vérifier.** Personne ne recompte à la main trente et une
/// heures de travail : un total faux de 12 % passerait un an sans être vu, et
/// pendant ce temps il servirait à décider quoi faire de ses journées.
///
/// D'où l'endroit des tests : ici, sur une fonction qui ne connaît ni disque ni
/// horloge — et pas dans la vue, qui ne fait que peindre ce qu'on lui rend.
@Suite("Résumé de la semaine")
struct WeekSummaryTests {

    // MARK: - Outils

    /// Un calendrier fixe. `Calendar.current` rendrait les tests dépendants de
    /// la machine qui les exécute, et un test qui passe à Paris mais pas à
    /// Auckland ne prouve rien.
    private var paris: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris") ?? .gmt
        return calendar
    }

    private func date(
        _ d: Int, _ h: Int, _ m: Int = 0, month: Int = 8, calendar: Calendar? = nil
    ) -> Date {
        let calendar = calendar ?? paris
        return calendar.date(from: DateComponents(
            year: 2026, month: month, day: d, hour: h, minute: m
        )) ?? .distantPast
    }

    /// Un intervalle fermé. `d` vaut par défaut la durée murale, parce que
    /// c'est le cas normal ; les tests de veille le contredisent exprès.
    private func event(
        lane: String = "cc:/Users/x/castral/crm",
        name: String = "crm · main",
        state: LaneState = .working,
        from: Date,
        to: Date,
        d: TimeInterval? = nil,
        cwd: String? = "/Users/x/castral/crm",
        src: WatchEvent.Source = .certain,
        fg: Bool? = nil
    ) -> WatchEvent {
        WatchEvent(
            lane: lane, name: name, p: 2, state: state,
            from: from, to: to, d: d ?? to.timeIntervalSince(from),
            src: src, why: "test", cwd: cwd, branch: "main",
            fg: fg
        )
    }

    /// Aujourd'hui, pour tous les tests : jeudi 6 août 2026, 18 h.
    private var now: Date { date(6, 18) }

    private func summary(
        _ events: [WatchEvent],
        markers: [WeekMarker] = [],
        span: WeekSpan = .week
    ) -> WeekSummary {
        WeekSummary.make(events: events, markers: markers, now: now, span: span, calendar: paris)
    }

    // MARK: - La semaine vide

    @Test("Une semaine sans rien rend sept barres à zéro, pas une liste vide")
    func emptyWeek() {
        let result = summary([])

        #expect(result.days.count == 7)
        #expect(result.days.allSatisfy { $0.total == 0 })
        #expect(result.projects.isEmpty)
        #expect(result.trackedSeconds == 0)
        #expect(result.waitingSeconds == 0)
        #expect(result.parallelism == .none)
        #expect(result.isEmpty)
    }

    @Test("La fenêtre se termine aujourd'hui, et aujourd'hui est marqué une seule fois")
    func windowEndsToday() {
        let result = summary([])

        #expect(result.days.map(\.key) == [
            "2026-07-31", "2026-08-01", "2026-08-02", "2026-08-03",
            "2026-08-04", "2026-08-05", "2026-08-06",
        ])
        #expect(result.days.filter(\.isToday).count == 1)
        #expect(result.days.last?.isToday == true)
    }

    @Test("Les clés de jour sont celles de WatchDay — donc celles des fichiers du journal")
    func dayKeysMatchTheJournal() {
        // Si ces deux-là divergeaient, la vue chercherait une journée dans un
        // fichier qui ne la contient pas, et rien ne le signalerait.
        let result = summary([])
        for bar in result.days {
            #expect(bar.key == WatchDay.key(for: bar.date, calendar: paris))
        }
    }

    @Test("La portée « mois » rend trente barres")
    func monthSpan() {
        let result = summary([], span: .month)
        #expect(result.days.count == 30)
        #expect(result.days.first?.key == "2026-07-08")
        #expect(result.days.last?.key == "2026-08-06")
    }

    // MARK: - Le temps par projet

    @Test("Deux branches du même dossier sont un seul projet")
    func branchesMergeIntoOneProject() {
        // Le `name` d'une voie Claude Code contient la branche : grouper
        // dessus ferait apparaître deux projets pour un seul travail.
        let result = summary([
            event(name: "crm · main", from: date(6, 9), to: date(6, 10)),
            event(name: "crm · feat/api", from: date(6, 10), to: date(6, 11)),
        ])

        #expect(result.projects.count == 1)
        #expect(result.projects[0].name == "crm")
        #expect(result.projects[0].worked == 7200)
    }

    /// **Un onglet n'est pas un projet.** Ce test verrouillait l'inverse : il
    /// affirmait que la clé de voie — donc le titre de la fenêtre — faisait
    /// office de projet. Mesuré sur deux jours de journal réel, ça donnait 125
    /// « projets » pour 18 propriétaires, et la ligne « 4 projets » de l'en-tête
    /// annonçait des dizaines. Faute de mieux, l'application est le bon grain :
    /// voir `WeekSummary.projectKey`.
    @Test("Sans dossier de travail, c'est l'application qui fait office de projet")
    func applicationIsTheFallbackProject() {
        let result = summary([
            event(lane: "win:com.apple.Terminal:build", name: "build", from: date(6, 9), to: date(6, 10), cwd: nil)
        ])

        #expect(result.projects.count == 1)
        #expect(result.projects[0].key == "win:com.apple.Terminal")
        #expect(result.projects[0].name == "Terminal")
    }

    /// La conséquence qui compte : trois titres du même navigateur font **un**
    /// projet, pas trois. C'est ce que le compteur de l'en-tête annonce.
    @Test("Trois titres d'une même application ne font qu'un projet")
    func troisTitresUnSeulProjet() {
        let result = summary([
            event(lane: "win:com.google.Chrome:GitHub", name: "GitHub", from: date(6, 9), to: date(6, 10), cwd: nil),
            event(lane: "win:com.google.Chrome:Gmail", name: "Gmail", from: date(6, 10), to: date(6, 11), cwd: nil),
            event(lane: "win:com.google.Chrome:Docs", name: "Docs", from: date(6, 11), to: date(6, 12), cwd: nil),
        ])

        #expect(result.projects.count == 1)
        #expect(result.projects[0].name == "Chrome")
        #expect(result.projects[0].worked == 10800)
        // Trois voies distinctes ont fait avancer ce « projet », et le dire
        // reste juste : c'est exactement ce que porte `laneCount`.
        #expect(result.projects[0].laneCount == 3)
    }

    /// Une clé qui n'est pas celle d'une fenêtre n'est pas découpée au hasard :
    /// une session Claude Code a déjà son dossier, et une forme inconnue reste
    /// intacte plutôt que d'être tronquée par une règle qui ne la vise pas.
    @Test("Une clé qui n'est pas une fenêtre n'est pas découpée")
    func cleNonFenetreIntacte() {
        let result = summary([
            event(lane: "autre-chose", name: "autre", from: date(6, 9), to: date(6, 10), cwd: nil)
        ])

        #expect(result.projects[0].key == "autre-chose")
        #expect(result.projects[0].name == "autre")
    }

    // MARK: - Ce qui compte comme du travail

    /// **La décision la plus importante du produit, verrouillée ici.**
    ///
    /// Avant, le total comptait toute fenêtre dont plus de 1 % des blocs de
    /// luminance avaient bougé. Sur deux jours de journal réel, 7,6 h des 12,1 h
    /// annoncées venaient de là, et « Téléchargements » passait devant le
    /// dossier client. Un lecteur vidéo, une barre de progression ou un fil qui
    /// se rafraîchit ne sont pas votre journée de travail.
    @Test("Une fenêtre qui bouge sans vous n'entre pas dans le total")
    func fenetreQuiBougeSansVousNEntrePas() {
        let result = summary([
            event(lane: "win:x:video", name: "video", from: date(6, 9), to: date(6, 12),
                  cwd: nil, src: .pixels, fg: false)
        ])

        #expect(result.workedSeconds == 0)
        #expect(result.machineSeconds == 10800)
        #expect(result.days.first(where: \.isToday)?.machine == 10800)
    }

    @Test("Une fenêtre que vous teniez est votre travail")
    func fenetreTenueEstVotreTravail() {
        let result = summary([
            event(lane: "win:x:editeur", name: "editeur", from: date(6, 9), to: date(6, 12),
                  cwd: nil, src: .pixels, fg: true)
        ])

        #expect(result.workedSeconds == 10800)
        #expect(result.machineSeconds == 0)
    }

    /// Une session d'agent avance parce que vous la lui avez demandée, même si
    /// vous êtes ailleurs. C'est le travail que vous avez lancé, et le capteur
    /// certain suffit à le dire.
    @Test("Un capteur certain compte, même sans vous devant")
    func capteurCertainCompteSansVous() {
        let result = summary([
            event(from: date(6, 9), to: date(6, 12), src: .certain, fg: false)
        ])

        #expect(result.workedSeconds == 10800)
        #expect(result.machineSeconds == 0)
    }

    /// Un journal écrit avant `WatchEvent.fg` ne peut pas trancher. Sous-estimer
    /// le passé est le bon sens de l'erreur : gonfler mars ferait croire à une
    /// baisse en avril qui n'a pas eu lieu.
    @Test("Un journal sans le champ ne gonfle pas le passé")
    func journalAncienNeGonflePas() {
        let result = summary([
            event(lane: "win:x:vieux", name: "vieux", from: date(6, 9), to: date(6, 10),
                  cwd: nil, src: .pixels, fg: nil)
        ])

        #expect(result.workedSeconds == 0)
        #expect(result.machineSeconds == 3600)
    }

    /// Les deux parts vivent dans la même ligne de projet, et ne s'ajoutent
    /// jamais : un projet essentiellement « sans vous » est un projet que vous
    /// surveillez, pas un projet sur lequel vous travaillez.
    @Test("Un projet porte les deux parts séparément")
    func projetPorteLesDeuxParts() {
        let result = summary([
            event(from: date(6, 9), to: date(6, 10), src: .certain, fg: true),
            event(from: date(6, 10), to: date(6, 12), src: .pixels, fg: false),
        ])

        #expect(result.projects.count == 1)
        #expect(result.projects[0].worked == 3600)
        #expect(result.projects[0].machine == 7200)
    }

    // MARK: - Le temps non observé

    /// **Le défaut le plus grave que l'audit ait trouvé.** « Non observé » est
    /// une propriété de l'observateur, pas des voies : quinze fenêtres
    /// illisibles pendant dix minutes font dix minutes d'aveuglement, pas deux
    /// heures trente. La version précédente les additionnait, et le chiffre
    /// affiché montait avec le nombre d'onglets ouverts.
    @Test("Le temps non observé se compte une fois, pas une fois par fenêtre")
    func tempsNonObserveSeCompteUneFois() {
        let result = summary([
            event(lane: "a", name: "a", state: .unknown, from: date(6, 9), to: date(6, 10), cwd: nil),
            event(lane: "b", name: "b", state: .unknown, from: date(6, 9), to: date(6, 10), cwd: nil),
            event(lane: "c", name: "c", state: .unknown, from: date(6, 9), to: date(6, 10), cwd: nil),
        ])

        #expect(result.unknownSeconds == 3600)
        #expect(result.days.first(where: \.isToday)?.unknown == 3600)
    }

    @Test("Deux périodes non observées disjointes s'ajoutent")
    func periodesDisjointesSAjoutent() {
        let result = summary([
            event(lane: "a", name: "a", state: .unknown, from: date(6, 9), to: date(6, 10), cwd: nil),
            event(lane: "b", name: "b", state: .unknown, from: date(6, 14), to: date(6, 15), cwd: nil),
        ])

        #expect(result.unknownSeconds == 7200)
    }

    @Test("Deux périodes non observées qui se chevauchent à moitié ne comptent qu'une fois le recouvrement")
    func chevauchementCompteUneFois() {
        let result = summary([
            event(lane: "a", name: "a", state: .unknown, from: date(6, 9), to: date(6, 11), cwd: nil),
            event(lane: "b", name: "b", state: .unknown, from: date(6, 10), to: date(6, 12), cwd: nil),
        ])

        #expect(result.unknownSeconds == 10800)
    }

    @Test("Les projets sont triés du plus long au plus court")
    func projectsAreSorted() {
        let result = summary([
            event(lane: "a", name: "a", from: date(6, 9), to: date(6, 10), cwd: "/x/petit"),
            event(lane: "b", name: "b", from: date(6, 9), to: date(6, 12), cwd: "/x/gros"),
            event(lane: "c", name: "c", from: date(6, 9), to: date(6, 11), cwd: "/x/moyen"),
        ])

        #expect(result.projects.map(\.name) == ["gros", "moyen", "petit"])
    }

    @Test("À égalité, l'ordre est celui des noms et ne bouge pas d'un rendu à l'autre")
    func tiesAreStable() {
        // L'ordre d'un dictionnaire n'en est pas un : sans second critère, deux
        // projets à égalité échangeraient leur place au hasard.
        let events = [
            event(lane: "a", name: "a", from: date(6, 9), to: date(6, 10), cwd: "/x/zulu"),
            event(lane: "b", name: "b", from: date(6, 9), to: date(6, 10), cwd: "/x/alpha"),
        ]

        for _ in 0..<20 {
            #expect(summary(events).projects.map(\.name) == ["alpha", "zulu"])
        }
    }

    @Test("Le projet porte le nombre de voies distinctes qui l'ont fait avancer")
    func laneCount() {
        let result = summary([
            event(lane: "cc:/x/crm#1", from: date(6, 9), to: date(6, 10), cwd: "/x/crm"),
            event(lane: "cc:/x/crm#2", from: date(6, 9), to: date(6, 10), cwd: "/x/crm"),
            event(lane: "cc:/x/crm#1", from: date(6, 11), to: date(6, 12), cwd: "/x/crm"),
        ])

        #expect(result.projects[0].laneCount == 2)
    }

    // MARK: - Le temps par jour

    @Test("Chaque intervalle tombe dans la barre de son jour")
    func perDayBuckets() {
        let result = summary([
            event(from: date(4, 9), to: date(4, 11)),
            event(from: date(6, 14), to: date(6, 15)),
        ])

        let byKey = Dictionary(uniqueKeysWithValues: result.days.map { ($0.key, $0) })
        #expect(byKey["2026-08-04"]?.worked == 7200)
        #expect(byKey["2026-08-06"]?.worked == 3600)
        #expect(byKey["2026-08-05"]?.worked == 0)
    }

    @Test("Un intervalle à cheval sur minuit se partage entre les deux jours")
    func intervalStraddlingMidnight() {
        // `WatchStore` ferme tout à minuit, donc ça ne devrait pas arriver —
        // mais un journal d'avant ce comportement, ou récupéré après une
        // coupure, en porte, et le perdre décalerait tout l'histogramme.
        let result = summary([
            event(from: date(5, 23), to: date(6, 1))   // 23 h → 1 h : deux heures, à parts égales
        ])

        let byKey = Dictionary(uniqueKeysWithValues: result.days.map { ($0.key, $0) })
        #expect(byKey["2026-08-05"]?.worked == 3600)
        #expect(byKey["2026-08-06"]?.worked == 3600)
        // Rien ne se perd en route : la somme des barres vaut le total.
        #expect(result.days.reduce(0) { $0 + $1.worked } == result.workedSeconds)
    }

    @Test("Un intervalle antérieur à la fenêtre est écarté, celui qui la traverse est rogné")
    func windowClipping() {
        let result = summary([
            event(from: date(1, 9, month: 7), to: date(1, 10, month: 7)),     // hors fenêtre
            event(from: date(30, 22, month: 7), to: date(31, 2, month: 7)),   // à cheval sur la borne
        ])

        #expect(result.days.first?.key == "2026-07-31")
        // Quatre heures murales, dont deux dans la fenêtre.
        #expect(result.workedSeconds == 7200)
    }

    // MARK: - Ce qui compte et ce qui ne compte pas

    @Test("La dette d'attente est le cumul des états « vous attend »")
    func waitingDebtIsCumulative() {
        let result = summary([
            event(state: .working, from: date(4, 9), to: date(4, 10)),
            event(state: .waiting, from: date(4, 10), to: date(4, 10, 20)),
            event(state: .waiting, from: date(6, 15), to: date(6, 15, 27)),
        ])

        #expect(result.waitingSeconds == 47 * 60)
        #expect(result.workedSeconds == 3600)
        // « suivies » = ce qui a avancé plus ce qui a attendu.
        #expect(result.trackedSeconds == 3600 + 47 * 60)
    }

    @Test("Ce que bran n'a pas su lire est compté à part, en trou visible")
    func unknownIsATrackedHole() {
        // CR-1 : ne jamais deviner à la place d'un capteur absent. L'écarter
        // reviendrait à faire passer une panne pour du repos.
        let result = summary([
            event(state: .working, from: date(6, 9), to: date(6, 10)),
            event(state: .unknown, from: date(6, 10), to: date(6, 11)),
        ])

        #expect(result.unknownSeconds == 3600)
        #expect(result.trackedSeconds == 3600)
        #expect(result.days.last?.unknown == 3600)
        #expect(result.isEmpty == false)
    }

    @Test("Une voie oubliée n'est pas du travail")
    func staleAndAbandonedDoNotCount() {
        let result = summary([
            event(state: .stale, from: date(6, 9), to: date(6, 12)),
            event(state: .abandoned, from: date(6, 12), to: date(6, 17)),
        ])

        #expect(result.trackedSeconds == 0)
        #expect(result.projects.isEmpty)
        #expect(result.days.allSatisfy { $0.total == 0 })
    }

    @Test("C'est la durée mesurée qui compte, pas l'horloge murale")
    func measuredDurationWins() {
        // Une nuit de veille au milieu d'un intervalle : `to - from` dit huit
        // heures, `SuspendingClock` dit dix minutes. C'est `d` qui a raison.
        let result = summary([
            event(from: date(6, 1), to: date(6, 9), d: 600)
        ])

        #expect(result.workedSeconds == 600)
    }

    // MARK: - Le parallélisme

    @Test("Deux voies qui se chevauchent à moitié donnent 1,5 en moyenne et 2 au pic")
    func overlapIsMeasured() {
        // Le pari du produit : on croit en faire tourner quatre, on en fait
        // tourner une virgule six. Ce chiffre-là doit être exact.
        let result = summary([
            event(lane: "a", from: date(6, 9), to: date(6, 11), cwd: "/x/a"),
            event(lane: "b", from: date(6, 10), to: date(6, 12), cwd: "/x/b"),
        ])

        #expect(result.parallelism.peak == 2)
        #expect(result.parallelism.busySeconds == 3 * 3600)
        #expect(abs(result.parallelism.average - 4.0 / 3.0) < 0.0001)
    }

    @Test("Deux lignes consécutives d'une même voie ne font pas deux voies")
    func adjacentIntervalsDoNotInflateThePeak() {
        // Le journal coupe un intervalle dès que la *raison* change, sans que
        // la voie s'arrête. Si les ouvertures passaient avant les fermetures à
        // instant égal, chacune de ces coupures inventerait une voie de plus.
        let result = summary([
            event(from: date(6, 9), to: date(6, 10)),
            event(from: date(6, 10), to: date(6, 11)),
            event(from: date(6, 11), to: date(6, 12)),
        ])

        #expect(result.parallelism.peak == 1)
        #expect(result.parallelism.average == 1)
        #expect(result.parallelism.busySeconds == 3 * 3600)
    }

    @Test("Une seule voie, jamais doublée, donne exactement 1")
    func singleLane() {
        let result = summary([
            event(from: date(4, 9), to: date(4, 12)),
            event(from: date(6, 14), to: date(6, 16)),
        ])

        #expect(result.parallelism.average == 1)
        #expect(result.parallelism.peak == 1)
    }

    @Test("Le temps d'attente n'entre pas dans le parallélisme")
    func waitingIsNotParallelWork() {
        // Trois voies qui attendent ne sont pas trois voies qui avancent —
        // c'est exactement l'illusion que ce chiffre existe pour casser.
        let result = summary([
            event(lane: "a", state: .waiting, from: date(6, 9), to: date(6, 11), cwd: "/x/a"),
            event(lane: "b", state: .waiting, from: date(6, 9), to: date(6, 11), cwd: "/x/b"),
            event(lane: "c", state: .working, from: date(6, 9), to: date(6, 11), cwd: "/x/c"),
        ])

        #expect(result.parallelism.peak == 1)
        #expect(result.parallelism.average == 1)
    }

    // MARK: - Les jalons

    @Test("Les jalons se groupent par jour, du plus récent au plus ancien")
    func milestonesAreGroupedByDay() {
        let markers = [
            WeekMarker(id: "1", kind: .meeting, title: "ORPHEO GNB", at: date(4, 10), duration: 1800),
            WeekMarker(id: "2", kind: .dictation, title: "note", at: date(6, 9)),
            WeekMarker(id: "3", kind: .snapshot, title: "erreur", at: date(6, 15)),
        ]
        let result = summary([], markers: markers)

        #expect(result.timeline.map(\.key) == ["2026-08-06", "2026-08-04"])
        #expect(result.timeline[0].markers.map(\.id) == ["3", "2"])
        #expect(result.isEmpty == false)
    }

    @Test("Un jalon hors fenêtre ne remonte pas")
    func milestonesOutsideTheWindow() {
        let result = summary([], markers: [
            WeekMarker(id: "vieux", kind: .meeting, title: "début juillet", at: date(1, 10, month: 7)),
            WeekMarker(id: "bord", kind: .meeting, title: "premier jour", at: date(31, 0, 1, month: 7)),
        ])

        #expect(result.timeline.count == 1)
        #expect(result.timeline[0].markers.map(\.id) == ["bord"])
    }

    // MARK: - Le fuseau

    @Test("Le fuseau du calendrier décide du jour, pas UTC")
    func timeZoneDecidesTheDay() {
        // 6 août, 0 h 30 à Paris, c'est encore le 5 août à Londres. Le journal
        // écrit dans le fichier du calendrier de l'utilisateur ; si le résumé
        // pensait en UTC, une heure de travail changerait de barre.
        var london = Calendar(identifier: .gregorian)
        london.timeZone = TimeZone(identifier: "Europe/London") ?? .gmt

        let instant = date(6, 0, 30)
        let sample = event(from: instant, to: instant.addingTimeInterval(1800))

        let parisian = WeekSummary.make(events: [sample], now: now, calendar: paris)
        let londoner = WeekSummary.make(events: [sample], now: now, calendar: london)

        #expect(parisian.days.last?.key == "2026-08-06")
        #expect(parisian.days.last?.worked == 1800)

        // À Londres, il est 23 h 30 le 5 : le travail tombe la veille.
        #expect(londoner.days.first(where: { $0.key == "2026-08-05" })?.worked == 1800)
        #expect(londoner.days.last?.worked == 0)
    }

    // MARK: - Les bords sales

    @Test("Un intervalle instantané garde sa durée mesurée au lieu de disparaître")
    func instantInterval() {
        // Un seul battement porte déjà un `d` non nul : le jeter perdrait le
        // premier tic de chaque voie, tous les jours.
        let result = summary([
            event(from: date(6, 9), to: date(6, 9), d: 4)
        ])

        #expect(result.workedSeconds == 4)
        #expect(result.days.last?.worked == 4)
        #expect(result.parallelism.peak == 0)
    }

    @Test("Un intervalle à l'envers ne casse rien")
    func reversedInterval() {
        // Une ligne écrite par une version boguée, ou une horloge système
        // reculée : le résumé ne doit ni planter ni compter du temps négatif.
        let result = summary([
            event(from: date(6, 12), to: date(6, 9), d: 100)
        ])

        #expect(result.workedSeconds >= 0)
        #expect(result.days.allSatisfy { $0.total >= 0 })
    }
}
