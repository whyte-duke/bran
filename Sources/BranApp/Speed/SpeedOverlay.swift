import AppKit
import BranCore
import SwiftUI

/// **Le compteur, sous la barre de menus.**
///
/// ```
///   ──────── barre de menus ────────────────────  ◉ 21,5
///                            ╭──────────────────────╮
///                            │  ◗ Descente          │
///                            │      ╭─────╮         │
///                            │     │ 21,5  │        │
///                            │      ╰─────╯         │
///                            │  172 Mbit/s · 26 ms  │
///                            ╰──────────────────────╯
/// ```
///
/// **Le troisième panneau flottant de bran, et le premier à ne pas recopier sa
/// configuration.** `OverlayPanel` existe précisément pour ça : l'encoche et la
/// pilule du veilleur avaient dupliqué neuf lignes de réglages, à une propriété
/// près, et le fichier a été écrit pour que le suivant n'ait plus à les
/// connaître. Celui-ci est ce suivant.
///
/// **Pourquoi un panneau à soi et pas l'encoche.** L'encoche est partagée par la
/// dictée et la capture de texte, et son `NotchContent.Mode` porte douze cas
/// dont deux propriétés exhaustives — `isCancellable`, `isTerminal` — qui
/// arbitrent des fins de course subtiles déjà payées par des défauts réels. Y
/// ajouter trois cas pour une troisième fonction reviendrait à rouvrir cet
/// arbitrage pour une fonction qui n'en a pas besoin : un test de débit ne colle
/// rien, n'est pas interruptible par relâchement de touche, et n'a pas de
/// livraison à confirmer. Le veilleur avait pris la même décision, pour la même
/// raison, et c'est le précédent qu'on suit.
///
/// **À droite, sous l'icône de bran.** Le centre est occupé par l'encoche — la
/// vraie sur un MacBook récent, celle que la dictée simule partout ailleurs — et
/// le test de débit se déclenche depuis le menu, donc l'œil est déjà à droite au
/// moment où le panneau s'ouvre. La pilule du veilleur occupe le même coin ; elle
/// se tait pendant la mesure, comme elle se tait déjà pendant une dictée.
@MainActor
final class SpeedOverlay {

    private var panel: NSPanel?
    private var hosting: SpeedHostingView?
    private let controller: SpeedController
    private let chrome = SpeedChrome()

    init(controller: SpeedController) {
        self.controller = controller
    }

    func setVisible(_ visible: Bool) {
        visible ? show() : hide()
    }

    private func show() {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main
        else { return }

        let size = CGSize(width: Metric.width, height: Metric.height)
        // Sous la zone auxiliaire droite quand elle existe — c'est-à-dire sous
        // la partie de la barre de menus qui porte les icônes, encoche exclue.
        let right = screen.auxiliaryTopRightArea?.maxX ?? screen.visibleFrame.maxX
        let origin = CGPoint(
            x: min(right, screen.frame.maxX) - size.width - Space.inset,
            y: screen.visibleFrame.maxY - size.height - Space.small
        )

        if let panel {
            panel.setFrame(NSRect(origin: origin, size: size), display: true)
            panel.orderFrontRegardless()
            return
        }

        let view = SpeedHostingView(rootView: SpeedPanel(controller: controller, chrome: chrome))
        view.liveArea = { [chrome] in chrome.closeFrame }
        view.onHoverChange = { [chrome] hovering in chrome.isHoveringClose = hovering }
        view.onClick = { [weak self] in self?.controller.cancel() }

        panel = OverlayPanel.make(
            frame: NSRect(origin: origin, size: size),
            content: view,
            // **Le panneau accepte la souris, mais seulement sur la croix.**
            //
            // Il ne l'acceptait pas. L'argument tenait — un afficheur d'état n'a
            // pas de contrôle, et intercepter un clic destiné à la fenêtre du
            // dessous est un défaut pur — mais il oubliait le cas où l'affichage
            // lui-même est ce qui gêne : neuf secondes d'animation posées sur ce
            // qu'on est en train de faire, sans aucun moyen de les faire taire.
            //
            // Le tri de ce qui est cliquable se fait dans le `hitTest` de
            // `SpeedHostingView`, à partir du tracé que la croix publie : tout le
            // reste du panneau continue de laisser passer les clics comme avant.
            // C'est exactement ce que fait la pilule du veilleur, dont le panneau
            // est lui aussi bien plus grand que sa zone sensible.
            acceptsMouse: true
        )
        hosting = view
    }

