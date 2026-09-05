import AppKit
import BranWindows
import CoreGraphics
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
    private struct ScreenContext {
        let screen: NSScreen
        let isFullScreen: Bool
    }

    /// L'écran et le mode de la fenêtre réellement au premier plan.
    ///
    /// `NSApp.keyWindow` ne répond pas à cette question quand bran est en
    /// arrière-plan : elle peut encore désigner sa propre fenêtre de réglages,
    /// sur un autre écran. Le serveur de fenêtres donne au contraire le cadre de
    /// la fenêtre que l'utilisateur utilise. Ses coordonnées sont celles de
    /// Core Graphics ; `CGDisplayBounds` permet de les comparer sans conversion
    /// fragile avec les coordonnées AppKit.
    private static var activeContext: ScreenContext? {
        if let application = NSWorkspace.shared.frontmostApplication,
           let window = WindowList.onScreen(titled: false).first(where: {
               $0.processID == application.processIdentifier
                   && $0.layer == 0
                   && $0.frame.isEmpty == false
           }),
           let pair = NSScreen.screens.compactMap({ screen -> (NSScreen, CGRect)? in
               guard let bounds = displayBounds(of: screen) else { return nil }
               return (screen, bounds)
           }).first(where: { $0.1.contains(CGPoint(x: window.frame.midX, y: window.frame.midY)) }) {
            return ScreenContext(
                screen: pair.0,
                isFullScreen: fillsDisplay(window.frame, displayBounds: pair.1)
            )
        }

        let screen = NSApp.keyWindow?.screen
            ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
        return screen.map { ScreenContext(screen: $0, isFullScreen: false) }
    }

    private static func displayBounds(of screen: NSScreen) -> CGRect? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let number = screen.deviceDescription[key] as? NSNumber else { return nil }
        return CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
    }

    /// Une fenêtre plein écran couvre le display, contrairement à une fenêtre
    /// simplement maximisée qui laisse au moins la barre de menus. Une petite
    /// tolérance absorbe les arrondis de pixels et les bordures invisibles.
    private static func fillsDisplay(_ window: CGRect, displayBounds: CGRect) -> Bool {
        let tolerance: CGFloat = 4
        return abs(window.minX - displayBounds.minX) <= tolerance
            && abs(window.minY - displayBounds.minY) <= tolerance
            && abs(window.width - displayBounds.width) <= tolerance
            && abs(window.height - displayBounds.height) <= tolerance
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
    private static func geometry(for context: ScreenContext) -> Geometry {
        let screen = context.screen
        let notchHeight = notchHeight(of: screen)
        let notchWidth = notchWidth(of: screen)
        // En plein écran, la zone de l'encoche appartient au Space principal et
        // peut masquer notre dessin malgré `.fullScreenAuxiliary`. La parade est
        // volontairement visuelle : on garde exactement le même contenu dans
        // une pilule placée juste sous la zone sûre, donc toujours dans les
        // pixels de l'application plein écran.
        let hasNotch = context.isFullScreen == false && notchHeight > 0 && notchWidth > 0

        let contentHeight = hasNotch ? notchHeight + NotchView.dropHeight : NotchView.pillSize.height
        let size = CGSize(
            width: NotchView.maximumWidth,
            height: contentHeight + NotchView.verticalSlack
        )

        // Le haut du **contenu**, pas celui de la fenêtre : le contenu est calé
        // en haut d'un panneau plus grand que lui.
        let contentTop: CGFloat
        if hasNotch {
            contentTop = screen.frame.maxY
        } else if context.isFullScreen {
            contentTop = screen.frame.maxY - notchHeight - 8
        } else {
            contentTop = screen.visibleFrame.maxY - 8
        }

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

    /// Hauteur du trou physique, ou zéro.
    ///
    /// La zone sûre suffit sur le bureau normal. Les rectangles auxiliaires
    /// gardent en plus la mesure matérielle quand une application plein écran
    /// reprend la barre de menus, précisément au moment où le repli en pilule
    /// en a besoin pour ne pas se poser sous la caméra.
    private static func notchHeight(of screen: NSScreen) -> CGFloat {
        let auxiliaryHeight = max(
            screen.auxiliaryTopLeftArea?.height ?? 0,
            screen.auxiliaryTopRightArea?.height ?? 0
        )
        return max(screen.safeAreaInsets.top, auxiliaryHeight)
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
        guard let context = Self.activeContext else { return }

        collapseTask?.cancel()
        collapseTask = nil

        let next = Self.geometry(for: context)

        if let panel, let hosting, panel.isOnActiveSpace {
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

        // `NSPanel.isVisible` ne suffit pas après une veille : AppKit peut
        // conserver une fenêtre ordonnée sur l'ancien Space alors qu'elle
        // n'est plus composée sur celui où l'utilisateur travaille. C'est le
        // même état qui rendait le panneau du presse-papiers « visible et clé »
        // dans le journal, mais absent de l'écran. L'encoche ne porte aucun état
        // durable ; la recréer sur l'écran actif est donc la réparation la plus
        // petite et ne touche ni à la dictée ni à l'OCR en cours.
        if panel != nil {
            dismiss()
        }

        geometry = next
        let hostingView = NSHostingView(rootView: view(for: next))
        let newPanel = OverlayPanel.make(
            frame: next.frame,
            content: hostingView,
            // L'encoche n'a aucun contrôle : elle affiche un état. Intercepter un
            // clic destiné à la fenêtre du dessous serait un défaut pur.
            acceptsMouse: false
        )

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
    ///
    /// **L'attente vient de `Motion.notchCollapse`, pas d'un nombre écrit ici.**
    /// Elle valait 380 ms en dur, pendant que le ressort qu'elle attend vit dans
    /// `Design.swift`. Deux fichiers pour un seul mouvement : régler le ressort
    /// sans y penser faisait disparaître le panneau au milieu de sa propre
    /// fermeture, et rien n'aurait pu le signaler.
    func hide() {
        content.isExpanded = false

        collapseTask?.cancel()
        collapseTask = Task { [weak self] in
            try? await Task.sleep(for: Motion.notchCollapse)
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
        /// **Le collage est en train de se faire.** Présent, pas passé : la
        /// phase `.pasting` est atteinte *avant* que le presse-papiers soit
        /// écrit et le ⌘V envoyé, et depuis que cette écriture est asynchrone,
        /// elle peut attendre des secondes derrière une lecture bloquée
        /// (`Paster`, point 8). L'encoche disait « Dictée collée » à cet
        /// instant-là : elle affirmait un fait qui n'avait pas eu lieu, et son
        /// minuteur de 1,8 s pouvait la faire disparaître avant qu'il n'ait
        /// lieu.
        ///
        /// Sans texte associé, délibérément. Le mode est posé au changement de
        /// phase, et à cet instant `DictationController.lastTranscript` n'est
        /// pas encore écrit : c'est l'effet `.paste` qui l'écrit, et les effets
        /// s'exécutent après la publication de la phase. L'extrait n'a de toute
        /// façon de sens qu'après coup — il sert à vérifier ce qui a atterri.
        case pasting
        case done(String)

        // Capture de texte
        /// Chargement du moteur. `nil` tant qu'aucune progression n'est connue :
        /// une barre qui prétend savoir où elle en est alors qu'elle l'ignore
        /// est pire qu'une barre indéterminée.
        case preparing(Double?)
        case reading
        /// L'écriture au presse-papiers est en cours. Même raison qu'à
        /// `.pasting`, même remède.
        case copying
        case captured(String)

        // Communs
        /// Le texte est au presse-papiers **et l'utilisateur a un ⌘V à faire**.
        ///
        /// Un troisième état de fin, et non une variante de `.done` : ce que
        /// `Paster.Landing.clipboardOnly` décrit n'est pas un collage réussi,
        /// c'est un collage qui n'a pas pu se faire — cible disparue, saisie
        /// sécurisée. Les confondre laissait l'utilisateur devant une coche
        /// verte et un texte qui n'était nulle part.
        case handedOver
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
        ///
        /// `.pasting` et `.copying` n'en sont pas : la touche est relâchée, le
        /// texte existe, et plus rien n'attend l'utilisateur. Les compter comme
        /// interruptibles ferait annoncer « annulé » au retour au repos, sur une
        /// dictée qui vient d'aboutir.
        var isCancellable: Bool {
            switch self {
            case .listening, .transcribing, .preparing, .reading: true
            case .idle, .pasting, .copying, .done, .captured, .handedOver,
                 .empty, .cancelled, .failed: false
            }
        }

        /// Un état de fin : il a le dernier mot, et le retour au repos ne doit
        /// pas l'écraser.
        ///
        /// **Le piège que ça ferme.** `NotchPresenter.settleToIdle` énumérait
        /// ces cas à la main, dans quatre `if case`. Le cinquième état de fin —
        /// `.handedOver` — se serait ajouté sans que rien ne le rappelle, et
        /// l'instruction « faites ⌘V » aurait disparu au bout de 0,9 s en
        /// laissant « Annulé » à sa place.
        var isTerminal: Bool {
            switch self {
            case .done, .captured, .handedOver, .empty, .cancelled, .failed: true
            case .idle, .listening, .transcribing, .pasting, .preparing, .reading, .copying: false
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
