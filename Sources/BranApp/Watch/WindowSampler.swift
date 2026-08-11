import AppKit
import BranWatch
import BranWindows
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// Ce que l'énumération des fenêtres rend, **et pourquoi ce n'est pas un
/// `SCWindow`**.
///
/// `SCWindow` n'est pas `Sendable` — vérifié au compilateur, pas supposé. Le
/// laisser traverser une frontière d'isolation ne compile pas en Swift 6, et le
/// contourner avec un `@unchecked Sendable` reviendrait à promettre au
/// compilateur une garantie qu'Apple ne documente nulle part. On copie donc les
/// huit champs dont le veilleur a besoin, à la frontière, une fois.
struct WindowSnapshot: Sendable {
    let windowID: CGWindowID
    let processID: pid_t
    let bundleIdentifier: String?
    let applicationName: String
    let title: String
    let frame: CGRect
    /// Faux pour une fenêtre minimisée ou masquée. Une fenêtre qui n'est pas à
    /// l'écran ne se capture **jamais** : le compositeur n'en a plus les pixels,
    /// et insister rend une image uniforme qu'on lirait comme « immobile ».
    let isOnScreen: Bool
    let layer: Int

    /// La voie que cette fenêtre représente.
    var identity: LaneIdentity {
        .window(
            bundleIdentifier: bundleIdentifier,
            applicationName: applicationName,
            title: title
        )
    }
}

