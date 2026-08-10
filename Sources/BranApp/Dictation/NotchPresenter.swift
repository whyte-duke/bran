import AppKit
import BranSpeech
import BranVision
import Foundation
import Observation

/// Fait le lien entre l'état des fonctions et le panneau de l'encoche.
///
/// Séparé des contrôleurs pour une raison simple : eux doivent rester testables
/// et sans fenêtre. Ici on ne fait que traduire des phases en pixels, et décider
/// combien de temps un message reste affiché.
///
/// **Un seul présentateur pour deux fonctions.** L'encoche est unique : deux
/// présentateurs sur le même `NotchOverlay` se voleraient le panneau, et le
/// minuteur de disparition de l'un masquerait le travail en cours de l'autre.
/// L'exclusion entre dictée et capture est garantie en amont par
/// `ShortcutRouter` ; ici on se contente de savoir qui parle.
@MainActor
final class NotchPresenter {

    private let content = NotchContent()
    private let overlay: NotchOverlay
    private let dictation: DictationController
    private let snapshot: SnapshotController

    private var refreshTask: Task<Void, Never>?
    private var dismissTask: Task<Void, Never>?

    init(dictation: DictationController, snapshot: SnapshotController) {
        self.dictation = dictation
        self.snapshot = snapshot
        self.overlay = NotchOverlay(content: content)

        dictation.onPhaseChange = { [weak self] phase in
            self?.react(to: phase)
        }
        dictation.onEmpty = { [weak self] in
            self?.announceEmpty(source: .dictation)
        }
        snapshot.onPhaseChange = { [weak self] phase in
            self?.react(to: phase)
        }
        snapshot.onEmpty = { [weak self] in
            self?.announceEmpty(source: .snapshot)
        }
    }

    // MARK: - Dictée

    private func react(to phase: DictationMachine.Phase) {
        switch phase {
        case .capturing:
            dismissTask?.cancel()
            content.source = .dictation
            content.levels = []
            content.elapsed = 0
            present(.listening)
            overlay.show()
            startRefreshing()

        case .transcribing:
            dismissTask?.cancel()
            stopRefreshing()
            present(.transcribing)
            overlay.show()

        case .pasting:
            stopRefreshing()
            // **Aucun minuteur ici.** Cette phase est atteinte avant que le
            // presse-papiers soit écrit et le ⌘V envoyé ; le compte à rebours
            // partait donc d'un événement qui ne dit rien de ce qu'il annonce,
            // et pouvait expirer avant même que le collage ait lieu. Il part
            // maintenant de l'atterrissage, c'est-à-dire de `.idle` — la phase
            // que la dictée n'atteint qu'au rappel de `Paster` (voir
            // `DictationController.performPaste`), et seulement par là :
            // `DictationMachine` ne sort de `.pasting` que sur `.pasted`.
            //
            // **Ce mode-ci est ce que le retour au repos lit ensuite** pour
            // savoir qu'une livraison était en cours et qu'elle vient
            // d'aboutir. C'est ce qui rend le `publish()` d'avant les effets
            // indispensable pour une autre raison que celle qui l'a fait
            // écrire : sans lui, `.pasting` ne serait jamais vue, et le retour
            // au repos trouverait « Transcription… » — un mode interruptible —
            // donc annoncerait « annulé » sur une dictée qui a réussi.
            dismissTask?.cancel()
            content.source = .dictation
            present(.pasting)
            overlay.show()

        case .failed(let reason):
            stopRefreshing()
            present(.failed(reason.summary))
            overlay.show()
            // Plus longtemps : un échec doit se lire, pas se deviner.
            scheduleDismiss(after: 4)

        case .idle:
            stopRefreshing()
            settleToIdle(
                delivered: dictation.lastTranscript,
                landing: dictation.pasteLanding
            )
        }
    }

    // MARK: - Capture de texte

    private func react(to phase: SnapshotMachine.Phase) {
        switch phase {
        case .selecting:
            // **L'encoche se tait.** Le viseur de macOS est modal et prend tout
            // l'écran ; lui superposer un panneau brouillerait la sélection au
            // moment précis où l'utilisateur vise. Elle réapparaît dès que la
            // zone est choisie.
            stopRefreshing()
            dismissTask?.cancel()
            overlay.hide()

        case .preparing(let fraction):
            dismissTask?.cancel()
            content.source = .snapshot
            present(.preparing(fraction))
            overlay.show()

        case .recognising:
            dismissTask?.cancel()
            content.source = .snapshot
            present(.reading)
            overlay.show()

        case .copying:
            // Même règle qu'à `.pasting` : l'écriture est postée, pas faite.
            // `SnapshotController.finishDelivery` n'est appelé qu'au rappel de
            // `Paster`, et c'est lui qui fait retomber la phase à `.idle`.
            dismissTask?.cancel()
            content.source = .snapshot
            present(.copying)
            overlay.show()

        case .failed(let reason):
            content.source = .snapshot
            present(.failed(reason.summary))
            overlay.show()
            scheduleDismiss(after: 4)

        case .idle:
            settleToIdle(
                delivered: snapshot.lastText,
                landing: snapshot.pasteLanding
            )
        }
    }

