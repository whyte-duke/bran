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

    /// L'instant depuis lequel le chrono système compte.
    ///
    /// Recalé à chaque reprise plutôt que fixé une fois : `AppModel` déduit le
    /// temps passé en pause de la durée affichée, et un chrono parti de
    /// `recordingStartedAt` compterait donc les pauses en trop.
    @State private var timerStart = Date.now

    /// Le clignotement, en une seule valeur.
    ///
    /// Elle sert **à la fois** d'opacité et de déclencheur d'animation. Quand
    /// les deux divergeaient, la mise en pause changeait l'opacité hors du champ
    /// du `value:` : l'animation en boucle était remplacée par une affectation
    /// sèche et la pastille restait figée à 35 % — elle se lisait « en pause »
    /// alors que l'enregistrement tournait.
    private var shouldPulse: Bool { isPulsing && model.isPaused == false }

    var body: some View {
        HStack(spacing: Space.stack) {
            indicator

            VStack(alignment: .leading, spacing: Space.line) {
                elapsedLabel
                    .font(Type.timer)
                    .monospacedDigit()

                Text(model.isPaused ? "En pause · \(sizeLine)" : sizeLine)
                    .font(Type.meta)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .frame(minWidth: 130, alignment: .leading)

            Divider().frame(height: 30)

            titleField

            Spacer(minLength: Space.inset)

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
            .tint(Palette.live)
            .controlSize(.large)
            .keyboardShortcut("s", modifiers: [.command, .shift])
        }
        .padding(.horizontal, Space.stack)
        .padding(.vertical, Space.inset)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .onAppear {
            isPulsing = reduceMotion == false
            recalibrateTimer()
        }
        .onChange(of: model.isPaused) { recalibrateTimer() }
    }

    /// Le chrono.
    ///
    /// Pendant l'enregistrement, c'est le système qui compte : `contentTransition`
    /// ne jouait jamais sur la valeur écrite chaque seconde hors transaction
    /// animée, et cette lecture réveillait toute la barre à chaque tic.
    /// En pause rien n'avance : la valeur figée du modèle suffit, et elle est
    /// plus lisible qu'un chrono arrêté.
    @ViewBuilder
    private var elapsedLabel: some View {
        if model.isPaused {
            Text(model.elapsedDescription)
        } else {
            Text(timerInterval: timerStart...Date.distantFuture, countsDown: false)
        }
    }

    private func recalibrateTimer() {
        timerStart = Date.now.addingTimeInterval(-Double(model.elapsed.components.seconds))
    }

    private var indicator: some View {
        Circle()
            .fill(model.isPaused ? Palette.held : Palette.live)
            .frame(width: 12, height: 12)
            // Le clignotement s'arrête en pause : une pastille fixe dit
            // « rien ne se passe » sans un mot.
            .opacity(shouldPulse ? 0.35 : 1)
            // Le clignotement dit « c'est en direct » mieux qu'un mot. Il est
            // désactivé si l'utilisateur a demandé moins d'animations : une
            // pastille rouge fixe transmet la même chose.
            //
            // La boucle n'est posée que pendant qu'elle doit tourner : la garder
            // à l'arrêt ferait osciller la pastille de pause entre les deux
            // opacités, indéfiniment.
            .animation(pulseAnimation, value: shouldPulse)
            .accessibilityHidden(true)
    }

    private var pulseAnimation: Animation? {
        guard reduceMotion == false else { return nil }
        return shouldPulse ? Motion.breathe : Motion.hover
    }

    private var titleField: some View {
        HStack(spacing: Space.small) {
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
        .padding(.horizontal, Space.inset)
        .padding(.vertical, Space.small)
        .background(Palette.well, in: .rect(cornerRadius: Radius.field))
        .frame(maxWidth: 340)
    }

    private var sizeLine: String {
        let size = model.currentFileSize.formatted(.byteCount(style: .file))
        return model.currentFileSize > 0
            ? "\(size) · \(model.quality.estimatedRate)"
            : "démarrage de l'écriture…"
    }
}