    private func hide() {
        // Le panneau peut disparaître pendant que le curseur est posé sur la
        // croix — l'échéance de cinq secondes suffit. Sans ce rappel, la main
        // resterait sur la pile des curseurs et le pointeur garderait sa forme
        // partout ailleurs. Même rite que la pilule du veilleur.
        hosting?.releaseCursor()
        panel?.orderOut(nil)
        panel = nil
        hosting = nil
    }

    enum Metric {
        static let width: CGFloat = 236
        static let height: CGFloat = 178
    }
}

/// L'état de la croix : son tracé, et si le curseur est dessus.
///
/// **Séparé du contrôleur, délibérément.** Où se trouve un bouton à l'écran et
/// s'il est survolé ne dit rien sur le débit d'une ligne ; ranger ça dans
/// `SpeedController` le rendrait dépendant d'une géométrie, et la sonde en ligne
/// de commande — qui fait tourner la même mesure sans écran — hériterait de deux
/// propriétés qui n'ont aucun sens pour elle. C'est le même partage que
/// `AttentionContent`.
@MainActor
@Observable
final class SpeedChrome {
    /// Le tracé de la croix, en coordonnées SwiftUI. C'est la seule zone du
    /// panneau qui intercepte un clic.
    var closeFrame: CGRect = .zero
    var isHoveringClose = false
}

/// La vue qui ne réclame la souris **que sur la croix**.
///
/// Copie assumée de `PillHostingView`, y compris ses raisons — elles sont les
/// mêmes, mot pour mot, et elles ont été payées une fois : un panneau borderless
/// et non activant ne devient jamais fenêtre clé, donc les gestes SwiftUI y sont
/// au mieux incertains ; et `onHover` s'appuie sur une zone de suivi
/// `.activeInActiveApp` qui ne se déclencherait jamais, ce panneau vivant par
/// construction au-dessus d'une *autre* application.
///
/// Elles ne sont pas réunies dans un type commun parce que `NSHostingView` est
/// générique sur sa vue racine : les factoriser demanderait d'effacer ce type,
/// donc de perdre précisément ce que `NSHostingView` apporte. Ce qui *pouvait*
/// être mis en commun — la configuration de la fenêtre — l'est déjà, dans
/// `OverlayPanel`.
private final class SpeedHostingView: NSHostingView<SpeedPanel> {

    var liveArea: () -> CGRect = { .zero }
    var onHoverChange: (Bool) -> Void = { _ in }
    var onClick: () -> Void = {}

    private var hoverArea: NSTrackingArea?
    private var isInside = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard liveArea().contains(flip(convert(point, from: superview))) else { return nil }
        return super.hitTest(point)
    }

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

    required init(rootView: SpeedPanel) { super.init(rootView: rootView) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) n'est pas utilisé : le panneau est construit en code.") }
}

/// Ce que le panneau montre. Il observe le contrôleur directement : celui-ci est
/// `@Observable`, donc il n'y a pas de raison d'interposer un objet de contenu
/// comme le font l'encoche et la pilule — les deux le font parce que leur
/// contrôleur, lui, n'est pas observable.
private struct SpeedPanel: View {
    let controller: SpeedController
    @Bindable var chrome: SpeedChrome

    /// Le repère dans lequel la croix publie son tracé. Nommé, et pas
    /// `.global` : sur un `NSHostingView`, `.global` ne garantit pas l'origine du
    /// panneau, et un décalage silencieux rendrait la croix cliquable à côté
    /// d'elle-même. Même précaution que la pilule du veilleur.
    ///
    /// `nonisolated` parce que `onGeometryChange` évalue sa transformation dans
    /// une fermeture `Sendable`, hors de l'acteur principal où vit `View`.
    private nonisolated static let space = "speed.panel"

    /// La dernière phrase annoncée, pour ne pas la répéter. Même mémoire, et
    /// même raison, que `AttentionOverlay.announce`.
    @State private var lastAnnouncement = ""

