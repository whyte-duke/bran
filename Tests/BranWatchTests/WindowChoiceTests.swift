import Foundation
import Testing
@testable import BranWatch

/// Le geste de retour se joue ici : activer la mauvaise fenêtre coûte plus cher
/// que de n'en activer aucune, parce que l'utilisateur perd sa place *et* sa
/// confiance dans l'outil. Tout ce qui peut se tromper de façon intéressante est
/// dans ce fichier ; le reste — `activate()`, `AXRaise` — ne se teste pas.
@Suite("Choix de la fenêtre à ramener")
struct WindowChoiceTests {

    private let crm = LaneIdentity.claudeCode(
        sessionID: "s1", workingDirectory: "/Users/x/castral/crm", branch: "feat/ocr"
    )

    // MARK: - Lire une clé de voie

    /// Un titre stable contient très souvent un deux-points — « root@kvm4: ~ »
    /// est le cas le plus banal qui soit — alors qu'un identifiant de paquet n'en
    /// contient jamais. Couper au dernier rendrait un propriétaire absurde.
    @Test("Une clé de fenêtre se découpe au premier deux-points, pas au dernier")
    func decoupageAuPremierDeuxPoints() {
        let cible = LaneTarget(key: "win:com.apple.Terminal:root@kvm4: ~")
        #expect(cible == .window(owner: "com.apple.Terminal", stableTitle: "root@kvm4: ~"))
    }

    @Test("Une clé de session Claude Code désigne son dossier de travail")
    func cleDeSessionDesigneLeDossier() {
        #expect(LaneTarget(key: crm.key) == .workspace(directory: "/Users/x/castral/crm"))
    }

    @Test("Une clé qu'on ne sait pas lire ne désigne rien plutôt que n'importe quoi")
    func cleIllisibleNeDesigneRien() {
        #expect(LaneTarget(key: "") == nil)
        #expect(LaneTarget(key: "cc:") == nil)
        #expect(LaneTarget(key: "win:") == nil)
        #expect(LaneTarget(key: "win:Terminal") == nil)
        #expect(LaneTarget(key: "autre:chose") == nil)
    }

    // MARK: - Retrouver une voie de fenêtre

    /// Le verdict et le clic ne sont pas simultanés. Entre les deux, la fenêtre
    /// peut avoir été redimensionnée : si la comparaison portait sur le titre
    /// brut, le geste de retour ne trouverait plus rien précisément dans le cas
    /// que le correctif de géométrie vient de fermer.
    @Test("Une fenêtre redimensionnée depuis le verdict reste retrouvable")
    func fenetreRedimensionneeRetrouvee() {
        let voie = LaneIdentity.window(
            bundleIdentifier: "com.apple.Terminal", applicationName: "Terminal",
            title: "root@kvm4: ~ - 244x67"
        )
        let ouvertes = [
            WindowCandidate(owner: "com.apple.Terminal", title: "root@kvm4: ~ - 96x31"),
            WindowCandidate(owner: "com.apple.Terminal", title: "root@autre: ~ - 96x31"),
        ]

        #expect(WindowChoice.best(among: ouvertes, for: voie) == ouvertes[0])
    }

    @Test("À titre stable égal, l'application propriétaire départage")
    func proprietaireDepartage() {
        let voie = LaneIdentity.window(
            bundleIdentifier: "com.googlecode.iterm2", applicationName: "iTerm2", title: "zsh"
        )
        let ouvertes = [
            WindowCandidate(owner: "com.apple.Terminal", title: "zsh"),
            WindowCandidate(owner: "com.googlecode.iterm2", title: "zsh"),
        ]

        #expect(WindowChoice.best(among: ouvertes, for: voie) == ouvertes[1])
    }

    @Test("Un identifiant de paquet et un nom d'application désignent la même app")
    func paquetEtNomSeReconnaissent() {
        #expect(WindowChoice.sameOwner("com.apple.Terminal", "Terminal"))
        #expect(WindowChoice.sameOwner("Terminal", "terminal"))
        #expect(WindowChoice.sameOwner("com.apple.Terminal", "com.apple.Safari") == false)
    }

