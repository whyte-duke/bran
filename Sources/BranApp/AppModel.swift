import BranCore
import Foundation
import Observation

/// Câblage : détecteurs → `SessionResolver` → proposition → `RecordingEngine`.
///
/// La différence avec le plan d'origine tient en un mot : le résolveur ne
/// déclenche plus l'enregistrement, il le *propose*. Rejoindre une réunion et
/// attendre dix minutes qu'un client arrive est le cas normal, pas l'exception,
/// et cette attente n'a rien à faire dans un fichier.
@MainActor
@Observable
public final class AppModel {

    /// 5 s. `CGWindowListCopyWindowInfo` coûte ~1 ms ; descendre plus bas
    /// n'apporte rien, une réunion ne commence pas à la seconde près.
    private static let pollInterval = Duration.seconds(5)

    public let permissions = PermissionsService()
    public let engine: RecordingEngine
    let store = RecordingStore()
    let loginItem = LoginItemService()
    let storage = StorageLocation()
    let uploads: UploadService
    let directory: MeetingDirectory

    /// La dictée. Volontairement autonome : elle a sa propre machine à états,
    /// son propre stockage et ses propres autorisations. Le seul lien avec
    /// l'enregistreur de réunions est le dossier de destination — et, un jour,
    /// le modèle Parakeet, qui pourrait transcrire les closings sur place au
    /// lieu de les téléverser.
    let dictationSettings = DictationSettings()
    let dictation: DictationController

    /// La capture de texte à l'écran. Même autonomie que la dictée, et le même
    /// unique lien : le dossier de destination.
    let snapshotSettings = SnapshotSettings()
    let snapshot: SnapshotController

    /// La veille des sessions parallèles. Même autonomie encore : son propre
    /// résolveur, son propre journal, ses propres réglages.
    ///
    /// Elle a un second lien avec l'enregistreur, et un seul : elle doit savoir
    /// se taire quand une réunion est en cours ou détectée (correctif CR-4).
    /// Ce lien passe par une **fermeture**, comme le dossier de destination des
    /// deux autres — le veilleur n'a pas à savoir ce qu'est une réunion, et
    /// l'enregistreur n'a pas à savoir qu'un veilleur existe.
    let watchSettings = WatchSettings()
    let watch: WatchController

    /// L'éveil : empêcher le Mac de s'endormir, tant qu'on le demande.
    ///
    /// Même autonomie que les trois modules précédents, et c'est le plus
    /// autonome de tous : il ne connaît ni les réunions, ni la dictée, ni le
    /// veilleur. Il tient une assertion du gestionnaire d'énergie et un état.
    /// Son seul lien avec le reste est la fermeture d'échec, câblée plus bas —
    /// bran a déjà un canal pour dire ce qui a raté, il n'en aura pas un second.
    let awakeSettings = AwakeSettings()
    let awake: AwakeController

    /// Ce que bran coûte, en processeur et en mémoire.
    ///
    /// **La contrainte C10 dit qu'un plafond CPU/énergie est un critère de
    /// succès, pas un détail** — et elle n'avait jamais eu d'instrument. Le
    /// moniteur est cet instrument, et il est aussi découplé que les trois
    /// autres modules : il ne connaît ni Parakeet, ni le veilleur, ni les
    /// réunions. Ce qu'il affiche sous « En ce moment » lui arrive par une
    /// fermeture, câblée plus bas.
    let meter = ResourceMeter()

    /// Le journal de bord. **La seule chose du modèle qui lise les quatre
    /// sources d'un coup** — et elle ne les possède pas : elle relit le journal
    /// du veilleur en lecture seule, et la vue lui passe les repères des trois
    /// autres stores. Aucun module n'apprend l'existence des trois autres.
    let week: WeekLoader

    /// Le guet du clavier, **partagé** par la dictée et la capture. Un seul
    /// `CGEventTap` pour toute l'application : deux taps doubleraient le
    /// travail à chaque frappe du système et pourraient mourir séparément.
    private let shortcuts = ShortcutRouter()

    private var notchPresenter: NotchPresenter?

    /// Le panneau du veilleur. Son propre `NSPanel`, distinct de celui de
    /// l'encoche : deux panneaux ne se volent rien, alors que deux présentateurs
    /// pour un même panneau, si.
    private var attention: AttentionOverlay?

    /// Réunion détectée, en attente d'une décision de l'utilisateur.
    /// Non nil ≠ enregistrement en cours.
    public private(set) var pendingMeeting: MeetingRef?

    public private(set) var recordingStartedAt: Date?

    /// Rafraîchi chaque seconde pendant l'enregistrement : c'est ce qui rend le
    /// menu vivant au lieu d'afficher une durée figée.
    public private(set) var elapsed: Duration = .zero

    /// Poids du fichier en cours d'écriture, relevé à chaque seconde.
    /// C'est la réponse à « ça pèse combien pour l'instant », qu'aucun autre
    /// écran ne donne pendant que ça tourne.
    public private(set) var currentFileSize: Int64 = 0

