import AVFoundation
import BranCore
import BranSpeech
import Foundation
import Observation

// MARK: - Conformités

/// Une dictée se range comme n'importe quel contenu : une identité, une date,
/// un fichier lourd voisin. Le seul écart est le nom du champ —
/// `audioFileName` se lit mieux que `blobFileName` partout ailleurs dans
/// l'application, et c'est le nom que portent les fichiers déjà écrits.
///
/// La conformité est déclarée ici, et pas dans `BranSpeech`, parce que `BranApp`
/// est le seul module d'où `BranCore` et `BranSpeech` se voient tous les deux.
extension TranscriptEntry: ContentEntry {
    public var blobFileName: String? {
        get { audioFileName }
        set { audioFileName = newValue }
    }
}

/// `RetentionPolicy` satisfait déjà le protocole mot pour mot : elle n'a rien à
/// apprendre, et elle reste dans `BranSpeech` avec ses neuf tests.
extension RetentionPolicy: ContentRetentionPolicy {}

// MARK: - Le store

/// L'historique des dictées.
///
/// Une coquille au-dessus de `ContentStore` : tout ce qui est commun aux trois
/// bibliothèques — balayage du dossier, sidecars, purge, comptage des octets —
/// vit dans `BranCore`, où il est enfin testable. Ne reste ici que ce qui est
/// propre à de l'audio : l'écriture d'un `.wav` et sa relecture.
///
/// ```
/// ~/…/bran/Dictées/
///   2026-08-05T14-22-03-<uuid>.json   ← le texte, gardé pour toujours
///   2026-08-05T14-22-03-<uuid>.wav    ← l'audio, purgé après 7 jours
/// ```
@MainActor
@Observable
final class DictationStore {

    private let store: ContentStore<TranscriptEntry>

    init(root: @escaping @MainActor () -> URL, retention: RetentionPolicy = .default) {
        self.store = ContentStore(
            root: root,
            shape: ContentShape(
                folderName: "Dictées",
                blobExtension: "wav",
                // L'audio part, le texte reste. Réessayer et purger sont
                // couplés : au huitième jour le bouton « réessayer » doit être
                // désactivé avec sa raison, pas échouer.
                purge: .blobOnly,
                inaccessibleFolderMessage: "Dossier des dictées inaccessible",
                // Silence délibéré, à la différence des captures : l'audio est
                // un confort, le texte est déjà là, et une bannière d'erreur
                // après une dictée réussie ferait douter d'une transcription qui
                // n'a pourtant rien perdu.
                blobFailureMessage: nil
            ),
            retention: retention
        )
    }

    var entries: [TranscriptEntry] { store.entries }
    var problem: String? { store.problem }

    /// Octets occupés par l'audio conservé. Affiché dans les réglages : une
    /// rétention se règle mieux quand on voit ce qu'elle coûte.
    var audioBytes: Int64 { store.blobBytes }

    var folder: URL { store.folder }

    func setRetention(_ policy: RetentionPolicy) {
        store.setRetention(policy)
    }

    // MARK: - Lecture

    func reload() async {
        await store.reload()
    }

    // MARK: - Écriture

    /// Écrit l'audio puis le sidecar, dans cet ordre.
    ///
    /// Un tampon vide n'est pas une erreur : c'est une dictée sans son, et elle
    /// s'enregistre quand même — le texte est l'essentiel.
    func save(_ entry: TranscriptEntry, samples: [Float]?) async {
        guard let samples, samples.isEmpty == false else {
            await store.save(entry)
            return
        }
        await store.save(entry) { try Self.writeWave(samples, to: $0) }
    }

    /// Modifie une entrée en réécrivant son sidecar.
    func mutate(_ id: UUID, _ change: (inout TranscriptEntry) -> Void) {
        store.mutate(id, change)
    }

    func delete(_ entry: TranscriptEntry) async {
        await store.delete(entry)
    }

    func audioURL(for entry: TranscriptEntry) -> URL? {
        store.blobURL(for: entry)
    }

    // MARK: - Purge

    /// Supprime l'audio arrivé à échéance. Le texte n'est jamais touché.
    ///
    /// Appelée au lancement et une fois par jour — pas à chaque ouverture de la
    /// vue, où elle ne ferait que ralentir un affichage.
    @discardableResult
    func purgeExpiredAudio(now: Date = .now) async -> Int {
        await store.purgeExpired(now: now)
    }

    func expiryDate(for entry: TranscriptEntry) -> Date {
        store.expiryDate(for: entry)
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
