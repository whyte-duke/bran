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

        // **Un second élément, et pas une ligne de plus dans le premier.**
        //
        // Le libellé de l'élément bran porte déjà le chrono pendant un
        // enregistrement et « à l'écoute » pendant une dictée : les deux moments
        // où la consommation monte sont donc exactement les deux moments où le
        // chiffre disparaîtrait. iStat Menus et Stats, les deux références du
        // genre, séparent pour la même raison.
        //
        // `isInserted` plutôt qu'un `if` : c'est la façon dont SwiftUI retire
        // proprement un élément de la barre de menus, sans reconstruire la scène.
        MenuBarExtra(isInserted: Binding(
            get: { model.meter.showsInMenuBar },
            set: { model.meter.showsInMenuBar = $0 }
        )) {
            ResourceMenu(meter: model.meter)
        } label: {
            // `monospacedDigit` ici, et un remplissage en U+2007 dans la chaîne
            // elle-même : le modificateur de police n'est pas toujours honoré
            // sur un élément de barre de menus, le contenu de la chaîne l'est
            // toujours. Voir `ResourceFormat.menuBarLabel`.
            Label {
                Text(model.meter.label).monospacedDigit()
            } icon: {
                Image(systemName: "speedometer")
            }
        }

        Window("bran", id: "library") {
            LibraryView(model: model)
        }
        .defaultSize(width: 1080, height: 700)
        // Une app dont le seul point d'entrée est une icône de barre de menus
        // n'a pas de premier lancement utilisable si cette icône est masquée.
        .defaultLaunchBehavior(.presented)
        .commands { branCommands }

        // « Bienvenue » et non « autorisations » : l'écran dit ce que bran sait
        // faire, et les autorisations n'y sont qu'une conséquence.
        Window("bran — bienvenue", id: "permissions") {
            PermissionsView(model: model)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 520, height: 520)
        .defaultLaunchBehavior(.suppressed)
    }

    /// Les raccourcis de la fenêtre.
    ///
    /// L'application n'en déclarait aucun : ⌘, ne faisait rien, et le menu
    /// « bran » ne proposait pas les réglages — pourtant ouverts depuis trois
    /// endroits de l'interface.
    ///
    /// Les réglages restent la feuille existante plutôt qu'une scène `Settings`
    /// séparée : `SettingsPane` est dimensionnée et refermée comme une feuille,
    /// et deux présentations différentes du même écran selon la porte d'entrée
    /// se remarqueraient tout de suite.
    @CommandsBuilder
    private var branCommands: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Réglages…") { model.showsSettings = true }
                .keyboardShortcut(",", modifiers: .command)
        }

        CommandGroup(after: .toolbar) {
            Button("Actualiser") {
                Task {
                    await model.store.reload()
                    await model.directory.refresh()
                }
            }
            .keyboardShortcut("r", modifiers: .command)

            Button("Rechercher") { NotificationCenter.default.post(name: .branFocusSearch, object: nil) }
                .keyboardShortcut("f", modifiers: .command)
        }
    }
}

extension Notification.Name {
    /// ⌘F. Le champ de recherche est écrit à la main et vit au milieu du
    /// contenu ; aucune commande de menu ne peut atteindre son `@FocusState`
    /// autrement. Une seule section est construite à la fois, donc un seul
    /// champ écoute.
    static let branFocusSearch = Notification.Name("bran.focusSearch")
}
