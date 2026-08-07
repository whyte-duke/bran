import Foundation

/// **L'état de l'humain devant la machine.** Distinct de l'état d'une voie, et
/// c'est tout l'intérêt.
///
/// Jusqu'ici, tout ce que le veilleur n'observait pas tombait dans
/// `LaneState.unknown`, libellé « pas observable ». Ce libellé est honnête sur
/// l'ignorance de la machine et catastrophique pour qui lit le journal : il met
/// dans le même sac la pause déjeuner, l'écran verrouillé, la machine endormie
/// et le capteur mort. Tant que ces quatre-là partagent une couleur, la question
/// « quand ai-je pris ma dernière pause » n'a pas de réponse — et sans elle, ni
/// ratio pause/travail, ni moyenne journalière honnête, ni fin de journée.
///
/// **On ne devine rien, on lit.** macOS donne gratuitement le verrouillage de
/// session, la veille de l'écran et l'inactivité clavier-souris. Chacun de ces
/// trois signaux est déjà mesuré ailleurs dans bran ; il ne manquait que de les
/// écrire.
///
/// Le cas absent de cette énumération est délibéré : **il n'y a pas de cas
/// « inconnu »**. Quand le capteur d'inactivité ne répond pas, `resolve` rend
/// `nil` et rien n'est écrit. Un trou dans le journal de présence redevient donc
/// ce qu'il aurait toujours dû être — un capteur muet — au lieu d'être un
/// fourre-tout où la pause se cache.
public enum Presence: String, Sendable, Codable, CaseIterable, Comparable {

    /// Quelqu'un est aux commandes, ou vient de l'être.
    case present

    /// La machine est éveillée et personne ne la touche. **Une pause probable**,
    /// pas certaine : lire un écran de code pendant douze minutes sans bouger la
    /// souris est exactement cette signature.
    case idle

    /// Session verrouillée, écran éteint ou machine endormie. **Certain.**
    case away

    /// L'ordre est celui de la certitude décroissante sur « il travaille ».
    private var rank: Int {
        switch self {
        case .present: 0
        case .idle: 1
        case .away: 2
        }
    }

    public static func < (lhs: Presence, rhs: Presence) -> Bool {
        lhs.rank < rhs.rank
    }

    /// Est-ce que cet intervalle peut compter comme une pause ?
    ///
    /// `present` ne compte jamais. Les deux autres comptent **à partir d'une
    /// durée** : voir `BreakSummary.threshold`. Aller chercher un café n'est pas
    /// une pause, et compter les micro-absences ferait un ratio flatteur qui ne
    /// veut rien dire.
    public var mayBeBreak: Bool { self != .present }

    public var label: String {
        switch self {
        case .present: "présent"
        case .idle: "sans activité"
        case .away: "absent"
        }
    }

    public var symbol: String {
        switch self {
        case .present: "person.fill"
        case .idle: "person"
        case .away: "moon.zzz"
        }
    }
}

// MARK: - Ce qu'on lit pour décider

/// Les signaux bruts d'un battement. Aucun ne coûte d'autorisation, et aucun
/// n'est nouveau : les trois premiers sont déjà lus par `WatchController`, le
/// quatrième est `HumanPresence`.
public struct PresenceInput: Equatable, Sendable {

    /// `com.apple.screenIsLocked`, observé sur le centre de notifications
    /// distribué.
    public var isScreenLocked: Bool

    /// `CGDisplayIsAsleep`. Le contrôleur le lit déjà pour se taire ; ici il
    /// sert à conclure, ce qui n'est pas la même chose.
    public var isDisplayAsleep: Bool

    /// Le pas d'horloge a sauté : la machine a dormi pendant l'intervalle.
    /// `WatchClock` le détecte déjà, et c'est le seul témoin d'une veille dont
    /// personne n'a reçu la notification.
    public var machineSlept: Bool

    /// L'inactivité clavier-souris. **`nil` veut dire capteur muet**, et c'est
    /// la seule valeur qui empêche de conclure.
    public var idleSeconds: TimeInterval?

    public init(
        isScreenLocked: Bool = false,
        isDisplayAsleep: Bool = false,
        machineSlept: Bool = false,
        idleSeconds: TimeInterval? = nil
    ) {
        self.isScreenLocked = isScreenLocked
        self.isDisplayAsleep = isDisplayAsleep
        self.machineSlept = machineSlept
        self.idleSeconds = idleSeconds
    }
}

extension Presence {