    @Test("Aucune fenêtre ne correspond : on le dit plutôt que d'en choisir une")
    func aucuneCorrespondance() {
        let voie = LaneIdentity.window(
            bundleIdentifier: "com.apple.Terminal", applicationName: "Terminal", title: "zsh"
        )
        let ouvertes = [WindowCandidate(owner: "com.apple.Safari", title: "Actualités")]

        #expect(WindowChoice.best(among: ouvertes, for: voie) == nil)
    }

    // MARK: - Retrouver une voie Claude Code, qui n'a pas de fenêtre à elle

    @Test("Une session Claude Code se retrouve par le nom de son dossier")
    func sessionRetrouveeParLeDossier() {
        let ouvertes = [
            WindowCandidate(owner: "com.apple.Safari", title: "Actualités"),
            WindowCandidate(owner: "com.apple.Terminal", title: "crm — claude"),
        ]

        #expect(WindowChoice.best(among: ouvertes, for: crm) == ouvertes[1])
    }

    /// Sans la comparaison par mot entier, un onglet ouvert sur la page d'un
    /// homonyme volerait le geste de retour, et l'utilisateur atterrirait dans
    /// son navigateur en croyant revenir sur son terminal.
    @Test("Un homonyme dans une adresse ne vole pas le geste de retour")
    func homonymeNeVolePasLeRetour() {
        let ouvertes = [WindowCandidate(owner: "com.apple.Safari", title: "crmsoftware.com — Safari")]
        #expect(WindowChoice.best(among: ouvertes, for: crm) == nil)

        #expect(WindowChoice.containsWord("crm", in: "crm — claude"))
        #expect(WindowChoice.containsWord("crm", in: "castral/crm"))
        #expect(WindowChoice.containsWord("crm", in: "crmsoftware.com") == false)
        #expect(WindowChoice.containsWord("crm", in: "acrm") == false)
    }

    @Test("La branche départage deux fenêtres ouvertes sur le même dossier")
    func brancheDepartageDeuxFenetres() {
        let ouvertes = [
            WindowCandidate(owner: "com.apple.Terminal", title: "crm — main"),
            WindowCandidate(owner: "com.apple.Terminal", title: "crm — feat/ocr"),
        ]

        #expect(WindowChoice.best(among: ouvertes, for: crm) == ouvertes[1])
    }

    @Test("Le chemin complet l'emporte sur le seul nom de dossier")
    func cheminCompletLEmporte() {
        let ouvertes = [
            WindowCandidate(owner: "com.apple.Terminal", title: "crm — un très long titre"),
            WindowCandidate(owner: "com.apple.Terminal", title: "/Users/x/castral/crm"),
        ]

        #expect(WindowChoice.best(among: ouvertes, for: crm) == ouvertes[1])
    }

    /// Le système énumère ses fenêtres dans un ordre qui change d'un appel à
    /// l'autre. Sans départage total, le même clic ramènerait tantôt l'une,
    /// tantôt l'autre — et un geste de retour imprévisible ne s'utilise plus.
    @Test("À égalité, le choix ne dépend pas de l'ordre d'énumération du système")
    func choixIndependantDeLOrdre() {
        let a = WindowCandidate(owner: "com.apple.Terminal", title: "crm — zzz")
        let b = WindowCandidate(owner: "com.apple.Terminal", title: "crm — aaa")

        #expect(WindowChoice.best(among: [a, b], for: crm) == b)
        #expect(WindowChoice.best(among: [b, a], for: crm) == b)
    }

    @Test("Le titre le plus court gagne : c'est celui qui porte le moins d'étranger")
    func titreLePlusCourtGagne() {
        let court = WindowCandidate(owner: "com.apple.Terminal", title: "crm")
        let long = WindowCandidate(owner: "com.apple.Terminal", title: "crm — et beaucoup d'autre chose")

        #expect(WindowChoice.best(among: [long, court], for: crm) == court)
    }
}
