import Foundation
import Testing
@testable import BranWatch

/// **Le défaut que ces tests interdisent de revenir** : la purge comptait ses
/// tentatives, pas ses réussites. `try? removeItem` puis `removed += 1`, et un
/// fichier que le disque refuse de rendre était annoncé effacé. Comme le journal
/// contient des titres de fenêtres, l'erreur n'était pas comptable : elle
/// promettait une suppression qui n'avait pas eu lieu.
@Suite("Compte-rendu de purge du journal")
struct WatchPurgeReportTests {

    // MARK: - Le compte

    @Test("Un rapport vide est complet et n'a rien à dire")
    func vide() {
        let report = WatchPurgeReport()
        #expect(report.removed == 0)
        #expect(report.isComplete)
        #expect(report.problem == nil)
    }

    @Test("Le compte est celui des fichiers partis, pas des fichiers tentés")
    func compteLesReussites() {
        var report = WatchPurgeReport()
        report.succeeded("2026-07-01.jsonl")
        report.failed("2026-07-02.jsonl", reason: "Permission refusée")
        report.succeeded("2026-07-03.jsonl")

        #expect(report.removed == 2)
        #expect(report.isComplete == false)
    }

    /// Le cas qui produisait un « 4 supprimés » mensonger : tout échoue, donc
    /// rien n'est supprimé, et le compte doit être zéro.
    @Test("Quand tout échoue, le compte est zéro")
    func toutEchoue() {
        var report = WatchPurgeReport()
        for day in ["2026-07-01", "2026-07-02", "2026-07-03", "2026-07-04"] {
            report.failed("\(day).jsonl", reason: "Volume en lecture seule")
        }

        #expect(report.removed == 0)
        #expect(report.problem != nil)
    }

    // MARK: - La phrase

    @Test("Un succès complet ne dérange personne")
    func succesSilencieux() {
        var report = WatchPurgeReport()
        report.succeeded("2026-07-01.jsonl")
        report.succeeded("2026-07-02.jsonl")

        #expect(report.isComplete)
        #expect(report.problem == nil)
    }

    /// La phrase doit nommer le fichier : sans son nom, l'utilisateur ne peut ni
    /// vérifier ni supprimer à la main.
    @Test("Un seul échec est dit au singulier, et le fichier est nommé")
    func singulier() throws {
        var report = WatchPurgeReport()
        report.failed("2026-07-02.jsonl", reason: "Permission refusée")

        let problem = try #require(report.problem)
        #expect(problem.contains("1 journal arrivé à échéance n'a pas pu être supprimé"))
        #expect(problem.contains("2026-07-02.jsonl"))
        #expect(problem.contains("Permission refusée"))
        #expect(problem.contains("titres de fenêtres"))
    }

    @Test("Plusieurs échecs passent au pluriel")
    func pluriel() throws {
        var report = WatchPurgeReport()
        report.failed("2026-07-02.jsonl", reason: "Permission refusée")
        report.failed("2026-07-03.jsonl", reason: "Permission refusée")

        let problem = try #require(report.problem)
        #expect(problem.contains("2 journaux arrivés à échéance n'ont pas pu être supprimés"))
    }

    @Test("Au-delà de trois fichiers, la phrase compte le reste au lieu de tout lister")
    func listeAbregee() throws {
        var report = WatchPurgeReport()
        for day in 1...7 {
            report.failed(String(format: "2026-07-%02d.jsonl", day), reason: "Permission refusée")
        }

        let problem = try #require(report.problem)
        #expect(problem.contains("2026-07-01.jsonl, 2026-07-02.jsonl, 2026-07-03.jsonl et 4 autres"))
        #expect(problem.contains("2026-07-05.jsonl") == false)
        #expect(problem.contains("7 journaux"))
    }

    @Test("Quatre fichiers : « et 1 autre », pas « et 1 autres »")
    func accordDuReste() throws {
        var report = WatchPurgeReport()
        for day in 1...4 {
            report.failed(String(format: "2026-07-%02d.jsonl", day), reason: "Permission refusée")
        }

        let problem = try #require(report.problem)
        #expect(problem.contains("et 1 autre"))
        #expect(problem.contains("et 1 autres") == false)
    }

    /// Un volume débranché produit la même erreur sur chaque fichier. La répéter
    /// trente fois n'apprend rien de plus que la première.
    @Test("Une raison partagée n'est dite qu'une fois")
    func raisonDedoublonnee() throws {
        var report = WatchPurgeReport()
        report.failed("2026-07-01.jsonl", reason: "Volume introuvable")
        report.failed("2026-07-02.jsonl", reason: "Volume introuvable")

        let problem = try #require(report.problem)
        let occurrences = problem.components(separatedBy: "Volume introuvable").count - 1
        #expect(occurrences == 1)
    }

    @Test("Deux raisons distinctes sont toutes les deux dites")
    func raisonsDistinctes() throws {
        var report = WatchPurgeReport()
        report.failed("2026-07-01.jsonl", reason: "Volume introuvable")
        report.failed("2026-07-02.jsonl", reason: "Permission refusée")

        let problem = try #require(report.problem)
        #expect(problem.contains("Volume introuvable"))
        #expect(problem.contains("Permission refusée"))
    }

    // MARK: - La purge empêchée

    /// Le dossier illisible était l'autre silence : `guard let files = try? …
    /// else { return 0 }`. Zéro supprimé, aucune plainte — indistinguable d'un
    /// dossier où il n'y avait rien à supprimer.
    @Test("Un dossier illisible se dit autrement qu'un fichier récalcitrant")
    func dossierIllisible() throws {
        let report = WatchPurgeReport.blocked(by: "Le volume n'est pas monté")

        #expect(report.removed == 0)
        #expect(report.isComplete == false)

        let problem = try #require(report.problem)
        #expect(problem.contains("Le volume n'est pas monté"))
        #expect(problem.contains("toujours sur le disque"))
    }

    /// Un fichier déjà absent est un fichier dont la rétention voulait
    /// l'absence : elle l'a. Le compter comme échec ferait clignoter un
    /// avertissement pour une purge parfaitement tenue.
    @Test("Un fichier déjà absent compte comme supprimé")
    func dejaAbsent() {
        var report = WatchPurgeReport()
        report.succeeded("2026-07-01.jsonl")

        #expect(report.removed == 1)
        #expect(report.isComplete)
    }
}
