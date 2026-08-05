import Foundation

/// Le seul point de décision de la capture de texte.
///
/// Même parti pris que `DictationMachine` : elle ne touche ni à l'écran, ni au
/// presse-papiers, ni au disque. Elle reçoit des événements et rend des effets,
/// ce qui la rend testable en une milliseconde, sans autorisation.
///
/// ```
///          ┌──────┐   raccourci ↓
///     ┌───►│ idle │────────────────┐
///     │    └──────┘                ▼
///     │                     ┌─────────────┐  échap / clic droit
///     │                     │  selecting  │──────────────────┐
///     │                     └──────┬──────┘                  │
///     │                            │ zone choisie            │
///     │            moteur froid    ▼    moteur chaud         │
///     │              ┌──────────────────────┐                │
///     │              │  preparing(0…1)      │  ← le seul     │
///     │              └──────────┬───────────┘    état visible│
///     │                         │ prêt            uniquement │
///     │              ┌──────────▼───────────┐    à froid     │
///     │              │     recognising      │                │
///     │              └──────────┬───────────┘                │
///     │                         │ texte      rien lu         │
///     │              ┌──────────▼───────────┐                │
///     └──────────────┤       copying        │◄───────────────┘
///                    └──────────────────────┘
///                    ┌──────────────────────┐  écran refusé, moteur absent,
///                    │     failed(why)      │  reconnaissance en panne
///                    └──────────────────────┘
/// ```
///
/// **Pourquoi `preparing` existe alors que Vision se charge en zéro seconde.**
/// Parce que le moteur est interchangeable. Avec Vision la phase est traversée
/// sans être vue ; avec un modèle local de deux gigaoctets, elle dure le temps
/// d'une lecture disque, et sans elle l'utilisateur regarderait une encoche
/// figée en se demandant si son raccourci a été pris en compte.
public struct SnapshotMachine: Sendable {

    public enum Phase: Equatable, Sendable {
        case idle
        case selecting
        /// Chargement du moteur. `nil` tant qu'aucune progression n'est connue —
        /// une barre qui démarre à zéro et saute à cent ment moins qu'une barre
        /// qui prétend connaître une progression qu'elle n'a pas.
        case preparing(Double?)
        case recognising
        case copying
        case failed(SnapshotFailure)

        public var isBusy: Bool {
            switch self {
            case .idle, .failed: false
            case .selecting, .preparing, .recognising, .copying: true
            }
        }

        /// Vrai tant que macOS a la main sur l'écran. Pendant ce temps l'encoche
        /// doit se taire : le viseur système est modal, et lui superposer un
        /// panneau brouillerait la sélection.
        public var isSystemOwningScreen: Bool {
            if case .selecting = self { return true }
            return false
        }
    }

    public enum Event: Equatable, Sendable {
        case triggered
        /// Une zone a été choisie. `engineReady` évite d'afficher un chargement
        /// de moteur quand il n'y en a pas à faire.
        case regionSelected(engineReady: Bool)
        case selectionCancelled
        case engineProgress(Double)
        case engineReady
        case recognised(String)
        /// La zone ne contenait aucun texte lisible.
        case recognisedNothing
        case copied
        case cancelRequested
        case failed(SnapshotFailure)
    }

    /// Ce que l'appelant doit faire.
    public enum Effect: Equatable, Sendable {
        case beginSelection
        case prepareEngine
        case recognise
        case deliver(String)
        case announceEmpty
        case discard
    }

    public private(set) var phase: Phase = .idle

    public init() {}

