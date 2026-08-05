import Foundation

/// Le seul point de décision de la dictée.
///
/// Volontairement séparé de `RecordingEngine` : celui-ci parle `Intent`,
/// `proposal` et `segments`, et connaît un état `.paused` qui n'a aucun sens
/// quand on tient une touche pour parler. Deux vocabulaires, deux machines,
/// un seul dossier de stockage.
///
/// ```
///          ┌──────┐   raccourci ↓
///     ┌───►│ idle │───────────────┐
///     │    └──────┘               ▼
///     │                    ┌─────────────┐  échap    ┌───────────┐
///     │                    │  capturing  │──────────►│ (annulé)  │
///     │                    └──────┬──────┘           └─────┬─────┘
///     │        raccourci ↑ /      │                        │
///     │        plafond atteint    ▼                        │
///     │                   ┌──────────────┐   silence       │
///     │                   │ transcribing │────────────────►┤
///     │                   └──────┬───────┘                 │
///     │                          │ texte                   │
///     │                   ┌──────▼───────┐                 │
///     └───────────────────┤   pasting    │                 │
///                         └──────────────┘◄────────────────┘
///                         ┌──────────────┐
///                         │ failed(why)  │  saisie sécurisée, micro refusé,
///                         └──────────────┘  modèle absent, disque plein
/// ```
public struct DictationMachine: Sendable {

    public enum Phase: Equatable, Sendable {
        case idle
        case capturing
        case transcribing
        case pasting
        case failed(DictationFailure)

        public var isBusy: Bool {
            switch self {
            case .idle, .failed: false
            case .capturing, .transcribing, .pasting: true
            }
        }
    }

    /// Comment le raccourci se comporte.
    ///
    /// `.toggle` est ce qui a été demandé : un appui démarre, un second arrête.
    /// `.hold` est ce que font Handy et la dictée système : on garde la touche
    /// enfoncée. Sur une phrase de dix secondes, `.hold` est nettement plus
    /// rapide et l'annulation devient évidente — on relâche sans avoir parlé.
    public enum Trigger: String, Codable, CaseIterable, Sendable {
        case toggle
        case hold

        public var label: String {
            switch self {
            case .toggle: "Appuyer pour démarrer, appuyer pour arrêter"
            case .hold: "Maintenir la touche enfoncée"
            }
        }
    }

    public enum Event: Equatable, Sendable {
        case hotkeyDown
        case hotkeyUp
        case cancelRequested
        /// Le plafond de durée est atteint : on arrête, mais on transcrit.
        case durationCapReached
        case transcribed(String)
        /// Le VAD n'a trouvé aucune parole, ou le modèle a rendu une chaîne vide.
        case transcribedNothing
        case pasted
        case failed(DictationFailure)
    }

    /// Ce que l'appelant doit faire. La machine ne fait rien elle-même : elle ne
    /// touche ni au micro, ni au presse-papiers, ni au disque. C'est ce qui la
    /// rend testable en une milliseconde.
    public enum Effect: Equatable, Sendable {
        case startCapture
        case finishCaptureAndTranscribe
        case discardCapture
        case paste(String)
        case announceEmpty
    }

    public private(set) var phase: Phase = .idle
    public var trigger: Trigger

    public init(trigger: Trigger = .toggle) {
        self.trigger = trigger
    }

