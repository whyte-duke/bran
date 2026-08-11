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

    /// Comment la dernière livraison s'est terminée. `nil` tant qu'il n'y en a
    /// pas eu, ou qu'elle est en cours.
    ///
    /// Posée **une fois l'écriture aboutie**, jamais avant : chacun de ses cas
    /// affirme quelque chose de l'état du presse-papiers, et tant que `Paster`
    /// n'a pas rappelé, on n'en sait rien.
    ///
    /// **Un seul canal.** L'encoche a besoin de la distinction complète — il y a
    /// trois fins possibles et elles demandent trois gestes différents — tandis
    /// que le panneau n'a besoin que de la phrase. Publier les deux séparément
    /// donnerait deux sources pour la même vérité, dont une à oublier de mettre
    /// à jour ; `pasteFallbackNotice` est donc dérivé et non stocké.
    private(set) var pasteLanding: Paster.Landing?

    /// Ce qu'il reste à dire à l'utilisateur, ou `nil` quand tout s'est passé
    /// comme prévu. Lu par `DictationPane`.
    var pasteFallbackNotice: String? { pasteLanding?.notice }

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
    /// Surveille que le micro envoie réellement du son. Voir `startSilenceWatchdog`.
    private var watchdogTask: Task<Void, Never>?
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
        aimAtFrontmostApp()
        apply(machine.handle(.hotkeyDown))
    }

    /// Mémorise ce qu'on ne pourra plus apprendre plus tard : la cible du
    /// collage et, quand ça vaut la peine, le contenu du presse-papiers.
    ///
    /// **Un appui pendant une dictée en cours ne fait ni l'un ni l'autre.** En
    /// mode bascule, ce second appui est celui qui *arrête* — et c'est le cas
    /// qui reste. Le second, la répétition système de la touche tenue en mode
    /// maintien, n'arrive plus jusqu'ici : `HotkeyMonitor` écarte les `keyDown`
    /// répétés dans le callback du tap et tient la règle « un appui, un signal »
    /// avec `HeldTriggers`. Une touche modificatrice seule y échappait déjà —
    /// elle n'apparaît que dans `flagsChanged`, sur transition —, et c'est
    /// justement cette asymétrie entre les deux branches qui était le défaut.
    ///
    /// Cette garde-ci reste quand même, et pas par prudence rituelle : elle
    /// répond à une autre question. Un appui *légitime* pendant une dictée —
    /// celui qui arrête, en mode bascule — n'a pas plus le droit de réviser la
    /// cible qu'une répétition.
    ///
    /// Dans les deux cas, l'application au premier plan à cet instant n'est plus
    /// forcément celle qu'on visait : la prendre pour cible annule le point 1 de
    /// `Paster`, qui existe très exactement pour que la dictée atterrisse là où
    /// elle a commencé même si l'utilisateur est allé ailleurs entre-temps.
    ///
    /// Une correction précédente avait mis la *lecture* derrière cette condition
    /// et laissé la mise à jour de la cible inconditionnelle. C'était se tromper
    /// deux fois : le mode bascule réécrivait la cible avec l'application du
    /// moment de l'arrêt, et le mode maintien la réécrivait à chaque répétition.
    ///
    /// **La lecture, elle, a deux conditions de plus.** Elle n'est pas gratuite :
    /// lire un type *promis* réveille l'application source et peut durer des
    /// secondes (`Paster`, point 6), et depuis macOS 15.4 un accès au
    /// presse-papiers peut faire apparaître l'alerte système « bran a collé
    /// depuis une autre application ». Payer ça pour une dictée qu'on va refuser
    /// dans la milliseconde qui suit est un mauvais marché — et l'alerte, elle,
    /// est visible par l'utilisateur.
    ///
    /// Ces refus-là se connaissent avant d'avoir enregistré la moindre trame, et
    /// ce sont les seuls qu'on teste. Le reste — le flux audio qui ne démarre
    /// pas, le modèle qui ne répond pas — ne se sait qu'en essayant, et attendre
    /// de le savoir ferait perdre à la lecture sa seule raison d'être : avoir
    /// toute la durée de la dictée devant elle.
    private func aimAtFrontmostApp() {
        guard machine.phase.isBusy == false else { return }

        // La saisie sécurisée bloque la synthèse du ⌘V autant que la lecture du
        // clavier (`Paster`) : le collage est déjà connu impossible, donc il n'y
        // aura rien à restituer.
        let secureInput = HotkeyMonitor.isSecureInputActive

        // Micro refusé : `startCapture` va échouer tout de suite. Micro pas
        // encore demandé : une fenêtre système s'ouvre et l'utilisateur mettra
        // des secondes à répondre — deux alertes empilées, dont une évitable, et
        // une lecture entièrement spéculative.
        let microphoneReady = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized

        paster.rememberTarget(readingClipboard: secureInput == false && microphoneReady)
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
            aimAtFrontmostApp()
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
    /// collage rappelait `apply` en cascade, la machine passait à `.idle` avant
    /// qu'on ait annoncé `.pasting`, et l'encoche n'affichait jamais le texte
    /// transcrit — elle sautait de « Transcription… » à un panneau vide.
    ///
    /// Le collage, lui, ne cascade plus : `.pasted` n'arrive qu'au rappel de
    /// `Paster` (voir `performPaste`). Mais la cascade existe toujours ailleurs —
    /// `startCapture` peut échouer dans la même pile — et la garde reste donc ce
    /// qui rend chaque phase observable, quel que soit l'effet.
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
        pasteLanding = nil
        lastTranscript = nil

        // La saisie sécurisée bloque aussi bien la lecture du clavier que le
        // collage. Mieux vaut le dire avant d'enregistrer trente secondes pour
        // rien.
        if HotkeyMonitor.isSecureInputActive {
            apply(machine.handle(.failed(.secureInputActive(app: Self.secureInputSuspect()))))
            return
        }

        // Trois cas, et ils ne se traitent pas pareil. Les confondre laissait
        // l'encoche annoncer « écoute » sur un micro qui n'enregistrait rien :
        // la machine restait en `.capturing`, `startedAt` n'était jamais posé —
        // d'où un chrono figé à 00:00 — et l'arrêt ne rendait aucun échantillon,
        // donc « rien entendu ». Un refus doit se dire, pas se mimer.
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            requestMicrophoneThenStart()
            return
        case .denied, .restricted:
            apply(machine.handle(.failed(.microphoneDenied)))
            return
        @unknown default:
            apply(machine.handle(.failed(.microphoneDenied)))
            return
        }

        do {
            let device = AudioInputDevice.device(uid: settings.inputDeviceUID)
            FeatureLog.record(
                "dictée → micro « \(device?.name ?? "périphérique système") »"
                + " (réglage=\(settings.inputDeviceUID ?? "aucun"))"
            )
            try mic.start(deviceID: device?.id)
            startedAt = .now
            if settings.playsSound { Self.playStartCue() }
            startTicking()
            startSilenceWatchdog()
        } catch {
            apply(machine.handle(.failed(.captureFailed(error.localizedDescription))))
        }
    }

    /// Vérifie que le micro envoie réellement quelque chose.
    ///
    /// **Le principe : jamais de faux espoir.** Une encoche qui affiche « écoute »
    /// pendant qu'on parle dans un micro muet est pire qu'une erreur — on parle
    /// trente secondes avant de comprendre, et on ne sait toujours pas pourquoi.
    ///
    /// Deux vérifications, à deux instants, parce qu'elles ne détectent pas la
    /// même panne :
    ///
    /// ```
    ///   1,2 s   aucun échantillon reçu   → le flux ne tourne pas du tout
    ///   3,0 s   des échantillons, mais   → le flux tourne et rend du silence
    ///           un pic resté à zéro         numérique : micro coupé, mauvais
    ///                                        périphérique, autorisation périmée
    /// ```
    ///
    /// Le second seuil est volontairement plus long : quelqu'un peut appuyer sur
    /// le raccourci puis prendre une seconde avant de parler, et l'accuser d'un
    /// micro muet serait faux.
    private func startSilenceWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task { [weak self] in
            // Premier contrôle très tôt : si rien n'arrive au bout de 400 ms,
            // le périphérique imposé est muet. On repart sur le défaut système
            // avant que l'utilisateur ait fini sa première phrase, plutôt que de
            // lui annoncer une panne qu'on sait réparer.
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, Task.isCancelled == false, machine.phase == .capturing else { return }

            if mic.duration == 0, settings.inputDeviceUID != nil {
                do {
                    try mic.restartOnSystemDefault()
                } catch {
                    // **La panne est annoncée ici, avec sa vraie raison.**
                    // Avant, l'échec n'allait qu'au journal : le repli étant le
                    // dernier recours, la dictée continuait à vide et ne
                    // s'arrêtait qu'à la garde suivante, 800 ms plus tard, sur
                    // un « micro muet » générique. L'utilisateur perdait à la
                    // fois du temps et la seule information utile — ce que
                    // CoreAudio a refusé, et pourquoi.
                    FeatureLog.record("micro : la reprise système a échoué", error: error)
                    apply(machine.handle(.failed(.captureFailed(error.localizedDescription))))
                    return
                }
            }

            try? await Task.sleep(for: .milliseconds(800))
            guard Task.isCancelled == false, machine.phase == .capturing else { return }

            guard mic.duration > 0 else {
                FeatureLog.record("dictée : aucun échantillon après 1,2 s — le flux ne tourne pas")
                apply(machine.handle(.failed(.microphoneSilent)))
                return
            }

            try? await Task.sleep(for: .milliseconds(1800))
            guard Task.isCancelled == false, machine.phase == .capturing else { return }

            // Un vrai micro a toujours un plancher de bruit. Un pic exactement
            // nul sur trois secondes n'est pas du silence, c'est une panne.
            guard mic.peakLevel <= 0 else { return }
            FeatureLog.record("dictée : pic resté à zéro après 3 s — le flux rend du silence")
            apply(machine.handle(.failed(.microphoneSilent)))
        }
    }

    private func stopSilenceWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = nil
    }

    private func finishCapture() {
        stopSilenceWatchdog()
        stopTicking()
        capturedSamples = mic.stop()
        let duration = Double(capturedSamples.count) / SpeechAudioFormat.sampleRate
        let peak = mic.peakLevel
        startedAt = nil

        FeatureLog.record(String(
            format: "dictée ← %d échantillons, %.2f s, pic %.5f (seuils : %.2f s et 0,004)",
            capturedSamples.count, duration, peak, SpeechAudioFormat.minimumDuration
        ))
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
        stopSilenceWatchdog()
        currentToken = UUID()
        stopTicking()
        mic.discard()
        capturedSamples = []
        startedAt = nil
    }

    /// Colle le texte — et n'en tire aucune conclusion avant que ce soit vrai.
    ///
    /// **La dictée finit au rappel de `Paster`, pas au retour de `paste(_:)`.**
    /// Celui-ci ne fait que *poster* l'écriture du presse-papiers (`Paster`,
    /// point 8) : conclure là faisait passer la machine au repos pendant qu'un
    /// ⌘V était encore armé, donc autorisait une nouvelle dictée à démarrer et à
    /// écrire par-dessus la précédente — un chevauchement que les états de la
    /// machine déclarent impossible. En attendant `whenLanded`, la phase reste
    /// `.pasting`, donc `isBusy`, donc l'appui suivant ne démarre rien.
    ///
    /// **Et cette attente est bornée par `Paster`, pas par ici** (point 9 de son
    /// en-tête). Attendre un rappel qui pouvait ne jamais venir était le prix de
    /// la ligne précédente : une application source bloquée dans son XPC rendait
    /// la dictée muette, `isBusy` pour toujours, sans même un raccourci pour en
    /// sortir. Un minuteur *ici* aurait pu le corriger aussi, et aurait été le
    /// mauvais endroit : il y a trois appels à `Paster` dans le programme, donc
    /// trois minuteurs à écrire, dont celui qu'on oublie est celui qui gèle. Et
    /// c'est `Paster` qui sait quand l'écriture a été postée — mesurer depuis
    /// ici mesurerait en plus le saut d'isolation. La borne est donc une
    /// propriété de `paste(_:)`, et ce contrôleur n'a rien à faire de plus que
    /// répondre à ce qu'on lui dit.
    ///
    /// La valeur de retour, elle, répond à l'autre question — « vais-je seulement
    /// essayer ? » — et sert au journal : savoir si un collage était impossible
    /// dès le départ ou l'est devenu pendant l'attente change le diagnostic.
    private func performPaste(_ text: String) {
        lastTranscript = text

        let willTry = paster.paste(text) { [weak self] landing in
            guard let self else { return }
            // C'est seulement maintenant qu'on sait quelque chose de l'état du
            // presse-papiers — et `landing` est le seul à le savoir. Le
            // ternaire d'avant ne distinguait que deux fins et aurait affiché
            // « faites ⌘V » sur un `.stalled`, où il n'y a rien à coller.
            pasteLanding = landing
            // La transition part dans tous les cas, y compris `.stalled` : la
            // dictée est finie, ratée mais finie, et la laisser en `.pasting`
            // serait le gel qu'on vient de supprimer.
            apply(machine.handle(.pasted))
        }

        if willTry == false {
            FeatureLog.record(
                "dictée : collage impossible dès le départ (cible absente ou saisie"
                + " sécurisée) — le texte partira quand même au presse-papiers"
            )
        }
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

    /// Demande le micro, puis démarre la capture.
    ///
    /// Deux pièges, tous deux vécus :
    ///
    /// **La fenêtre système peut s'ouvrir derrière tout le reste.** bran est un
    /// agent sans icône du Dock : il ne passe pas au premier plan de lui-même, et
    /// une demande d'autorisation invisible ressemble exactement à une
    /// application qui a planté.
    ///
    /// **On relance la capture, pas l'événement.** Renvoyer `.hotkeyDown` à une
    /// machine déjà en `.capturing` la fait basculer en `.transcribing` en mode
    /// bascule — donc arrêter la dictée à l'instant précis où elle vient d'être
    /// autorisée.
    private func requestMicrophoneThenStart() {
        NSApp.activate(ignoringOtherApps: true)

        Task { [weak self] in
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            guard let self else { return }

            guard granted else {
                apply(machine.handle(.failed(.microphoneDenied)))
                return
            }

            // Le raccourci a pu être relâché, ou la dictée annulée, pendant que
            // la fenêtre système attendait une réponse.
            guard machine.phase == .capturing else { return }
            startCapture()
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
