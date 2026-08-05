import AppKit
import AVFoundation
import BranSpeech
import Foundation
import Observation

/// L'orchestrateur de la dictée.
///
/// Il ne décide de rien : `DictationMachine` décide, lui exécute. C'est ce
/// découplage qui permet de tester tous les enchaînements — annulation en
/// pleine transcription, appui répété, plafond atteint — en deux millisecondes
/// et sans micro.
@MainActor
@Observable
final class DictationController {

    // MARK: - État observable

    private(set) var phase: DictationMachine.Phase = .idle
    /// Instant du début de la capture, pour afficher la durée qui court.
    private(set) var startedAt: Date?
    private(set) var lastTranscript: String?
    /// Renseigné quand le texte n'a pas pu être collé mais reste au
    /// presse-papiers — l'utilisateur doit le savoir, pas le deviner.
    private(set) var pasteFallbackNotice: String?

    let settings: DictationSettings
    let store: DictationStore
    let host = SpeechModelHost()

    // MARK: - Machinerie

    private var machine = DictationMachine()
    private let mic = MicCapture()
    private let paster = Paster()
    /// Le guet du clavier est **partagé** avec la capture de texte : un seul
    /// `CGEventTap` pour toute l'application. Voir `HotkeyMonitor`.
    private let monitor: HotkeyMonitor

    private var capturedSamples: [Float] = []
    private var tickTask: Task<Void, Never>?
    /// Jeton de la dictée en cours. Une transcription qui revient après une
    /// annulation porte un jeton périmé et se jette en silence.
    private var currentToken = UUID()

    var onPhaseChange: ((DictationMachine.Phase) -> Void)?

    /// « Rien entendu » n'est pas une phase : c'est un retour au repos avec une
    /// raison. Sans ce signal, l'encoche afficherait « annulé » alors que
    /// l'utilisateur a bien appuyé et bien relâché — et il chercherait ce qu'il
    /// a fait de travers.
    var onEmpty: (() -> Void)?

    init(settings: DictationSettings, store: DictationStore, monitor: HotkeyMonitor) {
        self.settings = settings
        self.store = store
        self.monitor = monitor
    }

    // MARK: - Cycle de vie

    /// Active ou désactive la surveillance du clavier.
    ///
    /// Retourne `false` quand l'Accessibilité manque : l'appelant doit alors
    /// proposer de l'accorder plutôt que d'afficher un interrupteur qui se
    /// remet tout seul sur « non ».
    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        guard enabled else {
            // On retire la liaison, pas le tap : la capture de texte peut
            // encore s'en servir. Désinstaller ici rendrait l'autre fonction
            // muette sans que personne comprenne pourquoi.
            monitor.bind(.dictation, to: nil)
            settings.isEnabled = false
            return true
        }

        monitor.bind(.dictation, to: settings.trigger)
        monitor.cancelKey = settings.cancelKey
        machine.trigger = settings.triggerMode

        guard monitor.install() else {
            settings.isEnabled = false
            return false
        }

