import AVFoundation
import BranSpeech
import Foundation
import Observation

/// L'historique des dictées.
///
/// Même parti pris que `RecordingStore` : **le dossier est la source de
/// vérité**. Pas de base de données à côté du disque — deux sources de vérité
/// divergent toujours, et c'est l'utilisateur qui arbitre au pire moment. Ici
/// l'utilisateur peut supprimer un `.wav` dans le Finder ; au prochain scan,
/// l'entrée existe toujours mais devient non-réessayable. C'est exactement le
/// comportement souhaité.
///
/// ```
/// ~/…/bran/Dictées/
///   2026-08-05T14-22-03-<uuid>.json   ← le texte, gardé pour toujours
///   2026-08-05T14-22-03-<uuid>.wav    ← l'audio, purgé après 7 jours
/// ```
@MainActor
@Observable
final class DictationStore {

    private(set) var entries: [TranscriptEntry] = []
    private(set) var problem: String?

    /// Octets occupés par l'audio conservé. Affiché dans les réglages : une
    /// rétention se règle mieux quand on voit ce qu'elle coûte.
    private(set) var audioBytes: Int64 = 0

    /// Le dossier suit celui des enregistrements : changer la destination dans
    /// les réglages déplace les deux d'un coup. Une fermeture plutôt qu'une
    /// `URL` figée, sinon le store garderait l'ancien dossier jusqu'au
    /// prochain lancement.
    private let root: @MainActor () -> URL
    private var retention: RetentionPolicy

    init(root: @escaping @MainActor () -> URL, retention: RetentionPolicy = .default) {
        self.root = root
        self.retention = retention
    }

    var folder: URL {
        root().appending(path: "Dictées", directoryHint: .isDirectory)
    }

    func setRetention(_ policy: RetentionPolicy) {
        retention = policy
        Task { await purgeExpiredAudio() }
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
            var found: [TranscriptEntry] = []
            var bytes: Int64 = 0

            for url in files {
                if url.pathExtension == "json",
                   let data = try? Data(contentsOf: url),
                   var entry = try? decoder.decode(TranscriptEntry.self, from: data) {

                    // Un `.wav` supprimé à la main dans le Finder doit rendre
                    // l'entrée non-réessayable, pas planter au clic.
                    if let name = entry.audioFileName,
                       FileManager.default.fileExists(atPath: folder.appending(path: name).path(percentEncoded: false)) == false {
                        entry.audioFileName = nil
                    }
                    found.append(entry)
                } else if url.pathExtension == "wav" {
                    bytes += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                }
            }

            entries = found.sorted { $0.createdAt > $1.createdAt }
            audioBytes = bytes
            problem = nil
        } catch {
            problem = "Dossier des dictées inaccessible : \(error.localizedDescription)"
        }
    }

    // MARK: - Écriture

    /// Écrit l'audio puis le sidecar, dans cet ordre.
    ///
    /// L'ordre compte : un `.json` qui référence un `.wav` inexistant serait
    /// une entrée qui promet un réessai impossible. L'inverse — un `.wav`
    /// orphelin — se nettoie tout seul à la purge.
    func save(_ entry: TranscriptEntry, samples: [Float]?) async {
        var stored = entry

        if let samples, samples.isEmpty == false {
            let name = "\(Self.stamp(entry.createdAt))-\(entry.id.uuidString).wav"
            do {
                try Self.writeWave(samples, to: folder.appending(path: name))
                stored.audioFileName = name
            } catch {
                // L'audio est un confort ; le texte est l'essentiel. On garde
                // l'entrée sans son audio plutôt que de tout perdre.
                stored.audioFileName = nil
            }
        }

        write(stored)
        entries.insert(stored, at: 0)
        await refreshAudioBytes()
    }

    /// Modifie une entrée en relisant d'abord le disque, comme `RecordingStore`.
    func mutate(_ id: UUID, _ change: (inout TranscriptEntry) -> Void) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        var entry = entries[index]
        change(&entry)
        entries[index] = entry
        write(entry)
    }

    func delete(_ entry: TranscriptEntry) async {
        if let name = entry.audioFileName {
            try? FileManager.default.removeItem(at: folder.appending(path: name))
        }
        try? FileManager.default.removeItem(at: sidecarURL(for: entry))
        entries.removeAll { $0.id == entry.id }
        await refreshAudioBytes()
    }

    func audioURL(for entry: TranscriptEntry) -> URL? {
        entry.audioFileName.map { folder.appending(path: $0) }
    }

    // MARK: - Purge

    /// Supprime l'audio arrivé à échéance. Le texte n'est jamais touché.
    ///
    /// Appelée au lancement et une fois par jour — pas à chaque ouverture de la
    /// vue, où elle ne ferait que ralentir un affichage.
    @discardableResult
    func purgeExpiredAudio(now: Date = .now) async -> Int {
        let expired = retention.entriesToPurge(from: entries, now: now)
        guard expired.isEmpty == false else { return 0 }

        for entry in expired {
            if let name = entry.audioFileName {
                try? FileManager.default.removeItem(at: folder.appending(path: name))
            }
            mutate(entry.id) { $0.audioFileName = nil }
        }

        await refreshAudioBytes()
        return expired.count
    }

    func expiryDate(for entry: TranscriptEntry) -> Date {
        retention.expiryDate(for: entry)
    }

    // MARK: - Interne

    private func write(_ entry: TranscriptEntry) {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let data = try Self.encoder.encode(entry)
            try data.write(to: sidecarURL(for: entry), options: .atomic)
        } catch {
            problem = "Écriture impossible : \(error.localizedDescription)"
        }
    }

    private func sidecarURL(for entry: TranscriptEntry) -> URL {
        folder.appending(path: "\(Self.stamp(entry.createdAt))-\(entry.id.uuidString).json")
    }

    private func refreshAudioBytes() async {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]
        )) ?? []

        audioBytes = files
            .filter { $0.pathExtension == "wav" }
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

    // MARK: - Écriture du WAV

    /// PCM 16 bits mono à 16 kHz : 32 ko la seconde, lisible par tout, et c'est
    /// exactement ce qu'on redonnera au modèle en cas de réessai.
    private static func writeWave(_ samples: [Float], to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: SpeechAudioFormat.sampleRate,
            AVNumberOfChannelsKey: Int(SpeechAudioFormat.channelCount),
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]

        let file = try AVAudioFile(forWriting: url, settings: settings)

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: SpeechAudioFormat.sampleRate,
            channels: SpeechAudioFormat.channelCount,
            interleaved: false
        ) else { return }

        // Par blocs : un tableau de dix minutes fait 38 Mo, et `AVAudioFile`
        // n'aime pas les tampons démesurés.
        let chunk = 16_384
        var offset = 0
        while offset < samples.count {
            let count = min(chunk, samples.count - offset)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
                  let channel = buffer.floatChannelData?[0]
            else { break }

            samples.withUnsafeBufferPointer { source in
                channel.update(from: source.baseAddress! + offset, count: count)
            }
            buffer.frameLength = AVAudioFrameCount(count)
            try file.write(from: buffer)
            offset += count
        }
    }

    /// Relit un `.wav` pour un réessai.
    static func readSamples(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: SpeechAudioFormat.sampleRate,
            channels: SpeechAudioFormat.channelCount,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)
        ) else { return [] }

        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }
}
