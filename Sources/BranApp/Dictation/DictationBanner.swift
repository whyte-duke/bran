import BranSpeech
import SwiftUI

/// L'état de la dictée, en tête de la colonne.
///
/// Répond à la seule question qui compte avant d'appuyer sur la touche : est-ce
/// que ça écoute, oui ou non — et si non, pourquoi. Un raccourci global qui ne
/// répond pas est indiscernable d'une application plantée ; c'est là qu'on le
/// dit.
struct DictationBanner: View {
    @Bindable var model: AppModel

    private var controller: DictationController { model.dictation }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.callout.weight(.medium))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 6)

                action
            }

            if let notice = controller.pasteFallbackNotice {
                Label(notice, systemImage: "doc.on.clipboard")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if isSecureInputBlocking {
                Label(
                    "Saisie sécurisée active : macOS bloque tout raccourci global tant qu'un champ de mot de passe a le focus.",
                    systemImage: "lock.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }

    /// Vrai seulement quand ça nous concerne : la saisie sécurisée est normale
    /// et fréquente, il ne faut pas l'annoncer en permanence.
    private var isSecureInputBlocking: Bool {
        controller.settings.isEnabled && HotkeyMonitor.isSecureInputActive
    }

    // MARK: -

    private var symbol: String {
        switch controller.phase {
        case .capturing: "waveform.circle.fill"
        case .transcribing: "hourglass"
        case .pasting: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .idle: controller.settings.isEnabled ? "keyboard.badge.ellipsis" : "keyboard"
        }
    }

    private var tint: Color {
        switch controller.phase {
        case .capturing: .red
        case .pasting: .green
        case .failed: .orange
        case .transcribing, .idle: .secondary
        }
    }

    private var title: String {
        switch controller.phase {
        case .capturing: "À l'écoute…"
        case .transcribing: "Transcription en cours"
        case .pasting: "Texte collé"
        case .failed(let reason): reason.summary
        case .idle: controller.settings.isEnabled ? "En attente du raccourci" : "Dictée désactivée"
        }
    }

    private var subtitle: String {
        switch controller.phase {
        case .capturing:
            controller.settings.triggerMode == .hold
                ? "Relâchez pour transcrire · \(controller.settings.cancelKey.displayName) pour annuler"
                : "\(controller.settings.trigger.displayName) pour arrêter · \(controller.settings.cancelKey.displayName) pour annuler"
        case .transcribing:
            "Le modèle travaille sur votre Mac. Rien ne part sur Internet."
        case .pasting:
            "Le texte est aussi dans le presse-papiers."
        case .failed(let reason):
            reason.remedy
        case .idle:
            controller.settings.isEnabled
                ? "\(controller.settings.trigger.displayName) n'importe où · \(controller.host.availability.description)"
                : "Activez-la dans les réglages pour dicter dans n'importe quelle application."
        }
    }

    @ViewBuilder
    private var action: some View {
        switch controller.phase {
        case .capturing:
            Button("Arrêter") { controller.toggleFromUI() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        case .failed:
            Button("Compris") { controller.acknowledgeFailure() }
                .controlSize(.small)
        case .idle where controller.settings.isEnabled:
            Button("Dicter") { controller.toggleFromUI() }
                .controlSize(.small)
        default:
            EmptyView()
        }
    }
}
