import Foundation
import Testing
@testable import BranCore

@Suite("RecordingEngine")
@MainActor
struct RecordingEngineTests {

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

    /// Collecte le chemin parcouru, pas seulement l'état final.
    private func trace(_ engine: RecordingEngine) -> Trace {
        let trace = Trace()
        engine.onTransition = { trace.append($0) }
        return trace
    }

    @MainActor
    final class Trace {
        private(set) var states: [RecordingState] = []
        func append(_ state: RecordingState) { states.append(state) }
    }

    @Test("Cycle nominal complet")
    func nominalCycle() async {
        let backend = FakeCaptureBackend()
        let engine = RecordingEngine(backend: backend)
        let path = trace(engine)
        let ref = meeting()

        await engine.handle(.start(ref))
        #expect(engine.state == .recording(ref))
        #expect(engine.currentFileURL?.lastPathComponent == "\(ref.id).mp4")

        await engine.handle(.stop)
        #expect(engine.state == .idle)

        // Les segments survivent à la finalisation : c'est l'appelant qui les
        // consomme (fusion, compression) puis appelle `clearSegments()`. Les
        // effacer ici perdrait les fichiers qu'on vient d'écrire.
        #expect(engine.segments.count == 1)
        engine.clearSegments()
        #expect(engine.currentFileURL == nil)

        #expect(path.states == [.starting(ref), .recording(ref), .finalizing(ref), .idle])
        #expect(backend.calls == [.start(ref), .stop])
    }

    @Test("Toute sortie de .recording passe par .finalizing")
    func exitAlwaysGoesThroughFinalizing() async throws {
        let backend = FakeCaptureBackend()
        let engine = RecordingEngine(backend: backend)
        let path = trace(engine)

        await engine.handle(.start(meeting()))
        await engine.handle(.stop)

        let finalizing = try #require(path.states.firstIndex { $0.isFinalizing })
        let idle = try #require(path.states.firstIndex(of: .idle))
        #expect(finalizing < idle, "l'état .idle ne doit jamais précéder .finalizing")
    }

    @Test(".start pendant .recording → ignoré")
    func startDuringRecordingIsIgnored() async {
        let backend = FakeCaptureBackend()
        let engine = RecordingEngine(backend: backend)
        let ref = meeting()

        await engine.handle(.start(ref))
        await engine.handle(.start(ref))
        await engine.handle(.start(ref))

        #expect(engine.state == .recording(ref))
        #expect(backend.calls == [.start(ref)], "un seul démarrage réel du flux")
    }

    @Test(".stop pendant .idle → ignoré")
    func stopWhileIdleIsIgnored() async {
        let backend = FakeCaptureBackend()
        let engine = RecordingEngine(backend: backend)

        await engine.handle(.stop)

        #expect(engine.state == .idle)
        #expect(backend.calls.isEmpty)
    }

    @Test("Échec du démarrage → .failed, jamais un faux .recording")
    func startFailureIsLoud() async {
        let backend = FakeCaptureBackend(.init(failOnStart: true))
        let engine = RecordingEngine(backend: backend)

        await engine.handle(.start(meeting()))

        guard case .failed(let reason) = engine.state else {
            Issue.record("attendu .failed, reçu \(engine.state)")
            return
        }
        #expect(reason.isEmpty == false)
    }

    @Test("Échec de la finalisation → .failed, pas un retour silencieux à .idle")
    func finalizationFailureIsLoud() async {
        let backend = FakeCaptureBackend(.init(failOnStop: true))
        let engine = RecordingEngine(backend: backend)

        await engine.handle(.start(meeting()))
        await engine.handle(.stop)

        guard case .failed = engine.state else {
            Issue.record("attendu .failed, reçu \(engine.state)")
            return
        }
    }

    @Test("Défaillance du flux en cours de route → .failed")
    func midStreamFailure() async {
        let backend = FakeCaptureBackend()
        let engine = RecordingEngine(backend: backend)

        await engine.handle(.start(meeting()))
        engine.reportFailure("autorisation révoquée")

        #expect(engine.state == .failed(reason: "autorisation révoquée"))
    }

    @Test("Une défaillance signalée à l'arrêt ne réveille pas la machine")
    func failureWhileIdleIsIgnored() {
        let engine = RecordingEngine(backend: FakeCaptureBackend())
        engine.reportFailure("bruit")
        #expect(engine.state == .idle)
    }

