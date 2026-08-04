import Testing
@testable import BranCore

@Suite("MeetTitleMatcher")
struct MeetTitleMatcherTests {

    @Test("Titres qui désignent une réunion en cours", arguments: [
        "Meet - abc-defg-hij",
        "Meet – abc-defg-hij",              // tiret demi-cadratin, celui de Chrome
        "Meet — abc-defg-hij",
        "Réunion équipe - Google Meet",     // pas de préfixe, mais… voir note ci-dessous
        "Meet - Point hebdo",
        "abc-defg-hij - Google Meet",
    ])
    func matchesMeetingTitles(_ title: String) {
        #expect(MeetTitleMatcher.isMeeting(title), "attendu vrai pour \(title)")
    }

    @Test("Titres qui ne désignent pas une réunion", arguments: [
        "Slack | #meeting",                 // faux positif classique
        "Google Meet",                      // page d'accueil, pas encore en réunion
        "Meet",
        "",                                 // TCC refusée : aucun titre exposé
        "   ",
        "Meeting notes - Notion",
        "Zoom Meeting",
        "Comment démarrer avec Google Meet - Documentation",
    ])
    func rejectsNonMeetingTitles(_ title: String) {
        #expect(MeetTitleMatcher.isMeeting(title) == false, "attendu faux pour \(title)")
    }

    @Test("Extraction du code de réunion")
    func extractsMeetCode() {
        #expect(MeetTitleMatcher.meetCode(in: "Meet - abc-defg-hij") == "abc-defg-hij")
        #expect(MeetTitleMatcher.meetCode(in: "Meet – xyz-qrst-uvw") == "xyz-qrst-uvw")
        #expect(MeetTitleMatcher.meetCode(in: "Meet - Point hebdo") == nil)
    }

    @Test("Le code n'est pas confondu avec du texte quelconque")
    func doesNotOverMatchCodes() {
        #expect(MeetTitleMatcher.meetCode(in: "une-suite-de-mots-ici") == nil)
        #expect(MeetTitleMatcher.meetCode(in: "abcd-defg-hij") == nil)
        #expect(MeetTitleMatcher.meetCode(in: "abc-defgh-hij") == nil)
    }

    @Test("Le signal porte le titre brut, pas le titre normalisé")
    func preservesRawTitle() throws {
        let signal = try #require(MeetTitleMatcher.signal(from: "  Meet - abc-defg-hij  ", owningApplication: "Google Chrome"))
        #expect(signal.windowTitle == "Meet - abc-defg-hij")
        #expect(signal.meetCode == "abc-defg-hij")
        #expect(signal.owningApplication == "Google Chrome")
    }
}
