import AVFoundation
import BranCore
import Foundation
import Observation

/// La bibliothèque. **Le dossier est la source de vérité**, pas l'inverse.
///
/// `reload()` lit `~/Movies/bran`, apparie chaque `.mp4` avec son `.json`, et
/// fabrique des métadonnées minimales pour les fichiers orphelins. Conséquence
/// directe : un enregistrement fait avant l'existence de cette classe apparaît
/// quand même, et supprimer le `.json` ne fait pas disparaître la vidéo.
@MainActor
@Observable
final class RecordingStore {

    private(set) var recordings: [Recording] = []
    private(set) var isScanning = false

    private(set) var root: URL

    init(root: URL = StorageLocation.default) {
        self.root = root
    }

    func setRoot(_ url: URL) async {
        guard url != root else { return }
        root = url
        await reload()
    }

    // MARK: - Lecture

    func reload() async {
        isScanning = true
        defer { isScanning = false }

        let found = await Self.scan(root: root)
        recordings = found.sorted { $0.metadata.startedAt > $1.metadata.startedAt }
    }

    /// Suffixe des morceaux intermédiaires — `<uuid>-seg000.mp4`. Ils ne sont
    /// jamais des entrées de bibliothèque : ce sont les pièces détachées d'une
    /// session, pas des enregistrements.
    private nonisolated static let segmentMarker = "-seg"

    private nonisolated static func scan(root: URL) async -> [Recording] {
        let manager = FileManager.default
        let path = root.path(percentEncoded: false)
        guard let names = try? manager.contentsOfDirectory(atPath: path) else { return [] }

        let finals = names.filter { $0.hasSuffix(".mp4") && $0.contains(segmentMarker) == false }
        let segments = names.filter { $0.hasSuffix(".mp4") && $0.contains(segmentMarker) }
        var found: [Recording] = []

        for name in finals {
            let url = root.appending(path: name)
            let identifier = UUID(uuidString: (name as NSString).deletingPathExtension)

            let attributes = try? manager.attributesOfItem(atPath: url.path(percentEncoded: false))
            let stored = loadMetadata(root: root, identifier: identifier)

            found.append(
                Recording(
                    metadata: stored ?? RecordingMetadata(
                        id: identifier ?? UUID(),
                        startedAt: attributes?[.creationDate] as? Date ?? .now
                    ),
                    url: url,
                    fileSize: attributes?[.size] as? Int64 ?? 0,
                    duration: await durationOfFile(at: url),
                    existsOnDisk: true,
                    hasMetadataFile: stored != nil
                )
            )
        }

        // Sessions dont le fichier final n'existe pas encore : enregistrement en
        // cours, ou post-traitement pas terminé. Sans elles, une session
        // disparaîtrait de la bibliothèque entre l'arrêt et la fin de la
        // compression — le moment exact où on regarde si ça a marché.
        let finalIdentifiers = Set(found.map(\.id))

        for name in names where name.hasSuffix(".json") {
            guard let identifier = UUID(uuidString: (name as NSString).deletingPathExtension),
                  finalIdentifiers.contains(identifier) == false,
                  let metadata = loadMetadata(root: root, identifier: identifier)
            else { continue }

            let prefix = "\(identifier.uuidString)\(segmentMarker)"
            let pieces = segments.filter { $0.hasPrefix(prefix) }
            let size = pieces.reduce(Int64.zero) { total, piece in
                let attributes = try? manager.attributesOfItem(
                    atPath: root.appending(path: piece).path(percentEncoded: false)
                )
                return total + (attributes?[.size] as? Int64 ?? 0)
            }

            found.append(
                Recording(
                    metadata: metadata,
                    url: root.appending(path: metadata.fileName),
                    fileSize: size,
                    duration: nil,
                    existsOnDisk: false,
                    hasMetadataFile: true
                )
            )
        }

        return found
    }

