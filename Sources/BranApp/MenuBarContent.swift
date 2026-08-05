import BranCore
import SwiftUI

struct MenuBarContent: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let next = model.directory.next, model.hasOpenSession == false {
            Text("Prochain RDV — \(next.displayName)")
            if let link = next.meeting_url, let url = URL(string: link) {
                Link("Rejoindre la visio", destination: url)
            }
            Divider()
        }

        Button("Ouvrir bran…", systemImage: "macwindow") {
            WindowPresenter.bringToFront("library", using: openWindow)
        }
        .keyboardShortcut("o")

        Divider()

        dictationItems

        Divider()

        Text(model.statusSummary)

        if let failure = model.lastFailure {
            Text("⚠︎ \(failure)")
            Button("Ignorer cet avertissement") { model.lastFailure = nil }
        }

        Divider()

        if model.hasOpenSession {
            Button(model.isPaused ? "Reprendre l'enregistrement" : "Mettre en pause") {
                model.togglePause()
            }
            .keyboardShortcut("p")

            Button("Arrêter et enregistrer le fichier") {
                model.stopRecording()
            }
            .keyboardShortcut("s")
        } else if let meeting = model.pendingMeeting {
            Button("Démarrer — \(meeting.title ?? "réunion non reconnue")") {
                model.startPendingRecording()
            }
            .keyboardShortcut("r")

            Button("Pas cette fois") {
                model.dismissProposal()
            }
        } else {
            Button("Démarrer un enregistrement") {
                model.startManualRecording()
            }
            .keyboardShortcut("r")
            .disabled(model.permissions.canRecord == false)
        }

        Divider()

        if model.permissions.canRecord == false {
            Button("Autorisations…") {
                WindowPresenter.bringToFront("permissions", using: openWindow)
            }
        }

        Divider()

        Button("Quitter bran") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    /// La dictée dans le menu. Deux lignes seulement : l'état, et le geste.
    /// C'est aussi le seul endroit où l'on peut la relancer si le raccourci
    /// global ne répond pas — un filet de sécurité qui coûte trois lignes.
    @ViewBuilder
    private var dictationItems: some View {
        if model.dictationSettings.isEnabled {
            switch model.dictation.phase {
            case .capturing:
                Button("Arrêter la dictée") { model.dictation.toggleFromUI() }
                Button("Annuler la dictée") { model.dictation.cancel() }
            case .transcribing:
                Text("Transcription en cours…")
            case .failed(let reason):
                Text("⚠︎ \(reason.summary)")
                Button("Compris") { model.dictation.acknowledgeFailure() }
            case .idle, .pasting:
                Button("Dicter — \(model.dictationSettings.trigger.displayName)") {
                    model.dictation.toggleFromUI()
                }
            }
        } else {
            Button("Activer la dictée…") {
                WindowPresenter.bringToFront("library", using: openWindow)
            }
        }
    }
}

extension AppModel {
    /// L'icône doit dire d'un coup d'œil si on enregistre. C'est le seul retour
    /// visuel permanent tant que l'overlay n'existe pas.
    var menuBarSymbol: String {
        // La dictée passe devant : elle dure quelques secondes, l'enregistrement
        // dure une heure. C'est l'événement court qui a besoin d'un retour
        // immédiat — surtout sur un écran sans encoche, où le panneau tombe en
        // pilule flottante qu'on peut manquer.
        switch dictation.phase {
        case .capturing: return "waveform.circle.fill"
        case .transcribing: return "hourglass"
        case .idle, .pasting, .failed: break
        }

        return switch engine.state {
        case .recording, .finalizing: "record.circle.fill"
        case .paused: "pause.circle.fill"
        case .starting: "record.circle"
        case .failed: "exclamationmark.triangle.fill"
        case .idle: pendingMeeting != nil ? "bell.badge" : "eye"
        }
    }

    /// Court, mais présent : c'est ce qui rend l'élément repérable dans une
    /// barre de menus chargée — et pendant l'enregistrement, la durée est
    /// l'information qu'on cherche.
    var menuBarTitle: String {
        switch dictation.phase {
        case .capturing: return "à l'écoute"
        case .transcribing: return "…"
        case .idle, .pasting, .failed: break
        }

        return switch engine.state {
        case .recording: elapsedDescription
        case .paused: "‖ \(elapsedDescription)"
        case .starting, .finalizing: "…"
        case .failed: "bran ⚠︎"
        case .idle: pendingMeeting != nil ? "Meet ?" : "bran"
        }
    }
}