    // MARK: - Retour au repos, commun aux deux

    /// Décide ce qu'on affiche quand une fonction revient au repos.
    ///
    /// **C'est ici que le passé s'écrit.** Le retour au repos n'est pas un
    /// détail de fin de course : pour les deux fonctions, c'est le seul moment
    /// où le texte est réellement au presse-papiers. Ni `.pasting` ni `.copying`
    /// ne le garantissent — les deux sont atteintes avant l'écriture, qui est
    /// postée sur une file et peut attendre (`Paster`, point 8) —, et les deux
    /// contrôleurs n'appellent la machine à états qu'au rappel de `Paster`. Un
    /// « collé » affiché plus tôt est un « collé » qui peut être faux ; affiché
    /// ici, il ne peut plus l'être.
    ///
    /// **Le piège, déjà payé une fois sur la dictée.** Un état de fin déjà
    /// affiché a le dernier mot : il vient de poser son minuteur, et le
    /// raccourcir ici ferait disparaître le texte avant qu'on ait pu le lire.
    /// D'où `Mode.isTerminal`, plutôt que la liste des `if case` qu'il fallait
    /// penser à rallonger.
    ///
    /// - Parameters:
    ///   - delivered: le texte que la fonction vient de livrer, pour en montrer
    ///     le début. `nil` quand il n'y en a pas — la coche reste juste, elle
    ///     dit que c'est fait, pas ce que c'était.
    ///   - landing: ce que `Paster` a répondu, **posé par le contrôleur au
    ///     rappel de `Paster`, juste avant la transition vers `.idle`**. `nil`
    ///     quand il n'y a rien à signaler.
    ///
    ///     C'était un `Bool` — « faut-il faire ⌘V ? » —, lu sur la présence du
    ///     `pasteFallbackNotice` du contrôleur. Deux fins tenaient dans un
    ///     `Bool` ; il y en a trois depuis que le presse-papiers peut ne pas
    ///     répondre du tout (`Paster`, point 9), et la troisième se serait
    ///     rangée du côté `false`, donc affichée en coche verte sur un texte
    ///     qui n'est allé nulle part. La valeur passe donc entière, par le même
    ///     canal unique : `pasteFallbackNotice` en est maintenant dérivé, ce qui
    ///     évite au contrôleur d'en ouvrir un second pour la même information.
    private func settleToIdle(delivered: String?, landing: Paster.Landing?) {
        switch content.mode {
        case .pasting:
            present(ending(delivered: delivered, landing: landing, pasted: true))
            scheduleDismiss(after: Self.readingTime(landing))

        case .copying:
            present(ending(delivered: delivered, landing: landing, pasted: false))
            scheduleDismiss(after: Self.readingTime(landing))

        case _ where content.mode.isTerminal:
            return

        // Distinguer « annulé » de « rien trouvé » : deux gestes différents, et
        // l'utilisateur doit savoir lequel a été compris.
        case _ where content.mode.isCancellable:
            present(.cancelled)
            scheduleDismiss(after: 0.9)

        default:
            scheduleDismiss(after: 1.2)
        }
    }

    /// Ce que l'encoche dit une fois la livraison terminée.
    ///
    /// **Trois fins, trois modes, et aucun qui déborde sur l'autre.**
    /// `.stalled` sort par `.failed` et non par `.handedOver` : `.handedOver`
    /// affiche « ⌘V pour coller », ce qui, sur un presse-papiers qu'on n'a
    /// jamais réussi à écrire, ferait coller le contenu d'avant. Un mode de
    /// panne qui donne une instruction fausse est pire que pas de mode du tout.
    /// `.failed` porte déjà sa raison en texte, est terminal — donc le retour au
    /// repos ne l'écrasera pas — et existe sans que `NotchContent.Mode` ait à
    /// gagner un cas de plus pour un chemin qu'on espère ne jamais voir.
    ///
    /// - Parameter pasted: `true` pour la dictée, dont la fin réussie est un
    ///   collage ; `false` pour la capture de texte, dont la fin réussie est une
    ///   copie. La distinction ne survit ni au `.clipboardOnly` ni au
    ///   `.stalled` : dans ces deux cas les deux fonctions disent la même chose,
    ///   parce que l'utilisateur a exactement le même geste à faire — ⌘V pour
    ///   l'un, aller le chercher dans l'historique pour l'autre.
    private func ending(
        delivered: String?,
        landing: Paster.Landing?,
        pasted: Bool
    ) -> NotchContent.Mode {
        switch landing {
        case .clipboardOnly:
            return .handedOver
        case .stalled:
            return .failed(Paster.stalledNotice)
        case .pasted, nil:
            let excerpt = delivered.map { Self.excerpt($0) } ?? ""
            return pasted ? .done(excerpt) : .captured(excerpt)
        }
    }

