import Foundation
import Testing

@testable import BranCore

/// **Recoller la mauvaise chose est le seul défaut que l'utilisateur ne
/// pardonne pas.**
///
/// Tout le reste de l'historique se répare en rouvrant le panneau. Un ↵ qui pose
/// du texte nu là où il y avait un tableau, une image à la place d'un lien, ou
/// rien du tout, atterrit dans le document de quelqu'un — et c'est le geste
/// entier de la fonctionnalité qui est perdu.
///
/// Tout se vérifie ici sans presse-papiers et sans disque : la lecture des
/// contenus lourds est une fermeture.
@Suite("Ce qu'on repose sur le presse-papiers")
struct ClipboardPastePlanTests {

    // MARK: - Outillage

    private static var noon: Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: DateComponents(year: 2026, month: 8, day: 10, hour: 12))!
    }

    /// Une bibliothèque de contenus lourds en mémoire, indexée par empreinte.
    private struct Blobs {
        var contents: [String: Data] = [:]

        mutating func add(_ body: String, ext: String) -> ClipboardBlobRef {
            let data = Data(body.utf8)
            let payload = ClipboardBlobPayload(data: data, ext: ext)
            contents[payload.hash] = data
            return payload.ref
        }

        func read(_ reference: ClipboardBlobRef) -> Data? { contents[reference.hash] }
    }

    private func plan(
        _ entry: ClipboardEntry,
        _ variant: ClipboardPastePlan.Variant = .faithful,
        _ blobs: Blobs = Blobs()
    ) -> [[ClipboardPasteRepresentation]] {
        ClipboardPastePlan.items(for: entry, variant: variant) { blobs.read($0) }
    }

    private func text(_ body: String) -> String? {
        body
    }

    // MARK: - Texte brut

    @Test("Un texte en ligne se repose tel quel, sans toucher au disque")
    func texteEnLigne() {
        let entry = ClipboardEntry(copiedAt: Self.noon, kind: .text, text: "Bonjour")
        let items = plan(entry)

        #expect(items.count == 1)
        #expect(items.first?.count == 1)
        #expect(items.first?.first?.type == ClipboardPastePlan.utf8TextType)
        #expect(items.first?.first?.data == Data("Bonjour".utf8))
    }

    /// Le texte au-delà de 512 Kio vit dans un blob. Ne pas aller le chercher
    /// rendrait incollables précisément les entrées qu'on garde parce qu'on ne
    /// les a nulle part ailleurs — un journal, un export CSV.
    @Test("Un texte trop long pour l'index se repose depuis son fichier")
    func texteDebordant() {
        var blobs = Blobs()
        let long = String(repeating: "a", count: ClipboardEntry.inlineTextLimit + 1)
        let reference = blobs.add(long, ext: "txt")
        let entry = ClipboardEntry(
            copiedAt: Self.noon, kind: .text, text: long, blobs: [reference]
        )

        #expect(entry.plainText == nil, "le texte ne tient pas en ligne, c'est la prémisse")
        let items = plan(entry, .faithful, blobs)
        #expect(items.first?.first?.data == Data(long.utf8))
    }

    // MARK: - Texte enrichi

    /// **Le test qui garde l'ordre.** L'application qui reçoit prend le premier
    /// type qu'elle comprend : poser le texte brut devant ferait coller du texte
    /// nu dans un traitement de texte parfaitement capable d'afficher la mise en
    /// forme.
    @Test("La forme enrichie passe devant son texte brut, jamais l'inverse")
    func formeRicheEnTete() throws {
        var blobs = Blobs()
        let rtf = blobs.add("{\\rtf1 Bonjour}", ext: "rtf")
        let entry = ClipboardEntry(
            copiedAt: Self.noon,
            kind: .richText,
            preview: "Bonjour",
            plainText: "Bonjour",
            blobs: [rtf]
        )

        let representations = try #require(plan(entry, .faithful, blobs).first)
        #expect(representations.count == 2)
        #expect(representations.first?.type == "public.rtf")
        #expect(representations.last?.type == ClipboardPastePlan.utf8TextType)
    }

    @Test("« Sans mise en forme » ne repose que le texte")
    func sansMiseEnForme() throws {
        var blobs = Blobs()
        let rtf = blobs.add("{\\rtf1 Bonjour}", ext: "rtf")
        let entry = ClipboardEntry(
            copiedAt: Self.noon,
            kind: .richText,
            preview: "Bonjour",
            plainText: "Bonjour",
            blobs: [rtf]
        )

        let representations = try #require(plan(entry, .plainText, blobs).first)
        #expect(representations.count == 1)
        #expect(representations.first?.type == ClipboardPastePlan.utf8TextType)
    }

    /// Le rendu matriciel d'un texte enrichi est **conservé** par la capture pour
    /// un futur « coller comme image ». Le reposer ici ferait coller une capture
    /// d'écran du tableau à la place du tableau, dans toute application qui
    /// préfère les images — et il y en a.
    @Test("Le rendu matriciel d'un texte enrichi n'est pas reposé")
    func rendaMatricielNonReposé() throws {
        var blobs = Blobs()
        let rtf = blobs.add("{\\rtf1 tableau}", ext: "rtf")
        let png = blobs.add("des pixels", ext: "png")
        let entry = ClipboardEntry(
            copiedAt: Self.noon,
            kind: .richText,
            preview: "tableau",
            plainText: "tableau",
            blobs: [rtf, png]
        )

        let representations = try #require(plan(entry, .faithful, blobs).first)
        #expect(representations.map(\.type) == ["public.rtf", ClipboardPastePlan.utf8TextType])
    }

    // MARK: - Image

    @Test("Une image se repose avec le type que son extension désigne")
    func image() throws {
        var blobs = Blobs()
        let png = blobs.add("des pixels", ext: "png")
        let entry = ClipboardEntry(
            copiedAt: Self.noon, kind: .image, preview: "", blobs: [png]
        )

        let items = plan(entry, .faithful, blobs)
        #expect(items.count == 1)
        #expect(items.first?.first?.type == "public.png")
    }

    /// Demander « sans mise en forme » sur une image est un geste qui n'a pas de
    /// sens ; ne rien coller serait le prendre pour une demande de ne rien faire.
    @Test("« Sans mise en forme » sur une image repose quand même l'image")
    func imageSansMiseEnForme() {
        var blobs = Blobs()
        let png = blobs.add("des pixels", ext: "png")
        let entry = ClipboardEntry(
            copiedAt: Self.noon, kind: .image, preview: "", blobs: [png]
        )

        #expect(plan(entry, .plainText, blobs).isEmpty == false)
    }

    @Test("Deux images copiées ensemble redonnent deux éléments")
    func deuxImages() {
        var blobs = Blobs()
        let a = blobs.add("première", ext: "png")
        let b = blobs.add("seconde", ext: "png")
        let entry = ClipboardEntry(
            copiedAt: Self.noon, kind: .image, preview: "", blobs: [a, b], pasteboardItems: 2
        )

        #expect(plan(entry, .faithful, blobs).count == 2)
    }

    // MARK: - Fichiers

    /// **Un élément par fichier, jamais un élément à N représentations.** Les
    /// aplatir donnerait un presse-papiers qui ne désigne plus qu'un fichier, et
    /// une copie de douze fichiers en collerait un seul — silencieusement.
    @Test("Une sélection de trois fichiers redonne trois éléments")
    func troisFichiers() {
        let entry = ClipboardEntry(
            copiedAt: Self.noon,
            kind: .file,
            preview: "",
            fileURLs: [
                "file:///Users/x/un.txt",
                "file:///Users/x/deux.txt",
                "file:///Users/x/trois.txt",
            ]
        )

        let items = plan(entry)
        #expect(items.count == 3)
        #expect(items.allSatisfy { $0.count == 1 })
        #expect(items.first?.first?.type == ClipboardPastePlan.fileURLType)
    }

    /// `NSFilenamesPboardType` transporte des chemins **nus**. Les reposer tels
    /// quels donnerait une chaîne que rien ne reconnaît comme un fichier.
    @Test("Un chemin nu est reposé en URL de fichier")
    func cheminNu() throws {
        let entry = ClipboardEntry(
            copiedAt: Self.noon, kind: .file, preview: "", fileURLs: ["/Users/x/un.txt"]
        )

        let representation = try #require(plan(entry).first?.first)
        let url = try #require(String(data: representation.data, encoding: .utf8))
        #expect(url.hasPrefix("file://"))
        #expect(url.hasSuffix("/Users/x/un.txt"))
    }

    // MARK: - Ce qui ne se recolle pas

    /// Une entrée purgée garde son texte — il vit dans l'index, que la rétention
    /// ne touche jamais — mais perd son image. Les deux cas doivent se comporter
    /// exactement comme `canPaste` l'annonce, sinon le bouton et le geste se
    /// contredisent.
    @Test("Une image purgée ne repose rien, un texte purgé repose son texte")
    func aprèsLaPurge() {
        let image = ClipboardEntry(
            copiedAt: Self.noon,
            kind: .image,
            preview: "",
            blobs: [ClipboardBlobRef(hash: String(repeating: "a", count: 64), ext: "png", bytes: 9)]
        ).purgingBlobs(at: Self.noon)
        #expect(image.canPaste == false)
        #expect(plan(image).isEmpty)

        let texte = ClipboardEntry(copiedAt: Self.noon, kind: .text, text: "gardé")
            .purgingBlobs(at: Self.noon)
        #expect(texte.canPaste)
        #expect(plan(texte).isEmpty == false)
    }

    @Test("Une entrée refusée à l'écriture ne repose rien")
    func entréeRefusée() {
        var entry = ClipboardEntry(copiedAt: Self.noon, kind: .image, preview: "")
        entry.refusedBytes = ClipboardEntry.maximumBlobBytes + 1
        #expect(entry.canPaste == false)
        #expect(plan(entry).isEmpty)
    }

    /// Un contenu lourd que le disque refuse de rendre ne doit pas emporter les
    /// autres représentations avec lui.
    @Test("Un fichier illisible ne fait pas perdre le texte brut qui l'accompagne")
    func blobIllisible() throws {
        var blobs = Blobs()
        let rtf = blobs.add("{\\rtf1 Bonjour}", ext: "rtf")
        blobs.contents.removeAll()                 // le disque ne rend plus rien
        let entry = ClipboardEntry(
            copiedAt: Self.noon,
            kind: .richText,
            preview: "Bonjour",
            plainText: "Bonjour",
            blobs: [rtf]
        )

        let representations = try #require(plan(entry, .faithful, blobs).first)
        #expect(representations.map(\.type) == [ClipboardPastePlan.utf8TextType])
    }

    // MARK: - La table des types

    /// L'inverse de `ClipboardCapture.blobExtensions`, écrite à la main parce
    /// qu'une inversion mécanique rendrait un identifiant au hasard là où quatre
    /// s'écrivent `txt`. Ce test gèle les deux sens.
    @Test("Toute extension que la capture écrit se relit en un type")
    func tableDesTypesRéversible() {
        for (type, ext) in ClipboardCapture.blobExtensions {
            let back = ClipboardPastePlan.type(for: ext)
            #expect(back.isEmpty == false)
            #expect(back != "public.data", "l'extension « \(ext) » n'a pas de type au retour")
            // Les familles où plusieurs identifiants partagent une extension ne
            // rendent pas forcément le même — c'est voulu, et documenté. Ce qu'on
            // exige est que le retour soit un membre de la même famille.
            if ext == ClipboardPastePlan.plainTextExtension {
                #expect(ClipboardTypePolicy.textTypes.contains(back))
            } else if ClipboardTypePolicy.imageTypes.contains(type) {
                #expect(ClipboardTypePolicy.imageTypes.contains(back))
            } else {
                #expect(ClipboardTypePolicy.richTextTypes.contains(back))
            }
        }
    }

    @Test("Une extension inconnue rend des octets, jamais rien")
    func extensionInconnue() {
        #expect(ClipboardPastePlan.type(for: "xyz") == "public.data")
    }
}
