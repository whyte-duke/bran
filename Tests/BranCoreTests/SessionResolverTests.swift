import Foundation
import Testing
@testable import BranCore

@Suite("SessionResolver")
struct SessionResolverTests {

    private let now = Date(timeIntervalSince1970: 1_770_000_000)
    private let fixedID = UUID(uuidString: "00000000-0000-0000-0000-00000000BEEF")!

    private func meetWindow(code: String? = "abc-defg-hij") -> MeetWindowSignal {
        MeetWindowSignal(windowTitle: "Meet - \(code ?? "sans code")", meetCode: code)
    }

    private func calendarEvent() -> CalendarSignal {
        CalendarSignal(
            eventID: "EV-1",
            title: "Point hebdo produit",
            attendees: ["alice@example.com", "bob@example.com"],
            endsAt: now.addingTimeInterval(3600)
        )
    }

    @Test("Fenêtre + événement → démarre avec le titre du calendrier")
    func windowAndCalendarStartsWithEventTitle() throws {
        var resolver = SessionResolver()
        let intent = resolver.resolve(
            windows: [meetWindow()],
            calendar: calendarEvent(),
            at: now,
            makeID: { self.fixedID }
        )

        guard case .start(let meeting) = intent else {
            Issue.record("attendu .start, reçu \(intent)")
            return
        }
        #expect(meeting.title == "Point hebdo produit")
        #expect(meeting.calendarEventID == "EV-1")
        #expect(meeting.attendees.count == 2)
        #expect(meeting.meetCode == "abc-defg-hij")
        #expect(meeting.startedAt == now)
    }

    @Test("Fenêtre seule → démarre sans titre, à horodater à l'affichage")
    func windowAloneStartsUntitled() throws {
        var resolver = SessionResolver()
        let intent = resolver.resolve(windows: [meetWindow()], at: now, makeID: { self.fixedID })

        guard case .start(let meeting) = intent else {
            Issue.record("attendu .start, reçu \(intent)")
            return
        }
        #expect(meeting.title == nil)
        #expect(meeting.calendarEventID == nil)
        #expect(meeting.attendees.isEmpty)
    }

    @Test("Événement seul → ne déclenche rien, il n'y a pas d'écran à filmer")
    func calendarAloneDoesNothing() {
        var resolver = SessionResolver()
        let intent = resolver.resolve(windows: [], calendar: calendarEvent(), at: now)

        #expect(intent == .noop)
        #expect(resolver.activeMeeting == nil)
    }

    @Test("Aucun signal, rien en cours → aucune décision")
    func nothingAtAllIsNoop() {
        var resolver = SessionResolver()
        #expect(resolver.resolve(windows: [], at: now) == .noop)
    }

    @Test("Deux fenêtres Meet de la même réunion → un seul démarrage")
    func twoWindowsStartOnlyOnce() {
        var resolver = SessionResolver()
        let windows = [meetWindow(), meetWindow()]

        let first = resolver.resolve(windows: windows, at: now, makeID: { self.fixedID })
        let second = resolver.resolve(windows: windows, at: now.addingTimeInterval(5))

        #expect(first != .noop)
        #expect(second == .noop)
    }

    @Test("Signal encore présent au tic suivant → aucun nouveau démarrage")
    func repeatedSignalDoesNotRestart() {
        var resolver = SessionResolver()
        _ = resolver.resolve(windows: [meetWindow()], at: now, makeID: { self.fixedID })

        for tick in 1...10 {
            let intent = resolver.resolve(windows: [meetWindow()], at: now.addingTimeInterval(Double(tick) * 5))
            #expect(intent == .noop)
        }
    }

    // MARK: - Hystérésis

    @Test("Signal perdu brièvement → on ne coupe pas (changement d'onglet)")
    func briefSignalLossDoesNotStop() {
        var resolver = SessionResolver(stopDelay: 120)
        _ = resolver.resolve(windows: [meetWindow()], at: now, makeID: { self.fixedID })

        // L'utilisateur consulte un autre onglet pendant une minute.
        for tick in stride(from: 5, through: 60, by: 5) {
            let intent = resolver.resolve(windows: [], at: now.addingTimeInterval(Double(tick)))
            #expect(intent == .noop, "coupure prématurée à \(tick) s")
        }

        // Il revient sur Meet : la réunion n'a jamais été interrompue.
        #expect(resolver.resolve(windows: [meetWindow()], at: now.addingTimeInterval(65)) == .noop)
        #expect(resolver.activeMeeting != nil)
    }

