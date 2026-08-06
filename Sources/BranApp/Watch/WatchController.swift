import AppKit
import BranWatch
import CoreGraphics
import Foundation
import Observation

/// **L'orchestrateur du veilleur.** Il ne décide rien : `WatchResolver` décide,
/// lui échantillonne, lit et publie.
///
/// ```
///   transcriptions ─┐
///                   ├─▶ [LaneObservation] ─▶ WatchResolver ─▶ WatchVerdict
///   pixels ─────────┘                              │              │
///                                                  │              ├─▶ WatchPane
///   présence humaine ──────────────────────────────┘              ├─▶ AttentionOverlay
///                                                                 └─▶ WatchStore
/// ```
///
/// Le découpage est celui de la dictée et de la capture, et pour la même
/// raison : le résolveur se teste en une milliseconde, l'orchestrateur ne se
/// teste pas du tout parce qu'il touche à l'écran, à l'horloge et au disque.
@MainActor
@Observable
final class WatchController {

    // MARK: - État observable

    private(set) var verdict: WatchVerdict = .silent
    private(set) var human: HumanPresence = .unavailable(reason: "pas encore mesurée")
    /// Instant du dernier tic complet. `nil` tant que rien n'a été observé :
    /// c'est ce qui distingue « aucune voie » de « pas encore regardé ».
    private(set) var lastTickAt: Date?
    private(set) var pause: Pause?
    /// Ce qui empêche d'observer les fenêtres, quand quelque chose l'empêche.
    private(set) var screenProblem: String?
    /// Vrai pendant qu'un prélèvement de pixels est en cours.
    private(set) var isSampling = false

    /// Pourquoi le veilleur s'est tu. Chacun de ces cas est **volontaire** : un
    /// veilleur silencieux sans explication ressemble à un veilleur cassé.
    enum Pause: Equatable {
        case disabled
        case muted
        case lowPower
        case displayAsleep

        var label: String {
            switch self {
            case .disabled: "veille désactivée"
            case .muted: "silence — réunion en cours"
            case .lowPower: "silence — mode économie d'énergie"
            case .displayAsleep: "écran éteint"
            }
        }
    }

    let settings: WatchSettings
    let store: WatchStore

    /// **Correctif CR-4.** Le prédicat s'appelle `isMuted` et pas
    /// `isRecording` parce que ce dont il protège est un **partage d'écran** :
    /// si l'utilisateur partage son écran en réunion sans que bran enregistre,
    /// le panneau d'attention montrerait le nom de ses clients à ses clients.
    ///
    /// Une fermeture, pas une référence : c'est le patron du dépôt
    /// (`DictationStore(root:)`, `SnapshotController.onPhaseChange`) et surtout
    /// c'est ce qui permet aux modules de ne pas se connaître. `AppModel` sait
    /// qu'une réunion est détectée ; le veilleur n'a pas à savoir ce qu'est une
    /// réunion.
    ///
    /// **Assignée après la construction, et pas par l'initialiseur** : la
    /// fermeture capture `AppModel`, qui ne peut pas se référencer lui-même
    /// avant d'avoir fini d'initialiser toutes ses propriétés — dont celle-ci.
    /// `notifications.onStartRequested` est câblé de la même façon, dix lignes
    /// plus bas, pour exactement la même raison.
    ///
    /// Le défaut est « on ne se tait pas » : un veilleur qui se tairait par
    /// omission de câblage serait un veilleur mort en silence.
    var isMuted: @MainActor () -> Bool = { false }

    /// Publié à chaque verdict. `AttentionOverlay` s'y branche.
    var onVerdict: ((WatchVerdict) -> Void)?

    // MARK: - Machinerie

    private let sampler = WindowSampler()
    private var loop: Task<Void, Never>?

    /// L'origine des durées, sur l'horloge qui **s'arrête pendant la veille**.
    /// Voir `WatchClock` : c'est tout le correctif CR-2.
    private let bootedAt = SuspendingClock.now
    private var previousInstant = WatchClock.Instant.now
    private let focus: HumanFocus

