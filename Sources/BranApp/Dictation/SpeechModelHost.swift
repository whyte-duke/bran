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

    /// Dossier du modèle, tel que FluidAudio le définit **lui-même**.
    ///
    /// **Ce chemin était écrit à la main, et il désignait le mauvais dossier.**
    /// Il valait `Application Support/FluidAudio/Models`, c'est-à-dire le parent
    /// du dossier du modèle et non le modèle. Trois usages en dépendent, et deux
    /// se trompaient en silence :
    ///
    /// - `isDownloaded` marchait, par un hasard heureux : `AsrModels.modelsExist`
    ///   remonte d'un cran avant d'ajouter le nom du dépôt, si bien que la
    ///   question tombait au bon endroit ;
    /// - `downloadedSize` mesurait le contenu de `Models/`, qui ne contient pas
    ///   le modèle. Sur cette machine il y annonçait 483 Mo — le poids de
    ///   fichiers hérités d'une ancienne version de FluidAudio — au lieu des
    ///   461 Mo du modèle réellement chargé. Sur un Mac neuf, ce dossier n'existe
    ///   même pas : la ligne aurait affiché « 0 octet » sous un modèle installé ;
    /// - `deleteDownloadedModel` effaçait ce même `Models/`. Sur un Mac neuf,
    ///   « Supprimer le modèle » n'aurait donc **rien** supprimé : aucun octet
    ///   libéré, `isDownloaded` toujours vrai, l'interface toujours sur
    ///   « installé », et pas un message pour l'expliquer. Un bouton qui ne fait
    ///   rien et ne le dit pas est le pire des deux mondes.
    ///
    /// La valeur vient désormais de la bibliothèque et non d'une chaîne recopiée.
    /// C'est elle qui décide où elle écrit ; le jour où elle change d'avis — ce
    /// qu'elle a manifestement déjà fait, vu les fichiers hérités — bran suit
    /// sans qu'on ait à s'en apercevoir.
    static var modelDirectory: URL {
        AsrModels.defaultCacheDirectory(for: .v3)
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

    /// L'emplacement où une version antérieure de FluidAudio déposait le modèle.
    ///
    /// `Application Support/FluidAudio/<dépôt>`, sans le `Models/` intermédiaire.
    /// C'est là qu'il atterrissait tant que `modelDirectory` était écrit à la
    /// main, et c'est là qu'il se trouve encore sur toute machine ayant fait
    /// tourner une version précédente de bran.
    private static var legacyModelDirectory: URL {
        URL.applicationSupportDirectory
            .appending(path: "FluidAudio", directoryHint: .isDirectory)
            .appending(path: modelDirectory.lastPathComponent, directoryHint: .isDirectory)
    }

    /// Récupère un modèle déposé à l'ancien emplacement, plutôt que de le
    /// retélécharger.
    ///
    /// **Corriger `modelDirectory` déplaçait la question sans la poser** : bran
    /// se serait mis à chercher au bon endroit un fichier qui est à l'ancien, en
    /// aurait conclu « absent », et aurait redemandé 461 Mo à quelqu'un qui les a
    /// déjà sur son disque — pour écrire une copie identique deux dossiers plus
    /// bas et laisser la première pourrir là où elle est. Un correctif dont le
    /// prix est un gigaoctet n'est pas un correctif.
    ///
    /// Un `moveItem`, donc : instantané, sur le même volume, et sans jamais deux
    /// copies. Il ne s'exécute que si la destination n'a pas déjà le modèle —
    /// dans ce cas l'ancien dossier est un doublon, et bran n'y touche pas : ce
    /// sont des fichiers dans le dossier d'un autre, et les effacer sans le dire
    /// n'est pas à lui d'en décider.
    static func adoptLegacyModelIfNeeded() {
        let manager = FileManager.default
        let legacy = legacyModelDirectory
        guard legacy != modelDirectory,
              isDownloaded == false,
              manager.fileExists(atPath: legacy.path(percentEncoded: false))
        else { return }

        do {
            try manager.createDirectory(
                at: modelDirectory.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try manager.moveItem(at: legacy, to: modelDirectory)
            FeatureLog.record("modèle de dictée — repris de l'ancien emplacement, aucun téléchargement")
        } catch {
            // Rien n'est perdu : le modèle est resté où il était, et le pire qui
            // puisse arriver est un téléchargement que l'utilisateur aurait
            // voulu s'épargner. Ça se dit, ça ne bloque rien.
            FeatureLog.record("modèle de dictée — reprise impossible : \(error.localizedDescription)")
        }
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
