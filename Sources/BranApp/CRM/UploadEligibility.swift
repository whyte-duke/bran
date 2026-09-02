import BranCore
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
///
/// **La décision elle-même n'est plus ici.** Elle vit dans
/// `MeetingUploadPolicy`, dans une cible pure et avec ses tests, parce qu'elle
/// était écrite en trois endroits qui avaient déjà divergé — voir l'en-tête de
/// ce type. Ce qui reste dans ce fichier est ce qui appartient bien à
/// l'interface : les phrases à afficher et le geste à proposer.
enum UploadEligibility: Equatable, Sendable {
    case ready(CRMBooking)
    case notConfigured
    case noBooking
    case bookingWithoutCompany(CRMBooking)

    /// Le rendez-vous est clos — annulé, reporté, absence — et l'envoi partait
    /// tout seul.
    case bookingClosed(CRMBooking)

    /// Le rendez-vous porte déjà un compte-rendu, et l'envoi partait tout seul.
    case bookingAlreadyTranscribed(CRMBooking)

    var booking: CRMBooking? {
        switch self {
        case .ready(let booking), .bookingWithoutCompany(let booking),
             .bookingClosed(let booking), .bookingAlreadyTranscribed(let booking):
            booking
        case .notConfigured, .noBooking:
            nil
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
        case .bookingClosed(let booking):
            "Le rendez-vous « \(booking.displayName) » n'est plus d'actualité (\(booking.status))."
        case .bookingAlreadyTranscribed(let booking):
            "Le rendez-vous « \(booking.displayName) » porte déjà un compte-rendu."
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
        case .bookingClosed:
            return """
            bran n'envoie pas tout seul vers un rendez-vous annulé ou reporté : \
            l'audio irait sur une fiche que personne ne relit. Si la réunion a bien \
            eu lieu, lancez l'envoi depuis la bibliothèque en choisissant ce \
            rendez-vous.
            """
        case .bookingAlreadyTranscribed:
            return """
            Un envoi automatique remplacerait le compte-rendu déjà déposé. Si c'est \
            bien ce que vous voulez — une première transcription ratée, par exemple —, \
            lancez l'envoi depuis la bibliothèque en choisissant ce rendez-vous.
            """
        }
    }

    /// - Parameter intent: `.automatic` quand bran a rapproché tout seul,
    ///   `.manual` quand quelqu'un a choisi le rendez-vous et cliqué. La valeur
    ///   par défaut est **volontairement** la plus stricte : un appelant qui
    ///   oublie de se déclarer se voit appliquer les gardes de l'envoi
    ///   automatique, et non l'inverse.
    static func evaluate(
        booking: CRMBooking?,
        isConfigured: Bool,
        intent: UploadIntent = .automatic
    ) -> UploadEligibility {
        let refusal = MeetingUploadPolicy.refusal(
            target: booking.map(\.uploadTarget),
            isConfigured: isConfigured,
            intent: intent
        )

        switch refusal {
        case .none:
            // `booking` est forcément là : la politique rend `.noBooking` sinon.
            guard let booking else { return .noBooking }
            return .ready(booking)
        case .notConfigured:
            return .notConfigured
        case .noBooking:
            return .noBooking
        case .withoutCompany:
            return booking.map { .bookingWithoutCompany($0) } ?? .noBooking
        case .inactiveBooking:
            return booking.map { .bookingClosed($0) } ?? .noBooking
        case .alreadyTranscribed:
            return booking.map { .bookingAlreadyTranscribed($0) } ?? .noBooking
        }
    }
}

extension CRMBooking {
    /// Les trois seuls faits dont la politique d'envoi a besoin.
    var uploadTarget: UploadTarget {
        UploadTarget(
            status: status,
            hasCompany: company != nil,
            hasExistingTranscription: hasExistingTranscription
        )
    }
}
