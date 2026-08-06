import Foundation

/// Ce que l'on sait de l'humain. **Trois cas, dont un qui n'est pas une valeur.**
///
/// Correctif CR-1 : l'inactivité clavier-souris est la moitié gauche de l'idée
/// centrale du produit — « vous ne faites rien *pendant que* trois choses
/// attendent ». Si ce signal meurt, il ne faut ni conclure « actif » ni conclure
/// « inactif » : les deux fabriquent un échec silencieux. On dit qu'on ne sait
/// pas, et le résolveur en tient compte.
public enum HumanPresence: Equatable, Sendable {
    case active
    case idle(seconds: Double)
    case unavailable(reason: String)

    public var idleSeconds: Double? {
        if case let .idle(seconds) = self { return seconds }
        if case .active = self { return 0 }
        return nil
    }
}

/// Ce qu'un capteur rapporte sur une voie, pour un tic donné.
/// **Rapporte, ne décide pas** — le patron de `SessionResolver`.
public struct LaneObservation: Equatable, Sendable {
    public let identity: LaneIdentity
    /// Part des blocs qui ont bougé depuis le tic précédent. `nil` si la fenêtre
    /// n'a pas pu être capturée (elle vient d'apparaître, le flux est tombé).
    public let motionRatio: Double?
    /// Depuis combien de temps cette voie n'a rien fait bouger.
    public let stillFor: TimeInterval?
    /// Le verdict d'un capteur certain, quand il en existe un pour cette tribu.
    ///
    /// **Deux cas seulement, volontairement.** La première version acceptait les
    /// cinq `LaneState` ; un capteur qui aurait rendu `.unknown` aurait produit
    /// un `because` affirmant « la session est en train d'appeler un outil » —
    /// un mensonge affiché à l'utilisateur. Un capteur certain qui ne sait pas
    /// n'est pas un capteur certain : il ne rapporte rien.
    public let certain: Certainty?

    /// Depuis combien de temps l'humain n'a plus touché **cette voie**
    /// précisément (fenêtre au premier plan, frappe dedans). `nil` si on ne sait
    /// pas. Voir la clause de `waiting` dans `resolve`.
    public let lastTouchedByHuman: TimeInterval?

    /// L'horodatage exact du dernier tour terminé, quand un capteur certain le
    /// fournit. **Insensible à la veille**, contrairement à `stillFor` qui est
    /// une soustraction d'horloge murale — c'est donc lui qui doit servir à
    /// calculer une durée d'attente quand il existe.
    public let certainSince: Date?

    public enum Certainty: Equatable, Sendable {
        case waiting
        case working
    }

    public init(
        identity: LaneIdentity,
        motionRatio: Double? = nil,
        stillFor: TimeInterval? = nil,
        certain: Certainty? = nil,
        lastTouchedByHuman: TimeInterval? = nil,
        certainSince: Date? = nil
    ) {
        self.identity = identity
        self.motionRatio = motionRatio
        self.stillFor = stillFor
        self.certain = certain
        self.lastTouchedByHuman = lastTouchedByHuman
        self.certainSince = certainSince
    }
}

public struct Lane: Equatable, Sendable {
    public let identity: LaneIdentity
    public let state: LaneState
    public let waitingFor: TimeInterval
    /// Sur quoi la décision repose. Affiché à l'utilisateur : une alerte dont on
    /// ne peut pas expliquer l'origine finit par être ignorée.
    public let because: String
}

