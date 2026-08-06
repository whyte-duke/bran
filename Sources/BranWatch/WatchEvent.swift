import Foundation

/// Un intervalle fermé : une voie, un état, du temps `a` à `b`.
///
/// **C'est cette forme qui décide du stockage, et pas l'inverse.** Écrire une
/// ligne par tic et par voie donnerait, à 2 secondes et cinq voies, 216 000
/// lignes et ~50 Mo par jour : à ce volume, un fichier texte ne tient pas et il
/// faut une base. En fusionnant les états continus — la voie était `working`, de
/// 9 h 12 à 9 h 47, une ligne — on tombe à quelques centaines de lignes et
/// ~75 Ko par jour. Un fichier texte redevient évident, et le README garde sa
/// promesse : « la bibliothèque est juste un dossier ».
///
/// Autrement dit, la règle de fusion n'est pas une optimisation ajoutée après
/// coup, c'est ce qui rend le choix de stockage possible.
public struct WatchEvent: Equatable, Sendable, Codable {

    /// Version du schéma. Écrite sur chaque ligne pour qu'un journal d'il y a
    /// six mois reste relisible après un changement de format.
    public var v: Int = 1

    public let lane: String
    public let name: String
    /// `LaneIdentity.Precision.rawValue` — dit ce qu'on a le droit de conclure
    /// de `lane`.
    public let p: Int
    public let state: LaneState

    /// Horloge murale, pour l'affichage.
    public let from: Date
    public private(set) var to: Date

    /// La durée mesurée sur `SuspendingClock` — **la seule de confiance**.
    ///
    /// `to - from ≠ d` signifie qu'une veille a eu lieu pendant l'intervalle. Ce
    /// n'est pas une redondance : c'est le seul endroit où la veille laisse une
    /// trace mesurée, et ça ne coûte rien.
    public private(set) var d: TimeInterval

    /// D'où vient le verdict. Sans ce champ, impossible de rejouer un taux de
    /// fausses alertes par capteur, donc impossible d'améliorer les seuils.
    public let src: Source
    /// `Lane.because`. Une alerte qu'on ne sait pas expliquer finit ignorée.
    public let why: String

    public let cwd: String?
    public let branch: String?

    public enum Source: String, Sendable, Codable {
        case certain, pixels, aucun
    }

    public init(
        lane: String, name: String, p: Int, state: LaneState,
        from: Date, to: Date, d: TimeInterval,
        src: Source, why: String,
        cwd: String? = nil, branch: String? = nil
    ) {
        self.lane = lane
        self.name = name
        self.p = p
        self.state = state
        self.from = from
        self.to = to
        self.d = d
        self.src = src
        self.why = why
        self.cwd = cwd
        self.branch = branch
    }

    mutating func extend(to instant: Date, by elapsed: TimeInterval) {
        to = instant
        d += elapsed
    }
}

/// La règle de fusion, en logique pure. Le store ne fait que sérialiser ce
/// qu'elle rend.
///
/// Un intervalle ouvert par voie. À chaque battement : même état et battement
/// pas trop tardif, on étend ; sinon on ferme la ligne et on en rouvre une.
public struct WatchLedger: Sendable {

    /// Tolérance avant de considérer qu'un battement manquant coupe
    /// l'intervalle. **2,5 fois le tic** : ça absorbe un tic sauté — capture
    /// lente, budget épuisé — sans fragmenter en deux lignes ce qui est une
    /// seule période de travail.
    public var pulse: TimeInterval

    private var open: [String: (event: WatchEvent, lastSeen: Date)] = [:]

    public init(tickInterval: TimeInterval) {
        self.pulse = tickInterval * 2.5
    }

    /// Enregistre l'état d'une voie. Rend l'intervalle **fermé** s'il y en a un
    /// à écrire, `nil` si l'intervalle courant s'est simplement prolongé.
    public mutating func beat(
        lane: Lane,
        at instant: Date,
        elapsed: TimeInterval,
        source: WatchEvent.Source
    ) -> WatchEvent? {
        let key = lane.identity.key

        if var current = open[key] {
            let onTime = instant.timeIntervalSince(current.lastSeen) <= pulse
            if current.event.state == lane.state, onTime {
                current.event.extend(to: instant, by: elapsed)
                current.lastSeen = instant
                open[key] = current
                return nil
            }
            open[key] = (start(lane, at: instant, source: source), instant)
            return current.event
        }

        open[key] = (start(lane, at: instant, source: source), instant)
        return nil
    }

    /// Ferme tout ce qui est en cours. À appeler avant une mise en veille, à la
    /// fermeture de l'application et au changement de jour — un crash perd les
    /// intervalles ouverts, jamais les fermés.
    public mutating func flush() -> [WatchEvent] {
        let events = open.values.map(\.event)
        open.removeAll()
        return events.sorted { $0.from < $1.from }
    }

    /// Les voies qui ont disparu de l'observation : leur intervalle se ferme,
    /// sinon une fenêtre fermée resterait ouverte pour toujours dans le journal.
    public mutating func closeMissing(keeping keys: Set<String>) -> [WatchEvent] {
        let gone = open.keys.filter { keys.contains($0) == false }
        let events = gone.compactMap { open.removeValue(forKey: $0)?.event }
        return events.sorted { $0.from < $1.from }
    }

    private func start(_ lane: Lane, at instant: Date, source: WatchEvent.Source) -> WatchEvent {
        WatchEvent(
            lane: lane.identity.key,
            name: lane.identity.displayName,
            p: lane.identity.precision.rawValue,
            state: lane.state,
            from: instant,
            to: instant,
            d: 0,
            src: source,
            why: lane.because,
            cwd: lane.identity.workingDirectory,
            branch: lane.identity.branch
        )
    }
}