        settings.isEnabled = true
        host.idleUnloadDelay = TimeInterval(settings.idleUnloadMinutes) * 60
        return true
    }

    /// Réapplique les réglages à chaud, sans redémarrer l'application.
    func applySettings() {
        if settings.isEnabled { monitor.bind(.dictation, to: settings.trigger) }
        monitor.cancelKey = settings.cancelKey
        machine.trigger = settings.triggerMode
        paster.restoresClipboard = settings.restoresClipboard
        host.idleUnloadDelay = TimeInterval(settings.idleUnloadMinutes) * 60
        store.setRetention(settings.retention)

        if settings.isEnabled, monitor.isInstalled == false {
            _ = monitor.install()
        }
    }

    var isMonitoring: Bool { monitor.isInstalled }

    var isAccessibilityTrusted: Bool { HotkeyMonitor.isTrusted }

    // MARK: - Signaux du clavier

    /// Appelés par `ShortcutRouter`, qui possède le tap partagé.
    func hotkeyDown() {
        // Le chargement démarre à l'appui, en parallèle de la capture. C'est
        // ce qui permet de décharger le modèle sans jamais faire attendre.
        host.warmUp()
        paster.rememberTarget()
        apply(machine.handle(.hotkeyDown))
    }

    func hotkeyUp() {
        apply(machine.handle(.hotkeyUp))
    }

    /// Vrai quand une dictée est en cours. Sert au routeur pour arbitrer entre
    /// les deux fonctions.
    var isBusy: Bool { machine.phase.isBusy }

    /// Point d'entrée depuis l'interface — le bouton « Dicter » de la fenêtre.
    func toggleFromUI() {
        if machine.phase == .capturing {
            apply(machine.handle(settings.triggerMode == .hold ? .hotkeyUp : .hotkeyDown))
        } else if machine.phase.isBusy == false {
            host.warmUp()
            paster.rememberTarget()
            apply(machine.handle(.hotkeyDown))
        }
    }

    func cancel() {
        guard machine.phase.isBusy else { return }
        apply(machine.handle(.cancelRequested))
    }

    func acknowledgeFailure() {
        machine.acknowledgeFailure()
        publish()
    }

    // MARK: - Exécution des effets

    /// Publie **avant** d'exécuter les effets, puis après.
    ///
    /// Sans le premier `publish()`, la phase `.pasting` n'était jamais vue : le
    /// collage rappelle `apply` en cascade, la machine passait à `.idle` avant
    /// qu'on ait annoncé `.pasting`, et l'encoche n'affichait jamais le texte
    /// transcrit — elle sautait de « Transcription… » à un panneau vide.
    private func apply(_ effects: [DictationMachine.Effect]) {
        publish()

        for effect in effects {
            switch effect {
            case .startCapture: startCapture()
            case .finishCaptureAndTranscribe: finishCapture()
            case .discardCapture: discardCapture()
            case .paste(let text): performPaste(text)
            case .announceEmpty: announceEmpty()
            }
        }
        publish()
    }

    private func startCapture() {
        currentToken = UUID()
        pasteFallbackNotice = nil
        lastTranscript = nil

        // La saisie sécurisée bloque aussi bien la lecture du clavier que le
        // collage. Mieux vaut le dire avant d'enregistrer trente secondes pour
        // rien.
        if HotkeyMonitor.isSecureInputActive {
            apply(machine.handle(.failed(.secureInputActive(app: Self.secureInputSuspect()))))
            return
        }

        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            requestMicrophoneThenRetry()
            return
        }

        do {
            let device = AudioInputDevice.device(uid: settings.inputDeviceUID)
            try mic.start(deviceID: device?.id)
            startedAt = .now
            if settings.playsSound { Self.playStartCue() }
            startTicking()
        } catch {
            apply(machine.handle(.failed(.captureFailed(error.localizedDescription))))
        }
    }

    private func finishCapture() {
        stopTicking()
        capturedSamples = mic.stop()
        let duration = Double(capturedSamples.count) / SpeechAudioFormat.sampleRate
        let peak = mic.peakLevel
        startedAt = nil
        if settings.playsSound { Self.playStopCue() }

        // Deux façons de n'avoir rien dit, et elles méritent le même traitement :
        // trop court, ou silencieux. Coller le fruit de l'imagination du modèle
        // dans le document de quelqu'un est la pire issue possible.
        guard duration >= SpeechAudioFormat.minimumDuration, peak > 0.004 else {
            capturedSamples = []
            apply(machine.handle(.transcribedNothing))
            return
        }

        let token = currentToken
        let samples = capturedSamples
        let startedDate = Date().addingTimeInterval(-duration)

        Task { [weak self] in
            guard let self else { return }
            do {
                let outcome = try await host.transcribe(samples, language: settings.language)
                guard token == currentToken else { return }  // annulée entre-temps

                let corrected = settings.vocabulary.apply(to: outcome.text)
                await record(
                    text: corrected,
                    raw: outcome.text,
                    samples: samples,
                    duration: duration,
                    startedAt: startedDate,
                    processingTime: outcome.processingTime,
                    confidence: outcome.confidence
                )

                if corrected.isEmpty {
                    apply(machine.handle(.transcribedNothing))
                } else {
                    apply(machine.handle(.transcribed(corrected)))
                }
            } catch {
                guard token == currentToken else { return }
                // L'audio est gardé : l'échec devient réessayable depuis
                // l'historique plutôt que perdu.
                await record(
                    text: "",
                    raw: nil,
                    samples: samples,
                    duration: duration,
                    startedAt: startedDate,
                    processingTime: nil,
                    confidence: nil,
                    failure: error.localizedDescription
                )
                apply(machine.handle(.failed(.transcriptionFailed(error.localizedDescription))))
            }
        }
    }

    private func discardCapture() {
        currentToken = UUID()
        stopTicking()
        mic.discard()
        capturedSamples = []
        startedAt = nil
    }

    private func performPaste(_ text: String) {
        lastTranscript = text
        let pasted = paster.paste(text)
        pasteFallbackNotice = pasted
            ? nil
            : "Le texte n'a pas pu être collé — il est dans le presse-papiers, faites ⌘V."
        apply(machine.handle(.pasted))
    }

    private func announceEmpty() {
        lastTranscript = nil
        capturedSamples = []
        onEmpty?()
    }

    // MARK: - Persistance

    private func record(
        text: String,
        raw: String?,
        samples: [Float],
        duration: TimeInterval,
        startedAt: Date,
        processingTime: TimeInterval?,
        confidence: Double?,
        failure: String? = nil
    ) async {
        let entry = TranscriptEntry(
            createdAt: startedAt,
            duration: duration,
            text: text,
            rawText: raw != text ? raw : nil,
            language: settings.language.code,
            confidence: confidence,
            processingTime: processingTime,
            modelVersion: SpeechModelHost.modelName,
            failure: failure
        )
        await store.save(entry, samples: samples)
    }

    /// Les transcriptions en cours de relance.
    ///
    /// Sans cet état, réessayer était un clic sans aucun retour : le texte
    /// restait le même pendant deux secondes, et on ne savait pas si le bouton
    /// avait été pris en compte. On recliquait, et deux transcriptions partaient.
    private(set) var retrying: Set<UUID> = []

    func isRetrying(_ id: UUID) -> Bool { retrying.contains(id) }

    /// Relance la transcription d'une entrée conservée.
    func retry(_ entry: TranscriptEntry) {
        guard let url = store.audioURL(for: entry) else { return }
        // Un second clic pendant que ça tourne ne doit rien relancer.
        guard retrying.contains(entry.id) == false else { return }

        retrying.insert(entry.id)
        // Le modèle est peut-être froid : on le réveille tout de suite, comme à
        // l'appui sur le raccourci.
        host.warmUp()

        Task { [weak self] in
            guard let self else { return }
            defer { retrying.remove(entry.id) }

            do {
                let samples = try DictationStore.readSamples(from: url)
                let outcome = try await host.transcribe(samples, language: settings.language)
                let corrected = settings.vocabulary.apply(to: outcome.text)

                store.mutate(entry.id) {
                    $0.text = corrected
                    $0.rawText = outcome.text != corrected ? outcome.text : nil
                    $0.confidence = outcome.confidence
                    $0.processingTime = outcome.processingTime
                    $0.language = settings.language.code
                    $0.failure = nil
                }
            } catch {
                store.mutate(entry.id) { $0.failure = error.localizedDescription }
            }
        }
    }

    /// Réapplique le dictionnaire à une entrée sans relancer le modèle.
    ///
    /// Gratuit, instantané, et ça marche même quand l'audio a été purgé — c'est
    /// tout l'intérêt d'avoir gardé le texte brut.
    func reapplyVocabulary(to entry: TranscriptEntry) {
        let source = entry.rawText ?? entry.text
        let corrected = settings.vocabulary.apply(to: source)
        store.mutate(entry.id) {
            $0.text = corrected
            $0.rawText = corrected != source ? source : nil
        }
    }

    func copy(_ entry: TranscriptEntry) {
        paster.copyOnly(entry.text)
    }

    // MARK: - Horloge et publication

    /// Lu directement depuis le tampon partagé, sans passer par une propriété
    /// observable. Republier un tableau vingt fois par seconde ferait recalculer
    /// tout ce qui observe le contrôleur — la bannière, le menu — alors que seul
    /// le `Canvas` de l'encoche s'en sert.
    var waveform: [Float] { mic.waveform }

    /// Surveille le plafond de durée, rien d'autre.
    ///
    /// Quatre fois par seconde suffit : personne ne remarquera 250 ms d'écart
    /// sur un arrêt à dix minutes, et c'est autant de réveils en moins.
    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while Task.isCancelled == false {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, Task.isCancelled == false else { return }

                if mic.duration >= SpeechAudioFormat.maximumDuration {
                    apply(machine.handle(.durationCapReached))
                    return
                }
            }
        }
    }

    private func stopTicking() {
        tickTask?.cancel()
        tickTask = nil
    }

    private func publish() {
        let next = machine.phase
        guard next != phase else { return }
        phase = next
        onPhaseChange?(next)
    }

    var elapsed: TimeInterval {
        guard let startedAt else { return 0 }
        return Date().timeIntervalSince(startedAt)
    }

    // MARK: - Micro

    private func requestMicrophoneThenRetry() {
        Task { [weak self] in
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            guard let self else { return }
            if granted {
                apply(machine.handle(.hotkeyDown))
            } else {
                apply(machine.handle(.failed(.microphoneDenied)))
            }
        }
    }

    // MARK: - Retours sonores

    /// Deux repères sonores, volontairement discrets.
    ///
    /// Avec un casque et l'encoche hors du champ de vision, c'est souvent le
    /// seul retour réellement perçu — mais on dicte vingt fois par heure, et un
    /// son à plein volume vingt fois par heure devient une agression. À 12 %,
    /// on l'entend sans jamais y penser.
    ///
    /// Les instances sont conservées : `NSSound(named:)` relit le fichier depuis
    /// le disque à chaque appel, ce qui ajoute un délai juste avant de parler.
    private static let startCue = DictationController.cue("Tink")
    private static let stopCue = DictationController.cue("Morse")

    private static func cue(_ name: String) -> NSSound? {
        let sound = NSSound(named: name)
        sound?.volume = 0.12
        return sound
    }

    private static func playStartCue() { startCue?.play() }

    private static func playStopCue() {
        // Rejouer un son déjà en cours ne fait rien : il faut le rembobiner.
        stopCue?.stop()
        stopCue?.play()
    }

    /// macOS ne dit pas qui a activé la saisie sécurisée. On nomme le suspect le
    /// plus probable — l'application au premier plan — plutôt que rien.
    private static func secureInputSuspect() -> String? {
        NSWorkspace.shared.frontmostApplication?.localizedName
    }
}
