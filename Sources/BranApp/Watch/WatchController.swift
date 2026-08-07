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

        var label: String {
            switch self {
            case .disabled: "veille désactivée"
            case .muted: "silence — réunion en cours"
            case .lowPower: "silence — mode économie d'énergie"
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

    /// Le temps qu'un prélèvement de pixels a le droit de prendre.
    ///
    /// Nommé une fois parce qu'il sert **deux fois** : le budget donné au
    /// préleveur, et le seuil de péremption qui doit forcément le dépasser.
    /// Les écrire séparément avait produit exactement l'égalité qui fait
    /// clignoter toutes les voies — voir `watchWindows`.
    private var pixelBudget: TimeInterval { settings.tickInterval * 2 }
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
        self.focus = HumanFocus()
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
            // …mais l'absence, elle, n'est pas inconnue : on en connaît les deux
            // bornes exactement. C'est la seule chose qu'une veille apprend au
            // lieu de la détruire.
            store.recordSleep(seconds: step.slept, endingAt: now)
        }

        // Le jour a changé : un intervalle qui commence à 23 h 50 et se ferme à
        // 8 h du matin appartiendrait à deux fichiers-jour à la fois.
        if store.dayChanged(at: now) {
            store.flush()
            await store.reload()
            // **Et c'est le seul moment où la rétention peut être tenue.**
            //
            // La purge ne tournait qu'au lancement de l'application et au
            // changement de réglage. Sur une application de barre de menus, qui
            // reste ouverte des semaines, « conserver 7 jours » voulait donc
            // dire « conserver 7 jours à compter du dernier redémarrage » —
            // c'est-à-dire ne rien supprimer du tout. Le journal du veilleur
            // écrit des titres de fenêtres : des noms de documents, de projets
            // et de clients. Une durée de conservation qu'on annonce sans la
            // tenir est pire que pas de durée du tout, parce qu'elle rassure.
            //
            // Ici, exactement une fois par jour, au moment où l'on rouvre déjà
            // le fichier : la purge est un `removeItem` après lecture d'un nom.
            await store.purgeExpired(now: now)
        }

        // **La présence est relevée avant tout arbitrage, et notamment avant la
        // décision de se taire.**
        //
        // C'est l'inversion qui compte. Les quatre raisons de silence — veille
        // désactivée mise à part — sont exactement les moments où l'on veut
        // savoir si quelqu'un était là : écran éteint, réunion en cours,
        // économie d'énergie. La version précédente n'écrivait rien pendant
        // ces périodes, et le journal ne pouvait plus distinguer une pause
        // déjeuner d'un capteur mort. Trois appels système, aucune capture
        // d'écran, aucun titre de fenêtre écrit.
        human = Self.presence()
        recordPresence(at: now, step: step)

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
    ///
    /// **L'écran éteint n'y figure plus.** Il coupait tout, alors qu'il ne
    /// devrait couper que les pixels : voir `pixelsAreBlind`.
    private func idleReason() -> Pause? {
        if settings.isEnabled == false { return .disabled }
        if isMuted() { return .muted }
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return .lowPower }
        return nil
    }

    /// L'écran est éteint : **le capteur de pixels est aveugle, et lui seul**.
    ///
    /// Cette distinction était perdue. `displayAsleep` figurait parmi les
    /// raisons de silence, donc un écran éteint arrêtait le tic entier — y
    /// compris la lecture des transcriptions d'agent, qui ne regarde aucun
    /// écran, ne demande aucune autorisation et se moque complètement de savoir
    /// si un moniteur est allumé.
    ///
    /// Ce que ça coûtait, très concrètement : lancer une longue tâche à un agent
    /// et aller déjeuner. L'écran s'éteint au bout de dix minutes, la tâche
    /// finit à la douzième, et l'attente commence — mais bran s'était tu à la
    /// dixième. Au retour, aucune alerte, aucune durée mesurée, et le seul
    /// scénario que le produit existe pour couvrir n'était justement pas
    /// couvert.
    ///
    /// Le compositeur ne rendant que des images figées, les pixels, eux,
    /// s'arrêtent bien : `watchWindows` le lit et n'ouvre aucun prélèvement.
    private var pixelsAreBlind: Bool {
        CGDisplayIsAsleep(CGMainDisplayID()) != 0
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
        // `human` a déjà été relevé en tête de tic, avant l'arbitrage du
        // silence : le relever une seconde fois ici donnerait deux mesures d'un
        // même battement, et c'est celle du journal de présence qui ferait foi.
        // **La fenêtre d'activité est celle du résolveur, pas deux tics.**
        //
        // Elle valait `tickInterval * 2`, soit huit secondes : lire un
        // paragraphe pendant vingt secondes suffisait à ne plus « toucher » la
        // fenêtre qu'on avait sous les yeux, et la voie glissait vers l'attente
        // alors que l'utilisateur était devant. `humanIdleAfter` est déjà la
        // définition que bran donne de « l'humain est absent » — deux minutes —
        // et il n'y a aucune raison d'en avoir une seconde, plus sévère, cachée
        // ici.
        focus.update(uptime: uptime, human: human, within: settings.thresholds.humanIdleAfter)

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
            fresh.lanes.map { lane in
                LaneRecord(
                    lane: lane,
                    source: sources[lane.identity.key] ?? .aucun,
                    foreground: focus.current == lane.identity.key
                )
            },
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

        // L'écran éteint arrête les pixels, et rien d'autre. Les voies déjà
        // mesurées ne sont pas rendues `unknown` de force : elles cessent
        // simplement d'être rafraîchies, et la péremption de deux tics s'en
        // charge — c'est la même règle que pour un prélèvement en retard.
        guard pixelsAreBlind == false else {
            screenProblem = "L'écran est éteint : les fenêtres ne sont plus observées. Les sessions d'agent, elles, continuent de l'être."
            return []
        }
        screenProblem = nil

        requestSample(uptime: uptime, certainKeys: certainKeys)

        // Des mesures trop vieilles ne valent plus rien : le prélèvement s'est
        // figé ou la fenêtre a disparu. `motionRatio: nil` donne `.unknown`, ce
        // qui est la forme exacte de CR-5.
        //
        // **Le budget de capture entre dans le seuil, et c'est le correctif.**
        // La version précédente comparait deux tics à un âge compté depuis la
        // *demande* du prélèvement — alors que le prélèvement a le droit de
        // durer `plan.timeBudget`, qui vaut lui-même deux tics. Une capture qui
        // consommait son budget arrivait donc périmée à la seconde où elle
        // arrivait : sur une machine chargée, ou simplement avec vingt fenêtres
        // ouvertes, toutes les voies observées à l'image clignotaient entre
        // « travaille » et « pas observable » à chaque tic — et le journal
        // écrivait la même alternance, ligne après ligne.
        //
        // Le seuil juste est donc « le temps qu'un prélèvement a le droit de
        // prendre, plus deux tics de grâce ». Deux tics est la même tolérance
        // que celle de `WatchLedger.pulse`, et pour la même raison : absorber un
        // battement sauté sans fabriquer un trou.
        let staleAfter = pixelBudget + settings.tickInterval * 2
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
        plan.timeBudget = pixelBudget
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
                // **L'instant de la réponse, pas celui de la demande.** La
                // version précédente rangeait ici `uptime`, qui est le paramètre
                // capturé au moment du lancement : une mesure naissait donc
                // avec l'âge de sa propre capture. Combiné à un seuil de
                // péremption égal au budget, ça la rendait périmée à la seconde
                // où elle arrivait. Les deux moitiés du défaut sont corrigées,
                // et il fallait les deux.
                self.pixelsAt = self.uptime
                self.samplingSince = nil
                self.isSampling = false
            }
        }
    }

    // MARK: - La présence

    /// Le verrouillage de session, tenu à jour par notification.
    ///
    /// **Il n'y a pas d'API pour le demander.** `CGSessionCopyCurrentDictionary`
    /// expose `kCGSSessionOnConsoleKey`, mais il répond « sur console » pour un
    /// écran simplement verrouillé — il distingue le changement d'utilisateur
    /// rapide, pas le verrou. Les deux notifications distribuées sont le seul
    /// signal juste, et elles imposent de tenir un état plutôt que d'interroger.
    ///
    /// Le défaut est « déverrouillé » : bran démarre au lancement de la session,
    /// donc déverrouillé, et se tromper dans ce sens fabrique au pire une
    /// présence en trop pendant quelques secondes — jamais une absence
    /// inventée.
    private var isScreenLocked = false

    /// Écrit la présence de ce battement, ou n'écrit rien.
    ///
    /// La durée versée est **murale** et non celle de l'horloge suspendue : voir
    /// `PresenceEvent.d`, où le choix inverse de `WatchEvent` est justifié.
    private func recordPresence(at now: Date, step: WatchClock.Step) {
        let input = PresenceInput(
            isScreenLocked: isScreenLocked,
            isDisplayAsleep: CGDisplayIsAsleep(CGMainDisplayID()) != 0,
            // La veille de ce pas a déjà été écrite en intervalle fermé par
            // `recordSleep` : la redire ici ouvrirait une absence au moment
            // précis où l'utilisateur revient.
            machineSlept: false,
            idleSeconds: human.idleSeconds
        )

        guard let presence = Presence.resolve(input) else {
            // Capteur d'inactivité muet. On ferme ce qui est ouvert plutôt que
            // de l'étendre sur une mesure qu'on n'a pas : le trou qui en résulte
            // dit la vérité, et c'est exactement ce que `Presence` n'a pas de
            // cas pour représenter.
            store.flushPresence()
            return
        }

        store.record(presence: presence, at: now, elapsed: step.elapsed + step.slept)
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

        // **Le verrou, et son centre à lui.** Un troisième centre de
        // notifications, après `NSWorkspace.shared.notificationCenter` et
        // `NotificationCenter.default` : `com.apple.screenIsLocked` n'est postée
        // que sur le centre **distribué**, celui qui traverse les processus.
        // S'abonner au mauvais des trois ne lève rien — l'observateur ne se
        // déclenche jamais — et le défaut ne se verrait qu'en verrouillant son
        // écran pour de vrai, ce qu'aucun test ne fait.
        let distributed = DistributedNotificationCenter.default()

        observers.append(distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.isScreenLocked = true }
        })

        observers.append(distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.isScreenLocked = false }
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
