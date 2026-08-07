import Foundation

/// **Le journal de bord** : ce que la semaine a été, en un seul objet.
///
/// Elle prend des intervalles fermés (`WatchEvent`) et des repères datés
/// (`WeekMarker` : réunions, dictées, captures), et rend de quoi peindre une
/// vue — sans jamais toucher au disque ni lire `Date.now`.
///
/// **Pourquoi cette séparation ici plutôt qu'une agrégation dans la vue.** Les
/// quatre chiffres que cette structure calcule sont exactement ceux sur
/// lesquels l'utilisateur va décider quelque chose : « sur quoi j'ai bossé »,
/// « combien j'ai attendu », « est-ce que le parallélisme que je crois avoir
/// existe ». Un chiffre faux ne se voit pas — il se croit. C'est donc le seul
/// endroit du module qui mérite des tests, et il ne peut en avoir que s'il
/// n'a besoin ni d'un dossier, ni d'une horloge, ni d'un écran.
public struct WeekSummary: Equatable, Sendable {

    /// La fenêtre observée, bornes incluse/exclue.
    public let start: Date
    public let end: Date
    public let span: WeekSpan

    /// Une barre par jour, **toujours** : les jours sans rien y sont, à zéro.
    /// Un histogramme dont les jours vides disparaissent ment sur le rythme —
    /// il montre six barres pleines là où il y a eu quatre jours de travail et
    /// trois jours d'arrêt.
    public let days: [DayBar]

    /// Les projets, triés du plus long au plus court.
    public let projects: [ProjectRow]

    /// Le temps qu'on a le droit d'appeler « suivi » : ce qui a avancé plus ce
    /// qui a attendu. Ni `stale`, ni `abandoned` — une voie oubliée trois
    /// heures n'est pas trois heures de travail, et les compter gonflerait le
    /// seul chiffre que l'utilisateur va citer.
    public let trackedSeconds: TimeInterval

    /// Le temps de travail **attribué** : une session d'agent qui avance, ou une
    /// fenêtre que l'humain tenait. C'est le chiffre principal de tous les
    /// écrans, et c'est celui qui a changé de définition.
    ///
    /// Avant, il comptait toute fenêtre visible dont plus de 1 % des blocs de
    /// luminance avaient bougé. Sur deux jours de journal réel, 7,6 h des 12,1 h
    /// annoncées venaient de là : « Téléchargements » (123 min) et « empty
    /// project » (120 min) passaient devant le dossier client (89 min). Un
    /// dénominateur, un ratio pause/travail, une répartition par catégorie et
    /// une comparaison au mois dernier bâtis là-dessus héritent tous de la même
    /// erreur — et l'historique devient incomparable le jour où on la corrige.
    ///
    /// Voir `WatchEvent.fg`.
    public let workedSeconds: TimeInterval

    /// Le temps où **une machine avançait sans vous**, séparé et jamais ajouté
    /// au total.
    ///
    /// Ce n'est pas du déchet : trois agents qui compilent pendant que vous
    /// relisez une documentation, c'est exactement ce qu'on veut. Mais ce n'est
    /// pas votre journée de travail, et les mélanger fabrique des journées de
    /// dix-neuf heures.
    ///
    /// Un journal antérieur à `WatchEvent.fg` n'a pas de quoi trancher : ses
    /// intervalles de pixels tombent ici plutôt que dans `workedSeconds`, ce qui
    /// sous-estime le passé au lieu de le surestimer. C'est le bon sens de
    /// l'erreur pour une mesure qu'on va comparer d'un mois sur l'autre.
    public let machineSeconds: TimeInterval

    /// **La dette d'attente de la semaine, cumulée.** À ne pas confondre avec
    /// `WatchVerdict.waitingNow`, qui est instantané et retombe à zéro dès
    /// qu'on reprend la main. C'est ce cumul-là, et lui seul, qui dira dans un
    /// mois si le veilleur sert à quelque chose.
    public let waitingSeconds: TimeInterval

