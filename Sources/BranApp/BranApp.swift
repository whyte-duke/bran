import SwiftUI

/// Le point d'entrée réel, et la seule chose qu'il fait avant SwiftUI.
///
/// **Un type de lancement séparé, parce qu'on ne peut pas doubler `main()` sur
/// une `App`.** Le protocole `App` fournit son propre `main()` statique, qui
/// démarre AppKit et la scène ; le redéclarer dans `BranApp` le masquerait sans
/// laisser aucun moyen d'appeler celui d'origine. Une vingtaine de lignes ici
/// évitent donc de réimplémenter un démarrage SwiftUI à la main.
///
/// Ce qui passe avant l'interface, ce sont **deux** sondes de diagnostic, qui ne
/// s'exécutent que sur un drapeau explicite et sortent sans rien afficher.
///
/// `PasteboardAccessProbe` est là et pas dans `BranSpike` pour une raison qui
/// n'a pas d'échappatoire : ce qu'elle mesure est attaché à l'identité de
/// l'application signée, et un exécutable en ligne de commande hérite de celle
/// du terminal.
///
/// `SpeedProbeReport` y est pour une raison plus faible mais suffisante : elle
/// mesure du réseau, donc elle *pourrait* vivre dans `BranSpike` — mais elle
/// mesurerait alors une copie du code au lieu de celui qui tourne, et c'est
/// exactement la question qu'on lui pose quand un chiffre paraît faux. Elle
/// partage la porte plutôt que le code.
@main
struct BranLaunch {
    static func main() {
        if PasteboardAccessProbe.runIfRequested() { return }
        if SpeedProbeReport.runIfRequested() { return }

        // Les deux sous-commandes de la sauvegarde, et elles ne sont pas des
        // sondes de diagnostic comme les deux au-dessus : ce sont des modes de
        // fonctionnement à part entière.
        //
        // **`--backup-run` est la fonctionnalité, pas un accessoire.** Le
        // rythme d'une sauvegarde ne peut pas dépendre de l'ouverture d'une
        // fenêtre : un minuteur posé dans l'interface annonce « tous les deux
        // jours » et ne s'exécute jamais les jours où l'application n'est pas
        // lancée — c'est le défaut qui a laissé ce Mac sans une seule
        // sauvegarde restaurable pendant des semaines. C'est donc launchd qui
        // appelle ce chemin, sur le même binaire, sans jamais démarrer AppKit.
        //
        // Les deux sortent par `exit()` plutôt que par un `return` : un script
        // et `launchctl` lisent un code de sortie, et `BackupHeadlessRun` en
        // distingue six.
        if BackupProvisioning.runIfRequested() { return }
        if BackupHeadlessRun.runIfRequested() { return }

        BranApp.main()
    }
}

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
                // **Deux constructions, parce qu'un symbole à valeur variable en
                // demande une autre.** Le test de débit est la seule fonction
                // qui s'en serve : ses points s'allument avec le débit pendant
                // les neuf secondes de la mesure. Passer `0` au lieu de choisir
                // ne marcherait pas — un cadran à zéro est une image, l'absence
                // de valeur en est une autre. Voir `menuBarVariableValue`.
                if let fill = model.menuBarVariableValue {
                    Image(systemName: model.menuBarSymbol, variableValue: fill)
                } else {
                    Image(systemName: model.menuBarSymbol)
                }
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
