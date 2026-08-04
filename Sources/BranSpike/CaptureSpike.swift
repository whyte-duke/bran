import AVFoundation
import Foundation
import ScreenCaptureKit
import Synchronization

/// Barrière Phase 1.
///
/// Le plan prévoyait `SCStream` → `AVAssetWriter` avec trois flux à muxer à la
/// main. Les en-têtes du SDK montrent que l'audio système sort au format
/// `sampleRate`/`channelCount` de la configuration tandis que le micro sort au
/// « native format » du périphérique : deux formats, donc un mixage manuel.
///
/// `SCRecordingOutput` (macOS 15+) écrit lui-même le `.mp4` complet. Ce spike
/// teste cette voie en premier, parce que si elle passe, tout le mixage manuel
/// et toute la manipulation de `CMSampleBuffer` disparaissent du projet.
struct CaptureSpike {
    let duration: Duration
    let output: URL?

    /// Multiplicateur appliqué à la résolution en points de l'écran.
    /// 1,0 = résolution logique (≈1 Go/h). 2,0 = Retina natif (≈4 Go/h).
    let scale: Double

    let codec: AVVideoCodecType

    func run() async throws {
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            throw ProbeError.screenRecordingDenied
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw CaptureSpikeError.noDisplay }

        // L'overlay de la Phase 5 se filmerait lui-même si l'app n'était pas
        // exclue de sa propre capture. On installe l'exclusion dès le spike.
        let ownApplication = content.applications.first {
            $0.processID == ProcessInfo.processInfo.processIdentifier
        }
        let filter = SCContentFilter(
            display: display,
            excludingApplications: ownApplication.map { [$0] } ?? [],
            exceptingWindows: []
        )

        let configuration = SCStreamConfiguration()
        // H.264 exige des dimensions paires — l'écran fait 1117 points de haut.
        configuration.width = evenDimension(Double(display.width) * scale)
        configuration.height = evenDimension(Double(display.height) * scale)
        configuration.captureResolution = scale > 1 ? .best : .nominal
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.showsCursor = true
        configuration.capturesAudio = true                  // les participants
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.excludesCurrentProcessAudio = true    // pas de larsen
        configuration.captureMicrophone = true              // soi-même
        configuration.captureDynamicRange = .SDR            // HDR + recordingOutput = échec, cf. en-tête

        let destination = try output ?? makeOutputURL()
        let recordingConfiguration = SCRecordingOutputConfiguration()
        recordingConfiguration.outputURL = destination
        recordingConfiguration.outputFileType = .mp4
        recordingConfiguration.videoCodecType = codec

        let (events, continuation) = AsyncStream.makeStream(of: CaptureEvent.self)
        let delegate = CaptureSpikeDelegate(continuation: continuation)

        // Un seul consommateur du flux d'événements, vivant du début à la fin.
        // Il journalise et met à jour l'état terminal ; personne d'autre ne
        // touche à `events`.
        let state = CaptureState()
        let consumer = Task {
            for await event in events {
                print(event.line)
                state.record(event)
            }
        }

        let stream = SCStream(filter: filter, configuration: configuration, delegate: delegate)
        let recordingOutput = SCRecordingOutput(configuration: recordingConfiguration, delegate: delegate)

        // L'en-tête est explicite : ajouter la sortie AVANT startCapture est la
        // seule façon de garantir que la toute première frame atterrit dans le fichier.
        try stream.addRecordingOutput(recordingOutput)

        print("→ écran \(display.width)×\(display.height) pts → capture \(configuration.width)×\(configuration.height) (×\(scale.formatted())), \(codec.rawValue), 30 fps")
        print("→ sortie : \(destination.path)")
        print("→ durée : \(duration)\n")

        try await stream.startCapture()
        print("● enregistrement en cours — parlez, et faites parler quelqu'un d'autre")
        print("  (test de résilience : depuis un autre terminal, `kill -9 \(ProcessInfo.processInfo.processIdentifier)`)")

        // Enregistrement en cours. On s'arrête à l'échéance OU à la première
        // défaillance : dormir 30 s après la mort du flux, c'est exactement la
        // panne silencieuse que le §10 du plan interdit.
        try await state.waitUntil(deadline: .now + duration) { $0.failure != nil }

