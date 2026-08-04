import Foundation
import Observation

/// Machine à états. Exécute, ne décide pas.
///
/// Invariants garantis ici, et testés :
/// - `.start` reçu pendant `.starting`, `.recording` ou `.paused` → ignoré
/// - `.stop` reçu pendant `.idle` → ignoré
/// - toute sortie de `.recording` ou `.paused` passe par `.finalizing`
/// - un échec est bruyant : `.failed` avec une raison, jamais un retour
///   silencieux à `.idle`
/// - la liste des segments ne perd jamais un morceau : un fichier écrit y
///   figure, même si la session échoue ensuite
@MainActor
@Observable
public final class RecordingEngine {
    public private(set) var state: RecordingState = .idle

    /// Morceaux écrits pour la session en cours, dans l'ordre.
    ///
    /// Une session sans pause en contient un seul. Ils sont recollés en un
    /// fichier unique après `.finalizing`.
    public private(set) var segments: [URL] = []

    /// Journal des transitions. Sert au diagnostic en production et de point
    /// d'observation aux tests, qui vérifient le CHEMIN et pas seulement l'état
    /// final — c'est la seule façon de prouver le passage par `.finalizing`.
    public var onTransition: (@MainActor (RecordingState) -> Void)?

    private let backend: any CaptureBackend

    /// `.stop` arrivé pendant `.starting`. Sans ça, l'ordre serait perdu et
    /// l'enregistrement tournerait indéfiniment : le résolveur n'émet `.stop`
    /// qu'une fois.
    private var stopRequestedDuringStart = false

    public init(backend: any CaptureBackend) {
        self.backend = backend
    }

    public var currentFileURL: URL? { segments.last }

    // MARK: - Intentions du résolveur

    public func handle(_ intent: Intent) async {
        switch (state, intent) {
        case (.idle, .start(let meeting)), (.failed, .start(let meeting)):
            await beginRecording(meeting)

        case (.recording(let meeting), .stop), (.paused(let meeting), .stop):
            await finalize(meeting)

        case (.starting, .stop):
            stopRequestedDuringStart = true

        default:
            break
        }
    }

    // MARK: - Actions de l'utilisateur
    //
    // Pause et reprise ne passent pas par `Intent` : `Intent` est le vocabulaire
    // de `SessionResolver`, qui décide à partir de ce qu'il observe à l'écran.
    // Mettre en pause est un geste humain, qu'aucune observation ne produit.

    public func pause() async {
        guard case .recording(let meeting) = state else { return }

        do {
            try await backend.pause()
            transition(to: .paused(meeting))
        } catch {
            transition(to: .failed(reason: "pause impossible : \(error)"))
        }
    }

    public func resume() async {
        guard case .paused(let meeting) = state else { return }

        do {
            segments.append(try await backend.resume())
            transition(to: .recording(meeting))
        } catch {
            transition(to: .failed(reason: "reprise impossible : \(error)"))
        }
    }

    /// Défaillance signalée par le backend en cours de route — flux interrompu,
    /// autorisation révoquée, disque plein.
    public func reportFailure(_ reason: String) {
        guard state.isActive else { return }
        transition(to: .failed(reason: reason))
    }

    /// Vide la liste des segments une fois qu'ils ont été consommés par le
    /// post-traitement. Appelé par l'appelant, pas par la machine : celle-ci
    /// n'a aucune idée de ce qu'on fait des fichiers.
    public func clearSegments() {
        segments.removeAll()
    }

    // MARK: - Transitions

    private func beginRecording(_ meeting: MeetingRef) async {
        stopRequestedDuringStart = false
        segments.removeAll()
        transition(to: .starting(meeting))

        do {
            segments.append(try await backend.start(meeting))
        } catch {
            transition(to: .failed(reason: "démarrage impossible : \(error)"))
            return
        }

        transition(to: .recording(meeting))

        if stopRequestedDuringStart {
            stopRequestedDuringStart = false
            await finalize(meeting)
        }
    }

    private func finalize(_ meeting: MeetingRef) async {
        let wasPaused = state == .paused(meeting)
        transition(to: .finalizing(meeting))

        do {
            // En pause, le segment courant est déjà fermé : rien à finaliser.
            if wasPaused == false {
                try await backend.stop()
            }
        } catch {
            transition(to: .failed(reason: "finalisation impossible : \(error)"))
            return
        }

        transition(to: .idle)
    }

    private func transition(to next: RecordingState) {
        state = next
        onTransition?(next)
    }
}