    /// Le temps que bran **n'a pas su lire** (`LaneState.unknown`), mesuré à
    /// l'horloge murale.
    ///
    /// **C'est la seule des quatre durées qui soit une union et pas une somme,
    /// et c'en est la définition même.** `worked` et `waiting` cumulent du
    /// temps-voie : deux sessions qui avancent une heure en parallèle *ont* fait
    /// deux heures de travail, et `parallelism` est là pour dire à quel prix.
    /// « Non observé » ne se cumule pas — c'est une propriété de l'observateur,
    /// pas des voies. Quinze fenêtres illisibles pendant dix minutes font dix
    /// minutes d'aveuglement, pas deux heures trente.
    ///
    /// La version précédente les additionnait, et le chiffre annoncé montait
    /// avec le nombre de fenêtres ouvertes : une journée à vingt onglets
    /// affichait plus d'heures « non observées » qu'elle n'en comptait.
    ///
    /// Il reste compté et montré au lieu d'être écarté : un trou visible est
    /// réparable, un trou silencieux se confond avec du repos.
    public let unknownSeconds: TimeInterval

    public let parallelism: Parallelism

    /// Les jalons, groupés par jour, du plus récent au plus ancien.
    public let timeline: [MilestoneDay]

    /// Vrai quand il n'y a strictement rien à montrer — ni intervalle, ni
    /// jalon. C'est ce qui distingue « rien cette semaine » de « une semaine
    /// calme », et les deux méritent des mots différents.
    public var isEmpty: Bool {
        projects.isEmpty && timeline.isEmpty && unknownSeconds == 0
    }

    public static let empty = WeekSummary(
        start: .distantPast, end: .distantPast, span: .week,
        days: [], projects: [],
        trackedSeconds: 0, workedSeconds: 0, machineSeconds: 0,
        waitingSeconds: 0, unknownSeconds: 0,
        parallelism: .none, timeline: []
    )

    // MARK: - Les pièces

    /// Une barre de l'histogramme.
    public struct DayBar: Equatable, Sendable, Identifiable {
        /// La clé `AAAA-MM-JJ`, **produite par `WatchDay`**. C'est la même que
        /// celle du nom de fichier : si les deux divergeaient, la vue
        /// chercherait des journées dans des fichiers qui ne les contiennent
        /// pas, et personne ne s'en apercevrait avant un changement d'heure.
        public let key: String
        public let date: Date
        /// Le travail attribué : voir `WeekSummary.workedSeconds`.
        public let worked: TimeInterval
        /// Ce qui a avancé sans vous : voir `WeekSummary.machineSeconds`.
        public let machine: TimeInterval
        public let waiting: TimeInterval
        public let unknown: TimeInterval
        public let isToday: Bool

        public var id: String { key }
        public var total: TimeInterval { worked + machine + waiting + unknown }
    }

    /// Un projet, tel que la semaine l'a vu.
    public struct ProjectRow: Equatable, Sendable, Identifiable {
        /// Le dossier de travail quand il est connu, sinon le nom de la voie.
        public let key: String
        public let name: String
        public let worked: TimeInterval
        /// La part qui a avancé sans vous. Un projet dont c'est l'essentiel est
        /// un projet que vous surveillez, pas un projet sur lequel vous
        /// travaillez, et la barre a le droit de le dire.
        public let machine: TimeInterval
        public let waiting: TimeInterval
        /// Combien de voies distinctes ont porté ce projet dans la semaine.
        public let laneCount: Int

        public var id: String { key }
        public var tracked: TimeInterval { worked + waiting }
    }

    /// **Le parallélisme réel.** Le pari, c'est que l'utilisateur croit faire
    /// tourner quatre sessions et qu'il en fait tourner une virgule six.
    public struct Parallelism: Equatable, Sendable {
        /// Voies actives simultanément, en moyenne — pondérée par le temps, et
        /// **conditionnée aux moments où au moins une voie avance**. Diviser
        /// par la semaine entière donnerait 0,3 et ne répondrait à rien : la
        /// question n'est pas « combien de voies la nuit », c'est « combien de
        /// voies pendant que je travaille ».
        public let average: Double
        /// Le maximum réellement observé.
        public let peak: Int
        /// L'union des périodes où au moins une voie avançait.
        public let busySeconds: TimeInterval

        public static let none = Parallelism(average: 0, peak: 0, busySeconds: 0)
    }

    public struct MilestoneDay: Equatable, Sendable, Identifiable {
        public let key: String
        public let date: Date
        public let markers: [WeekMarker]
        public var id: String { key }

        /// Public parce que la vue en refabrique un lorsqu'elle filtre le fil
        /// sur la recherche : un jour dont il ne reste que deux jalons est
        /// encore un jour, et le regrouper à nouveau depuis la vue serait
        /// remettre du calcul là où on vient de l'enlever.
        public init(key: String, date: Date, markers: [WeekMarker]) {
            self.key = key
            self.date = date
            self.markers = markers
        }
    }
}