    private nonisolated static func loadMetadata(root: URL, identifier: UUID?) -> RecordingMetadata? {
        guard let identifier else { return nil }
        let sidecar = root.appending(path: "\(identifier.uuidString).json")
        guard let data = try? Data(contentsOf: sidecar) else { return nil }
        return try? JSONDecoder.bran.decode(RecordingMetadata.self, from: data)
    }

    private nonisolated static func durationOfFile(at url: URL) async -> TimeInterval? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration), duration.isNumeric else { return nil }
        return duration.seconds
    }

    // MARK: - Écriture

    /// Écrit le `.json` **dès le démarrage**, avant qu'une panne devienne
    /// possible. Un `.json` sans `endedAt` signale une session interrompue —
    /// c'est la sentinelle du §10, sans fichier `.lock` séparé à gérer.
    func beginSession(_ meeting: MeetingRef) {
        write(RecordingMetadata(meeting: meeting))
    }

    func completeSession(id: UUID, endedAt: Date = .now) async {
        guard var metadata = Self.loadMetadata(root: root, identifier: id) else { return }
        metadata.endedAt = endedAt
        write(metadata)
        await reload()
    }

    /// Renommage. Fonctionne pendant l'enregistrement : seul le `.json` change,
    /// le `.mp4` garde son nom d'UUID.
    /// Modification arbitraire du sidecar, relue depuis le disque à chaque fois.
    ///
    /// Relire plutôt que muter la copie en mémoire évite d'écraser un champ
    /// qu'un autre chemin vient d'écrire — le suivi CRM et la saisie de notes
    /// touchent le même fichier sans se coordonner.
    func mutate(_ id: UUID, _ change: (inout RecordingMetadata) -> Void) async {
        guard var metadata = Self.loadMetadata(root: root, identifier: id) else { return }
        change(&metadata)
        write(metadata)

        if let index = recordings.firstIndex(where: { $0.id == id }) {
            recordings[index].metadata = metadata
        }
    }

    func completeProcessing(id: UUID, originalBytes: Int64, segmentCount: Int) async {
        guard var metadata = Self.loadMetadata(root: root, identifier: id) else { return }
        metadata.originalBytes = originalBytes
        metadata.segmentCount = segmentCount
        metadata.processedAt = .now
        write(metadata)
        await reload()
    }

    func updateTitle(_ title: String, for id: UUID) {
        guard var metadata = Self.loadMetadata(root: root, identifier: id) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        metadata.title = trimmed.isEmpty ? nil : trimmed
        write(metadata)

        if let index = recordings.firstIndex(where: { $0.id == id }) {
            recordings[index].metadata = metadata
        }
    }

    func updateNotes(_ notes: String, for id: UUID) {
        guard var metadata = Self.loadMetadata(root: root, identifier: id) else { return }
        metadata.notes = notes
        write(metadata)

        if let index = recordings.firstIndex(where: { $0.id == id }) {
            recordings[index].metadata = metadata
        }
    }

    /// Corbeille, jamais suppression.
    ///
    /// Une heure de réunion effacée depuis un bouton de 24 points ne se
    /// récupère pas. `trashItem` rend l'annulation possible sans écrire une
    /// seule ligne de plus — c'est le Finder qui la porte.
    func delete(_ recording: Recording) async {
        let manager = FileManager.default
        try? manager.trashItem(at: recording.url, resultingItemURL: nil)
        try? manager.trashItem(
            at: root.appending(path: recording.metadata.sidecarName),
            resultingItemURL: nil
        )
        await reload()
    }

    private func write(_ metadata: RecordingMetadata) {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder.bran.encode(metadata) else { return }
        try? data.write(to: root.appending(path: metadata.sidecarName), options: .atomic)
    }
}

extension JSONEncoder {
    /// Dates ISO-8601 : lisibles à l'œil dans le `.json`, et non ambiguës.
    static let bran: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
}

extension JSONDecoder {
    static let bran: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
