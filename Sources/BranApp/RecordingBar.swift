import SwiftUI

/// Barre de session, visible en bas de la fenêtre **uniquement** pendant qu'un
/// enregistrement tourne.
///
/// Elle transforme la bibliothèque en poste de pilotage sans changer d'écran :
/// tant qu'on enregistre, la seule chose qu'on veut faire est nommer la session
/// et savoir quand l'arrêter.
struct RecordingBar: View {
    @Bindable var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPulsing = false
    @FocusState private var isTitleFocused: Bool

    var body: some View {
        HStack(spacing: 14) {
            indicator

            VStack(alignment: .leading, spacing: 1) {
                Text(model.elapsedDescription)
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())

                Text(model.isPaused ? "En pause · \(sizeLine)" : sizeLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .frame(minWidth: 130, alignment: .leading)

            Divider().frame(height: 30)

            titleField

            Spacer(minLength: 12)

            Button(
                model.isPaused ? "Reprendre" : "Pause",
                systemImage: model.isPaused ? "play.fill" : "pause.fill"
            ) {
                model.togglePause()
            }
            .controlSize(.large)
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .help(model.isPaused
                ? "Ouvre un nouveau morceau, recollé au précédent à l'arrêt."
                : "Ferme le morceau en cours. Rien n'est enregistré pendant la pause.")

            Button("Arrêter", systemImage: "stop.fill") {
                isTitleFocused = false
                model.stopRecording()
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)
            .keyboardShortcut("s", modifiers: [.command, .shift])
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .onAppear { isPulsing = reduceMotion == false }
    }

    private var indicator: some View {
        Circle()
            .fill(model.isPaused ? .orange : .red)
            .frame(width: 12, height: 12)
            // Le clignotement s'arrête en pause : une pastille fixe dit
            // « rien ne se passe » sans un mot.
            .opacity(isPulsing && model.isPaused == false ? 0.35 : 1)
            // Le clignotement dit « c'est en direct » mieux qu'un mot. Il est
            // désactivé si l'utilisateur a demandé moins d'animations : une
            // pastille rouge fixe transmet la même chose.
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 1).repeatForever(autoreverses: true),
                value: isPulsing
            )
            .accessibilityHidden(true)
    }

    private var titleField: some View {
        HStack(spacing: 6) {
            Image(systemName: "pencil")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField("Nommer cette réunion…", text: $model.currentTitle)
                .textFieldStyle(.plain)
                .font(.body)
                .focused($isTitleFocused)
                .onSubmit { isTitleFocused = false }
                .accessibilityLabel("Titre de l'enregistrement en cours")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
        .frame(maxWidth: 340)
    }

    private var sizeLine: String {
        let size = model.currentFileSize.formatted(.byteCount(style: .file))
        return model.currentFileSize > 0
            ? "\(size) · \(model.quality.estimatedRate)"
            : "démarrage de l'écriture…"
    }
}