    /// Les dernières mesures de pixels, par clé de voie, et leur âge.
    private var pixels: [String: WindowSampler.Measurement] = [:]
    private var pixelsAt: Duration = .zero
    /// Depuis quand un prélèvement est en cours. Sert de garde-fou : voir
    /// `requestSample`.
    private var samplingSince: Duration?
    /// Jeton de génération, patron de `SnapshotController.currentToken` : un
    /// prélèvement lancé avant un réveil n'a plus le droit de publier.
    private var generation = UUID()

    private var observers: [any NSObjectProtocol] = []

    init(settings: WatchSettings, store: WatchStore) {
        self.settings = settings
        self.store = store
        self.focus = HumanFocus(startedAt: .zero)
        observeSystem()
    }

    // MARK: - Cycle de vie

    func applySettings() {
        store.setRetention(settings.retention, tickInterval: settings.tickInterval)
        setEnabled(settings.isEnabled)
    }

    func setEnabled(_ enabled: Bool) {
        settings.isEnabled = enabled

        guard enabled else {
            loop?.cancel()
            loop = nil
            pause = .disabled
            // Les intervalles ouverts se ferment : les laisser courir écrirait
            // demain une attente de douze heures qui n'a jamais eu lieu.
            store.flush()
            verdict = .silent
            onVerdict?(verdict)
            return
        }

        guard loop == nil else { return }
        pause = nil
        loop = Task { [weak self] in await self?.run() }
    }

    var uptime: Duration { bootedAt.duration(to: SuspendingClock.now) }

    // MARK: - La boucle

    /// **L'échéance est calculée en tête de boucle, pas après le travail.**
    ///
    /// Le spike faisait dormir `interval` *après* avoir tout capturé : à vingt
    /// fenêtres, le tic de 2 s dérivait vers 3 s, et tous les seuils temporels
    /// glissaient d'un tiers sans que rien ne le dise. Ici, un tic qui déborde
    /// mange sa propre pause, il ne décale pas le suivant.
    ///
    /// `clock: .suspending` pour la même raison que tout le reste : une pause de
    /// quatre secondes ne doit pas se transformer en pause de huit heures parce
    /// qu'on a refermé le capot au milieu.
    private func run() async {
        var deadline = SuspendingClock.now

        while Task.isCancelled == false {
            let now = SuspendingClock.now
            if deadline < now { deadline = now }
            deadline = deadline.advanced(by: .seconds(settings.tickInterval))

            await tick()

            try? await Task.sleep(
                until: deadline,
                tolerance: .milliseconds(200),
                clock: .suspending
            )
        }
    }

    private func tick() async {
        let clock = WatchClock(tickInterval: settings.tickInterval)
        let step = clock.step(from: previousInstant)
        previousInstant = .now
        let uptime = self.uptime
        let now = Date.now

        // CR-2. Après une veille, toutes les durées d'avant sont fausses et les
        // vignettes d'hier soir ne ressemblent plus à rien. On oublie tout et on
        // repart d'inconnu plutôt que de réveiller quelqu'un avec cinq alertes
        // inventées.
        if step.jumped {
            forgetEverything()
        }

        // Le jour a changé : un intervalle qui commence à 23 h 50 et se ferme à
        // 8 h du matin appartiendrait à deux fichiers-jour à la fois.
        if store.dayChanged(at: now) {
            store.flush()
            await store.reload()
        }

        guard let reason = idleReason() else {
            pause = nil
            await observe(at: now, uptime: uptime, elapsed: step.elapsed, clockJumped: step.jumped)
            return
        }

        pause = reason
        // On se tait **et on n'écrit rien**, pas même une fermeture. Les
        // intervalles ouverts cessent simplement de battre : au retour, le
        // registre verra que le battement est trop tardif, fermera la ligne sur
        // son dernier battement connu et en ouvrira une neuve. Le journal montre
        // donc un trou pendant la réunion — ce qui est la vérité, plutôt qu'un
        // « travaille » de soixante minutes que personne n'a observé.
        verdict = .silent
        onVerdict?(verdict)
    }

