import Foundation

/// Frontière entre la machine à états et ScreenCaptureKit.
///
/// Elle existe pour une seule raison : rendre `RecordingEngine` testable sans
/// écran, sans permission et sans `replayd`.
public protocol CaptureBackend: Sendable {
    /// Démarre la capture et rend l'URL du fichier en cours d'écriture.
    ///
    /// Ne rend la main qu'une fois le flux réellement démarré. L'URL est
    /// retournée dès le départ pour que l'appelant puisse poser sa sentinelle
    /// avant qu'une panne devienne possible.
    func start(_ meeting: MeetingRef) async throws -> URL

    /// Ferme le segment courant. Le fichier doit être complet et lisible au
    /// retour — une pause est une finalisation comme une autre.
    func pause() async throws

    /// Ouvre un nouveau segment et rend son URL.
    func resume() async throws -> URL

    /// Arrête ET finalise.
    ///
    /// Contrat non négociable : cette méthode ne doit pas rendre la main avant
    /// que le fichier soit écrit et lisible. `SCStream.stopCapture()` seul ne
    /// suffit pas — il faut attendre `recordingOutputDidFinishRecording`.
    /// Le spike de la Phase 1 a échoué exactement là.
    func stop() async throws
}
