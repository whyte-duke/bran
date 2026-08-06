import Foundation

/// L'état d'une voie de travail. **Priorité descendante : le premier satisfait
/// l'emporte.**
///
/// La révision 2 du plan listait ces états sans ordre de priorité, si bien
/// qu'une voie immobile depuis trois heures *avec* confirmation satisfaisait
/// `waiting` et `abandoned` en même temps. L'ordre est ici porté par
/// `Comparable`, pas par une convention à retenir.
public enum LaneState: String, Sendable, Codable, CaseIterable, Comparable {

    /// Immobile depuis plus de deux heures. Ce n'est plus une attente, c'est un
    /// abandon : ne pas déranger l'utilisateur avec ça.
    case abandoned

    /// Immobile depuis longtemps, mais sans confirmation d'un capteur certain.
    /// On ne sait pas si elle attend ou si elle est morte.
    case stale

    /// Elle a fini et elle vous attend. Le seul état qui justifie d'interrompre.
    case waiting

    /// Elle travaille.
    case working

    /// **On ne sait pas, et on le dit.** Signal d'inactivité mort, flux de
    /// capture tombé, réveil de veille. Correctif CR-1 : ne jamais deviner à la
    /// place d'un capteur absent — un échec silencieux est pire qu'un trou
    /// visible.
    case unknown

    private var rank: Int {
        switch self {
        case .abandoned: 0
        case .stale: 1
        case .waiting: 2
        case .working: 3
        case .unknown: 4
        }
    }

    public static func < (lhs: LaneState, rhs: LaneState) -> Bool {
        lhs.rank < rhs.rank
    }

    /// Est-ce que cet état mérite d'interrompre quelqu'un ?
    public var deservesAttention: Bool { self == .waiting }

    public var label: String {
        switch self {
        case .abandoned: "en sommeil"
        case .stale: "sans nouvelles"
        case .waiting: "vous attend"
        case .working: "travaille"
        case .unknown: "pas observable"
        }
    }

    /// L'ordre dans lequel l'utilisateur veut les voir — qui n'est pas l'ordre
    /// de priorité de la machine à états.
    ///
    /// Trier sur `rank` mettait `abandoned` en tête de liste : la première chose
    /// que l'œil rencontrait était ce qui ne le concerne plus. Ici, ce qui
    /// réclame une action passe devant.
    public var displayOrder: Int {
        switch self {
        case .waiting: 0
        case .working: 1
        case .stale: 2
        case .unknown: 3
        case .abandoned: 4
        }
    }

    public var symbol: String {
        switch self {
        case .abandoned: "moon.zzz"
        case .stale: "questionmark.circle"
        case .waiting: "bell.badge"
        case .working: "gearshape.2"
        case .unknown: "circle.dotted"
        }
    }
}