    /// Titre de la session en cours, modifiable en direct.
    public var currentTitle: String = "" {
        didSet {
            guard let id = engine.state.meeting?.id, currentTitle != oldValue else { return }
            store.updateTitle(currentTitle, for: id)
        }
    }

    public var lastFailure: String?

    /// Ajoute un motif d'échec sans effacer le précédent.
    ///
    /// Deux pannes peuvent tomber dans la même seconde — un arrêt qui échoue,
    /// puis des segments que le disque refuse de rendre — et ce sont deux choses
    /// à réparer, pas une. `FailureBanner` borne le fil à deux lignes et
    /// dédoublonne : sans ça, un dossier en lecture seule ferait grossir le
    /// bandeau à chaque frappe dans le champ « titre ».
    func report(_ message: String) {
        lastFailure = FailureBanner.appending(message, to: lastFailure)
    }

    /// Porté par le modèle et non par la vue : les réglages s'ouvrent depuis la
    /// colonne, depuis une section, et depuis un message d'erreur. Trois
    /// endroits, un seul état.
    public var showsSettings = false

    public var quality: QualityPreset {
        didSet {
            UserDefaults.standard.set(quality.rawValue, forKey: Self.qualityKey)
            Task { await capture.updateQuality(quality) }
        }
    }

    private static let qualityKey = "bran.quality"

    private let capture: CaptureSession
    private let processor = PostProcessor()
    /// Depuis quand une proposition n'a plus de signal à l'écran.
    /// RDV reconnu par son code Meet. Rapprochement certain : pas besoin de
    /// demander à qui rattacher l'audio.
    private(set) var linkedBooking: CRMBooking?

    private var proposalMissingSince: Date?

    /// Délai avant d'abandonner une proposition dont la fenêtre a disparu.
    ///
    /// Court, à l'inverse des 120 s qui protègent un enregistrement en cours :
    /// fermer l'onglet Meet doit revenir à cliquer « Pas cette fois ». Les
    /// quinze secondes évitent seulement qu'un changement d'onglet fasse
    /// clignoter la proposition.
    private static let proposalGrace: TimeInterval = 15

    private var pausedAt: Date?
    private var accumulatedPause: TimeInterval = 0
    private let notifications = NotificationService()
    private let detector = WindowTitleDetector()
    private var resolver = SessionResolver()
    private var pollTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?

    public init(capture: CaptureSession = CaptureSession()) {
        let stored = UserDefaults.standard.string(forKey: Self.qualityKey)
        self.quality = stored.flatMap(QualityPreset.init(rawValue:)) ?? .elevee
        self.capture = capture
        self.engine = RecordingEngine(backend: capture)
        self.uploads = UploadService(store: store)
        self.directory = MeetingDirectory(configuration: uploads.configuration)
        self.awake = AwakeController(settings: awakeSettings)

        let settings = self.dictationSettings
        let dictationStore = DictationStore(
            root: { [storage] in storage.root },
            retention: settings.retention
        )
        self.dictation = DictationController(
            settings: settings,
            store: dictationStore,
            monitor: shortcuts.monitor
        )

        let snapshotSettings = self.snapshotSettings
        let snapshotStore = SnapshotStore(
            root: { [storage] in storage.root },
            retention: snapshotSettings.retention
        )
        self.snapshot = SnapshotController(settings: snapshotSettings, store: snapshotStore)
        shortcuts.attach(dictation: dictation, snapshot: snapshot)

        let watchSettings = self.watchSettings
        let watchStore = WatchStore(
            root: { [storage] in storage.root },
            retention: watchSettings.retention,
            tickInterval: watchSettings.tickInterval
        )
        self.watch = WatchController(settings: watchSettings, store: watchStore)
        self.week = WeekLoader(folder: { watchStore.folder })

        Task { [weak self, capture] in
            for await reason in capture.failures {
                guard let self else { return }
                self.engine.reportFailure(reason)
                self.report(reason)
            }
        }

        // La bibliothèque parle par le canal d'échec unique de bran, comme
        // `AwakeController` : une fiche qu'on n'a pas pu écrire, une fiche qu'on
        // n'a pas pu relire, un fichier que la corbeille a refusé. Une
        // revalidation de la destination suit, parce qu'une écriture refusée est
        // presque toujours un dossier cassé — et c'est dans les réglages qu'on
        // va le réparer.
        store.onProblem = { [weak self] reason in
            guard let self else { return }
            report(reason)
            storage.validate()
        }

        // La conclusion d'une session passe par ici, et par ici seulement.
        // C'est la machine qui décide *quand* — voir `concludeSession`, et
        // `RecordingEngine.onSettled` pour ce que ça répare.
        engine.onSettled = { [weak self] meeting, verdict in
            guard let self else { return }

            // Les segments sont relevés MAINTENANT, de façon synchrone, pas
            // dans la tâche : un nouveau départ appelle `segments.removeAll()`,
            // et il suffirait que l'utilisateur relance avant que la tâche ne
            // s'exécute pour que les morceaux de la session précédente
            // disparaissent de la liste sans avoir été fusionnés.
            let segments = verdict.consumesSegments ? engine.segments : []
            engine.clearSegments()

            Task { await self.concludeSession(meeting, verdict: verdict, segments: segments) }
        }

        notifications.onStartRequested = { [weak self] in
            self?.startPendingRecording()
        }
        notifications.configure()

        // CR-4 : « une réunion est en cours **ou détectée** ». Le prédicat est
        // volontairement plus large qu'un enregistrement — ce dont il protège,
        // c'est un partage d'écran, et on peut partager son écran sans que bran
        // enregistre quoi que ce soit.
        watch.isMuted = { [weak self] in
            guard let self else { return false }
            return hasOpenSession || pendingMeeting != nil
        }

        Task { await capture.updateQuality(quality) }
        applyStorageRoot()

        // Le journal vit à côté des enregistrements, et il est armé avant toute
        // fonction : il ne doit pas dépendre de l'ordre de construction.
        FeatureLog.folder = storage.root.appending(path: "Journal", directoryHint: .isDirectory)

        // **Avant les fonctions, parce que ça décide de ce que macOS affiche.**
        // `Info.plist` déclare `LSUIElement = false`, donc l'application démarre
        // toujours avec une icône dans le Dock. Celui qui l'a retirée dans les
        // réglages doit la voir disparaître au lancement suivant, pas seulement
        // le jour où il rouvre les réglages.
        DockPresence.apply()

        directory.start()
        startDictation()
        startSnapshot()
        startWatch()
        startAwake()
        startMeter()

        // La surveillance est permanente. Il n'y a pas de raison de la
        // suspendre : elle ne fait qu'observer des titres de fenêtres, et une
        // surveillance qu'on oublie d'activer ne sert à rien.
        startWatching()
    }

