import BranSpeech
import Foundation
import Observation

/// Fait le lien entre l'état de la dictée et le panneau de l'encoche.
///
/// Séparé du contrôleur pour une raison simple : le contrôleur doit rester
/// testable et sans fenêtre. Ici on ne fait que traduire des phases en pixels,
/// et décider combien de temps un message reste affiché.
@MainActor
final class NotchPresenter {

    private let content = NotchContent()
    private let overlay: NotchOverlay
    private let controller: DictationController

    private var refreshTask: Task<Void, Never>?
    private var dismissTask: Task<Void, Never>?

    init(controller: DictationController) {
        self.controller = controller
        self.overlay = NotchOverlay(content: content)

        controller.onPhaseChange = { [weak self] phase in
            self?.react(to: phase)
        }
        controller.onEmpty = { [weak self] in
            self?.announceEmpty()
        }
    }

    private func react(to phase: DictationMachine.Phase) {
        switch phase {
        case .capturing:
            dismissTask?.cancel()
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
            if let text = controller.lastTranscript {
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

            // `.pasting` arrive juste avant `.idle`, dans la même pile d'appels.
            // Le minuteur de 1,8 s vient d'être posé : le raccourcir ici
            // ferait disparaître le texte avant qu'on ait pu le lire.
            if case .done = content.mode { return }
            if case .empty = content.mode { return }

            // Distinguer « annulé » de « rien entendu » : deux gestes
            // différents, et l'utilisateur doit savoir lequel a été compris.
            if content.mode == .listening || content.mode == .transcribing {
                content.mode = .cancelled
                scheduleDismiss(after: 0.9)
            } else {
                scheduleDismiss(after: 1.2)
            }
        }
    }

    /// Signale explicitement qu'aucune parole n'a été détectée.
    func announceEmpty() {
        dismissTask?.cancel()
        content.mode = .empty
        overlay.show()
        scheduleDismiss(after: 1.4)
    }

    // MARK: - Rafraîchissement

    /// 20 Hz. Le `Canvas` de la vue redessine à 30 Hz de son côté ; ici on ne
    /// fait que pousser de nouvelles valeurs, ce qui est bien plus coûteux.
    private func startRefreshing() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while Task.isCancelled == false {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, Task.isCancelled == false else { return }
                content.levels = controller.waveform
                content.elapsed = controller.elapsed
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
    private static func excerpt(_ text: String, limit: Int = 42) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
