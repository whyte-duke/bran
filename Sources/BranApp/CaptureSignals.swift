import Foundation
import Synchronization

/// État terminal de la capture, écrit par les callbacks ScreenCaptureKit (qui
/// arrivent sur une queue arbitraire) et lu par l'acteur `CaptureSession`.
///
/// Attente par sondage plutôt que par continuation : une continuation
/// qu'aucun événement ne vient résoudre suspend la tâche pour toujours. Un
/// sondage a toujours une échéance, et une échéance dépassée est un échec
/// visible plutôt qu'un blocage muet.
final class CaptureSignals: Sendable {
    private struct State {
        var didFinish = false
        var failure: String?
    }

    private let storage = Mutex(State())

    func reset() {
        storage.withLock { $0 = State() }
    }

    func markFinished() {
        storage.withLock { $0.didFinish = true }
    }

    func markFailed(_ reason: String) {
        storage.withLock { state in
            state.failure = state.failure ?? reason
            // Une défaillance débloque l'attente de finalisation : le fichier
            // n'arrivera jamais.
            state.didFinish = true
        }
    }

    var failure: String? {
        storage.withLock { $0.failure }
    }

    /// `true` si la finalisation a été signalée avant l'échéance.
    func waitForFinish(timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout

        while .now < deadline {
            if storage.withLock({ $0.didFinish }) {
                return storage.withLock { $0.failure == nil }
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }
}
