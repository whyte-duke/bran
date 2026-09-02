import Foundation

/// Accumule la sortie d'un sous-processus **avec un plafond**, pour que la
/// durée d'un run ne devienne jamais une consommation mémoire.
///
/// ## La panne que ce type ferme
///
/// `kopia snapshot create --progress` réécrit une ligne d'état sur stderr à
/// chaque avancée du hachage. Relevé le 02/09/2026 sur ce Mac : la ligne
/// mesure de l'ordre de 120 octets et revient plusieurs fois par seconde. Sur
/// la première sauvegarde de ce Mac — ~600 Go à 5,5 Mo/s, donc de l'ordre de
/// 30 heures — un accumulateur sans plafond retient tout.
///
/// Simulé avec ces chiffres (30 h, 4 lignes de 120 octets par seconde,
/// 432 000 lignes) :
///
/// ```
///   sans plafond : 51 Mo résidents, qui ne redescendent jamais
///   avec plafond : 256 Kio, et 51 Mo élidés — comptés, jamais tus
/// ```
///
/// 51 Mo est le **plancher** : kopia émet bien plus souvent que 4 fois par
/// seconde pendant les phases de hachage local, et la maintenance qui se
/// déclenche en cours de route écrit ses propres lignes. Le processus qui doit
/// tourner trente heures sans surveillance est exactement celui qui n'a pas le
/// droit de grossir sans borne.
///
/// ## Pourquoi la tête **et** la queue, jamais une troncature aveugle
///
/// Couper à N octets et jeter le reste jetterait précisément ce qui compte :
/// **l'erreur arrive à la fin**. C'est la dernière ligne de stderr que
/// `KopiaFailureClassifier` lit pour dire pourquoi un run a échoué. Garder la
/// tête aussi n'est pas de la symétrie décorative : la bannière de démarrage
/// de kopia (version, dépôt ouvert, politique appliquée) y est, et c'est elle
/// qui dit *contre quoi* le run tournait quand on relit un diagnostic six mois
/// plus tard.
///
/// Entre les deux, un marqueur qui **compte** ce qui manque, en français : un
/// diagnostic amputé sans le dire serait le même mensonge, à l'échelle du
/// journal, que celui que tout ce module combat.
///
/// ## Pourquoi stdout ne se traite pas pareil
///
/// stdout porte du JSON qu'il faut **décoder**. Y insérer un marqueur au
/// milieu le rendrait illisible, et une troncature silencieuse produirait un
/// manifeste amputé qu'un décodeur indulgent pourrait accepter — le pire des
/// deux mondes. D'où le second mode, ``Policy/refuseBeyond(limit:)`` : on
/// accumule jusqu'à un plafond très haut, et au-delà on **refuse**
/// (``didOverflow``) plutôt que de rendre une sortie partielle qui a l'air
/// entière. C'est à l'appelant d'en faire un échec nommé.
final class BoundedOutputBuffer: @unchecked Sendable {

    /// Ce qui se passe quand le plafond est atteint.
    enum Policy: Sendable {
        /// Garde les `head` premiers octets et les `tail` derniers, et compte
        /// ce qui a été élidé entre les deux. Pour un flux de progression,
        /// dont seules la bannière et la fin portent de l'information.
        case headAndTail(head: Int, tail: Int)
        /// Accumule jusqu'à `limit`, puis cesse et lève ``didOverflow``. Pour
        /// un flux qui doit rester décodable ou ne rien valoir.
        case refuseBeyond(limit: Int)
    }

    /// 64 Kio de tête : largement de quoi contenir la bannière d'ouverture du
    /// dépôt et les premières lignes de politique.
    static let defaultStderrHead = 64 * 1024
    /// 192 Kio de queue : la fin porte l'erreur, elle a donc trois fois la
    /// part de la tête.
    static let defaultStderrTail = 192 * 1024
    /// 64 Mio pour stdout. Un manifeste de snapshot fait quelques centaines
    /// d'octets ; `snapshot list --all --json` sur un dépôt de plusieurs
    /// milliers de snapshots reste très en dessous. Ce plafond ne se rencontre
    /// pas en fonctionnement normal — c'est un filet contre un binaire qui
    /// n'est pas celui qu'on croit.
    static let defaultStdoutLimit = 64 * 1024 * 1024

    private let lock = NSLock()
    private let policy: Policy
    private var head = Data()
    private var tail = Data()
    private var elided = 0
    private var overflowed = false

    init(policy: Policy) {
        self.policy = policy
    }

    /// Le tampon de stderr, avec ses réglages par défaut.
    static func stderr() -> BoundedOutputBuffer {
        BoundedOutputBuffer(policy: .headAndTail(head: defaultStderrHead, tail: defaultStderrTail))
    }

    /// Le tampon de stdout, avec son plafond de refus par défaut.
    static func stdout() -> BoundedOutputBuffer {
        BoundedOutputBuffer(policy: .refuseBeyond(limit: defaultStdoutLimit))
    }

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        switch policy {
        case .headAndTail(let headLimit, let tailLimit):
            var remaining = chunk
            if head.count < headLimit {
                let take = min(headLimit - head.count, remaining.count)
                head.append(remaining.prefix(take))
                remaining = remaining.dropFirst(take)
            }
            guard !remaining.isEmpty else { return }
            tail.append(remaining)
            if tail.count > tailLimit {
                let excess = tail.count - tailLimit
                tail = Data(tail.dropFirst(excess))
                elided += excess
            }
        case .refuseBeyond(let limit):
            guard !overflowed else { return }
            if head.count + chunk.count > limit {
                overflowed = true
                // On garde ce qui a déjà été reçu : il sert au diagnostic,
                // jamais au décodage — voir `didOverflow`.
                return
            }
            head.append(chunk)
        }
    }

    /// Vrai quand le plafond de ``Policy/refuseBeyond(limit:)`` a été franchi.
    /// Les octets rendus par ``snapshot()`` sont alors **incomplets** et ne
    /// doivent jamais être décodés comme s'ils étaient entiers.
    var didOverflow: Bool {
        lock.lock(); defer { lock.unlock() }
        return overflowed
    }

    /// Le nombre d'octets élidés entre la tête et la queue. Zéro est le cas
    /// normal.
    var elidedByteCount: Int {
        lock.lock(); defer { lock.unlock() }
        return elided
    }

    /// Les octets accumulés, marqueur d'élision compris quand il y en a un.
    func snapshot() -> Data {
        lock.lock(); defer { lock.unlock() }
        guard elided > 0 else { return head + tail }
        return head + Data(Self.elisionMarker(bytes: elided).utf8) + tail
    }

    /// Le texte accumulé, décodé **une seule fois depuis les octets
    /// complets** — jamais recollé à partir des fragments passés au lecteur de
    /// progression, dont un caractère multi-octets a pu être coupé en deux.
    /// Une sortie qui n'est pas de l'UTF-8 valide devient un texte qui le dit,
    /// jamais un décodage silencieusement approximatif.
    func text() -> String {
        let data = snapshot()
        return String(data: data, encoding: .utf8) ?? "<sortie non-UTF8, \(data.count) octets>"
    }

    static func elisionMarker(bytes: Int) -> String {
        "\n… [\(bytes) octets de sortie élidés par bran — tête et fin conservées] …\n"
    }
}