/// Le résultat d'un tic. Tout ce que l'interface affiche vient d'ici.
public struct WatchVerdict: Equatable, Sendable {
    public let lanes: [Lane]
    /// Le routeur d'attention : la seule voie qu'il faut reprendre maintenant.
    public let next: Lane?
    /// **L'idée centrale.** L'humain ne fait rien *et* des machines attendent.
    /// `nil` quand la présence humaine est inconnue — jamais `false` par défaut.
    public let sharedSilence: Bool?
    /// Somme des attentes **en cours, à cet instant**.
    ///
    /// Ce n'est PAS « la dette d'attente du jour » du périmètre accepté : celle-ci
    /// retombe à zéro dès qu'on répond, et vaut zéro pendant toute une réunion.
    /// Le cumul quotidien se calcule sur le journal d'événements, pas ici. Deux
    /// mesures différentes ne doivent pas porter le même nom.
    public let waitingNow: TimeInterval
    /// Vrai quand le résolveur s'est tu volontairement (enregistrement en cours).
    public let muted: Bool

    public static let silent = WatchVerdict(
        lanes: [], next: nil, sharedSilence: nil, waitingNow: 0, muted: true
    )
}

/// **Le seul endroit qui décide.** Les capteurs rapportent, lui tranche.
///
/// C'est le jumeau de `SessionResolver`, et pour la même raison : un unique
/// goulot rend l'incohérence impossible plutôt qu'improbable. Il n'y a pas de
/// `if waiting { notify() }` ailleurs dans l'application.
public struct WatchResolver: Sendable {

    public struct Thresholds: Sendable {
        /// Au-dessus, la voie travaille.
        ///
        /// **Sans valeur par défaut, volontairement.** Les trois seuils
        /// temporels ci-dessous sont des choix de produit défendables à la
        /// lecture ; celui-ci est une grandeur physique que seule une mesure
        /// peut donner, et il conditionne directement le critère « moins de
        /// 25 % d'alertes fausses ». Un défaut qui marche « à peu près » est le
        /// meilleur moyen de ne jamais faire tourner le spike : on le rend donc
        /// impossible à oublier.
        public var busyRatio: Double
        /// Immobile plus longtemps que ça : elle attend.
        public var waitingAfter: TimeInterval = 180
        /// Immobile plus longtemps que ça sans confirmation : sans nouvelles.
        public var staleAfter: TimeInterval = 1800
        /// Immobile plus longtemps que ça : abandonnée, on ne dérange plus.
        public var abandonedAfter: TimeInterval = 7200
        /// L'humain est réputé absent au-delà.
        public var humanIdleAfter: TimeInterval = 120

        public init(busyRatio: Double) {
            self.busyRatio = busyRatio
        }

        /// Le seuil que le spike a observé sur un terminal en travail — ratio
        /// max 0,0364 contre 0,0000 exactement pour les fenêtres immobiles. À
        /// n'utiliser que dans les tests : en production, la valeur vient des
        /// réglages, où l'utilisateur voit d'où elle sort.
        public static let measuredOnce = Thresholds(busyRatio: 0.01)
    }

    public var thresholds: Thresholds

    public init(thresholds: Thresholds) {
        self.thresholds = thresholds
    }

