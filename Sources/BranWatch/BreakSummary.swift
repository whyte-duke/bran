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
    ///   - workStartedAt: le premier instant de travail attribué de la journée.
    ///     **C'est lui qui sépare une pause de la nuit.** `nil` quand rien n'a
    ///     encore été travaillé : il n'y a alors aucune pause, par définition.
    ///   - threshold: la durée minimale d'une pause.
    public static func make(
        events: [PresenceEvent],
        workStartedAt: Date? = nil,
        now: Date,
        threshold: TimeInterval = BreakSummary.threshold
    ) -> BreakSummary {
        let sorted = events.sorted { $0.from < $1.from }

        var breaks: [Break] = []
        var present: TimeInterval = 0
        var paused: TimeInterval = 0

        for event in sorted where event.presence.mayBeBreak == false {
            present += event.d
        }

        for absence in stitch(sorted.filter(\.presence.mayBeBreak)) {
            // **Une pause se prend d'un travail, donc il faut avoir commencé.**
            //
            // Sans cette ligne, la nuit est la plus longue pause de la journée :
            // mesuré sur un vrai journal, une absence de 13 h 20 partant de
            // 00 h 08. Elle est parfaitement réelle — personne n'était devant la
            // machine — et elle n'est pas une pause. Le ratio pause/travail
            // devenait alors « une de pause pour 0,01 de travail », c'est-à-dire
            // un chiffre qui décrit un sommeil.
            //
            // Ce qui distingue les deux n'est pas la durée : une sieste de trois
            // heures est une pause, une nuit de six heures n'en est pas une. La
            // différence est **la place** — une pause sépare deux moments de
            // travail. Il suffit donc d'avoir travaillé avant.
            guard let workStartedAt, absence.at >= workStartedAt else { continue }
            // **La durée mesurée, pas l'écart des horloges murales.** Une nuit
            // de veille au milieu d'un intervalle donne `to - from` de huit
            // heures et `d` de quelques secondes. Compter la première ferait
            // une pause de huit heures que personne n'a prise ; l'intervalle
            // porte déjà la bonne valeur, il suffit de la lire.
            guard absence.seconds >= threshold else { continue }
            breaks.append(absence)
            paused += absence.seconds
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

    /// **Recoud les absences que l'observation a coupées.**
    ///
    /// Trouvé dans un vrai journal, et invisible depuis un test : sur une
    /// journée réelle, 59 des 136 intervalles de présence faisaient moins d'une
    /// minute, et trois absences consécutives — 405 s, 46 s, 900 s — se
    /// suivaient là où l'utilisateur avait vécu une seule absence de vingt-trois
    /// minutes.
    ///
    /// **Pourquoi le registre les coupe.** `PresenceLedger` ferme un intervalle
    /// dès qu'un battement arrive trop tard, et une veille machine fait
    /// exactement ça : la boucle ne tourne pas pendant que la machine dort, donc
    /// chaque cycle veille-réveil rouvre une ligne. C'est le bon comportement
    /// pour une **voie** — une fenêtre peut disparaître et revenir pendant le
    /// trou — mais pas pour un humain : un trou d'observation au milieu d'une
    /// absence est encore de l'absence. Personne n'est revenu travailler
    /// pendant les quatre secondes où bran ne regardait pas.
    ///
    /// **Et ce n'est pas cosmétique.** Le seuil de cinq minutes s'applique à
    /// chaque morceau : une absence d'une heure coupée en quinze fragments
    /// disparaissait entièrement du compteur de pauses, et « quand ai-je pris ma
    /// dernière pause » — la question de départ — répondait « aucune ».
    ///
    /// Le raccommodage vit ici et non dans le registre parce que c'est une
    /// décision de lecture : le journal doit garder ce qui a été observé, y
    /// compris ses trous. C'est le même partage que partout ailleurs — la règle
    /// de fusion enregistre, le résumé interprète.
    static func stitch(
        _ absences: [PresenceEvent],
        within gap: TimeInterval = BreakSummary.stitchGap
    ) -> [Break] {
        var stitched: [Break] = []

        for event in absences {
            guard var last = stitched.last else {
                stitched.append(Break(at: event.from, seconds: event.d, presence: event.presence))
                continue
            }

            guard event.from.timeIntervalSince(last.endsAt) <= gap else {
                stitched.append(Break(at: event.from, seconds: event.d, presence: event.presence))
                continue
            }

            // La durée court **de bout en bout**, trou compris : c'est le temps
            // que l'utilisateur a passé loin de sa machine, et le trou en fait
            // partie. Additionner les seules durées mesurées sous-estimerait la
            // pause d'exactement ce qu'on n'a pas su regarder.
            let end = max(last.endsAt, event.from.addingTimeInterval(event.d))
            stitched[stitched.count - 1] = Break(
                at: last.at,
                seconds: end.timeIntervalSince(last.at),
                // `away` l'emporte sur `idle` : une absence certaine reste
                // certaine même recousue à une immobilité qui ne l'était pas.
                presence: max(last.presence, event.presence)
            )
            last = stitched[stitched.count - 1]
        }

        return stitched
    }

    /// Le trou maximal entre deux absences pour qu'elles n'en fassent qu'une.
    ///
    /// **Une minute.** Il faut qu'il dépasse largement la tolérance du registre
    /// — 2,5 tics, soit dix secondes — pour absorber un cycle de veille, et
    /// qu'il reste bien sous le seuil d'une pause pour ne jamais recoudre deux
    /// vraies pauses séparées par une vraie reprise de travail. Entre dix
    /// secondes et cinq minutes, tout choix marche ; une minute est au milieu et
    /// se raconte.
    public static let stitchGap: TimeInterval = 60
}
