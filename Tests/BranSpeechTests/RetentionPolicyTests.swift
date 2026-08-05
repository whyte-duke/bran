import Foundation
import Testing
@testable import BranSpeech

@Suite("Politique de rétention")
struct RetentionPolicyTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func entry(daysAgo: Double, hasAudio: Bool = true) -> TranscriptEntry {
        TranscriptEntry(
            createdAt: now.addingTimeInterval(-daysAgo * 86_400),
            duration: 12,
            text: "bonjour",
            audioFileName: hasAudio ? "a.wav" : nil
        )
    }

    @Test("L'audio de plus d'une semaine est purgé")
    func purgesOldAudio() {
        let policy = RetentionPolicy.default
        let old = entry(daysAgo: 8)
        let fresh = entry(daysAgo: 2)

        let purged = policy.entriesToPurge(from: [old, fresh], now: now)
        #expect(purged.map(\.id) == [old.id])
    }

    /// La limite exacte. Sans ce test, un `>` au lieu d'un `>=` fait traîner un
    /// fichier une journée de plus pour une raison que personne ne sait
    /// expliquer.
    @Test("Pile à la limite, l'audio est purgé")
    func purgesExactlyAtBoundary() {
        let policy = RetentionPolicy.default
        let borderline = entry(daysAgo: 7)

        #expect(policy.entriesToPurge(from: [borderline], now: now).count == 1)
    }

    @Test("Une entrée déjà purgée n'est pas repurgée")
    func skipsEntriesWithoutAudio() {
        let policy = RetentionPolicy.default
        let purgedAlready = entry(daysAgo: 30, hasAudio: false)

        #expect(policy.entriesToPurge(from: [purgedAlready], now: now).isEmpty)
    }

    @Test("Le texte n'est jamais concerné par la purge")
    func textSurvivesForever() {
        let policy = RetentionPolicy.default
        let ancient = entry(daysAgo: 400)

        let purged = policy.entriesToPurge(from: [ancient], now: now)
        // On ne renvoie que des entrées dont l'audio doit partir : le texte de
        // ces mêmes entrées reste sur le disque.
        #expect(purged.count == 1)
        #expect(purged[0].text == "bonjour")
    }

    @Test("Une liste vide ne provoque rien")
    func emptyListIsFine() {
        #expect(RetentionPolicy.default.entriesToPurge(from: [], now: now).isEmpty)
    }

    @Test("Une durée personnalisée est respectée")
    func honoursCustomLifetime() {
        let policy = RetentionPolicy.days(1)
        #expect(policy.entriesToPurge(from: [entry(daysAgo: 2)], now: now).count == 1)
        #expect(policy.entriesToPurge(from: [entry(daysAgo: 0.5)], now: now).isEmpty)
    }

    @Test("La date d'expiration permet de prévenir avant, pas de constater après")
    func announcesExpiry() {
        let policy = RetentionPolicy.days(3)
        let subject = entry(daysAgo: 0)

        let expiry = policy.expiryDate(for: subject)
        #expect(abs(expiry.timeIntervalSince(now) - 3 * 86_400) < 1)
    }

    @Test("L'étiquette se lit en français")
    func labelReadsWell() {
        #expect(RetentionPolicy.days(1).label == "1 jour")
        #expect(RetentionPolicy.days(7).label == "7 jours")
    }

    @Test("Toutes les durées proposées font un aller-retour propre")
    func offeredDaysRoundTrip() {
        for count in RetentionPolicy.offeredDays {
            #expect(RetentionPolicy.days(count).days == count)
        }
    }
}
