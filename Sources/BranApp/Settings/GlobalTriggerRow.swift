import AppKit
import BranSpeech
import SwiftUI

/// La ligne « Raccourci » d'une fonction, avec tout ce que le conflit implique.
///
/// **Une seule vue pour toutes les fonctions.** La dictée et la capture de texte
/// avaient chacune leur ligne, et elles ne faisaient pas la même chose : celle
/// de la capture refusait un raccourci déjà pris et proposait l'échange, celle
/// de la dictée écrivait sans rien vérifier. La moitié du travail était donc
/// dupliquée, et l'autre moitié simplement absente d'un côté. Réunir les deux
/// n'a pas seulement supprimé la répétition : ça a corrigé la dictée.
///
/// La vue ne connaît aucune fonction par son nom — elle reçoit un
/// `GlobalTrigger` et demande le reste à `GlobalTriggerRegistry`.
struct GlobalTriggerRow: View {

    @Bindable var model: AppModel
    let trigger: GlobalTrigger

    @State private var isCapturing = false
    /// Le raccourci qu'on vient de refuser parce qu'il est déjà pris.
    @State private var refused: HotkeyBinding?

    private var current: HotkeyBinding { GlobalTriggerRegistry.binding(trigger, in: model) }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.small) {
            HStack {
                Text("Raccourci")
                Spacer()
                HotkeyField(
                    binding: Binding(
                        get: { current },
                        set: { assign($0) }
                    ),
                    isCapturing: $isCapturing
                )
            }

            // **Le conflit est refusé, pas seulement signalé.** L'ancienne
            // version affichait l'avertissement et enregistrait quand même :
            // les deux fonctions se retrouvaient sur la même touche, et
            // `ShortcutRouter` en arbitrait une en silence. L'utilisateur
            // voyait l'autre fonction « ne plus marcher » sans rien pour
            // l'expliquer.
            if let refused, let holder = holder(of: refused) {
                VStack(alignment: .leading, spacing: Space.small) {
                    Label(
                        "\(refused.displayName) est déjà le raccourci \(holder.possessiveName). Les deux fonctions ne peuvent pas le partager : le système n'en préviendrait qu'une seule, toujours la même.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(Type.meta)
                    .foregroundStyle(Palette.attention)
                    .fixedSize(horizontal: false, vertical: true)

                    HStack {
                        Button("Échanger avec \(holder.definiteName)") { exchange(with: refused) }
                        Button("Garder \(current.displayName)") { self.refused = nil }
                    }
                    .controlSize(.small)
                }
            } else if let holder = holder(of: current) {
                // Le conflit qui n'est pas passé par cet écran : chaque réglage
                // est persisté de son côté, et une installation antérieure à
                // cette vérification peut les avoir déjà alignés.
                Label(
                    "Cette touche est déjà celle \(holder.possessiveName). Les deux fonctions ne peuvent pas partager un raccourci.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(Type.meta)
                .foregroundStyle(Palette.attention)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: -

    private func holder(of binding: HotkeyBinding) -> GlobalTrigger? {
        GlobalTriggerRegistry.holder(of: binding, excluding: trigger, in: model)
    }

    /// Enregistre le raccourci, ou le refuse s'il est déjà pris.
    private func assign(_ newValue: HotkeyBinding) {
        guard holder(of: newValue) == nil else {
            refused = newValue
            return
        }
        refused = nil
        GlobalTriggerRegistry.assign(newValue, to: trigger, in: model)
    }

    /// L'échange, parce que c'est presque toujours ce qu'on voulait.
    ///
    /// Vouloir ⌘⇧2 pour la capture alors que la dictée l'occupe veut dire qu'on
    /// préfère l'autre touche pour la dictée — pas qu'on renonce.
    private func exchange(with wanted: HotkeyBinding) {
        GlobalTriggerRegistry.exchange(trigger, to: wanted, in: model)
        refused = nil
    }
}

/// Le champ de saisie d'un raccourci global.
///
/// Écoute localement les `flagsChanged` et les `keyDown` : pas besoin de tap ni
/// d'autorisation pour lire ce qui arrive à notre propre fenêtre.
///
/// Partagé par toutes les fonctions via `GlobalTriggerRow` : deux
/// implémentations divergeraient sur les touches refusées, et l'une des deux
/// finirait par laisser passer Entrée.
struct HotkeyField: View {
    @Binding var binding: HotkeyBinding
    @Binding var isCapturing: Bool

    @State private var monitor: Any?

    var body: some View {
        Button {
            isCapturing.toggle()
            isCapturing ? startListening() : stopListening()
        } label: {
            Text(isCapturing ? "Appuyez sur une touche…" : binding.displayName)
                .font(Type.code)
                // TODO(design) : pas d'échelle de largeurs de composant. Cette
                // largeur plancher empêche le bouton de sauter entre « ⌘⇧2 » et
                // « Appuyez sur une touche… » ; elle est mesurée sur le texte.
                .frame(minWidth: 130)
        }
        .buttonStyle(.bordered)
        .tint(isCapturing ? .accentColor : nil)
        .onDisappear(perform: stopListening)
    }

    private func startListening() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            let captured = Self.interpret(event)
            guard let captured, captured.isAcceptableAsTrigger else { return nil }
            binding = captured
            isCapturing = false
            stopListening()
            return nil
        }
    }

    private func stopListening() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private static func interpret(_ event: NSEvent) -> HotkeyBinding? {
        if event.type == .flagsChanged {
            // Un `flagsChanged` où plus aucun modificateur n'est actif est un
            // relâchement : on l'ignore, sinon relâcher la touche l'écraserait
            // par elle-même.
            guard event.modifierFlags.rawValue & Self.significant != 0 else { return nil }
            return HotkeyBinding(keyCode: event.keyCode, isModifierOnly: true)
        }

        return HotkeyBinding(
            keyCode: event.keyCode,
            modifiers: UInt64(event.modifierFlags.rawValue) & Self.significantCG,
            isModifierOnly: false
        )
    }

    private static let significant = NSEvent.ModifierFlags([.command, .option, .control, .shift]).rawValue
    private static let significantCG: UInt64 = 0x1E_0000
}
