import Foundation

/// Un fait rapporté par `CalendarWatcher`. Enrichit, ne déclenche jamais :
/// un événement au calendrier sans fenêtre à l'écran n'est pas une réunion,
/// c'est un rendez-vous.
public struct CalendarSignal: Equatable, Sendable {
    public let eventID: String
    public let title: String
    public let attendees: [String]
    public let endsAt: Date?

    public init(eventID: String, title: String, attendees: [String], endsAt: Date?) {
        self.eventID = eventID
        self.title = title
        self.attendees = attendees
        self.endsAt = endsAt
    }
}