    // MARK: - Dictée

    private func startDictation() {
        notchPresenter = NotchPresenter(dictation: dictation, snapshot: snapshot)
        dictation.applySettings()
        dictation.host.refreshAvailability()

        if dictationSettings.isEnabled {
            // Une autorisation d'Accessibilité peut avoir été retirée entre deux
            // lancements. Si l'installation échoue, le réglage repasse à « non »
            // et l'interface le dira — plutôt qu'un interrupteur qui prétend
            // surveiller sans rien surveiller.
            dictation.setEnabled(true)
        }

        Task { [dictation] in
            await dictation.store.reload()
            // La purge tourne au lancement, pas à chaque ouverture d'une vue où
            // elle ne ferait que ralentir un affichage.
            await dictation.store.purgeExpiredAudio()
        }
    }

    /// Tout est-il en place — les trois capacités, modèle compris ?
    ///
    /// Sert à deux endroits : l'intitulé de l'entrée de menu, et la décision
    /// d'ouvrir l'accueil au lancement. Un accueil qui ne s'ouvre jamais
    /// n'accueille personne, et c'est exactement ce qui se passait.
    /// L'accueil a-t-il déjà été montré **pendant ce lancement**. Voir
    /// `LibraryView`, où la règle est écrite : une fois, pas à chaque création
    /// de fenêtre.
    var hasShownWelcome = false

    var isFullyReady: Bool {
        permissions.canRecord
            && HotkeyMonitor.isTrusted
            && dictation.host.availability.isUsable
    }

    /// Le détail, pour le journal. Un accueil qui ne s'ouvre pas se diagnostique
    /// mal sans savoir laquelle des trois conditions était déjà remplie.
    var readinessDescription: String {
        "écran=\(permissions.screenRecording) micro=\(permissions.microphone) "
        + "accessibilité=\(HotkeyMonitor.isTrusted) "
        + "modèle=\(dictation.host.availability)"
    }

    // MARK: - Capture de texte

    private func startSnapshot() {
        snapshot.applySettings()
        // Vision est vérifié au lancement sur une image fabriquée en mémoire.
        // Cent millisecondes, aucune capture d'écran, et une ligne de journal qui
        // dirait immédiatement si le moteur redevenait muet.
        snapshot.selfTest("au démarrage")

        if snapshotSettings.isEnabled {
            enableSnapshot(true)
        }

        Task { [snapshot] in
            await snapshot.store.reload()
            await snapshot.store.purgeExpiredImages()
        }
    }

    // MARK: - Veille

    private func startWatch() {
        // Le panneau se tait pendant que l'encoche travaille. Une fermeture, et
        // aucune propriété partagée : `NotchPresenter` garde son panneau, le
        // veilleur a le sien.
        attention = AttentionOverlay(isSuppressed: { [weak self] in
            guard let self else { return true }
            return dictation.isBusy || snapshot.isBusy
        })

        // Le clic sur la pilule est le geste de retour. Un échec passe par
        // `lastFailure`, comme tous les autres : le panneau n'a pas de place
        // pour l'expliquer, et un geste qui échoue en silence est ce qui apprend
        // à ne plus cliquer.
        attention?.onReturn = { [weak self] identity in
            guard let self else { return }
            switch LaneReturn.go(to: identity) {
            case .raised:
                lastFailure = nil
            case .appOnly(let reason), .notFound(let reason):
                report(reason)
            }
        }

        watch.onVerdict = { [weak self] verdict in
            guard let self else { return }
            attention?.update(verdict, enabled: watchSettings.showsOverlay)
        }

        watch.applySettings()

        Task { [watch] in
            await watch.store.reload()
            // La purge tourne au lancement, comme pour les deux autres modules :
            // à l'ouverture d'une vue, elle ne ferait que ralentir un affichage.
            await watch.store.purgeExpired()
        }
    }

