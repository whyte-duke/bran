import AppKit
import BranCore
import BranVision
import ImageIO
import UniformTypeIdentifiers
import Foundation
import Observation

// MARK: - Conformités

/// Une capture se range comme n'importe quel contenu : une identité, une date,
/// un fichier lourd voisin. Le seul écart est le nom du champ — `imageFileName`
/// se lit mieux que `blobFileName` partout ailleurs dans l'application, et c'est
/// le nom que portent les fichiers déjà écrits sur le disque.
///
/// La conformité est déclarée ici, et pas dans `BranVision`, parce que `BranApp`
/// est le seul module d'où `BranCore` et `BranVision` se voient tous les deux.
/// Faire dépendre `BranVision` de `BranCore` pour trois lignes serait une arête
/// de plus dans le graphe des cibles pour un gain nul.
extension SnippetEntry: ContentEntry {
    public var blobFileName: String? {
        get { imageFileName }
        set { imageFileName = newValue }
    }
}

/// `SnapshotRetention` satisfait déjà le protocole mot pour mot : elle n'a rien
/// à apprendre, et elle reste dans `BranVision` avec ses treize tests. Voir la
/// note sur `ContentRetentionPolicy` pour pourquoi les deux politiques n'ont pas
/// été fondues en une seule.
extension SnapshotRetention: ContentRetentionPolicy {}

// MARK: - Le store

/// L'historique des captures de texte.
///
/// Une coquille au-dessus de `ContentStore` : tout ce qui est commun aux trois
/// bibliothèques — balayage du dossier, sidecars, purge, comptage des octets —
/// vit dans `BranCore`, où il est enfin testable. Ne reste ici que ce qui est
/// propre à une image : l'écriture d'un PNG, sa relecture, et la seule question
/// que la générique ne sait pas poser à la politique de rétention
/// (`keepsNothing`).
///
/// ```
/// ~/…/bran/Captures/
///   2026-08-05T20-47-11-<uuid>.json   ← le texte, gardé pour toujours
///   2026-08-05T20-47-11-<uuid>.png    ← l'image, purgée après 7 jours
/// ```
@MainActor
@Observable
final class SnapshotStore {

    private let store: ContentStore<SnippetEntry>

    /// Gardée en plus de celle du `ContentStore` parce que `save` lui pose une
    /// question que le protocole générique n'expose pas : `keepsNothing`. Ce
    /// n'est pas une deuxième source de vérité — les deux sont réglées ensemble,
    /// et seule celle-ci est interrogée.
    private var retention: SnapshotRetention

    init(root: @escaping @MainActor () -> URL, retention: SnapshotRetention = .default) {
        self.retention = retention
        self.store = ContentStore(
            root: root,
            shape: ContentShape(
                folderName: "Captures",
                blobExtension: "png",
                // L'image part, le texte reste. Le contraire effacerait des
                // captures vieilles de plus d'une semaine sans que personne ne
                // l'ait demandé.
                purge: .blobOnly,
                inaccessibleFolderMessage: "Dossier des captures inaccessible",
                // On **dit** pourquoi l'image manque. La première version avalait
                // l'erreur, et c'est exactement ce qui a empêché de diagnostiquer
                // une capture vide : plus d'image, donc plus rien à regarder.
                blobFailureMessage: "Image non conservée"
            ),
            retention: retention
        )
    }

    var entries: [SnippetEntry] { store.entries }
    var problem: String? { store.problem }

    /// Octets occupés par les images conservées. Affiché dans les réglages :
    /// une rétention se règle mieux quand on voit ce qu'elle coûte.
    var imageBytes: Int64 { store.blobBytes }

    var folder: URL { store.folder }

    func setRetention(_ policy: SnapshotRetention) {
        retention = policy
        store.setRetention(policy)
    }

    // MARK: - Lecture

    func reload() async {
        await store.reload()
    }

    // MARK: - Écriture

    /// Écrit l'image puis le sidecar, dans cet ordre.
    ///
    /// Deux raisons de ne pas écrire d'image, et elles ne se racontent pas
    /// pareil : il n'y en avait pas à écrire (silence), ou la rétention est
    /// réglée sur zéro (il faut le dire, sinon l'absence d'image ressemble à une
    /// panne).
    func save(_ entry: SnippetEntry, image: CGImage?) async {
        guard let image else {
            await store.save(entry)
            return
        }

        guard retention.keepsNothing == false else {
            store.report("Image non conservée : la durée de conservation est réglée sur zéro.")
            await store.save(entry)
            return
        }

        await store.save(entry) { try Self.writePNG(image, to: $0) }
    }

    /// Modifie une entrée en réécrivant son sidecar.
    func mutate(_ id: UUID, _ change: (inout SnippetEntry) -> Void) {
        store.mutate(id, change)
    }

    func delete(_ entry: SnippetEntry) async {
        await store.delete(entry)
    }

    func imageURL(for entry: SnippetEntry) -> URL? {
        store.blobURL(for: entry)
    }

    /// Relit une image pour une nouvelle lecture.
    func loadImage(for entry: SnippetEntry) -> CGImage? {
        guard let url = imageURL(for: entry),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil)
        else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    // MARK: - Purge

    /// Supprime les images arrivées à échéance. Le texte n'est jamais touché.
    @discardableResult
    func purgeExpiredImages(now: Date = .now) async -> Int {
        await store.purgeExpired(now: now)
    }

    func expiryDate(for entry: SnippetEntry) -> Date {
        store.expiryDate(for: entry)
    }

    // MARK: - Interne

    /// PNG et pas JPEG : du texte à l'écran est du trait net sur fond uni,
    /// exactement le cas où la compression avec perte fabrique des halos autour
    /// des caractères. Mesuré sur des captures réelles, un PNG de zone de texte
    /// pèse 150 à 270 Ko — assez peu pour ne pas justifier de dégrader l'image
    /// qui servira à une relecture.
    private static func writePNG(_ image: CGImage, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}
