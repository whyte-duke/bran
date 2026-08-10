import Foundation
import Testing
@testable import BranCore

@Suite("StopVerdict")
struct StopVerdictTests {

    private func meeting() -> MeetingRef {
        MeetingRef(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000000BEEF")!,
            startedAt: Date(timeIntervalSince1970: 1_770_000_000),
            title: "Point hebdo produit",
            meetCode: "abc-defg-hij",
            calendarEventID: "EV-1",
            attendees: []
        )
    }

    @Test("Retour au repos → arrêt propre, la fin peut être horodatée")
    func idleIsComplete() {
        let verdict = StopVerdict(.idle)
        #expect(verdict == .complete)
        #expect(verdict.isSettled)
        #expect(verdict.writesEndedAt)
        #expect(verdict.consumesSegments)
        #expect(verdict.message == nil)
    }

    /// Le défaut R1, en une assertion : c'est `writesEndedAt` qui décide si la
    /// bibliothèque distingue un fichier entier d'un fichier tronqué.
    @Test("Échec → la fin n'est PAS horodatée : la sentinelle doit survivre")
    func failureNeverStampsTheEnd() {
        let verdict = StopVerdict(.failed(reason: "finalisation impossible : délai dépassé"))

        #expect(verdict.writesEndedAt == false)
        #expect(verdict.isSettled, "un échec est tranché : il ne faut pas attendre la machine")
        #expect(verdict.consumesSegments, "les minutes déjà capturées se récupèrent quand même")
    }

    @Test("Un échec se dit, et dit que le fichier peut être tronqué")
    func failureSpeaks() throws {
        let message = try #require(StopVerdict(.failed(reason: "flux interrompu")).message)
        #expect(message.contains("flux interrompu"))
        #expect(message.contains("tronqué"))
    }

    @Test("Session encore ouverte → on n'écrit rien et on ne consomme rien")
    func openStatesAreNotSettled() {
        let ref = meeting()
        for state in [RecordingState.starting(ref), .recording(ref), .paused(ref), .finalizing(ref)] {
            let verdict = StopVerdict(state)
            #expect(verdict == .stillOpen, "\(state) n'est pas un arrêt tranché")
            #expect(verdict.isSettled == false)
            #expect(verdict.writesEndedAt == false)
            #expect(verdict.consumesSegments == false, "vider les segments d'une session vivante les perdrait")
            #expect(verdict.message == nil)
        }
    }

    /// `.stop` reçu pendant `.starting` est mémorisé par la machine, qui
    /// finalisera elle-même. L'appelant qui conclurait à ce moment-là écrirait
    /// une fin de session sur un enregistrement qui commence.
    @Test("Le .stop différé pendant .starting ne conclut rien")
    func deferredStopConcludesNothing() {
        #expect(StopVerdict(.starting(meeting())).isSettled == false)
    }
}
