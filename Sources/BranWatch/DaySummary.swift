import Foundation

/// **La journée, à l'heure près.**
///
/// `WeekSummary` répond à « combien ». Celle-ci répond à « quand », et c'est une
/// autre question : un total de six heures ne dit pas si elles ont été faites
/// d'un bloc ou en dix-sept morceaux, et c'est exactement la différence entre
/// une bonne journée et une journée épuisante.
///
/// ```
///  6   7   8   9  10  11  12  13  14  15  16  17  18  19  20  21
/// ─┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬─
///          ███████░░████████    ▒▒▒▒▒███████████░░░███████
///  bran    ████████░░░░████████████                    3 h 40
///  crm       ░░░████████░░░░░░░░░░░░                   1 h 50
/// ```
///
/// **Elle ne calcule aucun total que `WeekSummary` sait déjà rendre.** La portée
/// `.day` de celle-ci donne les heures, les projets et le parallélisme ; ce qui
/// manquait, et ce qui vit ici, c'est la position dans la journée — les blocs,
/// les voies sur un axe commun, et les pauses.
public struct DaySummary: Equatable, Sendable {

    /// Minuit du jour observé, et minuit du lendemain.
    public let start: Date
    public let end: Date

    /// Les blocs de travail, dans l'ordre. C'est la ligne du haut.
    public let blocks: [Block]

    /// Une piste par voie, sur le même axe. **C'est la vue du multitâche** :
    /// trois pistes entrelacées se lisent d'un coup d'œil, là où « 1,6 voie en
    /// parallèle » demande d'y croire.
    public let lanes: [LaneTrack]

    /// Les pauses, dérivées de la présence.
    public let breaks: BreakSummary

    /// Les changements de contexte, et ce qu'ils ont coûté.
    public let switching: Switching

    /// **Les bornes de l'axe**, et elles ne sont pas fixes.
    ///
    /// Une règle figée de 6 h à 21 h coupe les nuits de qui travaille tard et
    /// laisse six heures de vide à qui commence à midi. Elles suivent donc ce
    /// qui a été observé, arrondi à l'heure, avec un minimum de huit heures pour
    /// qu'une journée de vingt minutes ne s'étale pas sur toute la largeur.
    public let firstHour: Int
    public let lastHour: Int

    public var isEmpty: Bool { blocks.isEmpty && breaks.isEmpty }

    // MARK: - Les pièces

    /// Un bloc de travail : une période continue où au moins une voie avançait
    /// pour vous.
    ///
    /// Les blocs sont **l'union** des intervalles, pas leur liste : deux voies
    /// qui travaillent en même temps font un bloc, pas deux. C'est ce qui permet
    /// de lire « j'ai travaillé de 9 h 12 à 10 h 20 » plutôt qu'une pile de
    /// segments qu'il faudrait recomposer à l'œil.
    public struct Block: Equatable, Sendable, Identifiable {
        public let from: Date
        public let to: Date
        /// La voie qui a occupé le plus de temps dans ce bloc. C'est le nom
        /// qu'on écrit à côté.
        public let title: String
        /// Combien de voies distinctes l'ont traversé.
        public let laneCount: Int
        /// Combien de fois l'attention a changé de voie **pendant** ce bloc.
        /// Un bloc d'une heure avec onze changements n'est pas une heure de
        /// travail profond, et c'est le seul endroit qui le dit.
        public let switches: Int

        public var id: Date { from }
        public var seconds: TimeInterval { to.timeIntervalSince(from) }
    }

    /// Une voie, et ses segments sur l'axe de la journée.
    public struct LaneTrack: Equatable, Sendable, Identifiable {
        public let key: String
        public let name: String
        public let segments: [Segment]
        public let seconds: TimeInterval

        public var id: String { key }
    }

    public struct Segment: Equatable, Sendable {
        public let from: Date
        public let to: Date
        /// Vrai si c'était votre travail, faux si la machine avançait seule.
        /// Voir `WeekSummary.isYours`.
        public let yours: Bool
        public let waiting: Bool
    }

    /// **Le multitâche, mesuré comme un fait humain.**
    ///
    /// `WeekSummary.Parallelism` compte des voies simultanées, ce qui est une
    /// grandeur machine : trois agents qui compilent pendant qu'on lit une
    /// documentation ne coûtent rien à personne. Le coût est ailleurs — dans le
    /// nombre de fois où l'attention change de place, et dans le temps passé
    /// dans des séjours trop courts pour entrer dans quoi que ce soit.
    public struct Switching: Equatable, Sendable {
        /// Combien de fois l'attention a changé de voie sur la journée.
        public let count: Int
        /// Le temps passé dans des séjours plus courts que `minimumStay`.
        /// **C'est le chiffre qui fait mal**, et il manque partout ailleurs.
        public let fragmentedSeconds: TimeInterval
        /// Le temps total attribué, qui sert de dénominateur.
        public let attributedSeconds: TimeInterval

