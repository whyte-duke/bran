import Foundation

// Types du contrat `crm/docs/recorder-macos.md`. Les noms de champs suivent le
// JSON pour que la correspondance reste évidente à la relecture.

struct CRMBooking: Codable, Identifiable, Sendable, Hashable {
    struct Company: Codable, Sendable, Hashable {
        let id: String
        let nom: String
        let domain: String?
        let owner_sdr: String?
    }

    struct ExistingTranscription: Codable, Sendable, Hashable {
        let id: String
        let stage: String
        let label: String?
        let original_filename: String?
        let created_at: String?
    }

    let booking_id: String
    let cal_uid: String?
    let start_at: Date
    let end_at: Date?
    let status: String
    let attendee_name: String?
    let attendee_email: String?
    let meeting_url: String?
    let detected_domain: String?
    let company: Company?
    let transcriptions: [ExistingTranscription]?

    var id: String { booking_id }

    /// `null` = RDV non rattaché à un lead. Un audio déposé là produit un
    /// compte-rendu sans nom d'entreprise, qui n'apparaît sur aucune fiche.
    var isOrphan: Bool { company == nil }

    var hasExistingTranscription: Bool {
        (transcriptions?.isEmpty ?? true) == false
    }

    var displayName: String {
        company?.nom ?? attendee_name ?? detected_domain ?? "RDV sans nom"
    }

    var plannedDuration: TimeInterval? {
        end_at.map { $0.timeIntervalSince(start_at) }
    }
}

struct CRMTargets: Codable, Sendable {
    let bookings: [CRMBooking]
}

struct CRMCreateRequest: Codable, Sendable {
    let source_type: String
    let booking_id: String?
    let filename: String
    let mime_type: String
    let size_bytes: Int
    let audio_duration_ms: Int
    let max_speakers: Int
    let created_by: String
    let summary_complement: String?
}

struct CRMCreateResponse: Codable, Sendable {
    struct Upload: Codable, Sendable {
        let url: String
        let token: String?
        let path: String?
    }

    let id: String
    let engine: String?
    let upload: Upload
}

struct CRMStartResponse: Codable, Sendable {
    let id: String?
    let status: String?
    let alreadyStarted: Bool?
}

/// Les six étapes du §5.5. `stage` est le champ qui pilote l'interface —
/// `status` et `summary_status` sont l'état brut, utiles au diagnostic.
enum CRMStage: String, Codable, Sendable {
    case upload
    case queued
    case transcribing
    case summarizing
    case ready
    case failed

    var isTerminal: Bool { self == .ready || self == .failed }
}

struct CRMStatus: Codable, Sendable {
    let id: String
    let stage: CRMStage
    let label: String?
    let progress: Int?
    let error: String?
    let warning: String?
    let status: String?
    let summary_status: String?
    let engine: String?
    let attempts: Int?
    let segments_count: Int?
    let duration_ms: Int?
    let company: CRMBooking.Company?
    let summary: CRMSummary?
    let crm_url: String?

    /// Le mode asynchrone (> 70 min d'audio) peut rester sur `transcribing`
    /// plusieurs minutes sans que rien ne soit bloqué.
    var isBatchEngine: Bool { engine == "azure_batch" }
}

struct CRMSummary: Codable, Sendable {
    struct Objection: Codable, Sendable {
        let objection: String?
        let reponse_apportee: String?
        let traitee: Bool?
    }

    struct Verbatim: Codable, Sendable {
        let timestamp: String?
        let citation: String?
        let pourquoi: String?
    }

    struct Speaker: Codable, Sendable {
        let numero: Int?
        let role: String?
        let nom: String?
        let indice: String?
    }

    let issue_rdv: String?
    let temperature_lead: Int?
    let temperature_justification: String?
    let prix_annonce_eur_ht: Double?
    let prix_perimetre: String?
    let decideur_present: Bool?
    let decideur_nom: String?
    let prochaine_etape: String?
    let next_action_at: String?
    let resume: String?
    let objections: [Objection]?
    let axes_amelioration: [String]?
    let verbatims_cles: [Verbatim]?
    let locuteurs: [Speaker]?
    let model: String?

    var issueLabel: String? {
        switch issue_rdv {
        case "signe": "Signé"
        case "oui_verbal": "Oui verbal"
        case "a_relancer": "À relancer"
        case "pas_interesse": "Pas intéressé"
        case "sans_suite_claire": "Sans suite claire"
        default: issue_rdv
        }
    }
}

/// Le CRM répond **toujours** `{"error": "phrase en français"}` en cas d'échec.
/// On l'affiche telle quelle : elle est écrite pour un humain.
struct CRMErrorBody: Codable, Sendable {
    let error: String
}
