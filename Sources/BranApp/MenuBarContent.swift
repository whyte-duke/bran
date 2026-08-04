import BranCore
import SwiftUI

struct MenuBarContent: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Ouvrir bran…", systemImage: "macwindow") {
            WindowPresenter.bringToFront("library", using: openWindow)
        }
        .keyboardShortcut("o")

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
            Button("Démarrer — \(meeting.title ?? "réunion en cours")") {
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
}

extension AppModel {
    /// L'icône doit dire d'un coup d'œil si on enregistre. C'est le seul retour
    /// visuel permanent tant que l'overlay n'existe pas.
    var menuBarSymbol: String {
        switch engine.state {
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
        switch engine.state {
        case .recording: elapsedDescription
        case .paused: "‖ \(elapsedDescription)"
        case .starting, .finalizing: "…"
        case .failed: "bran ⚠︎"
        case .idle: pendingMeeting != nil ? "Meet ?" : "bran"
        }
    }
}
