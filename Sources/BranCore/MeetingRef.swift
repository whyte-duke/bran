import Foundation

/// Identité d'une réunion en cours. Produite par `SessionResolver`, consommée
/// par `RecordingEngine` et le stockage.
public struct MeetingRef: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let startedAt: Date

    /// Titre issu du calendrier, `nil` si aucun événement ne correspond.
    ///
    /// Écart assumé avec le §6 du plan, qui voulait un `title` non optionnel
    /// « horodaté sinon ». Écrire une date déjà formatée dans la base la fige
    /// dans la langue et le fuseau du jour de l'enregistrement. On garde
    /// `startedAt` et on formate à l'affichage : c'est réversible, localisable,
    /// et ça rend `SessionResolver` testable sans dépendre de la locale.
    public let title: String?

    public let meetCode: String?
    public let calendarEventID: String?
    public let attendees: [String]

    public init(
        id: UUID,
        startedAt: Date,
        title: String?,
        meetCode: String?,
        calendarEventID: String?,
        attendees: [String]
    ) {
        self.id = id
        self.startedAt = startedAt
        self.title = title
        self.meetCode = meetCode
        self.calendarEventID = calendarEventID
        self.attendees = attendees
    }
}