    @Test("Signal perdu au-delà du délai → arrêt")
    func prolongedSignalLossStops() {
        var resolver = SessionResolver(stopDelay: 120)
        _ = resolver.resolve(windows: [meetWindow()], at: now, makeID: { self.fixedID })

        #expect(resolver.resolve(windows: [], at: now.addingTimeInterval(119)) == .noop)
        #expect(resolver.resolve(windows: [], at: now.addingTimeInterval(120)) == .stop)
        #expect(resolver.activeMeeting == nil)
    }

    @Test("Le compteur d'absence repart de zéro à chaque signal retrouvé")
    func hysteresisResetsOnEverySignal() {
        var resolver = SessionResolver(stopDelay: 120)
        _ = resolver.resolve(windows: [meetWindow()], at: now, makeID: { self.fixedID })

        _ = resolver.resolve(windows: [], at: now.addingTimeInterval(100))
        _ = resolver.resolve(windows: [meetWindow()], at: now.addingTimeInterval(110))

        // 130 s après le début, mais seulement 20 s après le dernier signal.
        #expect(resolver.resolve(windows: [], at: now.addingTimeInterval(130)) == .noop)
        #expect(resolver.resolve(windows: [], at: now.addingTimeInterval(230)) == .stop)
    }

    @Test("Arrêt puis nouvelle réunion → nouveau démarrage")
    func newMeetingAfterStop() {
        var resolver = SessionResolver(stopDelay: 120)
        _ = resolver.resolve(windows: [meetWindow()], at: now, makeID: { self.fixedID })
        #expect(resolver.resolve(windows: [], at: now.addingTimeInterval(200)) == .stop)

        let intent = resolver.resolve(windows: [meetWindow(code: "xyz-qrst-uvw")], at: now.addingTimeInterval(300))
        #expect(intent != .noop)
        #expect(resolver.activeMeeting?.meetCode == "xyz-qrst-uvw")
    }

    // MARK: - Enchaînement de réunions

    @Test("Réunion différente pendant l'enregistrement → arrêt d'abord")
    func differentMeetingStopsFirst() {
        var resolver = SessionResolver()
        _ = resolver.resolve(windows: [meetWindow(code: "abc-defg-hij")], at: now, makeID: { self.fixedID })

        let intent = resolver.resolve(windows: [meetWindow(code: "xyz-qrst-uvw")], at: now.addingTimeInterval(5))
        #expect(intent == .stop, "deux réunions ne doivent pas atterrir dans le même fichier")

        let next = resolver.resolve(windows: [meetWindow(code: "xyz-qrst-uvw")], at: now.addingTimeInterval(10))
        #expect(next != .noop)
    }

    @Test("forget() permet de reproposer la même réunion")
    func forgetAllowsReproposal() {
        var resolver = SessionResolver()
        _ = resolver.resolve(windows: [meetWindow()], at: now, makeID: { self.fixedID })

        // Sans oubli, le résolveur tient la réunion pour active.
        #expect(resolver.resolve(windows: [meetWindow()], at: now.addingTimeInterval(5)) == .noop)

        resolver.forget()
        #expect(resolver.activeMeeting == nil)

        let intent = resolver.resolve(windows: [meetWindow()], at: now.addingTimeInterval(10))
        #expect(intent != .noop, "après oubli, la réunion doit pouvoir être reproposée")
    }

    @Test("forget() n'émet pas .stop")
    func forgetIsSilent() {
        var resolver = SessionResolver()
        _ = resolver.resolve(windows: [meetWindow()], at: now, makeID: { self.fixedID })
        resolver.forget()

        // Rien en cours : plus aucune décision à prendre, surtout pas un arrêt.
        #expect(resolver.resolve(windows: [], at: now.addingTimeInterval(300)) == .noop)
    }

    @Test("Titre sans code → pas de coupure spéculative")
    func missingCodeDoesNotTriggerStop() {
        var resolver = SessionResolver()
        _ = resolver.resolve(windows: [meetWindow(code: "abc-defg-hij")], at: now, makeID: { self.fixedID })

        let untitled = MeetWindowSignal(windowTitle: "Meet - Point hebdo", meetCode: nil)
        #expect(resolver.resolve(windows: [untitled], at: now.addingTimeInterval(5)) == .noop)
    }
}