// MARK: - La portée

/// Semaine ou mois. Une fenêtre **glissante** qui se termine aujourd'hui, et
/// non la semaine civile : un mardi, la semaine civile affiche cinq barres
/// vides, ce qui se lit « vous n'avez rien fait » alors que ça veut dire
/// « la semaine commence ».
public enum WeekSpan: String, Sendable, Equatable, CaseIterable, Identifiable, Codable {
    case week
    case month

    public var id: String { rawValue }

    public var days: Int {
        switch self {
        case .week: 7
        case .month: 30
        }
    }

    public var label: String {
        switch self {
        case .week: "7 jours"
        case .month: "30 jours"
        }
    }

    /// L'amorce de la ligne chiffrée. « Cette semaine : 31 h suivies… »
    public var headline: String {
        switch self {
        case .week: "Cette semaine"
        case .month: "Ce mois-ci"
        }
    }
}

// MARK: - Les repères des trois autres sources

/// Une réunion, une dictée ou une capture, posée sur la même horloge que le
/// veilleur. Les trois stores vivent dans `BranApp` et ont trois formes
/// différentes ; ce type est le plus petit dénominateur qui permette de les
/// afficher sur un seul fil, et il garde l'agrégation ignorante de leurs
/// dépendances (AVFoundation, Vision, FluidAudio).
public struct WeekMarker: Equatable, Sendable, Identifiable {

    public enum Kind: String, Sendable, Equatable, CaseIterable, Codable {
        case meeting
        case dictation
        case snapshot

        public var label: String {
            switch self {
            case .meeting: "Réunion"
            case .dictation: "Dictée"
            case .snapshot: "Capture"
            }
        }

        public var symbol: String {
            switch self {
            case .meeting: "film.stack"
            case .dictation: "waveform"
            case .snapshot: "text.viewfinder"
            }
        }
    }

    public let id: String
    public let kind: Kind
    public let title: String
    public let at: Date
    public let duration: TimeInterval?

    public init(id: String, kind: Kind, title: String, at: Date, duration: TimeInterval? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.at = at
        self.duration = duration
    }
}

// MARK: - L'agrégation

extension WeekSummary {

    /// Construit le résumé.
    ///
    /// - Parameters:
    ///   - now: passé, jamais lu. Sans ça, la fonction serait intestable — et
    ///     c'est exactement la fonction qu'il faut tester.
    ///   - calendar: le **même** que celui de `WatchDay` par défaut, pour que
    ///     les clés de jour concordent avec les noms de fichiers du journal.
    public static func make(
        events: [WatchEvent],
        markers: [WeekMarker] = [],
        now: Date,
        span: WeekSpan = .week,
        calendar: Calendar = .current
    ) -> WeekSummary {
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -(span.days - 1), to: today) ?? today
        // Fin exclusive : minuit *demain*. Un intervalle ouvert à 23 h 58 fait
        // partie d'aujourd'hui, pas de la semaine prochaine.
        let end = calendar.date(byAdding: .day, value: 1, to: today) ?? today

        let todayKey = WatchDay.key(for: now, calendar: calendar)
        let boundaries = dayBoundaries(from: start, count: span.days, calendar: calendar)

        // Un accumulateur par jour, indexé par clé — la même clé que le nom de
        // fichier du journal.
        var perDay: [String: (worked: TimeInterval, machine: TimeInterval, waiting: TimeInterval)] = [:]
        var perProject: [String: (name: String, worked: TimeInterval, machine: TimeInterval, waiting: TimeInterval, lanes: Set<String>)] = [:]

        var worked: TimeInterval = 0
        var machine: TimeInterval = 0
        var waiting: TimeInterval = 0

        var workingSpans: [(from: Date, to: Date)] = []
        // « Non observé » se mesure en union, pas en somme : voir
        // `unknownSeconds`. On garde donc les intervalles au lieu d'un total,
        // globalement et par jour.
        var unknownSpans: [(from: Date, to: Date)] = []
        var unknownPerDay: [String: [(from: Date, to: Date)]] = [:]