    /// Le seuil au-delà duquel une immobilité devient `idle`.
    ///
    /// **Deux minutes**, et le choix est contraint des deux côtés. En dessous,
    /// on fabrique une absence chaque fois que quelqu'un lit un paragraphe :
    /// l'inactivité clavier-souris ne distingue pas lire de partir. Au-dessus,
    /// on rate les vraies coupures courtes et le chrono « depuis la dernière
    /// pause » repart trop tard.
    ///
    /// Ce n'est **pas** le seuil qui fait une pause — celui-là vit dans
    /// `BreakSummary` et vaut cinq minutes. Deux seuils, deux questions : ici
    /// « est-ce que quelqu'un est aux commandes », là-bas « est-ce que ça
    /// compte comme une pause ».
    public static let idleAfter: TimeInterval = 120

    /// **La règle, en logique pure.** Ordre de certitude décroissante : le
    /// premier signal qui conclut l'emporte.
    ///
    /// - Returns: `nil` quand aucun capteur ne permet de conclure. L'appelant
    ///   n'écrit alors rien, et le trou dans le journal dit la vérité.
    public static func resolve(
        _ input: PresenceInput,
        idleAfter threshold: TimeInterval = Presence.idleAfter
    ) -> Presence? {
        // Les trois certitudes d'abord. Aucune ne demande d'interprétation :
        // une session verrouillée est une absence, point.
        if input.isScreenLocked { return .away }
        if input.machineSlept { return .away }
        if input.isDisplayAsleep { return .away }

        // Le capteur d'inactivité est le seul qui reste, et s'il est muet on ne
        // conclut pas. C'est le correctif CR-1 appliqué à la présence : ne
        // jamais deviner à la place d'un capteur absent.
        guard let idle = input.idleSeconds else { return nil }

        return idle >= threshold ? .idle : .present
    }
}

// MARK: - L'intervalle stocké

/// Un intervalle de présence, écrit dans le **même fichier-jour** que les
/// intervalles de voies.
///
/// **Pourquoi le même fichier et pas un fichier voisin.** `WatchRetention` purge
/// en lisant la date dans le nom, sur le format exact `AAAA-MM-JJ.jsonl` — un
/// `2026-08-07.presence.jsonl` ne serait reconnu par personne et ne serait donc
/// **jamais supprimé**. Réutiliser le fichier du jour hérite gratuitement de la
/// rétention, du roulement à minuit et du `FileHandle` déjà ouvert.
///
/// **Comment les deux formes cohabitent sans se marcher dessus.** `k` est requis
/// ici et absent de `WatchEvent` ; `lane` et `state` sont requis là-bas et
/// absents ici. Chacun des deux décodeurs échoue proprement sur les lignes de
/// l'autre, et le lecteur saute déjà les lignes illisibles — c'est la règle
/// écrite pour les coupures de courant, qui sert ici une deuxième fois.
///
/// **Et ce journal-là ne contient aucun titre de fenêtre.** Ni nom de client, ni
/// nom de projet, ni chemin : quatre champs, dont trois sont des instants. C'est
/// la partie du journal du veilleur qu'on peut garder sans rien risquer.
public struct PresenceEvent: Equatable, Sendable, Codable {

    /// Le discriminant. Requis, et c'est ce qui sépare les deux formes.
    public let k: String
    public static let kind = "p"

    public var v: Int = 1

    public let presence: Presence

    /// Horloge murale, pour l'affichage.
    public let from: Date
    public private(set) var to: Date

    /// La durée de l'intervalle, **en temps mural**.
    ///
    /// C'est la seule différence de fond avec `WatchEvent.d`, et elle est
    /// voulue. Là-bas, `d` exclut la veille parce qu'une voie ne travaille pas
    /// pendant que la machine dort : compter les huit heures de la nuit
    /// annoncerait huit heures de travail. Ici, c'est l'inverse — quelqu'un qui
    /// referme son capot est absent pendant huit heures pour de bon, et une
    /// pause qu'on ne compterait qu'en temps de veille durerait zéro seconde.
    ///
    /// La même quantité physique porte donc deux mesures différentes selon la
    /// question posée, et c'est pour ça que les deux journaux ne fusionnent pas.
    public private(set) var d: TimeInterval

    public init(presence: Presence, from: Date, to: Date, d: TimeInterval) {
        self.k = Self.kind
        self.presence = presence
        self.from = from
        self.to = to
        self.d = d
    }

    /// Rejette une ligne dont le discriminant n'est pas le nôtre, au lieu de la
    /// décoder à moitié.
    public init(from decoder: any Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try box.decode(String.self, forKey: .k)
        guard kind == Self.kind else {
            throw DecodingError.dataCorruptedError(
                forKey: .k, in: box, debugDescription: "ligne d'un autre type"
            )
        }
        self.k = kind
        self.v = try box.decodeIfPresent(Int.self, forKey: .v) ?? 1
        self.presence = try box.decode(Presence.self, forKey: .presence)
        self.from = try box.decode(Date.self, forKey: .from)
        self.to = try box.decode(Date.self, forKey: .to)
        self.d = try box.decode(TimeInterval.self, forKey: .d)
    }

