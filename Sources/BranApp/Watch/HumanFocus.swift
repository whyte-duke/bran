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
/// **Le cas de la voie jamais vue au premier plan**, qui est celui où ce type
/// s'est trompé le plus longtemps. On rend `nil`, et le résolveur en fait ce
/// qu'il a toujours dit qu'il en ferait : il refuse de conclure à une attente.
/// Voir `sinceTouched`, où le raisonnement est écrit en entier.
@MainActor
final class HumanFocus {

    private var touched: [String: Duration] = [:]

    init() {}

    /// À appeler une fois par tic, avant de résoudre.
    ///
    /// - Parameter human: l'inactivité clavier-souris. Une fenêtre au premier
    ///   plan devant un humain parti déjeuner n'est pas « touchée ».
    func update(uptime: Duration, human: HumanPresence, within: TimeInterval) {
        guard let idle = human.idleSeconds, idle <= within else { return }
        guard let identity = Self.frontmostLane() else { return }
        touched[identity.key] = uptime
    }

    /// Depuis quand l'humain n'a pas touché cette voie. **`nil` quand il ne l'a
    /// jamais touchée**, ce qui n'est pas la même chose que « il y a
    /// longtemps ».
    ///
    /// La version précédente rendait le temps écoulé depuis le démarrage du
    /// veilleur, en se justifiant ainsi : « c'est vrai — elle n'a pas été
    /// touchée depuis au moins ça — et ça se corrige tout seul dès qu'on
    /// l'active une fois ». Les deux moitiés de la phrase sont exactes et la
    /// conclusion est fausse, parce qu'elle oublie le cas où l'on ne l'active
    /// **jamais**.
    ///
    /// Ce que ça donnait : toute fenêtre visible et immobile que l'utilisateur
    /// n'a pas mise au premier plan — un onglet de documentation laissé ouvert,
    /// une fenêtre de préférences, un lecteur PDF sur un second écran — passait
    /// à « vous attend » au bout de trois minutes de fonctionnement du veilleur,
    /// et pouvait rafler le routeur d'attention. C'est-à-dire le générateur de
    /// fausses alertes que `lastTouchedByHuman` avait été introduit pour
    /// supprimer, réintroduit par sa propre valeur de repli.
    ///
    /// `WatchResolver` sait déjà quoi faire de `nil` : il refuse de conclure à
    /// une attente et laisse la voie en `stale`, « un état visible qui ne
    /// dérange personne, plutôt qu'une alerte inventée ». Il ne restait qu'à le
    /// lui dire.
    ///
    /// Les sessions d'agent ne perdent rien : un capteur certain court-circuite
    /// cette clause avant même de la lire.
    func sinceTouched(_ key: String, uptime: Duration) -> TimeInterval? {
        guard let at = touched[key] else { return nil }
        return WatchClock.seconds(from: at, to: uptime)
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