        for event in events {
            // Un intervalle qui déborde de la fenêtre est **rogné**, pas
            // écarté : la nuit de dimanche à lundi appartient pour partie à la
            // semaine affichée.
            guard let clipped = clip(event, from: start, to: end) else { continue }

            let yours = isYours(event)

            switch event.state {
            case .working:
                if yours { worked += clipped.seconds } else { machine += clipped.seconds }
            case .waiting: waiting += clipped.seconds
            case .unknown:
                if clipped.to > clipped.from {
                    unknownSpans.append((clipped.from, clipped.to))
                }
            case .stale, .abandoned: break
            }

            // Répartition sur les jours traversés. `WatchStore` ferme tout à
            // minuit, donc le cas normal est « un seul jour » ; mais un journal
            // écrit par une version antérieure, ou récupéré après une coupure,
            // peut porter un intervalle à cheval, et le perdre décalerait
            // silencieusement l'histogramme.
            for slice in split(clipped, over: boundaries, calendar: calendar) {
                if event.state == .unknown {
                    unknownPerDay[slice.key, default: []].append((slice.from, slice.to))
                    continue
                }
                var bucket = perDay[slice.key] ?? (0, 0, 0)
                switch event.state {
                case .working:
                    if yours { bucket.worked += slice.seconds } else { bucket.machine += slice.seconds }
                case .waiting: bucket.waiting += slice.seconds
                case .unknown, .stale, .abandoned: continue
                }
                perDay[slice.key] = bucket
            }

            if event.state == .working, clipped.to > clipped.from {
                workingSpans.append((clipped.from, clipped.to))
            }

            guard event.state == .working || event.state == .waiting else { continue }

            let key = projectKey(for: event)
            var row = perProject[key] ?? (projectName(for: event), 0, 0, 0, [])
            switch (event.state, yours) {
            case (.working, true): row.worked += clipped.seconds
            case (.working, false): row.machine += clipped.seconds
            default: row.waiting += clipped.seconds
            }
            row.lanes.insert(event.lane)
            perProject[key] = row
        }

        let bars = boundaries.map { day in
            let bucket = perDay[day.key] ?? (0, 0, 0)
            return DayBar(
                key: day.key,
                date: day.start,
                worked: bucket.worked,
                machine: bucket.machine,
                waiting: bucket.waiting,
                unknown: union(of: unknownPerDay[day.key] ?? []),
                isToday: day.key == todayKey
            )
        }

        // Tri décroissant sur le temps suivi, puis sur le nom : sans le second
        // critère, deux projets à égalité changent de place à chaque rendu,
        // parce que l'ordre d'un dictionnaire n'en est pas un.
        var rows: [ProjectRow] = []
        rows.reserveCapacity(perProject.count)
        for (key, value) in perProject {
            rows.append(ProjectRow(
                key: key,
                name: value.name,
                worked: value.worked,
                machine: value.machine,
                waiting: value.waiting,
                laneCount: value.lanes.count
            ))
        }
        rows.sort { left, right in
            left.tracked == right.tracked
                ? left.name.localizedStandardCompare(right.name) == .orderedAscending
                : left.tracked > right.tracked
        }

