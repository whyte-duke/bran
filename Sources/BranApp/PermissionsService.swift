import AVFoundation
import CoreGraphics
import EventKit
import Foundation
import Observation

/// Préflight TCC des trois autorisations.
///
/// Deux sont obligatoires (écran, micro), la troisième enrichit seulement
/// (calendrier). L'app doit pouvoir enregistrer sans le calendrier.
@MainActor
@Observable
public final class PermissionsService {

    public enum Access: Equatable, Sendable {
        case granted
        case denied
        case notDetermined
    }

    public private(set) var screenRecording: Access = .notDetermined
    public private(set) var microphone: Access = .notDetermined
    public private(set) var calendar: Access = .notDetermined

    private let eventStore = EKEventStore()

    public init() {
        refresh()
    }

    /// Les deux autorisations sans lesquelles un enregistrement serait vide ou
    /// muet. Le calendrier n'en fait pas partie : il ne fait que nommer.
    public var canRecord: Bool {
        screenRecording == .granted && microphone == .granted
    }

    public func refresh() {
        // CGPreflight ne distingue pas « refusée » de « jamais demandée ».
        // Les deux appellent la même action de l'utilisateur, la nuance est
        // donc sans conséquence ici.
        screenRecording = CGPreflightScreenCaptureAccess() ? .granted : .notDetermined

        microphone = switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .denied, .restricted: .denied
        case .notDetermined: .notDetermined
        @unknown default: .notDetermined
        }

        calendar = switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .granted
        case .denied, .restricted, .writeOnly: .denied
        case .notDetermined: .notDetermined
        @unknown default: .notDetermined
        }
    }

    /// Déclenche la fenêtre système. macOS n'accorde l'autorisation qu'au
    /// prochain démarrage du processus — d'où le redémarrage explicite proposé
    /// dans l'interface plutôt qu'une attente qui ne viendra jamais.
    public func requestScreenRecording() {
        CGRequestScreenCaptureAccess()
        refresh()
    }

    public func requestMicrophone() async {
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        refresh()
    }

    public func requestCalendar() async {
        _ = try? await eventStore.requestFullAccessToEvents()
        refresh()
    }
}