    @Test("Après un échec, un nouveau .start relance")
    func recoversAfterFailure() async {
        let backend = FakeCaptureBackend()
        let engine = RecordingEngine(backend: backend)
        let ref = meeting()

        engine.reportFailure("panne")     // ignoré : à l'arrêt
        await engine.handle(.start(ref))
        #expect(engine.state == .recording(ref))
    }

    // MARK: - Pause et reprise

    @Test("Pause puis reprise : deux segments, un seul démarrage de session")
    func pauseThenResumeAccumulatesSegments() async {
        let backend = FakeCaptureBackend()
        let engine = RecordingEngine(backend: backend)
        let ref = meeting()

        await engine.handle(.start(ref))
        #expect(engine.segments.count == 1)

        await engine.pause()
        #expect(engine.state == .paused(ref))
        #expect(engine.segments.count == 1, "la pause n'ouvre pas de segment")

        await engine.resume()
        #expect(engine.state == .recording(ref))
        #expect(engine.segments.count == 2)

        await engine.handle(.stop)
        #expect(engine.state == .idle)
        #expect(engine.segments.count == 2, "les segments survivent à la finalisation")
    }

    @Test("Arrêt depuis .paused : pas de second stop du flux déjà fermé")
    func stopFromPausedDoesNotStopTwice() async {
        let backend = FakeCaptureBackend()
        let engine = RecordingEngine(backend: backend)
        let ref = meeting()
        let path = trace(engine)

        await engine.handle(.start(ref))
        await engine.pause()
        await engine.handle(.stop)

        #expect(engine.state == .idle)
        #expect(backend.calls == [.start(ref), .pause], "stop() ne doit pas refermer un segment déjà fermé")
        #expect(path.states.contains { $0.isFinalizing }, "la sortie passe quand même par .finalizing")
    }

    @Test("Pause hors enregistrement → ignorée")
    func pauseOutsideRecordingIsIgnored() async {
        let backend = FakeCaptureBackend()
        let engine = RecordingEngine(backend: backend)

        await engine.pause()
        #expect(engine.state == .idle)

        await engine.resume()
        #expect(engine.state == .idle)
        #expect(backend.calls.isEmpty)
    }

    @Test(".start pendant .paused → ignoré")
    func startDuringPauseIsIgnored() async {
        let backend = FakeCaptureBackend()
        let engine = RecordingEngine(backend: backend)
        let ref = meeting()

        await engine.handle(.start(ref))
        await engine.pause()
        await engine.handle(.start(ref))

        #expect(engine.state == .paused(ref))
        #expect(engine.segments.count == 1, "aucun segment fantôme")
    }

    @Test("Échec de la pause → .failed, pas un faux .paused")
    func pauseFailureIsLoud() async {
        let backend = FakeCaptureBackend(.init(failOnPause: true))
        let engine = RecordingEngine(backend: backend)

        await engine.handle(.start(meeting()))
        await engine.pause()

        guard case .failed = engine.state else {
            Issue.record("attendu .failed, reçu \(engine.state)")
            return
        }
    }

    @Test("Un nouveau départ repart d'une liste de segments vide")
    func restartClearsSegments() async {
        let backend = FakeCaptureBackend()
        let engine = RecordingEngine(backend: backend)

        await engine.handle(.start(meeting()))
        await engine.pause()
        await engine.resume()
        await engine.handle(.stop)
        #expect(engine.segments.count == 2)

        await engine.handle(.start(meeting()))
        #expect(engine.segments.count == 1, "les segments de la session précédente ne doivent pas fuiter")
    }

    @Test(".stop reçu pendant .starting n'est pas perdu")
    func stopDuringStartingIsHonoured() async {
        let ref = meeting()
        let engineBox = EngineBox()

        // Le backend rend la main lentement : `.stop` arrive alors que la
        // machine est encore dans `.starting`. Le résolveur n'émet `.stop`
        // qu'une seule fois — le perdre laisserait l'enregistrement tourner
        // indéfiniment.
        let backend = FakeCaptureBackend(.init(duringStart: {
            await engineBox.engine?.handle(.stop)
        }))
        let engine = RecordingEngine(backend: backend)
        engineBox.engine = engine
        let path = trace(engine)

        await engine.handle(.start(ref))

        #expect(engine.state == .idle)
        #expect(backend.calls == [.start(ref), .stop])
        #expect(path.states == [.starting(ref), .recording(ref), .finalizing(ref), .idle])
    }

    @MainActor
    final class EngineBox {
        var engine: RecordingEngine?
    }
}

private extension RecordingState {
    var isFinalizing: Bool {
        if case .finalizing = self { true } else { false }
    }
}
