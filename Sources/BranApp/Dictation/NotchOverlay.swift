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
    private var collapseTask: Task<Void, Never>?
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

        collapseTask?.cancel()
        collapseTask = nil

        let notchHeight = Self.notchHeight(of: screen)
        let notchWidth = Self.notchWidth(of: screen)
        let hasNotch = notchHeight > 0 && notchWidth > 0

        // La fenêtre est créée **à sa taille finale** et ne bouge plus. Toute
        // l'ouverture est jouée par le tracé à l'intérieur : redimensionner un
        // `NSPanel` à chaque image saccade, alors qu'un `Shape` animé est lissé
        // par Core Animation.
        let size = CGSize(
            width: hasNotch ? notchWidth + 2 * NotchView.earWidth : NotchView.pillSize.width,
            height: hasNotch ? notchHeight + NotchView.dropHeight : NotchView.pillSize.height
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
            content.isExpanded = true
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
        content.isExpanded = true
    }

    /// Referme, puis retire la fenêtre.
    ///
    /// L'ordre compte : `orderOut` immédiat ferait disparaître le panneau d'un
    /// coup, et toute l'animation de fermeture ne serait jamais vue. On laisse
    /// donc le tracé se refermer, puis on retire la fenêtre une fois qu'elle est
    /// déjà invisible.
    func hide() {
        content.isExpanded = false

        collapseTask?.cancel()
        collapseTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(380))
            guard Task.isCancelled == false else { return }
            self?.panel?.orderOut(nil)
        }
    }

    func dismiss() {
        collapseTask?.cancel()
        collapseTask = nil
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
        // Dictée
        case listening
        case transcribing
        case done(String)

        // Capture de texte
        /// Chargement du moteur. `nil` tant qu'aucune progression n'est connue :
        /// une barre qui prétend savoir où elle en est alors qu'elle l'ignore
        /// est pire qu'une barre indéterminée.
        case preparing(Double?)
        case reading
        case captured(String)

        // Communs
        case empty
        case cancelled
        case failed(String)

    }

    /// Quelle fonction pilote l'encoche.
    ///
    /// Nécessaire parce que `.empty`, `.cancelled` et `.failed` sont communs aux
    /// deux : sans cette information, une capture sans texte annoncerait
    /// « Rien entendu », ce qui enverrait chercher un problème de micro.
    enum Source: Equatable {
        case dictation
        case snapshot
    }

    var mode: Mode = .listening
    var source: Source = .dictation
    var levels: [Float] = []
    var elapsed: TimeInterval = 0

    /// Ouvert ou fermé. C'est le seul déclencheur de l'animation d'entrée et de
    /// sortie : la vue observe ce booléen, pas la présence de la fenêtre.
    var isExpanded = false
}