        // `stopCapture()` retire la sortie d'enregistrement ET finalise le
        // fichier. Appeler `removeRecordingOutput()` avant, c'est provoquer un
        // double `exportAndInvalidate` sur le même SCAssetWriter : l'export
        // échoue et le .mp4 n'est jamais écrit. Vérifié dans les logs de replayd.
        try? await stream.stopCapture()

        if let failure = state.snapshot.failure {
            print("\n■ arrêt sur défaillance : \(failure.line)")
        } else {
            print("\n■ arrêt demandé — finalisation…")
        }

        // ÉTAT .finalizing. `stopCapture()` rend la main avant que replayd ait
        // fini d'écrire le conteneur ; le fichier n'existe pas encore à cet
        // instant. Il faut attendre `recordingOutputDidFinishRecording`.
        try await state.waitUntil(deadline: .now + .seconds(30)) {
            $0.didFinish || $0.failure != nil
        }
        continuation.finish()
        consumer.cancel()

        if state.snapshot.didFinish == false, state.snapshot.failure == nil {
            print("⚠︎ aucun signal de finalisation après 30 s — le fichier peut être incomplet")
        }
        print()

        try await FileReport.print(for: destination)
    }

    private func evenDimension(_ value: Double) -> Int {
        let rounded = Int(value.rounded())
        return rounded.isMultiple(of: 2) ? rounded : rounded + 1
    }

    private func makeOutputURL() throws -> URL {
        try FileStamp.storageRoot().appending(path: "spike-\(FileStamp.now).mp4")
    }
}

/// État terminal de la capture, écrit par le consommateur d'événements et lu
/// par le flux principal.
///
/// Attente par sondage plutôt que par continuation : une continuation en attente
/// qu'aucun événement ne vient résoudre bloque le processus pour toujours — et
/// « bloqué pour toujours » est le mode d'échec que ce projet ne peut pas se
/// permettre. Un sondage à 100 ms a toujours une échéance.
final class CaptureState: Sendable {
    struct Snapshot: Sendable {
        var failure: CaptureEvent?
        var didFinish = false
    }

    private let storage = Mutex(Snapshot())

    var snapshot: Snapshot { storage.withLock { $0 } }

    func record(_ event: CaptureEvent) {
        storage.withLock { state in
            if event.isFailure, state.failure == nil { state.failure = event }
            if case .recordingFinished = event { state.didFinish = true }
        }
    }

    func waitUntil(
        deadline: ContinuousClock.Instant,
        _ isSatisfied: (Snapshot) -> Bool
    ) async throws {
        while .now < deadline {
            if isSatisfied(snapshot) { return }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}

enum CaptureEvent: Sendable {
    case recordingStarted
    case recordingFinished
    case recordingFailed(String)
    case streamStopped(String)

    var isFailure: Bool {
        switch self {
        case .recordingFailed, .streamStopped: true
        case .recordingStarted, .recordingFinished: false
        }
    }

    var line: String {
        switch self {
        case .recordingStarted: "  ↳ SCRecordingOutput : écriture démarrée"
        case .recordingFinished: "  ↳ SCRecordingOutput : fichier finalisé"
        case .recordingFailed(let message): "  ✗ SCRecordingOutput a échoué : \(message)"
        case .streamStopped(let message): "  ✗ SCStream interrompu : \(message)"
        }
    }
}

enum CaptureSpikeError: Error, CustomStringConvertible {
    case noDisplay

    var description: String {
        switch self {
        case .noDisplay: "Aucun écran partageable retourné par SCShareableContent."
        }
    }
}

/// `SCStreamDelegate` et `SCRecordingOutputDelegate` sont des protocoles
/// Objective-C rappelés sur une queue arbitraire. Le seul état stocké est une
/// continuation `Sendable`, d'où le `@unchecked Sendable` : il n'y a rien à
/// protéger.
final class CaptureSpikeDelegate: NSObject, SCStreamDelegate, SCRecordingOutputDelegate, @unchecked Sendable {
    private let continuation: AsyncStream<CaptureEvent>.Continuation

    init(continuation: AsyncStream<CaptureEvent>.Continuation) {
        self.continuation = continuation
    }

    func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        continuation.yield(.recordingStarted)
    }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        continuation.yield(.recordingFinished)
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
        continuation.yield(.recordingFailed(error.localizedDescription))
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        continuation.yield(.streamStopped(error.localizedDescription))
    }
}
