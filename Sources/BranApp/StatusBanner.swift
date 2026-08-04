import SwiftUI

/// « Est-ce que ça tourne, et depuis combien de temps. »
///
/// C'est la question la plus fréquente et la seule à laquelle l'icône de barre
/// de menus répond mal. Le bandeau la traite en toutes lettres.
struct StatusBanner: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(indicatorColor)
                .frame(width: 9, height: 9)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(headline)
                    .font(.subheadline.weight(.medium))
                    .monospacedDigit()
                Text(subline)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            action
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(headline). \(subline)")
    }

    @ViewBuilder
    private var action: some View {
        if model.hasOpenSession {
            Button("Arrêter") { model.stopRecording() }
                .buttonStyle(.borderedProminent)
                .tint(.red)
        } else if model.pendingMeeting != nil {
            Button("Enregistrer") { model.startPendingRecording() }
                .buttonStyle(.borderedProminent)
        } else {
            Button("Démarrer") { model.startManualRecording() }
                .disabled(model.permissions.canRecord == false)
        }
    }

    private var headline: String {
        switch model.engine.state {
        case .recording: "Enregistrement · \(model.elapsedDescription)"
        case .paused: "En pause · \(model.elapsedDescription)"
        case .starting: "Démarrage…"
        case .finalizing: "Finalisation du fichier"
        case .failed: "Échec"
        case .idle: model.pendingMeeting != nil ? "Réunion détectée" : "En veille"
        }
    }

    private var subline: String {
        if let failure = model.lastFailure { return failure }

        return switch model.engine.state {
        case .paused:
            "Le segment est fermé. La reprise ouvrira un nouveau morceau."
        case .recording, .starting, .finalizing:
            model.pendingMeeting?.title ?? "Écran entier · \(model.quality.estimatedRate)"
        case .failed:
            "Aucun enregistrement en cours."
        case .idle:
            model.pendingMeeting != nil
                ? "Rien n'est enregistré tant que vous ne l'avez pas demandé."
                : "bran surveille les fenêtres Meet en permanence."
        }
    }

    private var indicatorColor: Color {
        switch model.engine.state {
        case .recording, .starting: .red
        case .paused: .orange
        case .finalizing: .orange
        case .failed: .yellow
        case .idle: model.pendingMeeting != nil ? .blue : .secondary
        }
    }
}
