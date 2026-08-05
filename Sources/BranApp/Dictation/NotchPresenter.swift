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
            content.mode = .listening
            content.levels = []
            content.elapsed = 0
            overlay.show()
            startRefreshing()

        case .transcribing:
            dismissTask?.cancel()
            stopRefreshing()
            content.mode = .transcribing
            overlay.show()

        case .pasting:
            stopRefreshing()
            if let text = dictation.lastTranscript {
                content.mode = .done(Self.excerpt(text))
            }
            overlay.show()
            // Assez pour lire le début de ce qui vient d'être collé et vérifier
            // que c'est bien ça.
            scheduleDismiss(after: 1.8)

        case .failed(let reason):
            stopRefreshing()
            content.mode = .failed(reason.summary)
            overlay.show()
            // Plus longtemps : un échec doit se lire, pas se deviner.
            scheduleDismiss(after: 4)

        case .idle:
            stopRefreshing()
            settleToIdle(cancellableFrom: [.listening, .transcribing])
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
            content.mode = .preparing(fraction)
            overlay.show()

        case .recognising:
            dismissTask?.cancel()
            content.source = .snapshot
            content.mode = .reading
            overlay.show()

        case .copying:
            if let text = snapshot.lastText {
                content.mode = .captured(Self.excerpt(text))
            }
            overlay.show()
            scheduleDismiss(after: 1.8)

        case .failed(let reason):
            content.source = .snapshot
            content.mode = .failed(reason.summary)
            overlay.show()
            scheduleDismiss(after: 4)

        case .idle:
            settleToIdle(cancellableFrom: [.reading])
        }
    }

    // MARK: - Retour au repos, commun aux deux

    /// Décide ce qu'on affiche quand une fonction revient au repos.
    ///
    /// **Le piège, déjà payé une fois sur la dictée.** `.copying` et `.pasting`
    /// arrivent juste avant `.idle`, dans la même pile d'appels. Le minuteur de
    /// 1,8 s vient d'être posé : le raccourcir ici ferait disparaître le texte
    /// avant qu'on ait pu le lire. D'où le retour immédiat quand un état de fin
    /// est déjà affiché.
    private func settleToIdle(cancellableFrom shown: [NotchContent.Mode]) {
        if case .done = content.mode { return }
        if case .captured = content.mode { return }
        if case .empty = content.mode { return }
        if case .failed = content.mode { return }

        // Distinguer « annulé » de « rien trouvé » : deux gestes différents, et
        // l'utilisateur doit savoir lequel a été compris.
        if shown.contains(content.mode) {
            content.mode = .cancelled
            scheduleDismiss(after: 0.9)
        } else {
            scheduleDismiss(after: 1.2)
        }
    }

    /// Signale explicitement qu'il n'y avait rien à prendre.
    func announceEmpty(source: NotchContent.Source) {
        dismissTask?.cancel()
        content.source = source
        content.mode = .empty
        overlay.show()
        scheduleDismiss(after: 1.4)
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
