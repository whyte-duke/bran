import Foundation

/// Métadonnées d'un enregistrement, écrites dans un fichier `.json` posé **à
/// côté** du `.mp4`.
///
/// Écart assumé avec le §6 du plan, qui prévoyait SwiftData. Une base de
/// données séparée des fichiers crée deux sources de vérité qui divergent :
/// c'est de là que viennent les états `.missing` et `.corrupt` que le plan
/// devait ensuite gérer. Un fichier `.json` à côté du `.mp4` supprime la classe
/// de problèmes entière — déplacer le dossier, le copier sur un autre Mac, le
/// restaurer d'une sauvegarde : tout continue de marcher, et la bibliothèque se
/// reconstruit en lisant le dossier.
public struct RecordingMetadata: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var startedAt: Date
    public var endedAt: Date?

    /// Titre issu du calendrier. `nil` = à horodater à l'affichage, dans la
    /// langue et le fuseau du moment où on regarde.
    public var title: String?

    public var meetCode: String?
    public var calendarEventID: String?
    public var attendees: [String]
    public var notes: String

    /// Nombre de morceaux enregistrés. > 1 signifie que la session a été mise
    /// en pause puis reprise, et que le fichier final est le résultat d'une
    /// fusion.
    ///
    /// Optionnel, et pas `Int = 1` : le décodage synthétisé par Swift n'utilise
    /// PAS les valeurs par défaut des propriétés. Un champ non optionnel ajouté
    /// après coup ferait échouer la lecture de tous les `.json` déjà écrits.
    public var segmentCount: Int?

    /// Poids cumulé des segments avant compression. `nil` tant que le
    /// post-traitement n'a pas eu lieu.
    public var originalBytes: Int64?

    public var processedAt: Date?

    // MARK: - Liaison CRM
    //
    // Persistée dans le sidecar, et pas seulement en mémoire : le contrat CRM
    // prévient qu'il n'existe aucune notification poussée. C'est à bran de
    // redemander l'état au réveil, donc à bran de se souvenir de quel job
    // interroger, même après un redémarrage.

    /// Identifiant de la transcription côté CRM.
    public var transcriptionID: String?

    /// RDV cal.com auquel l'audio a été rattaché.
    public var bookingID: String?

    public var companyName: String?
    public var companyID: String?

    /// Lien de la réunion, tel que le RDV cal.com le porte. Permet de rouvrir
    /// la visio depuis la bibliothèque.
    public var meetingURL: String?

    /// Dernier `stage` connu : `upload` `queued` `transcribing` `summarizing`
    /// `ready` `failed`.
    public var crmStage: String?

    /// Message d'erreur du CRM, déjà écrit pour un humain.
    public var crmError: String?

    public var crmWarning: String?

    /// `resume` du compte-rendu — celui qui a été écrit dans `bookings.notes`.
    public var crmSummary: String?

    public var crmIssue: String?
    public var crmTemperature: Int?
    public var uploadedAt: Date?

    public init(
        id: UUID,
        startedAt: Date,
        endedAt: Date? = nil,
        title: String? = nil,
        meetCode: String? = nil,
        calendarEventID: String? = nil,
        attendees: [String] = [],
        notes: String = ""
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.title = title
        self.meetCode = meetCode
        self.calendarEventID = calendarEventID
        self.attendees = attendees
        self.notes = notes
    }

    public init(meeting: MeetingRef) {
        self.init(
            id: meeting.id,
            startedAt: meeting.startedAt,
            title: meeting.title,
            meetCode: meeting.meetCode,
            calendarEventID: meeting.calendarEventID,
            attendees: meeting.attendees
        )
    }

    /// Nom de fichier relatif à la racine de stockage. Jamais de chemin absolu :
    /// déplacer le dossier ne doit rien casser.
    public var fileName: String { "\(id.uuidString).mp4" }
    public var sidecarName: String { "\(id.uuidString).json" }
}
