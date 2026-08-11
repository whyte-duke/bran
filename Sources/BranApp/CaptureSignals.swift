import BranCore
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

    /// Attend la finalisation **aussi longtemps que le fichier grossit**.
    ///
    /// L'échéance sèche d'avant (`waitForFinish(timeout: .seconds(60))`) a été
    /// retirée : `FinalizationWatch` explique pourquoi elle ne pouvait pas
    /// marcher au-delà de trois minutes d'enregistrement. Ici il ne reste que
    /// la mécanique — sonder, mesurer, rendre compte ; la décision est dans
    /// `BranCore`, où elle se teste sans dormir.
    ///
    /// - Parameters:
    ///   - bytesWritten: taille du fichier en cours d'écriture. Appelée deux
    ///     fois par seconde ; un `stat` est négligeable devant le travail de
    ///     `replayd`.
    func awaitFinish(
        watch: consuming FinalizationWatch,
        bytesWritten: @Sendable () -> Int64
    ) async -> FinalizationWatch.Verdict {
        let started = ContinuousClock.now

        while true {
            let (didFinish, failure) = storage.withLock { ($0.didFinish, $0.failure) }
            let verdict = watch.observe(
                bytesWritten: bytesWritten(),
                didFinish: didFinish,
                failure: failure,
                at: ContinuousClock.now - started
            )

            guard verdict.isSettled == false else { return verdict }

            try? await Task.sleep(for: .milliseconds(500))
        }
    }
}
