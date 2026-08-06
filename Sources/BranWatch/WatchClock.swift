import Foundation

/// L'horloge du veilleur, et la détection de veille qui va avec. **Correctif CR-2.**
///
/// Toutes les durées du produit — depuis combien de temps une voie attend, la
/// dette d'attente du jour, la longueur d'un intervalle journalisé — sont des
/// soustractions. Faites sur la mauvaise horloge, elles annoncent dix heures
/// d'attente au premier café et réveillent l'utilisateur avec cinq alertes
/// inventées. Ce n'est pas un cas limite : c'est tous les matins.
///
/// **Laquelle prendre, et le piège de Darwin.**
///
/// | Horloge Swift | Darwin | Avance pendant la veille ? |
/// |---|---|---|
/// | `ContinuousClock` | `CLOCK_MONOTONIC_RAW` | **oui** |
/// | `SuspendingClock` | `CLOCK_UPTIME_RAW` | **non** ← celle-ci |
///
/// Sur macOS, `CLOCK_MONOTONIC` avance **aussi** pendant la veille malgré son
/// nom. Seul `CLOCK_UPTIME_RAW` s'arrête, et c'est `SuspendingClock` qui
/// l'expose.
///
/// **Et la détection de veille tombe gratuitement.** En gardant les deux
/// instants au tic précédent, leur écart *est* le temps dormi. Aucune
/// notification à recevoir, donc rien à rater : ce détecteur survit à une
/// notification perdue, à un lancement pendant la veille, à une pause de
/// débogueur.
public struct WatchClock: Sendable {

    public struct Instant: Sendable {
        let suspending: SuspendingClock.Instant
        let continuous: ContinuousClock.Instant

        public static var now: Instant {
            Instant(suspending: SuspendingClock.now, continuous: ContinuousClock.now)
        }
    }

    /// Ce qui s'est passé entre deux tics.
    public struct Step: Equatable, Sendable {
        /// Le temps réellement écoulé hors veille. **La seule durée de confiance.**
        public let elapsed: TimeInterval
        /// Le temps passé en veille pendant l'intervalle.
        public let slept: TimeInterval
        /// Vrai si la machine a dormi assez pour que toutes les durées d'avant
        /// ne veuillent plus rien dire.
        public let jumped: Bool
    }

    /// Au-delà de ce multiple de l'intervalle de tic, on considère qu'il y a eu
    /// veille et non simple retard. Deux tics de marge absorbent une capture
    /// lente sans déclencher une remise à zéro injustifiée.
    public var jumpFactor: Double = 2

    public var tickInterval: TimeInterval

    public init(tickInterval: TimeInterval, jumpFactor: Double = 2) {
        self.tickInterval = tickInterval
        self.jumpFactor = jumpFactor
    }

    public func step(from previous: Instant, to current: Instant = .now) -> Step {
        let elapsed = Self.seconds(previous.suspending.duration(to: current.suspending))
        let wall = Self.seconds(previous.continuous.duration(to: current.continuous))
        let slept = max(0, wall - elapsed)

        return Step(
            elapsed: elapsed,
            slept: slept,
            jumped: slept > tickInterval * jumpFactor
        )
    }

    static func seconds(_ duration: Duration) -> TimeInterval {
        let (whole, attoseconds) = duration.components
        return TimeInterval(whole) + TimeInterval(attoseconds) / 1e18
    }

    /// Secondes écoulées entre deux points de la même horloge suspendue.
    ///
    /// Tronqué à la seconde, et **jamais négatif**. Tout ce qui s'en sert
    /// compare à des seuils exprimés en minutes : une durée négative — deux
    /// instants relevés dans le désordre entre deux tâches concurrentes — se
    /// lirait comme « à l'instant », c'est-à-dire comme un mouvement qui n'a pas
    /// eu lieu.
    public static func seconds(from start: Duration, to end: Duration) -> TimeInterval {
        max(0, TimeInterval((end - start).components.seconds))
    }
}
