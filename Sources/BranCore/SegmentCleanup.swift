import Foundation

/// Bilan de la suppression des morceaux intermédiaires, après une fusion
/// réussie.
///
/// **Un effacement raté ne doit jamais être rapporté comme un effacement.** Les
/// `<uuid>-segNNN.mp4` sont exclus de la bibliothèque par construction : ce sont
/// les pièces détachées d'une session, pas des enregistrements. S'ils survivent
/// à la fusion — volume plein, verrou d'un antivirus, dossier passé en lecture
/// seule — ils occupent des giga-octets qu'aucun écran ne montre et que personne
/// ne pense à aller chercher. Le fichier final, lui, est bien là : rien ne
/// signale l'anomalie.
public struct SegmentCleanup: Equatable, Sendable {

    /// Un morceau que le disque a refusé de rendre.
    public struct Leftover: Equatable, Sendable {
        public let name: String
        public let reason: String

        public init(name: String, reason: String) {
            self.name = name
            self.reason = reason
        }
    }

    public let removed: [String]
    public let leftovers: [Leftover]

    public init(removed: [String] = [], leftovers: [Leftover] = []) {
        self.removed = removed
        self.leftovers = leftovers
    }

    public var isClean: Bool { leftovers.isEmpty }

    /// Ce qu'on dit à l'utilisateur, ou `nil` quand tout est parti.
    ///
    /// Les noms sont cités : c'est ce qui rend le ménage possible à la main,
    /// et c'est la seule information que l'interface n'a nulle part ailleurs.
    public var problem: String? {
        guard leftovers.isEmpty == false else { return nil }

        let subject = leftovers.count == 1
            ? "Un morceau intermédiaire n'a pas pu être supprimé"
            : "\(leftovers.count) morceaux intermédiaires n'ont pas pu être supprimés"
        let names = leftovers.map(\.name).joined(separator: ", ")
        let reason = leftovers[0].reason

        return "\(subject) après la fusion : \(names) — \(reason). "
            + "Cette place reste occupée sans que rien ne l'indique dans la bibliothèque ; le fichier final, lui, est complet."
    }
}
