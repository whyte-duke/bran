import AppKit
import SwiftUI

/// Le panneau qui affiche l'état de la dictée, au-dessus de tout.
///
/// Deux géométries, une seule vue :
///
/// ```
/// AVEC ENCOCHE (MacBook, capot ouvert)
///   ┌─────────┐
///  ─┤  ●●●●●  ├─    le panneau épouse l'encoche et déborde de part et d'autre
///   └─────────┘
///
/// SANS ENCOCHE (écran externe, capot fermé, iMac, MacBook d'avant 2021)
///   ──── barre de menus ────
///       ╭───────────────╮
///       │  ●●●●●  0:07  │   pilule flottante juste dessous
///       ╰───────────────╯
/// ```
///
/// Sans le repli, la fonctionnalité devient muette dès qu'on branche un écran —
/// on appuierait sur la touche sans savoir si ça enregistre. Et la majorité des
/// Mac n'ont pas d'encoche du tout.
@MainActor
final class NotchOverlay {

    private var panel: NSPanel?
    private var hosting: NSHostingView<NotchView>?
    private let content: NotchContent

    init(content: NotchContent) {
        self.content = content
    }

    // MARK: - Géométrie

    /// L'écran qui a le focus clavier. C'est là qu'on tape, donc là qu'il faut
    /// afficher — pas forcément sur l'écran intégré.
    private static var activeScreen: NSScreen? {
        NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
    }

    /// Hauteur du trou physique, ou zéro. `safeAreaInsets.top` ne vaut plus de
    /// zéro que sur l'écran interne d'un MacBook à encoche.
    private static func notchHeight(of screen: NSScreen) -> CGFloat {
        screen.safeAreaInsets.top
    }

    /// Largeur de l'encoche, déduite des deux zones auxiliaires : ce qui reste
    /// entre le coin haut-gauche utilisable et le coin haut-droit utilisable.
    private static func notchWidth(of screen: NSScreen) -> CGFloat {
        guard let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else {
            return 0
        }
        return max(0, right.minX - left.maxX)
    }

    // MARK: - Présentation

    func show() {
        guard let screen = Self.activeScreen else { return }

        let notchHeight = Self.notchHeight(of: screen)
        let notchWidth = Self.notchWidth(of: screen)
        let hasNotch = notchHeight > 0 && notchWidth > 0

        let size = CGSize(
            width: hasNotch ? notchWidth + 2 * NotchView.earWidth : 260,
            height: hasNotch ? notchHeight + NotchView.dropHeight : 44
        )

        let origin = CGPoint(
            x: screen.frame.midX - size.width / 2,
            // Avec encoche, on part du bord haut de l'écran pour épouser le trou.
            // Sans, on se glisse sous la barre de menus.
            y: hasNotch
                ? screen.frame.maxY - size.height
                : screen.visibleFrame.maxY - size.height - 8
        )

        let view = NotchView(content: content, hasNotch: hasNotch, notchWidth: notchWidth)

        if let panel, let hosting {
            hosting.rootView = view
            panel.setFrame(NSRect(origin: origin, size: size), display: true)
            panel.orderFrontRegardless()
            return
        }

        let hostingView = NSHostingView(rootView: view)
        let newPanel = NSPanel(
            contentRect: NSRect(origin: origin, size: size),
            // `.nonactivatingPanel` : afficher l'état de la dictée ne doit pas
            // voler le focus à l'application où l'on est en train d'écrire.
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        newPanel.contentView = hostingView
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        newPanel.hasShadow = false
        // Au-dessus de la barre de menus, sinon le panneau passe dessous sur un
        // écran à encoche et devient invisible.
        newPanel.level = .init(Int(CGShieldingWindowLevel()))
        newPanel.ignoresMouseEvents = true
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        newPanel.hidesOnDeactivate = false
        newPanel.orderFrontRegardless()

        panel = newPanel
        hosting = hostingView
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
        hosting = nil
    }
}

/// Ce que l'encoche affiche. Une classe observable partagée entre le contrôleur
/// et la vue, pour que le panneau se redessine sans être recréé.
@MainActor
@Observable
final class NotchContent {
    enum Mode: Equatable {
        case listening
        case transcribing
        case done(String)
        case empty
        case cancelled
        case failed(String)
    }

    var mode: Mode = .listening
    var levels: [Float] = []
    var elapsed: TimeInterval = 0
}