    /// Assez pour lire le début de ce qui vient d'être livré et vérifier que
    /// c'est bien ça — et plus longtemps dès qu'il reste quelque chose à faire :
    /// une instruction qui s'efface avant d'être lue n'a servi à rien.
    ///
    /// `.stalled` a droit aux mêmes 4 s que `.clipboardOnly`, et pour une raison
    /// plus forte : sa phrase est la seule trace de l'incident. Il n'y a pas de
    /// coche à revoir, pas de texte collé quelque part à retrouver — juste ces
    /// quelques secondes et le bandeau du panneau, que l'utilisateur n'a aucune
    /// raison d'aller ouvrir s'il n'a pas su qu'il s'était passé quelque chose.
    private static func readingTime(_ landing: Paster.Landing?) -> TimeInterval {
        switch landing {
        case .clipboardOnly, .stalled: 4
        case .pasted, nil: 1.8
        }
    }

    /// Signale explicitement qu'il n'y avait rien à prendre.
    func announceEmpty(source: NotchContent.Source) {
        dismissTask?.cancel()
        content.source = source
        present(.empty)
        overlay.show()
        scheduleDismiss(after: 1.4)
    }

    // MARK: - Ce que l'encoche dit, et ce qu'elle en dit à voix haute

    /// Le seul chemin par lequel le mode change.
    ///
    /// Il existe pour que l'annonce VoiceOver ne puisse pas être oubliée au
    /// prochain état ajouté.
    private func present(_ mode: NotchContent.Mode) {
        content.mode = mode
        announce(Self.spoken(mode, source: content.source))
    }

    /// Le dernier texte annoncé. `.preparing` arrive à chaque pour-cent : sans
    /// cette mémoire, VoiceOver répéterait la même phrase vingt fois.
    private var lastAnnouncement = ""

    /// **Le panneau est hors de la hiérarchie d'accessibilité.** C'est une
    /// fenêtre sans contrôle, qui n'accepte pas la souris et ne prend jamais le
    /// focus : un utilisateur de VoiceOver appuyait sur le raccourci et n'avait
    /// strictement aucun retour — ni que ça écoute, ni que ça a échoué. Une
    /// annonce système coûte une ligne et ferme le trou.
    private func announce(_ text: String) {
        guard text.isEmpty == false, text != lastAnnouncement else { return }
        lastAnnouncement = text
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: text,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ]
        )
    }

    private static func spoken(_ mode: NotchContent.Mode, source: NotchContent.Source) -> String {
        let who = source == .snapshot ? "Capture" : "Dictée"
        return switch mode {
        case .idle: ""
        case .listening: "Dictée : à l'écoute"
        case .transcribing: "Dictée : transcription en cours"
        // Le temps du verbe est la seule différence entre ces deux-là, et c'est
        // toute la correction : « collage en cours » pendant, « collée » après.
        case .pasting: "Dictée : collage en cours"
        case .done(let text): "Dictée collée : \(text)"
        case .preparing: "Capture : chargement du moteur"
        case .reading: "Capture : lecture du texte"
        case .copying: "Capture : copie en cours"
        case .captured(let text): "Texte copié : \(text)"
        // La phrase entière, pas l'abrégé de l'encoche : à l'oreille il n'y a
        // pas de place à gagner, et c'est le seul retour dont dispose quelqu'un
        // qui n'a pas vu le panneau.
        case .handedOver: "\(who) : \(Paster.fallbackNotice)"
        case .empty: source == .snapshot ? "Capture : aucun texte trouvé" : "Dictée : rien entendu"
        case .cancelled: "\(who) : annulé"
        case .failed(let reason): "\(who) : \(reason)"
        }
    }

    // MARK: - Rafraîchissement

    /// 20 Hz. Le `Canvas` de la vue redessine à 40 Hz de son côté ; ici on ne
    /// fait que pousser de nouvelles valeurs, ce qui est bien plus coûteux.
    ///
    /// Seule la dictée en a besoin : le balayage de lecture est entièrement
    /// dessiné par le `TimelineView`, sans aucune donnée à pousser.
    private func startRefreshing() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while Task.isCancelled == false {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, Task.isCancelled == false else { return }
                content.levels = dictation.waveform
                content.elapsed = dictation.elapsed
            }
        }
    }

    private func stopRefreshing() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    private func scheduleDismiss(after delay: TimeInterval) {
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard Task.isCancelled == false else { return }
            self?.overlay.hide()
        }
    }

    /// Un aperçu, pas le texte entier : l'encoche fait cent points de large.
    ///
    /// Les sauts de ligne deviennent des espaces — un extrait de code sur une
    /// seule ligne se lit, le même extrait tronqué à la première ligne ne dit
    /// rien de ce qui a été capturé.
    private static func excerpt(_ text: String, limit: Int = 42) -> String {
        let flat = text
            .split(whereSeparator: \.isNewline)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard flat.count > limit else { return flat }
        return String(flat.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
