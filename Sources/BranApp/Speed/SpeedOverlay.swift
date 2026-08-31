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
    private let controller: SpeedController

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

        let hosting = NSHostingView(rootView: SpeedPanel(controller: controller))
        panel = OverlayPanel.make(
            frame: NSRect(origin: origin, size: size),
            content: hosting,
            // **Transparent aux clics, comme l'encoche.** Le panneau n'a aucun
            // contrôle : il affiche une mesure qui dure neuf secondes et se
            // referme seule. Intercepter un clic destiné à la fenêtre du dessous
            // — celle où l'on travaillait pendant que ça mesurait — serait un
            // défaut pur, et c'est exactement l'arbitrage que le paramètre de
            // `OverlayPanel.make` existe pour rendre visible.
            acceptsMouse: false
        )
    }

    private func hide() {
        panel?.orderOut(nil)
        panel = nil
    }

    enum Metric {
        static let width: CGFloat = 236
        static let height: CGFloat = 178
    }
}

/// Ce que le panneau montre. Il observe le contrôleur directement : celui-ci est
/// `@Observable`, donc il n'y a pas de raison d'interposer un objet de contenu
/// comme le font l'encoche et la pilule — les deux le font parce que leur
/// contrôleur, lui, n'est pas observable.
private struct SpeedPanel: View {
    let controller: SpeedController

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
        .branAnimation(Motion.enter, value: controller.phase)
        // Le panneau reste hors de la hiérarchie d'accessibilité — il ne se
        // clique pas — mais ces attributs sont ce que lira quiconque
        // l'atteindra, et ils coûtent trois lignes.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
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
        }
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
