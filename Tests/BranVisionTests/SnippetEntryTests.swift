import Foundation
import Testing
@testable import BranVision

@Suite("Entrée d'historique et rétention")
struct SnippetEntryTests {

    // MARK: - La leçon qui a déjà coûté deux allers-retours

    @Test("Une entrée écrite par une version antérieure reste lisible")
    func compatibiliteAscendante() throws {
        // Le `Decodable` synthétisé ignore les valeurs par défaut. Un champ non
        // optionnel ajouté à `SnippetEntry` rendrait illisibles, d'un coup,
        // toutes les captures déjà sur le disque. Ce test gèle le contrat :
        // seuls id, createdAt et text sont exigés.
        let json = """
        {
          "id": "8B0D5F2E-1C4A-4E3B-9A7D-2F6C1E0A5B33",
          "createdAt": 1786000000,
          "text": "public struct DictationMachine: Sendable {"
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let entry = try decoder.decode(SnippetEntry.self, from: Data(json.utf8))

        #expect(entry.text.hasPrefix("public struct"))
        #expect(entry.layout == nil)
        #expect(entry.engine == nil)
        #expect(entry.imageFileName == nil)
        #expect(entry.canRetry == false)
    }

    @Test("Un aller-retour d'encodage conserve tout")
    func allerRetour() throws {
        let entry = SnippetEntry(
            createdAt: Date(timeIntervalSince1970: 1_786_000_000),
            text: "case .idle",
            rawText: "case •idle",
            layout: .monospaced,
            engine: "vision",
            confidence: 0.94,
            processingTime: 0.188,
            repairCount: 1,
            sourceApp: "Terminal",
            imageFileName: "capture.png",
            pixelWidth: 942,
            pixelHeight: 420
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        let round = try decoder.decode(SnippetEntry.self, from: encoder.encode(entry))
        #expect(round == entry)
    }

    // MARK: - Ce que la liste affiche

    @Test("Le décompte de mots, lignes et caractères")
    func decomptes() {
        let entry = SnippetEntry(createdAt: .now, text: "une ligne\net une autre")
        #expect(entry.wordCount == 5)
        #expect(entry.lineCount == 2)
        // 9 + 1 (le saut de ligne) + 12
        #expect(entry.characterCount == 22)
        #expect(entry.sizeDescription == "2 lignes · 22 caractères")
    }

    @Test("Une capture d'une seule ligne n'annonce pas ses lignes")
    func uneSeuleLigne() {
        let entry = SnippetEntry(createdAt: .now, text: "bonjour")
        #expect(entry.sizeDescription == "7 caractères")
    }

    @Test("Un texte vide ne compte aucune ligne")
    func texteVide() {
        let entry = SnippetEntry(createdAt: .now, text: "")
        #expect(entry.lineCount == 0)
        #expect(entry.wordCount == 0)
    }

    @Test("Un échec s'affiche à la place d'un texte vide")
    func apercuDUnEchec() {
        let entry = SnippetEntry(createdAt: .now, text: "", failure: "moteur indisponible")
        #expect(entry.previewText == "moteur indisponible")
        #expect(entry.isFailed)
    }

    @Test("Un texte présent l'emporte sur un échec enregistré")
    func texteAvantEchec() {
        let entry = SnippetEntry(createdAt: .now, text: "du texte", failure: "un avertissement")
        #expect(entry.previewText == "du texte")
    }

    // MARK: - Rétention

    @Test("Une image atteignant exactement la limite est purgée")
    func purgeALaLimite() {
        let policy = SnapshotRetention.days(7)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let entry = SnippetEntry(
            createdAt: now.addingTimeInterval(-7 * 86_400),
            text: "x",
            imageFileName: "a.png"
        )
        #expect(policy.entriesToPurge(from: [entry], now: now).count == 1)
    }

    @Test("Une image d'une seconde plus jeune survit")
    func survivantALaLimite() {
        let policy = SnapshotRetention.days(7)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let entry = SnippetEntry(
            createdAt: now.addingTimeInterval(-7 * 86_400 + 1),
            text: "x",
            imageFileName: "a.png"
        )
        #expect(policy.entriesToPurge(from: [entry], now: now).isEmpty)
    }

    @Test("Une entrée sans image n'est jamais purgée deux fois")
    func pasDeDoublePurge() {
        let policy = SnapshotRetention.days(1)
        let now = Date()
        let entry = SnippetEntry(createdAt: now.addingTimeInterval(-86_400 * 30), text: "x")
        #expect(policy.entriesToPurge(from: [entry], now: now).isEmpty)
    }

    @Test("Zéro jour signifie qu'aucune image n'est conservée")
    func aucuneConservation() {
        let policy = SnapshotRetention.days(0)
        #expect(policy.keepsNothing)
        #expect(policy.label == "Aucune image conservée")
    }

    @Test("Les durées proposées sont ordonnées et commencent à zéro")
    func dureesProposees() {
        #expect(SnapshotRetention.offeredDays.first == 0)
        #expect(SnapshotRetention.offeredDays == SnapshotRetention.offeredDays.sorted())
    }

    @Test("La date d'expiration est annonçable avant qu'elle arrive")
    func dateDExpiration() {
        let policy = SnapshotRetention.days(3)
        let created = Date(timeIntervalSince1970: 1_800_000_000)
        let entry = SnippetEntry(createdAt: created, text: "x", imageFileName: "a.png")
        #expect(policy.expiryDate(for: entry) == created.addingTimeInterval(3 * 86_400))
    }
}
