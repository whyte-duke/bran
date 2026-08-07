import AppKit
import BranWatch
import SwiftUI

/// **Le routeur d'attention** : une pilule au-dessus de tout, qui dit la seule
/// voie qu'il faut reprendre maintenant — et qui, depuis, y ramène.
///
/// ```
///   ──────────── barre de menus ────────────
///                        ╭──────────────────────────╮
///                        │ 🔔 crm · feat/api  19 min │  ← cliquable
///                        ╰──────────────────────────╯
/// ```
///
/// **Son propre `NSPanel`, et pas celui de l'encoche.** `NotchPresenter` tient
/// un invariant — un seul présentateur possède le panneau — qui existe parce que
/// deux fonctions se le disputaient. Un panneau distinct ne viole pas cet
/// invariant, il l'évite. Et un fichier neuf ne conflicte avec le travail de
/// personne.
///
/// **Quand il s'affiche, et pourquoi si rarement.** Deux conditions ensemble :
/// une voie attend *et* l'humain ne fait rien. C'est l'idée centrale du produit
/// — le silence partagé — et c'est aussi la seule situation où interrompre ne
/// coûte rien, puisqu'il n'y a rien à interrompre. Tant que quelqu'un tape, la
/// section « Veille » suffit : elle est là, elle ne clignote pas.
///
/// Une seule règle d'arbitrage avec l'encoche : on se cache tant qu'elle
/// travaille. Une observation, aucune propriété partagée.
///
/// **Le clic agit, l'affichage non.** Le panneau reste `.nonactivatingPanel` :
/// dire qu'une machine attend ne doit toujours pas voler le focus à celle où
/// l'on écrit. Seul le clic déclenche quelque chose — et il ne porte que sur le
/// tracé exact de la capsule, voir `PillHostingView`.
@MainActor
final class AttentionOverlay {

    private var panel: NSPanel?
    /// Le repli en cours. Annulé dès qu'on réaffiche : sans ça, une pilule qui
    /// réapparaît juste après avoir été cachée se ferait retirer par la tâche
    /// de la fois d'avant.
    private var collapseTask: Task<Void, Never>?
    private var hosting: PillHostingView?
    private let content = AttentionContent()

    /// Ce qui doit faire taire le panneau sans qu'il ait à savoir pourquoi :
    /// une dictée ou une capture en cours, c'est-à-dire l'encoche déployée.
    private let isSuppressed: @MainActor () -> Bool

    /// Le geste de retour. Assigné après construction, comme
    /// `WatchController.isMuted` et pour la même raison : la fermeture capture
    /// `AppModel`, qui ne peut pas se référencer avant d'avoir fini d'initialiser.
    var onReturn: (@MainActor (LaneIdentity) -> Void)?

    /// La voie que la pilule montre en ce moment. C'est elle que le clic
    /// reprend — et pas celle du verdict au moment du clic : ce qui est écrit à
    /// l'écran est ce qui doit se produire, même si un tic est passé entre les
    /// deux.
    private var shown: LaneIdentity?

    init(isSuppressed: @escaping @MainActor () -> Bool) {
        self.isSuppressed = isSuppressed
    }

    /// Appelé à chaque verdict.
    func update(_ verdict: WatchVerdict, enabled: Bool) {
        guard enabled,
              isSuppressed() == false,
              verdict.muted == false,
              verdict.sharedSilence == true,
              let next = verdict.next
        else {
            hide()
            return
        }

        shown = next.identity
        content.name = next.identity.displayName
        content.detail = Self.detail(for: next, verdict: verdict)
        show()
    }

    private static func detail(for lane: Lane, verdict: WatchVerdict) -> String {
        let minutes = Int(lane.waitingFor / 60)
        let waiting = verdict.lanes.filter { $0.state.deservesAttention }.count
        let duration = minutes >= 1 ? "\(minutes) min" : "à l'instant"
        // Le nombre d'autres voies compte : « une machine attend » et « quatre
        // machines attendent » n'appellent pas le même geste.
        return waiting > 1 ? "\(duration) · et \(waiting - 1) autre(s)" : duration
    }

