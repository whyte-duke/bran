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

    /// **L'humain était-il aux commandes de cette voie pendant cet intervalle ?**
    ///
    /// C'est le champ qui répond à la question la plus importante du produit :
    /// qu'est-ce qui compte comme du travail. Sans lui, la réponse implicite
    /// était « toute fenêtre visible dont plus de 1 % des blocs de luminance ont
    /// bougé » — mesuré sur deux jours de journal réel, 7,6 h sur 12,1 h, si
    /// bien que « Téléchargements » et « empty project » passaient devant le
    /// dossier client.
    ///
    /// `HumanFocus` mesure déjà l'information à chaque battement, et
    /// `WatchResolver` en tire un booléen local qu'il jette aussitôt. Elle ne
    /// manquait qu'au journal.
    ///
    /// Vrai dès que la voie a été au premier plan **une fois** pendant
    /// l'intervalle, l'humain étant présent au même moment. Pas « pendant tout
    /// l'intervalle » : personne ne regarde une fenêtre en continu pendant
    /// quarante minutes, et exiger la continuité rendrait le champ toujours faux.
    ///
    /// **Optional, et ce n'est pas un détail de style.** La synthèse `Codable`
    /// de Swift n'emploie pas les valeurs par défaut : un champ non optionnel
    /// ajouté ici rendrait illisible chaque ligne déjà écrite, et les deux
    /// lecteurs avalent l'échec de décodage en silence — un mois d'historique
    /// disparaîtrait sans un message. `nil` veut donc dire « journal antérieur à
    /// ce champ », ce qui n'est ni vrai ni faux et doit se lire comme tel.
    public private(set) var fg: Bool?

    public enum Source: String, Sendable, Codable {
        case certain, pixels, aucun
    }

    public init(
        lane: String, name: String, p: Int, state: LaneState,
        from: Date, to: Date, d: TimeInterval,
        src: Source, why: String,
        cwd: String? = nil, branch: String? = nil,
        fg: Bool? = nil
    ) {
        self.fg = fg
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

    /// **Le plafond d'une durée d'intervalle : 366 jours.**
    ///
    /// Ce n'est pas une borne de vraisemblance mais une borne de sûreté, et elle
    /// est volontairement très au-delà de tout ce que les deux journaux
    /// écrivent : un intervalle de voie est fermé à chaque changement de jour,
    /// et la plus longue absence imaginable est un Mac refermé pendant des
    /// vacances. Ce qu'elle refuse est ce qu'aucune horloge ne produit.
    public static let durationCeiling: TimeInterval = 366 * 86_400

    /// Cette durée peut-elle sortir d'une horloge ?
    ///
    /// Un `Double` de JSON accepte `1e308`, `-1`, `nan` et `inf` ; aucun n'est
    /// une durée mesurée, et tous font tomber la conversion en entier que
    /// l'affichage fait ensuite.
    static func isPlausibleDuration(_ value: TimeInterval) -> Bool {
        value.isFinite && value >= 0 && value <= durationCeiling
    }

    /// **Refuse au décodage ce qui ferait tomber le panneau.**
    ///
    /// `d` était un `Double` que rien ne validait. Mesuré : la ligne
    /// `{"v":1,"lane":"win:x",…,"d":1e308,…}` se décode sans un mot, puis
    /// l'affichage la convertit en entier et tue le processus — « Double value
    /// cannot be converted to Int because the result would be greater than
    /// Int.max ». La panne n'était pas une ligne perdue : c'était le panneau du
    /// veilleur devenu impossible à ouvrir, tous les jours, tant que la ligne
    /// restait dans le journal du jour.
    ///
    /// **Refuser plutôt que ramener à zéro** : une durée est ce qui fonde les
    /// totaux de la journée et de la semaine, et un zéro inventé se
    /// mélangerait aux vraies mesures sans plus jamais pouvoir s'en distinguer.
    /// Le magasin sait déjà compter une ligne illisible et le dire ; c'est là
    /// que celle-ci va.
    ///
    /// Le reste du décodage est celui que Swift synthétisait, à la lettre :
    /// `decodeIfPresent` pour chaque champ optionnel, sans quoi un journal
    /// antérieur à `fg` cesserait de se lire — la panne que la documentation de
    /// ce champ décrit.
    public init(from decoder: any Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        let duration = try box.decode(TimeInterval.self, forKey: .d)
        guard Self.isPlausibleDuration(duration) else {
            throw DecodingError.dataCorruptedError(
                forKey: .d, in: box, debugDescription: "durée impossible (\(duration))"
            )
        }

        self.v = try box.decode(Int.self, forKey: .v)
        self.lane = try box.decode(String.self, forKey: .lane)
        self.name = try box.decode(String.self, forKey: .name)
        self.p = try box.decode(Int.self, forKey: .p)
        self.state = try box.decode(LaneState.self, forKey: .state)
        self.from = try box.decode(Date.self, forKey: .from)
        self.to = try box.decode(Date.self, forKey: .to)
        self.d = duration
        self.src = try box.decode(Source.self, forKey: .src)
        self.why = try box.decode(String.self, forKey: .why)
        self.cwd = try box.decodeIfPresent(String.self, forKey: .cwd)
        self.branch = try box.decodeIfPresent(String.self, forKey: .branch)
        self.fg = try box.decodeIfPresent(Bool.self, forKey: .fg)
    }

    mutating func extend(to instant: Date, by elapsed: TimeInterval, foreground: Bool) {
        to = instant
        d += elapsed
        // Un « oui » ne se reprend pas : la voie a bien été au premier plan
        // pendant cet intervalle, même si elle ne l'est plus au battement
        // suivant. Et `nil` ne devient `false` que si l'on a vraiment observé —
        // ici on observe toujours, donc le `nil` d'un journal relu n'est jamais
        // écrasé, puisqu'on ne relit pas pour étendre.
        fg = (fg ?? false) || foreground
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
        source: WatchEvent.Source,
        foreground: Bool = false
    ) -> WatchEvent? {
        let key = lane.identity.key

        if var current = open[key] {
            let onTime = instant.timeIntervalSince(current.lastSeen) <= pulse
            if current.event.state == lane.state, onTime {
                current.event.extend(to: instant, by: elapsed, foreground: foreground)
                current.lastSeen = instant
                open[key] = current
                return nil
            }

            // **Le battement de la transition appartient à l'intervalle qui se
            // ferme, pas à celui qui s'ouvre.**
            //
            // Il n'appartenait à aucun des deux. L'intervalle sortant se fermait
            // sur son avant-dernier battement et le nouveau s'ouvrait à `d = 0` :
            // chaque changement d'état perdait un tic. Deux cents intervalles par
            // jour, c'est un quart d'heure évaporé sans que rien ne le dise ;
            // et un état qui ne dure qu'un seul battement — le cas exact d'une
            // voie qui alterne — s'écrivait avec une durée de zéro. Une journée
            // entière pouvait ainsi valoir zéro seconde dans le journal.
            //
            // Il revient au sortant parce que c'est lui qui l'a vécu : entre les
            // deux battements, l'état observé était l'ancien. Le nouveau, lui,
            // commence à l'instant présent et n'a encore rien duré.
            //
            // La propriété que ça rétablit, et que le test vérifie : la somme des
            // durées écrites vaut la somme des `elapsed` fournis.
            if onTime {
                current.event.extend(to: instant, by: elapsed, foreground: foreground)
            }
            open[key] = (start(lane, at: instant, source: source, foreground: foreground), instant)
            return current.event
        }

        open[key] = (start(lane, at: instant, source: source, foreground: foreground), instant)
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

    private func start(
        _ lane: Lane,
        at instant: Date,
        source: WatchEvent.Source,
        foreground: Bool
    ) -> WatchEvent {
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
            branch: lane.identity.branch,
            fg: foreground
        )
    }
}
