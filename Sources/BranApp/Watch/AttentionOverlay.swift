import AppKit
import BranWatch
import SwiftUI

/// **Le routeur d'attention** : une pilule au-dessus de tout, qui dit la seule
/// voie qu'il faut reprendre maintenant.
///
/// ```
///   ──────────── barre de menus ────────────
///                        ╭──────────────────────────╮
///                        │ 🔔 crm · feat/api  19 min │
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
@MainActor
final class AttentionOverlay {

    private var panel: NSPanel?
    private var hosting: NSHostingView<AttentionPill>?
    private let content = AttentionContent()

    /// Ce qui doit faire taire le panneau sans qu'il ait à savoir pourquoi :
    /// une dictée ou une capture en cours, c'est-à-dire l'encoche déployée.
    private let isSuppressed: @MainActor () -> Bool

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
            return
        }

        let view = AttentionPill(content: content)
        let hostingView = NSHostingView(rootView: view)
        let newPanel = NSPanel(
            contentRect: NSRect(origin: origin, size: size),
            // `.nonactivatingPanel` : signaler qu'une machine attend ne doit pas
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
        content.isVisible = true
    }

    func hide() {
        guard content.isVisible else { return }
        content.isVisible = false
        panel?.orderOut(nil)
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
        hosting = nil
    }
}

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
}

struct AttentionPill: View {
    @Bindable var content: AttentionContent

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "bell.badge.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.orange)

            Text(content.name)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)

            Text(content.detail)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial, in: .capsule)
        .overlay {
            Capsule().stroke(.white.opacity(0.12), lineWidth: 1)
        }
        .opacity(content.isVisible ? 1 : 0)
        .scaleEffect(content.isVisible ? 1 : 0.94, anchor: .top)
        .animation(.snappy(duration: 0.24), value: content.isVisible)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}
