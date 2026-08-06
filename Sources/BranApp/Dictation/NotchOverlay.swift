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
    /// La géométrie actuellement posée sur le panneau. Elle ne dépend que de
    /// l'écran : tant qu'elle ne change pas, la fenêtre ne bouge plus.
    private var geometry: Geometry?

    init(content: NotchContent) {
        self.content = content
    }

    // MARK: - Géométrie

    /// L'écran qui a le focus clavier. C'est là qu'on tape, donc là qu'il faut
    /// afficher — pas forcément sur l'écran intégré.
    ///
    /// **La souris n'est qu'un repli.** La version précédente ne lisait que
    /// `NSEvent.mouseLocation`, ce que son propre commentaire contredisait :
    /// dicter dans une fenêtre de l'écran interne en ayant laissé le curseur sur
    /// l'écran externe affichait l'encoche sur le mauvais écran.
    private static var activeScreen: NSScreen? {
        NSApp.keyWindow?.screen
            ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
    }

    /// Tout ce que le panneau doit savoir — et **rien du contenu**.
    private struct Geometry: Equatable {
        var hasNotch: Bool
        var notchWidth: CGFloat
        var notchHeight: CGFloat
        var frame: NSRect
    }

    /// **Le panneau est dimensionné une fois pour toutes, à la plus grande
    /// géométrie.**
    ///
    /// Le calcul précédent partait du contenu, donc la fenêtre changeait de
    /// taille dès que le contenu changeait — et il fallait alors remplacer la
    /// `rootView`, ce que le commentaire de `show()` identifiait lui-même comme
    /// dangereux. Tant qu'il n'y avait que deux fonctions et deux tailles
    /// constantes par écran, le cas ne se présentait jamais ; il serait devenu
    /// le cas normal à la troisième.
    ///
    /// La fenêtre est transparente et ignore la souris : la faire plus large
    /// qu'il ne faut ne coûte rien, et le contenu qui grandit à l'intérieur est
    /// animé par SwiftUI au lieu d'être redimensionné image par image.
    private static func geometry(of screen: NSScreen) -> Geometry {
        let notchHeight = notchHeight(of: screen)
        let notchWidth = notchWidth(of: screen)
        let hasNotch = notchHeight > 0 && notchWidth > 0

        let contentHeight = hasNotch ? notchHeight + NotchView.dropHeight : NotchView.pillSize.height
        let size = CGSize(
            width: NotchView.maximumWidth,
            height: contentHeight + NotchView.verticalSlack
        )

        // Le haut du **contenu**, pas celui de la fenêtre : le contenu est calé
        // en haut d'un panneau plus grand que lui.
        let contentTop = hasNotch ? screen.frame.maxY : screen.visibleFrame.maxY - 8

        return Geometry(
            hasNotch: hasNotch,
            notchWidth: notchWidth,
            notchHeight: notchHeight,
            frame: NSRect(
                x: screen.frame.midX - size.width / 2,
                y: contentTop - size.height,
                width: size.width,
                height: size.height
            )
        )
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

        let next = Self.geometry(of: screen)

        if let panel, let hosting {
            // **La `rootView` n'est plus remplacée qu'au changement d'écran
            // physique.** `show()` est appelé à chaque changement de phase, et
            // remplacer la `rootView` d'un `NSHostingView` pendant qu'une
            // animation tourne à 40 images par seconde laisse SwiftUI avec des
            // attributs qui pointent vers l'arbre précédent. Le contenu, lui,
            // est observable : il se met à jour tout seul, et la fenêtre garde
            // la même taille quoi qu'il affiche.
            if geometry != next {
                geometry = next
                hosting.rootView = view(for: next)
                panel.setFrame(next.frame, display: true)
            }
            panel.orderFrontRegardless()
            content.isExpanded = true
            return
        }

        geometry = next
        let hostingView = NSHostingView(rootView: view(for: next))
        let newPanel = NSPanel(
            contentRect: next.frame,
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

    private func view(for geometry: Geometry) -> NotchView {
        NotchView(
            content: content,
            hasNotch: geometry.hasNotch,
            notchWidth: geometry.notchWidth,
            notchHeight: geometry.notchHeight
        )
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
        geometry = nil
    }
}

/// Ce que l'encoche affiche. Une classe observable partagée entre le contrôleur
/// et la vue, pour que le panneau se redessine sans être recréé.
@MainActor
@Observable
final class NotchContent {
    enum Mode: Equatable {
        /// Rien en cours. **L'état initial d'un panneau vide.**
        ///
        /// Sans lui, un panneau qui n'a encore rien à dire démarrait sur
        /// « à l'écoute », pastille rouge comprise : tout chemin appelant
        /// `show()` avant d'avoir posé un mode annonçait une dictée qui
        /// n'existait pas.
        case idle

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

        /// Un mode qu'on peut interrompre — donc dont le retour au repos veut
        /// dire « annulé » et non « terminé ».
        ///
        /// **Une propriété, pas une comparaison de cas.** `NotchPresenter`
        /// écrivait `[.listening, .transcribing].contains(mode)`, ce qui passe
        /// par `Equatable`, donc par les valeurs associées : le jour où l'un de
        /// ces cas en porte une, la comparaison devient silencieusement fausse.
        /// `.preparing(_)` le montrait déjà — impossible à mettre dans une telle
        /// liste sans en inventer la valeur.
        var isCancellable: Bool {
            switch self {
            case .listening, .transcribing, .preparing, .reading: true
            case .idle, .done, .captured, .empty, .cancelled, .failed: false
            }
        }
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

    var mode: Mode = .idle
    var source: Source = .dictation
    var levels: [Float] = []
    var elapsed: TimeInterval = 0

    /// Ouvert ou fermé. C'est le seul déclencheur de l'animation d'entrée et de
    /// sortie : la vue observe ce booléen, pas la présence de la fenêtre.
    var isExpanded = false
}
