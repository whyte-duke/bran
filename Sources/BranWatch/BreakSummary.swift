import Foundation

/// **Les pauses de la journée, dérivées de la présence.**
///
/// Rien n'est mesuré ici : tout est déduit des intervalles de `PresenceEvent`.
/// C'est délibéré. Une pause n'est pas un événement qu'un capteur voit passer,
/// c'est une absence assez longue pour compter — et « assez longue » est un
/// réglage, pas une vérité.
///
/// ```
///  présence  ▓▓▓▓▓▓▓░░░░▓▓▓▓▓▓▓▓▓▓▓▓░░▓▓▓▓▓▓▓░░░░░░░░▓▓▓▓
///                   └18m┘              └2m┘   └──34m──┘
///  pauses            ██████                   ████████
///                    (compte)  (trop courte)  (compte)
/// ```
public struct BreakSummary: Equatable, Sendable {

    /// **Cinq minutes.** En dessous, c'est aller chercher un café ou répondre à
    /// quelqu'un dans le couloir : le compter ferait un ratio flatteur qui ne
    /// se compare à rien. Au-dessus, on raterait la vraie coupure courte de dix
    /// minutes, qui est justement celle qu'on veut se voir prendre.
    ///
    /// Distinct de `Presence.idleAfter`, qui vaut deux minutes et répond à une
    /// autre question : celui-ci dit « est-ce que ça compte », l'autre disait
    /// « est-ce que quelqu'un est aux commandes ».
    public static let threshold: TimeInterval = 300

    /// Les pauses retenues, dans l'ordre chronologique.
    public let breaks: [Break]

    /// Le temps de présence effective. C'est le dénominateur du ratio.
    public let presentSeconds: TimeInterval

    /// Le temps en pause, pauses retenues seulement.
    public let pausedSeconds: TimeInterval

    /// **Depuis quand la dernière pause s'est terminée**, à l'instant demandé.
    ///
    /// `nil` s'il n'y a eu aucune pause : la valeur juste est alors « depuis le
    /// début de la journée », et c'est à l'affichage de le dire en toutes
    /// lettres plutôt qu'à ce type de fabriquer un zéro trompeur.
    public let sinceLastBreak: TimeInterval?

    /// Une pause : quand, combien, et de quelle nature.
    public struct Break: Equatable, Sendable, Identifiable {
        public let at: Date
        public let seconds: TimeInterval
        /// `idle` ou `away`. Une absence certaine et une immobilité longue ne se
        /// valent pas, et l'écran a le droit de les distinguer.
        public let presence: Presence

        public var id: Date { at }
        public var endsAt: Date { at.addingTimeInterval(seconds) }
    }

    /// Le ratio travail / pause, tel que Rize l'affiche : « 1 / 3,6 » se lit
    /// « une minute de pause pour 3,6 minutes de travail ».
    ///
    /// `nil` sans pause **ou** sans travail — un ratio sur zéro n'est pas
    /// l'infini, c'est une absence de mesure, et l'écrire « ∞ » serait mentir
    /// avec un symbole mathématique.
    public var workPerBreak: Double? {
        guard pausedSeconds > 0, presentSeconds > 0 else { return nil }
        return presentSeconds / pausedSeconds
    }

    public var isEmpty: Bool { breaks.isEmpty && presentSeconds == 0 }

    public static let empty = BreakSummary(
        breaks: [], presentSeconds: 0, pausedSeconds: 0, sinceLastBreak: nil
    )

    public init(
        breaks: [Break],
        presentSeconds: TimeInterval,
        pausedSeconds: TimeInterval,
        sinceLastBreak: TimeInterval?
    ) {
        self.breaks = breaks
        self.presentSeconds = presentSeconds
        self.pausedSeconds = pausedSeconds
        self.sinceLastBreak = sinceLastBreak
    }

    // MARK: - L'agrégation

    /// Construit le résumé à partir des intervalles de présence d'une journée.
    ///
    /// - Parameters:
    ///   - events: les intervalles, dans n'importe quel ordre.
    ///   - now: l'instant de lecture. C'est lui qui donne son sens à
    ///     `sinceLastBreak`, et le passer explicitement rend la fonction
    ///     testable — la même journée relue à deux heures d'écart doit rendre
    ///     deux valeurs différentes, et une seule des deux est juste.
    ///   - threshold: la durée minimale d'une pause.
    public static func make(
        events: [PresenceEvent],
        now: Date,
        threshold: TimeInterval = BreakSummary.threshold
    ) -> BreakSummary {
        let sorted = events.sorted { $0.from < $1.from }

        var breaks: [Break] = []
        var present: TimeInterval = 0
        var paused: TimeInterval = 0

        for event in sorted {
            guard event.presence.mayBeBreak else {
                present += event.d
                continue
            }
            // **La durée mesurée, pas l'écart des horloges murales.** Une nuit
            // de veille au milieu d'un intervalle donne `to - from` de huit
            // heures et `d` de quelques secondes. Compter la première ferait
            // une pause de huit heures que personne n'a prise ; l'intervalle
            // porte déjà la bonne valeur, il suffit de la lire.
            guard event.d >= threshold else { continue }
            breaks.append(Break(at: event.from, seconds: event.d, presence: event.presence))
            paused += event.d
        }

        // La fin de la dernière pause, et non son début : « il y a 42 min » veut
        // dire « ça fait 42 minutes que j'ai repris », pas « ça fait 42 minutes
        // que je me suis arrêté ».
        let since = breaks.last.map { max(0, now.timeIntervalSince($0.endsAt)) }

        return BreakSummary(
            breaks: breaks,
            presentSeconds: present,
            pausedSeconds: paused,
            sinceLastBreak: since
        )
    }
}
