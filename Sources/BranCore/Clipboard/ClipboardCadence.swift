import Foundation

/// **À quelle cadence relire `changeCount`, selon ce que fait la machine.**
///
/// ```
///   écran endormi / session verrouillée ─────────────▶ 60 s
///   personne n'a touché clavier ni souris depuis 60 s ▶ 10 s
///   quelqu'un est là                                 ─▶  2 s
/// ```
///
/// **Le sondage existe pour rattraper les copies faites à la souris** — Édition
/// › Copier, un glisser-déposer, un bouton « Copier » dans une page. Celles
/// faites au clavier arrivent par le guet, immédiatement, et c'est l'écrasante
/// majorité. Le filet lent tournait pourtant à deux secondes en permanence,
/// batterie et fenêtre fermée comprises : **trente réveils par minute**,
/// 1 800 par heure, 14 400 sur une journée de travail, dont la quasi-totalité
/// pour relire un entier qui n'avait pas bougé.
///
/// La lecture elle-même ne coûte rien — `NSPasteboard.changeCount` mesuré à
/// 1,6 µs sur ce Mac. Ce qu'on paie est le réveil du processus, et c'est
/// exactement ce que la cadence espace.
///
/// **Pourquoi l'inactivité humaine est le bon signal, et non la batterie.** Une
/// copie à la souris demande une main sur la souris. Si le compteur
/// d'inactivité du système annonce qu'aucun événement clavier ni souris n'est
/// arrivé depuis une minute, il ne s'est produit aucune copie de ce type dans
/// cette minute-là — ce n'est pas une supposition sur l'usage, c'est ce que le
/// capteur dit. La batterie, elle, ne dit rien sur ce qui se passe : ralentir
/// dessus ferait manquer des copies à quelqu'un qui travaille.
///
/// **Ce que le ralentissement coûte, exactement.** Quand quelqu'un revient
/// après une pause, son premier événement n'est vu qu'au réveil suivant du
/// sondeur — jusqu'à dix secondes plus tard. Une copie à la souris faite dans
/// la foulée peut donc apparaître dans l'historique avec dix secondes de retard
/// au lieu de deux. Elle n'est jamais perdue : `changeCount` est un compteur
/// monotone, le sondeur voit le saut quel que soit le temps écoulé. C'est
/// pourquoi le palier lent reste à dix secondes et pas à soixante — soixante
/// aurait été un historique qui semble ne pas marcher.
///
/// L'écran endormi et la session verrouillée sont l'exception : là, il n'y a
/// personne devant la machine par construction, et le réveil coûte le prix
/// fort — c'est précisément l'heure où le Mac cherche à descendre dans ses
/// états de sommeil profond.
public struct ClipboardCadence: Equatable, Sendable {

    /// Ce que la machine rapporte au moment de choisir la cadence.
    public struct Facts: Equatable, Sendable {
        /// Secondes depuis le dernier événement clavier ou souris. `nil` quand
        /// le compteur du système ne répond pas — on retombe alors sur la
        /// cadence rapide, parce qu'un capteur muet ne justifie pas de ralentir
        /// une fonction que l'utilisateur croit active.
        public var idleSeconds: TimeInterval?
        /// L'écran est éteint par le gestionnaire d'énergie.
        public var isDisplayAsleep: Bool
        /// La session est verrouillée.
        public var isScreenLocked: Bool

        public init(
            idleSeconds: TimeInterval? = nil,
            isDisplayAsleep: Bool = false,
            isScreenLocked: Bool = false
        ) {
            self.idleSeconds = idleSeconds
            self.isDisplayAsleep = isDisplayAsleep
            self.isScreenLocked = isScreenLocked
        }
    }

    /// Deux secondes : la cadence d'origine, celle de quelqu'un qui travaille.
    public static let attentive: TimeInterval = 2
    /// Dix secondes : personne devant, mais l'écran est allumé.
    public static let relaxed: TimeInterval = 10
    /// Soixante secondes : écran éteint ou session verrouillée. On ne s'arrête
    /// pas complètement — une écriture faite par un script, une synchronisation
    /// ou un autre Mac via le Presse-papiers universel reste une copie, et
    /// l'historique doit la voir avant la purge de minuit.
    public static let parked: TimeInterval = 60

    /// Au-delà de cette inactivité, on passe au palier lent. Une minute :
    /// assez pour ne pas ralentir quelqu'un qui lit une page avant de copier
    /// dedans, assez court pour que la pause déjeuner soit couverte dès sa
    /// première minute.
    public static let idleThreshold: TimeInterval = 60

    /// L'intervalle à respecter avant la prochaine lecture.
    public static func interval(for facts: Facts) -> TimeInterval {
        if facts.isDisplayAsleep || facts.isScreenLocked { return parked }
        guard let idle = facts.idleSeconds, idle.isFinite, idle >= 0 else { return attentive }
        return idle >= idleThreshold ? relaxed : attentive
    }

    /// Combien de réveils par heure cette cadence représente. Sert au journal
    /// des fonctions et aux tests : un chiffre annoncé doit pouvoir être
    /// recalculé.
    public static func wakeupsPerHour(_ interval: TimeInterval) -> Int {
        guard interval > 0 else { return 0 }
        return Int((3600 / interval).rounded())
    }
}