    @discardableResult
    public mutating func handle(_ event: Event) -> [Effect] {
        switch (phase, event) {

        // — Démarrage —————————————————————————————————————————————
        case (.idle, .triggered), (.failed, .triggered):
            phase = .selecting
            return [.beginSelection]

        // Un second appui pendant que le viseur est ouvert ne relance rien : le
        // viseur système est déjà là, et en ouvrir un deuxième laisserait un
        // processus orphelin à attendre une sélection qui n'arrivera jamais.
        case (.selecting, .triggered):
            return []

        // — Sélection —————————————————————————————————————————————
        case (.selecting, .regionSelected(let ready)):
            if ready {
                phase = .recognising
                return [.recognise]
            }
            phase = .preparing(nil)
            return [.prepareEngine]

        // Annuler au viseur est un geste normal, pas un échec. On revient à
        // l'état neutre sans rien afficher : signaler « annulé » à quelqu'un qui
        // vient d'appuyer sur Échap, c'est lui répéter ce qu'il vient de faire.
        case (.selecting, .selectionCancelled), (.selecting, .cancelRequested):
            phase = .idle
            return []

        // — Chargement du moteur ——————————————————————————————————
        case (.preparing, .engineProgress(let fraction)):
            phase = .preparing(min(max(fraction, 0), 1))
            return []

        case (.preparing, .engineReady):
            phase = .recognising
            return [.recognise]

        // — Reconnaissance ————————————————————————————————————————
        case (.recognising, .recognised(let text)):
            phase = .copying
            return [.deliver(text)]

        case (.recognising, .recognisedNothing):
            phase = .idle
            return [.announceEmpty]

        case (.copying, .copied):
            phase = .idle
            return []

        // — Annulation en cours de route ———————————————————————————
        //
        // Ni le chargement du modèle ni une inférence ne s'interrompent
        // proprement en cours de route. On revient donc à l'état neutre et on
        // jettera le résultat quand il arrivera, plutôt que de laisser le moteur
        // dans un état incertain.
        case (.preparing, .cancelRequested), (.recognising, .cancelRequested):
            phase = .idle
            return [.discard]

        // — Échec —————————————————————————————————————————————————
        case (_, .failed(let reason)):
            phase = .failed(reason)
            return [.discard]

        // — Tout le reste est sans effet ——————————————————————————
        default:
            return []
        }
    }

    public mutating func acknowledgeFailure() {
        if case .failed = phase { phase = .idle }
    }
}

/// Les façons dont une capture de texte peut échouer, et la réparation associée.
///
/// Même règle que pour la dictée : un message qui décrit le problème sans dire
/// quoi faire ne vaut pas mieux qu'un silence.
public enum SnapshotFailure: Equatable, Sendable, Codable {
    case screenRecordingDenied
    case accessibilityDenied
    case selectionFailed(String)
    case engineUnavailable(String)
    case recognitionFailed(String)
    case diskFull

    public var summary: String {
        switch self {
        case .screenRecordingDenied:
            "bran n'a pas accès à l'enregistrement de l'écran."
        case .accessibilityDenied:
            "bran n'a pas l'autorisation d'Accessibilité."
        case .selectionFailed(let detail):
            "La capture de la zone a échoué — \(detail)"
        case .engineUnavailable(let detail):
            "Le moteur de reconnaissance n'est pas disponible — \(detail)"
        case .recognitionFailed(let detail):
            "La lecture du texte a échoué — \(detail)"
        case .diskFull:
            "Espace disque insuffisant pour conserver la capture."
        }
    }

    public var remedy: String {
        switch self {
        case .screenRecordingDenied:
            """
            Réglages système › Confidentialité et sécurité › Enregistrement de \
            l'écran, puis cochez bran. C'est la même autorisation que pour \
            l'enregistrement des réunions.
            """
        case .accessibilityDenied:
            """
            Réglages système › Confidentialité et sécurité › Accessibilité, \
            puis cochez bran. Sans elle, le raccourci global ne peut pas être lu.
            """
        case .selectionFailed:
            "Réessayez. Si le problème persiste, redémarrez bran."
        case .engineUnavailable:
            "Ouvrez les réglages de la capture de texte pour vérifier le moteur."
        case .recognitionFailed:
            "L'image est conservée : vous pouvez réessayer depuis l'historique."
        case .diskFull:
            "Libérez de l'espace, ou réduisez la durée de conservation des images."
        }
    }
}

/// Permet à `error.localizedDescription` de rendre le résumé plutôt que
/// « The operation couldn't be completed », qui n'aide personne.
extension SnapshotFailure: LocalizedError {
    public var errorDescription: String? { summary }
    public var recoverySuggestion: String? { remedy }
}
