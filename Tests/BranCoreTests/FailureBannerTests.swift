import Foundation
import Testing
@testable import BranCore

@Suite("FailureBanner")
struct FailureBannerTests {

    @Test("Premier motif : le bandeau vaut le motif")
    func firstMessageStandsAlone() {
        #expect(FailureBanner.appending("disque plein", to: nil) == "disque plein")
        #expect(FailureBanner.appending("disque plein", to: "") == "disque plein")
    }

    @Test("Deux pannes dans la même seconde : la seconde n'efface pas la première")
    func secondFailureDoesNotEraseTheFirst() {
        let banner = FailureBanner.appending("segments non supprimés", to: "enregistrement non finalisé")
        #expect(banner.contains("enregistrement non finalisé"))
        #expect(banner.contains("segments non supprimés"))
    }

    /// Un dossier en lecture seule fait échouer une écriture à chaque frappe
    /// dans le champ « titre ». Sans dédoublonnage, le bandeau devient un mur.
    @Test("Le même motif répété n'apparaît qu'une fois")
    func repeatsAreCollapsed() {
        var banner = FailureBanner.appending("fiche non écrite", to: nil)
        for _ in 0..<50 {
            banner = FailureBanner.appending("fiche non écrite", to: banner)
        }
        #expect(banner == "fiche non écrite")
    }

    @Test("Deux lignes au maximum, les plus récentes")
    func onlyTheLastTwoSurvive() {
        var banner: String?
        for motif in ["un", "deux", "trois", "quatre"] {
            banner = FailureBanner.appending(motif, to: banner)
        }
        #expect(banner == "trois\nquatre")
        #expect(banner?.components(separatedBy: "\n").count == FailureBanner.capacity)
    }

    @Test("Un motif ancien remonte en dernier quand il revient")
    func recurrenceMovesToTheEnd() {
        var banner = FailureBanner.appending("un", to: nil)
        banner = FailureBanner.appending("deux", to: banner)
        banner = FailureBanner.appending("un", to: banner)
        #expect(banner == "deux\nun")
    }
}