    /// Applique un événement et retourne les effets à exécuter.
    ///
    /// Un événement qui n'a pas de sens dans l'état courant ne produit rien et
    /// ne change rien — plutôt que de lever une erreur. Un raccourci pressé
    /// deux fois en 50 ms ne doit pas casser l'application.
    @discardableResult
    public mutating func handle(_ event: Event) -> [Effect] {
        switch (phase, event) {

        // — Démarrage —————————————————————————————————————————————
        case (.idle, .hotkeyDown), (.failed, .hotkeyDown):
            phase = .capturing
            return [.startCapture]

        // Un second appui arrête, en mode bascule uniquement. En mode maintien,
        // l'appui est répété par le système tant que la touche est enfoncée :
        // le traiter comme un arrêt couperait la dictée au bout de 500 ms.
        case (.capturing, .hotkeyDown) where trigger == .toggle:
            phase = .transcribing
            return [.finishCaptureAndTranscribe]

        case (.capturing, .hotkeyUp) where trigger == .hold:
            phase = .transcribing
            return [.finishCaptureAndTranscribe]

        case (.capturing, .durationCapReached):
            phase = .transcribing
            return [.finishCaptureAndTranscribe]

        // — Annulation ————————————————————————————————————————————
        case (.capturing, .cancelRequested):
            phase = .idle
            return [.discardCapture]

        // Annuler pendant la transcription : le calcul continue en arrière-plan,
        // mais son résultat sera ignoré. On ne peut pas interrompre le Neural
        // Engine au milieu d'une inférence, et essayer laisserait le modèle dans
        // un état incertain.
        case (.transcribing, .cancelRequested):
            phase = .idle
            return [.discardCapture]

        // — Fin ———————————————————————————————————————————————————
        case (.transcribing, .transcribed(let text)):
            phase = .pasting
            return [.paste(text)]

        case (.transcribing, .transcribedNothing):
            phase = .idle
            return [.announceEmpty]

        case (.pasting, .pasted):
            phase = .idle
            return []

        // — Échec —————————————————————————————————————————————————
        case (_, .failed(let reason)):
            let wasCapturing = phase == .capturing
            phase = .failed(reason)
            return wasCapturing ? [.discardCapture] : []

        // — Tout le reste est sans effet ——————————————————————————
        default:
            return []
        }
    }

    /// Remet à zéro après qu'un échec a été lu par l'utilisateur.
    public mutating func acknowledgeFailure() {
        if case .failed = phase { phase = .idle }
    }
}

/// Les façons dont la dictée peut échouer, et ce qu'on en dit.
///
/// Chaque cas porte sa propre réparation. Un message qui décrit le problème
/// sans dire quoi faire ne vaut pas mieux qu'un silence.
public enum DictationFailure: Equatable, Sendable, Codable {
    case microphoneDenied
    case accessibilityDenied
    /// macOS coupe tous les taps d'événements quand le curseur est dans un champ
    /// de mot de passe. `app` est le coupable quand on arrive à l'identifier.
    case secureInputActive(app: String?)
    case modelUnavailable(String)
    case captureFailed(String)
    case transcriptionFailed(String)
    case diskFull

    public var summary: String {
        switch self {
        case .microphoneDenied:
            "bran n'a pas accès au microphone."
        case .accessibilityDenied:
            "bran n'a pas l'autorisation d'Accessibilité."
        case .secureInputActive(let app):
            if let app {
                "« \(app) » a activé la saisie sécurisée du clavier."
            } else {
                "Une application a activé la saisie sécurisée du clavier."
            }
        case .modelUnavailable(let detail):
            "Le modèle de transcription n'est pas disponible — \(detail)"
        case .captureFailed(let detail):
            "La capture du micro a échoué — \(detail)"
        case .transcriptionFailed(let detail):
            "La transcription a échoué — \(detail)"
        case .diskFull:
            "Espace disque insuffisant pour enregistrer la dictée."
        }
    }

    public var remedy: String {
        switch self {
        case .microphoneDenied:
            "Réglages système › Confidentialité et sécurité › Microphone."
        case .accessibilityDenied:
            """
            Réglages système › Confidentialité et sécurité › Accessibilité, \
            puis cochez bran. Sans elle, le raccourci ne peut pas être lu et le \
            texte ne peut pas être collé.
            """
        case .secureInputActive:
            """
            macOS bloque alors toute lecture du clavier, y compris la nôtre. \
            Fermez le champ de mot de passe. Si le problème persiste, décochez \
            « Saisie sécurisée du clavier » dans le menu Terminal — ce réglage \
            reste actif tant qu'on ne le retire pas.
            """
        case .modelUnavailable:
            "Ouvrez les réglages de la dictée pour retélécharger le modèle."
        case .captureFailed:
            "Vérifiez que le micro choisi est bien connecté."
        case .transcriptionFailed:
            "L'audio est conservé : vous pouvez réessayer depuis l'historique."
        case .diskFull:
            "Libérez de l'espace, ou changez le dossier de destination."
        }
    }
}
