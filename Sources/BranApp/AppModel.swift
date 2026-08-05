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

    /// Le guet du clavier, **partagé** par la dictée et la capture. Un seul
    /// `CGEventTap` pour toute l'application : deux taps doubleraient le
    /// travail à chaque frappe du système et pourraient mourir séparément.
    private let shortcuts = ShortcutRouter()

    private var notchPresenter: NotchPresenter?

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

        Task { [weak self, capture] in
            for await reason in capture.failures {
                guard let self else { return }
                self.engine.reportFailure(reason)
                self.lastFailure = reason
            }
        }

        notifications.onStartRequested = { [weak self] in
            self?.startPendingRecording()
        }
        notifications.configure()

        Task { await capture.updateQuality(quality) }
        applyStorageRoot()

        directory.start()
        startDictation()
        startSnapshot()

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

    /// Vrai tant qu'une session est ouverte, en cours ou en pause. C'est ce qui
    /// commande l'affichage de la barre de pilotage.
    public var hasOpenSession: Bool { isRecording || isPaused }

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

    public func stopRecording() {
        guard let meeting = engine.state.meeting else { return }

        Task {
            await engine.handle(.stop)
            recordingStartedAt = nil
            pausedAt = nil
            stopTicking()

            let segments = engine.segments
            engine.clearSegments()
            await store.completeSession(id: meeting.id)
            await postProcess(meeting.id, segments: segments)
        }
    }

    /// Fusion des segments puis compression, en une seule passe d'encodage.
    ///
    /// Lancé après la finalisation, jamais pendant : encoder en parallèle d'une
    /// capture volerait au flux le matériel vidéo dont il a besoin.
    private func postProcess(_ id: UUID, segments: [URL]) async {
        guard segments.isEmpty == false else { return }

        let destination = store.root.appending(path: "\(id.uuidString).mp4")
        processingProgress[id] = 0

        do {
            let outcome = try await processor.process(segments: segments, into: destination) { fraction in
                Task { @MainActor [weak self] in self?.processingProgress[id] = fraction }
            }

            processingProgress[id] = nil
            await store.completeProcessing(
                id: id,
                originalBytes: outcome.originalBytes,
                segmentCount: segments.count
            )

            let percent = (outcome.savedFraction * 100).formatted(.number.precision(.fractionLength(0)))
            lastSaving = "\(outcome.originalBytes.formatted(.byteCount(style: .file))) → \(outcome.finalBytes.formatted(.byteCount(style: .file))) (−\(percent) %)"
            await store.reload()
            await offerUpload(for: id)
        } catch {
            processingProgress[id] = nil
            // Les segments sont intacts : le post-traitement ne les supprime
            // qu'après avoir écrit un fichier final non vide.
            lastFailure = "Compression impossible : \(error.localizedDescription) — les segments bruts sont conservés."
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
    func chooseStorageFolder() {
        guard isRecording == false else {
            lastFailure = "Impossible de changer de dossier pendant un enregistrement."
            return
        }
        guard storage.chooseFolder() else { return }
        applyStorageRoot()
    }

    func resetStorageFolder() {
        guard isRecording == false else { return }
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
            // Une session en pause s'arrête aussi : la réunion est terminée.
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
            lastFailure = "Autorisation manquante — enregistrement non démarré."
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
                lastFailure = eligibility.blockingReason
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
            lastFailure = "CRM injoignable : \(error.localizedDescription)"
        }
    }

    /// Envoi demandé à la main depuis la bibliothèque.
    func requestUpload(for recording: Recording) {
        Task {
            guard uploads.configuration.isConfigured else {
                lastFailure = "Liaison CRM non configurée — voir les Réglages."
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
                lastFailure = "CRM injoignable : \(error.localizedDescription)"
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
