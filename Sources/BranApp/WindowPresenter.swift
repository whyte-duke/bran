import AppKit
import SwiftUI

/// Ouvre une fenêtre depuis le menu de la barre de menus.
///
/// `openWindow(id:)` seul ne suffit pas depuis un `MenuBarExtra` : bran n'est
/// presque jamais l'application active, puisque tout son intérêt est de ne pas
/// l'être. La fenêtre est bien créée, mais elle reste derrière tout le reste —
/// indiscernable de « il ne s'est rien passé ».
///
/// *Corrigé le 2026-08-06 :* ce commentaire justifiait le contournement par
/// « l'app est un agent (`LSUIElement`) ». Elle ne l'est plus par défaut — voir
/// `DockPresence` — et le contournement reste pourtant nécessaire, parce que ce
/// qui compte n'a jamais été la politique d'activation mais le fait de ne pas
/// avoir le focus.
///
/// Il faut donc activer l'app, puis remonter explicitement la fenêtre au premier
/// plan. Le délai laisse à SwiftUI le temps de créer la fenêtre avant qu'on la
/// cherche : elle n'existe pas encore au retour de `openWindow`.
enum WindowPresenter {
    static func bringToFront(_ identifier: String, using openWindow: OpenWindowAction) {
        openWindow(id: identifier)
        NSApplication.shared.activate()

        Task { @MainActor in
            for _ in 0..<20 {
                if let window = NSApplication.shared.windows.first(where: { $0.identifier?.rawValue == identifier }) {
                    window.makeKeyAndOrderFront(nil)
                    window.orderFrontRegardless()
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
            }

            // Repli : au moins une fenêtre visible vaut mieux qu'aucune.
            NSApplication.shared.windows.first { $0.isVisible }?.makeKeyAndOrderFront(nil)
        }
    }
}
