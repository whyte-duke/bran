import Foundation
import Testing
@testable import BranCore

/// **Une entrée illisible est un mois d'historique perdu sans un message.**
///
/// C'est le seul risque de ce type qui soit irréparable : les lecteurs du dépôt
/// avalent l'échec de décodage par tolérance aux fichiers coupés, donc une ligne
/// qui ne se décode plus ne fait pas de bruit, elle disparaît. Les deux premiers
/// tests gèlent le contrat de format ; les autres vérifient que ce qu'on affiche
/// se déduit de ce qui est écrit, et non l'inverse.
@Suite("L'entrée de presse-papiers")
struct ClipboardEntryTests {

    private let origin = Date(timeIntervalSince1970: 1_786_000_000)

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }

    // MARK: - La leçon qui a déjà coûté trois allers-retours

    @Test("Une entrée écrite par une version antérieure reste lisible")
    func compatibiliteAscendante() throws {
        // Le `Decodable` synthétisé ignore les valeurs par défaut. Un champ non
        // optionnel ajouté à `ClipboardEntry` rendrait illisible, d'un coup,
        // chaque ligne déjà écrite. Ce test gèle le contrat : seuls id,
        // copiedAt, kind et preview sont exigés. Tout ajout futur qui casse ce
        // test casse l'historique de quelqu'un.
        let json = """
        {
          "id": "3F1A9C74-6E20-4D8B-9C11-7A5E4B02D9F0",
          "copiedAt": 1786000000,
          "kind": "text",
          "preview": "git rebase -i origin/main"
        }
        """

        let entry = try decoder.decode(ClipboardEntry.self, from: Data(json.utf8))

        #expect(entry.preview == "git rebase -i origin/main")
        #expect(entry.kind == .text)
        #expect(entry.recopiedAt == nil)
        #expect(entry.repeatCount == nil)
        #expect(entry.source == nil)
        #expect(entry.blobs == nil)
        #expect(entry.fileURLs == nil)
        #expect(entry.blobsPurgedAt == nil)

        // Et les dérivations tiennent debout sans aucun de ces champs.
        #expect(entry.lastCopiedAt == entry.copiedAt)
        #expect(entry.copyCount == 1)
        #expect(entry.itemCount == 1)
        #expect(entry.characterCount == 25)
        #expect(entry.isPreviewTruncated == false)
    }

    @Test("Une entrée écrite par une version postérieure reste lisible")
    func compatibiliteDescendante() throws {
        // L'autre sens du même problème : deux versions de bran peuvent lire la
        // même bibliothèque — un .app installé et un binaire de développement.
        // Une clé inconnue doit être ignorée, pas faire tomber la ligne.
        let json = """
        {
          "id": "3F1A9C74-6E20-4D8B-9C11-7A5E4B02D9F0",
          "copiedAt": 1786000000,
          "kind": "text",
          "preview": "swift test",
          "pinnedAt": 1786000900,
          "tags": ["build"]
        }
        """

        let entry = try decoder.decode(ClipboardEntry.self, from: Data(json.utf8))
        #expect(entry.preview == "swift test")
    }

    @Test("Un aller-retour d'encodage conserve tout")
    func allerRetour() throws {
        let entry = ClipboardEntry(
            copiedAt: origin,
            kind: .richText,
            preview: "Une citation mise en forme",
            recopiedAt: origin.addingTimeInterval(90),
            repeatCount: 2,
            source: ClipboardSource(bundleIdentifier: "com.google.Chrome", name: "Google Chrome"),
            plainText: "Une citation mise en forme",
            blobs: [ClipboardBlobRef(hash: "a1b2", ext: "rtf", bytes: 4_096)],
            fileURLs: nil,
            pasteboardItems: 1,
            fullTextLength: 26,
            refusedBytes: nil,
            blobsPurgedAt: origin.addingTimeInterval(2_592_000)
        )

        let round = try decoder.decode(ClipboardEntry.self, from: encoder.encode(entry))
        #expect(round == entry)
    }

    // MARK: - Compter les copies sans écrire le cas majoritaire

    @Test("Une entrée jamais recopiée n'écrit ni date ni compteur")
    func copieUnique() throws {
        // 207 entrées sur 250 sont dans ce cas sur l'historique mesuré. Les
        // deux champs valent `nil`, donc l'encodeur ne les écrit pas du tout,
        // et la lecture reste juste.
        let entry = ClipboardEntry(copiedAt: origin, kind: .text, text: "npm run dev")
        #expect(entry.copyCount == 1)
        #expect(entry.wasRecopied == false)
        #expect(entry.lastCopiedAt == origin)

        let json = String(decoding: try encoder.encode(entry), as: UTF8.self)
        #expect(json.contains("recopiedAt") == false)
        #expect(json.contains("repeatCount") == false)
    }

    @Test("Recopier fait monter le compteur sans déplacer la première copie")
    func recopie() {
        // `copiedAt` désigne le dossier-jour où la ligne est écrite : le
        // déplacer déplacerait la ligne, ou pire la laisserait dans un dossier
        // qui ne correspond plus à sa date.
        let once = ClipboardEntry(copiedAt: origin, kind: .text, text: "kill -9")
        let twice = once.recopied(at: origin.addingTimeInterval(300))
        let thrice = twice.recopied(at: origin.addingTimeInterval(900))

        #expect(twice.copyCount == 2)
        #expect(thrice.copyCount == 3)
        #expect(thrice.copiedAt == origin)
        #expect(thrice.lastCopiedAt == origin.addingTimeInterval(900))
        #expect(thrice.wasRecopied)
    }

    @Test("Une recopie antérieure ne fait pas reculer la dernière date")
    func recopieAnterieure() {
        // Une horloge qui recule — recalage réseau, sortie de veille — ne doit
        // pas faire redescendre une entrée dans la liste, qui trie sur cette
        // date. La rétention, elle, ne la lit pas : elle compte depuis
        // `copiedAt`, la date qui nomme le dossier.
        let entry = ClipboardEntry(copiedAt: origin, kind: .text, text: "x")
            .recopied(at: origin.addingTimeInterval(600))
            .recopied(at: origin.addingTimeInterval(-60))

        #expect(entry.copyCount == 3)
        #expect(entry.lastCopiedAt == origin.addingTimeInterval(600))
    }

    @Test("Le dossier d'une entrée est nommé par la première copie, jamais par la dernière")
    func dossierNommeParLaPremiereCopie() {
        // **La règle de nommage est ici, en code, et pas seulement en prose.**
        // C'est `copiedAt` qui décide de l'emplacement du blob sur le disque,
        // donc de sa durée de vie ; une recopie six jours plus tard ne déplace
        // pas un fichier déjà écrit, et ne doit donc pas changer la réponse.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let premier = Date(timeIntervalSince1970: 1_786_000_000)   // 2026-08-06 07:06:40 UTC

        let entry = ClipboardEntry(copiedAt: premier, kind: .text, text: "brew upgrade")
            .recopied(at: premier.addingTimeInterval(6 * 86_400))

        #expect(entry.dayFolderName(calendar: calendar) == "2026-08-06")
        #expect(entry.lastCopiedAt == premier.addingTimeInterval(6 * 86_400))
        #expect(
            entry.dayFolderName(calendar: calendar)
                == ClipboardRetention.dayKey(for: entry.copiedAt, calendar: calendar)
        )
    }

    // MARK: - Dériver l'aperçu

    @Test("Un texte au ras de la limite n'est pas rogné")
    func apercuALaLimite() {
        let text = String(repeating: "a", count: ClipboardEntry.previewLimit)
        let entry = ClipboardEntry(copiedAt: origin, kind: .text, text: text)

        #expect(entry.preview.count == 512)
        #expect(entry.characterCount == 512)
        #expect(entry.isPreviewTruncated == false)
    }

    @Test("Un caractère de plus et l'aperçu s'arrête à 512")
    func apercuRogne() {
        let text = String(repeating: "a", count: ClipboardEntry.previewLimit + 1)
        let entry = ClipboardEntry(copiedAt: origin, kind: .text, text: text)

        #expect(entry.preview.count == 512)
        #expect(entry.characterCount == 513)
        #expect(entry.isPreviewTruncated)
        // Aucune ellipse dans la donnée : c'est l'interface qui la pose.
        #expect(entry.preview.hasSuffix("…") == false)
    }

    @Test("L'aperçu ne coupe jamais un emoji en deux")
    func apercuEtGraphemes() {
        // Rogner en octets ou en scalaires produirait ici de l'UTF-8 invalide
        // au milieu d'un fichier JSON. `prefix` compte des grappes de
        // graphèmes, donc la famille part entière ou reste entière.
        let famille = "👨‍👩‍👧‍👦"
        #expect(famille.count == 1)

        let text = String(repeating: "a", count: ClipboardEntry.previewLimit) + famille
        let entry = ClipboardEntry(copiedAt: origin, kind: .text, text: text)

        #expect(entry.preview.count == 512)
        #expect(entry.preview.contains("👨") == false)
        #expect(entry.preview.unicodeScalars.count == 512)
        #expect(entry.isPreviewTruncated)
    }

    @Test("Les bords blancs disparaissent, l'indentation intérieure reste")
    func apercuRogneLesBords() {
        // Une copie de terminal se termine presque toujours par un saut de
        // ligne, et une ligne de panneau qui commence par du vide a l'air
        // cassée. L'indentation d'un bout de code, elle, est de l'information.
        let entry = ClipboardEntry(
            copiedAt: origin,
            kind: .text,
            text: "\n  func run() {\n      try body()\n  }\n\n"
        )

        #expect(entry.preview == "func run() {\n      try body()\n  }")
        #expect(entry.characterCount == entry.preview.count)
        #expect(entry.isPreviewTruncated == false)
    }

    @Test("La ligne compacte tient sur une ligne")
    func ligneCompacte() {
        let entry = ClipboardEntry(
            copiedAt: origin,
            kind: .text,
            text: "    git   commit -m\n  puis pousser"
        )

        #expect(entry.rowTitle == "git commit -m")
        // Le détail, lui, garde le texte tel quel.
        #expect(entry.preview.contains("\n"))
    }

    @Test("Une image n'a pas d'aperçu textuel, et n'en invente pas")
    func apercuDUneImage() {
        let entry = ClipboardEntry(
            copiedAt: origin,
            kind: .image,
            preview: "",
            blobs: [ClipboardBlobRef(hash: "ff00", ext: "png", bytes: 1_048_576)]
        )

        #expect(entry.preview.isEmpty)
        #expect(entry.rowTitle.isEmpty)
        #expect(entry.canPaste)
    }

    // MARK: - Les seuils

    @Test("512 Kio de texte tiennent en ligne, un octet de plus part en blob")
    func seuilDeMiseEnBlob() {
        let juste = String(repeating: "a", count: ClipboardEntry.inlineTextLimit)
        #expect(ClipboardEntry.fitsInline(juste))
        #expect(ClipboardEntry(copiedAt: origin, kind: .text, text: juste).isTextInline)

        let trop = juste + "a"
        #expect(ClipboardEntry.fitsInline(trop) == false)

        let entry = ClipboardEntry(
            copiedAt: origin,
            kind: .text,
            text: trop,
            blobs: [ClipboardBlobRef(hash: "c0de", ext: "txt", bytes: trop.utf8.count)]
        )
        // Rien n'est coupé : le texte n'est plus en ligne, il est ailleurs, et
        // l'aperçu dit combien il en manque.
        #expect(entry.isTextInline == false)
        #expect(entry.characterCount == ClipboardEntry.inlineTextLimit + 1)
        #expect(entry.isPreviewTruncated)
        #expect(entry.canPaste)
    }

    @Test("Le seuil se compte en octets UTF-8 et non en caractères")
    func seuilEnOctets() {
        // Un caractère hors ASCII pèse plusieurs octets : compter les
        // caractères laisserait passer trois fois la taille annoncée.
        let text = String(repeating: "é", count: ClipboardEntry.inlineTextLimit / 2)
        #expect(text.count < ClipboardEntry.inlineTextLimit)
        #expect(ClipboardEntry.fitsInline(text))
        #expect(ClipboardEntry.fitsInline(text + "é") == false)
    }

    @Test("32 Mio passent, un octet de plus est refusé")
    func seuilDeRefus() {
        #expect(ClipboardEntry.isTooLarge(bytes: ClipboardEntry.maximumBlobBytes) == false)
        #expect(ClipboardEntry.isTooLarge(bytes: ClipboardEntry.maximumBlobBytes + 1))
    }

    @Test("Un contenu refusé laisse une entrée qui dit son type et sa taille")
    func contenuRefuse() {
        let entry = ClipboardEntry(
            copiedAt: origin,
            kind: .image,
            preview: "",
            refusedBytes: 48 * 1024 * 1024
        )

        #expect(entry.isRefused)
        #expect(entry.canPaste == false)
        #expect(entry.blobs == nil)
        #expect(entry.kind == .image)
        #expect(entry.sizeDescription.hasSuffix("— non conservé"))
    }

    // MARK: - Vivre après la purge

    @Test("Un blob purgé laisse l'entrée vivante et bavarde")
    func blobPurge() {
        // Même parti pris que `SnippetEntry.canRetry` : un bouton désactivé
        // avec sa raison, jamais un bouton qui échoue. Et contrairement à
        // `SnippetEntry`, la référence est conservée — c'est elle qui permet
        // d'écrire *ce qui* a disparu plutôt que rien.
        let entry = ClipboardEntry(
            copiedAt: origin,
            kind: .image,
            preview: "",
            blobs: [ClipboardBlobRef(hash: "beef", ext: "png", bytes: 2_000_000)]
        )
        let purged = entry.purgingBlobs(at: origin.addingTimeInterval(2_592_000))

        #expect(purged.blobsArePurged)
        #expect(purged.canPaste == false)
        #expect(purged.blobs?.count == 1)
        #expect(purged.totalBlobBytes == 2_000_000)
        #expect(purged.blobs?.first?.fileName == "beef.png")
        // Tout le reste de l'entrée est intact.
        #expect(purged.id == entry.id)
        #expect(purged.copiedAt == entry.copiedAt)
        #expect(purged.kind == entry.kind)
    }

    @Test("Un texte en ligne survit à la purge de son blob")
    func texteEnLigneSurvitALaPurge() {
        // Le cas d'un `richText` : le RTF part au bout de trente jours, le texte
        // brut reste pour toujours. « Coller sans mise en forme » marche encore.
        let entry = ClipboardEntry(
            copiedAt: origin,
            kind: .richText,
            preview: "Un titre en gras",
            plainText: "Un titre en gras",
            blobs: [ClipboardBlobRef(hash: "1234", ext: "rtf", bytes: 8_192)]
        ).purgingBlobs(at: origin)

        #expect(entry.plainText == "Un titre en gras")
        #expect(entry.blobsArePurged)
        // Coller reste possible — le texte brut est dans l'index, que la
        // rétention ne touche jamais. Ce qui est perdu, c'est la mise en forme,
        // et c'est `isComplete` qui autorise l'interface à le dire.
        #expect(entry.canPaste)
        #expect(entry.isComplete == false)
    }

    // MARK: - Plusieurs éléments, une seule entrée

    @Test("Une sélection multiple du Finder est une entrée et non N")
    func selectionMultiple() {
        // Mesuré : un `writeObjects` de N éléments n'incrémente le compteur de
        // changement qu'une fois. Le système considère ça comme une copie ; en
        // faire N lignes inventerait des événements qui n'ont pas eu lieu.
        let entry = ClipboardEntry(
            copiedAt: origin,
            kind: .file,
            preview: "rapport.pdf",
            fileURLs: [
                "/Users/x/Documents/rapport.pdf",
                "/Users/x/Documents/annexe.pdf",
                "/Users/x/Documents/notes.md",
            ]
        )

        #expect(entry.itemCount == 3)
        #expect(entry.isMultipleItems)
        #expect(entry.canPaste)
    }

    @Test("Un richText à deux blobs reste un seul élément")
    func deuxBlobsUnSeulElement() {
        // C'est pour ce cas précis que le nombre d'éléments est stocké et non
        // déduit de `blobs.count` : compter les blobs annoncerait « 2 éléments »
        // pour un bout de texte copié depuis une page web.
        let entry = ClipboardEntry(
            copiedAt: origin,
            kind: .richText,
            preview: "Un paragraphe",
            plainText: "Un paragraphe",
            blobs: [
                ClipboardBlobRef(hash: "aa", ext: "rtf", bytes: 1_024),
                ClipboardBlobRef(hash: "bb", ext: "html", bytes: 2_048),
            ]
        )

        #expect(entry.itemCount == 1)
        #expect(entry.isMultipleItems == false)
        #expect(entry.totalBlobBytes == 3_072)
    }

    // MARK: - Ce que le pied de ligne annonce

    @Test("Un texte annonce ses caractères, pas ses octets")
    func tailleDUnTexte() {
        let entry = ClipboardEntry(copiedAt: origin, kind: .text, text: "bonjour")
        #expect(entry.sizeDescription == "7 caractères")
    }

    @Test("Une source vide se tait plutôt que d'écrire « Inconnu »")
    func sourceInconnue() {
        let entry = ClipboardEntry(
            copiedAt: origin,
            kind: .text,
            text: "x",
            source: ClipboardSource(bundleIdentifier: nil, name: nil)
        )
        #expect(entry.source?.isUnknown == true)
    }
}
