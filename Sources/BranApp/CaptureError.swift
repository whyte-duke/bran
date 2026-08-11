import Foundation

enum CaptureError: LocalizedError {
    case screenRecordingDenied
    case noDisplay
    case insufficientSpace(availableBytes: Int64)

    /// La finalisation a été abandonnée — plus rien n'était écrit, ou le
    /// plafond absolu a été atteint.
    ///
    /// Remplace `finalizationTimedOut`, dont le nom disait « le délai est
    /// dépassé » là où l'utilisateur avait besoin de lire « votre réunion est
    /// sur le disque, voici son poids ». Le 11 août 2026, l'ancienne erreur
    /// s'est affichée sur une réunion parfaitement enregistrée de 2,56 Go,
    /// pendant que `replayd` finissait de l'écrire.
    case finalizationAbandoned(String, bytesWritten: Int64)

    case noSessionToResume

    var errorDescription: String? {
        switch self {
        case .screenRecordingDenied:
            "L'autorisation « Enregistrement de l'écran » n'est plus accordée."
        case .noDisplay:
            "Aucun écran partageable."
        case .insufficientSpace(let bytes):
            "Espace disque insuffisant : \(bytes.formatted(.byteCount(style: .file))) disponibles."
        case .finalizationAbandoned(let detail, _):
            "Finalisation abandonnée : \(detail)"
        case .noSessionToResume:
            "Aucune session en pause à reprendre."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .screenRecordingDenied:
            "Réglages Système → Confidentialité et sécurité → Enregistrement de l'écran → activer bran."
        case .insufficientSpace:
            "Libérez de l'espace, ou purgez d'anciens enregistrements."
        case .finalizationAbandoned(_, let bytes) where bytes > 0:
            "Le fichier brut est dans le dossier des enregistrements, sous le nom du segment "
            + "(`…-seg000.mp4`). Il est presque toujours lisible tel quel."
        case .noDisplay, .finalizationAbandoned, .noSessionToResume:
            nil
        }
    }
}