    var body: some View {
        VStack(spacing: Space.small) {
            header

            // **Un échec n'a pas de cadran.** La première version en gardait un,
            // vide, et le rendu l'a tranché : il ne restait qu'une ligne pour la
            // phrase, qui s'y coupait à « demande une paus… ». Un cadran à zéro
            // n'apprend rien sur une panne, et il volait la place du seul texte
            // qui, lui, apprend quelque chose — notamment que la pause vient du
            // serveur et non de la ligne.
            if case .failed(let reason) = controller.phase {
                Spacer(minLength: 0)
                Text(reason)
                    .font(Type.cardBody)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            } else {
                SpeedDial(
                    needle: controller.needle,
                    caption: dialCaption,
                    unit: "Mo/s",
                    tint: tint,
                    isMeasuring: controller.phase.isRunning
                )

                footer
            }
        }
        .padding(Space.inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: Radius.panel))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.panel, style: .continuous)
                .strokeBorder(.separator, lineWidth: Space.line)
        }
        .coordinateSpace(.named(Self.space))
        .branAnimation(Motion.enter, value: controller.phase)
        // **`.contain` et non `.ignore`.** Le panneau était purement décoratif,
        // donc il s'annonçait d'un bloc et masquait ses enfants. Il porte
        // maintenant une commande : l'aplatir rendrait la croix inatteignable
        // pour qui navigue au clavier ou à VoiceOver, c'est-à-dire précisément
        // ceux pour qui un panneau surgissant est le plus coûteux à subir.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilitySummary)
        // **Le panneau est hors du parcours VoiceOver, et les attributs
        // ci-dessus ne suffisent donc pas.**
        //
        // `OverlayPanel.make` construit un `NSPanel` `[.borderless,
        // .nonactivatingPanel]` : il ne devient jamais fenêtre clé, et le
        // curseur d'accessibilité ne le rejoint pas. Quelqu'un qui lance un test
        // depuis le menu voit l'aiguille tourner pendant neuf secondes ; à
        // VoiceOver, il ne se passe rien du tout — ni le début, ni le résultat,
        // ni l'échec.
        //
        // Le remède est celui qu'`AttentionOverlay` a déjà payé pour la pilule
        // du veilleur : une annonce système, qui ne demande pas que la fenêtre
        // soit atteignable. Elle est accrochée à la **phase** et non à
        // l'aiguille : celle-ci change plusieurs fois par seconde, et l'annoncer
        // couvrirait la voix de tout le reste du système.
        .onAppear { announce() }
        .onChange(of: controller.phase) { _, _ in announce() }
    }

    /// Dit où en est la mesure, une fois par changement de phase.
    private func announce() {
        let text = "\(accessibilitySummary). Le panneau flotte : ouvrez bran, section Débit, pour l'arrêter."
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

    private var header: some View {
        HStack(spacing: Space.tight) {
            Image(systemName: symbol)
                .font(Type.metaFaint)
                .foregroundStyle(tint)
            Text(controller.phase.title)
                .font(Type.panelHead)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            close
        }
    }

    /// **La croix : arrêter la mesure et faire disparaître le panneau.**
    ///
    /// Elle est **grande**, et c'est le point. Une croix de onze points au coin
    /// d'un panneau qu'on n'a pas demandé est une croix qu'on ne trouve pas :
    /// le panneau se pose au-dessus de ce qu'on est en train de faire, et le
    /// geste qu'on cherche alors est le plus impatient de toute l'application.
    /// Vingt-six points de cible, c'est deux fois la surface d'une pastille de
    /// fenêtre, et ça reste discret tant qu'on ne la vise pas.
    ///
    /// **Elle est là dans tous les états**, pas seulement pendant la mesure. Un
    /// verdict s'affiche cinq secondes, ce qui est court quand on le lit et long
    /// quand on l'a déjà lu ; un échec reste quatre secondes de plus. Il n'y a
    /// aucun état de ce panneau où « je veux qu'il parte » soit une demande
    /// illégitime.
    ///
    /// Le clic lui-même n'est pas ici : c'est `SpeedHostingView.mouseUp` qui
    /// l'actionne, à partir du tracé publié juste dessous. Un panneau borderless
    /// et non activant ne devient jamais fenêtre clé, et les gestes SwiftUI y
    /// sont au mieux incertains — la leçon est celle de la pilule du veilleur,
    /// et elle a déjà été payée une fois.
    private var close: some View {
        Image(systemName: "xmark")
            .font(.system(size: Metric.crossGlyph, weight: .semibold))
            .foregroundStyle(chrome.isHoveringClose ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            .frame(width: Metric.cross, height: Metric.cross)
            .background(
                Circle().fill(chrome.isHoveringClose ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
            )
            .contentShape(.circle)
            .branAnimation(Motion.hover, value: chrome.isHoveringClose)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: {
                chrome.closeFrame = $0
            }
            .accessibilityLabel("Arrêter la mesure")
            .accessibilityAddTraits(.isButton)
    }

    private enum Metric {
        /// La cible. Deux fois la surface d'une pastille de fenêtre.
        static let cross: CGFloat = 26
        /// Le trait de la croix à l'intérieur.
        static let crossGlyph: CGFloat = 13
    }

    /// Les deux lignes du bas. **Elles changent avec la phase**, parce qu'un
    /// panneau qui garderait la même mise en page du début à la fin devrait
    /// afficher « — » pendant les huit premières secondes, à l'endroit précis
    /// où l'œil va chercher le résultat.
    @ViewBuilder
    private var footer: some View {
        switch controller.phase {
        case .sounding:
            Text("Mesure de la latence…")
                .font(Type.metaFaint)
                .foregroundStyle(.secondary)

        case .done, .idle:
            // **Les deux sens, une fois le test fini.** Le cadran n'en porte
            // qu'un — la descente, celle qu'on est venu chercher — mais laisser
            // la montée au seul menu revenait à cacher un chiffre qu'on vient
            // d'attendre quatre secondes de plus pour obtenir.
            VStack(spacing: 1) {
                HStack(spacing: Space.small) {
                    Text("↓ \(SpeedFormat.megabits(controller.reading.download))")
                    Text("↑ \(SpeedFormat.megabits(controller.reading.upload))")
                }
                .font(Type.metaFaint.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)

                latencyLine
            }

        default:
            VStack(spacing: 1) {
                Text(SpeedFormat.megabits(footerRate))
                    .font(Type.metaFaint.monospacedDigit())
                    .foregroundStyle(.secondary)
                latencyLine
            }
        }
    }

    /// La latence, sous les débits. Absente tant qu'elle n'a pas été mesurée :
    /// une ligne « — ms · — ms » occuperait la place en ne disant rien.
    @ViewBuilder
    private var latencyLine: some View {
        if let latency = controller.reading.latency {
            Text("\(SpeedFormat.milliseconds(latency))  ·  \(SpeedFormat.milliseconds(controller.reading.jitter)) de gigue")
                .font(Type.metaFaint.monospacedDigit())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    /// Le chiffre du centre : **l'aiguille pendant la mesure, le verdict après.**
    ///
    /// C'est la seule règle d'affichage qui compte ici. Montrer le résultat
    /// médian pendant la mesure serait plus « juste » et beaucoup moins utile :
    /// il ne bougerait pas pendant la première seconde, puis à peine — un
    /// compteur immobile ressemble à un compteur en panne.
    private var dialCaption: String {
        if controller.phase.isRunning {
            return SpeedFormat.megabytes(controller.live)
        }
        return SpeedFormat.megabytes(resultRate)
    }

    private var footerRate: Double? {
        controller.phase.isRunning ? controller.live : resultRate
    }

    /// **La descente, toujours.** C'est le chiffre qu'on est venu chercher, et
    /// le cadran n'en porte qu'un. La montée a sa place dans le menu, où il y a
    /// de quoi la nommer au lieu de la laisser deviner.
    private var resultRate: Double? { controller.reading.download }

    private var symbol: String {
        switch controller.phase {
        case .idle, .done: "gauge.with.dots.needle.bottom.50percent"
        case .sounding: "dot.radiowaves.left.and.right"
        case .downloading: "arrow.down.circle.fill"
        case .uploading: "arrow.up.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch controller.phase {
        case .failed: Palette.broken
        case .done: Palette.done
        default: .accentColor
        }
    }

    private var accessibilitySummary: String {
        switch controller.phase {
        case .failed(let reason): "Test de débit — \(reason)"
        case .sounding, .downloading, .uploading:
            "Test de débit en cours — \(SpeedFormat.megabytesSigned(controller.live))"
        case .idle, .done:
            "Débit — \(SpeedFormat.megabytesSigned(controller.reading.download)) en descente"
        }
    }
}
