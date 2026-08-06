import AppKit
import BranWatch
import BranWindows
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// Sonde du veilleur. **Ne décide rien, ne construit rien : elle mesure.**
///
/// Elle répond à une seule question, et le reste du projet en dépend : le
/// mouvement de pixels distingue-t-il une machine qui *travaille* d'une machine
/// qui *attend* ? Si la réponse est non, quatorze heures de développement ne
/// sont pas écrites.
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
/// **Pourquoi une capture ponctuelle et non un `SCStream`.** `CaptureSession`
/// tient déjà un flux plein écran pendant une réunion, et changer la
/// configuration d'un flux actif l'interrompt. `SCScreenshotManager` ne touche à
/// rien. Et il capture *une fenêtre nommée* plutôt qu'un écran — ce qui pourrait
/// rendre des pixels même quand elle est cachée derrière une autre. C'est le
/// mode `--occlusion` qui le dit.
struct WatchProbe {

    enum Mode: String {
        /// Diagnostic unique : une capture par fenêtre, et un verdict sur
        /// l'occultation. À lancer en premier, avant tout le reste.
        case occlusion
        /// Le test du curseur : deux fenêtres suivies de près, sur peu de temps.
        case cursor
        /// La vraie mesure, sur une journée de travail.
        case watch
    }

    let mode: Mode
    let interval: Duration
    /// δ — l'écart de luminance, sur 0…1, au-delà duquel un bloc « a bougé ».
    let delta: Double
    /// Le ratio au-dessus duquel une voie est réputée travailler.
    let busyRatio: Double
    /// Minutes d'immobilité avant qu'une voie ne déclenche une alerte.
    let alertMinutes: Double
    /// Nombre de tics avant arrêt. Zéro = sans fin, jusqu'à Ctrl-C.
    var ticks: Int = 0

    private static let thumbnailWidth = 320
    private static let blockSize = 16

    // MARK: - Entrée

    func run() async throws {
        // Sans ça, `SCScreenshotManager` abandonne le processus sur
        // « Assertion failed: (did_initialize), CGS_REQUIRE_INIT ». Un
        // exécutable en ligne de commande n'ouvre pas de connexion au serveur
        // de fenêtres tout seul ; l'énumération marche quand même, la capture
        // non. Mesuré : exit 134 sans cette ligne.
        await MainActor.run { _ = NSApplication.shared }

        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            throw ProbeError.screenRecordingDenied
        }