/// **Le capteur de pixels du veilleur.** Extrait de `WatchProbe`, la sonde qui a
/// mesuré que le mouvement d'écran distingue une machine qui travaille d'une
/// machine qui attend.
///
/// ```
///   fenêtre ──▶ vignette 320 px ──▶ blocs 16×16 ──▶ moyenne par bloc
///                                                        │
///                              tic précédent ────────────┤
///                                                        ▼
///                                        ratio = part des blocs qui ont
///                                                bougé de plus de δ
/// ```
///
/// **Un `actor`, et pas du code sur le `MainActor`.** Une vignette de 320×200
/// en niveaux de gris, c'est un tracé Core Graphics puis 64 000 additions ; à
/// vingt fenêtres, l'interface se figerait à chaque tic. L'acteur rend des
/// `[Double]` et jamais un `CGImage` : rien de lourd ne traverse.
///
/// **Ce qui change par rapport au spike**, et pourquoi :
///
/// - pas de `NSApplication.shared`. Le spike en avait besoin parce qu'un
///   exécutable en ligne de commande n'ouvre pas de connexion au serveur de
///   fenêtres et que `SCScreenshotManager` abandonnait le processus. Une
///   application en a déjà une ;
/// - les moyennes précédentes sont indexées par `LaneIdentity.key`, **pas par
///   `CGWindowID`**. Les identifiants de fenêtre sont recyclés par le système :
///   fermer puis rouvrir une fenêtre casserait la voie, ce que `LaneIdentity`
///   existe précisément pour empêcher ;
/// - un budget de captures par tic, au lieu de tout capturer à chaque fois.
actor WindowSampler {

    /// Ce qu'une voie observée rapporte pour un tic.
    struct Measurement: Sendable {
        let identity: LaneIdentity
        /// `nil` quand aucune mesure n'existe : fenêtre jamais capturée, hors
        /// écran, ou capture impossible. Le résolveur en fait un `.unknown`,
        /// ce qui est la forme exacte de CR-5 — on ne devine pas à la place
        /// d'un capteur muet.
        let motionRatio: Double?
        let stillFor: TimeInterval?
        /// Vrai si la mesure vient de ce tic. Faux quand la cadence a
        /// délibérément sauté la fenêtre : la valeur reste valable, elle est
        /// juste un peu ancienne.
        let isFresh: Bool
    }

    /// Ce que le contrôleur impose au prélèvement.
    struct Plan: Sendable {
        /// Au-delà, on arrête la boucle de captures même si le budget reste :
        /// un tic qui déborde vaut mieux qu'un tic qui ne finit pas. C'est la
        /// seule borne qui reste ici, parce que c'est la seule qui se lit sur
        /// une horloge.
        var timeBudget: TimeInterval = 2
        /// Au-dessus, la voie bouge. Vient des réglages : c'est une grandeur
        /// physique, pas un choix de produit.
        var busyRatio: Double
        /// Qui mérite le budget de captures de ce tic, et dans quel ordre.
        /// Toute cette décision vit dans `BranWatch`, où elle est testée.
        var cadence = SamplingCadence()
    }

    private struct Tracked {
        var means: [Double]
        var lastRatio: Double
        /// Uptime du dernier mouvement constaté. Sur `SuspendingClock` : la
        /// veille ne compte pas (CR-2).
        var stillSince: Duration
        var lastCapturedTick: Int
    }

    // MARK: - Réglages de mesure

    /// 320 px de large : assez pour qu'un curseur qui clignote ne représente
    /// qu'une fraction d'un bloc, assez peu pour que la vignette tienne en
    /// 64 Ko.
    private static let thumbnailWidth = 320
    private static let blockSize = 16

    /// δ — l'écart de luminance, sur 0…1, au-delà duquel un bloc « a bougé ».
    /// Valeur du spike, celle avec laquelle les ratios ont été mesurés.
    private static let delta = 0.02

    private var tracked: [String: Tracked] = [:]
    private var tick = 0

    /// Jeton de génération, sur le patron de `SnapshotController.currentToken`.
    /// Un prélèvement lancé avant un réveil ou un changement de réglages n'a
    /// plus le droit d'écrire dans `tracked` quand il revient.
    private var generation = UUID()

    // MARK: - Énumération

    /// Les fenêtres candidates, **sans ScreenCaptureKit**.
    ///
    /// **C'était le premier poste de dépense de l'application au repos.**
    /// `SCShareableContent.excludingDesktopWindows` était appelé à chaque tic,
    /// et le profil montrait pourquoi c'est cher : la réponse arrive par XPC
    /// depuis `replayd`, puis ScreenCaptureKit construit un `SCWindow` par
    /// fenêtre, et chacun construit un `SCRunningApplication` qui demande son
    /// nom localisé à LaunchServices — **un aller-retour XPC synchrone de plus
    /// par fenêtre**. Soixante-neuf échantillons de profil sur douze secondes,
    /// pour une liste qui, entre deux tics, n'a presque jamais changé.
    ///
    /// `CGWindowListCopyWindowInfo` répond à la même question depuis le serveur
    /// de fenêtres, en une lecture, sans XPC ni LaunchServices — et il porte
    /// tout ce dont la cadence a besoin pour décider : identifiant, propriétaire,
    /// titre, cadre, couche, présence à l'écran. ScreenCaptureKit reste
    /// indispensable pour **capturer**, mais seulement pour ça : voir
    /// `shareableWindows(for:)`.
    ///
    /// `all()` et non `onScreen()` : une fenêtre minimisée doit rester une voie
    /// visible dans la liste — à l'état inconnu — plutôt que de disparaître
    /// comme si le travail n'existait plus.
    private func listedWindows() -> [WindowSnapshot] {
        let mine = ProcessInfo.processInfo.processIdentifier

        let listed = WindowList.all()
            // Couche 0 seulement : les palettes flottantes, les info-bulles et
            // notre propre panneau d'attention vivent au-dessus et ne sont pas
            // des unités de travail.
            .filter { $0.layer == 0 }
            .filter { $0.frame.width > 200 && $0.frame.height > 120 }
            .filter { $0.processID != mine }
            // **Le même critère que ScreenCaptureKit appliquait de lui-même.**
            // L'énumération d'avant partait de `SCShareableContent.windows`,
            // qui ne contient que des fenêtres partageables. Sans ce filtre, une
            // fenêtre qu'une application déclare non partageable — c'est ce que
            // font les gestionnaires de mots de passe et les lecteurs vidéo
            // protégés — deviendrait une voie que rien ne peut jamais mesurer :
            // elle apparaîtrait, resterait à l'état inconnu, puis vieillirait
            // vers « abandonnée ». Une voie fantôme, née d'un changement
            // d'énumération.
            .filter { $0.isShareable }

        // Les PID disparus quittent le cache des propriétaires. macOS recycle
        // les numéros de processus : garder une réponse pour un PID qu'on ne
        // voit plus, c'est risquer de la rendre un jour pour une **autre**
        // application — et la voie porterait alors le nom de la mauvaise.
        let alive = Set(listed.map(\.processID))
        owners = owners.filter { alive.contains($0.key) }

        return listed.map(describe)
    }

    /// Ce que l'application propriétaire d'un processus déclare, retenu par PID.
    ///
    /// **Les deux champs viennent de `NSRunningApplication`, exactement comme
    /// ceux que ScreenCaptureKit posait dans `SCRunningApplication`** : la clé
    /// de voie est `"win:\(bundleIdentifier ?? applicationName):\(titre)"`, et
    /// la changer de source aurait renommé toutes les voies déjà écrites dans le
    /// journal. Prendre `kCGWindowOwnerName` aurait été plus direct et
    /// silencieusement différent pour les applications sans identifiant de
    /// paquet.
    ///
    /// Le cache existe parce que la question se pose une fois par fenêtre et par
    /// tic, alors que la réponse ne change jamais pour un PID donné — un
    /// processus ne change pas de paquet. Il est vidé avec le reste par
    /// `forget()`, et un PID recyclé après un redémarrage d'application est
    /// couvert par là.
    private struct Owner {
        /// Le nom que le serveur de fenêtres donnait au propriétaire quand cette
        /// entrée a été résolue. **C'est le témoin de recyclage** : macOS
        /// réattribue les numéros de processus, et un PID peut désigner une
        /// autre application au tic suivant sans jamais quitter la liste des
        /// vivants. Le voir changer suffit à savoir qu'il faut redemander — et
        /// il ne coûte rien, l'énumération le donne déjà.
        let witness: String?
        let bundleIdentifier: String?
        let name: String
    }

    private var owners: [pid_t: Owner] = [:]

    private func owner(of window: ListedWindow) -> Owner {
        if let known = owners[window.processID], known.witness == window.ownerName {
            return known
        }
        // **`NSRunningApplication`, et pas `kCGWindowOwnerName`.** C'est la
        // source exacte de ce que `SCRunningApplication` posait avant, et la clé
        // de voie est `"win:\(bundleIdentifier ?? applicationName):\(titre)"` :
        // changer de source aurait renommé des voies déjà écrites dans le
        // journal, et coupé leur histoire en deux. Le nom du serveur de fenêtres
        // serait souvent meilleur que le « ? » de repli — ce n'est pas une
        // raison de le substituer ici, où l'on ne veut rien changer d'autre.
        let application = NSRunningApplication(processIdentifier: window.processID)
        let resolved = Owner(
            witness: window.ownerName,
            bundleIdentifier: application?.bundleIdentifier,
            name: application?.localizedName ?? "?"
        )
        owners[window.processID] = resolved
        return resolved
    }

    private func describe(_ window: ListedWindow) -> WindowSnapshot {
        let owner = owner(of: window)
        return WindowSnapshot(
            windowID: window.windowID,
            processID: window.processID,
            bundleIdentifier: owner.bundleIdentifier,
            applicationName: owner.name,
            title: window.title,
            frame: window.frame,
            isOnScreen: window.isOnScreen,
            layer: window.layer
        )
    }

    // MARK: - Les objets de capture

    /// Les `SCWindow` retenus d'une énumération à l'autre, par identifiant.
    ///
    /// Un `SCWindow` n'est qu'une poignée vers une fenêtre du compositeur : ce
    /// qu'on en fait ici, c'est le passer à `SCContentFilter` pour capturer. Ses
    /// champs — titre, cadre — ne sont **jamais** lus ; ils viennent tous de
    /// l'énumération fraîche du serveur de fenêtres. La poignée peut donc être
    /// gardée tant que la fenêtre existe, et son existence est justement ce que
    /// `listedWindows` vient de vérifier.
    ///
    /// **Le PID est retenu avec la poignée, et il n'est pas décoratif.** Les
    /// `CGWindowID` sont recyclés — c'est déjà la raison pour laquelle les
    /// mesures sont indexées par `LaneIdentity.key` et non par identifiant de
    /// fenêtre. Une poignée gardée pour l'identifiant 1234 pourrait donc être
    /// resservie pour la fenêtre 1234 d'une **autre** application, et ce qui
    /// serait capturé alors n'est garanti par rien. Exiger que le propriétaire
    /// soit le même transforme ce cas en simple absence de cache : on
    /// réénumère, ce qui est exactement ce qu'il faut faire.
    private var shareable: [CGWindowID: (processID: pid_t, window: SCWindow)] = [:]

    /// Les poignées de capture des fenêtres demandées, en n'appelant
    /// ScreenCaptureKit que si l'une d'elles manque.
    ///
    /// C'est là qu'est l'économie : au repos, l'ensemble des fenêtres ouvertes
    /// ne bouge pas pendant des minutes, donc le cache répond et l'énumération
    /// n'a pas lieu. Elle reprend son coût le jour où une fenêtre s'ouvre — ce
    /// qui est exactement le moment où il faut la payer.
    private func shareableWindows(
        for wanted: [(id: CGWindowID, processID: pid_t)]
    ) async -> [CGWindowID: SCWindow] {
        let cached = wanted.allSatisfy { shareable[$0.id]?.processID == $0.processID }

        if cached == false {
            if let content = try? await SCShareableContent.excludingDesktopWindows(
                true, onScreenWindowsOnly: false
            ) {
                // Reconstruit, et non fusionné : les identifiants disparus
                // doivent partir. Sinon la table grandit d'une entrée par
                // fenêtre jamais rouverte, pour la vie du processus.
                shareable = Dictionary(
                    content.windows.map {
                        ($0.windowID, ($0.owningApplication?.processID ?? 0, $0))
                    },
                    uniquingKeysWith: { first, _ in first }
                )
            }
            // Une énumération en échec — autorisation retirée en cours de route,
            // service de fenêtres indisponible — laisse la table telle quelle.
            // Le filtre ci-dessous écarte alors les poignées douteuses, et une
            // mesure absente est déjà un cas prévu : `absorb` ne touche à rien.
        }

        var handles: [CGWindowID: SCWindow] = [:]
        for target in wanted {
            guard let entry = shareable[target.id], entry.processID == target.processID else {
                continue
            }
            handles[target.id] = entry.window
        }
        return handles
    }

    // MARK: - Prélèvement

    /// Un tic de mesure. Rend une observation par fenêtre, capturée ou non.
    ///
    /// **L'énumération et la capture sont deux questions séparées, et c'est ce
    /// qui rend le tic bon marché.** Savoir *quelles fenêtres existent* est une
    /// lecture du serveur de fenêtres, faite à chaque tic ; obtenir de quoi *les
    /// capturer* passe par ScreenCaptureKit, et n'est refait que lorsqu'une
    /// fenêtre qu'on veut capturer n'a pas encore de poignée. Le budget de
    /// captures, lui, reste servi par une seule énumération — une par capture
    /// ferait six allers-retours là où un suffit.
    func sample(uptime: Duration, plan: Plan) async -> [Measurement] {
        tick += 1
        let token = generation

        let windows = listedWindows()
        let chosen = plan.cadence.selection(
            windows.map { candidate($0, uptime: uptime) },
            tick: tick
        )
        let deadline = SuspendingClock.now.advanced(by: .seconds(plan.timeBudget))

        if chosen.isEmpty == false {
            let handles = await shareableWindows(
                for: chosen.map { (windows[$0].windowID, windows[$0].processID) }
            )
            guard token == generation else { return [] }

            for index in chosen {
                guard SuspendingClock.now < deadline else { break }
                // Une fenêtre que ScreenCaptureKit ne connaît pas est une
                // fenêtre qui vient de se fermer entre l'énumération et ici.
                // Elle n'est pas mesurée ce tic, et rien d'autre n'en découle :
                // `absorb` ne touche à rien sur une mesure absente.
                guard let handle = handles[windows[index].windowID] else { continue }

                let means = await measure(handle, snapshot: windows[index])
                guard token == generation else { return [] }
                absorb(means, for: windows[index], uptime: uptime, plan: plan)
            }
        }

        return windows.map { window in
            let key = window.identity.key
            guard window.isOnScreen, let entry = tracked[key] else {
                return Measurement(
                    identity: window.identity,
                    motionRatio: nil,
                    stillFor: nil,
                    isFresh: false
                )
            }
            return Measurement(
                identity: window.identity,
                motionRatio: entry.lastRatio,
                stillFor: WatchClock.seconds(from: entry.stillSince, to: uptime),
                isFresh: entry.lastCapturedTick == tick
            )
        }
    }

    /// Oublie tout. Appelé au réveil : comparer une vignette d'hier soir à celle
    /// de ce matin rendrait un ratio énorme, donc « ça travaille », pour une
    /// machine qui a seulement dormi.
    func forget() {
        tracked.removeAll()
        // Les deux caches partent avec : après une veille, une application a pu
        // quitter et une autre reprendre son PID, et une poignée de capture peut
        // désigner une fenêtre qui n'existe plus. Aucun des deux ne porte de
        // mesure — les reconstruire ne coûte qu'une énumération.
        owners.removeAll()
        shareable.removeAll()
        generation = UUID()
    }

    // MARK: - Cadence

    /// Ce que `SamplingCadence` a besoin de savoir de cette fenêtre.
    ///
    /// C'est **toute** la part système de la cadence : traduire l'état interne
    /// de l'acteur en quatre valeurs nues. Le reste — les rangs, les périodes,
    /// la répartition du budget — est de l'arithmétique et vit dans `BranWatch`,
    /// avec ses tests.
    private func candidate(
        _ window: WindowSnapshot,
        uptime: Duration
    ) -> SamplingCadence.Candidate {
        let entry = tracked[window.identity.key]
        return SamplingCadence.Candidate(
            key: window.identity.key,
            isOnScreen: window.isOnScreen,
            lastCapturedTick: entry?.lastCapturedTick,
            stillFor: entry.map { WatchClock.seconds(from: $0.stillSince, to: uptime) }
        )
    }

    // MARK: - Mesure

    private func absorb(
        _ means: [Double]?,
        for window: WindowSnapshot,
        uptime: Duration,
        plan: Plan
    ) {
        let key = window.identity.key

        guard let means, means.isEmpty == false else {
            // La capture a échoué : on ne touche NI aux moyennes NI à
            // `stillSince`. Traiter un échec comme « immobile » ferait vieillir
            // une voie vers l'alerte sans qu'aucun pixel ne l'ait justifié.
            return
        }

        guard var entry = tracked[key], entry.means.count == means.count else {
            tracked[key] = Tracked(
                means: means,
                lastRatio: 0,
                stillSince: uptime,
                lastCapturedTick: tick
            )
            return
        }

        let ratio = MotionMeasure.movementRatio(entry.means, means, delta: Self.delta)
        entry.means = means
        entry.lastRatio = ratio
        entry.lastCapturedTick = tick
        if ratio > plan.busyRatio { entry.stillSince = uptime }
        tracked[key] = entry
    }

    /// La capture elle-même.
    ///
    /// `SCContentFilter` et `SCStreamConfiguration` sont construits **ici**,
    /// dans l'acteur qui appelle `captureImage` : ce sont des objets de
    /// ScreenCaptureKit, ils ne traversent aucune frontière.
    ///
    /// **Pourquoi une capture ponctuelle et non un `SCStream`.**
    /// `CaptureSession` tient déjà un flux plein écran pendant une réunion, et
    /// changer la configuration d'un flux actif l'interrompt.
    /// `SCScreenshotManager` ne touche à rien.
    private func measure(_ window: SCWindow, snapshot: WindowSnapshot) async -> [Double]? {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        configuration.width = Self.thumbnailWidth
        configuration.height = max(
            Self.blockSize,
            Int((snapshot.frame.height / max(snapshot.frame.width, 1)) * CGFloat(Self.thumbnailWidth))
        )
        configuration.showsCursor = false
        configuration.captureResolution = .nominal
        // L'ombre portée bouge quand la fenêtre **voisine** bouge : sans ça, une
        // fenêtre parfaitement immobile est lue comme active dès qu'on déplace
        // celle d'à côté.
        configuration.ignoreShadowsSingleWindow = true

        guard let image = try? await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        ) else { return nil }

        guard let thumbnail = Thumbnail(image) else { return nil }
        return MotionMeasure.blockMeans(
            thumbnail.pixels,
            width: thumbnail.width,
            height: thumbnail.height,
            size: Self.blockSize
        )
    }
}
