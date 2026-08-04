import Foundation
import Synchronization
@testable import BranCore

/// Double de `CaptureSession`. Aucune ligne de ScreenCaptureKit dans les tests.
final class FakeCaptureBackend: CaptureBackend, Sendable {
    struct Behaviour: Sendable {
        var failOnStart = false
        var failOnStop = false
        var failOnPause = false

        /// Exécuté pendant que `start` est encore en vol. Permet de tester ce
        /// qui arrive à un `.stop` reçu en plein `.starting`.
        var duringStart: (@MainActor @Sendable () async -> Void)?
    }

    enum Call: Equatable, Sendable {
        case start(MeetingRef)
        case pause
        case resume
        case stop
    }

    struct Failure: Error, Equatable {
        let message: String
    }

    private let behaviour: Behaviour
    private let recorded = Mutex<[Call]>([])

    init(_ behaviour: Behaviour = Behaviour()) {
        self.behaviour = behaviour
    }

    var calls: [Call] { recorded.withLock { $0 } }

    func start(_ meeting: MeetingRef) async throws -> URL {
        recorded.withLock { $0.append(.start(meeting)) }
        await behaviour.duringStart?()
        if behaviour.failOnStart { throw Failure(message: "flux refusé") }
        return URL(fileURLWithPath: "/tmp/bran-test/\(meeting.id).mp4")
    }

    func pause() async throws {
        recorded.withLock { $0.append(.pause) }
        if behaviour.failOnPause { throw Failure(message: "pause impossible") }
    }

    func resume() async throws -> URL {
        let index = recorded.withLock { calls -> Int in
            calls.append(.resume)
            return calls.count(where: { $0 == .resume })
        }
        return URL(fileURLWithPath: "/tmp/bran-test/segment-\(index).mp4")
    }

    func stop() async throws {
        recorded.withLock { $0.append(.stop) }
        if behaviour.failOnStop { throw Failure(message: "écriture impossible") }
    }
}
