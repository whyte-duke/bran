import Observation
import ServiceManagement

/// Démarrage au login.
///
/// `SMAppService.mainApp` enregistre le bundle lui-même — pas un helper séparé.
/// C'est possible parce que bran est un agent (`LSUIElement`) : il démarre sans
/// fenêtre ni icône du Dock, ce qui rend le lancement automatique acceptable.
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
