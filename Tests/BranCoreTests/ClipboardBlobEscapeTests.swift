import Foundation
import Testing

@testable import BranCore

/// **Ce que ce fichier protège** : un sidecar du presse-papiers est un fichier
/// JSON déposé dans un dossier ordinaire, et rien ne garantit qui l'a écrit.
/// `ClipboardBlobRef.fileName` concaténait `hash` et `ext` sans jamais les
/// relire : une entrée portant `"hash":"../../../Documents/secret"` résolvait
/// vers un fichier hors de la bibliothèque, que « copier » chargeait dans le
/// presse-papiers et que l'épinglage recopiait — donc une évasion en lecture
/// **et** en écriture. Ces tests exigent que le magasin refuse tout nom qu'il
/// n'aurait pas pu écrire lui-même.
@Suite("Évasion de dossier par un contenu du presse-papiers")
@MainActor
struct ClipboardBlobEscapeTests {

    private func makeRoot() throws -> URL {
        let url = URL.temporaryDirectory
            .appending(path: "ClipboardBlobEscapeTests", directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Une empreinte parfaitement bien formée, pour isoler ce que le test
    /// mesure : c'est l'extension, et elle seule, qui porte l'évasion.
    private let goodHash = String(repeating: "a", count: 64)

    /// Dépose un sidecar sur le disque **par le chemin du magasin lui-même**.
    ///
    /// L'encodeur est `ClipboardStore.sidecarEncoder` et pas un `JSONEncoder`
    /// neuf : le magasin lit ses dates en `secondsSince1970`, et un sidecar
    /// écrit en ISO 8601 ne décode tout simplement pas. Le test passerait alors
    /// sur une bibliothèque vide, en croyant avoir prouvé quelque chose.
    private func writeSidecar(_ entry: ClipboardEntry, root: URL) throws {
        let folder = root
            .appending(path: ClipboardStore.folderName, directoryHint: .isDirectory)
            .appending(path: entry.dayFolderName(), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try ClipboardStore.sidecarEncoder.encode(entry)
        try data.write(to: ClipboardStore.sidecarURL(entry, in: folder))
    }

    @Test("Un contenu qui remonte d'un dossier ne rend aucun chemin")
    func unContenuQuiRemonteNeRendAucunChemin() async throws {
        let root = try makeRoot()

        // Le voisin que l'on essaie d'atteindre : un fichier hors de la
        // bibliothèque, comme le serait un document personnel.
        let neighbour = root.appending(path: "secret.png")
        try Data("le contenu de quelqu'un d'autre".utf8).write(to: neighbour)

        let hostile = ClipboardEntry(
            copiedAt: .now,
            kind: .image,
            text: "",
            blobs: [ClipboardBlobRef(hash: "../../secret", ext: "png", bytes: 1)]
        )
        try writeSidecar(hostile, root: root)

        let store = ClipboardStore(root: { root })
        _ = await store.load()

        // **On affirme d'abord que le scénario est bien chargé.** Sans cette
        // ligne, un sidecar qui ne décode pas ferait passer le test sur une
        // bibliothèque vide — le défaut serait intact et la suite verte.
        #expect(store.recent.count == 1)
        let loaded = try #require(store.recent.first)
        let ref = try #require(loaded.blobs?.first)

        #expect(store.blobURL(for: ref, of: loaded) == nil)
        // Le voisin n'a pas bougé : on refuse de le lire, on ne le touche pas.
        #expect(FileManager.default.fileExists(atPath: neighbour.path(percentEncoded: false)))
    }

    @Test("Une extension qui contient un séparateur est refusée")
    func uneExtensionAvecSeparateurEstRefusee() async throws {
        let root = try makeRoot()

        // Le piège de forme : l'empreinte est irréprochable, et le découpage du
        // nom ne coupe qu'au premier point. Sans refus explicite des barres
        // obliques, `png/../../secret` passait la vérification d'empreinte.
        let hostile = ClipboardEntry(
            copiedAt: .now,
            kind: .image,
            text: "",
            blobs: [ClipboardBlobRef(hash: goodHash, ext: "png/../../secret", bytes: 1)]
        )
        try writeSidecar(hostile, root: root)

        let store = ClipboardStore(root: { root })
        _ = await store.load()

        #expect(store.recent.count == 1)
        let loaded = try #require(store.recent.first)
        let ref = try #require(loaded.blobs?.first)
        #expect(store.blobURL(for: ref, of: loaded) == nil)
    }

    @Test("Un contenu que le magasin a écrit lui-même reste lisible")
    func unContenuLegitimeResteLisible() async throws {
        let root = try makeRoot()

        // Le pendant obligatoire : une garde qui refuse tout protégerait aussi
        // bien et casserait la fonctionnalité entière.
        let honest = ClipboardEntry(
            copiedAt: .now,
            kind: .image,
            text: "",
            blobs: [ClipboardBlobRef(hash: goodHash, ext: "png", bytes: 12)]
        )
        try writeSidecar(honest, root: root)

        let store = ClipboardStore(root: { root })
        _ = await store.load()

        #expect(store.recent.count == 1)
        let loaded = try #require(store.recent.first)
        let ref = try #require(loaded.blobs?.first)
        let url = try #require(store.blobURL(for: ref, of: loaded))
        #expect(url.lastPathComponent == "\(goodHash).png")
        #expect(url.deletingLastPathComponent().lastPathComponent == ClipboardStore.blobsFolderName)
    }

    @Test("L'épinglage refuse de recopier un contenu au nom fabriqué")
    func lEpinglageRefuseUnNomFabrique() async throws {
        let root = try makeRoot()
        let jour = root.appending(path: "jour", directoryHint: .isDirectory)
        let epingles = root.appending(path: "Pinned", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: jour, withIntermediateDirectories: true)

        // C'est le chemin qui **écrit** : sans garde, ce `copyBlobsToPinned`
        // déposait le fichier hors du dossier épinglé.
        // `BlobRefused` plutôt que l'ancien `ClipboardStoreError` : les deux
        // lots de correction ont fermé cette traversée en parallèle, et c'est la
        // version la plus stricte qui a été retenue à la fusion — elle refuse en
        // plus les empreintes non-ASCII (`Character.isHexDigit` accepte les
        // chiffres pleine chasse) et les extensions qui portent un chemin.
        await #expect(throws: BlobRefused.self) {
            try await ClipboardStore.copyBlobsToPinned(
                [ClipboardBlobRef(hash: "../evasion", ext: "png", bytes: 1)],
                from: jour,
                to: epingles
            )
        }
    }

    @Test("Le prédicat de nom accepte ce que le magasin écrit, et rien d'autre")
    func lePredicatDeNomEstExact() {
        #expect(ClipboardStore.containedBlobName(
            ClipboardBlobRef(hash: goodHash, ext: "png", bytes: 1)
        ) == "\(goodHash).png")

        // Les quatre graphies d'évasion qu'un sidecar peut porter.
        for (hash, ext) in [
            ("../../secret", "png"),
            (goodHash, "png/../../secret"),
            ("/etc/passwd", ""),
            ("..", ""),
        ] {
            #expect(
                ClipboardStore.containedBlobName(
                    ClipboardBlobRef(hash: hash, ext: ext, bytes: 1)
                ) == nil,
                "« \(hash).\(ext) » ne doit pas être accepté"
            )
        }