    // MARK: - Présentation

    private func show() {
        // **Le repli en cours est annulé ici, et il ne l'était nulle part.**
        //
        // La déclaration de `collapseTask` promet pourtant « annulé dès qu'on
        // réaffiche » depuis le premier jour. Seuls `hide()` et `dismiss()`
        // l'annulaient — c'est-à-dire les deux chemins qui n'en ont pas besoin.
        // Une voie qui repasse en attente moins de 300 ms après avoir cessé de
        // l'être — ce qui arrive à chaque tic pendant qu'un agent alterne entre
        // deux outils — se faisait donc retirer par la tâche de la fois d'avant,
        // juste après avoir été affichée. La pilule clignotait, et le geste de
        // retour disparaissait sous le curseur.
        collapseTask?.cancel()
        collapseTask = nil

        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main
        else { return }

        let size = CGSize(width: 260, height: 34)
        // À droite plutôt qu'au centre : le centre est occupé par l'encoche sur
        // un MacBook récent, et par l'encoche *simulée* de la dictée partout
        // ailleurs. Sous la zone auxiliaire droite quand elle existe.
        let right = screen.auxiliaryTopRightArea?.maxX ?? screen.visibleFrame.maxX
        let origin = CGPoint(
            x: min(right, screen.frame.maxX) - size.width - 14,
            y: screen.visibleFrame.maxY - size.height - 8
        )

        if let panel {
            panel.setFrame(NSRect(origin: origin, size: size), display: true)
            panel.orderFrontRegardless()
            content.isVisible = true
            announce()
            return
        }

        let hostingView = PillHostingView(rootView: AttentionPill(content: content))
        hostingView.liveArea = { [content] in content.pillFrame }
        hostingView.onHoverChange = { [content] hovering in content.isHovering = hovering }
        hostingView.onClick = { [weak self] in self?.activate() }

        let newPanel = OverlayPanel.make(
            frame: NSRect(origin: origin, size: size),
            content: hostingView,
            // Le clic **est** le produit ici : c'est le geste de retour. Le tri
            // de ce qui est cliquable se fait dans le `hitTest` de la vue, le
            // panneau étant bien plus grand que la capsule qu'il porte.
            acceptsMouse: true
        )

        panel = newPanel
        hosting = hostingView
        content.isVisible = true
        announce()
    }

    private func activate() {
        guard let shown else { return }
        onReturn?(shown)
    }

    /// **On laisse la pilule se refermer avant de retirer la fenêtre.**
    ///
    /// `orderOut` est synchrone : posé dans le même tour de boucle que
    /// `isVisible = false`, il faisait disparaître le panneau avant la première
    /// image de l'animation de sortie. L'entrée était animée, la sortie était un
    /// clic sec — une asymétrie que la vue déclarait pourtant explicitement.
    ///
    /// Même ordre et même raison que `NotchOverlay.hide()`, dont l'attente vient
    /// aussi de `Design.swift` plutôt que d'un nombre écrit sur place.
    func hide() {
        guard content.isVisible else { return }
        content.isVisible = false
        content.isHovering = false
        hosting?.releaseCursor()

        collapseTask?.cancel()
        collapseTask = Task { [weak self] in
            try? await Task.sleep(for: Motion.pillCollapse)
            guard Task.isCancelled == false else { return }
            self?.panel?.orderOut(nil)
        }
    }

    func dismiss() {
        collapseTask?.cancel()
        collapseTask = nil
        content.isHovering = false
        hosting?.releaseCursor()
        panel?.orderOut(nil)
        panel = nil
        hosting = nil
    }

    // MARK: - VoiceOver

    /// Le dernier texte annoncé, pour ne pas répéter la même phrase à chaque
    /// tic — même mémoire, et même raison, que `NotchPresenter.announce`.
    private var lastAnnouncement = ""

