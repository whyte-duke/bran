import Foundation
import Testing
@testable import BranCore

@Suite("SegmentCleanup")
struct SegmentCleanupTests {

    @Test("Tout est parti → rien à dire")
    func cleanIsSilent() {
        let cleanup = SegmentCleanup(removed: ["BEEF-seg000.mp4", "BEEF-seg001.mp4"])
        #expect(cleanup.isClean)
        #expect(cleanup.problem == nil)
    }

    @Test("Un objet vide est propre")
    func emptyIsClean() {
        #expect(SegmentCleanup().isClean)
        #expect(SegmentCleanup().problem == nil)
    }

    /// Le défaut R5 : la fusion réussissait, la suppression échouait, et le
    /// `try?` rapportait un ménage qui n'avait pas eu lieu.
    @Test("Un morceau survivant se dit, et se nomme")
    func oneLeftoverIsNamed() throws {
        let cleanup = SegmentCleanup(
            removed: ["BEEF-seg000.mp4"],
            leftovers: [.init(name: "BEEF-seg001.mp4", reason: "volume en lecture seule")]
        )

        #expect(cleanup.isClean == false)
        let problem = try #require(cleanup.problem)
        #expect(problem.contains("BEEF-seg001.mp4"), "sans le nom, le ménage à la main est impossible")
        #expect(problem.contains("volume en lecture seule"))
        #expect(problem.contains("Un morceau"))
    }

    @Test("Plusieurs morceaux : le compte est juste et tous sont nommés")
    func manyLeftoversAreCounted() throws {
        let cleanup = SegmentCleanup(
            leftovers: [
                .init(name: "BEEF-seg000.mp4", reason: "fichier verrouillé"),
                .init(name: "BEEF-seg001.mp4", reason: "fichier verrouillé"),
                .init(name: "BEEF-seg002.mp4", reason: "fichier verrouillé"),
            ]
        )

        let problem = try #require(cleanup.problem)
        #expect(problem.contains("3 morceaux"))
        #expect(problem.contains("BEEF-seg000.mp4"))
        #expect(problem.contains("BEEF-seg002.mp4"))
    }

    /// Le message doit rassurer sur ce qui compte vraiment : la réunion est
    /// entière. Sinon l'utilisateur croit à une perte et cherche là où il n'y a
    /// rien.
    @Test("Le message distingue le ménage raté de la réunion perdue")
    func leftoversDoNotSoundLikeDataLoss() throws {
        let problem = try #require(
            SegmentCleanup(leftovers: [.init(name: "A-seg000.mp4", reason: "disque plein")]).problem
        )
        #expect(problem.contains("complet"))
    }
}