        public static let none = Switching(count: 0, fragmentedSeconds: 0, attributedSeconds: 0)

        /// Changements par heure de travail. `nil` sans travail : une fréquence
        /// sur zéro n'est pas l'infini.
        public var perHour: Double? {
            guard attributedSeconds > 0 else { return nil }
            return Double(count) / (attributedSeconds / 3600)
        }
    }

    /// **Cinq minutes.** En dessous, on n'a pas eu le temps d'entrer dans la
    /// tâche : le séjour est du coût de changement, pas du travail. Au-dessus,
    /// on compterait comme fragmenté un aller-retour parfaitement normal vers
    /// une documentation.
    public static let minimumStay: TimeInterval = 300

    /// Le trou maximal entre deux intervalles pour qu'ils restent le même bloc.
    ///
    /// **Deux minutes**, la même valeur que `Presence.idleAfter`, et ce n'est
    /// pas une coïncidence : en dessous de ce seuil on ne considère pas que
    /// l'humain s'est absenté, donc on ne coupe pas son bloc de travail non
    /// plus. Deux seuils différents ici feraient apparaître des pauses dans le
    /// journal de présence qui ne coupent aucun bloc, et l'écran serait
    /// incohérent avec lui-même.
    public static let blockGap: TimeInterval = 120
}

// MARK: - L'agrégation

extension DaySummary {

    public static let empty = DaySummary(
        start: .distantPast, end: .distantPast,
        blocks: [], lanes: [], breaks: .empty, switching: .none,
        firstHour: 9, lastHour: 18
    )

    /// Construit la journée. **Aucun disque, aucune horloge lue** : `now` est
    /// fourni, comme partout ailleurs dans ce module.
    public static func make(
        events: [WatchEvent],
        presence: [PresenceEvent],
        now: Date,
        calendar: Calendar = .current
    ) -> DaySummary {
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start

        let inside = events
            .compactMap { clip($0, from: start, to: end) }
            .sorted { $0.from < $1.from }

        let tracks = lanes(of: inside)
        let spans = inside
            .filter { $0.event.state == .working && WeekSummary.isYours($0.event) }
            .map { (from: $0.from, to: $0.to) }

        let merged = merge(spans, gap: blockGap)
        let switching = self.switching(of: inside, blocks: merged)

        return DaySummary(
            start: start,
            end: end,
            blocks: blocks(from: merged, events: inside, switching: switching.perBlock),
            lanes: tracks,
            breaks: BreakSummary.make(
                events: presence.filter { $0.from < end && $0.to > start },
                // Le premier bloc de travail attribué : c'est lui qui fait la
                // différence entre une pause et la nuit. Voir `BreakSummary.make`.
                workStartedAt: merged.first?.from,
                now: now
            ),
            switching: switching.total,
            firstHour: bounds(of: inside, presence: presence, calendar: calendar).first,
            lastHour: bounds(of: inside, presence: presence, calendar: calendar).last
        )
    }

    // MARK: Rognage

    struct Span: Equatable, Sendable {
        let event: WatchEvent
        let from: Date
        let to: Date
    }

    static func clip(_ event: WatchEvent, from start: Date, to end: Date) -> Span? {
        let from = max(event.from, start)
        let to = min(max(event.to, event.from), end)
        guard to > from else { return nil }
        return Span(event: event, from: from, to: to)
    }

    // MARK: Les blocs

    /// Fusionne des intervalles qui se chevauchent ou se touchent à moins de
    /// `gap`. Le résultat est trié et disjoint.
    static func merge(_ spans: [(from: Date, to: Date)], gap: TimeInterval) -> [(from: Date, to: Date)] {
        let sorted = spans.sorted { $0.from < $1.from }
        var merged: [(from: Date, to: Date)] = []

        for span in sorted {
            guard var last = merged.last else {
                merged.append(span)
                continue
            }
            if span.from.timeIntervalSince(last.to) <= gap {
                last.to = max(last.to, span.to)
                merged[merged.count - 1] = last
            } else {
                merged.append(span)
            }
        }

        return merged
    }

    private static func blocks(
        from merged: [(from: Date, to: Date)],
        events: [Span],
        switching: [Date: Int]
    ) -> [Block] {
        merged.map { window in
            let inside = events.filter { $0.to > window.from && $0.from < window.to }

            // Le titre est la voie qui a le plus occupé le bloc. Prendre la
            // première venue donnerait le nom d'un passage de trente secondes
            // pour un bloc d'une heure.
            var byLane: [String: (name: String, seconds: TimeInterval)] = [:]
            for span in inside where span.event.state == .working {
                let overlap = min(span.to, window.to).timeIntervalSince(max(span.from, window.from))
                guard overlap > 0 else { continue }
                var row = byLane[span.event.lane] ?? (WeekSummary.projectName(for: span.event), 0)
                row.seconds += overlap
                byLane[span.event.lane] = row
            }

            // Départage stable : à durée égale, le nom. L'ordre d'un
            // dictionnaire n'en est pas un, et un titre qui change d'un rendu à
            // l'autre se remarque tout de suite.
            let winner = byLane.values.max { left, right in
                left.seconds == right.seconds
                    ? left.name.localizedStandardCompare(right.name) == .orderedDescending
                    : left.seconds < right.seconds
            }

            return Block(
                from: window.from,
                to: window.to,
                title: winner?.name ?? "—",
                laneCount: byLane.count,
                switches: switching[window.from] ?? 0
            )
        }
    }

