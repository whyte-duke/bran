import BranCore
import SwiftUI

/// Barre de session, visible en bas de la fenêtre pendant qu'un enregistrement
/// tourne **et pendant tout ce qui le suit**.
///
/// Elle transforme la bibliothèque en poste de pilotage sans changer d'écran :
/// tant qu'on enregistre, la seule chose qu'on veut faire est nommer la session
/// et savoir quand l'arrêter.
///
/// **Ce qu'elle ne faisait pas, et qui était le défaut.** Elle disparaissait à
/// l'instant où la machine repassait au repos, c'est-à-dire juste avant que la
/// finalisation, la fusion et l'extraction audio commencent. Sur une réunion de
/// trente-six minutes, ça fait plusieurs dizaines de minutes pendant lesquelles
/// bran travaille et l'écran ne montre rien — donc plusieurs dizaines de minutes
/// pendant lesquelles fermer l'application paraît sans conséquence. Elle reste
/// désormais montée tant que `AppModel.showsSessionBar` est vrai, et elle affiche
/// à chaque instant laquelle des trois étapes tourne.
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
        Group {
            if isPilotable {
                controls
            } else if let step = step {
                stageView(step)
            }
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

    // MARK: - Lequel des deux visages

    /// Y a-t-il encore quelque chose **à décider** ?
    ///
    /// C'est le seul arbitre entre les deux visages de la barre, et il est posé
    /// dans ce sens-là — « pilotable », et non « en train de traiter » — parce
    /// que les deux états peuvent être vrais en même temps. Une compression de
    /// vingt minutes n'empêche pas de démarrer la réunion suivante : quand cela
    /// arrive, ce sont les commandes qui gagnent, parce qu'une session ouverte
    /// qu'on ne peut plus arrêter est un défaut bien plus grave qu'une étape de
    /// fond qu'on ne voit pas. L'étape, elle, continue de se dire dans le menu et
    /// sur la ligne de bibliothèque concernée.
    ///
    /// `.starting` compte comme pilotable — c'était déjà le cas — parce qu'une
    /// session qui démarre doit pouvoir être arrêtée ; `.finalizing`, non : la
    /// capture est finie, les deux boutons ne sont plus acceptés par la machine,
    /// et les offrir quand même laisse croire que le premier clic sur « Arrêter »
    /// n'a pas été pris.
    private var isPilotable: Bool {
        model.hasOpenSession && model.isFinalizing == false
    }

    /// L'étape à peindre quand il n'y a plus rien à piloter.
    ///
    /// `model.currentStep` est la source. Le repli fabriqué ici ne couvre qu'un
    /// cas, et il est court : la machine est déjà passée en `.finalizing` et la
    /// chaîne n'a pas encore publié sa première étape. Sans lui, la barre se
    /// réduirait pendant ces quelques images à un liseré vide — un défaut plus
    /// visible que le titre approximatif qu'on affiche à la place, et qui n'est
    /// même pas approximatif : à cet instant, bran finalise bel et bien.
    ///
    /// Quand les deux sont nuls, ce corps ne rend rien du tout ; c'est un état
    /// que `showsSessionBar` ne laisse pas arriver, puisqu'il vaut
    /// `hasOpenSession || currentStep != nil`.
    private var step: SessionProgress? {
        if let published = model.currentStep { return published }
        guard model.isFinalizing else { return nil }
        return SessionProgress(
            stage: .finalizing,
            bytesWritten: model.currentFileSize,
            recorded: model.elapsed
        )
    }

    // MARK: - La chaîne de fin

    /// Ce que voit l'utilisateur entre le clic sur « Arrêter » et le fichier
    /// utilisable — pour les **trois** travaux, et plus seulement pour le
    /// premier.
    ///
    /// Il n'y a aucun bouton parce qu'il n'y a plus rien à décider : seulement à
    /// attendre, et à savoir que l'attente est normale, laquelle des trois étapes
    /// la cause, et combien de temps elle dure.
    ///
    /// **Le nom de la réunion est affiché, et ce n'est pas du décor.** La fenêtre
    /// peut être restée ouverte deux heures et trois réunions ; « Fusion et
    /// compression de la vidéo… » tout seul ne dit pas laquelle, donc ne dit pas
    /// si c'est celle qu'on attend pour l'envoyer au CRM.
    private func stageView(_ step: SessionProgress) -> some View {
        HStack(spacing: Space.stack) {
            // Une roue **seulement quand rien ne se mesure**. Une roue qui tourne
            // et une jauge qui avance disent la même chose deux fois ; quand la
            // jauge existe, c'est elle qui porte le mouvement, et elle le porte
            // mieux puisqu'elle dit aussi où on en est.
            if step.fraction == nil {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: Space.line) {
                if let title = model.currentStepTitle {
                    Text(title)
                        .font(Type.meta)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Text(step.title)
                    .font(Type.groupHead)

                Text(step.detail)
                    .font(Type.meta)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                if let fraction = step.fraction {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .frame(width: Size.stageProgress)
                        .padding(.top, Space.tight)
                        // La compression rapporte par sauts irréguliers — deux
                        // pour cent d'un coup, puis rien pendant six secondes.
                        // Animer le trajet rend l'avancement lisible sans rien
                        // inventer : la valeur d'arrivée reste celle qui a été
                        // mesurée.
                        .branAnimation(Motion.state, value: fraction)
                        .accessibilityHidden(true)
                }
            }

            Spacer(minLength: Space.inset)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenStage(step))
    }

    /// L'étape et son avancement, dits dans l'ordre où on les cherche : ce qui se
    /// passe, sur quelle réunion, et où ça en est.
    ///
    /// Les libellés viennent de `SessionProgress`, comme ceux de l'écran : deux
    /// formulations d'un même état — l'une pour les yeux, l'autre pour VoiceOver
    /// — divergent au premier changement de texte, et c'est toujours la seconde
    /// qui reste en arrière parce que personne ne l'entend.
    private func spokenStage(_ step: SessionProgress) -> String {
        var spoken = step.title
        if let title = model.currentStepTitle { spoken += " Réunion \(title)." }
        return "\(spoken) \(step.detail)"
    }

    // MARK: - Le pilotage

    private var controls: some View {
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
            .frame(minWidth: Size.timerColumn, alignment: .leading)

            Divider().frame(height: Size.barDivider)

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
            .frame(width: Size.liveDot, height: Size.liveDot)
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
                .font(Type.input)
                .focused($isTitleFocused)
                .onSubmit { isTitleFocused = false }
                .accessibilityLabel("Titre de l'enregistrement en cours")
        }
        .padding(.horizontal, Space.inset)
        .padding(.vertical, Space.small)
        .background(Palette.well, in: .rect(cornerRadius: Radius.field))
        .frame(maxWidth: Size.sessionTitleField)
    }

    private var sizeLine: String {
        let size = model.currentFileSize.formatted(.byteCount(style: .file))
        return model.currentFileSize > 0
            ? "\(size) · \(model.quality.estimatedRate)"
            : "démarrage de l'écriture…"
    }
}