    // MARK: - L'éveil

    /// Une fermeture d'échec, et rien d'autre.
    ///
    /// Un gestionnaire d'énergie qui refuse l'assertion est rare, mais c'est le
    /// seul cas où l'interface pourrait prétendre tenir le Mac éveillé sans le
    /// faire. Il repart donc par le même canal que les autres échecs de bran, et
    /// s'affiche au même endroit.
    private func startAwake() {
        awake.onFailure = { [weak self] reason in
            self?.report(reason)
        }
        awake.start()
    }

    // MARK: - Le moniteur

    /// Câble « En ce moment » et démarre la boucle.
    ///
    /// **Ce sont des états simultanés, pas des causes.** Personne n'a mesuré que
    /// le chargement de Parakeet explique ces 104 % — c'est très probable, ça
    /// n'est pas démontré, et un panneau qui affirmerait une causalité qu'il n'a
    /// pas mesurée mentirait sur ce qu'il sait.
    ///
    /// Chaque ligne n'apparaît que lorsqu'elle a quelque chose à dire. En
    /// particulier, un modèle `.installed` — présent sur le disque mais pas en
    /// mémoire — ne coûte rien et ne s'affiche donc pas : c'est exactement la
    /// distinction que l'utilisateur cherche quand il demande à savoir « quand
    /// il importe / active le modèle Parakeet ».
    private func startMeter() {
        meter.activities = { [weak self] in
            guard let self else { return [] }
            var lines: [ResourceMeter.Activity] = []

            if let detail = Self.modelActivity(
                dictation.host.availability,
                unloadDelay: dictation.host.idleUnloadDelay
            ) {
                lines.append(ResourceMeter.Activity(title: "Modèle de dictée", detail: detail))
            }

            // Le veilleur ne coûte que s'il a des voies à observer : à zéro
            // fenêtre, il fait une liste de titres et se rendort. Le dire quand
            // même serait la quatrième ligne permanente qu'on cherche à éviter.
            let lanes = watch.verdict.lanes.count
            if watchSettings.isEnabled, watch.pause == nil, lanes > 0 {
                lines.append(ResourceMeter.Activity(
                    title: "Veille",
                    detail: "\(lanes) \(lanes == 1 ? "fenêtre" : "fenêtres") / \(watchSettings.tickSeconds) s"
                ))
            }

            if hasOpenSession {
                lines.append(ResourceMeter.Activity(
                    title: "Enregistrement",
                    detail: isPaused ? "en pause" : "en cours"
                ))
            }

            return lines
        }

        meter.start()
    }

    /// Ce que le modèle de dictée coûte, ou `nil` s'il ne coûte rien.
    private static func modelActivity(
        _ availability: SpeechModelHost.Availability,
        unloadDelay: TimeInterval
    ) -> String? {
        switch availability {
        case .downloading(let fraction):
            let percent = (fraction * 100).formatted(.number.precision(.fractionLength(0)))
            return "téléchargement \(percent) %"
        case .loading:
            return "chargement…"
        case .ready:
            // Le délai est dit parce qu'il répond tout de suite à la question
            // suivante : « et ça va rester chargé combien de temps ? »
            let minutes = Int((unloadDelay / 60).rounded())
            return "chargé — libéré après \(minutes) min sans dictée"
        case .absent, .installed, .failed:
            // Sur le disque et pas en mémoire, c'est zéro octet et zéro cycle.
            return nil
        }
    }

    /// Active la capture de texte, en signalant si l'Accessibilité manque.
    ///
    /// Le tap est partagé : l'installer ici profite aussi à la dictée, et
    /// inversement. C'est pour ça que le réglage d'une fonction ne désinstalle
    /// jamais le tap — il retire seulement sa propre liaison.
    @discardableResult
    func enableSnapshot(_ enabled: Bool) -> Bool {
        guard enabled else {
            shortcuts.monitor.bind(.snapshot, to: nil)
            snapshotSettings.isEnabled = false
            return true
        }

        shortcuts.monitor.bind(.snapshot, to: snapshotSettings.trigger)
        guard shortcuts.monitor.install() else {
            shortcuts.monitor.bind(.snapshot, to: nil)
            snapshotSettings.isEnabled = false
            return false
        }

        snapshotSettings.isEnabled = true
        return true
    }

    /// Active la dictée, en signalant si l'Accessibilité manque.
    @discardableResult
    func enableDictation(_ enabled: Bool) -> Bool {
        dictation.setEnabled(enabled)
    }

    // MARK: - État affiché

