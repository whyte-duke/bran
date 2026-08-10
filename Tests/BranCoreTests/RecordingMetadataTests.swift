import Foundation
import Testing
@testable import BranCore

@Suite("RecordingMetadata")
struct RecordingMetadataTests {

    /// Le même réglage que `JSONDecoder.bran` et `JSONEncoder.bran`, qui vivent
    /// dans la cible applicative : sans les dates ISO-8601, on testerait un
    /// format que personne n'écrit sur le disque.
    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// Une fiche telle qu'elle a été écrite sur le disque **avant** l'existence
    /// de `interruptionReason` : session ouverte, jamais close, aucune clé de
    /// motif. C'est la forme qu'ont tous les enregistrements déjà stockés.
    private let sidecarWrittenBeforeTheField = """
        {
          "attendees" : ["alice@example.com"],
          "id" : "0E7B1F52-4F9F-4B0E-9A9B-9F1A2B3C4D5E",
          "notes" : "",
          "segmentCount" : 2,
          "startedAt" : "2026-03-02T09:12:04Z",
          "title" : "Closing Dupont"
        }
        """

    // MARK: - Compatibilité du sidecar

    /// **Le test qui protège un mois de réunions.**
    ///
    /// Le décodage synthétisé par Swift n'utilise pas les valeurs par défaut :
    /// un champ non optionnel ajouté ici ferait échouer la lecture de tous les
    /// `.json` déjà écrits. Et comme les lecteurs avalent les échecs de
    /// décodage, la bibliothèque se viderait sans un message.
    @Test("Une fiche écrite avant le champ se décode encore")
    func olderSidecarStillDecodes() throws {
        let data = Data(sidecarWrittenBeforeTheField.utf8)
        let metadata = try decoder.decode(RecordingMetadata.self, from: data)

        #expect(metadata.title == "Closing Dupont")
        #expect(metadata.attendees == ["alice@example.com"])
        #expect(metadata.segmentCount == 2)
        #expect(metadata.endedAt == nil)
        #expect(metadata.interruptionReason == nil)
    }

    /// Date à la seconde entière : l'ISO-8601 du sidecar n'écrit pas les
    /// fractions, et une comparaison stricte échouerait sur `.now`.
    @Test("Le motif fait l'aller-retour par le disque")
    func reasonSurvivesARoundTrip() throws {
        var metadata = RecordingMetadata(
            id: UUID(), startedAt: Date(timeIntervalSince1970: 1_772_442_724)
        )
        metadata.interruptionReason = "finalisation impossible : délai dépassé"

        let restored = try decoder.decode(
            RecordingMetadata.self, from: encoder.encode(metadata)
        )

        #expect(restored == metadata)
        #expect(restored.interruptionReason == "finalisation impossible : délai dépassé")
    }

    /// Une fiche sans motif ne doit pas non plus écrire la clé : rien à dire,
    /// rien dans le fichier.
    @Test("Sans motif, la clé n'apparaît pas dans le fichier")
    func absentReasonWritesNoKey() throws {
        let metadata = RecordingMetadata(id: UUID(), startedAt: .now)
        let json = try String(decoding: encoder.encode(metadata), as: UTF8.self)

        #expect(json.contains("interruptionReason") == false)
    }

    // MARK: - Ce que la ligne affiche

    @Test("Interrompue sans motif : la phrase s'arrête à ce qu'on sait")
    func noteWithoutReasonInventsNothing() {
        let metadata = RecordingMetadata(id: UUID(), startedAt: .now)

        #expect(metadata.interruptionDetail == nil)
        #expect(metadata.interruptionNote == "Session jamais close proprement.")
        #expect(metadata.interruptionNote.localizedCaseInsensitiveContains("inconnu") == false)
    }

    @Test("Interrompue avec motif : le motif est dans la phrase")
    func noteCarriesTheReason() {
        var metadata = RecordingMetadata(id: UUID(), startedAt: .now)
        metadata.interruptionReason = "finalisation impossible : délai dépassé"

        #expect(metadata.interruptionDetail == "finalisation impossible : délai dépassé")
        #expect(metadata.interruptionNote.contains("finalisation impossible : délai dépassé"))
    }

    /// Un sidecar réparé à la main, ou un moteur qui échoue sans rien avoir à
    /// dire : une chaîne vide vaut absence, sinon la ligne s'arrêterait sur ses
    /// deux points.
    @Test("Un motif vide ou blanc vaut absence de motif", arguments: ["", "   ", "\n \t"])
    func blankReasonIsNoReason(_ blank: String) {
        var metadata = RecordingMetadata(id: UUID(), startedAt: .now)
        metadata.interruptionReason = blank

        #expect(metadata.interruptionDetail == nil)
        #expect(metadata.interruptionNote == "Session jamais close proprement.")
    }

    @Test("Le point final du motif ne se double pas")
    func trailingPeriodIsNotDoubled() {
        var metadata = RecordingMetadata(id: UUID(), startedAt: .now)
        metadata.interruptionReason = "le disque a été démonté."

        #expect(metadata.interruptionNote == "Session jamais close proprement : le disque a été démonté.")
        #expect(metadata.interruptionNote.contains("..") == false)
    }

    /// Le motif est nettoyé de ses blancs : un `\n` final rendrait une infobulle
    /// sur deux lignes dont la seconde est vide.
    @Test("Le motif est débarrassé de ses blancs")
    func reasonIsTrimmed() {
        var metadata = RecordingMetadata(id: UUID(), startedAt: .now)
        metadata.interruptionReason = "  démarrage impossible  \n"

        #expect(metadata.interruptionDetail == "démarrage impossible")
    }
}
