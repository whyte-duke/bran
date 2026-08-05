import Foundation

/// Les quatre états locaux du §12 du contrat, plus le suivi côté CRM.
///
/// Le CRM ne connaît pas les états locaux : il prend la main au `PUT` et ne la
/// rend qu'à `ready`.
enum UploadState: Equatable, Sendable {
    case extractingAudio
    case uploading(Double)
    case starting
    case processing(stage: CRMStage, progress: Int, label: String?)
    case ready(summary: String?)
    case failed(String)

    var isFinished: Bool {
        switch self {
        case .ready, .failed: true
        default: false
        }
    }

    var description: String {
        switch self {
        case .extractingAudio:
            "Extraction de l'audio…"
        case .uploading(let fraction):
            "Envoi \((fraction * 100).formatted(.number.precision(.fractionLength(0)))) %"
        case .starting:
            "Lancement du traitement…"
        case .processing(_, let progress, let label):
            "\(label ?? "Traitement") — \(progress) %"
        case .ready:
            "Compte-rendu prêt"
        case .failed(let reason):
            reason
        }
    }

    /// Fraction pour une barre de progression, `nil` quand il n'y a rien de
    /// mesurable à montrer.
    var fraction: Double? {
        switch self {
        case .extractingAudio: nil
        case .uploading(let value): value
        case .starting: nil
        case .processing(_, let progress, _): Double(progress) / 100
        case .ready: 1
        case .failed: nil
        }
    }
}

/// Résultat de la recherche du RDV auquel rattacher un audio.
///
/// « Ne jamais deviner » est une règle du contrat, pas une précaution : un audio
/// rattaché au mauvais lead écrase le compte-rendu de quelqu'un d'autre.
enum BookingResolution: Sendable {
    /// Le meilleur candidat, quel que soit le cas.
    var booking: CRMBooking? {
        switch self {
        case .unique(let booking): booking
        case .ambiguous(let candidates), .none(let candidates): candidates.first
        }
    }

    /// Un seul RDV dans la fenêtre de ±2 h, sans transcription déjà déposée.
    case unique(CRMBooking)
    /// Plusieurs candidats, ou un candidat qui porte déjà une transcription.
    case ambiguous([CRMBooking])
    /// Aucun RDV dans la fenêtre — la liste complète est fournie pour un choix
    /// manuel.
    case none([CRMBooking])
}
