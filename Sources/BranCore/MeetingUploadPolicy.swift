import Foundation

/// Ce que bran a besoin de savoir d'un rendez-vous pour décider s'il a le droit
/// d'y déposer l'audio d'une réunion.
///
/// Volontairement réduit à trois faits, et pas au `CRMBooking` entier : cette
/// décision doit vivre dans une cible pure, et le modèle du contrat CRM — avec
/// ses dates, ses `Codable` et ses noms de champs en `snake_case` — vit dans
/// `BranApp`. Trois booléens suffisent à trancher, et ils se construisent en une
/// ligne à l'appel.
public struct UploadTarget: Equatable, Sendable {

    /// Le `status` tel que le CRM l'écrit : `scheduled`, `cancelled`,
    /// `rescheduled`, `completed`. Relevé le 14/08/2026 dans la base : 41, 6, 1
    /// et 1 occurrences respectivement.
    public let status: String

    /// Le RDV est-il rattaché à un lead ? `false` = compte-rendu produit,
    /// facturé, et visible sur aucune fiche.
    public let hasCompany: Bool

    /// Un compte-rendu a-t-il déjà été déposé sur ce rendez-vous ?
    public let hasExistingTranscription: Bool

    public init(status: String, hasCompany: Bool, hasExistingTranscription: Bool) {
        self.status = status
        self.hasCompany = hasCompany
        self.hasExistingTranscription = hasExistingTranscription
    }
}

/// Qui demande l'envoi.
///
/// La distinction n'est pas cosmétique : elle sépare ce que bran s'autorise à
/// faire tout seul de ce qu'un humain vient de demander en connaissance de
/// cause. Renvoyer un audio sur un rendez-vous qui porte déjà un compte-rendu
/// est une opération légitime — on refait une transcription ratée — mais
/// personne ne veut qu'elle parte sans qu'on l'ait demandée.
public enum UploadIntent: Equatable, Sendable {

    /// bran a rapproché tout seul et `autoUpload` est actif.
    case automatic

    /// Quelqu'un a choisi le rendez-vous et cliqué.
    case manual
}

/// La raison pour laquelle un envoi n'aura pas lieu.
public enum UploadRefusal: Equatable, Sendable {
    case notConfigured
    case noBooking
    case withoutCompany
    case inactiveBooking(status: String)
    case alreadyTranscribed
}

/// **La seule règle qui décide si l'audio d'un client part vers une fiche.**
///
/// Elle était écrite en trois endroits qui avaient déjà divergé :
/// `MeetingDirectory.isActive` savait écarter un rendez-vous annulé,
/// `UploadService.resolveBooking` ne regardait que l'écart horaire, et
/// `UploadEligibility.evaluate` ne contrôlait ni le statut ni la présence d'un
/// compte-rendu. Le chemin déjà rapproché par le code Meet — celui d'un
/// enregistrement qui porte son `bookingID` — appelait l'envoi directement dès
/// que `autoUpload` était actif, donc sans le garde que l'autre chemin avait.
///
/// La panne que ça produit : une réunion enregistrée reste rattachée par son
/// code Meet à un rendez-vous annulé après coup, ou à un rendez-vous qui porte
/// déjà un compte-rendu. L'audio part sans confirmation, la transcription est
/// facturée, et le nouveau compte-rendu remplace celui de quelqu'un d'autre.
/// Rien à l'écran ne le signale : les deux chemins affichent « envoyé ».
///
/// C'est pour ça que la règle est ici, dans une cible qui n'importe aucun
/// framework, avec ses tests — et pas dans une branche `if` de la couche
/// interface.
public enum MeetingUploadPolicy {

    /// Les statuts qui disent « la réunion n'a pas eu lieu comme prévu ».
    ///
    /// **`completed` n'en fait volontairement pas partie**, alors que le filtre
    /// d'affichage des prochains rendez-vous l'écarte. Les deux questions ne
    /// sont pas la même : `completed` n'est pas *à venir*, mais c'est
    /// exactement l'état qu'un rendez-vous peut avoir pris à la seconde où la
    /// réunion se termine — c'est-à-dire au moment précis où l'envoi
    /// automatique se déclenche. L'écarter ici transformerait le cas normal en
    /// refus silencieux.
    ///
    /// La liste est écrite en négatif, comme le filtre d'affichage : un statut
    /// inconnu ajouté demain côté CRM doit laisser passer l'envoi plutôt que le
    /// bloquer sans explication.
    public static let closedStatuses: Set<String> = ["cancelled", "rescheduled", "no_show"]

    /// Un rendez-vous encore d'actualité pour l'affichage : tout ce qui n'est
    /// ni clos ni déjà traité.
    ///
    /// La comparaison est faite en minuscules et sans espaces : le CRM écrit
    /// ses statuts en minuscules, mais une valeur qui arriverait en `Cancelled`
    /// ne doit pas faire réapparaître un rendez-vous annulé dans la liste.
    public static func isDisplayable(_ status: String) -> Bool {
        let normalized = normalize(status)
        return closedStatuses.contains(normalized) == false && normalized != "completed"
    }

    /// La décision d'envoi. `nil` = l'audio peut partir.
    public static func refusal(
        target: UploadTarget?,
        isConfigured: Bool,
        intent: UploadIntent
    ) -> UploadRefusal? {
        guard isConfigured else { return .notConfigured }
        guard let target else { return .noBooking }
        guard target.hasCompany else { return .withoutCompany }

        // Un envoi demandé à la main garde le droit de viser un rendez-vous
        // clos ou déjà transcrit : c'est le geste de rattrapage — le RDV a été
        // annulé dans cal.com après coup, ou la première transcription est
        // ratée — et il est fait par quelqu'un qui voit ce qu'il vise.
        guard intent == .automatic else { return nil }

        if closedStatuses.contains(normalize(target.status)) {
            return .inactiveBooking(status: target.status)
        }
        if target.hasExistingTranscription {
            return .alreadyTranscribed
        }
        return nil
    }

    private static func normalize(_ status: String) -> String {
        status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