    public var statusSummary: String {
        switch engine.state {
        case .recording:
            "Enregistrement — \(elapsedDescription)"
        case .paused:
            "En pause — \(elapsedDescription) enregistrées"
        case .starting:
            "Démarrage…"
        case .finalizing:
            "Finalisation du fichier…"
        case .failed(let reason):
            "Échec — \(reason)"
        case .idle:
            if processingProgress.isEmpty == false {
                "Compression en cours…"
            } else {
                pendingMeeting != nil ? "Réunion détectée — non enregistrée" : "En veille"
            }
        }
    }

    public var elapsedDescription: String {
        let total = Int(elapsed.components.seconds)
        let minutes = total / 60
        let seconds = total % 60
        return minutes > 0
            ? "\(minutes) min \(String(format: "%02d", seconds)) s"
            : "\(seconds) s"
    }

    public var isRecording: Bool {
        if case .recording = engine.state { true } else { false }
    }

    public var isPaused: Bool {
        if case .paused = engine.state { true } else { false }
    }

    /// Vrai tant qu'une session est ouverte — **y compris pendant `.starting` et
    /// `.finalizing`**. C'est ce qui commande l'affichage de la barre de
    /// pilotage.
    ///
    /// La version précédente disait `isRecording || isPaused`, et laissait donc
    /// deux trous de plusieurs secondes chacun, aux deux extrémités de la
    /// session, pendant lesquels bran se croyait au repos alors qu'un flux
    /// tournait :
    /// - la fenêtre Meet qui disparaît pendant `.starting` n'arrêtait rien
    ///   (`tick()` ne rappelait pas `stopRecording()`), et l'enregistrement
    ///   continuait sans plus rien pour le fermer automatiquement ;
    /// - le veilleur ne se taisait pas (correctif CR-4), et pouvait donc capturer
    ///   pendant qu'une réunion démarre ou se finalise ;
    /// - une proposition pouvait être faite par-dessus une session qui démarre ;
    /// - « En ce moment » n'annonçait pas l'enregistrement.
    ///
    /// `isActive` est la même question posée à la machine, qui, elle, connaît ses
    /// six états.
    public var hasOpenSession: Bool { engine.state.isActive }

    // MARK: - Post-traitement

    /// Progression de la fusion + compression, par enregistrement. Transitoire :
    /// vit en mémoire, jamais sur le disque.
    public private(set) var processingProgress: [UUID: Double] = [:]

    public private(set) var lastSaving: String?

    // MARK: - Actions

    /// Démarre l'enregistrement de la réunion détectée. C'est le seul chemin
    /// automatique-assisté : détection → proposition → geste explicite.
    public func startPendingRecording() {
        guard let meeting = pendingMeeting else {
            startManualRecording()
            return
        }
        Task { await begin(meeting) }
    }

    /// Enregistrement sans réunion détectée — bran comme simple enregistreur
    /// d'écran.
    public func startManualRecording() {
        let meeting = MeetingRef(
            id: UUID(),
            startedAt: .now,
            title: nil,
            meetCode: nil,
            calendarEventID: nil,
            attendees: []
        )
        Task { await begin(meeting) }
    }

    public func togglePause() {
        Task {
            if isPaused {
                await engine.resume()
                if let pausedAt { accumulatedPause += Date.now.timeIntervalSince(pausedAt) }
                pausedAt = nil
            } else if isRecording {
                await engine.pause()
                pausedAt = .now
            }
        }
    }

    /// Demande l'arrêt, et **rien d'autre**.
    ///
    /// Ce qui suit l'arrêt ne se décide pas ici : la machine peut trancher tout
    /// de suite (cas courant) ou plus tard (`.stop` reçu pendant `.starting`,
    /// qu'elle mémorise pour finaliser elle-même). Conclure au retour de
    /// `handle(.stop)` marchait dans le premier cas et abandonnait la session
    /// dans le second. `concludeSession` est donc appelé par la machine, par
    /// `onSettled`, dans les deux cas.
    ///
    /// Le garde-fou reste utile : sans session ouverte, il n'y a rien à arrêter,
    /// et un clic de trop sur « arrêter » ne doit pas réveiller la machine.
    public func stopRecording() {
        guard engine.state.meeting != nil else { return }
        Task { await engine.handle(.stop) }
    }

