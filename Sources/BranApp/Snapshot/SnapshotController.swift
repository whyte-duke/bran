import AppKit
import BranVision
import CoreGraphics
import Foundation
import Observation

/// L'orchestrateur de la capture de texte.
///
/// Il ne décide rien : `SnapshotMachine` décide, lui exécute. Le découpage est
/// le même que pour la dictée, et pour la même raison — la machine se teste en
/// une milliseconde, l'orchestrateur ne se teste pas du tout parce qu'il touche
/// à l'écran, au presse-papiers et au disque.
///
/// ```
///   raccourci → viseur macOS → CGImage → moteur → régions
///                                                    │
///                        TextAssembler ◄─────────────┘
///                              │
///                        CharacterFixer   (chasse fixe seulement)
///                              │
///                    ┌─────────┴─────────┐
///                    ▼                   ▼
///              presse-papiers        historique
/// ```
@MainActor
@Observable
final class SnapshotController {

    let settings: SnapshotSettings
    let store: SnapshotStore

    private(set) var phase: SnapshotMachine.Phase = .idle
    /// Le texte de la dernière capture réussie, pour l'aperçu dans l'encoche.
    private(set) var lastText: String?
    /// Les entrées dont une relecture est en cours.
    private(set) var relisting: Set<UUID> = []

    // MARK: - Machinerie

    private var machine = SnapshotMachine()
    private let capturer: RegionCapturer
    private let engine: VisionRecogniser
    private let paster = Paster()

    /// L'image en attente de lecture, et son contexte.
    private var pending: (image: CGImage, layout: LayoutMode, sourceApp: String?)?

    /// Jeton de la capture en cours. Un résultat qui revient après une
    /// annulation porte un jeton périmé et se jette en silence.
    private var currentToken = UUID()

    var onPhaseChange: ((SnapshotMachine.Phase) -> Void)?
    var onEmpty: (() -> Void)?

    init(
        settings: SnapshotSettings,
        store: SnapshotStore,
        capturer: RegionCapturer = SystemRegionCapturer(),
        engine: VisionRecogniser = VisionRecogniser()
    ) {
        self.settings = settings
        self.store = store
        self.capturer = capturer
        self.engine = engine
    }

    var isBusy: Bool { machine.phase.isBusy }

    func applySettings() {
        store.setRetention(settings.retention)
    }

    // MARK: - Déclenchement

