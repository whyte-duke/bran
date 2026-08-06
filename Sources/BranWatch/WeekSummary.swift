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
    public let workedSeconds: TimeInterval

    /// **La dette d'attente de la semaine, cumulée.** À ne pas confondre avec
    /// `WatchVerdict.waitingNow`, qui est instantané et retombe à zéro dès
    /// qu'on reprend la main. C'est ce cumul-là, et lui seul, qui dira dans un
    /// mois si le veilleur sert à quelque chose.
    public let waitingSeconds: TimeInterval

    /// Le temps que bran **n'a pas su lire** (`LaneState.unknown`). Il est
    /// compté et montré au lieu d'être écarté : un trou visible est réparable,
    /// un trou silencieux se confond avec du repos.
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
        trackedSeconds: 0, workedSeconds: 0, waitingSeconds: 0, unknownSeconds: 0,
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
        public let worked: TimeInterval
        public let waiting: TimeInterval
        public let unknown: TimeInterval
        public let isToday: Bool

        public var id: String { key }
        public var total: TimeInterval { worked + waiting + unknown }
    }

    /// Un projet, tel que la semaine l'a vu.
    public struct ProjectRow: Equatable, Sendable, Identifiable {
        /// Le dossier de travail quand il est connu, sinon le nom de la voie.
        public let key: String
        public let name: String
        public let worked: TimeInterval
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
        var perDay: [String: (worked: TimeInterval, waiting: TimeInterval, unknown: TimeInterval)] = [:]
        var perProject: [String: (name: String, worked: TimeInterval, waiting: TimeInterval, lanes: Set<String>)] = [:]

        var worked: TimeInterval = 0
        var waiting: TimeInterval = 0
        var unknown: TimeInterval = 0

        var workingSpans: [(from: Date, to: Date)] = []

        for event in events {
            // Un intervalle qui déborde de la fenêtre est **rogné**, pas
            // écarté : la nuit de dimanche à lundi appartient pour partie à la
            // semaine affichée.
            guard let clipped = clip(event, from: start, to: end) else { continue }

            switch event.state {
            case .working: worked += clipped.seconds
            case .waiting: waiting += clipped.seconds
            case .unknown: unknown += clipped.seconds
            case .stale, .abandoned: break
            }

            // Répartition sur les jours traversés. `WatchStore` ferme tout à
            // minuit, donc le cas normal est « un seul jour » ; mais un journal
            // écrit par une version antérieure, ou récupéré après une coupure,
            // peut porter un intervalle à cheval, et le perdre décalerait
            // silencieusement l'histogramme.
            for slice in split(clipped, over: boundaries, calendar: calendar) {
                var bucket = perDay[slice.key] ?? (0, 0, 0)
                switch event.state {
                case .working: bucket.worked += slice.seconds
                case .waiting: bucket.waiting += slice.seconds
                case .unknown: bucket.unknown += slice.seconds
                case .stale, .abandoned: continue
                }
                perDay[slice.key] = bucket
            }

            if event.state == .working, clipped.to > clipped.from {
                workingSpans.append((clipped.from, clipped.to))
            }

            guard event.state == .working || event.state == .waiting else { continue }

            let key = projectKey(for: event)
            var row = perProject[key] ?? (projectName(for: event), 0, 0, [])
            if event.state == .working { row.worked += clipped.seconds } else { row.waiting += clipped.seconds }
            row.lanes.insert(event.lane)
            perProject[key] = row
        }

        let bars = boundaries.map { day in
            let bucket = perDay[day.key] ?? (0, 0, 0)
            return DayBar(
                key: day.key,
                date: day.start,
                worked: bucket.worked,
                waiting: bucket.waiting,
                unknown: bucket.unknown,
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
            waitingSeconds: waiting,
            unknownSeconds: unknown,
            parallelism: concurrency(of: workingSpans),
            timeline: timeline(of: markers, from: start, to: end, calendar: calendar)
        )
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
    }

    private static func split(_ clipped: Clipped, over days: [Day], calendar: Calendar) -> [Slice] {
        let wall = clipped.to.timeIntervalSince(clipped.from)
        guard wall > 0 else {
            return [Slice(key: WatchDay.key(for: clipped.from, calendar: calendar), seconds: clipped.seconds)]
        }

        return days.compactMap { day in
            let from = max(clipped.from, day.start)
            let to = min(clipped.to, day.end)
            let overlap = to.timeIntervalSince(from)
            guard overlap > 0 else { return nil }
            return Slice(key: day.key, seconds: clipped.seconds * overlap / wall)
        }
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

    /// Le dossier de travail s'il existe, sinon la voie.
    ///
    /// Pas le `name` : celui d'une session Claude Code contient la branche
    /// (« crm · feat/api »), si bien qu'un changement de branche ferait
    /// apparaître un deuxième projet portant le même travail.
    static func projectKey(for event: WatchEvent) -> String {
        if let cwd = event.cwd, cwd.isEmpty == false { return cwd }
        return event.lane
    }

    static func projectName(for event: WatchEvent) -> String {
        if let cwd = event.cwd, cwd.isEmpty == false,
           let folder = cwd.split(separator: "/").last, folder.isEmpty == false {
            return String(folder)
        }
        return event.name.isEmpty ? event.lane : event.name
    }
}
