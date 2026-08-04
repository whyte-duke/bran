import Foundation

/// **Le seul point de décision du système.**
///
/// Les détecteurs rapportent des faits, `RecordingEngine` exécute. Toute la
/// politique — quand démarrer, quand arrêter, quoi faire d'un signal ambigu —
/// vit ici, et nulle part ailleurs.
public struct SessionResolver: Sendable {

    /// Délai d'absence de signal avant l'arrêt.
    ///
    /// Asymétrie volontaire : on démarre au premier tic, on s'arrête après deux
    /// minutes de silence. Le titre d'une fenêtre Chrome est celui de l'onglet
    /// ACTIF — changer d'onglet pendant une réunion fait disparaître le signal
    /// Meet alors que la réunion continue. Un arrêt symétrique couperait
    /// l'enregistrement à chaque consultation d'un autre onglet.
    public let stopDelay: TimeInterval

    private var active: MeetingRef?
    private var lastSignalAt: Date?

    public init(stopDelay: TimeInterval = 120) {
        self.stopDelay = stopDelay
    }

    public var activeMeeting: MeetingRef? { active }

    /// Oublie la réunion en cours sans émettre `.stop`.
    ///
    /// Sert quand l'appelant a renoncé de son côté — proposition abandonnée
    /// parce que la fenêtre Meet a été fermée, par exemple. Sans cet oubli, le
    /// résolveur continuerait de croire la réunion active et ne proposerait
    /// rien si l'utilisateur la rejoignait.
    public mutating func forget() {
        active = nil
        lastSignalAt = nil
    }

    public mutating func resolve(
        windows: [MeetWindowSignal],
        calendar: CalendarSignal? = nil,
        at now: Date,
        makeID: () -> UUID = UUID.init
    ) -> Intent {
        guard let window = windows.first else {
            return resolveWithoutWindow(at: now)
        }

        lastSignalAt = now

        if let active {
            // Passage d'une réunion à une autre : on arrête d'abord. Le tic
            // suivant démarrera la nouvelle. Deux fichiers distincts valent
            // mieux qu'un fichier qui chevauche deux réunions.
            if hasChangedMeeting(from: active, to: window) {
                self.active = nil
                lastSignalAt = nil
                return .stop
            }

            // Plusieurs fenêtres Meet, ou la même réunion au tic suivant :
            // un seul enregistrement.
            return .noop
        }

        let meeting = MeetingRef(
            id: makeID(),
            startedAt: now,
            title: calendar?.title,
            meetCode: window.meetCode,
            calendarEventID: calendar?.eventID,
            attendees: calendar?.attendees ?? []
        )
        active = meeting
        return .start(meeting)
    }

    private mutating func resolveWithoutWindow(at now: Date) -> Intent {
        // Aucune fenêtre et rien en cours. Un événement au calendrier seul ne
        // déclenche rien : il n'y a pas d'écran à filmer.
        guard active != nil else { return .noop }

        guard let lastSignalAt, now.timeIntervalSince(lastSignalAt) >= stopDelay else {
            return .noop
        }

        active = nil
        self.lastSignalAt = nil
        return .stop
    }

    private func hasChangedMeeting(from active: MeetingRef, to window: MeetWindowSignal) -> Bool {
        guard let activeCode = active.meetCode, let newCode = window.meetCode else {
            // Sans code des deux côtés, on ne peut pas distinguer deux réunions
            // d'une même réunion dont le titre a changé. On ne coupe pas.
            return false
        }
        return activeCode != newCode
    }
}
