import Observation
import ServiceManagement

/// Démarrage au login.
///
/// `SMAppService.mainApp` enregistre le bundle lui-même — pas un helper séparé.
///
/// **Ce commentaire disait le contraire de la vérité, et il faut le dire.** Il
/// justifiait le lancement automatique par le fait que bran est un agent
/// `LSUIElement`, « sans fenêtre ni icône du Dock ». Les deux moitiés sont
/// fausses depuis que le Dock a été rendu visible : `Info.plist` déclare
/// désormais `LSUIElement = false`, et `BranApp.swift` pose
/// `.defaultLaunchBehavior(.presented)` sur la fenêtre principale — c'est-à-dire
/// que bran ouvre une fenêtre au lancement, donc aussi à l'ouverture de session.
///
/// Ce qui rend le lancement automatique acceptable aujourd'hui est différent, et
/// c'est un choix de l'utilisateur : `DockPresence` lui permet de rétrograder
/// l'application en agent, et le réglage dit ce que ça change.
///
/// **Ce qui reste ouvert** : une session qui s'ouvre sur une fenêtre bran que
/// personne n'a demandée. `.defaultLaunchBehavior(.presented)` existe pour une
/// raison — une application dont le seul point d'entrée est un élément de barre
/// de menus n'a pas de premier lancement utilisable — mais elle ne distingue pas
/// « premier lancement » de « ouverture de session ». Voir TODOS.md.
@MainActor
@Observable
final class LoginItemService {
    private(set) var isEnabled: Bool

    init() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // L'échec le plus courant : l'app n'est pas dans un emplacement
            // stable. On resynchronise sur l'état réel plutôt que de mentir à
            // l'interface.
        }
        isEnabled = SMAppService.mainApp.status == .enabled
    }
}
