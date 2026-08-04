import Foundation

enum CaptureError: LocalizedError {
    case screenRecordingDenied
    case noDisplay
    case insufficientSpace(availableBytes: Int64)
    case finalizationTimedOut
    case noSessionToResume

    var errorDescription: String? {
        switch self {
        case .screenRecordingDenied:
            "L'autorisation « Enregistrement de l'écran » n'est plus accordée."
        case .noDisplay:
            "Aucun écran partageable."
        case .insufficientSpace(let bytes):
            "Espace disque insuffisant : \(bytes.formatted(.byteCount(style: .file))) disponibles."
        case .finalizationTimedOut:
            "Le fichier n'a pas été finalisé dans le délai imparti."
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
        case .noDisplay, .finalizationTimedOut, .noSessionToResume:
            nil
        }
    }
}
