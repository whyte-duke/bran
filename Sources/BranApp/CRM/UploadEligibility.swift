import Foundation

/// Conditions à réunir **avant** d'envoyer quoi que ce soit au CRM.
///
/// Le contrat se contente de demander un avertissement quand un RDV n'est
/// rattaché à aucune entreprise. bran refuse. La raison est concrète : le
/// rattachement lead ↔ RDV se fait par le domaine de l'email du prospect, donc
/// une réservation faite depuis une adresse Gmail laisse `resolved_company_id`
/// à `null`. L'audio part quand même, la transcription est facturée, le
/// compte-rendu est produit — et il n'apparaît sur aucune fiche. Personne ne le
/// lira, et personne ne saura qu'il existe.
///
/// Mieux vaut un envoi refusé, réparable en deux clics dans le CRM, qu'un
/// compte-rendu perdu que rien ne signale.
enum UploadEligibility: Equatable, Sendable {
    case ready(CRMBooking)
    case notConfigured
    case noBooking
    case bookingWithoutCompany(CRMBooking)

    var booking: CRMBooking? {
        switch self {
        case .ready(let booking), .bookingWithoutCompany(let booking): booking
        case .notConfigured, .noBooking: nil
        }
    }

    var canSend: Bool {
        if case .ready = self { true } else { false }
    }

    var blockingReason: String? {
        switch self {
        case .ready:
            nil
        case .notConfigured:
            "Liaison CRM non configurée."
        case .noBooking:
            "Aucun rendez-vous CRM n'est rattaché à cet enregistrement."
        case .bookingWithoutCompany(let booking):
            "Le rendez-vous « \(booking.displayName) » n'est rattaché à aucune entreprise."
        }
    }

    var remedy: String? {
        switch self {
        case .ready:
            return nil
        case .notConfigured:
            return "Renseignez l'adresse du CRM et le jeton dans les Réglages."
        case .noBooking:
            return "Choisissez le rendez-vous à rattacher, ou créez-le dans le CRM."
        case .bookingWithoutCompany(let booking):
            let domain = booking.detected_domain ?? booking.attendee_email ?? "l'adresse du prospect"
            return """
            Le lien entre un rendez-vous et un lead se fait par le domaine de \
            l'email — ici \(domain), qui ne correspond à aucune entreprise connue. \
            Rattachez le lead dans le CRM, puis revérifiez ici.
            """
        }
    }

    static func evaluate(booking: CRMBooking?, isConfigured: Bool) -> UploadEligibility {
        guard isConfigured else { return .notConfigured }
        guard let booking else { return .noBooking }
        guard booking.company != nil else { return .bookingWithoutCompany(booking) }
        return .ready(booking)
    }
}
