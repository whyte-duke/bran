import BranSpeech
import FluidAudio
import Foundation
import Observation
import Synchronization

/// La vie du modèle Parakeet : téléchargement, chargement, déchargement.
///
/// **Le chargement anticipé est l'astuce centrale de toute la fonctionnalité.**
/// Le modèle se charge dès l'appui sur le raccourci, en parallèle de la capture,
/// pas au relâchement :
///
/// ```
/// appui ─┬──► capture micro ─────────────────► relâche ──► transcribe ──► colle
///        │    (le niveau s'affiche tout de suite)
///        └──► chargement si froid
///             ├─ chaud  : 0 s
///             └─ froid  : masqué par la parole
/// ```
///
/// On parle toujours plus de deux secondes : le modèle est chaud avant la fin
/// de la phrase.
///
/// **Mesuré sur un MacBook Pro M2 Pro**, `swift run BranSpike speech` :
/// 483 Mo sur le disque, 42 Mo d'empreinte mémoire du processus après
/// chargement et transcription, et **67× le temps réel** — 10,5 s d'audio
/// transcrits en 0,16 s, soit environ 3,6 s pour quatre minutes de parole.
///
/// L'empreinte mesurée est donc bien plus faible que ce qu'on lit d'habitude sur
/// les modèles CoreML : le Neural Engine travaille sur des poids projetés en
/// mémoire, que le processus ne paie pas. Le déchargement reste offert, mais il
/// libère surtout les contextes CoreML, pas des gigaoctets — d'où un délai par
/// défaut confortable plutôt qu'agressif.
@MainActor
@Observable
final class SpeechModelHost {

    /// Où en est le modèle.
    ///
    /// **Il n'y a délibérément pas d'état « en cours de vérification ».** Savoir
    /// si le modèle est là est une lecture de dossier, immédiate : afficher
    /// « Vérification… » ne décrivait rien de réel et faisait croire à une
    /// attente. L'ancien `.unknown` servait en fait à dire « sur le disque mais
    /// pas encore en mémoire », ce qui est exactement `.installed`.
    enum Availability: Equatable {
        /// Les fichiers ne sont pas sur le disque.
        case absent
        case downloading(Double)
        /// Sur le disque, pas encore en mémoire. **Utilisable** : le chargement
        /// se fait tout seul au premier appui sur le raccourci.
        case installed
        case loading
        /// Chargé en mémoire : la première dictée n'attendra rien.
        case ready
        case failed(String)

        /// Peut-on dicter maintenant ? Vrai dès que les fichiers sont là — le
        /// chargement n'est pas une condition, juste une latence.
        var isUsable: Bool { self == .installed || self == .ready }

        /// Le modèle est-il déjà en mémoire ?
        var isReady: Bool { self == .ready }

        var description: String {
            switch self {
            case .absent: "Modèle à télécharger — 483 Mo, une seule fois"
            case .downloading(let fraction):
                "Téléchargement \((fraction * 100).formatted(.number.precision(.fractionLength(0)))) %"
            case .installed: "Modèle installé, prêt à l'emploi"
            case .loading: "Chargement du modèle…"
            case .ready: "Modèle chargé en mémoire"
            case .failed(let reason): reason
            }
        }
    }

    /// Renseigné dès la construction, pas après une vérification asynchrone :
    /// c'est une lecture de dossier, et l'interface ne doit jamais afficher un
    /// état d'attente pour quelque chose d'immédiat.
    private(set) var availability: Availability = SpeechModelHost.isDownloaded ? .installed : .absent
    /// Dernier temps de chargement observé, affiché dans les réglages. Un
    /// chiffre mesuré vaut mieux qu'une promesse.
    private(set) var lastLoadDuration: TimeInterval?
    private(set) var lastTranscribeDuration: TimeInterval?

    /// Le modèle reste chaud ce temps-là après la dernière dictée.
    var idleUnloadDelay: TimeInterval = 900

    private var manager: AsrManager?
    private var loadTask: Task<AsrManager, Error>?
    private var unloadTask: Task<Void, Never>?

    static let modelName = "parakeet-tdt-0.6b-v3"

    // MARK: - Présence sur le disque

    /// Dossier où FluidAudio dépose les modèles. Exposé pour que les réglages
    /// puissent l'ouvrir dans le Finder, et pour mesurer la place occupée.
    static var modelDirectory: URL {
        URL.applicationSupportDirectory
            .appending(path: "FluidAudio", directoryHint: .isDirectory)
            .appending(path: "Models", directoryHint: .isDirectory)
    }

    /// Trois situations distinctes, et il faut les distinguer dans l'interface :
    /// chargé en mémoire, présent sur le disque mais froid, ou pas installé.
    /// Seule la troisième demande une connexion.
    func refreshAvailability() {
        if manager != nil {
            availability = .ready
        } else {
            availability = Self.isDownloaded ? .installed : .absent
        }
    }

