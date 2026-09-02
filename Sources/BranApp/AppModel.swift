import AppKit
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

    /// À quelle fréquence redemander à TCC si l'écran est lisible. Une minute :
    /// voir `screenTitlesAreReadable`, où le chiffre est justifié par une mesure
    /// qui contredit l'intuition.
    private static let screenProbeInterval = Duration.seconds(60)
    private var screenProbedAt: SuspendingClock.Instant?
    private var screenIsGranted = true

    public let permissions = PermissionsService()
    public let engine: RecordingEngine
    let store = RecordingStore()
    let loginItem = LoginItemService()

    /// Les mises à jour. Aussi autonome que l'éveil ou le moniteur : elle ne
    /// connaît rien du reste de bran, et rien du reste de bran ne la connaît en
    /// dehors de l'entrée de menu qui la déclenche.
    let updates = UpdateService()
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

    /// L'historique du presse-papiers.
    ///
    /// **Pas de `ClipboardSettings` à côté, contrairement aux deux autres, et
    /// c'est voulu tant qu'il n'y a rien à régler.** La fonction arrive dans
    /// l'ordre inverse de ses aînées — le raccourci d'abord, l'écran de réglages
    /// ensuite — et sa liaison vit donc dans `GlobalTriggerRegistry`, qui la
    /// détient déjà pour la détection de conflits. Inventer un objet de réglages
    /// vide juste pour la symétrie ferait un fichier de plus qui ne réglerait
    /// rien.
    let clipboardSettings = ClipboardSettings()
    let clipboard: ClipboardController

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

    /// Le test de débit. Le plus autonome des modules après l'éveil : il ne
    /// connaît ni les réunions, ni la dictée, ni le veilleur, et rien de tout ça
    /// ne le connaît. Il tire des octets, les compte, et mémorise le résultat.
    ///
    /// Il reçoit la version parce qu'il l'annonce au serveur de mesure — voir
    /// `SpeedPlan.userAgent` : bran dit son nom plutôt que de se déguiser en
    /// navigateur, et c'est le seul endroit où cette chaîne sort de la machine.
    let speed: SpeedController

    /// La sauvegarde. Le module le plus autonome de tous : il ne connaît ni les
    /// réunions, ni la dictée, ni le veilleur, et aucun d'eux ne le connaît.
    ///
    /// **Il n'est pas le planificateur, et c'est le point à ne pas perdre.** Ce
    /// qui tient le rythme est un LaunchAgent qui rappelle le même binaire en
    /// `--backup-run`, fenêtre ouverte ou non — voir `BackupAgentInstaller`. Ce
    /// contrôleur-ci sert l'écran, propose un rattrapage quand la fenêtre est
    /// là, et partage avec le job un verrou de fichier pour que deux `kopia` ne
    /// se disputent jamais le dépôt.
    let backup = BackupController()

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

    /// Le compteur de débit. Encore un panneau à lui — le troisième — et pour la
    /// raison écrite dans `SpeedOverlay` : l'encoche est partagée par deux
    /// fonctions dont les fins de course sont déjà finement arbitrées, et le
    /// test de débit n'a aucun de leurs besoins.
    private var speedOverlay: SpeedOverlay?

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
        // La version vient de `UpdateService`, seul endroit du programme qui la
        // lise, et le compteur ne s'en sert que pour se nommer auprès du serveur
        // de mesure. Voir `SpeedPlan.userAgent`.
        self.speed = SpeedController(version: updates.installedVersion)
        backup.start()

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

        let clipboardSettings = self.clipboardSettings
        self.clipboard = ClipboardController(
            store: ClipboardStore(
                root: { [storage] in storage.root },
                retention: clipboardSettings.retention
            ),
            settings: clipboardSettings
        )

        // **Les deux coutures que le guet avait laissées ouvertes.** L'indice de
        // copie est relayé sans arbitrage — une copie faite pendant une dictée
        // est précisément celle qu'on voudra coller à la fin — tandis que ⌘⇧C
        // passe par l'arbitrage comme les deux autres fonctions.
        shortcuts.onCopyHint = { [weak self] changeCount in
            self?.clipboard.copyHinted(changeCount: changeCount)
        }
        shortcuts.openClipboardPanel = { [weak self] in
            self?.clipboard.openRequested()
        }
        shortcuts.clipboardIsBusy = { [weak self] in self?.clipboard.isBusy ?? false }
        shortcuts.closeClipboardPanel = { [weak self] in self?.clipboard.closePanel() }

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

        // L'heure d'entrée en finalisation, et rien d'autre.
        //
        // Elle sert à faire DÉCROÎTRE l'estimation affichée : sans elle, la barre
        // annonçait « environ 12 min » à la première seconde et « environ 12 min »
        // encore onze minutes plus tard. Une estimation qui ne bouge pas se lit
        // comme un blocage, c'est-à-dire exactement le contraire de ce qu'elle
        // essaie de dire.
        //
        // `onTransition` est le journal des transitions de la machine : c'est le
        // seul endroit qui voie l'entrée dans `.finalizing` quel que soit son
        // origine — un clic sur « Arrêter », la fenêtre Meet qui se ferme, ou un
        // arrêt différé que la machine avait mis de côté.
        engine.onTransition = { [weak self] state in
            guard let self else { return }
            if case .finalizing = state { finalizingStartedAt = .now }
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

        // **Sparkle ne relance pas bran pendant qu'un fichier s'écrit.**
        //
        // `showsSessionBar` et surtout pas `hasOpenSession` : celui-ci est déjà
        // faux pendant la fusion, la compression et l'extraction de l'audio,
        // c'est-à-dire pendant la fenêtre où l'on a le plus à perdre.
        // ScreenCaptureKit écrit 93 % du fichier après `stopCapture()`, et cette
        // finalisation a duré douze minutes sur une réunion de trente-six. Le
        // dépôt s'est déjà fait prendre deux fois par cette nuance — la barre de
        // session, puis `tidyRecordingFolders` —, ce qui suffit à en faire une
        // règle plutôt qu'un détail.
        updates.hasSomethingToLose = { [weak self] in self?.showsSessionBar ?? false }

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

        uploads.configuration.logConfiguration()

        // Au premier lancement seulement. Voir `adoptDefaultOnFirstLaunch` :
        // toutes les fonctions de bran sont actives par défaut, et celle-ci
        // conditionne les autres — un observateur qu'il faut penser à lancer
        // n'observe rien le jour où on l'oublie.
        loginItem.adoptDefaultOnFirstLaunch()

        directory.start()
        startDictation()
        startSnapshot()
        startWatch()
        startAwake()
        startMeter()
        startSpeed()
        clipboard.start(monitor: shortcuts.monitor)

        // La surveillance est permanente. Il n'y a pas de raison de la
        // suspendre : elle ne fait qu'observer des titres de fenêtres, et une
        // surveillance qu'on oublie d'activer ne sert à rien.
        startWatching()

        watchSystemSettingsChanges()
    }

    /// Deux réglages qui vivent **hors** de bran sont relus à chaque retour au
    /// premier plan.
    ///
    /// Ce sont les deux seuls que l'utilisateur peut changer dans Réglages
    /// système sans que rien ne nous le dise, et les deux se lisaient une fois
    /// pour toutes à l'initialisation :
    ///
    /// - l'autorisation de notifier. Elle n'est plus demandée au lancement — une
    ///   fenêtre système sans contexte se refuse par réflexe, et macOS ne repose
    ///   jamais la question. Celui qui l'accorde ensuite depuis les Réglages
    ///   n'était jamais vu comme l'ayant accordée, et les alertes de retard de
    ///   sauvegarde continuaient de partir dans le vide ;
    /// - l'élément d'ouverture. Retiré depuis Réglages système › Général ›
    ///   Ouverture, l'interrupteur de bran restait allumé pour toujours.
    ///
    /// Le retour au premier plan est le bon moment parce que c'est celui où
    /// l'utilisateur revient **de** ces Réglages. Un sondage périodique aurait
    /// relu les deux toutes les N secondes pour un changement qui arrive deux
    /// fois dans la vie d'une installation.
    private func watchSystemSettingsChanges() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.loginItem.refresh()
                Task { await self.notifications.refresh() }
            }
        }
    }

    // MARK: - Dictée

    private func startDictation() {
        notchPresenter = NotchPresenter(dictation: dictation, snapshot: snapshot)
        dictation.applySettings()
        // Avant de relever la disponibilité, pas après : sans ça, le premier
        // écran annoncerait « modèle absent » sur une machine qui l'a, et
        // proposerait de retélécharger 461 Mo déjà présents.
        SpeechModelHost.adoptLegacyModelIfNeeded()
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
        // **Le compteur de débit s'ajoute aux deux fonctions qui faisaient déjà
        // taire la pilule**, et pour la même raison de place : son panneau
        // occupe exactement le même coin de l'écran, sous la partie droite de la
        // barre de menus. Deux surfaces flottantes superposées ne se disputent
        // pas — elles se recouvrent, et c'est celle du dessous qui devient
        // illisible sans que personne ne sache pourquoi.
        attention = AttentionOverlay(isSuppressed: { [weak self] in
            guard let self else { return true }
            return dictation.isBusy || snapshot.isBusy || speed.phase.isRunning
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

    // MARK: - Le débit

    /// Deux fermetures, et rien d'autre — le patron de l'éveil.
    ///
    /// L'échec repart par `report`, comme tous les autres : bran a déjà un canal
    /// pour dire ce qui a raté, il n'en aura pas un second. L'affichage passe par
    /// `onPresent` plutôt que par une propriété partagée, pour que le contrôleur
    /// reste ignorant de l'existence d'un panneau — c'est ce qui permet à la
    /// sonde en ligne de commande de faire tourner la même mesure sans écran.
    private func startSpeed() {
        speedOverlay = SpeedOverlay(controller: speed)

        speed.onPresent = { [weak self] visible in
            self?.speedOverlay?.setVisible(visible)
        }

        speed.onFailure = { [weak self] reason in
            self?.report(reason)
        }
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
        // La chaîne de fin passe devant tout le reste, et c'est le point : c'est
        // depuis le menu, fenêtre fermée, que l'utilisateur surveille la fin
        // d'une réunion. « Compression en cours… » sans étape ni pourcentage
        // était indiscernable d'un blocage — et pendant la finalisation ou
        // l'extraction de l'audio, le menu ne disait rien du tout.
        if let step = currentStep { return step.summary }

        return switch engine.state {
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
            pendingMeeting != nil ? "Réunion détectée — non enregistrée" : "En veille"
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

    /// La capture est finie, `replayd` écrit encore.
    ///
    /// C'est l'état le plus long d'une fin de session — mesuré à un tiers de la
    /// durée enregistrée — et c'était le seul que l'interface ne montrait
    /// jamais. L'utilisateur cliquait « Arrêter », voyait la barre se figer,
    /// recliquait, puis lisait « Échec » : trois signaux faux pour un travail
    /// qui se déroulait normalement.
    public var isFinalizing: Bool {
        if case .finalizing = engine.state { true } else { false }
    }

    // L'estimation du temps de finalisation vivait ici. Elle est partie dans
    // `SessionProgress.remaining`, avec la mesure qui la fonde — le 11 août
    // 2026, 2 191 s enregistrées ont demandé 729 s de finalisation, soit un
    // tiers — et surtout avec les deux autres étapes, qui n'en avaient aucune.
    // La garder ici en aurait fait la seule estimation calculée à part, dans le
    // modèle, pendant que les deux autres se calculaient dans BranCore ; et
    // celle-ci était en plus la seule à ne jamais décroître, faute de savoir
    // depuis quand la finalisation durait.

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

    /// Non `nil` quand quitter maintenant coûterait un fichier — et dit lequel.
    ///
    /// **Le chiffre qui rend ce garde-fou nécessaire** : ScreenCaptureKit écrit
    /// 93 % du fichier **après** `stopCapture()`, et cette finalisation a duré
    /// douze minutes sur une réunion de trente-six. Quitter dans cette
    /// fenêtre-là ne perd pas quelques secondes de fin, il perd la réunion — le
    /// `.mp4` reste au tiers de sa taille et ne s'ouvre pas.
    ///
    /// **La question est « y a-t-il un fichier en train de s'écrire », pas
    /// « enregistre-t-on »**, et c'est ce qui fait qu'elle ne peut pas être
    /// `isRecording`. Trois moments coûtent un fichier, et deux d'entre eux ne
    /// ressemblent pas du tout à un enregistrement pour qui regarde l'écran :
    /// la session ouverte — départ, capture, pause, finalisation, que
    /// `hasOpenSession` couvre toutes les quatre —, et la chaîne de fin, où la
    /// fusion et la compression peuvent tourner une demi-heure après que la
    /// barre a disparu.
    ///
    /// La phrase rendue est celle que `SessionProgress` écrit déjà pour la
    /// barre : elle nomme l'étape, elle est en français, et la reprendre ici
    /// évite qu'une alerte de fermeture et la barre de progression décrivent le
    /// même travail avec deux vocabulaires différents.
    public var quitWouldLose: String? {
        if let step = currentStep { return step.title }
        return hasOpenSession ? "Enregistrement en cours…" : nil
    }

    // MARK: - Post-traitement

    /// Où en est la chaîne de fin de session, par enregistrement. Transitoire :
    /// vit en mémoire, jamais sur le disque.
    ///
    /// Remplace un `[UUID: Double]` qui ne portait qu'une fraction. Une fraction
    /// ne dit pas de quoi elle est la fraction : l'interface écrivait « Fusion et
    /// compression… » en dur, y compris pendant l'extraction de l'audio, et
    /// n'avait rien du tout à dire entre les deux.
    public private(set) var pipeline: [UUID: SessionProgress] = [:]

    /// L'enregistrement dont la chaîne de fin tourne en ce moment, s'il y en a un.
    ///
    /// Explicite plutôt que déduit d'un `pipeline.values.first` : l'ordre d'un
    /// dictionnaire n'est pas défini, et démarrer une réunion pendant que la
    /// précédente compresse est un cas réel — la barre choisirait alors une
    /// entrée au hasard.
    /// Les chaînes de fin en cours, dans l'ordre où elles ont commencé.
    ///
    /// **Un seul identifiant ne suffisait pas.** Une réunion peut compresser
    /// pendant une demi-heure ; démarrer et terminer la suivante dans cet
    /// intervalle est un cas ordinaire, pas une acrobatie. Avec une seule
    /// variable, la seconde prenait la place de la première, puis la libérait en
    /// finissant : la barre et le menu redevenaient muets alors qu'une
    /// compression tournait toujours — c'est-à-dire exactement le silence que ce
    /// lot existe pour supprimer, réintroduit par la porte de derrière.
    ///
    /// La plus ancienne est celle qu'on montre : c'est celle qui a le plus de
    /// chances d'aboutir bientôt, et c'est celle qu'on attend depuis le plus
    /// longtemps.
    private var stepOrder: [UUID] = []

    private var stepNames: [UUID: String] = [:]

    private var currentStepID: UUID? { stepOrder.first }

    private var currentStepName: String? { currentStepID.flatMap { stepNames[$0] } }

    /// Depuis quand la finalisation dure. Sert à retrancher le temps déjà passé
    /// de l'estimation, pour que celle-ci décroisse au lieu de rester figée.
    private var finalizingStartedAt: Date?

    /// L'étape à montrer, ou `nil` quand il n'y a rien en cours.
    ///
    /// La finalisation est fabriquée ici plutôt que rangée dans `pipeline` :
    /// elle appartient à `RecordingEngine`, pas au post-traitement, et la
    /// dupliquer dans le dictionnaire créerait deux sources de vérité pour un
    /// état que la machine connaît déjà. Le reste de l'application n'a pas à
    /// savoir que la chaîne a deux propriétaires.
    public var currentStep: SessionProgress? {
        if isFinalizing {
            return SessionProgress(
                stage: .finalizing,
                bytesWritten: currentFileSize,
                recorded: elapsed,
                elapsed: .seconds(Int(Date.now.timeIntervalSince(finalizingStartedAt ?? .now)))
            )
        }
        return currentStepID.flatMap { pipeline[$0] }
    }

    /// De quelle réunion il s'agit. Quand la fenêtre est restée ouverte deux
    /// heures, ce n'est pas du décor.
    public var currentStepTitle: String? {
        if isFinalizing {
            let typed = currentTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            return engine.state.meeting?.title ?? (typed.isEmpty ? nil : typed)
        }
        return currentStepName
    }

    /// La barre de pilotage doit-elle rester à l'écran ?
    ///
    /// **C'était le défaut**, et il tenait en un mot : la barre était montée sur
    /// `hasOpenSession`, qui devient faux à l'instant où la machine repasse au
    /// repos — c'est-à-dire juste AVANT que la fusion, la compression et
    /// l'extraction de l'audio commencent. Sur une réunion de trente-six minutes,
    /// ça faisait plusieurs dizaines de minutes de travail réel pendant
    /// lesquelles l'écran ne montrait plus rien, et pendant lesquelles fermer
    /// bran — le geste que le silence invite à faire — perdait le travail en
    /// cours.
    public var showsSessionBar: Bool { hasOpenSession || currentStep != nil }

    public private(set) var lastSaving: String?

    /// Une information neutre, qui n'est pas une panne : le résultat d'un
    /// rangement, la place gagnée par une compression.
    ///
    /// Séparée de `lastFailure` exprès. Faire passer un succès par le canal
    /// d'échec — bandeau d'avertissement, triangle orange — apprend à ignorer le
    /// bandeau, et c'est le bandeau qu'on a besoin de voir le jour où quelque
    /// chose rate vraiment.
    public var lastNotice: String?

    // MARK: - Rangement des anciens enregistrements

    /// Combien d'enregistrements sont encore rangés à plat, à l'ancienne.
    var legacyRecordingCount: Int { store.legacyCount }

    private(set) var isTidying = false

    /// Range les anciens enregistrements, un dossier chacun.
    ///
    /// **Sur demande explicite, jamais au lancement.** Déplacer plusieurs
    /// gigaoctets de réunions à l'insu de quelqu'un, au moment précis où il
    /// ouvre l'application, est le genre d'initiative qu'on ne prend pas — même
    /// quand le résultat est meilleur. Et si le déplacement tourne mal à
    /// mi-chemin, il vaut mieux que ce soit après un clic que pendant un
    /// démarrage.
    ///
    /// **Interdit aussi pendant la chaîne de fin**, et pas seulement pendant la
    /// capture. Une compression lit des morceaux bruts et écrit un fichier final
    /// dans un dossier ; les déplacer sous elle, c'est retirer le sol. Le garde
    /// d'origine ne regardait que `hasOpenSession`, qui est déjà faux quand la
    /// compression tourne — la fenêtre de tir durait donc toute la durée du
    /// post-traitement, c'est-à-dire le moment précis où l'utilisateur, qui
    /// vient de raccrocher, ouvre les réglages pour ranger ses réunions.
    func tidyRecordingFolders() {
        guard showsSessionBar == false, isTidying == false else { return }
        isTidying = true

        Task {
            let outcome = await store.tidyLegacyRecordings()
            isTidying = false
            if let outcome { lastNotice = outcome }
        }
    }

    // MARK: - Actions

    /// Démarre l'enregistrement de la réunion détectée. C'est le seul chemin
    /// automatique-assisté : détection → proposition → geste explicite.
    public func startPendingRecording() {
        guard let meeting = pendingMeeting else {
            startManualRecording()
            return
        }
        enqueueIntent { [weak self] in await self?.begin(meeting) }
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
        enqueueIntent { [weak self] in await self?.begin(meeting) }
    }

    /// **Les gestes d'enregistrement se suivent, ils ne se croisent pas.**
    ///
    /// Chaque clic créait sa propre tâche, et les deux lisaient l'état
    /// *avant* le premier `await`. Pause puis Arrêter, coup sur coup : les deux
    /// tâches voyaient `.recording`, les deux fermaient le même `SCStream` —
    /// dont la fermeture dure des minutes, voir `CaptureSession` — et si
    /// l'arrêt aboutissait le premier, la pause revenait ensuite remettre en
    /// `.paused` une réunion déjà conclue. Une double reprise pouvait de même
    /// ouvrir deux segments concurrents.
    ///
    /// La file rend la question sans objet : le second geste ne lit `isPaused`
    /// et `isRecording` qu'une fois le premier terminé, donc il voit l'état
    /// réel et non l'état d'il y a trois minutes. `await previous?.value`
    /// n'attend jamais une tâche annulée ou en échec — ces tâches ne lèvent
    /// pas — et une file vide ne coûte rien.
    ///
    /// Ce que ça ne corrige pas : `RecordingEngine` reste sans états
    /// transitoires, donc un appelant futur qui n'emprunterait pas cette file
    /// retrouverait la course. La décision appartient à `BranCore`.
    private var intents: Task<Void, Never>?

    private func enqueueIntent(_ work: @escaping @MainActor () async -> Void) {
        let previous = intents
        intents = Task { @MainActor in
            await previous?.value
            await work()
        }
    }

    public func togglePause() {
        enqueueIntent { [weak self] in
            guard let self else { return }
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
        // Même file que la pause : voir `enqueueIntent`. Le garde ci-dessus
        // reste lu tout de suite — il ne sert qu'à ne pas réveiller la machine
        // sur un clic de trop — et il est redoublé dans la file, parce que la
        // session a pu se conclure pendant l'attente.
        enqueueIntent { [weak self] in
            guard let self, engine.state.meeting != nil else { return }
            await engine.handle(.stop)
        }
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
        //
        // Le titre est relu dans la bibliothèque plutôt que pris sur `meeting` :
        // la réunion a pu être nommée à la main pendant qu'elle tournait, et
        // c'est ce nom-là qui doit se retrouver sur le dossier.
        await postProcess(
            meeting.id,
            title: store.recordings.first { $0.id == meeting.id }?.metadata.title ?? meeting.title,
            segments: segments,
            preservingSegments: verdict.writesEndedAt == false
        )
    }

    /// Fusion des segments, compression, puis préparation de l'audio du CRM.
    ///
    /// Lancé après la finalisation, jamais pendant : encoder en parallèle d'une
    /// capture volerait au flux le matériel vidéo dont il a besoin.
    ///
    /// **Le nom du dossier est aligné ici, et pas ailleurs.** C'est le premier
    /// instant où le titre définitif est connu : la réunion a pu être nommée à la
    /// main pendant qu'elle tournait, ou rattachée à un RDV du CRM qui porte le
    /// nom de l'entreprise. Renommer avant d'écrire le fichier final évite d'avoir
    /// à renommer le fichier ensuite, donc évite une seconde opération qui peut
    /// échouer à mi-chemin.
    private func postProcess(
        _ id: UUID,
        title: String?,
        segments: [URL],
        preservingSegments: Bool = false
    ) async {
        guard segments.isEmpty == false else { return }

        stepOrder.append(id)
        stepNames[id] = title
        defer {
            pipeline[id] = nil
            stepOrder.removeAll { $0 == id }
            stepNames[id] = nil
        }

        let folder = await store.alignFolderName(for: id)
        let pieces = Self.relocate(segments, into: folder)

        // La destination vient de `MeetingBundle` et n'est pas recomposée ici :
        // c'est la même règle qui décide où la vidéo s'écrit et où le balayage
        // ira la chercher, et deux endroits pour une même règle finissent
        // toujours par diverger d'une extension ou d'un séparateur.
        //
        // Le repli à plat couvre l'enregistrement dont le dossier n'a pas pu
        // être créé : il garde l'ancienne disposition, que la bibliothèque lit
        // toujours, et le rangement des réglages pourra s'en occuper plus tard.
        let destination = folder.map(MeetingBundle.videoDestination(in:))
            ?? store.root.appending(path: "\(id.uuidString).mp4")

        let startedAt = Date.now
        pipeline[id] = SessionProgress(stage: .merging, fraction: 0)

        do {
            let outcome = try await processor.process(
                segments: pieces,
                into: destination,
                preservingSegments: preservingSegments
            ) { fraction in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    // **Un rapport en retard ne ressuscite pas une étape
                    // terminée.** `requestMediaDataWhenReady` peut rappeler après
                    // la dernière image, et cette tâche est postée sur l'acteur
                    // principal : elle peut donc s'exécuter APRÈS que le
                    // post-traitement a rendu la main et vidé `pipeline`.
                    // Réécrire l'entrée à ce moment-là laissait une compression
                    // fantôme, figée à quelques pour cent, sur la ligne de
                    // bibliothèque d'une réunion pourtant terminée — et jusqu'à
                    // la fermeture de l'application, puisque plus personne ne
                    // devait la nettoyer.
                    guard self.stepOrder.contains(id) else { return }
                    self.pipeline[id] = SessionProgress(
                        stage: .merging,
                        fraction: fraction,
                        elapsed: .seconds(Int(Date.now.timeIntervalSince(startedAt)))
                    )
                }
            }

            await store.completeProcessing(
                id: id,
                originalBytes: outcome.originalBytes,
                segmentCount: segments.count
            )

            await prepareAudio(for: id, video: destination)

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
            // Les segments sont intacts : le post-traitement ne les supprime
            // qu'après avoir écrit un fichier final non vide.
            report("Compression impossible : \(error.localizedDescription) — les segments bruts sont conservés.")
        }

        await store.reload()
    }

    /// Extrait l'audio destiné au CRM et **le laisse à côté de la vidéo**.
    ///
    /// Avant, cette extraction n'avait lieu qu'au moment de l'envoi, dans le
    /// dossier temporaire, et le fichier était effacé en sortant. Trois
    /// conséquences, toutes mauvaises : impossible d'écouter ce qui est
    /// réellement parti au CRM ; impossible de le renvoyer à la main le jour où
    /// le CRM le refuse ; et l'attente de l'extraction tombait sur l'utilisateur
    /// au pire moment, celui où il venait de cliquer « envoyer ».
    ///
    /// Fait ici, c'est du temps machine pris pendant que personne n'attend — la
    /// vidéo vient d'être encodée, on est déjà dans le post-traitement — et le
    /// dossier du rendez-vous contient dès lors tout ce qu'il annonce : la vidéo,
    /// l'audio, la fiche.
    ///
    /// **Un échec ici n'est pas un échec de l'enregistrement.** La réunion est
    /// sur le disque, complète ; seule la commodité de l'envoi est perdue, et
    /// `UploadService` sait toujours extraire à la demande. Il se dit, il ne
    /// bloque rien.
    private func prepareAudio(for id: UUID, video: URL) async {
        guard let recording = store.recordings.first(where: { $0.id == id }),
              let destination = recording.audioDestination
        else { return }

        pipeline[id] = SessionProgress(stage: .exportingAudio)

        do {
            _ = try await AudioExporter.extractSpeechAudio(from: video, to: destination)
        } catch {
            report(
                "Audio du CRM non préparé pour « \(recording.displayTitle) » : "
                + "\(error.localizedDescription) La vidéo, elle, est intacte."
            )
        }
    }

    /// Retrouve les morceaux après un renommage de dossier.
    ///
    /// `alignFolderName` renomme le dossier du rendez-vous ; les URL des segments,
    /// elles, ont été relevées avant, et désignent l'ancien chemin. Sans ce
    /// rattrapage, `PostProcessor` ne trouverait plus aucun fichier et lèverait
    /// « Aucun segment exploitable » sur une réunion parfaitement enregistrée.
    ///
    /// **Le test d'existence dans les deux sens n'est pas une précaution
    /// décorative.** Quand la création du dossier a échoué, les segments sont
    /// restés à plat dans la racine : les réécrire vers un dossier les ferait
    /// pointer vers des fichiers qui n'existent pas, et transformerait un
    /// enregistrement récupérable en enregistrement perdu. On ne déplace donc une
    /// URL que si l'ancienne a disparu **et** que la nouvelle existe.
    private static func relocate(_ segments: [URL], into folder: URL?) -> [URL] {
        guard let folder else { return segments }
        let manager = FileManager.default

        return segments.map { url in
            guard manager.fileExists(atPath: url.path(percentEncoded: false)) == false else { return url }
            let candidate = folder.appending(path: url.lastPathComponent)
            return manager.fileExists(atPath: candidate.path(percentEncoded: false)) ? candidate : url
        }
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
    ///
    /// **Et sur la chaîne de fin aussi**, pour la même raison poussée d'un cran :
    /// la fusion lit les morceaux dans l'ancienne racine et y écrit son fichier
    /// final, pendant que la bibliothèque, elle, aurait déjà déménagé. La réunion
    /// se serait terminée d'écrire dans un dossier que plus personne ne balaie —
    /// invisible, et attribuée à une panne. `showsSessionBar` est exactement le
    /// prédicat voulu : il vaut « bran a encore quelque chose en cours sur cette
    /// racine ».
    func chooseStorageFolder() {
        guard showsSessionBar == false else {
            report("Impossible de changer de dossier pendant un enregistrement ou son traitement.")
            return
        }
        guard storage.chooseFolder() else { return }
        applyStorageRoot()
    }

    func resetStorageFolder() {
        guard showsSessionBar == false else { return }
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

    /// **Sans autorisation d'écran, il n'y a aucun titre à lire — donc rien à
    /// détecter, et rien à énumérer.**
    ///
    /// `kCGWindowName` n'est renseigné qu'avec l'autorisation Enregistrement de
    /// l'écran : sans elle, `WindowTitleDetector` parcourait douze fois par
    /// minute toutes les fenêtres du système pour n'en tirer strictement rien.
    /// Quelqu'un qui refuse l'autorisation et garde bran pour la dictée payait
    /// cette énumération pendant toute sa session.
    ///
    /// **Le verdict est mis en cache, et c'est la mesure qui l'impose.**
    /// `CGPreflightScreenCaptureAccess()` coûte **5,44 ms** sur ce Mac, contre
    /// **1,04 ms** pour l'énumération complète des fenêtres — cinq fois plus
    /// cher que ce qu'il sert à éviter. L'interroger à chaque tic aurait donc
    /// *aggravé* le défaut au lieu de le corriger. Une fois par minute, il ne
    /// coûte plus rien et laisse au plus soixante secondes entre la case cochée
    /// dans les Réglages système et la reprise de la détection — sans
    /// redémarrage.
    ///
    /// `ScreenAccess.verdict` n'est délibérément pas utilisé ici : sa seconde
    /// sonde est précisément l'énumération qu'on cherche à ne pas faire, et son
    /// cas `.unconfirmed` — autorisation cochée, aucune fenêtre témoin — doit
    /// laisser passer. Ne bloquer que ce qui est certain.
    private func screenTitlesAreReadable() -> Bool {
        let now = SuspendingClock.now
        if let probed = screenProbedAt, probed.duration(to: now) < Self.screenProbeInterval {
            return screenIsGranted
        }
        screenProbedAt = now
        screenIsGranted = ScreenAccess.isDeclaredGranted
        return screenIsGranted
    }

    private func tick() async {
        guard screenTitlesAreReadable() else { return }
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

    /// Une demande de démarrage est en vol.
    ///
    /// **Le verrou manquait, et il coûtait un dossier fantôme.** `begin` crée le
    /// dossier du rendez-vous et y écrit la fiche AVANT de demander le démarrage
    /// à la machine. Celle-ci ignore un second `.start` — c'est un de ses
    /// invariants — mais elle l'ignore *après* : deux clics rapprochés sur
    /// « Enregistrer », ou un clic doublé par la notification, fabriquaient donc
    /// deux dossiers et deux fiches, dont une pour une réunion qui n'a jamais
    /// démarré. Pire, le second `useFolder` prenait la place du premier : les
    /// morceaux de la réunion qui tournait réellement partaient dans le dossier
    /// de celle qui n'existait pas.
    ///
    /// Le verrou couvre toute la durée de `begin`, `await` compris — c'est
    /// exactement la fenêtre où la machine n'est pas encore passée en
    /// `.starting` et où `hasOpenSession` répond donc encore « non ».
    private var isOpeningSession = false

    private func begin(_ meeting: MeetingRef) async {
        guard hasOpenSession == false, isOpeningSession == false else { return }
        isOpeningSession = true
        defer { isOpeningSession = false }

        permissions.refresh()
        guard permissions.canRecord else {
            report("Autorisation manquante — enregistrement non démarré.")
            return
        }

        lastFailure = nil
        pendingMeeting = nil
        notifications.withdrawProposals()

        // Le dossier du rendez-vous et sa fiche sont créés AVANT le démarrage.
        // Une fiche sans `endedAt` signale ensuite une session interrompue :
        // c'est la sentinelle du §10, sans fichier `.lock` séparé à gérer.
        //
        // La capture apprend le dossier dans la foulée. Un `nil` — création
        // refusée — n'empêche pas d'enregistrer : les segments repartent à plat
        // dans la racine, et la bibliothèque sait lire les deux dispositions.
        // Perdre une réunion parce qu'un dossier n'a pas pu être créé serait
        // sans commune mesure avec le désagrément d'un fichier mal rangé.
        let folder = store.beginSession(meeting)
        await capture.useFolder(folder)

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
            // **L'intention change ce qui est admissible, donc elle se
            // déclare.** Sans elle, un enregistrement déjà lié à un rendez-vous
            // clos ou déjà transcrit était refusé ici même, alors que
            // l'auto-envoi est désactivé et que le geste attendu est justement
            // d'ouvrir la feuille pour laisser l'humain trancher.
            let eligibility = UploadEligibility.evaluate(
                booking: booking,
                isConfigured: uploads.configuration.isConfigured,
                intent: uploads.configuration.autoUpload ? .automatic : .manual
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
        // Un clic dans la feuille est un geste explicite : sans `.manual`, une
        // retranscription volontaire était refusée au dernier verrou alors que
        // la feuille venait de l'annoncer comme permise.
        uploads.send(recording, to: booking, complement: complement, intent: .manual)
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
                //
                // Pendant `.finalizing` non plus, et pour la même raison : plus
                // rien n'est capturé, `replayd` écrit ce qui l'a déjà été. Un
                // chrono qui continue pendant douze minutes de finalisation
                // ferait croire à une réunion de quarante-huit minutes.
                if self.isRecording {
                    self.elapsed = .seconds(Date.now.timeIntervalSince(started) - self.pausedDuration)
                }

                // Le poids, lui, se relève **tout le temps** : c'est le seul
                // signe visible que la finalisation avance, et c'est justement
                // là qu'on en a le plus besoin.
                if self.isPaused == false {
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
        finalizingStartedAt = nil
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
