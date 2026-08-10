import Foundation
import Testing

@testable import BranCore

/// **Ce que la capture rate ne se voit qu'au collage, des semaines plus tard.**
///
/// C'est la seule pièce de l'historique qui traduit : la machine décide, le
/// magasin écrit, et entre les deux cette couche transforme des octets en entrée.
/// Ses défauts sont tous de la même famille — une entrée qui a l'air normale dans
/// la liste et qui ne rend pas ce qu'on avait copié. Un texte rangé sans son blob,
/// un RTF dont l'aperçu est vide alors que le presse-papiers portait le texte
/// brut, une sélection de douze fichiers réduite à un, un UTF-16 lu en UTF-8 : les
/// quatre s'écrivent sans un message, et se découvrent au pire moment.
///
/// Tout se teste ici sans presse-papiers, sans AppKit et sans disque : la lecture
/// est un dictionnaire, l'heure est un paramètre.
@Suite("La traduction des octets du presse-papiers")
struct ClipboardCaptureTests {

    // MARK: - Outillage

    private let text = "public.utf8-plain-text"
    private let utf16Text = "public.utf16-external-plain-text"
    private let plainText = "public.plain-text"
    private let rtf = "public.rtf"
    private let rtfd = "com.apple.flat-rtfd"
    private let html = "public.html"
    private let png = "public.png"
    private let tiff = "public.tiff"
    private let fileURL = "public.file-url"
    private let legacyFilenames = "NSFilenamesPboardType"

