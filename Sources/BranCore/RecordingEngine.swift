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
/// - toute session ouverte se conclut, et une seule fois : `onSettled` est
///   appelé exactement une fois entre `.starting` et le retour à `.idle` ou
///   `.failed`, y compris quand l'arrêt a été différé
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

    /// La réunion de la session ouverte, du premier `.starting` jusqu'au verdict
    /// d'arrêt inclus.
    ///
    /// Deux raisons de la garder ici plutôt que de la relire dans `state` :
    /// `.failed` ne porte pas de `MeetingRef`, et c'est justement après un échec
    /// qu'il importe le plus de savoir quelle fiche refermer ; et sa remise à
    /// `nil` est le **verrou d'unicité** de `onSettled`.
    private var openSession: MeetingRef?

    /// L'arrêt est tranché : la session est close, bien ou mal.
    ///
    /// C'est la moitié qui manquait à `StopVerdict.stillOpen`. Un `.stop` reçu
    /// pendant `.starting` est différé : l'appelant obtient `.stillOpen`, repart
    /// sans rien écrire — ce qui est juste — et personne ne concluait la session
    /// quand le démarrage aboutissait enfin. La fin n'était pas horodatée, les
    /// segments n'étaient jamais fusionnés, et la bibliothèque affichait pour
    /// toujours une réunion « interrompue » que la machine, elle, tenait pour
    /// proprement close.
    ///
    /// La machine rappelle donc l'appelant au moment où **elle** tranche, tout de
    /// suite ou dix secondes plus tard, que l'arrêt ait été demandé (`.stop`) ou
    /// subi (`reportFailure`, échec de démarrage, échec de finalisation).
    ///
    /// Garanties :
    /// - **une fois par session**, jamais zéro, jamais deux — deux clics sur
    ///   « arrêter » ne fusionnent pas deux fois ;
    /// - `verdict.isSettled` est toujours vrai ;
    /// - `segments` est encore rempli à l'appel : c'est à l'observateur de le
    ///   relever puis d'appeler `clearSegments()`.
    public var onSettled: (@MainActor (MeetingRef, StopVerdict) -> Void)?

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
            transition(to: .failed(reason: "pause impossible : \(Self.explain(error))"))
        }
    }

    public func resume() async {
        guard case .paused(let meeting) = state else { return }

        do {
            segments.append(try await backend.resume())
            transition(to: .recording(meeting))
        } catch {
            transition(to: .failed(reason: "reprise impossible : \(Self.explain(error))"))
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
        // Avant la première transition : `.starting` peut échouer immédiatement,
        // et une session qui échoue à naître doit se conclure comme les autres.
        openSession = meeting
        transition(to: .starting(meeting))

        do {
            segments.append(try await backend.start(meeting))
        } catch {
            transition(to: .failed(reason: "démarrage impossible : \(Self.explain(error))"))
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
            transition(to: .failed(reason: "finalisation impossible : \(Self.explain(error))"))
            return
        }

        transition(to: .idle)
    }

    /// Le texte d'une erreur, écrit pour un humain.
    ///
    /// **`"\(error)"` interpolait le cas d'énumération.** Le 11 août 2026, la
    /// bibliothèque et le bandeau affichaient « finalisation impossible :
    /// finalizationTimedOut » — un identifiant Swift, en anglais, dans une
    /// interface française, alors que `CaptureError` portait depuis toujours une
    /// phrase complète que personne n'allait chercher. Le motif est écrit dans
    /// le sidecar et s'y lit des mois plus tard : c'est le dernier endroit où
    /// laisser un nom de symbole.
    private static func explain(_ error: any Error) -> String {
        (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private func transition(to next: RecordingState) {
        state = next
        onTransition?(next)

        // Le verdict est lu ici et nulle part ailleurs. `.idle` et `.failed` sont
        // les deux seules issues d'une session, et cinq transitions y mènent —
        // les reconnaître au passage évite d'oublier la sixième.
        let verdict = StopVerdict(next)
        guard verdict.isSettled, let meeting = openSession else { return }

        // Le verrou : la session est retirée AVANT l'appel. Un second `.stop`,
        // ou une panne signalée dans la même seconde, ne rejouera pas la
        // conclusion — et donc pas la fusion des segments.
        openSession = nil
        onSettled?(meeting, verdict)
    }
}
