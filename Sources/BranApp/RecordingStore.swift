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

    /// Ce que la bibliothèque n'a pas réussi à écrire, ou à relire fiche par
    /// fiche. Câblé par `AppModel` sur `lastFailure`.
    ///
    /// **Pas `problem`, volontairement.** `problem` remplace la liste entière par
    /// « Enregistrements introuvables » : c'est juste pour un dossier illisible,
    /// c'est absurde pour un titre qui n'a pas pu être sauvegardé — on masquerait
    /// quarante réunions intactes à cause d'une frappe. Ces ennuis-là passent par
    /// le canal d'échec unique de bran, celui du bandeau et du menu, exactement
    /// comme `AwakeController.onFailure`.
    var onProblem: (@MainActor (String) -> Void)?

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

        let scan = await Self.scan(root: root)
        recordings = scan.recordings.sorted { $0.metadata.startedAt > $1.metadata.startedAt }
        problem = scan.problem

        // Une fiche abîmée n'empêche pas la bibliothèque de s'afficher — les
        // autres réunions sont là, et celle-ci aussi, sous sa date. Elle a
        // seulement perdu son identité, et ça se dit ailleurs que dans un écran
        // vide.
        for fault in scan.faults { onProblem?(fault) }
    }

    /// **Ce qui empêche de lire le dossier, quand quelque chose l'empêche.**
    ///
    /// `DictationStore` et `WatchStore` en ont un depuis toujours ; celui-ci
    /// n'en avait pas, et son `try?` rendait un tableau vide. Un volume externe
    /// démonté, un dossier renommé, une autorisation retirée : quarante réunions
    /// intactes sur le disque, et l'écran qui annonce « Aucun enregistrement ».
    /// C'est la pire forme d'un défaut de lecture — elle ressemble à une perte
    /// de données, et on cherche le problème là où il n'est pas.
    private(set) var problem: String?

    /// Suffixe des morceaux intermédiaires — `<uuid>-seg000.mp4`. Ils ne sont
    /// jamais des entrées de bibliothèque : ce sont les pièces détachées d'une
    /// session, pas des enregistrements.
    private nonisolated static let segmentMarker = "-seg"

    struct Scan: Sendable {
        let recordings: [Recording]

        /// Ce qui empêche de lire le **dossier**. Bloquant : sans lui, il n'y a
        /// pas de bibliothèque du tout.
        let problem: String?

        /// Ce qui a mal tourné **fiche par fiche**. Non bloquant : les autres
        /// enregistrements s'affichent normalement.
        let faults: [String]
    }

    private nonisolated static func scan(root: URL) async -> Scan {
        let manager = FileManager.default
        let path = root.path(percentEncoded: false)

        let names: [String]
        do {
            names = try manager.contentsOfDirectory(atPath: path)
        } catch {
            // Un dossier absent est **normal** : c'est le premier lancement,
            // avant le premier enregistrement. Tout le reste — volume démonté,
            // droits retirés, chemin devenu un fichier — est un problème, et il
            // doit se dire. C'est la même distinction que `WeekLoader.harvest`
            // fait entre un jour sans veille et un journal refusé.
            let cocoa = error as NSError
            let missing = cocoa.domain == NSCocoaErrorDomain
                && cocoa.code == NSFileReadNoSuchFileError
            return Scan(
                recordings: [],
                problem: missing ? nil : "Dossier des enregistrements illisible : \(error.localizedDescription)",
                faults: []
            )
        }

        let finals = names.filter { $0.hasSuffix(".mp4") && $0.contains(segmentMarker) == false }
        let segments = names.filter { $0.hasSuffix(".mp4") && $0.contains(segmentMarker) }
        var found: [Recording] = []
        var faults: [String] = []

        for name in finals {
            let url = root.appending(path: name)
            let identifier = UUID(uuidString: (name as NSString).deletingPathExtension)

            let attributes = try? manager.attributesOfItem(atPath: url.path(percentEncoded: false))

            var stored: RecordingMetadata?
            var hasSidecar = false

            if let identifier {
                switch readSidecar(root: root, identifier: identifier) {
                case .success(let metadata):
                    stored = metadata
                    hasSidecar = true
                case .failure(let fault):
                    // Une fiche présente mais illisible n'est PAS une absence.
                    // `hasMetadataFile` reste vrai : la vidéo n'est pas une
                    // orpheline, elle est une réunion dont la fiche est cassée,
                    // et la bibliothèque la marque donc « interrompue » au lieu
                    // de la présenter comme un fichier quelconque.
                    hasSidecar = fault.isNormal == false
                    if let note = fault.listingNote(for: "\(identifier.uuidString).json") {
                        faults.append(note)
                    }
                }
            }

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
                    hasMetadataFile: hasSidecar
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
                  finalIdentifiers.contains(identifier) == false
            else { continue }

            let metadata: RecordingMetadata
            switch readSidecar(root: root, identifier: identifier) {
            case .success(let decoded):
                metadata = decoded
            case .failure(let fault):
                // Ici, la fiche est tout ce qu'on a : aucun `.mp4` final ne
                // porte cette session. La perdre en silence, c'est faire
                // disparaître de la bibliothèque une réunion dont les segments
                // sont peut-être encore sur le disque.
                if let note = fault.listingNote(for: name) { faults.append(note) }
                continue
            }

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

        return Scan(recordings: found, problem: nil, faults: faults)
    }

    /// Lit une fiche, ou dit pourquoi elle n'est pas lisible.
    ///
    /// L'ancienne version rendait `nil` dans les deux cas, et c'est ce qui
    /// rendait le défaut invisible : « aucune fiche » — un `.mp4` déposé à la
    /// main, parfaitement normal — et « une fiche qui ne se décode pas » — le
    /// titre, les notes, le rattachement CRM et l'état de la session partis sans
    /// un mot — donnaient exactement le même résultat à l'écran.
    private nonisolated static func readSidecar(
        root: URL,
        identifier: UUID
    ) -> Result<RecordingMetadata, SidecarFault> {
        let sidecar = root.appending(path: "\(identifier.uuidString).json")

        let data: Data
        do {
            data = try Data(contentsOf: sidecar)
        } catch {
            return .failure(.reading(error))
        }

        do {
            return .success(try JSONDecoder.bran.decode(RecordingMetadata.self, from: data))
        } catch {
            return .failure(.decoding(error))
        }
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
        guard var metadata = loadForEditing(id) else { return }
        metadata.endedAt = endedAt
        write(metadata)
        await reload()
    }

    /// Relit une fiche avant de la modifier, en disant ce qui empêche de le
    /// faire.
    ///
    /// Deux règles, et la seconde est celle qui compte : une fiche corrompue
    /// **n'est jamais réécrite**. Ses octets contiennent peut-être encore le
    /// titre et le rattachement CRM de la réunion, et un `.json` réparable à la
    /// main vaut infiniment mieux qu'un `.json` propre et vide.
    private func loadForEditing(_ id: UUID) -> RecordingMetadata? {
        switch Self.readSidecar(root: root, identifier: id) {
        case .success(let metadata):
            return metadata
        case .failure(let fault):
            onProblem?(fault.editingNote(for: "\(id.uuidString).json"))
            return nil
        }
    }

    /// Renommage. Fonctionne pendant l'enregistrement : seul le `.json` change,
    /// le `.mp4` garde son nom d'UUID.
    /// Modification arbitraire du sidecar, relue depuis le disque à chaque fois.
    ///
    /// Relire plutôt que muter la copie en mémoire évite d'écraser un champ
    /// qu'un autre chemin vient d'écrire — le suivi CRM et la saisie de notes
    /// touchent le même fichier sans se coordonner.
    func mutate(_ id: UUID, _ change: (inout RecordingMetadata) -> Void) async {
        guard var metadata = loadForEditing(id) else { return }
        change(&metadata)
        publish(metadata, for: id)
    }

    func completeProcessing(id: UUID, originalBytes: Int64, segmentCount: Int) async {
        guard var metadata = loadForEditing(id) else { return }
        metadata.originalBytes = originalBytes
        metadata.segmentCount = segmentCount
        metadata.processedAt = .now
        write(metadata)
        await reload()
    }

    func updateTitle(_ title: String, for id: UUID) {
        guard var metadata = loadForEditing(id) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        metadata.title = trimmed.isEmpty ? nil : trimmed
        publish(metadata, for: id)
    }

    func updateNotes(_ notes: String, for id: UUID) {
        guard var metadata = loadForEditing(id) else { return }
        metadata.notes = notes
        publish(metadata, for: id)
    }

    /// Écrit, **puis** met la copie en mémoire à jour — dans cet ordre, et
    /// seulement si l'écriture a réussi.
    ///
    /// L'ordre inverse afficherait un titre que le disque n'a pas : la
    /// bibliothèque montrerait la saisie comme prise en compte, jusqu'au
    /// prochain balayage qui la ferait disparaître sans explication.
    private func publish(_ metadata: RecordingMetadata, for id: UUID) {
        guard write(metadata) else { return }

        if let index = recordings.firstIndex(where: { $0.id == id }) {
            recordings[index].metadata = metadata
        }
    }

    /// Corbeille, jamais suppression.
    ///
    /// Une heure de réunion effacée depuis un bouton de 24 points ne se
    /// récupère pas. `trashItem` rend l'annulation possible sans écrire une
    /// seule ligne de plus — c'est le Finder qui la porte.
    ///
    /// Et **une suppression refusée n'est pas une suppression** : elle se dit.
    /// Sans ça, le bouton « Supprimer » sur un fichier verrouillé ne faisait
    /// rien du tout, l'enregistrement réapparaissait au balayage suivant, et
    /// l'utilisateur pouvait tout aussi bien conclure que bran avait perdu la
    /// trace de sa réunion.
    func delete(_ recording: Recording) async {
        let manager = FileManager.default

        do {
            try manager.trashItem(at: recording.url, resultingItemURL: nil)
        } catch {
            onProblem?(
                "Enregistrement non supprimé (\(recording.url.lastPathComponent)) : \(error.localizedDescription)"
            )
        }

        // La fiche n'existe pas toujours — un `.mp4` déposé à la main n'en a
        // pas — et son absence n'est pas un échec de suppression.
        let sidecar = root.appending(path: recording.metadata.sidecarName)
        if manager.fileExists(atPath: sidecar.path(percentEncoded: false)) {
            do {
                try manager.trashItem(at: sidecar, resultingItemURL: nil)
            } catch {
                onProblem?(
                    "Fiche non supprimée (\(recording.metadata.sidecarName)) : \(error.localizedDescription)"
                )
            }
        }

        await reload()
    }

    /// Écrit la fiche, ou dit pourquoi elle n'a pas été écrite.
    ///
    /// **Trois `try?` d'affilée : le titre, les notes, l'heure de fin et le lien
    /// CRM pouvaient partir sans un mot.** Disque plein, dossier déplacé pendant
    /// la réunion, volume externe démonté — l'écriture échouait, la fonction
    /// rendait la main comme si de rien n'était, et l'interface continuait
    /// d'afficher ce que le disque ne contenait pas.
    ///
    /// Le résultat est consommé (`@discardableResult` pour les appels où l'échec
    /// est déjà rapporté par le canal d'échec).
    @discardableResult
    private func write(_ metadata: RecordingMetadata) -> Bool {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let data = try JSONEncoder.bran.encode(metadata)
            try data.write(to: root.appending(path: metadata.sidecarName), options: .atomic)
            return true
        } catch {
            onProblem?(
                "Fiche non enregistrée (\(metadata.sidecarName)) : \(error.localizedDescription). "
                + "Le titre, les notes, l'heure de fin et le lien CRM de cette réunion ne sont pas sur le disque."
            )
            return false
        }
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
