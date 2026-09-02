import Foundation
import Testing
@testable import BranCore

/// **Ce que ce fichier protège** : que l'audio d'un client ne parte jamais tout
/// seul vers la mauvaise fiche.
///
/// Trois pannes réelles sont visées, et elles ont toutes la même signature —
/// l'envoi réussit, l'écran affiche « envoyé », et personne ne voit le dégât
/// avant des semaines. Un rendez-vous annulé après coup mais toujours rattaché
/// à l'enregistrement par son code Meet. Un rendez-vous qui porte déjà un
/// compte-rendu, que le nouveau remplace. Et la dissymétrie entre les deux
/// chemins d'envoi : celui qui passait par le code Meet appelait l'envoi
/// directement, sans le garde que l'autre avait.
///
/// Le quatrième cas est l'inverse, et il compte autant : un envoi refusé qui
/// aurait dû passer est une réunion perdue pour le CRM. D'où les tests qui
/// vérifient ce que la politique **laisse** passer.
@Suite("MeetingUploadPolicy")
struct MeetingUploadPolicyTests {

    private func target(
        status: String = "scheduled",
        company: Bool = true,
        transcription: Bool = false
    ) -> UploadTarget {
        UploadTarget(status: status, hasCompany: company, hasExistingTranscription: transcription)
    }

    @Test("Un rendez-vous annulé ne reçoit rien tout seul")
    func annuleBloqueLAutomatique() {
        let refus = MeetingUploadPolicy.refusal(
            target: target(status: "cancelled"),
            isConfigured: true,
            intent: .automatic
        )
        #expect(refus == .inactiveBooking(status: "cancelled"))
    }

    @Test("Reporté et absence sont clos au même titre qu'annulé")
    func reporteEtAbsenceBloquent() {
        for status in ["rescheduled", "no_show"] {
            #expect(
                MeetingUploadPolicy.refusal(
                    target: target(status: status),
                    isConfigured: true,
                    intent: .automatic
                ) == .inactiveBooking(status: status),
                "« \(status) » doit bloquer l'envoi automatique"
            )
        }
    }

    /// Le piège inverse : `completed` est écarté de la liste des prochains
    /// rendez-vous, et le recopier ici aurait bloqué le cas normal — un
    /// rendez-vous passé au statut « traité » à la seconde où la réunion se
    /// termine, c'est-à-dire au moment exact où l'envoi automatique part.
    @Test("Un rendez-vous terminé reste envoyable : ce n'est pas un rendez-vous clos")
    func termineResteEnvoyable() {
        #expect(
            MeetingUploadPolicy.refusal(
                target: target(status: "completed"),
                isConfigured: true,
                intent: .automatic
            ) == nil
        )
        #expect(MeetingUploadPolicy.isDisplayable("completed") == false, "mais il n'est plus « à venir »")
    }

    @Test("Un compte-rendu déjà déposé n'est jamais écrasé sans qu'on le demande")
    func transcriptionExistanteBloqueLAutomatique() {
        #expect(
            MeetingUploadPolicy.refusal(
                target: target(transcription: true),
                isConfigured: true,
                intent: .automatic
            ) == .alreadyTranscribed
        )
    }

    @Test("Le même envoi demandé à la main passe : c'est le geste de rattrapage")
    func laMainPasseOuLAutomatiqueRefuse() {
        #expect(
            MeetingUploadPolicy.refusal(
                target: target(status: "cancelled", transcription: true),
                isConfigured: true,
                intent: .manual
            ) == nil
        )
    }

    @Test("Un rendez-vous sans entreprise est refusé, y compris à la main")
    func sansEntrepriseRefusePartout() {
        for intent in [UploadIntent.automatic, .manual] {
            #expect(
                MeetingUploadPolicy.refusal(
                    target: target(company: false),
                    isConfigured: true,
                    intent: intent
                ) == .withoutCompany
            )
        }
    }

    @Test("Sans liaison CRM, rien ne part — et c'est dit avant tout le reste")
    func liaisonAbsentePrimeSurLeReste() {
        #expect(
            MeetingUploadPolicy.refusal(target: nil, isConfigured: false, intent: .manual)
                == .notConfigured
        )
        #expect(
            MeetingUploadPolicy.refusal(target: target(), isConfigured: false, intent: .manual)
                == .notConfigured
        )
    }

    @Test("Sans rendez-vous, il n'y a rien à viser")
    func sansRendezVous() {
        #expect(
            MeetingUploadPolicy.refusal(target: nil, isConfigured: true, intent: .automatic)
                == .noBooking
        )
    }

    @Test("Le cas normal passe : rendez-vous prévu, entreprise connue, rien de déposé")
    func casNormalPasse() {
        #expect(
            MeetingUploadPolicy.refusal(target: target(), isConfigured: true, intent: .automatic) == nil
        )
    }

    /// Un statut écrit autrement par le CRM ne doit pas rouvrir la porte : la
    /// comparaison est faite en minuscules et sans espaces.
    @Test("Un statut annulé écrit autrement bloque quand même")
    func statutInsensibleALaCasse() {
        #expect(
            MeetingUploadPolicy.refusal(
                target: target(status: " Cancelled "),
                isConfigured: true,
                intent: .automatic
            ) == .inactiveBooking(status: " Cancelled ")
        )
        #expect(MeetingUploadPolicy.isDisplayable(" CANCELLED ") == false)
    }

    /// La liste est écrite en négatif exprès : un statut ajouté demain côté CRM
    /// doit laisser passer plutôt que bloquer sans explication.
    @Test("Un statut inconnu laisse passer plutôt que de bloquer en silence")
    func statutInconnuLaissePasser() {
        #expect(
            MeetingUploadPolicy.refusal(
                target: target(status: "awaiting_payment"),
                isConfigured: true,
                intent: .automatic
            ) == nil
        )
        #expect(MeetingUploadPolicy.isDisplayable("awaiting_payment"))
    }
}