        switch mode {
        case .occlusion: try await runOcclusion()
        case .cursor: try await runLoop(label: "curseur", certain: false)
        case .watch: try await runLoop(label: "veille", certain: true)
        }
    }

    // MARK: - Mode occlusion

    /// Capture chaque fenêtre nommée une fois et mesure la **richesse** de
    /// l'image rendue : l'écart-type des moyennes de blocs. Une capture ratée ou
    /// vide est uniforme, donc proche de zéro. Une capture réelle ne l'est pas.
    ///
    /// Toutes les fenêtres ne peuvent pas être au premier plan en même temps. Si
    /// beaucoup rendent une image riche, c'est que la capture par fenêtre
    /// traverse l'occultation — et le trou n° 1 du projet se referme.
    private func runOcclusion() async throws {
        let windows = try await namedWindows()
        print("→ \(windows.count) fenêtre(s) nommée(s)\n")

        var rich = 0
        var blank = 0
        var failed = 0

        print(Self.row("RICHESSE", "COUCHE", "APPLICATION", "TITRE"))
        print(String(repeating: "─", count: 96))

        for window in windows {
            let title = String((window.title ?? "").prefix(44))
            let app = String((window.owningApplication?.applicationName ?? "?").prefix(20))
            let layer = "\(window.windowLayer)"

            guard let thumbnail = await capture(window) else {
                failed += 1
                print(Self.row("ÉCHEC", layer, app, title))
                continue
            }

            let means = Self.blockMeans(thumbnail)
            let spread = MotionMeasure.standardDeviation(means)
            if spread > 0.02 { rich += 1 } else { blank += 1 }

            print(Self.row(String(format: "%.4f", spread), layer, app, title))
        }

        print(String(repeating: "─", count: 96))
        print("\nriches : \(rich)   uniformes : \(blank)   échecs : \(failed)")
        print("""

        VERDICT — Toutes ces fenêtres ne peuvent pas être au premier plan en même
        temps. Si « riches » est nettement supérieur à 1, la capture par fenêtre
        traverse l'occultation, et la question ouverte n° 2 du plan se referme :
        une voie cachée derrière une autre reste observable.
        """)
    }

    // MARK: - Mode boucle

    private func runLoop(label: String, certain: Bool) async throws {
        let log = try LogFile(url: FileStamp.storageRoot().appending(path: "watch-\(FileStamp.now).jsonl"))

        print("→ mode \(label) · tic \(interval) · δ \(delta) · seuil d'activité \(busyRatio)")
        print("→ journal : voir ~/Movies/bran/")
        if certain {
            print("→ CERTAIN-1 actif : lecture de ~/.claude/projects (3 champs, jamais de contenu)")
        }
        print("→ Ctrl-C pour arrêter.\n")
        print(Self.row("HEURE", "RATIO", "ÉTAT", "IMMOBILE", "FENÊTRE"))
        print(String(repeating: "─", count: 92))

        var previous: [CGWindowID: [Double]] = [:]
        var stillSince: [CGWindowID: Date] = [:]
        var alerted: Set<CGWindowID> = []
        var peak: [CGWindowID: Double] = [:]
        var titles: [CGWindowID: String] = [:]
        var ticks = 0
        var alerts = 0

        while self.ticks == 0 || ticks < self.ticks {
            let now = Date.now
            let idle = Self.humanIdleSeconds()
            let windows = try await namedWindows()
            // Une seule fois par tic, et pas une fois par fenêtre : c'est une
            // énumération complète du serveur de fenêtres, et la réponse est la
            // même pour les vingt fenêtres du tour.
            let frontmost = WindowList.frontmost(titled: false)?.windowID
            var busyCount = 0

            for window in windows {
                guard let thumbnail = await capture(window) else { continue }
                let means = Self.blockMeans(thumbnail)
                defer { previous[window.windowID] = means }

                guard let before = previous[window.windowID], before.count == means.count else { continue }

                let ratio = MotionMeasure.movementRatio(before, means, delta: delta)
                let isBusy = ratio > busyRatio
                peak[window.windowID] = max(peak[window.windowID] ?? 0, ratio)
                titles[window.windowID] = String((window.title ?? "?").prefix(52))
                if isBusy { busyCount += 1 }

                if isBusy {
                    stillSince[window.windowID] = nil
                    alerted.remove(window.windowID)
                } else if stillSince[window.windowID] == nil {
                    stillSince[window.windowID] = now
                }

                let stillFor = stillSince[window.windowID].map { now.timeIntervalSince($0) } ?? 0
                let state = isBusy ? "travaille" : (stillFor > alertMinutes * 60 ? "ATTEND" : "immobile")

                // La règle d'alerte. Sans elle le taux de fausses alertes n'est
                // pas calculable, et la porte de décision n'a pas d'instrument.
                let humanElsewhere = idle < 60 && window.windowID != frontmost
                if state == "ATTEND", humanElsewhere, alerted.contains(window.windowID) == false {
                    alerted.insert(window.windowID)
                    alerts += 1
                    let title = (window.title ?? "?").prefix(50)
                    print("\n  ⚑ ALERTE #\(alerts) — « \(title) » immobile depuis \(Int(stillFor / 60)) min")
                    print("     v = vraie · f = fausse  (tapez puis Entrée)\n")
                    log.append(Self.json([
                        "kind": "alert", "n": "\(alerts)", "window": String(title),
                        "still_s": String(Int(stillFor)), "idle_s": String(Int(idle)),
                    ]))
                }

                if ticks % 5 == 0 || state == "ATTEND" {
                    print(Self.row(
                        Self.clock(now),
                        String(format: "%.3f", ratio),
                        state,
                        stillFor > 0 ? "\(Int(stillFor))s" : "—",
                        String((window.title ?? "?").prefix(46))
                    ))
                }

                log.append(Self.json([
                    "kind": "tick", "window": String((window.title ?? "?").prefix(60)),
                    "app": window.owningApplication?.applicationName ?? "?",
                    "ratio": String(format: "%.4f", ratio),
                    "state": state, "still_s": String(Int(stillFor)),
                ]))
            }

            if certain {
                for reading in TranscriptTail.readAll() {
                    log.append(Self.json([
                        "kind": "certain",
                        "state": reading.state.rawValue,
                        "session": reading.sessionID ?? "?",
                        "cwd": reading.workingDirectory ?? "?",
                        "branch": reading.branch ?? "?",
                        "ended": reading.endedAt ?? "",
                    ]))
                }
            }

            log.append(Self.json([
                "kind": "sample", "windows": String(windows.count),
                "busy": String(busyCount), "human_idle_s": String(Int(idle)),
            ]))

            ticks += 1
            try await Task.sleep(for: interval)
        }

        // Le récapitulatif : c'est lui qui sert au test du curseur. Le ratio
        // MAXIMUM atteint par chaque fenêtre sur la durée sépare une fenêtre qui
        // a travaillé d'une fenêtre qui n'a fait que clignoter.
        print("\n" + String(repeating: "═", count: 92))
        print("RÉCAPITULATIF — \(ticks) tics · \(alerts) alerte(s)\n")
        print(Self.row("RATIO MAX", "", "", "", "FENÊTRE"))
        for (id, value) in peak.sorted(by: { $0.value > $1.value }) {
            print(Self.row(String(format: "%.4f", value), "", "", "", titles[id] ?? "?"))
        }
        print("""

        Un ratio max élevé = la fenêtre a réellement travaillé pendant la mesure.
        Un ratio max proche de zéro = elle est restée immobile. Si un terminal qui
        ATTEND (curseur qui clignote) obtient un ratio comparable à un terminal qui
        TRAVAILLE, le signal est mort et il faut basculer sur l'approche A + C.
        """)
    }

    // MARK: - Capture

    private func namedWindows() async throws -> [SCWindow] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        return content.windows
            .filter { ($0.title ?? "").isEmpty == false }
            .filter { $0.frame.width > 200 && $0.frame.height > 120 }
            .sorted { ($0.owningApplication?.applicationName ?? "") < ($1.owningApplication?.applicationName ?? "") }
    }

    private func capture(_ window: SCWindow) async -> Thumbnail? {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        configuration.width = Self.thumbnailWidth
        configuration.height = max(
            Self.blockSize,
            Int((window.frame.height / max(window.frame.width, 1)) * CGFloat(Self.thumbnailWidth))
        )
        configuration.showsCursor = false
        configuration.captureResolution = .nominal

        // **Le même réglage que `WindowSampler`, et c'est non négociable.**
        //
        // L'ombre portée d'une fenêtre bouge quand la fenêtre *voisine* bouge :
        // c'est du mouvement qui n'appartient pas à la voie observée. L'app
        // l'ignore ; si la sonde ne l'ignorait pas, elle mesurerait des ratios
        // systématiquement plus élevés — et le δ calibré ici serait trop grand
        // pour l'application qui doit s'en servir.
        //
        // Une sonde qui ne mesure pas ce que le produit mesure ne calibre rien.
        configuration.ignoreShadowsSingleWindow = true

        guard let image = try? await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        ) else { return nil }

        return Thumbnail(image)
    }

    // MARK: - Mesure

    /// Les moyennes de blocs d'une vignette. L'arithmétique est dans
    /// `MotionMeasure`, côté `BranWatch` : la sonde et l'application mesurent
    /// **le même** ratio, sinon les seuils réglés ici ne voudraient rien dire
    /// là-bas.
    static func blockMeans(_ thumbnail: Thumbnail) -> [Double] {
        MotionMeasure.blockMeans(
            thumbnail.pixels,
            width: thumbnail.width,
            height: thumbnail.height,
            size: blockSize
        )
    }

    /// Inactivité de l'humain **sans installer de `CGEventTap`**.
    ///
    /// C'est ce qui répare le correctif CR-1 avant même qu'il soit écrit : un
    /// event tap est désactivé par macOS dès que le curseur entre dans un champ
    /// de mot de passe ou que *Secure Keyboard Entry* est actif, et la moitié
    /// gauche de l'eurêka meurt en silence. Cette API ne s'installe pas, ne peut
    /// pas être révoquée, et ne lit aucune frappe.
    static func humanIdleSeconds() -> Double {
        CGEventSource.secondsSinceLastEventType(
            .hidSystemState,
            eventType: CGEventType(rawValue: ~0) ?? .null
        )
    }

    // MARK: - Sortie

    private static func clock(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .standard)
    }

    /// Colonnes alignées sans `String(format:)`. `%@` s'appuie sur le pontage
    /// NSString et se comporte mal avec les accents et les largeurs ; le
    /// remplissage manuel donne toujours la même chose.
    private static func row(_ cells: String...) -> String {
        let widths = [10, 8, 11, 12]
        return cells.enumerated()
            .map { index, cell in
                guard index < widths.count else { return cell }
                let pad = max(0, widths[index] - cell.count)
                return cell + String(repeating: " ", count: pad)
            }
            .joined(separator: " ")
    }

    private static func json(_ fields: [String: String]) -> String {
        let body = fields
            .sorted { $0.key < $1.key }
            .map { "\"\($0.key)\":\"\($0.value.replacing("\"", with: "'"))\"" }
            .joined(separator: ",")
        return "{\(body)}"
    }
}

