import Foundation
import Testing
@testable import BranWatch

/// **La clé de jour décide de trois choses d'un coup** : dans quel fichier une
/// ligne est écrite, quand les intervalles ouverts sont fermés, et quel fichier
/// la rétention supprime. Aucune des trois ne se remarque le jour même — elles
/// se remarquent un mois plus tard, sur un journal troué.
@Suite("Clé de jour du journal")
struct WatchDayTests {

    private func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone) ?? .gmt
        return calendar
    }

    private func date(_ zone: String, _ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
        let calendar = calendar(zone)
        return calendar.date(from: DateComponents(
            year: y, month: m, day: d, hour: h, minute: min
        )) ?? .distantPast
    }

    // MARK: - Le format

    @Test("Le format est AAAA-MM-JJ, zéros compris")
    func format() {
        let paris = calendar("Europe/Paris")
        #expect(WatchDay.key(for: date("Europe/Paris", 2026, 1, 1, 12, 0), calendar: paris) == "2026-01-01")
        #expect(WatchDay.key(for: date("Europe/Paris", 2026, 8, 6, 12, 0), calendar: paris) == "2026-08-06")
        #expect(WatchDay.key(for: date("Europe/Paris", 2026, 12, 31, 23, 59), calendar: paris) == "2026-12-31")
    }

    /// La clé écrite par le journal et la clé lue par la purge doivent être la
    /// même chaîne. Si l'une des deux dérive, la rétention cesse de reconnaître
    /// ses propres fichiers — et ne supprime plus rien, en silence.
    @Test("La clé écrite est celle que la rétention sait relire")
    func accordAvecLaRetention() {
        let key = WatchDay.key(for: date("Europe/Paris", 2026, 8, 6, 9, 0), calendar: calendar("Europe/Paris"))
        #expect(WatchRetention.day(from: "\(key).jsonl") == key)
    }

    /// Le jour est celui de l'utilisateur, pas celui de Greenwich. À 1 h 30 du
    /// matin à Paris, il est encore la veille en UTC : un journal qui pense en
    /// UTC se couperait en deux au milieu d'une nuit de travail.
    @Test("La journée se termine à minuit chez l'utilisateur, pas en UTC")
    func fuseauLocal() {
        let instant = date("Europe/Paris", 2026, 8, 6, 1, 30)
        #expect(WatchDay.key(for: instant, calendar: calendar("Europe/Paris")) == "2026-08-06")
        #expect(WatchDay.key(for: instant, calendar: calendar("UTC")) == "2026-08-05")
    }

    @Test("Deux instants du même jour local donnent la même clé")
    func memeJournee() {
        let paris = calendar("Europe/Paris")
        let matin = WatchDay.key(for: date("Europe/Paris", 2026, 8, 6, 0, 1), calendar: paris)
        let soir = WatchDay.key(for: date("Europe/Paris", 2026, 8, 6, 23, 59), calendar: paris)
        #expect(matin == soir)
    }

    // MARK: - Le changement de jour

    /// Un intervalle qui commence à 23 h 50 et se ferme à 8 h du matin
    /// appartiendrait à deux fichiers-jour à la fois, ce qui n'existe pas.
    @Test("Minuit franchi ferme le fichier ouvert")
    func minuitFranchi() {
        let paris = calendar("Europe/Paris")
        #expect(WatchDay.changed(
            from: "2026-08-05",
            at: date("Europe/Paris", 2026, 8, 6, 0, 1),
            calendar: paris
        ))
        #expect(WatchDay.changed(
            from: "2026-08-05",
            at: date("Europe/Paris", 2026, 8, 5, 23, 59),
            calendar: paris
        ) == false)
    }

    /// Sans fichier ouvert il n'y a rien à fermer. Répondre « oui » ferait vider
    /// le registre à chaque tic tant que la première ligne du jour n'est pas
    /// écrite — c'est-à-dire toute la matinée d'un utilisateur silencieux.
    @Test("Aucun fichier ouvert, aucun changement de jour")
    func aucunFichierOuvert() {
        #expect(WatchDay.changed(from: nil, at: .now) == false)
    }
}
