import AVFoundation
import BranCore
import Foundation
import ScreenCaptureKit
import Synchronization

/// Implémentation réelle de `CaptureBackend`.
///
/// Un seul `SCStream`, une seule `SCRecordingOutput`, un seul fichier. Aucun
/// `CMSampleBuffer` ne traverse ce code : c'est `replayd` qui mux et qui écrit,
/// dans son propre processus. C'est ce qui rend l'enregistrement survivant à un
/// crash de bran — mesuré en Phase 1.
public actor CaptureSession: CaptureBackend {

    public struct Settings: Sendable {
        /// Multiplicateur de la résolution logique de l'écran.
        /// 2,0 = Retina natif : le texte des slides reste lisible au replay.
        public var scale: Double = 2
        public var codec: AVVideoCodecType = .hevc
        public var framesPerSecond: Int32 = 30
        public var storageRoot: URL = URL.moviesDirectory.appending(path: "bran", directoryHint: .isDirectory)

        public init() {}
    }

    /// Défaillances survenues en cours de route. `AppModel` les relaie à
    /// `RecordingEngine`, ce qui évite un cycle de références entre les deux.
    public nonisolated let failures: AsyncStream<String>

    private nonisolated let failureContinuation: AsyncStream<String>.Continuation
    private var settings: Settings
    private let signals = CaptureSignals()

    private var stream: SCStream?
    private var outputURL: URL?

    /// Session en cours. Survit à une pause : c'est ce qui permet à `resume()`
    /// de rouvrir un segment au bon nom, dans la bonne session.
    private var session: (meeting: MeetingRef, nextSegment: Int)?

    /// `SCStream` et `SCRecordingOutput` ne retiennent leur delegate que
    /// faiblement. Sans cette référence, le delegate est libéré dès la fin de
    /// `start()` : plus aucun callback n'arrive, `recordingOutputDidFinishRecording`
    /// non plus, et `stop()` expire au bout de 60 s alors que le fichier a été
    /// correctement écrit par replayd.
    private var delegate: CaptureDelegate?
    private var recordingOutput: SCRecordingOutput?

    public init(settings: Settings = Settings()) {
        self.settings = settings
        (failures, failureContinuation) = AsyncStream.makeStream(of: String.self)
    }

    /// Sans effet sur un enregistrement en cours : changer la configuration
    /// d'un `SCStream` actif l'interrompt.
    public func updateQuality(_ preset: QualityPreset) {
        settings.scale = preset.scale
    }

    /// Ne déplace rien : seuls les enregistrements suivants iront à la nouvelle
    /// destination. Déplacer des fichiers de plusieurs giga-octets à l'insu de
    /// l'utilisateur, pendant qu'une réunion tourne peut-être, serait une bien
    /// mauvaise idée.
    public func updateStorageRoot(_ url: URL) {
        settings.storageRoot = url
    }

    public func start(_ meeting: MeetingRef) async throws -> URL {
        session = (meeting, 0)
        return try await openSegment()
    }

    public func pause() async throws {
        try await closeCurrentSegment()
    }

    public func resume() async throws -> URL {
        guard session != nil else { throw CaptureError.noSessionToResume }
        return try await openSegment()
    }

    public func stop() async throws {
        defer { session = nil }
        try await closeCurrentSegment()
    }

    // MARK: - Segments

    private func openSegment() async throws -> URL {
        guard var session else { throw CaptureError.noSessionToResume }

        // Préflight avant CHAQUE démarrage, pas seulement au lancement : une
        // mise à jour système peut avoir révoqué l'autorisation depuis. Sans ce
        // contrôle, on enregistrerait un écran noir sans le savoir — la panne
        // silencieuse que le §10 du plan interdit.
        guard CGPreflightScreenCaptureAccess() else {
            throw CaptureError.screenRecordingDenied
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw CaptureError.noDisplay }

        let destination = try makeSegmentURL(for: session.meeting, index: session.nextSegment)
        try checkFreeSpace(at: destination)

        let filter = SCContentFilter(
            display: display,
            excludingApplications: ownApplication(in: content).map { [$0] } ?? [],
            exceptingWindows: []
        )

        let configuration = SCStreamConfiguration()
        configuration.width = evenDimension(Double(display.width) * settings.scale)
        configuration.height = evenDimension(Double(display.height) * settings.scale)
        configuration.captureResolution = settings.scale > 1 ? .best : .nominal
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: settings.framesPerSecond)
        configuration.showsCursor = true
        configuration.capturesAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.excludesCurrentProcessAudio = true
        configuration.captureMicrophone = true
        configuration.captureDynamicRange = .SDR   // HDR + recordingOutput = échec, cf. en-tête SDK

        let recordingConfiguration = SCRecordingOutputConfiguration()
        recordingConfiguration.outputURL = destination
        recordingConfiguration.outputFileType = .mp4
        recordingConfiguration.videoCodecType = settings.codec

        signals.reset()
        let delegate = CaptureDelegate(signals: signals, failures: failureContinuation)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: delegate)
        let recordingOutput = SCRecordingOutput(configuration: recordingConfiguration, delegate: delegate)

        // Avant startCapture : c'est la seule façon de garantir que la première
        // image atterrit dans le fichier.
        try stream.addRecordingOutput(recordingOutput)
        try await stream.startCapture()

        self.stream = stream
        self.delegate = delegate
        self.recordingOutput = recordingOutput
        self.outputURL = destination

        session.nextSegment += 1
        self.session = session

        return destination
    }

    private func closeCurrentSegment() async throws {
        guard let stream else { return }
        self.stream = nil

        // `stopCapture()` retire la sortie d'enregistrement ET finalise.
        // Appeler `removeRecordingOutput()` d'abord provoque un double
        // `exportAndInvalidate` sur le même SCAssetWriter : l'export échoue et
        // le fichier n'est jamais écrit. Constaté dans les logs de replayd.
        try await stream.stopCapture()

        // `stopCapture()` rend la main plusieurs secondes avant que le fichier
        // existe. Rendre la main ici sans attendre, c'est déclarer terminé un
        // enregistrement qui n'est pas écrit.
        let finalized = await signals.waitForFinish(timeout: .seconds(60))

        outputURL = nil
        delegate = nil
        recordingOutput = nil

        guard finalized else { throw CaptureError.finalizationTimedOut }
    }

    // MARK: - Détails

    /// `<uuid>-seg000.mp4`. Le fichier final prendra `<uuid>.mp4` après fusion,
    /// ce qui rend les intermédiaires reconnaissables au premier coup d'œil —
    /// et supprimables sans risque si quoi que ce soit tourne mal.
    private func makeSegmentURL(for meeting: MeetingRef, index: Int) throws -> URL {
        try FileManager.default.createDirectory(at: settings.storageRoot, withIntermediateDirectories: true)
        let suffix = String(format: "seg%03d", index)
        return settings.storageRoot.appending(path: "\(meeting.id.uuidString)-\(suffix).mp4")
    }

    /// ~1 Go/h en H.264, davantage en Retina. Démarrer avec moins de 5 Go libres,
    /// c'est programmer une interruption en plein milieu.
    private func checkFreeSpace(at destination: URL) throws {
        let values = try? destination.deletingLastPathComponent()
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])

        guard let available = values?.volumeAvailableCapacityForImportantUsage else { return }
        guard available >= 5_000_000_000 else {
            throw CaptureError.insufficientSpace(availableBytes: available)
        }
    }

    /// L'overlay de la Phase 5 se filmerait lui-même sans cette exclusion.
    private func ownApplication(in content: SCShareableContent) -> SCRunningApplication? {
        content.applications.first { $0.processID == ProcessInfo.processInfo.processIdentifier }
    }

    /// H.264 et HEVC exigent des dimensions paires.
    private func evenDimension(_ value: Double) -> Int {
        let rounded = Int(value.rounded())
        return rounded.isMultiple(of: 2) ? rounded : rounded + 1
    }
}