        return WeekSummary(
            start: start,
            end: end,
            span: span,
            days: bars,
            projects: rows,
            trackedSeconds: worked + waiting,
            workedSeconds: worked,
            machineSeconds: machine,
            waitingSeconds: waiting,
            unknownSeconds: union(of: unknownSpans),
            parallelism: concurrency(of: workingSpans),
            timeline: timeline(of: markers, from: start, to: end, calendar: calendar)
        )
    }

    /// **Est-ce que ce temps est le vôtre ?**
    ///
    /// La question que le produit devait trancher, en trois lignes. Deux façons
    /// d'y répondre oui, et elles ne se recouvrent pas :
    ///
    /// 1. **Un capteur certain.** Une session d'agent qui appelle un outil ne
    ///    ment pas : elle avance parce que vous la lui avez demandée, même si
    ///    vous êtes ailleurs. C'est le travail que vous avez lancé.
    /// 2. **Vous étiez dessus.** Une fenêtre que vous teniez pendant que le
    ///    système vous voyait actif. C'est le travail que vous faisiez.
    ///
    /// Tout le reste — une fenêtre dont des pixels bougent sans que personne ne
    /// la regarde — est du mouvement, pas du travail. Un lecteur vidéo, une
    /// barre de progression, une horloge, un fil qui se rafraîchit.
    ///
    /// **Le cas `nil` est délibérément compté comme « pas le vôtre ».** Un
    /// journal écrit avant `WatchEvent.fg` n'a pas de quoi trancher, et il vaut
    /// mieux sous-estimer une semaine passée que la surestimer : le jour où on
    /// compare mars à février, une erreur qui gonfle le passé fait croire à une
    /// baisse qui n'a pas eu lieu.
    static func isYours(_ event: WatchEvent) -> Bool {
        event.src == .certain || event.fg == true
    }

    // MARK: - Découpage du temps

    private struct Day {
        let key: String
        let start: Date
        let end: Date
    }

    private static func dayBoundaries(from start: Date, count: Int, calendar: Calendar) -> [Day] {
        (0..<count).compactMap { offset in
            guard let dayStart = calendar.date(byAdding: .day, value: offset, to: start),
                  let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)
            else { return nil }
            return Day(key: WatchDay.key(for: dayStart, calendar: calendar), start: dayStart, end: dayEnd)
        }
    }

    private struct Clipped {
        let from: Date
        let to: Date
        /// La durée **mesurée**, rognée au prorata. Pas `to - from` : `d` vient
        /// de `SuspendingClock` et c'est la seule qui ne compte pas une nuit de
        /// veille comme huit heures de travail.
        let seconds: TimeInterval
    }

    private static func clip(_ event: WatchEvent, from start: Date, to end: Date) -> Clipped? {
        let from = max(event.from, start)
        let to = min(max(event.to, event.from), end)
        guard to >= from else { return nil }

        let wall = event.to.timeIntervalSince(event.from)
        guard wall > 0 else {
            // Intervalle instantané : il n'y a rien à proratiser, mais `d` peut
            // être non nul (un seul battement en porte déjà un). On le garde en
            // entier s'il tombe dans la fenêtre.
            return event.from >= start && event.from < end
                ? Clipped(from: event.from, to: event.from, seconds: event.d)
                : nil
        }

        let share = to.timeIntervalSince(from) / wall
        return Clipped(from: from, to: to, seconds: event.d * share)
    }

    private struct Slice {
        let key: String
        let seconds: TimeInterval
        /// Les bornes murales de la tranche. Une somme n'en a pas besoin ; une
        /// **union** si, et c'est ce que réclame le temps non observé.
        let from: Date
        let to: Date
    }

    private static func split(_ clipped: Clipped, over days: [Day], calendar: Calendar) -> [Slice] {
        let wall = clipped.to.timeIntervalSince(clipped.from)
        guard wall > 0 else {
            return [Slice(
                key: WatchDay.key(for: clipped.from, calendar: calendar),
                seconds: clipped.seconds,
                from: clipped.from,
                to: clipped.from
            )]
        }

        return days.compactMap { day in
            let from = max(clipped.from, day.start)
            let to = min(clipped.to, day.end)
            let overlap = to.timeIntervalSince(from)
            guard overlap > 0 else { return nil }
            return Slice(
                key: day.key,
                seconds: clipped.seconds * overlap / wall,
                from: from,
                to: to
            )
        }
    }

    /// La durée **couverte** par un ensemble d'intervalles, comptée une seule
    /// fois quels que soient leurs recouvrements.
    ///
    /// Même balayage que `concurrency`, réduit à sa question la plus simple :
    /// combien de temps la profondeur a-t-elle été non nulle. C'est ce que
    /// `Parallelism.busySeconds` rend déjà pour le travail ; ici il n'y a que ça
    /// à savoir.
    static func union(of spans: [(from: Date, to: Date)]) -> TimeInterval {
        guard spans.isEmpty == false else { return 0 }

        var points: [(at: Date, delta: Int)] = []
        points.reserveCapacity(spans.count * 2)
        for span in spans where span.to > span.from {
            points.append((span.from, 1))
            points.append((span.to, -1))
        }
        guard points.isEmpty == false else { return 0 }

        points.sort { left, right in
            left.at == right.at ? left.delta < right.delta : left.at < right.at
        }

        var depth = 0
        var covered: TimeInterval = 0
        var previous = points[0].at

        for point in points {
            let elapsed = point.at.timeIntervalSince(previous)
            if elapsed > 0, depth > 0 { covered += elapsed }
            previous = point.at
            depth += point.delta
        }

        return covered
    }

    // MARK: - Le parallélisme

    /// Balayage classique : +1 à l'ouverture, −1 à la fermeture.
    ///
    /// **Les fermetures passent avant les ouvertures à égalité d'instant**, et
    /// c'est le seul détail qui compte ici. Dans l'autre ordre, une même voie
    /// qui passe de `working` à `working` — deux lignes consécutives, ce qui
    /// arrive à chaque changement de raison — compterait pour deux voies
    /// simultanées, et le maximum observé serait systématiquement faux.
    private static func concurrency(of spans: [(from: Date, to: Date)]) -> Parallelism {
        guard spans.isEmpty == false else { return .none }

        var points: [(at: Date, delta: Int)] = []
        points.reserveCapacity(spans.count * 2)
        for span in spans {
            points.append((span.from, 1))
            points.append((span.to, -1))
        }
        points.sort { left, right in
            left.at == right.at ? left.delta < right.delta : left.at < right.at
        }

        var depth = 0
        var peak = 0
        var busy: TimeInterval = 0
        var weighted: TimeInterval = 0
        var previous = points[0].at

        for point in points {
            let elapsed = point.at.timeIntervalSince(previous)
            if elapsed > 0, depth > 0 {
                busy += elapsed
                weighted += elapsed * Double(depth)
            }
            previous = point.at
            depth += point.delta
            peak = max(peak, depth)
        }

        return Parallelism(
            average: busy > 0 ? weighted / busy : 0,
            peak: peak,
            busySeconds: busy
        )
    }

    // MARK: - Les jalons

    private static func timeline(
        of markers: [WeekMarker],
        from start: Date,
        to end: Date,
        calendar: Calendar
    ) -> [MilestoneDay] {
        let inside = markers.filter { $0.at >= start && $0.at < end }
        guard inside.isEmpty == false else { return [] }

        let grouped = Dictionary(grouping: inside) { WatchDay.key(for: $0.at, calendar: calendar) }
        return grouped
            .map { key, value in
                MilestoneDay(
                    key: key,
                    date: calendar.startOfDay(for: value[0].at),
                    markers: value.sorted { $0.at > $1.at }
                )
            }
            .sorted { $0.key > $1.key }
    }

    // MARK: - L'identité d'un projet

    /// Le dossier de travail s'il existe, sinon **l'application** — jamais la
    /// voie.
    ///
    /// Pas le `name` : celui d'une session Claude Code contient la branche
    /// (« crm · feat/api »), si bien qu'un changement de branche ferait
    /// apparaître un deuxième projet portant le même travail.
    ///
    /// **Et pas la voie non plus, ce qui était le vrai défaut.** La clé d'une
    /// fenêtre vaut `win:<paquet>:<titre nettoyé>`, donc chaque titre distinct
    /// devenait un « projet » : mesuré sur deux jours de journal réel, 125 clés
    /// pour 18 propriétaires. La ligne « 4 projets » de l'en-tête annonçait
    /// alors des dizaines, et la liste des projets était une liste de titres de
    /// fenêtres triée par durée — c'est-à-dire l'écran que ce résumé existe pour
    /// remplacer.
    ///
    /// Un onglet de navigateur n'est pas un projet. L'application, elle, en est
    /// une approximation honnête tant qu'on n'a pas le domaine — voir
    /// `Docs/ANALYSEUR.md`, capteur 3.
    static func projectKey(for event: WatchEvent) -> String {
        if let cwd = event.cwd, cwd.isEmpty == false { return cwd }
        if let owner = applicationKey(of: event.lane) { return owner }
        return event.lane
    }

    static func projectName(for event: WatchEvent) -> String {
        if let cwd = event.cwd, cwd.isEmpty == false,
           let folder = cwd.split(separator: "/").last, folder.isEmpty == false {
            return String(folder)
        }
        if let owner = applicationKey(of: event.lane) {
            return applicationName(from: owner)
        }
        return event.name.isEmpty ? event.lane : event.name
    }

    /// `win:com.google.Chrome:GitHub — bran` → `win:com.google.Chrome`.
    ///
    /// Rend `nil` sur tout ce qui n'est pas une clé de fenêtre : une session
    /// Claude Code (`cc:…`) a déjà son dossier, et une clé d'une forme inconnue
    /// ne doit pas être découpée au hasard.
    static func applicationKey(of lane: String) -> String? {
        let parts = lane.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "win", parts[1].isEmpty == false else { return nil }
        return "win:\(parts[1])"
    }

    /// `win:com.google.Chrome` → `Chrome`.
    ///
    /// Le dernier segment d'un identifiant de paquet est le nom que l'éditeur a
    /// choisi, et c'est celui que l'utilisateur reconnaît. Quand il n'y a pas de
    /// point, c'est que `LaneIdentity.window` est retombé sur le nom
    /// d'application faute d'identifiant : il est alors déjà lisible tel quel.
    static func applicationName(from key: String) -> String {
        let raw = String(key.dropFirst("win:".count))
        guard let last = raw.split(separator: ".").last, last.isEmpty == false else { return raw }
        return String(last)
    }
}
