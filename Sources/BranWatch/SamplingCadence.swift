import Foundation

/// **Qui mérite le budget de captures de ce tic, et dans quel ordre.**
///
/// À vingt fenêtres, capturer tout le monde à chaque tic faisait dériver le tic
/// de 2 s vers 3 s — et tous les seuils temporels du résolveur glissaient d'un
/// tiers sans que rien ne le dise. Le budget est donc borné, et il faut choisir.
/// Le choix est de l'arithmétique sur des états : il n'a besoin ni d'écran ni
/// d'autorisation, donc il vit ici.
///
/// ```
///   rang  qui                          tic sur
///     0   jamais mesurée                  1     ← sinon la voie n'existe pas
///     1   proche du seuil d'attente        1     ← là où se décide une alerte
///     2   travaille / attend               3
///     3   sans nouvelles                  15
///     4   abandonnée / inconnue           60
/// ```
///
/// À rang égal, la voie mesurée il y a le plus longtemps passe devant : sans ça,
/// les six mêmes fenêtres se partageraient le budget éternellement et les autres
/// ne seraient jamais vues.
public struct SamplingCadence: Sendable {

    /// Ce que la cadence a besoin de savoir d'une fenêtre. Volontairement pas un
    /// `SCWindow` ni même une `LaneIdentity` complète : quatre champs suffisent
    /// à décider, et s'en tenir à quatre champs est ce qui rend la décision
    /// vérifiable.
    public struct Candidate: Sendable, Equatable {
        public let key: String
        /// Faux pour une fenêtre minimisée ou masquée. Le compositeur n'en a
        /// plus les pixels : la capturer rendrait une image uniforme qu'on
        /// lirait comme « immobile », donc on ne la capture jamais.
        public let isOnScreen: Bool
        /// Le tic de la dernière capture réussie. `nil` = jamais mesurée.
        public let lastCapturedTick: Int?
        /// Depuis combien de temps la voie est immobile. `nil` = jamais mesurée.
        public let stillFor: TimeInterval?

        public init(
            key: String,
            isOnScreen: Bool = true,
            lastCapturedTick: Int? = nil,
            stillFor: TimeInterval? = nil
        ) {
            self.key = key
            self.isOnScreen = isOnScreen
            self.lastCapturedTick = lastCapturedTick
            self.stillFor = stillFor
        }
    }

    /// Nombre maximal de captures par tic. Six est le compromis mesuré sur la
    /// sonde : au-delà, le tic déborde.
    public var budget: Int
    /// Sert à repérer les voies « proches du seuil », les seules qu'il faut
    /// mesurer à chaque tic.
    public var waitingAfter: TimeInterval
    /// L'état de chaque voie au tic précédent. Une voie absente n'a jamais été
    /// résolue et se traite comme active.
    public var states: [String: LaneState]
    /// Les voies pour lesquelles un capteur certain a parlé ce tic. Elles ne
    /// coûtent **aucune** capture : le verdict est déjà meilleur.
    public var certain: Set<String>

    public init(
        budget: Int = 6,
        waitingAfter: TimeInterval = 180,
        states: [String: LaneState] = [:],
        certain: Set<String> = []
    ) {
        self.budget = budget
        self.waitingAfter = waitingAfter
        self.states = states
        self.certain = certain
    }

    /// Un tic sur combien, par rang.
    public static let periods = [1, 1, 3, 15, 60]

    public func rank(_ candidate: Candidate) -> Int {
        guard let stillFor = candidate.stillFor else { return 0 }

        // La moitié du seuil : une voie qui approche des trois minutes doit être
        // mesurée à chaque tic, sinon l'alerte se déclenche sur une observation
        // vieille de plusieurs échantillons. Au-delà du seuil, l'alerte est déjà
        // partie et l'urgence retombe.
        if stillFor >= waitingAfter / 2, stillFor < waitingAfter { return 1 }

        return switch states[candidate.key] {
        case .working, .waiting, .none: 2
        case .stale: 3
        case .abandoned, .unknown: 4
        }
    }

    public func period(for candidate: Candidate) -> Int {
        let rank = rank(candidate)
        return rank < Self.periods.count ? Self.periods[rank] : 1
    }

    /// Cette fenêtre a-t-elle le droit d'être capturée à ce tic ?
    public func allowsCapture(_ candidate: Candidate, tick: Int) -> Bool {
        guard candidate.isOnScreen else { return false }
        guard certain.contains(candidate.key) == false else { return false }
        guard let last = candidate.lastCapturedTick else { return true }
        return tick - last >= period(for: candidate)
    }

    /// L'ordre dans lequel les fenêtres méritent le budget. Rend des **indices**
    /// et non des fenêtres : l'appelant a deux tableaux parallèles, les objets
    /// système et leurs copies transmissibles.
    ///
    /// `sorted` est stable ici parce que le comparateur départage jusqu'au bout
    /// les cas qui l'intéressent ; deux voies de même rang jamais mesurées
    /// gardent l'ordre d'énumération, qui est celui de la superposition.
    public func order(_ candidates: [Candidate]) -> [Int] {
        candidates.indices.sorted { left, right in
            let a = (rank(candidates[left]), candidates[left].lastCapturedTick ?? -1)
            let b = (rank(candidates[right]), candidates[right].lastCapturedTick ?? -1)
            return a < b
        }
    }

    /// Les indices à capturer ce tic : l'ordre de priorité, restreint à ce qui a
    /// le droit d'être capturé, coupé au budget.
    ///
    /// Une fenêtre écartée — hors écran, déjà certaine, ou pas encore due — ne
    /// **consomme pas** de budget : elle est sautée, et la suivante prend sa
    /// place. Sinon un écran plein de fenêtres minimisées affamerait les voies
    /// réellement observables.
    public func selection(_ candidates: [Candidate], tick: Int) -> [Int] {
        guard budget > 0 else { return [] }
        return order(candidates)
            .filter { allowsCapture(candidates[$0], tick: tick) }
            .prefix(budget)
            .map { $0 }
    }
}