    /// **Un panneau flottant est hors de la hiérarchie d'accessibilité.** Il ne
    /// prend jamais le focus et le curseur VoiceOver ne l'atteint pas : les
    /// attributs posés sur la pilule décrivent correctement ce qu'elle est, mais
    /// personne ne va les lire. C'est exactement le trou que `NotchPresenter` a
    /// dû fermer pour la dictée, et il se ferme de la même façon — une annonce
    /// système, qui coûte une ligne.
    private func announce() {
        let text = "Voie en attente : \(content.name), \(content.detail). Cliquez la pilule pour y revenir."
        guard text != lastAnnouncement else { return }
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
}

// MARK: - Le tri des clics

/// **Le panneau fait 260 × 34 ; la pilule qu'on y dessine est plus petite et
/// collée à droite.**
///
/// Accepter la souris sur tout le panneau avalerait les clics destinés à ce
/// qu'il y a dessous — un menu d'extra, l'icône d'un autre outil — et la zone
/// morte serait invisible, donc incompréhensible. La zone vivante doit être
/// exactement le tracé de la capsule.
///
/// `contentShape(.capsule)` déclare bien cette forme côté SwiftUI, mais la
/// décision d'accepter l'événement se prend un étage plus bas : c'est
/// `NSHostingView` que le serveur de fenêtres interroge. D'où ce `hitTest`, qui
/// consulte le rectangle que la vue publie, et rend `nil` partout ailleurs — le
/// clic traverse alors le panneau comme s'il n'existait pas.
///
/// **Le survol est câblé ici aussi, et pas en SwiftUI.** `onHover` s'appuie sur
/// une zone de suivi `.activeInActiveApp` : elle ne se déclencherait jamais,
/// puisque ce panneau vit par construction au-dessus d'une *autre* application.
/// `.activeAlways` est la seule option qui convienne.
private final class PillHostingView: NSHostingView<AttentionPill> {

    /// Le tracé vivant, en coordonnées SwiftUI (origine en haut à gauche).
    var liveArea: () -> CGRect = { .zero }
    var onHoverChange: (Bool) -> Void = { _ in }
    var onClick: () -> Void = {}

    private var hoverArea: NSTrackingArea?
    private var isInside = false

    // MARK: Souris

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard liveArea().contains(flip(convert(point, from: superview))) else { return nil }
        return super.hitTest(point)
    }

    /// **Le clic est actionné ici, pas par un `onTapGesture`.** Un panneau
    /// borderless et non activant ne devient jamais fenêtre clé ; les gestes
    /// SwiftUI y sont au mieux incertains. La couche AppKit a de toute façon dû
    /// apprendre la forme de la capsule pour le test de survol — lui confier
    /// aussi le déclenchement met la décision à un seul endroit.
    override func mouseUp(with event: NSEvent) {
        guard liveArea().contains(flip(convert(event.locationInWindow, from: nil))) else {
            super.mouseUp(with: event)
            return
        }
        onClick()
    }

    override func mouseMoved(with event: NSEvent) {
        setInside(liveArea().contains(flip(convert(event.locationInWindow, from: nil))))
    }

    override func mouseEntered(with event: NSEvent) {
        setInside(liveArea().contains(flip(convert(event.locationInWindow, from: nil))))
    }

    override func mouseExited(with event: NSEvent) {
        setInside(false)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways],
            owner: self
        )
        addTrackingArea(area)
        hoverArea = area
    }

    /// Le panneau peut disparaître pendant que le curseur est dessus — un
    /// verdict qui change suffit. Sans ce rappel, la main resterait posée sur
    /// la pile des curseurs et le pointeur garderait sa forme partout ailleurs.
    func releaseCursor() {
        guard isInside else { return }
        isInside = false
        NSCursor.pop()
    }

    private func setInside(_ value: Bool) {
        guard value != isInside else { return }
        isInside = value
        onHoverChange(value)
        if value { NSCursor.pointingHand.push() } else { NSCursor.pop() }
    }

    /// SwiftUI place son origine en haut à gauche, AppKit en bas à gauche tant
    /// que la vue n'est pas retournée. Sans cette conversion, la zone vivante
    /// serait testée sur la moitié opposée du panneau : le clic ne marcherait
    /// que là où il ne faut pas.
    private func flip(_ point: NSPoint) -> CGPoint {
        isFlipped ? point : CGPoint(x: point.x, y: bounds.height - point.y)
    }

    // MARK: Rites de NSHostingView

    required init(rootView: AttentionPill) { super.init(rootView: rootView) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) n'est pas utilisé : le panneau est construit en code.") }
}