    /// Referme la session **une fois que la machine a tranché**.
    ///
    /// Appelé par `RecordingEngine.onSettled`, jamais directement : c'est la
    /// machine qui sait quand elle a fini, et c'est elle qui garantit que ceci ne
    /// tourne qu'une fois par session. Deux clics sur « arrêter » ne fusionnent
    /// donc pas deux fois, et un arrêt différé finit par arriver ici au lieu de
    /// se perdre.
    ///
    /// La version d'origine poursuivait quoi qu'il arrive : `endedAt` était écrit
    /// même après une finalisation expirée ou une erreur de ScreenCaptureKit. La
    /// sentinelle de session interrompue disparaissait au passage, et la
    /// bibliothèque présentait un fichier peut-être tronqué comme une réunion
    /// complète. `RecordingEngine` distinguait pourtant déjà `.failed` d'un arrêt
    /// propre, et ses tests l'exigeaient ; c'est l'appelant qui l'ignorait.
    ///
    /// Ce que l'utilisateur voit désormais quand ça rate :
    /// - le bandeau et le menu disent l'échec et disent que le fichier peut
    ///   être tronqué ;
    /// - `statusSummary` reste sur « Échec — … », parce que la machine reste
    ///   dans `.failed` ;
    /// - **et surtout**, la fiche garde son `endedAt` vide et reçoit le motif :
    ///   la ligne de la bibliothèque porte le triangle « interrompue » *et dit
    ///   pourquoi*, aujourd'hui, demain, et après un redémarrage. C'est le seul
    ///   de ces trois signaux qui survive à la fermeture de la fenêtre — d'où
    ///   l'intérêt qu'il porte aussi la cause, plutôt que de renvoyer vers un
    ///   bandeau déjà remplacé par la panne suivante.
    private func concludeSession(
        _ meeting: MeetingRef,
        verdict: StopVerdict,
        segments: [URL]
    ) async {
        recordingStartedAt = nil
        pausedAt = nil
        stopTicking()

        if let message = verdict.message { report(message) }

        if verdict.writesEndedAt {
            await store.completeSession(id: meeting.id)
        } else {
            // Pas de `completeSession` : l'absence de `endedAt` EST le signal.
            // Mais elle ne dit pas pourquoi, et le motif ne vivait jusqu'ici que
            // dans le bandeau — c'est-à-dire nulle part une heure plus tard. On
            // l'écrit donc dans la fiche, au même endroit et avec la même durée
            // de vie que l'avertissement qu'il explique.
            if case .failed(let reason) = verdict {
                await store.mutate(meeting.id) { $0.interruptionReason = reason }
            }
            // On relit le dossier pour que la ligne apparaisse tout de suite
            // avec son avertissement.
            await store.reload()
        }

        // Les morceaux déjà écrits sont fusionnés même après un échec : ce sont
        // les minutes de réunion réellement capturées, et les laisser sous leur
        // nom de segment les rendrait invisibles. Mais après un échec ils ne
        // sont PAS effacés : `replayd` n'avait peut-être pas fini d'écrire, et
        // la fusion peut être plus courte que la source.
        await postProcess(
            meeting.id,
            segments: segments,
            preservingSegments: verdict.writesEndedAt == false
        )
    }

    /// Fusion des segments puis compression, en une seule passe d'encodage.
    ///
    /// Lancé après la finalisation, jamais pendant : encoder en parallèle d'une
    /// capture volerait au flux le matériel vidéo dont il a besoin.
    private func postProcess(_ id: UUID, segments: [URL], preservingSegments: Bool = false) async {
        guard segments.isEmpty == false else { return }

        let destination = store.root.appending(path: "\(id.uuidString).mp4")
        processingProgress[id] = 0

        do {
            let outcome = try await processor.process(
                segments: segments,
                into: destination,
                preservingSegments: preservingSegments
            ) { fraction in
                Task { @MainActor [weak self] in self?.processingProgress[id] = fraction }
            }

            processingProgress[id] = nil
            await store.completeProcessing(
                id: id,
                originalBytes: outcome.originalBytes,
                segmentCount: segments.count
            )

            // Le ménage raté se dit. Sans ça, la fusion annonçait un gain de
            // place que le disque n'avait pas fait : les morceaux étaient
            // toujours là, invisibles, en double du fichier final.
            if let leftover = outcome.cleanup.problem { report(leftover) }

            if preservingSegments {
                report(
                    "Les morceaux bruts de cette réunion (\(segments.count)) sont conservés dans le dossier "
                    + "des enregistrements : la session s'était mal terminée, et le fichier fusionné peut être "
                    + "plus court qu'eux. Supprimez-les une fois le fichier vérifié."
                )
            }

            let percent = (outcome.savedFraction * 100).formatted(.number.precision(.fractionLength(0)))
            lastSaving = "\(outcome.originalBytes.formatted(.byteCount(style: .file))) → \(outcome.finalBytes.formatted(.byteCount(style: .file))) (−\(percent) %)"
            await store.reload()
            await offerUpload(for: id)
        } catch {
            processingProgress[id] = nil
            // Les segments sont intacts : le post-traitement ne les supprime
            // qu'après avoir écrit un fichier final non vide.
            report("Compression impossible : \(error.localizedDescription) — les segments bruts sont conservés.")
        }

        await store.reload()
    }

    /// Refus explicite de l'utilisateur.
    ///
    /// Le résolveur garde la réunion pour active : reproposer trente secondes
    /// plus tard serait du harcèlement. La proposition ne reviendra qu'après la
    /// fin réelle de la réunion.
    public func dismissProposal() {
        pendingMeeting = nil
        proposalMissingSince = nil
        notifications.withdrawProposals()
    }

    public func setLaunchAtLogin(_ enabled: Bool) {
        loginItem.setEnabled(enabled)
    }

