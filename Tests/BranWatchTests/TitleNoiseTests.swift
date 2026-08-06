import Foundation
import Testing
@testable import BranWatch

/// Ce que le titre d'une fenêtre a le droit de changer sans changer de voie.
///
/// Le bogue mesuré qui a motivé la moitié de ces tests :
/// `bran - root@kvm4: ~ - ssh castral-azure - 244x67`. Le `244x67` est la taille
/// de la fenêtre ; le redimensionner fabriquait une voie neuve et laissait
/// l'ancienne partir en `waiting` puis en `stale`, sans que rien ne se soit
/// passé.
@Suite("Bruit volatil dans les titres de fenêtre")
struct TitleNoiseTests {

    private func terminal(_ title: String) -> LaneIdentity {
        LaneIdentity.window(
            bundleIdentifier: "com.apple.Terminal",
            applicationName: "Terminal",
            title: title
        )
    }

    // MARK: - Le suffixe de géométrie

    @Test("Redimensionner un terminal ne crée pas une seconde voie")
    func redimensionnerNeCreePasDeVoie() {
        let avant = terminal("bran - root@kvm4: ~ - ssh castral-azure - 244x67")
        let apres = terminal("bran - root@kvm4: ~ - ssh castral-azure - 180x52")

        #expect(avant.key == apres.key)
        #expect(LaneIdentity.stableTitle("bran - root@kvm4: ~ - ssh castral-azure - 244x67")
            == "bran - root@kvm4: ~ - ssh castral-azure")
    }

    @Test("Changer la police d'un terminal ne crée pas une seconde voie")
    func changerLaPoliceNeCreePasDeVoie() {
        // Une police plus grande, c'est moins de colonnes pour la même fenêtre.
        #expect(terminal("zsh - 244x67").key == terminal("zsh - 121x33").key)
    }

    @Test("Les quatre formats d'émulateur donnent la même clé pour la même session")
    func quatreEmulateursUneSeuleVoie() {
        // La même session ssh, vue par quatre couches qui l'habillent chacune à
        // sa façon. Ce qui reste, dans les quatre cas, est « root@kvm4: ~ ».
        let formats = [
            "root@kvm4: ~ - 244x67",        // Terminal.app : géométrie en suffixe
            "3. root@kvm4: ~ — 244×67",     // iTerm2 : numéro de fenêtre + cadratin
            "[0] root@kvm4: ~*",            // tmux : index de fenêtre + drapeau
            "root@kvm4: ~ — Edited",        // application de document : modifié
        ]

        let cles = Set(formats.map { terminal($0).key })
        #expect(cles.count == 1)
        #expect(cles.first == "win:com.apple.Terminal:root@kvm4: ~")
    }

    /// Le `~` final de « root@kvm4: ~ » est le dossier personnel, et c'est aussi
    /// le drapeau « silence » de tmux. Confondre les deux amputait le titre en
    /// « root@kvm4: », un titre que personne n'a jamais vu.
    @Test("Un tilde de dossier personnel n'est pas pris pour un drapeau tmux")
    func tildeDeDossierPreserve() {
        #expect(LaneIdentity.stableTitle("[0] root@kvm4: ~*") == "root@kvm4: ~")
        #expect(LaneIdentity.stableTitle("[0] root@kvm4: ~") == "root@kvm4: ~")
    }

    @Test("Les drapeaux tmux ne sont retirés que d'un titre qui vient de tmux")
    func drapeauxSeulementSousTmux() {
        // Hors tmux, ces caractères appartiennent au titre.
        #expect(LaneIdentity.stableTitle("Visual Studio C#") == "Visual Studio C#")
        #expect(LaneIdentity.stableTitle("Compilation terminée !") == "Compilation terminée !")
        // Sous tmux — format `#S:#I:#W` — ils sont volatils.
        #expect(LaneIdentity.stableTitle("castral:0:zsh*") == "castral:0:zsh")
    }

    // MARK: - La résolution qui ne doit pas être amputée

    /// **La décision, et ce qu'elle coûte.** Une capture d'écran ouverte dans un
    /// éditeur porte légitimement « 1920x1080 » dans son titre. Deux barrières
    /// la protègent : la règle n'agit qu'en fin de titre, et seulement pour des
    /// valeurs qu'un terminal peut réellement avoir. Une résolution franchit les
    /// deux bornes à la fois, une géométrie de terminal n'en franchit aucune.
    @Test("Une résolution au milieu d'un titre n'est pas amputée")
    func resolutionAuMilieuPreservee() {
        let titre = "Capture 1920x1080.png — Aperçu"
        #expect(LaneIdentity.stableTitle(titre) == titre)
    }

    @Test("Une résolution même en position de suffixe n'est pas amputée")
    func resolutionEnSuffixePreservee() {
        // La position ne suffit pas ici : c'est la plausibilité qui sauve le
        // titre. 1080 lignes de terminal demanderaient un écran de 8 600 points.
        #expect(LaneIdentity.stableTitle("Aperçu - 1920x1080") == "Aperçu - 1920x1080")
        #expect(LaneIdentity.stableTitle("Moniteur - 2560x1440") == "Moniteur - 2560x1440")
        #expect(LaneIdentity.stableTitle("Ancien écran - 800x600") == "Ancien écran - 800x600")
    }

    @Test("Les bornes de plausibilité acceptent une vraie géométrie de terminal")
    func bornesAcceptentUnTerminal() {
        #expect(TitleNoise.cellGeometry("244x67") != nil)
        #expect(TitleNoise.cellGeometry("80x24") != nil)
        #expect(TitleNoise.cellGeometry("1920x1080") == nil)
        // Ni un mot, ni un nombre seul, ni deux marques.
        #expect(TitleNoise.cellGeometry("Linux") == nil)
        #expect(TitleNoise.cellGeometry("244") == nil)
        #expect(TitleNoise.cellGeometry("1x2x3") == nil)
    }

    // MARK: - Les autres suffixes volatils

    @Test("Un aller-retour d'enregistrement ne crée pas une seconde voie")
    func marqueurDeModificationIgnore() {
        let sale = terminal("Notes de version — Edited")
        let propre = terminal("Notes de version")
        #expect(sale.key == propre.key)
        #expect(terminal("Notes de version — Modifié").key == propre.key)
    }

    @Test("Renuméroter les fenêtres iTerm2 ne crée pas une seconde voie")
    func numeroDeFenetreIgnore() {
        #expect(terminal("3. zsh").key == terminal("7. zsh").key)
    }

    @Test("Un point qui n'est pas un numéro de fenêtre reste dans le titre")
    func pointOrdinairePreserve() {
        #expect(LaneIdentity.stableTitle("1.5 GHz — Moniteur") == "1.5 GHz — Moniteur")
        #expect(LaneIdentity.stableTitle("README.md — bran") == "README.md — bran")
    }

    @Test("Un préfixe entre crochets écrit par un humain n'est pas retiré")
    func crochetsHumainsPreserves() {
        #expect(LaneIdentity.stableTitle("[WIP] refonte du veilleur") == "[WIP] refonte du veilleur")
    }

    // MARK: - Le titre déclaré par le shell distant

    /// Sans le fragment `precmd` du README, un titre de terminal nomme la
    /// machine et jamais le travail : trois chantiers sur la même VM partagent
    /// une seule voie. Avec lui, la voie porte le dossier et la branche.
    @Test("Un shell qui déclare son travail fait passer la voie en précision stable")
    func travailDeclareEleveLaPrecision() {
        let voie = terminal("scanner · feat/ocr - 244x67")

        #expect(voie.precision == .stable)
        #expect(voie.displayName == "scanner · feat/ocr")
        #expect(voie.workingDirectory == "scanner")
        #expect(voie.branch == "feat/ocr")
    }

    @Test("Sans déclaration, la voie d'une fenêtre reste fragile")
    func sansDeclarationRestefragile() {
        let voie = terminal("root@kvm4: ~ - 244x67")
        #expect(voie.precision == .fragile)
        #expect(voie.workingDirectory == nil)
    }

    @Test("Une puce dans une phrase n'est pas prise pour une déclaration de travail")
    func puceOrdinaireNestPasUneDeclaration() {
        // Le côté droit d'une vraie déclaration est un nom de branche : jamais
        // d'espace. Une énumération française en contient toujours.
        #expect(LaneIdentity.declaredWork(in: "Réunions · trois points à voir") == nil)
        #expect(LaneIdentity.declaredWork(in: "a · b · c") == nil)
        #expect(LaneIdentity.declaredWork(in: "scanner · feat/ocr") != nil)
    }
}