    /// Les raisons de ne rien faire ce tic.
    ///
    /// Le mode économie d'énergie suffit, sans tester la source d'alimentation :
    /// c'est un interrupteur que l'utilisateur a actionné lui-même, et le
    /// respecter sur secteur ne coûte rien de plus qu'un veilleur silencieux
    /// pendant qu'on ne lui demande rien.
    private func idleReason() -> Pause? {
        if settings.isEnabled == false { return .disabled }
        if isMuted() { return .muted }
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return .lowPower }
        // Écran éteint : personne ne regarde, et le compositeur ne rendrait de
        // toute façon que des images figées.
        if CGDisplayIsAsleep(CGMainDisplayID()) != 0 { return .displayAsleep }
        return nil
    }

    // MARK: - Un tour d'observation

    private func observe(
        at now: Date,
        uptime: Duration,
        elapsed: TimeInterval,
        clockJumped: Bool
    ) async {
        // Les transcriptions d'abord : elles ne coûtent aucune autorisation, et
        // une voie certaine dispense de capturer sa fenêtre.
        let certain = await Task.detached(priority: .utility) {
            AgentTranscripts.observations(now: now)
        }.value

        let certainKeys = Set(certain.map(\.identity.key))
        human = Self.presence()
        focus.update(uptime: uptime, human: human, within: settings.tickInterval * 2)

        let windows = watchWindows(certain: certain, keys: certainKeys, uptime: uptime)

        let resolver = WatchResolver(thresholds: settings.thresholds)
        let fresh = resolver.resolve(
            observations: certain + windows,
            human: human,
            isMuted: false,
            clockJumped: clockJumped,
            now: now
        )

        verdict = fresh
        lastTickAt = now
        onVerdict?(fresh)

        let sources = Dictionary(
            uniqueKeysWithValues: (certain + windows).map { observation in
                (observation.identity.key, Self.source(of: observation))
            }
        )
        store.record(
            fresh.lanes.map { LaneRecord(lane: $0, source: sources[$0.identity.key] ?? .aucun) },
            at: now,
            elapsed: elapsed
        )
    }

    private static func source(of observation: LaneObservation) -> WatchEvent.Source {
        if observation.certain != nil { return .certain }
        if observation.motionRatio != nil { return .pixels }
        return .aucun
    }

    // MARK: - Les pixels

    /// Les observations tirées des fenêtres, et le lancement du prélèvement
    /// suivant.
    ///
    /// Les mesures utilisées sont **celles du prélèvement précédent** : la
    /// capture est asynchrone et peut prendre plus longtemps qu'un tic, et
    /// attendre sa fin figerait la boucle. Décaler d'un tic coûte quatre
    /// secondes de retard sur un seuil qui en vaut cent quatre-vingts.
    private func watchWindows(
        certain: [LaneObservation],
        keys certainKeys: Set<String>,
        uptime: Duration
    ) -> [LaneObservation] {
        guard settings.watchesWindows else {
            screenProblem = nil
            return []
        }

        guard ScreenAccess.isUsable else {
            // Le capteur certain continue de fonctionner sans autorisation : le
            // veilleur reste utile, il le dit, et il n'invente pas de voies.
            screenProblem = ScreenAccess.diagnosis
            return []
        }
        screenProblem = nil

        requestSample(uptime: uptime, certainKeys: certainKeys)

        // Des mesures plus vieilles que deux tics ne valent plus rien : le
        // prélèvement s'est figé ou la fenêtre a disparu. `motionRatio: nil`
        // donne `.unknown`, ce qui est la forme exacte de CR-5.
        let staleAfter = settings.tickInterval * 2
        let age = WatchClock.seconds(from: pixelsAt, to: uptime)
        let folders = LaneDeduplication.folderNames(of: certain.map(\.identity))

        return pixels.values
            .filter { certainKeys.contains($0.identity.key) == false }
            .filter { LaneDeduplication.isDistinct($0.identity, from: folders) }
            .map { measurement in
                let usable = age <= staleAfter
                return LaneObservation(
                    identity: measurement.identity,
                    motionRatio: usable ? measurement.motionRatio : nil,
                    stillFor: usable ? measurement.stillFor : nil,
                    certain: nil,
                    lastTouchedByHuman: focus.sinceTouched(measurement.identity.key, uptime: uptime)
                )
            }
    }

    /// Lance un prélèvement, au plus un à la fois.
    ///
    /// `SCScreenshotManager.captureImage` n'a **aucun délai d'expiration** et
    /// peut se figer indéfiniment. Deux garde-fous, tous deux déjà présents
    /// ailleurs dans le dépôt : l'échéance de `CaptureSignals.waitForFinish` —
    /// ici, au bout de trente secondes on repart avec un nouveau jeton — et le
    /// jeton de génération de `SnapshotController`, qui fait qu'un prélèvement
    /// ressuscité ne publie rien.
    private func requestSample(uptime: Duration, certainKeys: Set<String>) {
        if let since = samplingSince {
            guard WatchClock.seconds(from: since, to: uptime) > 30 else { return }
            screenProblem = "La capture d'écran ne répond plus : les voies observées à l'image passent à l'état inconnu."
            generation = UUID()
            samplingSince = nil
            Task { [sampler] in await sampler.forget() }
            return
        }

        var plan = WindowSampler.Plan(busyRatio: settings.busyRatio)
        plan.timeBudget = settings.tickInterval * 2
        plan.cadence.waitingAfter = settings.thresholds.waitingAfter
        plan.cadence.certain = certainKeys
        plan.cadence.states = Dictionary(
            verdict.lanes.map { ($0.identity.key, $0.state) },
            uniquingKeysWith: { first, _ in first }
        )

        samplingSince = uptime
        isSampling = true
        let token = generation

        Task { [weak self, sampler] in
            let measurements = await sampler.sample(uptime: uptime, plan: plan)
            guard let self else { return }
            await MainActor.run {
                guard token == self.generation else { return }
                self.pixels = Dictionary(
                    measurements.map { ($0.identity.key, $0) },
                    uniquingKeysWith: { first, _ in first }
                )
                self.pixelsAt = uptime
                self.samplingSince = nil
                self.isSampling = false
            }
        }
    }

    // MARK: - CR-1, la présence humaine

    /// L'inactivité de l'humain, **sans installer de `CGEventTap`**.
    ///
    /// Un event tap est désactivé par macOS dès que le curseur entre dans un
    /// champ de mot de passe ou que *Secure Keyboard Entry* est actif : la
    /// moitié gauche de l'idée du produit — « vous ne faites rien *pendant que*
    /// trois choses attendent » — mourrait en silence. Cette API ne s'installe
    /// pas, ne peut pas être révoquée, et ne lit aucune frappe. (Il n'y a de
    /// toute façon qu'un seul tap dans bran, celui de `ShortcutRouter`.)
    ///
    /// **Et si la valeur est absurde, on le dit.** Ni « actif » ni « inactif » :
    /// les deux fabriquent un échec silencieux. `HumanPresence.unavailable`
    /// remonte jusqu'au résolveur, qui laisse `sharedSilence` à `nil`.
    static func presence() -> HumanPresence {
        let seconds = CGEventSource.secondsSinceLastEventType(
            .hidSystemState,
            eventType: CGEventType(rawValue: ~0) ?? .null
        )

        // Une journée d'inactivité clavier-souris sur une machine allumée n'est
        // pas une mesure, c'est un capteur mort.
        guard seconds.isFinite, seconds >= 0, seconds < 86_400 else {
            return .unavailable(reason: "le compteur d'inactivité du système ne répond pas")
        }
        return seconds < 1 ? .active : .idle(seconds: seconds)
    }

    // MARK: - Veille, réveil, fermeture

    /// **Ces notifications sont postées sur `NSWorkspace.shared.notificationCenter`,
    /// jamais sur `NotificationCenter.default`.** S'abonner au mauvais centre ne
    /// lève aucune erreur : l'observateur ne se déclenche simplement jamais, et
    /// le bogue ne se voit qu'après une nuit de veille.
    ///
    /// Elles ne servent qu'à **forcer** un tic et à vider ce qui doit l'être :
    /// la détection de veille, elle, vient de `WatchClock` et survit à une
    /// notification perdue.
    private func observeSystem() {
        let workspace = NSWorkspace.shared.notificationCenter

        observers.append(workspace.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Le dernier moment où l'on peut encore écrire : au réveil, ces
                // intervalles auraient une durée fausse.
                self.store.flush()
            }
        })

        observers.append(workspace.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.forgetEverything()
            }
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.store.flush()
            }
        })
    }

    private func forgetEverything() {
        store.flush()
        focus.forget()
        pixels.removeAll()
        pixelsAt = .zero
        generation = UUID()
        samplingSince = nil
        isSampling = false
        Task { [sampler] in await sampler.forget() }
    }
}
