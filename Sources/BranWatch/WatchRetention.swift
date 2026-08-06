import Foundation

/// Combien de jours de journal on garde. Jumeau de `SnapshotRetention` et de
/// `RetentionPolicy` — troisième application du même contrat.
///
/// **Pourquoi elle est dans le premier jet et pas dans un second.** Le journal
/// du veilleur écrit des titres de fenêtres sur le disque : donc des noms de
/// documents, de projets et de clients, qui n'y étaient jamais avant. CR-3
/// protège le contenu des transcriptions ; rien ne protège les titres. On peut
/// supprimer un dossier, on ne peut pas ne pas l'avoir écrit — d'où une durée de
/// conservation courte par défaut, et un « zéro jour » offert à qui n'en veut
/// aucune trace.
///
/// **Un fichier par jour, et c'est la rétention qui l'impose.** Purger un
/// journal unique en ajout continu obligerait à le relire entièrement, le
/// filtrer, puis le réécrire — sur le fichier vivant. Purger un dossier de
/// fichiers datés, c'est lire un nom et supprimer. Aucune lecture, aucun risque.
public struct WatchRetention: Equatable, Sendable, Codable {

    /// Trente jours : assez pour voir une tendance sur un mois de travail, assez
    /// court pour qu'un nom de client ne traîne pas un an.
    public var days: Int

    public init(days: Int = 30) {
        self.days = days
    }

    public static let `default` = WatchRetention()

    public static let offeredDays = [0, 7, 30, 90, 365]

    /// Ne rien garder : le journal du jour est effacé à minuit.
    public var keepsNothing: Bool { days <= 0 }

    public var label: String {
        switch days {
        case 0: "Aucun journal conservé"
        case 1: "1 jour"
        case 365: "1 an"
        case let count: "\(count) jours"
        }
    }

    /// Les noms de fichiers à supprimer, sur le format `AAAA-MM-JJ.jsonl`.
    ///
    /// Prend des noms et rend des noms : aucun accès disque, donc testable en
    /// une milliseconde comme le reste du target.
    public func filesToPurge(from names: [String], today: String) -> [String] {
        names.filter { name in
            guard let day = Self.day(from: name) else { return false }
            guard day != today else { return false }          // jamais le fichier vivant
            guard keepsNothing == false else { return true }
            guard let age = Self.daysBetween(day, and: today) else { return false }
            return age >= days
        }
    }

    /// `2026-08-06.jsonl` → `2026-08-06`. Rend `nil` sur tout le reste, ce qui
    /// protège d'une suppression de fichier étranger déposé dans le dossier.
    static func day(from name: String) -> String? {
        guard name.hasSuffix(".jsonl") else { return nil }
        let stem = String(name.dropLast(6))
        let parts = stem.split(separator: "-")
        guard parts.count == 3,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isNumber) })
        else { return nil }
        return stem
    }

    /// Différence en jours entre deux dates `AAAA-MM-JJ`, via un calendrier
    /// grégorien en UTC. Le fuseau n'a pas d'importance ici : les deux chaînes
    /// sont produites par le même formateur, dans le même fuseau.
    static func daysBetween(_ from: String, and to: String) -> Int? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt

        guard let start = date(from, calendar), let end = date(to, calendar) else { return nil }
        return calendar.dateComponents([.day], from: start, to: end).day
    }

    private static func date(_ text: String, _ calendar: Calendar) -> Date? {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}