    static var isDownloaded: Bool {
        AsrModels.modelsExist(at: modelDirectory)
    }

    /// Place occupée par le modèle, pour que « supprimer le modèle » ait un
    /// chiffre en face plutôt qu'un acte de foi.
    static var downloadedSize: Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: modelDirectory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            total += Int64(size)
        }
        return total
    }

    // MARK: - Chargement

    /// Démarre le chargement sans attendre. Appelé dès l'appui sur le raccourci.
    func warmUp() {
        unloadTask?.cancel()
        unloadTask = nil
        guard manager == nil, loadTask == nil else { return }
        Task { _ = try? await load() }
    }

    /// Charge le modèle, ou rend celui déjà chargé.
    ///
    /// Les appels concurrents partagent la même tâche : deux dictées lancées
    /// coup sur coup ne doivent pas télécharger deux fois deux gigaoctets.
    @discardableResult
    func load() async throws -> AsrManager {
        if let manager { return manager }
        if let loadTask { return try await loadTask.value }

        let started = Date()
        let wasDownloaded = Self.isDownloaded
        availability = wasDownloaded ? .loading : .downloading(0)

        // `self` est capturé une fois, ici, plutôt que dans chaque fermeture :
        // le handler de progression est appelé depuis une file quelconque, et
        // Swift 6 refuse d'y capturer une variable du contexte englobant.
        // FluidAudio rapporte la progression **par fichier**, et le modèle en
        // compte plusieurs : la fraction retombe à zéro à chaque nouveau. Une
        // barre qui recule six fois donne l'impression que rien n'avance.
        //
        // On compte donc les fichiers terminés et on n'affiche jamais une valeur
        // inférieure à la précédente. Le nombre exact de fichiers n'étant pas
        // annoncé, la barre est approximative — mais monotone, ce qui est la
        // seule propriété qu'on lui demande vraiment.
        let progress = Mutex(DownloadTally())
        let report: @Sendable (Double) -> Void = { [weak self] fraction in
            guard wasDownloaded == false else { return }
            let overall = progress.withLock { $0.advance(to: fraction) }
            Task { @MainActor in self?.availability = .downloading(overall) }
        }
        let markLoading: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in self?.availability = .loading }
        }

        let task = Task<AsrManager, Error> {
            let models = try await AsrModels.downloadAndLoad(
                to: Self.modelDirectory,
                version: .v3,
                progressHandler: { progress in report(progress.fractionCompleted) }
            )

            markLoading()

            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            return manager
        }

        loadTask = task

        do {
            let loaded = try await task.value
            manager = loaded
            loadTask = nil
            lastLoadDuration = Date().timeIntervalSince(started)
            availability = .ready
            return loaded
        } catch {
            loadTask = nil
            availability = .failed(Self.explain(error))
            throw error
        }
    }

    // MARK: - Transcription

    struct Outcome: Sendable {
        var text: String
        var confidence: Double?
        var processingTime: TimeInterval
    }

    func transcribe(_ samples: [Float], language: SpeechLanguage) async throws -> Outcome {
        let manager = try await load()
        let started = Date()

        // Un état de décodeur neuf par dictée. Le réutiliser ferait fuiter le
        // contexte linguistique d'une phrase à la suivante — pratique en
        // streaming, faux ici : chaque dictée est indépendante.
        var state = try TdtDecoderState()

        let hint = language.code.flatMap { Language(rawValue: $0) }
        let result = try await manager.transcribe(samples, decoderState: &state, language: hint)

        let elapsed = Date().timeIntervalSince(started)
        lastTranscribeDuration = elapsed
        scheduleUnload()

        return Outcome(
            text: result.text.trimmingCharacters(in: .whitespacesAndNewlines),
            confidence: Double(result.confidence),
            processingTime: elapsed
        )
    }

    // MARK: - Déchargement

    private func scheduleUnload() {
        unloadTask?.cancel()
        guard idleUnloadDelay > 0 else { return }

        unloadTask = Task { [weak self, delay = idleUnloadDelay] in
            try? await Task.sleep(for: .seconds(delay))
            guard Task.isCancelled == false else { return }
            await self?.unload()
        }
    }

    func unload() async {
        unloadTask?.cancel()
        unloadTask = nil
        guard let manager else { return }
        await manager.cleanup()
        self.manager = nil
        availability = Self.isDownloaded ? .installed : .absent
    }

    /// Supprime les fichiers du modèle. Réversible : un prochain usage les
    /// retéléchargera.
    func deleteDownloadedModel() async {
        await unload()
        try? FileManager.default.removeItem(at: Self.modelDirectory)
        availability = .absent
    }

    // MARK: -

    private static func explain(_ error: Error) -> String {
        let text = error.localizedDescription
        if (error as NSError).domain == NSURLErrorDomain {
            return "Téléchargement impossible — vérifiez la connexion. (\(text))"
        }
        return text
    }
}
