import Foundation

/// Deux durées de vie dans le même dossier.
///
/// L'audio est lourd et ne sert qu'à réessayer une transcription ratée ; le
/// texte est minuscule et c'est lui qu'on cherchera dans six mois. On purge
/// donc l'audio après une semaine et on garde le texte pour toujours.
///
/// Conséquence à ne pas manquer : **réessayer et purger sont couplés.** Au
/// huitième jour, l'audio n'existe plus. Le bouton « réessayer » ne doit pas
/// échouer, il doit être désactivé avec sa raison.
public struct RetentionPolicy: Equatable, Sendable, Codable {

    /// Durée de conservation de l'audio. Le texte n'est jamais supprimé
    /// automatiquement.
    public var audioLifetime: TimeInterval

    public init(audioLifetime: TimeInterval = 7 * 24 * 3600) {
        self.audioLifetime = audioLifetime
    }

    public static let `default` = RetentionPolicy()

    /// Les choix offerts dans les réglages, en jours.
    public static let offeredDays = [1, 3, 7, 14, 30]

    public var days: Int { Int((audioLifetime / 86_400).rounded()) }

    public static func days(_ count: Int) -> RetentionPolicy {
        RetentionPolicy(audioLifetime: TimeInterval(count) * 86_400)
    }

    /// Les entrées dont l'audio doit disparaître maintenant.
    ///
    /// Comparaison sur `>=` : une entrée qui atteint exactement la limite est
    /// purgée. Le contraire ferait traîner un fichier une journée de plus pour
    /// une raison que personne ne saurait expliquer.
    public func entriesToPurge(from entries: [TranscriptEntry], now: Date) -> [TranscriptEntry] {
        entries.filter { entry in
            guard entry.audioFileName != nil else { return false }
            return now.timeIntervalSince(entry.createdAt) >= audioLifetime
        }
    }

    /// Date à laquelle l'audio d'une entrée disparaîtra, pour pouvoir l'annoncer
    /// avant que ça arrive plutôt que de le constater après.
    public func expiryDate(for entry: TranscriptEntry) -> Date {
        entry.createdAt.addingTimeInterval(audioLifetime)
    }

    public var label: String {
        switch days {
        case 1: "1 jour"
        case let count: "\(count) jours"
        }
    }
}
