import AppKit
import BranWatch
import BranWindows
import Foundation

/// Depuis quand l'humain n'a pas touché **cette voie-là**.
///
/// `WatchResolver` refuse de conclure à une attente sans cette information, et
/// il a raison : sans capteur certain — le cas de tout onglet `claude.ai`, de
/// toute application de bureau — l'immobilité seule ne prouve rien. Une fenêtre
/// que l'utilisateur regarde à l'instant est immobile parce qu'il *lit*, pas
/// parce qu'elle l'attend. C'était le générateur de fausses alertes numéro un.
///
/// **Comment on le sait, sans rien installer.** À chaque tic, la fenêtre au
/// premier plan est identifiée, et si l'humain est actif au même moment, on note
/// que cette voie vient d'être touchée. Aucun `CGEventTap` — il n'y en a qu'un
/// dans bran, celui de `ShortcutRouter` — et aucune lecture de frappe : on
/// croise « quelle fenêtre est devant » avec « le système a vu un événement
/// récemment », deux informations que macOS donne gratuitement.
///
/// **Le cas de la voie jamais vue au premier plan.** Rendre `nil` la
/// condamnerait à ne jamais pouvoir attendre. On rend donc le temps écoulé
/// depuis le démarrage du veilleur : c'est vrai — elle n'a pas été touchée
/// depuis au moins ça — et ça se corrige tout seul dès qu'on l'active une fois.
@MainActor
final class HumanFocus {

    private var touched: [String: Duration] = [:]
    private let startedAt: Duration

    init(startedAt: Duration) {
        self.startedAt = startedAt
    }

    /// À appeler une fois par tic, avant de résoudre.
    ///
    /// - Parameter human: l'inactivité clavier-souris. Une fenêtre au premier
    ///   plan devant un humain parti déjeuner n'est pas « touchée ».
    func update(uptime: Duration, human: HumanPresence, within: TimeInterval) {
        guard let idle = human.idleSeconds, idle <= within else { return }
        guard let identity = Self.frontmostLane() else { return }
        touched[identity.key] = uptime
    }

    func sinceTouched(_ key: String, uptime: Duration) -> TimeInterval? {
        WatchClock.seconds(from: touched[key] ?? startedAt, to: uptime)
    }

    func forget() {
        touched.removeAll()
    }

    /// La voie de la fenêtre au premier plan.
    ///
    /// La clé doit tomber sur exactement la même que celle du capteur de pixels,
    /// donc elle est fabriquée avec les mêmes trois ingrédients :
    /// identifiant de paquet, nom d'application, titre. `kCGWindowName` n'est
    /// renseigné qu'avec l'autorisation d'écran — sans elle, on ne sait rien, ce
    /// qui est cohérent : sans elle il n'y a pas non plus de voies observées.
    private static func frontmostLane() -> LaneIdentity? {
        guard let application = NSWorkspace.shared.frontmostApplication else { return nil }
        guard let window = WindowList.frontmost() else { return nil }

        // L'identité est reconstruite à partir de `NSRunningApplication` et non
        // du nom rendu par le serveur de fenêtres : `WindowSampler` la fabrique
        // avec les mêmes trois ingrédients côté ScreenCaptureKit, et les deux
        // clés doivent tomber exactement l'une sur l'autre.
        return .window(
            bundleIdentifier: application.bundleIdentifier,
            applicationName: application.localizedName ?? "?",
            title: window.title
        )
    }
}
