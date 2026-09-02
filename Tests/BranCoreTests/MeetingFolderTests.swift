import Foundation
import Testing
@testable import BranCore

@Suite("Le nom d'un dossier de réunion")
struct MeetingFolderTests {

    /// Les dates sont construites par composantes, jamais par une chaîne ISO :
    /// `stamp` lit le calendrier de la machine, et un test qui figerait un
    /// instant absolu s'écrirait autrement à Paris et à Tokyo. Ici, 9 h 57 est
    /// 9 h 57 partout, ce qui est exactement la promesse de la source.
    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        var parts = DateComponents()
        parts.year = year
        parts.month = month
        parts.day = day
        parts.hour = hour
        parts.minute = minute
        guard let date = Calendar.current.date(from: parts) else {
            Issue.record("date impossible à construire : \(year)-\(month)-\(day) \(hour):\(minute)")
            return Date()
        }
        return date
    }

    // MARK: - L'horodatage

    @Test("L'horodatage est zéro-rempli, dans l'ordre année-mois-jour")
    func horodatageZeroRempli() {
        // Le zéro-remplissage n'est pas cosmétique : sans lui, « 2026-1-5 9h7 »
        // se trierait après « 2026-10-05 », et la bibliothèque partirait dans le
        // désordre dès le mois d'octobre.
        #expect(MeetingFolder.stamp(date(2026, 1, 5, 9, 7)) == "2026-01-05 09h07")
        #expect(MeetingFolder.stamp(date(2026, 8, 11, 9, 57)) == "2026-08-11 09h57")
        #expect(MeetingFolder.stamp(date(2026, 12, 31, 23, 59)) == "2026-12-31 23h59")
        #expect(MeetingFolder.stamp(date(2026, 8, 11, 0, 0)) == "2026-08-11 00h00")
    }

    @Test("L'horodatage ne contient jamais de « : » ni de « / »")
    func horodatageSansSeparateurDeChemin() {
        // Le Finder affiche encore un « : » comme un « / » : « 2026-08-11 09/57 »
        // ne veut plus rien dire, et un « / » réel fabriquerait un sous-dossier.
        for hour in 0..<24 {
            let stamp = MeetingFolder.stamp(date(2026, 8, 11, hour, 30))
            #expect(stamp.contains(":") == false, "« : » dans \(stamp)")
            #expect(stamp.contains("/") == false, "« / » dans \(stamp)")
        }
    }

    @Test("L'ordre alphabétique des horodatages est l'ordre chronologique")
    func ordreAlphabetiqueEgaleOrdreChronologique() {
        // C'est la raison d'être du format : une colonne de noms est le seul tri
        // que le Finder offre, et c'est aussi celui de la bibliothèque.
        let chronologique = [
            date(2025, 12, 31, 23, 59),
            date(2026, 1, 1, 0, 0),
            date(2026, 1, 5, 9, 7),
            date(2026, 1, 5, 9, 8),
            date(2026, 1, 5, 10, 0),
            date(2026, 2, 1, 8, 0),
            date(2026, 8, 11, 9, 57),
            date(2026, 10, 1, 8, 0),
            date(2026, 12, 31, 23, 59),
        ]

        let stamps = chronologique.map(MeetingFolder.stamp)
        #expect(stamps.sorted() == stamps, "le tri par nom ne rend pas l'ordre des réunions")
    }

    // MARK: - Le nom du dossier

    @Test("Avec un titre, l'horodatage reste en tête")
    func nomAvecTitre() {
        let nom = MeetingFolder.name(startedAt: date(2026, 8, 11, 9, 57), title: "SA SERMATEC")
        #expect(nom == "2026-08-11 09h57 — SA SERMATEC")
    }

    @Test("Sans titre — et sans titre qui survive — on obtient l'horodatage seul")
    func nomSansTitreExploitable() {
        // Le défaut à empêcher : un dossier appelé « 2026-08-11 09h57 — », qui se
        // termine sur un tiret et un blanc que le Finder rognerait de toute façon.
        let debut = date(2026, 8, 11, 9, 57)
        let attendu = "2026-08-11 09h57"

        #expect(MeetingFolder.name(startedAt: debut, title: nil) == attendu)
        #expect(MeetingFolder.name(startedAt: debut, title: "") == attendu)
        #expect(MeetingFolder.name(startedAt: debut, title: "     ") == attendu)
        #expect(MeetingFolder.name(startedAt: debut, title: "...") == attendu)

        for titre in [nil, "", "     ", "..."] as [String?] {
            let nom = MeetingFolder.name(startedAt: debut, title: titre)
            #expect(nom.hasSuffix("—") == false && nom.hasSuffix("— ") == false, "nom orphelin : « \(nom) »")
        }
    }

    // MARK: - Ce que le système de fichiers refuse

    /// **Le plafond de 60 *graphèmes* ne protège de rien**, parce que ce n'est
    /// pas dans cette unité que macOS compte. Mesuré sur APFS (macOS 26.5) :
    ///
    /// | nom | graphèmes | unités UTF-16 NFD | `mkdir` |
    /// |---|---|---|---|
    /// | 255 × `a` | 255 | 255 | accepté |
    /// | 256 × `a` | 256 | 256 | refusé (514) |
    /// | 128 × `é` en NFC | 128 | 256 | refusé (514) |
    /// | horodatage + 60 × 🙂 | 79 | 139 | accepté |
    /// | horodatage + 60 × 👨‍👩‍👧‍👦 | 79 | **679** | refusé (514) |
    /// | horodatage + 60 × `e` à 20 accents | 79 | **1279** | refusé (514) |
    ///
    /// La borne est donc 255 unités UTF-16 **de la forme décomposée**, et un
    /// graphème peut en peser autant qu'il veut. Un titre de réunion vient d'un
    /// titre de fenêtre, donc de la page web affichée : personne ne choisit ces
    /// caractères-là.
    ///
    /// Le symptôme : `createDirectory` refuse, la réunion reste à plat dans la
    /// racine ou ses médias ne sont pas renommés, alors que le plafond était
    /// annoncé comme sûr.
    @Test("Un titre que le système refuserait est ramené à un nom créable")
    func titreRamenéÀUnNomCréable() throws {
        let debut = date(2026, 8, 11, 9, 57)
        let dossier = URL.temporaryDirectory.appending(path: "MeetingFolderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dossier, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dossier) }

        let hostiles = [
            String(repeating: "👨‍👩‍👧‍👦", count: 60),
            String(repeating: "e" + String(repeating: "\u{0301}", count: 20), count: 60),
            String(repeating: "é", count: 300),
            String(repeating: "a", count: 4000),
        ]

        for titre in hostiles {
            let nom = MeetingFolder.name(startedAt: debut, title: titre)
            #expect(nom.hasPrefix("2026-08-11 09h57"))

            // Le dossier se crée, et le média qui reprend son nom aussi — c'est
            // la marge que le plafond doit garder pour « (2) » et « .mp4 ».
            let cible = dossier.appending(path: "\(nom) (50)")
            try FileManager.default.createDirectory(at: cible, withIntermediateDirectories: false)
            try Data("x".utf8).write(to: cible.appending(path: "\(nom) (50).mp4"))
        }
    }

    /// L'autre moitié : la borne ne doit pas rogner ce qui tenait déjà. Un titre
    /// de réunion réel tient très en dessous.
    @Test("Un titre ordinaire traverse la borne sans être touché")
    func titreOrdinaireIntact() {
        let debut = date(2026, 8, 11, 9, 57)
        #expect(
            MeetingFolder.name(startedAt: debut, title: "Closing L'Étoile & Fils")
                == "2026-08-11 09h57 — Closing L'Étoile & Fils"
        )
        // Soixante caractères accentués : 120 unités décomposées, largement sous
        // la borne, et le plafond de lisibilité ne les touche pas non plus.
        let soixante = String(repeating: "é", count: 60)
        #expect(MeetingFolder.name(startedAt: debut, title: soixante).hasSuffix(soixante))
    }

    // MARK: - L'assainissement du titre

    @Test("Un séparateur de chemin devient une espace, il ne disparaît pas")
    func separateursRemplacesParUneEspace() {
        // « CastralOrpheo » serait un mot que personne ne cherche : les deux mots
        // doivent rester deux mots.
        #expect(MeetingFolder.sanitized("Castral/Orpheo") == "Castral Orpheo")
        #expect(MeetingFolder.sanitized("Castral:Orpheo") == "Castral Orpheo")
        #expect(MeetingFolder.sanitized("A/B:C") == "A B C")
    }

    @Test("Les espaces multiples et les sauts de ligne sont repliés en une seule espace")
    func espacesReplies() {
        #expect(MeetingFolder.sanitized("Point    hebdo") == "Point hebdo")
        #expect(MeetingFolder.sanitized("Point\nhebdo") == "Point hebdo")
        #expect(MeetingFolder.sanitized("Point\t/  hebdo") == "Point hebdo")
        #expect(MeetingFolder.sanitized("  Point hebdo  ") == "Point hebdo")
    }

    @Test("Les points de tête sont retirés, y compris « .. » et « ... »")
    func pointsDeTeteRetires() {
        // Un seul point cache le dossier ; « .. » et « ... » sont pires. Le
        // retrait est répété, sinon « ...RDV » resterait « ..RDV ».
        #expect(MeetingFolder.sanitized(".RDV") == "RDV")
        #expect(MeetingFolder.sanitized("..RDV") == "RDV")
        #expect(MeetingFolder.sanitized("...RDV") == "RDV")
        #expect(MeetingFolder.sanitized("..") == nil)

        // Un point à l'intérieur n'a rien de dangereux et reste en place.
        #expect(MeetingFolder.sanitized("R.D.V. LACME") == "R.D.V. LACME")
    }

    @Test("Les accents, apostrophes et esperluettes sont gardés")
    func caracteresFrancaisGardes() {
        // Les déformer pour se conformer à des règles Windows qui ne s'appliquent
        // pas ici ferait chercher la réunion sous un nom qui n'est pas le sien.
        #expect(MeetingFolder.sanitized("Closing L'Étoile & Fils") == "Closing L'Étoile & Fils")
        #expect(MeetingFolder.sanitized("Réunion « à chaud » — n°3") == "Réunion « à chaud » — n°3")
    }

    @Test("Un titre trop long est tronqué sans laisser d'espace en fin")
    func titreTronqueSansEspaceFinale() {
        // La coupe tombe pile après une espace : la rendre telle quelle donnerait
        // un nom qui se termine par un blanc, invisible et impossible à retaper.
        let coupeSurUneEspace = String(repeating: "a", count: 59) + " " + String(repeating: "b", count: 10)
        let tronque = MeetingFolder.sanitized(coupeSurUneEspace)
        #expect(tronque == String(repeating: "a", count: 59))
        #expect(tronque?.hasSuffix(" ") == false)

        // Un titre d'un seul tenant est ramené au plafond de lisibilité.
        #expect(MeetingFolder.sanitized(String(repeating: "z", count: 100))?.count == 60)

        // Un titre qui tient déjà n'est pas touché.
        let pileSoixante = String(repeating: "c", count: 60)
        #expect(MeetingFolder.sanitized(pileSoixante) == pileSoixante)
    }

    @Test("Un titre vide ou blanc rend nil, jamais une chaîne vide")
    func titreVideRendNil() {
        #expect(MeetingFolder.sanitized("") == nil)
        #expect(MeetingFolder.sanitized("   ") == nil)
        #expect(MeetingFolder.sanitized("\n\t") == nil)
        #expect(MeetingFolder.sanitized("///") == nil)
        #expect(MeetingFolder.sanitized(":::") == nil)
    }

    // MARK: - Les morceaux

    @Test("Le numéro de morceau est zéro-rempli sur trois chiffres")
    func numeroDeMorceauZeroRempli() {
        #expect(MeetingFolder.segmentName(base: "réunion", index: 0) == "réunion-seg000.mp4")
        #expect(MeetingFolder.segmentName(base: "réunion", index: 9) == "réunion-seg009.mp4")
        #expect(MeetingFolder.segmentName(base: "réunion", index: 10) == "réunion-seg010.mp4")
        #expect(MeetingFolder.segmentName(base: "réunion", index: 123) == "réunion-seg123.mp4")
    }

    @Test("Après dix pauses, l'ordre alphabétique des morceaux reste l'ordre d'écriture")
    func ordreDesMorceauxApresDixPauses() {
        // C'est exactement ce qu'un « %d » sans remplissage aurait cassé : « seg10 »
        // se serait glissé avant « seg9 », et la fusion aurait recollé la réunion
        // dans le désordre.
        let morceaux = (0...12).map { MeetingFolder.segmentName(base: "réunion", index: $0) }
        #expect(morceaux.sorted() == morceaux)
        #expect(MeetingFolder.segmentName(base: "r", index: 9) < MeetingFolder.segmentName(base: "r", index: 10))
    }

    @Test("Un morceau se reconnaît, un fichier final n'est jamais pris pour un morceau")
    func reconnaissanceDesMorceaux() {
        // Présenter trois morceaux comme trois réunions serait le défaut visible ;
        // effacer la vidéo finale en croyant nettoyer serait le défaut coûteux.
        #expect(MeetingFolder.isSegment("2026-08-11 09h57-seg000.mp4"))
        #expect(MeetingFolder.isSegment(MeetingFolder.segmentName(base: "réunion", index: 7)))

        #expect(MeetingFolder.isSegment("2026-08-11 09h57 — SA SERMATEC.mp4") == false)
        #expect(MeetingFolder.isSegment("2026-08-11 09h57 — SA SERMATEC.m4a") == false)
        #expect(MeetingFolder.isSegment(MeetingFolder.sidecarName) == false)

        // Un morceau dont l'extension n'est pas celle de la vidéo n'est pas un
        // morceau : l'audio du CRM porte le même tronc de nom.
        #expect(MeetingFolder.isSegment("réunion-seg000.m4a") == false)
    }
}
