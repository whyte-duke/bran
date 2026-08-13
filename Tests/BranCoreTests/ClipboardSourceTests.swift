import Foundation
import Testing
@testable import BranCore

@Suite("La provenance d'une entrée")
struct ClipboardSourceTests {

    private func source(_ title: String?, app: String? = "Google Chrome") -> ClipboardSource {
        ClipboardSource(bundleIdentifier: "com.google.Chrome", name: app, windowTitle: title)
    }

    @Test("Un titre trop long est ramené au nom du site")
    func titreLongRamenéAuSite() {
        #expect(source("Diagnostic stratégique cyber | Castral | Cal.com").shortOrigin == "Cal.com")
        #expect(source("Bulletin d'exposition LACME — Google Docs").shortOrigin == "Google Docs")
        #expect(source("whyte-duke/bran: l'application · GitHub").shortOrigin == "GitHub")
    }

    @Test("Un titre qui tient déjà est rendu tel quel")
    func titreCourtInchangé() {
        // Le découper perdrait de l'information sans rien gagner.
        #expect(source("Castral CRM").shortOrigin == "Castral CRM")
        #expect(source("Notes | Perso").shortOrigin == "Notes | Perso")
    }

    @Test("Une phrase avec un tiret n'est pas un nom de site")
    func phraseAvecTiret() {
        // Le dernier segment dépasse le seuil : ce n'est pas une étiquette, on
        // garde le titre entier et c'est l'affichage qui le rognera.
        let long = "Réunion — nous reprendrons contact la semaine prochaine sans faute"
        #expect(source(long).shortOrigin == long)
    }

    @Test("Sans titre, c'est le nom de l'application qui parle")
    func repliSurLApplication() {
        // Sans l'autorisation Enregistrement de l'écran aucun titre n'est
        // lisible, et les entrées écrites avant ce champ n'en portent pas.
        #expect(source(nil).shortOrigin == "Google Chrome")
        #expect(source("   ").shortOrigin == "Google Chrome")
        #expect(source(nil, app: nil).shortOrigin == nil)
    }
}