// MARK: - Le contenu

/// Ce que la pilule affiche. Observable et partagée entre le présentateur et la
/// vue, pour que le panneau se redessine sans être recréé — même parti pris que
/// `NotchContent`, et pour la même raison : remplacer la `rootView` d'un
/// `NSHostingView` pendant une animation laisse SwiftUI avec des attributs qui
/// pointent vers l'arbre précédent.
@MainActor
@Observable
final class AttentionContent {
    var name = ""
    var detail = ""
    var isVisible = false
    var isHovering = false

    /// Le tracé de la capsule, publié par la vue et lu par le test de survol.
    /// La géométrie ne peut venir que de SwiftUI : la pilule se dimensionne sur
    /// son texte, et ce texte change à chaque verdict.
    var pillFrame: CGRect = .zero
}

struct AttentionPill: View {
    @Bindable var content: AttentionContent

    /// Le repère dans lequel la capsule publie son tracé. Nommé, et pas
    /// `.global` : sur un `NSHostingView`, `.global` ne garantit pas l'origine
    /// du panneau, et un décalage silencieux rendrait la pilule cliquable à côté
    /// d'elle-même.
    ///
    /// `nonisolated` parce que `onGeometryChange` évalue sa transformation dans
    /// une fermeture `Sendable`, hors de l'acteur principal où vit `View`.
    private nonisolated static let space = "attention.panel"

    var body: some View {
        pill
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            .coordinateSpace(.named(Self.space))
    }

    /// **Les tailles viennent de l'échelle `Type`, elles ne sont plus fixes.**
    /// La pilule portait 12 et 11 points en dur : un utilisateur qui augmente la
    /// taille du texte de macOS ne voyait rien changer, ce que ce fichier n'a
    /// aucune raison particulière de s'autoriser — contrairement à l'encoche,
    /// dont la hauteur est celle du matériel. Le rembourrage vertical est réduit
    /// à `Space.tight` pour laisser la place à un réglage plus grand dans les
    /// 34 points du panneau.
    private var pill: some View {
        HStack(spacing: Space.small) {
            Image(systemName: "bell.badge.fill")
                .font(Type.groupHead)
                .foregroundStyle(Palette.attention)

            Text(content.name)
                .font(Type.groupHead)
                .lineLimit(1)

            Text(content.detail)
                .font(Type.metaFaint.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, Space.inset)
        .padding(.vertical, Space.tight)
        .background(.ultraThinMaterial, in: .capsule)
        .overlay {
            // Le contour se teinte au survol plutôt que de s'épaissir : la
            // pilule est déjà à la limite de la hauteur du panneau, et un trait
            // plus large la ferait bouger.
            Capsule().strokeBorder(
                content.isHovering ? AnyShapeStyle(Palette.attention) : AnyShapeStyle(.separator),
                lineWidth: 1
            )
        }
        // La forme exacte de la zone sensible. Le reste du panneau doit laisser
        // passer les clics : c'est `PillHostingView.hitTest` qui l'applique
        // réellement, à partir du tracé publié juste dessous.
        .contentShape(.capsule)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: {
            content.pillFrame = $0
        }
        .scaleEffect(content.isHovering ? 1.03 : 1, anchor: .trailing)
        .branAnimation(Motion.hover, value: content.isHovering)
        .opacity(content.isVisible ? 1 : 0)
        .scaleEffect(content.isVisible ? 1 : 0.94, anchor: .top)
        .branAnimation(Motion.enter, value: content.isVisible)
        // Maintenant que la pilule agit, elle doit se décrire. Le panneau reste
        // hors de la hiérarchie d'accessibilité — d'où l'annonce système côté
        // présentateur — mais ces attributs sont ce que lira quiconque
        // l'atteindra, et ils coûtent trois lignes.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(content.name), en attente depuis \(content.detail)")
        .accessibilityHint("Revient sur cette voie")
        .accessibilityAddTraits(.isButton)
    }
}
