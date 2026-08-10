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

    // MARK: - Conclusion de la session (onSettled)
    //
    // `StopVerdict.stillOpen` interdit à l'appelant de conclure une session dont
    // l'arrêt a été différé. Il fallait bien que quelqu'un la conclue quand même :
    // sans ça, `endedAt` n'était jamais écrit, les segments jamais fusionnés, et
    // la bibliothèque affichait pour toujours une réunion « interrompue » que la
    // machine tenait, elle, pour proprement close.

    /// Ce que l'appelant reçoit, dans l'ordre.
    @MainActor
    final class Settlements {
        typealias Settlement = (meeting: MeetingRef, verdict: StopVerdict, segments: [URL])

        private(set) var all: [Settlement] = []
        var count: Int { all.count }
        var last: Settlement? { all.last }

        func append(_ settlement: Settlement) { all.append(settlement) }
    }

    /// Branche l'observateur **sans** vider les segments : chaque test décide.
    private func settlements(_ engine: RecordingEngine) -> Settlements {
        let log = Settlements()
        engine.onSettled = { [weak engine] meeting, verdict in
            log.append((meeting, verdict, engine?.segments ?? []))
        }
        return log
    }

    @Test("Un arrêt normal conclut la session")
    func nominalStopSettles() async throws {
        let engine = RecordingEngine(backend: FakeCaptureBackend())
        let log = settlements(engine)
        let ref = meeting()

        await engine.handle(.start(ref))
        #expect(log.count == 0, "une session qui démarre n'est pas une session close")

        await engine.handle(.stop)

        let settled = try #require(log.last)
        #expect(log.count == 1)
        #expect(settled.meeting == ref)
        #expect(settled.verdict == .complete)
        #expect(settled.segments.count == 1, "les segments sont encore là : l'appelant doit pouvoir les fusionner")
    }

    /// Le défaut S2, en une assertion.
    @Test("Le .stop différé pendant .starting conclut la session quand il aboutit")
    func deferredStopStillSettles() async throws {
        let ref = meeting()
        let engineBox = EngineBox()

        let backend = FakeCaptureBackend(.init(duringStart: {
            await engineBox.engine?.handle(.stop)
        }))
        let engine = RecordingEngine(backend: backend)
        engineBox.engine = engine
        let log = settlements(engine)

        await engine.handle(.start(ref))

        #expect(engine.state == .idle)
        let settled = try #require(log.last)
        #expect(log.count == 1, "l'arrêt différé conclut, et une seule fois")
        #expect(settled.meeting == ref, "la réunion à refermer est celle qu'on vient de démarrer")
        #expect(settled.verdict == .complete)
        #expect(settled.segments.count == 1, "le morceau écrit pendant .starting doit être fusionné, pas perdu")
    }

    @Test("Deux arrêts ne concluent qu'une fois")
    func doubleStopSettlesOnce() async {
        let engine = RecordingEngine(backend: FakeCaptureBackend())
        let log = settlements(engine)

        await engine.handle(.start(meeting()))
        await engine.handle(.stop)
        await engine.handle(.stop)
        await engine.handle(.stop)

        #expect(log.count == 1, "un clic de trop sur « arrêter » ne doit pas fusionner deux fois")
    }

    @Test("Deux arrêts différés pendant .starting ne concluent qu'une fois")
    func doubleDeferredStopSettlesOnce() async {
        let engineBox = EngineBox()

        let backend = FakeCaptureBackend(.init(duringStart: {
            await engineBox.engine?.handle(.stop)
            await engineBox.engine?.handle(.stop)
        }))
        let engine = RecordingEngine(backend: backend)
        engineBox.engine = engine
        let log = settlements(engine)

        await engine.handle(.start(meeting()))

        #expect(engine.state == .idle)
        #expect(log.count == 1)
    }

    @Test("Une finalisation en échec conclut quand même, avec son motif")
    func failedFinalizationSettlesAsFailure() async throws {
        let engine = RecordingEngine(backend: FakeCaptureBackend(.init(failOnStop: true)))
        let log = settlements(engine)

        await engine.handle(.start(meeting()))
        await engine.handle(.stop)

        let settled = try #require(log.last)
        #expect(log.count == 1)
        #expect(settled.verdict.writesEndedAt == false, "la sentinelle de session interrompue doit survivre")
        #expect(settled.verdict.consumesSegments, "les minutes capturées se récupèrent quand même")
        #expect(settled.segments.count == 1)
    }

    /// L'autre moitié du même trou : personne n'émet `.stop` sur une panne en
    /// cours de route, donc personne ne concluait la session. Les morceaux déjà
    /// écrits restaient sur le disque sous leur nom de segment, invisibles.
    @Test("Une panne en cours de route conclut la session")
    func midStreamFailureSettles() async throws {
        let engine = RecordingEngine(backend: FakeCaptureBackend())
        let log = settlements(engine)
        let ref = meeting()

        await engine.handle(.start(ref))
        engine.reportFailure("autorisation révoquée")

        let settled = try #require(log.last)
        #expect(log.count == 1)
        #expect(settled.meeting == ref, ".failed ne porte pas de réunion : la machine doit s'en souvenir")
        #expect(settled.verdict == .failed(reason: "autorisation révoquée"))
        #expect(settled.segments.count == 1)
    }

    @Test("Un démarrage en échec conclut la session qu'il n'a pas ouverte")
    func failedStartSettles() async throws {
        let engine = RecordingEngine(backend: FakeCaptureBackend(.init(failOnStart: true)))
        let log = settlements(engine)
        let ref = meeting()

        await engine.handle(.start(ref))

        let settled = try #require(log.last)
        #expect(log.count == 1, "la fiche a déjà été écrite avant le démarrage : il faut la refermer")
        #expect(settled.meeting == ref)
        #expect(settled.verdict.writesEndedAt == false)
    }

    @Test("Une pause en échec conclut la session")
    func failedPauseSettles() async {
        let engine = RecordingEngine(backend: FakeCaptureBackend(.init(failOnPause: true)))
        let log = settlements(engine)

        await engine.handle(.start(meeting()))
        await engine.pause()

        #expect(log.count == 1)
    }

    @Test("Rien à conclure sans session ouverte")
    func nothingSettlesWithoutASession() async {
        let engine = RecordingEngine(backend: FakeCaptureBackend())
        let log = settlements(engine)

        await engine.handle(.stop)
        engine.reportFailure("bruit")

        #expect(engine.state == .idle)
        #expect(log.count == 0)
    }

    @Test("Chaque session se conclut pour son compte")
    func eachSessionSettlesOnce() async {
        let engine = RecordingEngine(backend: FakeCaptureBackend())
        let log = settlements(engine)
        let first = meeting()
        let second = MeetingRef(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000000CAFE")!,
            startedAt: Date(timeIntervalSince1970: 1_770_001_000),
            title: "Revue client",
            meetCode: "zzz-yyyy-xxx",
            calendarEventID: "EV-2",
            attendees: []
        )

        await engine.handle(.start(first))
        await engine.handle(.stop)
        engine.clearSegments()

        await engine.handle(.start(second))
        await engine.handle(.stop)

        #expect(log.count == 2)
        #expect(log.all.map(\.meeting) == [first, second])
    }

    /// Après un échec, la session suivante doit pouvoir se conclure à son tour :
    /// le verrou d'unicité est par session, pas par machine.
    @Test("Une reprise après échec se conclut aussi")
    func settlesAgainAfterFailure() async {
        let engine = RecordingEngine(backend: FakeCaptureBackend())
        let log = settlements(engine)

        await engine.handle(.start(meeting()))
        engine.reportFailure("panne")
        engine.clearSegments()

        await engine.handle(.start(meeting()))
        await engine.handle(.stop)

        #expect(log.count == 2)
        #expect(log.all.map(\.verdict) == [.failed(reason: "panne"), .complete])
    }

    @Test("L'observateur est appelé après la transition, pas avant")
    func settlementFollowsTheTransition() async {
        let engine = RecordingEngine(backend: FakeCaptureBackend())
        let path = trace(engine)
        let stateAtSettle = StateBox()
        engine.onSettled = { [weak engine] _, _ in stateAtSettle.state = engine?.state }

        await engine.handle(.start(meeting()))
        await engine.handle(.stop)

        #expect(stateAtSettle.state == .idle, "conclure avant d'être à l'arrêt rejouerait le défaut d'origine")
        #expect(path.states.last == .idle)
    }

    @MainActor
    final class StateBox {
        var state: RecordingState?
    }
}

private extension RecordingState {
    var isFinalizing: Bool {
        if case .finalizing = self { true } else { false }
    }
}
