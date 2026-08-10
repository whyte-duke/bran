import Foundation

/// **Ce qu'une purge a réellement obtenu — pas ce qu'elle a tenté.**
///
/// `WatchRetention` décide *quels* fichiers doivent disparaître ; ce type dit
/// *lesquels* ont effectivement disparu. Les deux moitiés étaient confondues :
/// le compteur de la purge s'incrémentait après un `try?`, si bien qu'un fichier
/// que le système refusait de supprimer était compté comme supprimé. La
/// rétention annonçait alors « 4 journaux effacés » avec les quatre fichiers
/// toujours sur le disque.
///
/// Ce n'est pas un détail comptable. Le journal du veilleur écrit des titres de
/// fenêtres — mesuré sur deux jours réels : 165 noms distincts, dont des PDF
/// nommés d'après des personnes, des requêtes de recherche et un fragment
/// d'URL OAuth. C'est exactement pour ça que `WatchRetention` existe, et son
/// propre commentaire le dit : « on peut supprimer un dossier, on ne peut pas ne
/// pas l'avoir écrit ». Une rétention qui échoue en silence est pire que pas de
/// rétention du tout, parce que l'utilisateur croit la suppression faite.
///
/// **Pourquoi ici et pas dans le store.** Composer la phrase que l'utilisateur
/// lira est de la logique pure : des noms et des raisons entrent, une chaîne
/// sort. Dans `WatchStore`, elle serait sur `@MainActor`, mêlée à `FileManager`,
/// et dans une cible sans tests. Ici elle se teste en une milliseconde, comme
/// `filesToPurge` juste à côté.
public struct WatchPurgeReport: Equatable, Sendable {

    /// Un fichier que la rétention condamnait et que le disque a gardé.
    public struct Failure: Equatable, Sendable {
        public let file: String
        public let reason: String

        public init(file: String, reason: String) {
            self.file = file
            self.reason = reason
        }
    }

    /// Renseigné quand la purge n'a **pas pu commencer** : dossier illisible,
    /// volume débranché. Cas distinct d'un échec par fichier, parce qu'on ne
    /// sait même pas combien de journaux périmés sont concernés — donc il faut
    /// le dire autrement.
    public private(set) var blocked: String?

    /// Les fichiers qui ne sont plus là. « Plus là » inclut « déjà parti quand
    /// on est arrivé » : la rétention voulait leur absence, elle l'a obtenue.
    public private(set) var deleted: [String] = []

    public private(set) var failures: [Failure] = []

    public init() {}

    public static func blocked(by reason: String) -> WatchPurgeReport {
        var report = WatchPurgeReport()
        report.blocked = reason
        return report
    }

    public mutating func succeeded(_ file: String) {
        deleted.append(file)
    }

    public mutating func failed(_ file: String, reason: String) {
        failures.append(Failure(file: file, reason: reason))
    }

    /// Le nombre que la purge rend à son appelant. Il compte les fichiers
    /// **partis**, et c'est tout le correctif : il ne compte plus les tentatives.
    public var removed: Int { deleted.count }

    /// Vrai quand la rétention est tenue : rien n'a été empêché, rien n'a
    /// résisté. Un rapport vide est complet — il n'y avait rien à supprimer.
    public var isComplete: Bool { blocked == nil && failures.isEmpty }

    /// La phrase à afficher, ou `nil` quand il n'y a rien à signaler.
    ///
    /// Elle dit trois choses dans cet ordre, parce que c'est l'ordre dans lequel
    /// on les veut : ce qui n'a pas eu lieu, sur quoi, et pourquoi. Elle nomme
    /// les fichiers — sans eux, l'utilisateur ne peut ni vérifier ni supprimer à
    /// la main, et « une purge a échoué » ne serait qu'une inquiétude de plus.
    public var problem: String? {
        if let blocked {
            return """
                Rétention du journal non appliquée : le dossier de veille n'a pas pu être lu \
                (\(blocked)). Les journaux arrivés à échéance sont toujours sur le disque.
                """
        }

        guard failures.isEmpty == false else { return nil }

        let names = Self.list(failures.map(\.file))
        let why = Self.list(uniqueReasons, limit: 2, separator: " ; ")
        let count = failures.count
        let subject = count == 1
            ? "1 journal arrivé à échéance n'a pas pu être supprimé"
            : "\(count) journaux arrivés à échéance n'ont pas pu être supprimés"
        let warning = count == 1
            ? "Ce fichier contient des titres de fenêtres."
            : "Ces fichiers contiennent des titres de fenêtres."

        return "Rétention du journal non appliquée : \(subject) (\(names)) — \(why). \(warning)"
    }

    /// Dédoublonnées en gardant l'ordre de rencontre : trois fichiers sur le
    /// même volume débranché donnent trois fois la même phrase, et la répéter
    /// n'apprend rien.
    private var uniqueReasons: [String] {
        var seen = Set<String>()
        return failures.map(\.reason).filter { seen.insert($0).inserted }
    }

    /// « a, b et 3 autres ». Une liste complète de trente noms de fichiers dans
    /// un bandeau ne se lit pas ; trois noms suffisent à reconnaître le dossier
    /// en cause, et le compte dit l'ampleur.
    private static func list(
        _ items: [String],
        limit: Int = 3,
        separator: String = ", "
    ) -> String {
        guard items.count > limit else { return items.joined(separator: separator) }
        let shown = items.prefix(limit).joined(separator: separator)
        let rest = items.count - limit
        return rest == 1 ? "\(shown) et 1 autre" : "\(shown) et \(rest) autres"
    }
}
