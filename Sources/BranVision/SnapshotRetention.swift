import Foundation

/// Deux durées de vie dans le même dossier, comme pour la dictée.
///
/// L'image est lourde et ne sert qu'à relire ; le texte est minuscule et c'est
/// lui qu'on cherchera dans six mois. On purge donc l'image après une semaine
/// et on garde le texte pour toujours.
///
/// **Ce que coûte vraiment une image** — mesuré sur trois captures de zones de
/// texte réelles : 156 Ko, 247 Ko et 265 Ko. Dix captures par jour pendant un
/// mois font environ 75 Mo, pas le gigaoctet qu'on imagine. La rétention par
/// défaut peut donc rester alignée sur celle de l'audio sans remords.
///
/// **Pourquoi garder l'image alors qu'une relecture rend le même texte.** Avec
/// un moteur déterministe, relancer à l'identique ne sert à rien. Ce qui sert :
/// relire la même zone dans l'autre mode de mise en page — une sortie de
/// terminal lue comme de la prose perd ses colonnes — et la relire plus tard
/// avec un meilleur moteur. Sans l'image, ces deux réparations sont impossibles.
public struct SnapshotRetention: Equatable, Sendable, Codable {

    /// Durée de conservation des images. Le texte n'est jamais supprimé
    /// automatiquement.
    public var imageLifetime: TimeInterval

    public init(imageLifetime: TimeInterval = 7 * 24 * 3600) {
        self.imageLifetime = imageLifetime
    }

    public static let `default` = SnapshotRetention()

    /// Les choix offerts dans les réglages, en jours. Zéro est proposé pour qui
    /// capture des informations sensibles et ne veut aucune image sur le disque.
    public static let offeredDays = [0, 1, 3, 7, 14, 30]

    public var days: Int { Int((imageLifetime / 86_400).rounded()) }

    public static func days(_ count: Int) -> SnapshotRetention {
        SnapshotRetention(imageLifetime: TimeInterval(count) * 86_400)
    }

    /// Ne conserver aucune image : elle est effacée dès la lecture terminée.
    public var keepsNothing: Bool { imageLifetime <= 0 }

    /// Les entrées dont l'image doit disparaître maintenant.
    ///
    /// Comparaison sur `>=`, comme `RetentionPolicy` : une entrée qui atteint
    /// exactement la limite est purgée. Le contraire ferait traîner un fichier
    /// une journée de plus pour une raison inexplicable.
    public func entriesToPurge(from entries: [SnippetEntry], now: Date) -> [SnippetEntry] {
        entries.filter { entry in
            guard entry.imageFileName != nil else { return false }
            return now.timeIntervalSince(entry.createdAt) >= imageLifetime
        }
    }

    public func expiryDate(for entry: SnippetEntry) -> Date {
        entry.createdAt.addingTimeInterval(imageLifetime)
    }

    public var label: String {
        switch days {
        case 0: "Aucune image conservée"
        case 1: "1 jour"
        case let count: "\(count) jours"
        }
    }
}