    /// Le 10 août 2026 à midi, comme dans `ClipboardStoreTests` — midi et non
    /// minuit, une date de bord tomberait dans un autre jour selon le fuseau.
    private static var noon: Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: DateComponents(year: 2026, month: 8, day: 10, hour: 12))!
    }

    private let chrome = ClipboardSource(bundleIdentifier: "com.google.Chrome", name: "Google Chrome")

    private func plan(
        _ kind: ClipboardKind,
        _ primary: String,
        companions: [String] = [],
        items: Int = 1,
        changeCount: Int = 11
    ) -> ClipboardCapturePlan {
        ClipboardCapturePlan(
            kind: kind,
            changeCount: changeCount,
            primaryType: primary,
            companionTypes: companions,
            itemCount: items
        )
    }

    private func reading(
        _ items: [[String: Data]],
        flattened: String? = nil,
        changeCount: Int = 11
    ) -> ClipboardReading {
        ClipboardReading(changeCount: changeCount, items: items, flattenedText: flattened)
    }

    private func bytes(_ body: String) -> Data { Data(body.utf8) }

    private func make(
        _ plan: ClipboardCapturePlan,
        _ reading: ClipboardReading,
        source: ClipboardSource? = nil
    ) -> ClipboardCaptureResult? {
        ClipboardCapture.make(for: plan, reading: reading, source: source, copiedAt: Self.noon)
    }

    // MARK: - Texte brut

    @Test("Un texte court tient en ligne, sans un seul fichier à côté")
    func texteEnLigne() throws {
        let result = try #require(
            make(plan(.text, text), reading([[text: bytes("Bonjour")]]), source: chrome)
        )

        #expect(result.entry.kind == .text)
        #expect(result.entry.preview == "Bonjour")
        #expect(result.entry.plainText == "Bonjour")
        #expect(result.entry.isTextInline)
        #expect(result.entry.fullTextLength == 7)
        #expect(result.entry.source?.name == "Google Chrome")
        #expect(result.entry.copiedAt == Self.noon)
        #expect(result.payloads.isEmpty)
        #expect(result.entry.blobs == nil, "un tableau vide serait un champ de plus sur chaque ligne")
        #expect(result.entry.canPaste)
    }

    /// L'aperçu, la longueur et le rognage des bords appartiennent à
    /// `ClipboardEntry` ; ce test garde qu'on les lui laisse au lieu d'en refaire
    /// une version voisine ici.
    @Test("L'aperçu et la longueur sont ceux que l'entrée dérive, pas une seconde version")
    func apercuDelegue() throws {
        let body = "  du texte copié depuis un terminal\n"
        let result = try #require(make(plan(.text, text), reading([[text: bytes(body)]])))

        #expect(result.entry.preview == ClipboardEntry.preview(for: body))
        #expect(result.entry.preview == "du texte copié depuis un terminal")
        #expect(result.entry.fullTextLength == ClipboardEntry.normalized(body).count)
        // Le texte conservé, lui, n'est pas rogné : c'est l'aperçu qui l'est.
        #expect(result.entry.plainText == body)
    }

    @Test("L'UTF-16 du presse-papiers est lu comme de l'UTF-16, pas comme de l'UTF-8")
    func decodageUTF16() throws {
        let data = try #require("Bonjour ✂︎ 世界".data(using: .utf16))
        let result = try #require(make(plan(.text, utf16Text), reading([[utf16Text: data]])))

        #expect(result.entry.plainText == "Bonjour ✂︎ 世界")
        // Et le type compte vraiment : lus en UTF-8, ces mêmes octets ne donnent
        // pas la chaîne d'origine — c'est exactement le défaut qu'on empêche.
        #expect(ClipboardCapture.decodeText(data, as: "public.utf8-plain-text") != "Bonjour ✂︎ 世界")
    }

    @Test("Un UTF-16 sans nomenclature reste lisible : la représentation externe est gros-boutiste")
    func decodageUTF16SansNomenclature() throws {
        let data = try #require("Bonjour".data(using: .utf16BigEndian))
        #expect(ClipboardCapture.decodeText(data, as: utf16Text) == "Bonjour")
    }

    /// **Le test qui garde la promesse la plus chère de la fonctionnalité :** ce
    /// que l'utilisateur a copié n'est jamais coupé, seulement rangé ailleurs.
    /// Sans le blob produit ici, l'entrée naîtrait avec un aperçu de 512
    /// caractères et rien derrière.
    @Test("Un texte au-delà du seuil part en fichier, et l'entrée le cite")
    func texteAuDelaDuSeuil() throws {
        let long = String(repeating: "a", count: ClipboardEntry.inlineTextLimit + 1)
        let result = try #require(make(plan(.text, text), reading([[text: bytes(long)]])))

        #expect(result.entry.plainText == nil)
        #expect(result.entry.isTextInline == false)
        #expect(result.entry.preview.count == ClipboardEntry.previewLimit)
        #expect(result.entry.characterCount == ClipboardEntry.inlineTextLimit + 1)
        #expect(result.entry.isPreviewTruncated)

        #expect(result.payloads.count == 1)
        let payload = try #require(result.payloads.first)
        #expect(payload.ext == "txt")
        #expect(payload.data == Data(long.utf8))
        #expect(result.entry.blobs == [payload.ref], "sinon l'entrée naît avec son texte perdu")
        #expect(result.entry.canPaste)
    }

    @Test("Un texte exactement au seuil tient encore en ligne")
    func texteExactementAuSeuil() throws {
        let borderline = String(repeating: "a", count: ClipboardEntry.inlineTextLimit)
        let result = try #require(make(plan(.text, text), reading([[text: bytes(borderline)]])))

        #expect(result.entry.plainText == borderline)
        #expect(result.payloads.isEmpty)
    }

    // MARK: - Texte enrichi

    @Test("Un texte enrichi range sa forme en fichier et garde son texte brut en ligne")
    func texteEnrichiAvecCompagnon() throws {
        let result = try #require(
            make(
                plan(.richText, rtf, companions: [text]),
                reading([[rtf: bytes("{\\rtf1 Bonjour}"), text: bytes("Bonjour")]])
            )
        )

        #expect(result.entry.kind == .richText)
        #expect(result.entry.preview == "Bonjour")
        // En ligne : « coller sans mise en forme » ne doit rien coûter, et doit
        // survivre à la purge du blob. C'est ce que `canPaste` teste avant
        // `blobsArePurged`.
        #expect(result.entry.plainText == "Bonjour")
        #expect(result.entry.fullTextLength == 7)

        #expect(result.payloads.count == 1)
        #expect(result.payloads.first?.ext == "rtf")
        #expect(result.payloads.first?.data == bytes("{\\rtf1 Bonjour}"))
        #expect(result.entry.blobs?.count == 1)
        #expect(result.entry.purgedStillPastes)
    }

    @Test("Sans compagnon ni aplatissement, l'aperçu reste vide plutôt qu'inventé")
    func texteEnrichiSansCompagnon() throws {
        let result = try #require(
            make(plan(.richText, html), reading([[html: bytes("<p>Bonjour</p>")]]))
        )

        #expect(result.entry.kind == .richText)
        #expect(result.entry.preview.isEmpty)
        // `nil` et non `""` : la chaîne vide rendrait `isTextInline` vrai pour une
        // entrée qui n'a aucun texte à coller.
        #expect(result.entry.plainText == nil)
        #expect(result.entry.isTextInline == false)
        #expect(result.entry.fullTextLength == nil)
        #expect(result.payloads.count == 1)
        #expect(result.payloads.first?.ext == "html")
        // Il reste quelque chose à coller : le blob.
        #expect(result.entry.canPaste)
    }

    @Test("L'aplatissement de l'appelant sert d'aperçu quand le presse-papiers n'a pas de texte brut")
    func texteEnrichiAplatiParLAppelant() throws {
        // Aplatir du RTF exige AppKit, donc ça ne peut pas se faire dans BranCore.
        // Quand l'appelant a su le faire, ça ne doit pas être jeté.
        let result = try #require(
            make(
                plan(.richText, rtfd),
                reading([[rtfd: bytes("RTFD")]], flattened: "Le compte rendu")
            )
        )

        #expect(result.entry.preview == "Le compte rendu")
        #expect(result.entry.plainText == "Le compte rendu")
        #expect(result.payloads.first?.ext == "rtfd")
    }

    @Test("Le compagnon de l'application l'emporte sur l'aplatissement de l'appelant")
    func compagnonPrefereALAplatissement() throws {
        let result = try #require(
            make(
                plan(.richText, rtf, companions: [plainText]),
                reading([[rtf: bytes("RTF"), plainText: bytes("celui de l'application")]],
                        flattened: "celui de la conversion")
            )
        )
        #expect(result.entry.plainText == "celui de l'application")
    }

    /// **Le cas Excel**, tel que `ClipboardTypePolicy` le décrit : une plage de
    /// cellules arrive en HTML + texte + TIFF, le bitmap est un *rendu* du
    /// tableau. Deux blobs, et l'ordre compte — le contenu d'abord.
    @Test("Un texte enrichi avec son rendu matriciel écrit deux fichiers, la forme d'abord")
    func texteEnrichiAvecRenduMatriciel() throws {
        let result = try #require(
            make(
                plan(.richText, html, companions: [text, tiff]),
                reading([[
                    html: bytes("<table>…</table>"),
                    text: bytes("A1\tB1"),
                    tiff: bytes("TIFF"),
                ]])
            )
        )

        // Des variables locales plutôt que `map(\.ext)` dans `#expect` : le
        // développement de la macro passe le chemin de clé à une fonction
        // `rethrows`, et le compilateur en conclut que l'appel peut lancer.
        let extensions = result.payloads.map { $0.ext }
        let cited = (result.entry.blobs ?? []).map { $0.ext }
        #expect(result.payloads.count == 2)
        #expect(extensions == ["html", "tiff"])
        #expect(cited == ["html", "tiff"])
        #expect(result.entry.plainText == "A1\tB1")
        #expect(result.entry.preview == "A1\tB1")
        #expect(result.entry.pasteboardItems == nil, "un seul élément, N représentations")
        #expect(result.entry.itemCount == 1)
    }

    @Test("Un texte brut enrichi qui déborde le seuil part aussi en fichier")
    func compagnonTexteAuDelaDuSeuil() throws {
        let long = String(repeating: "b", count: ClipboardEntry.inlineTextLimit + 1)
        let result = try #require(
            make(
                plan(.richText, rtf, companions: [text, png]),
                reading([[rtf: bytes("RTF"), text: bytes(long), png: bytes("PNG")]])
            )
        )

        #expect(result.entry.plainText == nil, "il ne tient pas en ligne")
        #expect(result.entry.preview.count == ClipboardEntry.previewLimit)
        let extensions = result.payloads.map { $0.ext }
        #expect(extensions == ["rtf", "txt", "png"])
        #expect(result.entry.blobs?.count == 3)
    }

    /// Un compagnon est une autre vue du **même** objet. Le prendre chez le voisin
    /// collerait le nom d'un fichier sous une citation copiée du web.
    @Test("Les compagnons se prennent sur l'élément qui a décidé, pas chez le voisin")
    func compagnonsDuSeulElementDecideur() throws {
        let result = try #require(
            make(
                plan(.richText, rtf, companions: [text]),
                reading([
                    [text: bytes("le texte d'un autre objet")],
                    [rtf: bytes("RTF")],
                ])
            )
        )

        #expect(result.entry.preview.isEmpty)
        #expect(result.entry.plainText == nil)
        #expect(result.payloads.count == 1)
    }

    @Test("Une forme enrichie vide ne fait pas perdre le texte brut qui l'accompagnait")
    func formeEnrichieVide() throws {
        let result = try #require(
            make(
                plan(.richText, rtf, companions: [text]),
                reading([[rtf: Data(), text: bytes("Bonjour")]])
            )
        )

        // Zéro octet n'est pas un contenu : écrire ce blob donnerait une entrée
        // qui promet un fichier et n'en a pas.
        #expect(result.payloads.isEmpty)
        #expect(result.entry.blobs == nil)
        #expect(result.entry.plainText == "Bonjour")
        #expect(result.entry.canPaste)
    }

    // MARK: - Image

    @Test("Une image est toujours un fichier, et n'a rien à dire en texte")
    func image() throws {
        let result = try #require(
            make(plan(.image, png), reading([[png: bytes("PNG")]]), source: chrome)
        )

        #expect(result.entry.kind == .image)
        #expect(result.entry.preview.isEmpty, "« (image) » serait une chaîne d'interface dans une donnée")
        #expect(result.entry.plainText == nil)
        #expect(result.entry.fullTextLength == nil)
        #expect(result.payloads.count == 1)
        #expect(result.payloads.first?.ext == "png")
        #expect(result.entry.blobs == [result.payloads[0].ref])
        #expect(result.entry.totalBlobBytes == 3)
        #expect(result.entry.canPaste)
    }

    @Test("Le nom de fichier posé à côté d'une capture ne devient pas son aperçu")
    func imageAvecDuTexteACote() throws {
        // Le plan a déjà tranché : c'est une image, et une image n'a pas de
        // compagnon. Le texte présent sur l'élément ne doit pas remonter.
        let result = try #require(
            make(plan(.image, png), reading([[png: bytes("PNG"), text: bytes("Capture 3.png")]]))
        )
        #expect(result.entry.preview.isEmpty)
        #expect(result.entry.plainText == nil)
        #expect(result.payloads.count == 1)
    }

    @Test("Chaque format matriciel reçoit l'extension qui le rend ouvrable par Quick Look")
    func extensionsDesImages() {
        let attendu = [
            "public.png": "png",
            "public.tiff": "tiff",
            "public.jpeg": "jpeg",
            "public.heic": "heic",
            "public.heif": "heif",
            "com.compuserve.gif": "gif",
            "com.microsoft.bmp": "bmp",
        ]
        for (type, ext) in attendu {
            #expect(ClipboardCapture.fileExtension(for: type) == ext)
        }

        // Toute la table des types de la politique sait se nommer : le défaut
        // `dat` ne doit être atteignable que par un type qu'on aurait ajouté d'un
        // seul côté.
        for kind in ClipboardKind.allCases where kind != .file {
            for type in ClipboardTypePolicy.identifiers(for: kind) {
                #expect(
                    ClipboardCapture.fileExtension(for: type) != "dat",
                    "\(type) n'a pas d'extension dans ClipboardCapture.blobExtensions"
                )
            }
        }
        #expect(ClipboardCapture.fileExtension(for: "com.acme.inconnu") == "dat")
    }

    // MARK: - Fichiers

    @Test("Une copie de plusieurs fichiers garde tous les chemins, et aucun contenu")
    func plusieursFichiers() throws {
        let result = try #require(
            make(
                plan(.file, fileURL, items: 3),
                reading([
                    [fileURL: bytes("file:///Users/x/un.txt")],
                    [fileURL: bytes("file:///Users/x/deux.txt")],
                    [fileURL: bytes("file:///Users/x/trois.txt"), text: bytes("un.txt")],
                ])
            )
        )

        #expect(result.entry.kind == .file)
        #expect(result.entry.fileURLs?.count == 3)
        #expect(result.entry.fileURLs?.first == "file:///Users/x/un.txt")
        // `pasteboardItems` n'est **pas** écrit : le compte d'une entrée de
        // fichiers est celui des chemins réellement décodés, et
        // `ClipboardEntry.itemCount` y retombe. Écrire le chiffre du plan à côté
        // ferait deux vérités, dont une qui ment dès qu'une `public.file-url`
        // s'est révélée illisible — voir `fichierIllisibleNeGonflePasLeCompte`.
        #expect(result.entry.pasteboardItems == nil)
        #expect(result.entry.itemCount == 3)
        #expect(result.entry.isMultipleItems)
        // Le contenu d'un fichier n'est jamais repris : ce serait faire d'un
        // glisser de dossier de 4 Go une entrée d'historique.
        #expect(result.payloads.isEmpty)
        #expect(result.entry.blobs == nil)
        #expect(result.entry.preview.isEmpty)
        #expect(result.entry.canPaste)
    }

    @Test("Un seul fichier n'écrit pas de compteur d'éléments : l'absence dit déjà un")
    func unSeulFichier() throws {
        let result = try #require(
            make(plan(.file, fileURL), reading([[fileURL: bytes("file:///Users/x/seul.txt")]]))
        )
        #expect(result.entry.pasteboardItems == nil)
        #expect(result.entry.itemCount == 1)
        #expect(result.entry.isMultipleItems == false)
    }

    /// `NSFilenamesPboardType` porte un plist contenant un **tableau** de chemins
    /// dans un seul élément. Le décoder en chaîne donnerait une `fileURLs`
    /// contenant du XML : absurde à l'œil, mais écrit sans un mot.
    @Test("L'identifiant hérité porte un plist de chemins, pas une URL")
    func fichiersHerites() throws {
        let paths = ["/Users/x/un.txt", "/Users/x/deux.txt"]
        let data = try PropertyListSerialization.data(
            fromPropertyList: paths, format: .xml, options: 0
        )
        let result = try #require(make(plan(.file, legacyFilenames), reading([[legacyFilenames: data]])))

        #expect(result.entry.fileURLs == paths)
        // Le plan n'a vu qu'un élément, mais la copie en compte deux. Ne rien
        // écrire laisse `itemCount` retomber sur le vrai chiffre.
        #expect(result.entry.pasteboardItems == nil)
        #expect(result.entry.itemCount == 2)
    }

    @Test("Un chemin terminé par un octet nul reste retrouvable")
    func cheminTermineParNul() throws {
        // Certains écrivains posent une chaîne C terminée. Le `\0` final rend le
        // chemin introuvable pour `FileManager` alors que l'affichage, lui, a
        // l'air parfaitement normal.
        var data = bytes("file:///Users/x/un.txt")
        data.append(0x00)
        let result = try #require(make(plan(.file, fileURL), reading([[fileURL: data]])))
        #expect(result.entry.fileURLs == ["file:///Users/x/un.txt"])
    }

    // MARK: - Quand il n'y a rien à ranger

    @Test("Rien de décodable ne fabrique pas une entrée vide, pour aucune des quatre sortes")
    func rienDeDecodable() {
        // Le type promis est absent de la lecture — l'appelant a demandé, macOS
        // n'a rien rendu.
        #expect(make(plan(.text, text), reading([[:]])) == nil)
        #expect(make(plan(.image, png), reading([[:]])) == nil)
        #expect(make(plan(.file, fileURL), reading([[:]])) == nil)
        #expect(make(plan(.richText, rtf), reading([[:]])) == nil)

        // Présent, mais vide : ce qu'une application publie entre son
        // `clearContents()` et son `setData`.
        #expect(make(plan(.text, text), reading([[text: Data()]])) == nil)
        #expect(make(plan(.image, png), reading([[png: Data()]])) == nil)
        #expect(make(plan(.file, fileURL), reading([[fileURL: Data()]])) == nil)
        #expect(make(plan(.richText, rtf, companions: [text]),
                     reading([[rtf: Data(), text: Data()]])) == nil)

        // Aucun élément du tout.
        #expect(make(plan(.text, text), reading([])) == nil)
    }

    /// **Le décodage est strict, et son échec est franc.** Réparer en UTF-8
    /// permissif rendrait une entrée dont le texte n'est plus celui qui a été
    /// copié ; réessayer en UTF-16 réussirait presque toujours, en produisant des
    /// idéogrammes au hasard. Les deux ont l'air d'un succès, ce qui est pire que
    /// l'échec.
    @Test("Des octets qui ne sont pas de l'UTF-8 ne deviennent pas du faux texte")
    func decodageInvalide() {
        let invalid = Data([0xFF, 0xFE, 0xFF, 0x41])
        #expect(ClipboardCapture.decodeText(invalid, as: text) == nil)
        #expect(make(plan(.text, text), reading([[text: invalid]])) == nil)

        // Mais l'appelant qui avait obtenu la chaîne autrement ne perd rien : le
        // repli légitime est une autre représentation, pas une réparation.
        let sauve = make(plan(.text, text), reading([[text: invalid]], flattened: "Bonjour"))
        #expect(sauve?.entry.plainText == "Bonjour")
    }

    @Test("Un texte enrichi illisible en texte brut garde quand même sa forme")
    func compagnonIllisibleNeFaitPasPerdreLEntree() throws {
        let result = try #require(
            make(
                plan(.richText, rtf, companions: [text]),
                reading([[rtf: bytes("RTF"), text: Data([0xFF, 0xFF])]])
            )
        )
        #expect(result.entry.preview.isEmpty)
        #expect(result.payloads.count == 1)
        #expect(result.entry.canPaste, "la forme enrichie, elle, est intacte")
    }

    // MARK: - La fraîcheur, qui n'est pas l'affaire de la capture

    @Test("Le compteur se compare, il ne se juge pas ici")
    func fraicheurALAppelant() throws {
        let intention = plan(.text, text, changeCount: 11)
        #expect(reading([[text: bytes("A")]], changeCount: 11).matches(intention))
        #expect(reading([[text: bytes("A")]], changeCount: 12).matches(intention) == false)

        // Et un contenu périmé reste traduit : « illisible » et « trop tard » sont
        // deux verdicts distincts, que les fondre dans un même `nil` rendrait
        // indistinguables. C'est à l'appelant de trancher avant d'appeler.
        #expect(make(intention, reading([[text: bytes("A")]], changeCount: 99)) != nil)
    }

    // MARK: - De bout en bout, depuis un vrai relevé

    /// Ce test relie les trois étages : un relevé de types comme
    /// `ClipboardMachine` en reçoit, le plan que `ClipboardTypePolicy` en tire, et
    /// l'entrée que la capture en fait. Il attrape la classe de défaut qu'aucun
    /// des trois ne peut voir seul — un plan dont la capture ignore un compagnon,
    /// un type que la politique retient et que la table d'extensions ne connaît
    /// pas.
    @Test("Une copie de page web traverse les trois étages sans rien perdre")
    func deBoutEnBout() throws {
        let policy = ClipboardTypePolicy()
        let sample = ClipboardSample(
            changeCount: 42,
            items: [[html, rtf, text, "org.chromium.internal.source-rfh-token"]]
        )
        let capturePlan = try #require(policy.plan(for: sample))
        #expect(capturePlan.kind == .richText)
        #expect(capturePlan.primaryType == rtf)

        // L'appelant ne lit que `plan.types` : le jeton de Chrome n'est jamais lu,
        // donc jamais rangé.
        let read = reading(
            [[rtf: bytes("{\\rtf1 Une citation}"), text: bytes("Une citation")]],
            changeCount: 42
        )
        #expect(read.matches(capturePlan))

        let result = try #require(make(capturePlan, read, source: chrome))
        #expect(result.entry.kind == .richText)
        let cited = (result.entry.blobs ?? []).map { $0.ext }
        #expect(result.entry.plainText == "Une citation")
        #expect(cited == ["rtf"])
        #expect(result.entry.source?.bundleIdentifier == "com.google.Chrome")
        #expect(result.entry.dayFolderName() == ClipboardRetention.dayKey(for: Self.noon))
    }

    @Test("Une sélection multiple du Finder traverse les trois étages")
    func deBoutEnBoutFichiers() throws {
        let policy = ClipboardTypePolicy()
        let sample = ClipboardSample(
            changeCount: 7,
            items: [[fileURL, text], [fileURL], [fileURL]]
        )
        let capturePlan = try #require(policy.plan(for: sample))
        #expect(capturePlan.kind == .file)
        #expect(capturePlan.itemCount == 3)

        let result = try #require(
            make(
                capturePlan,
                reading(
                    [
                        [fileURL: bytes("file:///a"), text: bytes("a")],
                        [fileURL: bytes("file:///b")],
                        [fileURL: bytes("file:///c")],
                    ],
                    changeCount: 7
                )
            )
        )
        #expect(result.entry.fileURLs == ["file:///a", "file:///b", "file:///c"])
        #expect(result.entry.itemCount == 3)
        #expect(result.payloads.isEmpty)
    }

    // MARK: - Ce que la capture laisse au magasin

    /// Le refus de taille est global à l'entrée et il appartient au magasin :
    /// écrire le RTF d'un `richText` et refuser son HTML produirait une entrée à
    /// moitié vraie. Deux endroits qui appliquent la même règle sont deux endroits
    /// qui peuvent diverger.
    @Test("Un contenu énorme n'est pas filtré ici : le refus est l'affaire du magasin")
    func refusLaisseAuMagasin() throws {
        let enorme = Data(count: ClipboardEntry.maximumBlobBytes + 1)
        let result = try #require(make(plan(.image, png), reading([[png: enorme]])))

        #expect(result.payloads.count == 1)
        #expect(result.entry.refusedBytes == nil)
        #expect(result.entry.isRefused == false)
        #expect(ClipboardEntry.isTooLarge(bytes: result.payloads[0].data.count))
    }

    @Test("Les références posées ici sont exactement celles que le magasin recalculera")
    func referencesCoherentes() throws {
        let result = try #require(
            make(
                plan(.richText, html, companions: [text, tiff]),
                reading([[html: bytes("<b>x</b>"), text: bytes("x"), tiff: bytes("TIFF")]])
            )
        )

        let refs = result.payloads.map { $0.ref }
        let total = result.payloads.reduce(0) { $0 + $1.data.count }
        #expect(result.entry.blobs == refs)
        // Une fermeture et non `\.propriété` : le développement de `#expect` passe
        // le chemin de clé à `allSatisfy`, qui est `rethrows`, et le compilateur
        // en conclut que l'appel peut lancer.
        #expect(result.payloads.allSatisfy { $0.hash.count == 64 })
        #expect(result.entry.totalBlobBytes == total)
    }

    // MARK: - Ce qu'une revue a trouvé, et que ces tests gèlent

    /// **Une entrée ne doit jamais annoncer plus qu'elle ne porte.** Le compte
    /// venait du plan, c'est-à-dire de ce que le presse-papiers *déclarait* ;
    /// une seule `public.file-url` illisible sur trois donnait une entrée
    /// annonçant trois fichiers et n'en portant que deux, sans que rien ne
    /// puisse le rattraper en aval.
    @Test("Un chemin illisible ne gonfle pas le compte de fichiers")
    func fichierIllisibleNeGonflePasLeCompte() throws {
        let result = try #require(
            make(
                plan(.file, fileURL, items: 3),
                reading([
                    [fileURL: bytes("file:///Users/x/un.txt")],
                    [fileURL: Data()],                       // déclarée, vide
                    [fileURL: bytes("file:///Users/x/trois.txt")],
                ])
            )
        )

        #expect(result.entry.fileURLs?.count == 2)
        #expect(result.entry.itemCount == 2, "l'entrée annonce ce qu'elle porte")
    }

    /// Le même défaut sur les images, en pire : le contenu manquant n'était pas
    /// seulement mal compté, il n'était pas gardé du tout. Deux images copiées
    /// donnaient un seul blob et un compte de deux.
    @Test("Deux images copiées donnent deux contenus, pas un")
    func deuxImagesDonnentDeuxContenus() throws {
        let result = try #require(
            make(
                plan(.image, png, items: 2),
                reading([[png: bytes("la première")], [png: bytes("la seconde")]])
            )
        )

        #expect(result.payloads.count == 2)
        #expect(result.entry.blobs?.count == 2)
        #expect(result.entry.itemCount == 2)
        // Et les deux contenus sont bien distincts, pas le même deux fois.
        #expect(Set(result.payloads.map(\.hash)).count == 2)
    }

    /// Le contenu est adressé par son empreinte : deux fois la même image ne
    /// doit écrire qu'un fichier, et l'entrée ne doit pas prétendre en porter
    /// deux.
    @Test("La même image deux fois ne compte qu'une")
    func memeImageDeuxFois() throws {
        let result = try #require(
            make(
                plan(.image, png, items: 2),
                reading([[png: bytes("la même")], [png: bytes("la même")]])
            )
        )

        #expect(result.payloads.count == 1)
        #expect(result.entry.blobs?.count == 1)
        #expect(result.entry.itemCount == 1)
    }

    /// **Un nom de fichier peut légalement finir par une espace.** Le rognage
    /// d'origine emportait blancs et sauts de ligne, donc rangeait un fichier
    /// réellement nommé « brouillon  » sous « brouillon » — un chemin qui ne
    /// désigne rien, et une entrée morte à la naissance. Seul le NUL, qui ne
    /// peut apparaître dans aucun chemin, est rogné.
    @Test("Une espace finale appartient au nom du fichier, et n'est pas rognée")
    func espaceFinaleFaitPartieDuNom() throws {
        let brut = "/Users/x/brouillon "
        let plist = try PropertyListSerialization.data(
            fromPropertyList: [brut], format: .xml, options: 0
        )
        let result = try #require(
            make(
                plan(.file, ClipboardCapture.legacyFilenamesType),
                reading([[ClipboardCapture.legacyFilenamesType: plist]])
            )
        )

        #expect(result.entry.fileURLs == [brut])
    }

    /// Le NUL, lui, est bien retiré : c'est le terminateur de chaîne du noyau,
    /// et un chemin qui le porte est introuvable sans que rien ne le dise.
    @Test("Un NUL final est retiré, lui")
    func nulFinalEstRetire() throws {
        let result = try #require(
            make(
                plan(.file, fileURL),
                reading([[fileURL: bytes("file:///Users/x/un.txt\0")]])
            )
        )

        #expect(result.entry.fileURLs == ["file:///Users/x/un.txt"])
    }

}

// MARK: - Confort de lecture

private extension ClipboardEntry {
    /// Restera-t-il de quoi coller après la purge des contenus lourds ?
    ///
    /// Existe pour que le test du texte enrichi dise ce qu'il garde vraiment : le
    /// texte brut vit dans l'index, que la rétention ne touche jamais, donc un
    /// `richText` dont le RTF est parti reste collable en texte brut. C'est
    /// l'ordre des branches de `canPaste`, et il ne vaut que si la capture pose le
    /// texte en ligne.
    var purgedStillPastes: Bool {
        purgingBlobs(at: .distantFuture).canPaste
    }
}