    // MARK: Les voies

    private static func lanes(of spans: [Span]) -> [LaneTrack] {
        var byKey: [String: (name: String, segments: [Segment], seconds: TimeInterval)] = [:]

        for span in spans {
            let state = span.event.state
            guard state == .working || state == .waiting else { continue }

            let yours = WeekSummary.isYours(span.event)
            var row = byKey[span.event.lane]
                ?? (span.event.name.isEmpty ? span.event.lane : span.event.name, [], 0)

            row.segments.append(Segment(
                from: span.from, to: span.to, yours: yours, waiting: state == .waiting
            ))
            // Seul le travail qui vous revient entre dans la durée affichée :
            // c'est la même règle que partout, et l'appliquer ici aussi évite
            // qu'une voie de fond trône en tête de la liste.
            if state == .working, yours { row.seconds += span.to.timeIntervalSince(span.from) }
            byKey[span.event.lane] = row
        }

        return byKey
            .map { LaneTrack(key: $0.key, name: $0.value.name, segments: $0.value.segments, seconds: $0.value.seconds) }
            .sorted { left, right in
                left.seconds == right.seconds
                    ? left.name.localizedStandardCompare(right.name) == .orderedAscending
                    : left.seconds > right.seconds
            }
    }

    // MARK: Le multitâche

    /// La suite des changements d'attention, et le temps fragmenté.
    ///
    /// L'attention est portée par `WatchEvent.fg` : les intervalles au premier
    /// plan, mis bout à bout, *sont* la suite des voies que l'humain a tenues.
    /// Chaque passage d'une voie à une autre est un changement de contexte, et
    /// un séjour plus court que `minimumStay` est du temps où l'on n'est jamais
    /// resté assez longtemps pour entrer dans le travail.
    private static func switching(
        of spans: [Span],
        blocks: [(from: Date, to: Date)]
    ) -> (total: Switching, perBlock: [Date: Int]) {
        let held = spans
            .filter { $0.event.fg == true && $0.event.state == .working }
            .sorted { $0.from < $1.from }

        guard held.isEmpty == false else { return (.none, [:]) }

        var count = 0
        var fragmented: TimeInterval = 0
        var attributed: TimeInterval = 0
        var perBlock: [Date: Int] = [:]
        var previousLane: String?

        for stay in held {
            let seconds = stay.to.timeIntervalSince(stay.from)
            attributed += seconds
            if seconds < minimumStay { fragmented += seconds }

            defer { previousLane = stay.event.lane }
            guard let previous = previousLane, previous != stay.event.lane else { continue }
            count += 1

            if let block = blocks.first(where: { stay.from >= $0.from && stay.from < $0.to }) {
                perBlock[block.from, default: 0] += 1
            }
        }

        return (
            Switching(count: count, fragmentedSeconds: fragmented, attributedSeconds: attributed),
            perBlock
        )
    }

    // MARK: Les bornes de l'axe

    /// L'heure de début et de fin de l'axe, arrondies, avec une amplitude
    /// minimale.
    static func bounds(
        of spans: [Span],
        presence: [PresenceEvent],
        calendar: Calendar,
        minimumHours: Int = 8
    ) -> (first: Int, last: Int) {
        var instants = spans.flatMap { [$0.from, $0.to] }
        instants.append(contentsOf: presence.flatMap { [$0.from, $0.to] })

        guard instants.isEmpty == false else { return (9, 9 + minimumHours) }

        let hours = instants.map { calendar.component(.hour, from: $0) }
        var first = hours.min() ?? 9
        // `+1` parce que la borne haute est l'heure **suivante** : un intervalle
        // qui finit à 17 h 40 a besoin que l'axe aille jusqu'à 18 h, sinon il
        // dépasse la règle qui est censée le contenir.
        var last = min(24, (hours.max() ?? 18) + 1)

        // On étale symétriquement plutôt que vers la droite : une journée de
        // 14 h à 15 h doit rester centrée, pas commencer à 14 h et finir à 22 h.
        while last - first < minimumHours {
            if first > 0 { first -= 1 }
            if last - first < minimumHours, last < 24 { last += 1 }
            if first == 0, last == 24 { break }
        }

        return (first, last)
    }
}
