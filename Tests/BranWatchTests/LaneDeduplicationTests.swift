import Foundation
import Testing
@testable import BranWatch

/// **Le dédoublonnage entre ce qu'on sait et ce qu'on devine.**
///
/// Une erreur dans un sens fabrique une voie fantôme — deux lignes pour un seul
/// travail, dont une qui déclenchera des alertes que rien ne justifie. Une
/// erreur dans l'autre sens fait disparaître une voie légitime. Les deux se
/// jouent sur un `contains` de chaîne, ce qui est exactement le genre de code
/// qu'on croit évident jusqu'à ce qu'il ne le soit plus.
@Suite("Dédoublonnage des voies")
struct LaneDeduplicationTests {

    private func fenetre(_ title: String) -> LaneIdentity {
        .window(bundleIdentifier: "com.apple.Terminal", applicationName: "Terminal", title: title)
    }

    private func session(_ path: String) -> LaneIdentity {
        .claudeCode(sessionID: "s", workingDirectory: path, branch: "main")
    }

    // MARK: - Le nom de dossier

    @Test("Seul le dernier segment du chemin compte, en minuscules")
    func dernierSegment() {
        #expect(LaneDeduplication.folderName("/Users/x/Documents/castral/CRM") == "crm")
        #expect(LaneDeduplication.folderName("crm") == "crm")
    }

    /// Un chemin terminé par une barre oblique rendait la chaîne vide, qui est
    /// contenue dans tous les titres : **une seule** voie certaine avec un tel
    /// chemin faisait disparaître toutes les voies observées à l'image.
    @Test("Une barre oblique finale ne vide pas le nom de dossier")
    func barreObliqueFinale() {
        #expect(LaneDeduplication.folderName("/Users/x/castral/crm/") == "crm")
    }

    @Test("Les dossiers sont collectés depuis les voies qui en ont un")
    func collecteDesDossiers() {
        let folders = LaneDeduplication.folderNames(of: [
            session("/Users/x/castral/crm"),
            session("/Users/x/castral/bran"),
            fenetre("Safari — actualités"),   // aucune voie de travail : ignorée
        ])
        #expect(folders == ["crm", "bran"])
    }

    // MARK: - Le verdict

    /// Le cas visé, mot pour mot : un terminal qui fait tourner `claude` dans
    /// `castral/crm` s'intitule « crm — claude — 120×30 ».
    @Test("Un terminal nommé comme un dossier suivi est un doublon")
    func terminalDoublon() {
        let folders = LaneDeduplication.folderNames(of: [session("/Users/x/castral/crm")])
        #expect(LaneDeduplication.isDistinct(fenetre("crm — claude — 120×30"), from: folders) == false)
    }

    @Test("La comparaison ignore la casse du titre")
    func casseIgnoree() {
        let folders = LaneDeduplication.folderNames(of: [session("/Users/x/castral/CRM")])
        #expect(LaneDeduplication.isDistinct(fenetre("CRM — claude"), from: folders) == false)
    }

    @Test("Une fenêtre sans rapport reste une voie à part entière")
    func fenetreDistincte() {
        let folders = LaneDeduplication.folderNames(of: [session("/Users/x/castral/crm")])
        #expect(LaneDeduplication.isDistinct(fenetre("Safari — actualités"), from: folders))
        #expect(LaneDeduplication.isDistinct(fenetre("Mail — Boîte de réception"), from: folders))
    }

    @Test("Sans aucune voie certaine, rien n'est masqué")
    func aucuneVoieCertaine() {
        #expect(LaneDeduplication.isDistinct(fenetre("crm — claude"), from: []))
    }

    /// Le garde-fou : un dossier au nom vide est contenu dans tous les titres.
    /// Sans lui, une seule voie certaine mal formée effacerait la liste entière.
    @Test("Un dossier au nom vide ne masque rien")
    func dossierVide() {
        #expect(LaneDeduplication.isDistinct(fenetre("n'importe quoi"), from: [""]))
        #expect(LaneDeduplication.folderName("/") == "")
    }

    /// Le prix assumé de l'heuristique, écrit noir sur blanc pour qu'un
    /// changement de politique casse ce test plutôt que la liste de quelqu'un :
    /// une fenêtre qui *contient* le nom d'un dossier suivi est masquée, même si
    /// elle n'a rien à voir avec lui.
    @Test("Le faux positif de l'heuristique est connu et assumé")
    func fauxPositifAssume() {
        let folders = LaneDeduplication.folderNames(of: [session("/Users/x/projets/api")])
        #expect(LaneDeduplication.isDistinct(fenetre("Rapidapi — documentation"), from: folders) == false)
    }
}