        // Une empreinte trop courte ou en majuscules n'est pas des nôtres non
        // plus : le magasin écrit du minuscule sur 64 caractères.
        #expect(ClipboardStore.containedBlobName(
            ClipboardBlobRef(hash: String(repeating: "A", count: 64), ext: "png", bytes: 1)
        ) == nil)
        #expect(ClipboardStore.containedBlobName(
            ClipboardBlobRef(hash: "abc", ext: "png", bytes: 1)
        ) == nil)
    }
}

/// **Ce que ce fichier protège** : que la purge n'emporte pas les fichiers de
/// quelqu'un d'autre.
///
/// La bibliothèque est un dossier ordinaire — le README invite explicitement à
/// l'ouvrir, le déplacer, le copier, et les réglages laissent le poser où l'on
/// veut. La purge d'un jour entièrement expiré supprimait ce dossier d'un
/// `removeItem` récursif : un `notes.txt` qu'on y avait glissé disparaissait
/// avec, définitivement, sans avoir jamais été montré nulle part.
@Suite("La purge d'un jour ne supprime que ce que bran a écrit")
struct ClipboardDayFolderPurgeTests {

    @Test("Un fichier étranger survit à la purge du jour, et le dossier avec lui")
    func aForeignFileSurvivesTheDayPurge() async throws {
        let racine = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "bran-purge-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: racine) }
        let jour = racine.appending(path: "2026-01-01", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: jour, withIntermediateDirectories: true)

        // Ce que bran écrit.
        try Data("{}".utf8).write(to: jour.appending(path: "\(UUID().uuidString).json"))
        try Data("".utf8).write(to: jour.appending(path: ClipboardStore.indexFileName))
        // Ce que quelqu'un d'autre a mis là.
        let etranger = jour.appending(path: "notes.txt")
        try Data("à ne pas perdre".utf8).write(to: etranger)

        try await ClipboardStore.removeDayFolder(jour)

        #expect(
            FileManager.default.fileExists(atPath: etranger.path(percentEncoded: false)),
            "un fichier qui n'est pas à bran a été supprimé"
        )
        #expect(
            FileManager.default.fileExists(atPath: jour.path(percentEncoded: false)),
            "le dossier a été retiré alors qu'il n'était pas vide"
        )
    }

    @Test("Un jour qui ne contient que nos fichiers s'en va entièrement")
    func aDayWithOnlyOurFilesIsRemovedEntirely() async throws {
        let racine = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "bran-purge-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: racine) }
        let jour = racine.appending(path: "2026-01-01", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: jour, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: jour.appending(path: "\(UUID().uuidString).json"))
        try Data("".utf8).write(to: jour.appending(path: ClipboardStore.indexFileName))

        try await ClipboardStore.removeDayFolder(jour)

        #expect(FileManager.default.fileExists(atPath: jour.path(percentEncoded: false)) == false)
    }
}
