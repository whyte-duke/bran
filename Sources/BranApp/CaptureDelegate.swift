import Foundation
import ScreenCaptureKit

/// `SCStreamDelegate` et `SCRecordingOutputDelegate` sont des protocoles
/// Objective-C rappelés sur une queue arbitraire.
///
/// `@unchecked Sendable` justifié : les deux seules propriétés stockées sont
/// elles-mêmes `Sendable` et gèrent leur propre synchronisation. Il n'y a aucun
/// état mutable non protégé dans cette classe.
final class CaptureDelegate: NSObject, SCStreamDelegate, SCRecordingOutputDelegate, @unchecked Sendable {
    private let signals: CaptureSignals
    private let failures: AsyncStream<String>.Continuation

    init(signals: CaptureSignals, failures: AsyncStream<String>.Continuation) {
        self.signals = signals
        self.failures = failures
    }

    func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {}

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        signals.markFinished()
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
        report("écriture du fichier interrompue : \(error.localizedDescription)")
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        report("flux de capture interrompu : \(error.localizedDescription)")
    }

    private func report(_ reason: String) {
        signals.markFailed(reason)
        failures.yield(reason)
    }
}