    mutating func extend(to instant: Date, by elapsed: TimeInterval) {
        to = instant
        d += elapsed
    }

    /// Ramène la borne haute — et la durée avec elle — à un instant connu.
    /// Sert quand on apprend *après coup* qu'un intervalle s'est terminé plus
    /// tôt qu'on ne le croyait : le cas de la veille machine.
    mutating func close(at instant: Date) {
        to = max(from, instant)
        d = to.timeIntervalSince(from)
    }
}

/// La règle de fusion de la présence. Même forme que `WatchLedger`, et pour la
/// même raison : un battement toutes les quatre secondes écrirait 21 600 lignes
/// par jour pour une information qui change une vingtaine de fois.
///
/// Une seule différence, et elle est de fond : il n'y a **qu'un seul intervalle
/// ouvert**, parce qu'il n'y a qu'un seul humain. `WatchLedger` en tient un par
/// voie.
public struct PresenceLedger: Sendable {

    /// Tolérance avant qu'un battement manquant coupe l'intervalle. **2,5 fois
    /// le tic**, comme `WatchLedger` : absorbe un tic sauté sans fragmenter une
    /// pause en deux.
    public var pulse: TimeInterval

    private var open: (event: PresenceEvent, lastSeen: Date)?

    public init(tickInterval: TimeInterval) {
        self.pulse = tickInterval * 2.5
    }

    /// Enregistre la présence du battement. Rend l'intervalle **fermé** s'il y
    /// en a un à écrire, `nil` si l'intervalle courant s'est prolongé.
    public mutating func beat(
        _ presence: Presence,
        at instant: Date,
        elapsed: TimeInterval
    ) -> PresenceEvent? {
        guard var current = open else {
            open = (PresenceEvent(presence: presence, from: instant, to: instant, d: 0), instant)
            return nil
        }

        let onTime = instant.timeIntervalSince(current.lastSeen) <= pulse
        if current.event.presence == presence, onTime {
            current.event.extend(to: instant, by: elapsed)
            current.lastSeen = instant
            open = current
            return nil
        }

        // Le battement de la transition revient à l'intervalle qui se ferme :
        // même règle et même raison que `WatchLedger.beat`, où elle est écrite
        // en entier. Ici elle compte double, parce qu'une pause de cinq minutes
        // pile ne doit pas rater son seuil pour un tic manquant.
        if onTime {
            current.event.extend(to: instant, by: elapsed)
        }
        open = (PresenceEvent(presence: presence, from: instant, to: instant, d: 0), instant)
        return current.event
    }

    /// **Une veille machine, reconstruite après coup.**
    ///
    /// Le battement normal ne peut pas l'écrire : pendant que la machine dort,
    /// la boucle ne tourne pas, et au réveil elle ne voit qu'un tic en retard.
    /// `WatchClock.Step.slept` donne pourtant la durée exacte — c'est déjà lui
    /// qui déclenche l'oubli général — et sans cette méthode, une nuit de veille
    /// laisserait dans le journal de présence exactement le trou que ce type
    /// existe pour supprimer.
    ///
    /// L'intervalle est écrit **fermé**, aux deux bornes connues, et l'intervalle
    /// en cours est refermé d'abord : il s'arrête au début de la veille, pas au
    /// réveil.
    public mutating func slept(for seconds: TimeInterval, endingAt instant: Date) -> [PresenceEvent] {
        guard seconds > 0 else { return flush().map { [$0] } ?? [] }

        let start = instant.addingTimeInterval(-seconds)
        var written: [PresenceEvent] = []

        if var current = open?.event {
            // La borne haute de l'intervalle courant est le moment où la machine
            // s'est endormie, jamais le moment où elle s'est réveillée.
            current.close(at: min(current.to, start))
            written.append(current)
            open = nil
        }

        written.append(PresenceEvent(presence: .away, from: start, to: instant, d: seconds))
        return written
    }

    /// Ferme l'intervalle en cours. À appeler avant une veille, à la fermeture
    /// de l'application, au changement de jour et **quand le veilleur
    /// s'éteint** : sans ça, éteindre la veille à 18 h et la rallumer le
    /// lendemain écrirait une absence de quinze heures qui n'a jamais été
    /// observée.
    public mutating func flush() -> PresenceEvent? {
        defer { open = nil }
        return open?.event
    }
}
