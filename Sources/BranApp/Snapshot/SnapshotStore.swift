import AppKit
import BranVision
import Foundation
import Observation

/// L'historique des captures de texte.
///
/// Même parti pris que `RecordingStore` et `DictationStore` : **le dossier est
/// la source de vérité**. Pas de base de données à côté du disque — deux
/// sources de vérité divergent toujours, et c'est l'utilisateur qui arbitre au
/// pire moment. Supprimer un `.png` dans le Finder rend simplement l'entrée
/// non-relisable au prochain balayage, ce qui est le comportement souhaité.
///
/// ```
/// ~/…/bran/Captures/
///   2026-08-05T20-47-11-<uuid>.json   ← le texte, gardé pour toujours
///   2026-08-05T20-47-11-<uuid>.png    ← l'image, purgée après 7 jours
/// ```
@MainActor
@Observable
final class SnapshotStore {

    private(set) var entries: [SnippetEntry] = []
    private(set) var problem: String?

    /// Octets occupés par les images conservées. Affiché dans les réglages :
    /// une rétention se règle mieux quand on voit ce qu'elle coûte.
    private(set) var imageBytes: Int64 = 0

    /// Le dossier suit celui des enregistrements : changer la destination dans
    /// les réglages déplace tout d'un coup. Une fermeture plutôt qu'une `URL`
    /// figée, sinon le store garderait l'ancien dossier jusqu'au prochain
    /// lancement.
    private let root: @MainActor () -> URL
    private var retention: SnapshotRetention

    init(root: @escaping @MainActor () -> URL, retention: SnapshotRetention = .default) {
        self.root = root
        self.retention = retention
    }

    var folder: URL {
        root().appending(path: "Captures", directoryHint: .isDirectory)
    }

    func setRetention(_ policy: SnapshotRetention) {
        retention = policy
        Task { await purgeExpiredImages() }
    }

    // MARK: - Lecture

    func reload() async {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let files = try FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles]
            )

            let decoder = Self.decoder
            var found: [SnippetEntry] = []
            var bytes: Int64 = 0

            for url in files {
                if url.pathExtension == "json",
                   let data = try? Data(contentsOf: url),
                   var entry = try? decoder.decode(SnippetEntry.self, from: data) {

                    // Une image supprimée à la main dans le Finder doit rendre
                    // l'entrée non-relisable, pas planter au clic.
                    if let name = entry.imageFileName,
                       FileManager.default.fileExists(
                           atPath: folder.appending(path: name).path(percentEncoded: false)
                       ) == false {
                        entry.imageFileName = nil
                    }
                    found.append(entry)
                } else if url.pathExtension == "png" {
                    bytes += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                }
            }

            entries = found.sorted { $0.createdAt > $1.createdAt }
            imageBytes = bytes
            problem = nil
        } catch {
            problem = "Dossier des captures inaccessible : \(error.localizedDescription)"
        }
    }

    // MARK: - Écriture

    /// Écrit l'image puis le sidecar, dans cet ordre.
    ///
    /// L'ordre compte : un `.json` qui référence un `.png` inexistant serait une
    /// entrée qui promet une relecture impossible. L'inverse — une image
    /// orpheline — se nettoie tout seul à la purge.
    func save(_ entry: SnippetEntry, image: CGImage?) async {
        var stored = entry

        if let image, retention.keepsNothing == false {
            let name = "\(Self.stamp(entry.createdAt))-\(entry.id.uuidString).png"
            do {
                try Self.writePNG(image, to: folder.appending(path: name))
                stored.imageFileName = name
            } catch {
                // L'image est un confort ; le texte est l'essentiel. On garde
                // l'entrée sans son image plutôt que de tout perdre.
                stored.imageFileName = nil
            }
        }

        write(stored)
        entries.insert(stored, at: 0)
        await refreshImageBytes()
    }

    /// Modifie une entrée en réécrivant son sidecar.
    func mutate(_ id: UUID, _ change: (inout SnippetEntry) -> Void) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        var entry = entries[index]
        change(&entry)
        entries[index] = entry
        write(entry)
    }

    func delete(_ entry: SnippetEntry) async {
        if let name = entry.imageFileName {
            try? FileManager.default.removeItem(at: folder.appending(path: name))
        }
        try? FileManager.default.removeItem(at: sidecarURL(for: entry))
        entries.removeAll { $0.id == entry.id }
        await refreshImageBytes()
    }

    func imageURL(for entry: SnippetEntry) -> URL? {
        entry.imageFileName.map { folder.appending(path: $0) }
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
        let expired = retention.entriesToPurge(from: entries, now: now)
        guard expired.isEmpty == false else { return 0 }

        for entry in expired {
            if let name = entry.imageFileName {
                try? FileManager.default.removeItem(at: folder.appending(path: name))
            }
            mutate(entry.id) { $0.imageFileName = nil }
        }

        await refreshImageBytes()
        return expired.count
    }

    func expiryDate(for entry: SnippetEntry) -> Date {
        retention.expiryDate(for: entry)
    }

    // MARK: - Interne

    private func write(_ entry: SnippetEntry) {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let data = try Self.encoder.encode(entry)
            try data.write(to: sidecarURL(for: entry), options: .atomic)
        } catch {
            problem = "Écriture impossible : \(error.localizedDescription)"
        }
    }

    private func sidecarURL(for entry: SnippetEntry) -> URL {
        folder.appending(path: "\(Self.stamp(entry.createdAt))-\(entry.id.uuidString).json")
    }

    private func refreshImageBytes() async {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]
        )) ?? []

        imageBytes = files
            .filter { $0.pathExtension == "png" }
            .reduce(into: Int64(0)) { total, url in
                total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            }
    }

    /// Horodatage triable en tête de nom de fichier : le dossier se lit dans
    /// l'ordre chronologique sans outil.
    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }

    /// PNG et pas JPEG : du texte à l'écran est du trait net sur fond uni,
    /// exactement le cas où la compression avec perte fabrique des halos autour
    /// des caractères. Mesuré sur des captures réelles, un PNG de zone de texte
    /// pèse 150 à 270 Ko — assez peu pour ne pas justifier de dégrader l'image
    /// qui servira à une relecture.
    private static func writePNG(_ image: CGImage, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url, options: .atomic)
    }
}
