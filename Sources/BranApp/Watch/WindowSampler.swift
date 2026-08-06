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

    /// Les fenêtres candidates, gardées **à l'intérieur de l'acteur**.
    ///
    /// `onScreenWindowsOnly: false` volontairement : une fenêtre minimisée doit
    /// rester une voie visible dans la liste — à l'état inconnu — plutôt que de
    /// disparaître comme si le travail n'existait plus.
    private func liveWindows() async throws -> [SCWindow] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            true, onScreenWindowsOnly: false
        )
        let mine = ProcessInfo.processInfo.processIdentifier

        return content.windows
            .filter { ($0.title ?? "").isEmpty == false }
            // Couche 0 seulement : les palettes flottantes, les info-bulles et
            // notre propre panneau d'attention vivent au-dessus et ne sont pas
            // des unités de travail.
            .filter { $0.windowLayer == 0 }
            .filter { $0.frame.width > 200 && $0.frame.height > 120 }
            .filter { $0.owningApplication?.processID != mine }
    }

    private func describe(_ window: SCWindow) -> WindowSnapshot {
        WindowSnapshot(
            windowID: window.windowID,
            processID: window.owningApplication?.processID ?? 0,
            bundleIdentifier: window.owningApplication?.bundleIdentifier,
            applicationName: window.owningApplication?.applicationName ?? "?",
            title: window.title ?? "",
            frame: window.frame,
            isOnScreen: window.isOnScreen,
            layer: window.windowLayer
        )
    }

    // MARK: - Prélèvement

    /// Un tic de mesure. Rend une observation par fenêtre, capturée ou non.
    ///
    /// L'énumération n'a lieu **qu'une fois par tic** : les `SCWindow` restent
    /// dans cette méthode, ce qui permet de capturer sans ré-interroger
    /// ScreenCaptureKit à chaque fenêtre — une énumération par capture ferait
    /// six allers-retours là où un seul suffit.
    func sample(uptime: Duration, plan: Plan) async -> [Measurement] {
        tick += 1
        let token = generation

        let live: [SCWindow]
        do {
            live = try await liveWindows()
        } catch {
            // L'énumération elle-même a échoué : autorisation retirée en cours
            // de route, service de fenêtres indisponible. On ne rend rien
            // plutôt que d'inventer des voies.
            return []
        }
        guard token == generation else { return [] }

        let windows = live.map(describe)
        let chosen = plan.cadence.selection(
            windows.map { candidate($0, uptime: uptime) },
            tick: tick
        )
        let deadline = SuspendingClock.now.advanced(by: .seconds(plan.timeBudget))

        for index in chosen {
            guard SuspendingClock.now < deadline else { break }

            let means = await measure(live[index], snapshot: windows[index])
            guard token == generation else { return [] }
            absorb(means, for: windows[index], uptime: uptime, plan: plan)
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
