import AppKit
import CoreGraphics
import Foundation

/// Le collage du texte là où était le curseur.
///
/// Deux détails qui font toute la différence entre « ça marche » et « ça marche
/// vraiment » :
///
/// 1. **La cible peut changer.** Vous appuyez dans Slack, vous parlez, une
///    notification vous fait cliquer ailleurs, vous relâchez. Le texte partirait
///    dans la mauvaise fenêtre. On mémorise donc l'application au *début* de la
///    dictée et on la réactive avant de coller.
/// 2. **Le presse-papiers appartient à l'utilisateur.** Il y avait peut-être
///    quelque chose dedans. On le sauvegarde et on le rend après.
@MainActor
final class Paster {

    /// Application visée, mémorisée au moment où la dictée démarre.
    private var target: NSRunningApplication?

    /// Contenu du presse-papiers avant qu'on y touche.
    private var savedItems: [[String: Data]] = []

    /// Faut-il rendre le presse-papiers à l'utilisateur après collage ?
    /// Certains préfèrent garder la dernière dictée sous la main.
    var restoresClipboard = true

    /// Mémorise la cible. À appeler à l'appui sur le raccourci, pas au
    /// relâchement.
    func rememberTarget() {
        target = NSWorkspace.shared.frontmostApplication
    }

    /// Place le texte dans le presse-papiers et le colle dans la cible.
    ///
    /// Retourne `false` si le collage n'a pas pu être simulé — le texte reste
    /// alors dans le presse-papiers, et c'est ce qu'on dit à l'utilisateur.
    /// Perdre le texte serait la pire issue possible.
    @discardableResult
    func paste(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        saveClipboard(from: pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        guard let target, target.isTerminated == false else {
            // La cible a disparu pendant qu'on transcrivait. Le texte est dans
            // le presse-papiers : c'est récupérable, contrairement à un collage
            // envoyé dans le vide.
            return false
        }

        // La saisie sécurisée bloque aussi la synthèse d'événements. Inutile
        // d'essayer : on garde le presse-papiers et on le dit.
        guard HotkeyMonitor.isSecureInputActive == false else { return false }

        target.activate()

        // Laisser le temps au changement d'application d'aboutir. Sans ce
        // délai, le ⌘V part avant que la cible ait le focus clavier et se perd.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            Self.sendCommandV()
            guard let self, restoresClipboard else { return }
            // Assez tard pour que la cible ait lu le presse-papiers, assez tôt
            // pour que l'utilisateur ne s'en aperçoive pas.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                self.restoreClipboard(into: NSPasteboard.general)
            }
        }

        return true
    }

    /// Place le texte dans le presse-papiers, sans coller.
    func copyOnly(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // MARK: - Presse-papiers

    private func saveClipboard(from pasteboard: NSPasteboard) {
        guard restoresClipboard else { return }
        savedItems = pasteboard.pasteboardItems?.compactMap { item in
            var payload: [String: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { payload[type.rawValue] = data }
            }
            return payload.isEmpty ? nil : payload
        } ?? []
    }

    private func restoreClipboard(into pasteboard: NSPasteboard) {
        guard savedItems.isEmpty == false else { return }
        pasteboard.clearContents()
        let items = savedItems.map { payload -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in payload {
                item.setData(data, forType: NSPasteboard.PasteboardType(type))
            }
            return item
        }
        pasteboard.writeObjects(items)
        savedItems = []
    }

    // MARK: - Synthèse du ⌘V

    private static func sendCommandV() {
        // `cghidEventTap` et non `cgSessionEventTap` : injecté au niveau du
        // pilote, c'est le seul endroit où toutes les applications le voient,
        // y compris celles qui filtrent les événements de session.
        let source = CGEventSource(stateID: .hidSystemState)
        let keyCodeV: CGKeyCode = 9

        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCodeV, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCodeV, keyDown: false)
        else { return }

        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
