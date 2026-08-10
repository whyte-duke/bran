import Foundation

/// Ce que l'appelant a le droit d'écrire une fois l'arrêt demandé.
///
/// `RecordingEngine` distingue déjà un arrêt propre d'un échec, et ses tests
/// l'exigent nommément (« Échec de la finalisation → .failed, pas un retour
/// silencieux à .idle »). Rien n'obligeait en revanche l'appelant à en tenir
/// compte : `AppModel` horodatait la fin de session dans tous les cas, y compris
/// après une finalisation expirée. La sentinelle disparaissait, et la
/// bibliothèque présentait un fichier tronqué comme une réunion complète.
///
/// **Le pire défaut de bran n'est pas de perdre un enregistrement, c'est de dire
/// qu'il l'a gardé.** Ce type traduit l'état final de la machine en une décision
/// unique — peut-on écrire `endedAt`, oui ou non — et il est ici, dans une cible
/// testable, plutôt que dans une branche `if` de la couche interface.
public enum StopVerdict: Equatable, Sendable {

    /// La machine est revenue au repos : le flux est fermé et le fichier
    /// finalisé.
    case complete

    /// La machine est en `.failed`. Le fichier peut être tronqué, vide, ou
    /// absent — on ne sait pas, et c'est précisément pour ça qu'il ne faut rien
    /// affirmer.
    case failed(reason: String)

    /// La machine n'a pas tranché. Cas réel : `.stop` reçu pendant `.starting`,
    /// que `RecordingEngine` mémorise pour finaliser lui-même dès que le
    /// démarrage aboutit. Toucher au sidecar ou vider la liste des segments à ce
    /// moment-là reviendrait à conclure une session qui commence à peine.
    case stillOpen

    public init(_ state: RecordingState) {
        switch state {
        case .idle:
            self = .complete
        case .failed(let reason):
            self = .failed(reason: reason)
        case .starting, .recording, .paused, .finalizing:
            self = .stillOpen
        }
    }

    /// L'arrêt est tranché : la session est close, bien ou mal.
    public var isSettled: Bool { self != .stillOpen }

    /// Horodater la fin, oui ou non.
    ///
    /// **Non sur un échec.** Un sidecar sans `endedAt` est la sentinelle de
    /// session interrompue que la bibliothèque affiche déjà ; l'écrire quand
    /// même est exactement le geste qui rend un échec invisible.
    public var writesEndedAt: Bool { self == .complete }

    /// Les morceaux déjà écrits sont à récupérer **même après un échec** : ce
    /// sont les minutes de réunion qui ont bien été capturées, et les laisser
    /// sur le disque sous leur nom de segment les rendrait invisibles.
    public var consumesSegments: Bool { isSettled }

    /// Ce qu'on dit à l'utilisateur, ou `nil` s'il n'y a rien à dire.
    public var message: String? {
        guard case .failed(let reason) = self else { return nil }
        return "Enregistrement non finalisé : \(reason). Le fichier peut être tronqué — "
            + "la réunion reste marquée « interrompue » dans la bibliothèque tant qu'elle n'a pas été vérifiée."
    }
}
