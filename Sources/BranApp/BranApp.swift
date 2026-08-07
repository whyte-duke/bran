import SwiftUI

@main
struct BranApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        // **Un seul élément de barre de menus, et c'est un choix qui a été
        // repris.**
        //
        // bran en a porté deux : le sien, et un compteur de consommation séparé.
        // L'argument tenait — le libellé de bran porte le chrono pendant un
        // enregistrement, donc le chiffre aurait disparu au moment où il monte —
        // mais il faisait payer deux icônes en permanence pour une information
        // consultée une fois par semaine, dans une barre de menus qui en compte
        // déjà quinze. Tout est désormais sous une seule icône : la
        // consommation est dans le menu, et dans le libellé chaque fois que rien
        // d'autre ne s'y montre. Voir `AppModel.menuBarTitle` pour l'arbitrage,
        // et `ResourceLines` pour ce que ça coûte.
        MenuBarExtra {
            MenuBarContent(model: model)
        } label: {
            // Icône ET texte. Une icône seule de 16 points dans une barre de
            // menus chargée est introuvable, et sur un écran à encoche elle
            // peut passer dessous — invisible et non cliquable.
            //
            // `monospacedDigit` parce que ce texte porte maintenant des chiffres
            // dans trois cas sur cinq — chrono, décompte d'éveil, consommation.
            // Le remplissage en U+2007 de `ResourceFormat` reste nécessaire : le
            // modificateur de police n'est pas toujours honoré sur un élément de
            // barre de menus, le contenu de la chaîne l'est toujours.
            Label {
                Text(model.menuBarTitle).monospacedDigit()
            } icon: {
                Image(systemName: model.menuBarSymbol)
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