// MARK: - CERTAIN-1, la couche fichier

/// Va chercher sur le disque ce que `TranscriptVerdict` sait interpréter.
///
/// Volontairement mince : toute la logique — l'ordre des enregistrements, la
/// ligne tronquée, l'extraction sans contenu — vit dans `BranWatch`, où elle est
/// testée sans disque ni écran. Ici il ne reste que le `FileHandle`.
enum TranscriptTail {

    /// Les 256 derniers Ko suffisent largement à contenir le dernier tour, et
    /// bornent le coût quel que soit le poids du fichier : le plus gros du
    /// dossier pèse 20 Mo.
    static let tailBytes = 256 * 1024

    /// Au-delà, la session est morte, pas en attente. Mesuré : 37 des 51
    /// fichiers du dossier ont plus de sept jours. Sans ce plafond, la sonde
    /// ressusciterait trente-sept voies fantômes au premier lancement.
    static let liveness: TimeInterval = 6 * 3600

    static func readAll(now: Date = .now) -> [TranscriptVerdict.Reading] {
        let live = RunningAgents.workingDirectories()
        let root = URL.homeDirectory.appending(path: ".claude/projects")
        let manager = FileManager.default
        guard let projects = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return []
        }

        let cutoff = now.addingTimeInterval(-liveness)
        var readings: [TranscriptVerdict.Reading] = []

        for project in projects {
            guard let files = try? manager.contentsOfDirectory(
                at: project, includingPropertiesForKeys: [.contentModificationDateKey]
            ) else { continue }

            for file in files where file.pathExtension == "jsonl" {
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                guard modified > cutoff else { continue }
                if let reading = read(file) {
                    readings.append(TranscriptVerdict.gated(reading, liveWorkingDirectories: live))
                }
            }
        }
        return readings
    }

    static func read(_ file: URL) -> TranscriptVerdict.Reading? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: start)

        guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) else {
            return nil
        }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let reading = TranscriptVerdict.read(lines: lines, tailIsTruncated: start > 0)
        return reading.state == .unknown ? nil : reading
    }
}