    /// Appelé par `ShortcutRouter`.
    func triggered() {
        apply(machine.handle(.triggered))
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
    /// La leçon vient de la dictée : sans le premier `publish()`, une phase
    /// traversée en cascade — ici `.copying`, qui rappelle `apply` dans la même
    /// pile — n'était jamais annoncée, et l'encoche sautait l'étape.
    private func apply(_ effects: [SnapshotMachine.Effect]) {
        publish()
        for effect in effects {
            switch effect {
            case .beginSelection: beginSelection()
            case .prepareEngine: prepareEngine()
            case .recognise: recognise()
            case .deliver(let text): deliver(text)
            case .announceEmpty: onEmpty?()
            case .discard: discard()
            }
        }
        publish()
    }

    private func publish() {
        phase = machine.phase
        onPhaseChange?(machine.phase)
    }

    // MARK: - Les étapes

    private func beginSelection() {
        let token = UUID()
        currentToken = token

        // L'application au premier plan est mémorisée **avant** le viseur :
        // pendant la sélection, c'est bran ou `screencapture` qui est devant,
        // et on perdrait l'information qui rend l'historique cherchable.
        let sourceApp = NSWorkspace.shared.frontmostApplication?.localizedName
        if settings.pastesAutomatically { paster.rememberTarget() }

        Task { [weak self] in
            guard let self else { return }
            do {
                let image = try await capturer.selectRegion()
                guard currentToken == token else { return }

                guard let image else {
                    apply(machine.handle(.selectionCancelled))
                    return
                }

                pending = (image, settings.defaultLayout, sourceApp)
                let ready = await engine.isReady
                guard currentToken == token else { return }
                apply(machine.handle(.regionSelected(engineReady: ready)))
            } catch let failure as SnapshotFailure {
                guard currentToken == token else { return }
                apply(machine.handle(.failed(failure)))
            } catch {
                guard currentToken == token else { return }
                apply(machine.handle(.failed(.selectionFailed(error.localizedDescription))))
            }
        }
    }

    private func prepareEngine() {
        let token = currentToken
        Task { [weak self] in
            guard let self else { return }
            do {
                try await engine.prepare { fraction in
                    Task { @MainActor [weak self] in
                        guard let self, currentToken == token else { return }
                        apply(machine.handle(.engineProgress(fraction)))
                    }
                }
                guard currentToken == token else { return }
                apply(machine.handle(.engineReady))
            } catch {
                guard currentToken == token else { return }
                apply(machine.handle(.failed(.engineUnavailable(error.localizedDescription))))
            }
        }
    }

    private func recognise() {
        guard let pending else {
            apply(machine.handle(.failed(.selectionFailed("aucune image"))))
            return
        }
        let token = currentToken
        let started = Date()

        Task { [weak self] in
            guard let self else { return }
            do {
                let outcome = try await read(
                    image: pending.image,
                    layout: pending.layout,
                    language: settings.language
                )
                guard currentToken == token else { return }

                guard outcome.text.isEmpty == false else {
                    self.pending = nil
                    apply(machine.handle(.recognisedNothing))
                    return
                }

                lastText = outcome.text
                await store.save(
                    SnippetEntry(
                        createdAt: started,
                        text: outcome.text,
                        rawText: outcome.raw,
                        layout: pending.layout,
                        engine: engine.identifier,
                        confidence: outcome.confidence,
                        processingTime: Date().timeIntervalSince(started),
                        repairCount: outcome.repairs,
                        sourceApp: pending.sourceApp,
                        pixelWidth: pending.image.width,
                        pixelHeight: pending.image.height
                    ),
                    image: pending.image
                )
                self.pending = nil
                apply(machine.handle(.recognised(outcome.text)))
            } catch {
                guard currentToken == token else { return }
                self.pending = nil
                apply(machine.handle(.failed(.recognitionFailed(error.localizedDescription))))
            }
        }
    }

    private func deliver(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        if settings.pastesAutomatically {
            paster.restoresClipboard = false
            _ = paster.paste(text)
        }

        if settings.playsSound { Self.doneCue?.play() }
        apply(machine.handle(.copied))
    }

    private func discard() {
        pending = nil
        currentToken = UUID()
    }

    // MARK: - Le tuyau de lecture, partagé avec la relecture

    private struct Outcome {
        let text: String
        let raw: String
        let confidence: Double?
        let repairs: Int
    }

    private func read(
        image: CGImage,
        layout: LayoutMode,
        language: OCRLanguage
    ) async throws -> Outcome {
        let handle = RecognisableImage(
            handle: image,
            pixelWidth: image.width,
            pixelHeight: image.height
        )

        // Sur du code, la langue est imposée à l'anglais et le correcteur coupé.
        // Ce n'est pas un goût : avec le correcteur allumé, `awk '{print`
        // devient `awk 'fprint` sur la même image.
        let regions = switch layout {
        case .monospaced: try await engine.recogniseCode(handle)
        case .prose: try await engine.recognise(handle, language: language)
        }

        let raw = TextAssembler.assemble(regions, layout: layout)
        var text = CharacterFixer.fix(raw, layout: layout)
        if settings.trimsTrailingSpace {
            text = text.split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.replacing(/[ \t]+$/, with: "") }
                .joined(separator: "\n")
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        let confidences = regions.map(\.confidence)
        return Outcome(
            text: text,
            raw: raw,
            confidence: confidences.isEmpty ? nil : confidences.reduce(0, +) / Double(confidences.count),
            repairs: CharacterFixer.repairCount(raw, layout: layout)
        )
    }

    // MARK: - Relecture depuis l'historique

    /// Relit une capture conservée, éventuellement dans l'autre mise en page.
    ///
    /// C'est la seule relecture qui a du sens avec un moteur déterministe :
    /// rejouer à l'identique rendrait exactement le même texte. Changer de mode
    /// répare le cas fréquent — une sortie de terminal lue comme de la prose
    /// perd ses colonnes.
    func reread(_ entry: SnippetEntry, layout: LayoutMode? = nil) {
        guard relisting.contains(entry.id) == false else { return }
        guard let image = store.loadImage(for: entry) else { return }

        let target = layout ?? entry.layout ?? settings.defaultLayout
        relisting.insert(entry.id)

        Task { [weak self] in
            guard let self else { return }
            defer { relisting.remove(entry.id) }
            let started = Date()
            do {
                let outcome = try await read(image: image, layout: target, language: settings.language)
                store.mutate(entry.id) {
                    $0.text = outcome.text
                    $0.rawText = outcome.raw
                    $0.layout = target
                    $0.engine = engine.identifier
                    $0.confidence = outcome.confidence
                    $0.repairCount = outcome.repairs
                    $0.processingTime = Date().timeIntervalSince(started)
                    $0.failure = outcome.text.isEmpty ? "Aucun texte lisible dans cette image." : nil
                }
            } catch {
                store.mutate(entry.id) { $0.failure = error.localizedDescription }
            }
        }
    }

    func isRereading(_ id: UUID) -> Bool { relisting.contains(id) }

    func copy(_ entry: SnippetEntry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.text, forType: .string)
    }

    // MARK: - Son

    /// Un seul son, discret, et seulement à la fin. Le viseur de macOS ne fait
    /// déjà aucun bruit avec `-x` ; en ajouter un au déclenchement doublerait
    /// un retour visuel qui suffit.
    private static let doneCue: NSSound? = {
        let sound = NSSound(named: "Tink")
        sound?.volume = 0.1
        return sound
    }()
}
