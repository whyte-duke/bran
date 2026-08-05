import SwiftUI

@main
struct BranApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(model: model)
        } label: {
            // Icône ET texte. Une icône seule de 16 points dans une barre de
            // menus chargée est introuvable, et sur un écran à encoche elle
            // peut passer dessous — invisible et non cliquable.
            Label(model.menuBarTitle, systemImage: model.menuBarSymbol)
        }

        Window("bran", id: "library") {
            LibraryView(model: model)
        }
        .defaultSize(width: 1080, height: 700)
        // Une app dont le seul point d'entrée est une icône de barre de menus
        // n'a pas de premier lancement utilisable si cette icône est masquée.
        .defaultLaunchBehavior(.presented)

        Window("bran — autorisations", id: "permissions") {
            PermissionsView(model: model)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 460, height: 460)
        .defaultLaunchBehavior(.suppressed)
    }
}