    /// - Parameter isMuted: correctif CR-4.
    ///
    ///   **Le nom compte.** La première version s'appelait `isRecording`, et
    ///   elle mentait : ce dont CR-4 protège, c'est un **partage d'écran**, pas
    ///   un enregistrement. Si l'utilisateur partage son écran en réunion sans
    ///   que bran enregistre, le routeur affiche le nom de ses clients à ses
    ///   clients quand même. Le prédicat correct est donc plus large — une
    ///   fenêtre de réunion à l'écran suffit — et le nom devait le dire, sinon
    ///   quelqu'un aurait câblé la mauvaise condition dans six mois.
    /// - Parameter clockJumped: correctif CR-2. Après une veille, toutes les
    ///   durées sont fausses. On repart de `unknown` plutôt que de réveiller
    ///   quelqu'un avec cinq alertes inventées.
    public func resolve(
        observations: [LaneObservation],
        human: HumanPresence,
        isMuted: Bool = false,
        clockJumped: Bool = false,
        now: Date = .now
    ) -> WatchVerdict {
        guard isMuted == false else { return .silent }

        let lanes = observations.map { observation -> Lane in
            let still = observation.stillFor ?? 0

            if clockJumped {
                return Lane(
                    identity: observation.identity,
                    state: .unknown,
                    waitingFor: 0,
                    because: "au réveil, les durées d'avant la veille ne veulent rien dire"
                )
            }

            // Un capteur certain l'emporte toujours sur les pixels : il sait,
            // les pixels supposent.
            if let certain = observation.certain {
                // On préfère l'horodatage écrit par l'outil lui-même à une
                // soustraction d'horloge murale : il ne compte pas la veille.
                let waited = observation.certainSince.map { now.timeIntervalSince($0) } ?? still
                return Lane(
                    identity: observation.identity,
                    state: certain == .waiting ? .waiting : .working,
                    waitingFor: certain == .waiting ? max(0, waited) : 0,
                    because: certain == .waiting
                        ? "le dernier tour de la session est terminé"
                        : "la session est en train d'appeler un outil"
                )
            }

            guard let ratio = observation.motionRatio else {
                return Lane(
                    identity: observation.identity,
                    state: .unknown,
                    waitingFor: 0,
                    because: "cette fenêtre n'a pas pu être observée"
                )
            }

            if ratio > thresholds.busyRatio {
                return Lane(
                    identity: observation.identity,
                    state: .working,
                    waitingFor: 0,
                    because: "l'écran de cette fenêtre bouge"
                )
            }

            // **La clause qui manquait, et c'était un vrai générateur de fausses
            // alertes.** Sans capteur certain — le cas de tout onglet
            // `claude.ai` et de toute application de bureau — l'immobilité seule
            // ne prouve rien. Une fenêtre que l'utilisateur vient de regarder
            // n'« attend » pas : il est devant. On n'appelle `waiting` que si
            // l'humain n'a pas touché *cette voie* depuis au moins aussi
            // longtemps qu'elle est immobile.
            //
            // Quand on ignore la dernière interaction (`nil`), on refuse de
            // conclure à une attente et on reste sur `stale` : un état visible
            // qui ne dérange personne, plutôt qu'une alerte inventée.
            let humanAway: Bool = {
                guard let touched = observation.lastTouchedByHuman else { return false }
                return touched >= thresholds.waitingAfter
            }()

            let state: LaneState
            let because: String
            switch still {
            case thresholds.abandonedAfter...:
                state = .abandoned
                because = "immobile depuis plus de \(Int(thresholds.abandonedAfter / 3600)) h"
            case thresholds.staleAfter...:
                state = .stale
                because = "immobile depuis longtemps, et rien ne le confirme"
            case thresholds.waitingAfter...:
                state = humanAway ? .waiting : .stale
                because = humanAway
                    ? "immobile depuis \(Int(still / 60)) min, et vous n'y êtes pas revenu"
                    : "immobile, mais rien ne dit qu'elle vous attend"
            default:
                state = .working
                because = "immobile, mais pas depuis assez longtemps pour conclure"
            }

            return Lane(
                identity: observation.identity,
                state: state,
                waitingFor: state == .waiting ? still : 0,
                because: because
            )
        }

        let waiting = lanes.filter { $0.state.deservesAttention }

        // Le routeur : la voie qui attend depuis le plus longtemps. À égalité,
        // la plus précisément identifiée passe devant — on préfère envoyer
        // l'utilisateur vers quelque chose qu'on sait nommer.
        let next = waiting.max {
            ($0.waitingFor, $0.identity.precision.rawValue)
                < ($1.waitingFor, $1.identity.precision.rawValue)
        }

        let sharedSilence: Bool? = {
            guard let idle = human.idleSeconds else { return nil }   // CR-1
            return idle >= thresholds.humanIdleAfter && waiting.isEmpty == false
        }()

        return WatchVerdict(
            lanes: lanes.sorted { $0.state.displayOrder < $1.state.displayOrder },
            next: next,
            sharedSilence: sharedSilence,
            waitingNow: waiting.reduce(0) { $0 + $1.waitingFor },
            muted: false
        )
    }
}
