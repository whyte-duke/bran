import AppKit
import SwiftUI

/// Ouvre une fenêtre depuis le menu de la barre de menus.
///
/// `openWindow(id:)` seul ne suffit pas depuis un `MenuBarExtra` : l'app est un
/// agent (`LSUIElement`), elle n'est jamais l'application active. La fenêtre est
/// bien créée, mais elle reste derrière tout le reste — indiscernable de
/// « il ne s'est rien passé ».
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