    /// Changer de destination pendant un enregistrement enverrait la suite du
    /// fichier ailleurs, ou nulle part.
    ///
    /// Le test porte sur la session entière, pas sur le seul `.recording` : en
    /// pause, la reprise ouvrirait son segment dans le nouveau dossier et la
    /// fusion irait chercher des morceaux répartis sur deux racines.
    func chooseStorageFolder() {
        guard hasOpenSession == false else {
            report("Impossible de changer de dossier pendant un enregistrement.")
            return
        }
        guard storage.chooseFolder() else { return }
        applyStorageRoot()
    }

    func resetStorageFolder() {
        guard hasOpenSession == false else { return }
        guard storage.resetToDefault() else { return }
        applyStorageRoot()
    }

    private func applyStorageRoot() {
        storage.validate()
        let root = storage.root
        Task {
            await capture.updateStorageRoot(root)
            await store.setRoot(root)
        }
    }

    // MARK: - Boucle

    private func startWatching() {
        pollTask = Task { [weak self] in
            while Task.isCancelled == false {
                await self?.tick()
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    private func tick() async {
        let signals = detector.currentSignals()
        let intent = resolver.resolve(windows: signals, at: .now)

        expireProposalIfWindowClosed(hasSignal: signals.isEmpty == false)

        switch intent {
        case .start(let meeting):
            // Proposition, pas démarrage.
            guard hasOpenSession == false else { return }

            let booking = meeting.meetCode.flatMap { directory.booking(forMeetCode: $0) }
            linkedBooking = booking
            pendingMeeting = booking.map { enrich(meeting, with: $0) } ?? meeting
            notifications.proposeRecording(title: pendingMeeting?.title)

        case .stop:
            pendingMeeting = nil
            linkedBooking = nil
            notifications.withdrawProposals()
            // Une session en pause s'arrête aussi, et une session qui démarre
            // encore également : la réunion est terminée. Le résolveur n'émet
            // `.stop` qu'une fois, et la fenêtre Meet qui se ferme pendant les
            // secondes de `.starting` est un cas réel — c'est la machine qui
            // diffère l'ordre, pas nous qui le retenons.
            if hasOpenSession { stopRecording() }

        case .noop:
            break
        }
    }

    /// Une proposition dont la fenêtre a disparu s'annule d'elle-même.
    ///
    /// `resolver.forget()` est indispensable ici : sans lui, le résolveur
    /// tiendrait la réunion pour toujours en cours et ne proposerait plus rien
    /// si l'utilisateur rejoignait le même Meet.
    private func expireProposalIfWindowClosed(hasSignal: Bool) {
        guard pendingMeeting != nil, hasOpenSession == false else {
            proposalMissingSince = nil
            return
        }

        guard hasSignal == false else {
            proposalMissingSince = nil
            return
        }

        guard let since = proposalMissingSince else {
            proposalMissingSince = .now
            return
        }

        guard Date.now.timeIntervalSince(since) >= Self.proposalGrace else { return }

        pendingMeeting = nil
        proposalMissingSince = nil
        notifications.withdrawProposals()
        resolver.forget()
    }

    /// Le RDV du CRM porte le nom de l'entreprise, les participants et
    /// l'identifiant de rattachement. Autant les inscrire dès le départ : un
    /// enregistrement nommé « ORPHEO GNB » se retrouve, pas un UUID.
    private func enrich(_ meeting: MeetingRef, with booking: CRMBooking) -> MeetingRef {
        MeetingRef(
            id: meeting.id,
            startedAt: meeting.startedAt,
            title: booking.company?.nom ?? booking.attendee_name ?? booking.detected_domain,
            meetCode: meeting.meetCode,
            calendarEventID: booking.booking_id,
            attendees: [booking.attendee_email].compactMap(\.self)
        )
    }

    private func begin(_ meeting: MeetingRef) async {
        permissions.refresh()
        guard permissions.canRecord else {
            report("Autorisation manquante — enregistrement non démarré.")
            return
        }

        lastFailure = nil
        pendingMeeting = nil
        notifications.withdrawProposals()

        // Le `.json` est écrit AVANT le démarrage. Un `.json` sans `endedAt`
        // signale ensuite une session interrompue : c'est la sentinelle du §10,
        // sans fichier `.lock` séparé à gérer.
        store.beginSession(meeting)

        if let booking = linkedBooking {
            await store.mutate(meeting.id) { metadata in
                metadata.bookingID = booking.booking_id
                metadata.companyID = booking.company?.id
                metadata.companyName = booking.company?.nom
                metadata.meetingURL = booking.meeting_url
            }
        }

        await engine.handle(.start(meeting))

        if isRecording {
            recordingStartedAt = .now
            accumulatedPause = 0
            currentTitle = meeting.title ?? ""
            startTicking()
            await store.reload()
        }
    }

    // MARK: - Envoi au CRM

    /// Rattachement en attente d'un choix humain. Le contrat est formel :
    /// ne jamais deviner quand plusieurs RDV collent, ou aucun.
    var pendingUpload: (recording: Recording, candidates: [CRMBooking])?

    private func offerUpload(for id: UUID) async {
        guard uploads.configuration.isConfigured,
              let recording = store.recordings.first(where: { $0.id == id })
        else { return }

        // **Un enregistrement dont l'arrêt a échoué ne part pas tout seul au
        // CRM.** Envoyer sans rien dire un fichier peut-être tronqué à la fiche
        // d'un client, c'est la version aggravée du défaut qu'on vient de
        // corriger : non seulement bran prétendrait avoir tout gardé, mais il
        // agirait dessus. L'envoi manuel depuis la bibliothèque reste possible,
        // après avoir écouté le fichier.
        guard recording.wasInterrupted == false else {
            report(
                "Réunion « \(recording.displayTitle) » non envoyée au CRM : la session ne s'est pas terminée "
                + "proprement et le fichier peut être incomplet. Vérifiez-le, puis envoyez-le depuis la bibliothèque."
            )
            return
        }

        // Rattachement certain par le code Meet : aucune ambiguïté à lever.
        if let bookingID = recording.metadata.bookingID,
           let booking = directory.bookings.first(where: { $0.booking_id == bookingID }) {
            let eligibility = UploadEligibility.evaluate(
                booking: booking,
                isConfigured: uploads.configuration.isConfigured
            )

            guard eligibility.canSend else {
                // Ni envoi, ni fenêtre de choix : il n'y a rien à choisir, il y
                // a quelque chose à réparer dans le CRM. Le détail de
                // l'enregistrement l'explique et propose de revérifier.
                if let reason = eligibility.blockingReason { report(reason) }
                return
            }

            if uploads.configuration.autoUpload {
                uploads.send(recording, to: booking, complement: nil)
            } else {
                pendingUpload = (recording, [booking])
            }
            return
        }

        do {
            switch try await uploads.resolveBooking(for: recording) {
            case .unique(let booking) where uploads.configuration.autoUpload:
                uploads.send(recording, to: booking, complement: nil)
            case .unique(let booking):
                pendingUpload = (recording, [booking])
            case .ambiguous(let candidates), .none(let candidates):
                pendingUpload = (recording, candidates)
            }
        } catch {
            report("CRM injoignable : \(error.localizedDescription)")
        }
    }

    /// Envoi demandé à la main depuis la bibliothèque.
    func requestUpload(for recording: Recording) {
        Task {
            guard uploads.configuration.isConfigured else {
                report("Liaison CRM non configurée — voir les Réglages.")
                return
            }
            let linked = recording.metadata.bookingID.flatMap { id in
                directory.bookings.first { $0.booking_id == id }
            }

            do {
                let nearby: [CRMBooking] = switch try await uploads.resolveBooking(for: recording) {
                case .unique(let booking): [booking]
                case .ambiguous(let candidates), .none(let candidates): candidates
                }

                // Le RDV déjà rapproché passe en tête sans être dupliqué.
                let candidates = linked.map { booking in
                    [booking] + nearby.filter { $0.booking_id != booking.booking_id }
                } ?? nearby

                pendingUpload = (recording, candidates)
            } catch {
                // Le CRM ne répond pas : la feuille reste utile, sa recherche
                // retentera l'appel.
                pendingUpload = (recording, linked.map { [$0] } ?? [])
                report("CRM injoignable : \(error.localizedDescription)")
            }
        }
    }

    func confirmUpload(_ recording: Recording, booking: CRMBooking, complement: String?) {
        pendingUpload = nil
        uploads.send(recording, to: booking, complement: complement)
    }

    func searchableBookings(forceRefresh: Bool = false) async -> UploadService.SearchResults {
        await uploads.searchableBookings(forceRefresh: forceRefresh)
    }

    /// Admissibilité d'un enregistrement, réévaluée en interrogeant le CRM.
    /// C'est le bouton « Revérifier » après avoir rattaché le lead.
    func recheckEligibility(for recording: Recording) async -> UploadEligibility {
        await uploads.eligibility(for: recording, in: directory)
    }

    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while Task.isCancelled == false {
                guard let self, let started = self.recordingStartedAt else { return }

                // Le temps passé en pause ne compte pas : afficher une durée qui
                // avance pendant qu'on n'enregistre rien serait un mensonge.
                if self.isPaused == false {
                    self.elapsed = .seconds(Date.now.timeIntervalSince(started) - self.pausedDuration)
                    self.currentFileSize = self.engine.segments.reduce(0) { $0 + Self.sizeOfFile(at: $1) }
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func stopTicking() {
        tickTask?.cancel()
        tickTask = nil
        elapsed = .zero
        currentFileSize = 0
        currentTitle = ""
        accumulatedPause = 0
    }

    /// Cumul des pauses déjà terminées, plus celle en cours.
    private var pausedDuration: TimeInterval {
        accumulatedPause + (pausedAt.map { Date.now.timeIntervalSince($0) } ?? 0)
    }

    private static func sizeOfFile(at url: URL?) -> Int64 {
        guard let url else { return 0 }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        return attributes?[.size] as? Int64 ?? 0
    }
}
