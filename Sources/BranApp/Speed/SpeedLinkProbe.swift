import BranCore
import Foundation
import Network

/// **Demander au système par où passe le trafic**, une fois, sans rien envoyer.
///
/// ```
///   NWPathMonitor.start ──▶ premier chemin ──▶ (Wi-Fi, non facturé) ──▶ cancel
///                             ~1 ms
/// ```
///
/// **Pourquoi ce n'est pas une propriété qu'on observe.** `NWPathMonitor` est
/// fait pour rester allumé et prévenir à chaque changement ; c'est le bon outil
/// pour une application qui doit réagir à la perte du réseau. bran n'a pas ce
/// besoin : il veut savoir par où **cette mesure-là** est passée, au moment où
/// elle passe. Un moniteur permanent coûterait un objet vivant et une file de
/// dispatch pour répondre à une question qu'on pose deux fois par jour — la même
/// doctrine que `SpeedController`, qui ne fait tourner sa boucle que pendant un
/// test.
///
/// **Le chemin arrive tout de suite, mais pas depuis l'acteur principal.**
/// `pathUpdateHandler` est appelé sur la file qu'on lui donne, et il peut être
/// rappelé plusieurs fois — au démarrage, puis à chaque changement. Une
/// continuation reprise deux fois est un plantage, pas un avertissement : d'où
/// le drapeau sous verrou, et l'annulation du moniteur dès la première réponse.
///
/// **Il ne lève jamais.** Une question à laquelle le système ne répond pas rend
/// `nil`, et l'appelant écrit un relevé sans lien — exactement comme un relevé
/// écrit par une version antérieure. Faire échouer une mesure de débit parce
/// qu'on n'a pas su nommer l'interface serait absurde.
enum SpeedLinkProbe {

    /// Ce que le système dit du chemin courant.
    struct Reading: Sendable {
        var link: SpeedLink
        /// Liaison facturée au volume — un partage de connexion, typiquement.
        var isExpensive: Bool
    }

    /// Au-delà, on renonce et on renvoie `nil`.
    ///
    /// Une demi-seconde là où la réponse vient en une milliseconde : ce n'est
    /// pas une marge, c'est un filet. Le seul cas connu où le premier chemin
    /// tarde est celui où il n'y a pas de réseau du tout — c'est-à-dire celui où
    /// le test de débit va échouer trois secondes plus tard de toute façon, et
    /// où le faire attendre en plus n'apporterait rien.
    private static let deadline: Duration = .milliseconds(500)

    static func current() async -> Reading? {
        let monitor = NWPathMonitor()

        return await withTaskGroup(of: Reading?.self) { group in
            group.addTask {
                await withCheckedContinuation { continuation in
                    let once = Once()
                    monitor.pathUpdateHandler = { path in
                        guard once.claim() else { return }
                        continuation.resume(returning: Self.read(path))
                    }
                    monitor.start(queue: DispatchQueue(label: "bran.speed.link"))
                }
            }
            group.addTask {
                try? await Task.sleep(for: Self.deadline)
                return nil
            }

            let first = await group.next() ?? nil
            group.cancelAll()
            // **Après le premier résultat, pas dans le gestionnaire.** Annuler
            // un moniteur depuis son propre rappel est une invitation à se
            // désallouer sous ses propres pieds ; et si c'est l'échéance qui a
            // gagné, il faut l'annuler d'ici, sans quoi il resterait allumé pour
            // personne.
            monitor.cancel()
            return first
        }
    }

    private static func read(_ path: NWPath) -> Reading {
        let link: SpeedLink =
            if path.usesInterfaceType(.wifi) { .wifi }
            // **Le filaire après le Wi-Fi, et l'ordre compte.** Un Mac branché
            // en Ethernet *et* associé à une borne annonce les deux interfaces ;
            // c'est le Wi-Fi qui porte alors le trafic dans le cas le plus
            // fréquent — un dock dont le câble n'est pas raccordé — et se
            // tromper dans ce sens fait accuser le câble.
            else if path.usesInterfaceType(.wiredEthernet) { .wired }
            else if path.usesInterfaceType(.cellular) { .cellular }
            else { .other }

        return Reading(link: link, isExpensive: path.isExpensive)
    }
}

/// Un jeton à usage unique, sous verrou. Même `NSLock` que `SpeedProbe.Pump`,
/// et pour la même raison exactement.
///
/// `pathUpdateHandler` peut être rappelé à chaque changement de réseau — et il
/// l'est, en pratique, dans la seconde qui suit un `start()` sur une machine qui
/// vient de s'associer à une borne. Reprendre une continuation deux fois n'est
/// pas un défaut rattrapable : c'est un plantage immédiat.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false

    /// Rend `true` une seule fois, à celui qui arrive le premier.
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard taken == false else { return false }
        taken = true
        return true
    }
}
