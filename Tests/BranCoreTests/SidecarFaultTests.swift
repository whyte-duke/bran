import Foundation
import Testing
@testable import BranCore

@Suite("SidecarFault")
struct SidecarFaultTests {

    private func missingFileError() -> NSError {
        NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError)
    }

    private func permissionError() -> NSError {
        NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
    }

    @Test("Fichier absent → cas normal, et muet")
    func absentIsNormalAndSilent() {
        let fault = SidecarFault.reading(missingFileError())
        #expect(fault == .absent)
        #expect(fault.isNormal)
        #expect(fault.listingNote(for: "X.json") == nil, "un .mp4 déposé à la main n'est pas un défaut")
    }

    @Test("Lecture refusée → ce n'est pas une absence, et ça se dit")
    func unreadableIsReported() throws {
        let fault = SidecarFault.reading(permissionError())
        guard case .unreadable = fault else {
            Issue.record("attendu .unreadable, reçu \(fault)")
            return
        }
        #expect(fault.isNormal == false)
        let note = try #require(fault.listingNote(for: "X.json"))
        #expect(note.contains("X.json"))
    }

    /// Le défaut R4 : un `.json` qui ne se décode pas effaçait le titre, les
    /// notes et le rattachement CRM, et la vidéo réapparaissait en orpheline
    /// sans un mot.
    @Test("Décodage impossible → corrompu, signalé, et non réécrit")
    func corruptIsReportedAndRecoverable() throws {
        let broken = Data("{ pas du json".utf8)
        var fault: SidecarFault?
        do {
            _ = try JSONDecoder().decode(RecordingMetadata.self, from: broken)
        } catch {
            fault = .decoding(error)
        }

        let observed = try #require(fault)
        guard case .corrupt = observed else {
            Issue.record("attendu .corrupt, reçu \(observed)")
            return
        }
        #expect(observed.isNormal == false)

        let note = try #require(observed.listingNote(for: "BEEF.json"))
        #expect(note.contains("BEEF.json"))
        #expect(note.contains("intacte"), "la vidéo n'est pas perdue, et il faut le dire")
        #expect(note.contains("main"), "la donnée est peut-être récupérable : il faut le dire aussi")
    }

    /// Un JSON syntaxiquement valide mais amputé d'un champ obligatoire est le
    /// cas réel le plus fréquent — écriture interrompue par un démontage.
    @Test("Champ obligatoire manquant → corrompu, pas absent")
    func truncatedPayloadIsCorrupt() {
        let partial = Data(#"{"id":"00000000-0000-0000-0000-00000000BEEF"}"#.utf8)
        do {
            _ = try JSONDecoder().decode(RecordingMetadata.self, from: partial)
            Issue.record("le décodage aurait dû échouer")
        } catch {
            #expect(SidecarFault.decoding(error).isNormal == false)
        }
    }

    @Test("En édition, même l'absence se dit : la saisie n'a nulle part où aller")
    func editingNoteIsNeverSilent() {
        for fault in [SidecarFault.absent, .unreadable("volume démonté"), .corrupt("caractère inattendu")] {
            let note = fault.editingNote(for: "BEEF.json")
            #expect(note.isEmpty == false)
            #expect(note.contains("non enregistrée"))
        }
    }

    @Test("Un sidecar corrompu n'est jamais écrasé, et l'utilisateur l'apprend")
    func corruptSidecarIsNotOverwritten() {
        let note = SidecarFault.corrupt("caractère inattendu").editingNote(for: "BEEF.json")
        #expect(note.contains("écrase pas"), "réécrire un .json corrompu détruirait la donnée récupérable")
    }
}
