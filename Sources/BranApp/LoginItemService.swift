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

    private static let offeredKey = "bran.loginItem.proposed"

    init() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    /// Enregistre bran au login **au tout premier lancement, et une seule fois**.
    ///
    /// Les quatre fonctions de bran sont actives par défaut — dictée, capture de
    /// texte, presse-papiers, veille — et personne ne devrait avoir à ouvrir les
    /// réglages pour s'en servir. Le démarrage automatique était le seul réglage
    /// qui échappait à cette règle, et c'est celui qui compte le plus : bran
    /// observe pour proposer d'enregistrer une réunion. Un observateur qu'il faut
    /// penser à lancer n'observe rien le jour où on l'oublie, c'est-à-dire le
    /// jour où on en avait besoin.
    ///
    /// **Le marqueur est la moitié qui rend ça acceptable.** Sans lui, chaque
    /// lancement réenregistrerait l'élément, et quelqu'un qui l'a délibérément
    /// retiré le retrouverait le lendemain — une application qui remet ses
    /// réglages toute seule est une application qu'on désinstalle. Le marqueur
    /// dit « la proposition a été faite », pas « c'est activé » : il survit donc
    /// au refus, qui est exactement ce qu'il faut retenir.
    ///
    /// L'utilisateur voit ce qui vient de se passer : l'écran d'accueil porte
    /// l'interrupteur, allumé, avec de quoi l'éteindre sur place. macOS le
    /// signale de son côté par sa propre notification d'élément d'ouverture. Ce
    /// n'est donc pas une inscription silencieuse.
    /// **Le marqueur n'est posé que si l'enregistrement a abouti**, et l'ordre
    /// inverse était une faute : il était écrit d'abord, si bien qu'un échec au
    /// premier lancement consommait l'adoption pour toujours. Or l'échec le plus
    /// courant de `SMAppService` est « l'application n'est pas à un emplacement
    /// stable » — c'est-à-dire précisément le premier lancement depuis une image
    /// disque, avant que l'utilisateur l'ait glissée dans Applications. Le seul
    /// cas où la proposition comptait vraiment était donc le seul où elle se
    /// perdait. Un échec laisse maintenant le marqueur en place, et le lancement
    /// suivant — depuis Applications, cette fois — réessaie.
    func adoptDefaultOnFirstLaunch() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: Self.offeredKey) == false else { return }

        // Déjà enregistré — l'application a été réinstallée par-dessus une
        // version qui l'avait fait. Rien à proposer, et surtout rien à défaire.
        guard SMAppService.mainApp.status != .enabled else {
            defaults.set(true, forKey: Self.offeredKey)
            return
        }

        setEnabled(true)
        if isEnabled { defaults.set(true, forKey: Self.offeredKey) }
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
