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
    /// Renseigné quand le collage automatique a été demandé mais n'a pas eu
    /// lieu — le texte est au presse-papiers, il reste un ⌘V à faire.
    ///
    /// La capture ne disait rien du tout dans ce cas, là où la dictée affichait
    /// son bandeau depuis toujours : on visait une zone, on entendait le son de
    /// fin, et rien n'apparaissait dans l'application de départ. Même phrase,
    /// même bandeau, même moment — voir `Paster.fallbackNotice`.
    ///
    /// Posé **une fois l'écriture aboutie**, jamais avant : tant que `Paster`
    /// n'a pas rappelé, le texte n'est pas encore au presse-papiers.
    private(set) var pasteFallbackNotice: String?
    /// Les entrées dont une relecture est en cours.
    private(set) var relisting: Set<UUID> = []

    // MARK: - Machinerie

    private var machine = SnapshotMachine()
    private let capturer: RegionCapturer
    private let engine: VisionRecogniser
    /// Le colleur de la capture, distinct de celui de la dictée : chacun a le
    /// sien, et celui-ci **ne rend jamais le presse-papiers**.
    ///
    /// Le texte lu à l'écran est ce que l'utilisateur est venu chercher — le lui
    /// reprendre 0,6 s après le collage n'aurait aucun sens. Le drapeau est donc
    /// posé ici une fois pour toutes, et non juste avant chaque collage : ainsi
    /// `rememberTarget()` sait dès l'appui qu'il n'a aucune lecture détachée à
    /// lancer, et ne va pas faire fabriquer à l'application source des
    /// représentations promises dont personne ne voudra.
    private let paster: Paster = {
        let paster = Paster()
        paster.restoresClipboard = false
        return paster
    }()

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

    /// **Ne notifie que les vrais changements.**
    ///
    /// `apply()` publie avant *et* après chaque effet : sans cette garde — que
    /// `DictationController.publish()` a, elle — chaque effet annonçait deux
    /// fois la même phase. `NotchPresenter` reprogrammait alors deux fois ses
    /// minuteurs, et le second passage sur `.idle` remplaçait les 0,9 s
    /// d'« Annulé » par 1,2 s. La durée affichée n'était pas celle écrite ici.
    private func publish() {
        let next = machine.phase
        guard next != phase else { return }
        phase = next
        onPhaseChange?(next)
    }

    // MARK: - Les étapes

    private func beginSelection() {
        // **Vérifier l'autorisation d'abord.** Sans elle, `screencapture` ne
        // renvoie pas d'erreur : il renvoie le fond d'écran **sans aucune
        // fenêtre**. Une image sans texte, donc un « Aucun texte trouvé » qui
        // envoie chercher un problème de reconnaissance là où il n'y a qu'une
        // case à cocher. Un refus doit se dire, pas se déguiser en zone vide.
        FeatureLog.record(
            "déclenchement — autorisation déclarée=\(ScreenAccess.isDeclaredGranted) "
            + "titres de fenêtres lisibles=\(ScreenAccess.canSeeOtherWindows)"
        )
        guard ScreenAccess.isUsable else {
            if ScreenAccess.isDeclaredGranted == false { CGRequestScreenCaptureAccess() }
            apply(machine.handle(.failed(.screenRecordingBlind(ScreenAccess.diagnosis))))
            return
        }

        let token = UUID()
        currentToken = token
        // Le bandeau de la capture précédente ne parle pas de celle-ci.
        pasteFallbackNotice = nil

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
                    // **On garde quand même l'image.** « Aucun texte trouvé »
                    // sans rien d'autre laisse le doute entier : la zone
                    // était-elle vide, mal cadrée, ou la capture a-t-elle été
                    // bloquée ? Avec l'image conservée, un clic sur la carte
                    // montre exactement ce qui a été pris.
                    await store.save(
                        SnippetEntry(
                            createdAt: started,
                            text: "",
                            layout: pending.layout,
                            engine: engine.identifier,
                            processingTime: Date().timeIntervalSince(started),
                            sourceApp: pending.sourceApp,
                            pixelWidth: pending.image.width,
                            pixelHeight: pending.image.height,
                            failure: "Aucun texte lisible dans cette zone. L'image est conservée : ouvrez-la pour voir ce qui a été capturé."
                        ),
                        image: pending.image
                    )
                    self.pending = nil
                    selfTest("après une capture vide")
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

    /// Pose le texte là où l'utilisateur l'attend : au presse-papiers, et dans
    /// l'application de départ si le collage automatique est demandé.
    ///
    /// **Une seule écriture, sur chacun des deux chemins.** `Paster.paste(_:)`
    /// écrit lui-même le presse-papiers avant de simuler le ⌘V — c'est son
    /// contrat, et c'est aussi ce qui lui permet de rendre `false` sans rien
    /// perdre quand la cible a disparu ou que la saisie sécurisée est active : le
    /// texte est déjà au presse-papiers, il ne manque que le collage. Écrire ici
    /// *puis* l'appeler faisait donc deux écritures du même texte :
    ///
    /// - deux incréments de `changeCount`, donc deux entrées pour l'historique
    ///   de presse-papiers en cours de conception, alors qu'il ne s'est rien
    ///   passé qu'une seule capture ;
    /// - une fenêtre entre les deux, courte mais réelle, pendant laquelle une
    ///   application tierce peut copier — et se faire écraser par notre seconde
    ///   écriture.
    ///
    /// C'est donc `paste` qui garde l'écriture quand il est appelé, et
    /// `copyOnly` — le même `prepareForNewContents(with: .currentHostOnly)`,
    /// sans le ⌘V — qui s'en charge sinon. Passer par `Paster` plutôt que
    /// d'écrire ici garde la règle du point 4 de son en-tête — sans
    /// `.currentHostOnly`, le texte lu à l'écran repart sur l'iPhone et l'iPad
    /// du même compte iCloud par le presse-papiers universel — à un seul
    /// endroit.
    ///
    /// **Ni l'un ni l'autre n'a écrit quand il rend la main.** Les deux *postent*
    /// l'écriture sur la file du point 8 de `Paster` : jouer le son de fin et
    /// passer à `.copied` juste après revenait à annoncer « c'est copié » avant
    /// que ce soit vrai. L'utilisateur entendait le son, faisait ⌘V, et collait
    /// le contenu d'avant. Tout ce qui affirme quelque chose du presse-papiers
    /// est donc passé dans `finishDelivery(needsManualPaste:)`, qui n'est appelé
    /// qu'au rappel de `Paster`.
    private func deliver(_ text: String) {
        guard settings.pastesAutomatically else {
            // Personne n'a demandé de collage : il n'y a pas d'échec à signaler,
            // seulement une écriture à laisser aboutir.
            paster.copyOnly(text) { [weak self] in
                self?.finishDelivery(needsManualPaste: false)
            }
            return
        }

        let willTry = paster.paste(text) { [weak self] landing in
            self?.finishDelivery(needsManualPaste: landing.needsManualPaste)
        }

        if willTry == false {
            FeatureLog.record(
                "capture : collage impossible dès le départ (cible absente ou saisie"
                + " sécurisée) — le texte partira quand même au presse-papiers"
            )
        }
    }

    /// Le texte est au presse-papiers : c'est seulement maintenant qu'on a le
    /// droit de le dire, de le faire entendre, et de considérer la capture finie.
    private func finishDelivery(needsManualPaste: Bool) {
        pasteFallbackNotice = needsManualPaste ? Paster.fallbackNotice : nil
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
        FeatureLog.record("moteur → \(regions.count) régions (\(layout.rawValue))")
        for region in regions.prefix(3) {
            FeatureLog.record(String(
                format: "   x=%.4f y=%.4f l=%.4f h=%.4f conf=%.2f « %@ »",
                region.x, region.y, region.width, region.height, region.confidence,
                String(region.text.prefix(40))
            ))
        }

        let raw = TextAssembler.assemble(regions, layout: layout)
        FeatureLog.record("assemblage → \(raw.count) caractères")
        var text = CharacterFixer.fix(raw, layout: layout)
        if settings.trimsTrailingSpace {
            text = text.split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.replacing(/[ \t]+$/, with: "") }
                .joined(separator: "\n")
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        FeatureLog.record("nettoyage → \(text.count) caractères")

        let confidences = regions.map(\.confidence)
        return Outcome(
            text: text,
            raw: raw,
            confidence: confidences.isEmpty ? nil : confidences.reduce(0, +) / Double(confidences.count),
            repairs: CharacterFixer.repairCount(raw, layout: layout)
        )
    }

    // MARK: - Autotest

    /// Fait lire à Vision une image fabriquée en mémoire, dont on connaît le
    /// texte.
    ///
    /// Écrit pour trancher une question que rien d'autre ne tranchait : le même
    /// code, sur la même image, rendait 5 régions depuis un outil en ligne de
    /// commande et 0 depuis l'application. Deux appels — un au démarrage, avant
    /// tout `screencapture`, et un après une capture vide — disent si le moteur
    /// est cassé depuis le début dans ce processus, ou s'il le devient.
    /// Rejoue la chaîne **complète** — `screencapture`, décodage, moteur,
    /// assemblage — sur un rectangle imposé de l'écran.
    ///
    /// Sans ça, la seule façon d'observer le tuyau dans l'application était de
    /// demander une capture à la main, ce qui rendait chaque essai coûteux.
    /// Le rectangle est volontairement minuscule et pris en haut à gauche.
    func selfTestFullChain(_ rect: String = "0,0,900,120") {
        Task { [weak self] in
            guard let self else { return }
            do {
                guard let image = try await capturer.captureFixedRegion(rect) else {
                    FeatureLog.record("autotest chaîne : aucune image rendue")
                    return
                }
                FeatureLog.record("autotest chaîne : image \(image.width)×\(image.height)")
                let outcome = try await read(image: image, layout: .monospaced, language: settings.language)
                FeatureLog.record(
                    "autotest chaîne : \(outcome.text.count) caractères « "
                    + String(outcome.text.prefix(60)).replacingOccurrences(of: "\n", with: "⏎") + " »"
                )
            } catch {
                FeatureLog.record("autotest chaîne", error: error)
            }
        }
    }

    func selfTest(_ moment: String) {
        guard let image = Self.renderProbe() else {
            FeatureLog.record("autotest \(moment) : impossible de fabriquer l'image")
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let regions = try await engine.recogniseCode(
                    RecognisableImage(handle: image, pixelWidth: image.width, pixelHeight: image.height)
                )
                let text = regions.map(\.text).joined(separator: " ")
                FeatureLog.record("autotest \(moment) : \(regions.count) régions « \(text) »")
            } catch {
                FeatureLog.record("autotest \(moment)", error: error)
            }
        }
    }

    /// Une image de test, noir sur blanc, avec un texte connu.
    private static func renderProbe() -> CGImage? {
        let size = CGSize(width: 420, height: 90)
        guard let context = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        NSAttributedString(
            string: "autotest 12345",
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 34, weight: .regular),
                .foregroundColor: NSColor.black,
            ]
        ).draw(at: NSPoint(x: 16, y: 24))
        NSGraphicsContext.restoreGraphicsState()

        return context.makeImage()
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

    /// Recopie un extrait de l'historique.
    ///
    /// **Par `Paster`, comme tout le reste.** Les deux lignes qu'il y avait ici
    /// touchaient `NSPasteboard.general` directement depuis le main actor, donc
    /// hors de la file série du point 8 de `Paster` — le seul accès du programme
    /// censé être le seul. Un clic sur « Copier » pendant qu'une lecture ou une
    /// écriture tournait sur cette file s'y intercalait, et `NSPasteboard.general`
    /// est bien le même objet des deux côtés : il n'y a pas d'échappatoire par
    /// « une instance chacun ». `copyOnly` fait exactement les deux mêmes appels,
    /// `.currentHostOnly` compris — sans lui, recopier un ancien extrait le
    /// diffuserait sur les autres appareils du compte —, mais du bon côté.
    ///
    /// Pas de rappel demandé, comme du côté des dictées : la coche de la carte
    /// accuse réception du clic, et il n'y a derrière elle ni son, ni phase, ni
    /// ⌘V à ordonner. Le jour où l'un des trois apparaît, c'est
    /// `copyOnly(_:whenLanded:)` qu'il faudra attendre.
    func copy(_ entry: SnippetEntry) {
        paster.copyOnly(entry.text)
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
