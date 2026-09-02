import BranBackup
import Foundation
import Network

/// Les cinq premières sondes de la chaîne réseau — tout ce qui se mesure
/// **avant** que Kopia n'entre en scène. Le sixième maillon
/// (``ChainLink/repositoryOpens``) n'est pas ici : il appartient au pilote
/// Kopia, écrit ailleurs, qui devrait suivre le même patron —
/// `static func repositoryOpens(…) async -> LinkProbeResult`, en extension de
/// ``ChainProbes``, dans son propre fichier. C'est pour que ce patron soit
/// réutilisable que ``runProcess(executable:arguments:timeout:)`` et
/// ``ephemeralSession(timeout:)`` ci-dessous ne sont pas `private` : le pilote
/// Kopia lance lui aussi un `Process` (`kopia repository status`) qui peut
/// se bloquer exactement comme les nôtres, et n'a aucune raison de réinventer
/// un lecteur de tube sans interblocage.
///
/// **Pourquoi `s3Endpoint` et pas `minioTailscaleIP` pour les maillons 3 à 5.**
/// `BackupConfiguration` porte les deux. Mais le but de ces trois sondes est de
/// prédire si le maillon 6 s'ouvrira — donc elles doivent joindre très
/// exactement l'adresse que Kopia utilisera, qui est `s3Endpoint`
/// (`hôte:port`, relevé réel : `"…:9000"`). Sonder `minioTailscaleIP` à la
/// place mesurerait autre chose que ce qui compte : un hôte joignable dont
/// Kopia ne se sert pas ne prouve rien sur le maillon 6.
///
/// **Le seuil de lenteur.** Relevé le 02/09/2026 sur cette machine : TCP 9000
/// ouvert en 0,38 s, `/health/live` en 0,108 s, `/health/ready` en 0,194 s,
/// `GET /<seau>/` (403) en 0,109 s. `slowThreshold` est fixé à dix fois cette
/// pire mesure : assez large pour ne jamais confondre la variabilité normale
/// de la ligne (le propriétaire travaille depuis l'Indonésie, latence du
/// simple au double dans l'heure) avec une panne, assez serré pour rester un
/// vrai signal.
public enum ChainProbes {

    /// Voir la note d'en-tête : dix fois la pire mesure connue sur une ligne
    /// saine. Au-delà, une réponse qui arrive quand même n'est plus déclarée
    /// `up` mais `degraded` — elle n'est jamais déclarée `down` pour ça seul.
    static let slowThreshold: TimeInterval = 3.0

    // MARK: - Maillon 1 : Tailscale local

    /// `tailscale status --json`, lu pour `BackendState` et `Self.Online`.
    public static func tailscaleLocal(timeout: TimeInterval) async -> LinkProbeResult {
        let clock = ContinuousClock()
        let start = clock.now
        let fetch = await runTailscaleStatus(timeout: timeout)
        let latency = (clock.now - start).seconds

        switch fetch {
        case .binaryMissing:
            return makeResult(
                .tailscaleLocal, .down,
                "Tailscale introuvable : ni « /Applications/Tailscale.app » ni le "
                    + "binaire Homebrew ne sont présents sur ce Mac. Installer "
                    + "Tailscale pour activer la sauvegarde."
            )
        case .timedOut:
            return makeResult(
                .tailscaleLocal, .connecting,
                "« tailscale status » n'a pas répondu en \(Int(timeout)) s — pas "
                    + "forcément une panne, la ligne peut être lente. Une nouvelle "
                    + "sonde tranchera.",
                latency: latency
            )
        case .launchFailed(let reason):
            return makeResult(
                .tailscaleLocal, .down,
                "Impossible de lancer « tailscale status » : \(reason).",
                latency: latency
            )
        case .emptyOutput(let stderrText, let exitCode):
            return makeResult(
                .tailscaleLocal, .down,
                "« tailscale status » a échoué (code \(exitCode)) sans rien écrire "
                    + "sur sa sortie standard"
                    + (stderrText.isEmpty ? "." : " : \(stderrText)"),
                raw: stderrText, latency: latency
            )
        case .unreadableJSON(let raw):
            return makeResult(
                .tailscaleLocal, .down,
                "La sortie de « tailscale status --json » est illisible — Tailscale "
                    + "a peut-être changé de format.",
                raw: raw, latency: latency
            )
        case .decoded(let status, let raw):
            return evaluateLocalBackend(status, raw: raw, latency: latency)
        }
    }

    private static func evaluateLocalBackend(
        _ status: RawTailscaleStatus,
        raw: String,
        latency: TimeInterval
    ) -> LinkProbeResult {
        // Aucun état par défaut plausible : un champ absent est une sortie
        // qu'on ne comprend pas, pas un « probablement bon ».
        guard let backendState = status.BackendState else {
            return makeResult(
                .tailscaleLocal, .down,
                "Le champ « BackendState » est absent de la réponse de Tailscale — "
                    + "sortie inattendue.",
                raw: raw, latency: latency
            )
        }

        switch backendState {
        case "Running":
            if status.`Self`?.Online == true {
                return makeResult(
                    .tailscaleLocal, .up,
                    "Tailscale tourne et se signale en ligne (BackendState=Running).",
                    raw: raw, latency: latency
                )
            }
            return makeResult(
                .tailscaleLocal, .degraded,
                "Tailscale tourne (BackendState=Running) mais ne se signale pas "
                    + "encore en ligne — normal juste après un réveil, à surveiller "
                    + "sinon.",
                raw: raw, latency: latency
            )
        case "Starting":
            return makeResult(
                .tailscaleLocal, .connecting,
                "Tailscale démarre (BackendState=Starting).",
                raw: raw, latency: latency
            )
        case "NeedsLogin":
            return makeResult(
                .tailscaleLocal, .down,
                "Tailscale n'est pas authentifié (BackendState=NeedsLogin) — ouvrir "
                    + "Tailscale et se connecter.",
                raw: raw, latency: latency
            )
        case "Stopped":
            return makeResult(
                .tailscaleLocal, .down,
                "Le démon Tailscale est arrêté (BackendState=Stopped).",
                raw: raw, latency: latency
            )
        default:
            return makeResult(
                .tailscaleLocal, .down,
                "État Tailscale inattendu : BackendState=\(backendState).",
                raw: raw, latency: latency
            )
        }
    }

    // MARK: - Maillon 2 : le pair MinIO dans le tailnet

    /// Relit le même genre de JSON que ``tailscaleLocal(timeout:)`` — dans un
    /// second appel de processus, pas une réutilisation du premier : les deux
    /// sondes doivent pouvoir être rejouées indépendamment par l'appelant, à
    /// des instants différents.
    public static func minioNodeOnline(nodeName: String, timeout: TimeInterval) async -> LinkProbeResult {
        let clock = ContinuousClock()
        let start = clock.now
        let fetch = await runTailscaleStatus(timeout: timeout)
        let latency = (clock.now - start).seconds

        switch fetch {
        case .binaryMissing:
            return makeResult(
                .minioNodeOnline, .down,
                "Impossible de vérifier le pair « \(nodeName) » : Tailscale n'est "
                    + "pas installé sur ce Mac."
            )
        case .timedOut:
            return makeResult(
                .minioNodeOnline, .connecting,
                "« tailscale status » n'a pas répondu en \(Int(timeout)) s — "
                    + "impossible de savoir pour l'instant si « \(nodeName) » est en "
                    + "ligne.",
                latency: latency
            )
        case .launchFailed(let reason):
            return makeResult(
                .minioNodeOnline, .down,
                "Impossible de lancer « tailscale status » : \(reason).",
                latency: latency
            )
        case .emptyOutput(let stderrText, let exitCode):
            return makeResult(
                .minioNodeOnline, .down,
                "« tailscale status » a échoué (code \(exitCode)) — impossible de "
                    + "vérifier « \(nodeName) »"
                    + (stderrText.isEmpty ? "." : " : \(stderrText)"),
                raw: stderrText, latency: latency
            )
        case .unreadableJSON(let raw):
            return makeResult(
                .minioNodeOnline, .down,
                "La sortie de « tailscale status --json » est illisible — "
                    + "impossible de vérifier « \(nodeName) ».",
                raw: raw, latency: latency
            )
        case .decoded(let status, let raw):
            return evaluatePeer(nodeName: nodeName, status: status, raw: raw, latency: latency)
        }
    }

    private static func evaluatePeer(
        nodeName: String,
        status: RawTailscaleStatus,
        raw: String,
        latency: TimeInterval
    ) -> LinkProbeResult {
        guard let peers = status.Peer, let peer = findPeer(named: nodeName, in: peers) else {
            return makeResult(
                .minioNodeOnline, .down,
                "Aucun pair nommé « \(nodeName) » dans ce tailnet — vérifier le nom "
                    + "configuré, ou que le NAS est toujours enrôlé.",
                raw: raw, latency: latency
            )
        }

        // `Online` absent n'autorise ni « vrai » ni « faux » par défaut — voir
        // la doctrine du fichier partagé : une entrée illisible produit un
        // échec nommé, jamais une valeur plausible.
        guard let online = peer.Online else {
            return makeResult(
                .minioNodeOnline, .unknown,
                "Le pair « \(nodeName) » existe dans le tailnet mais son champ "
                    + "« Online » est absent de la réponse — impossible de conclure.",
                raw: raw, latency: latency
            )
        }

        if online {
            return makeResult(
                .minioNodeOnline, .up,
                "Le pair « \(nodeName) » est en ligne dans le tailnet.",
                raw: raw, latency: latency
            )
        }

        return makeResult(
            .minioNodeOnline, .down,
            "Le pair « \(nodeName) » est hors ligne\(offlineSince(peer.LastSeen)).",
            raw: raw, latency: latency
        )
    }

    /// L'enrichissement du message, jamais le verdict — c'est `Online` qui
    /// tranche `up`/`down`. `LastSeen` porte la valeur sentinelle
    /// `0001-01-01T00:00:00Z` sur des pairs **en ligne** sur cette machine
    /// (relevé le 02/09/2026) : il ne faut donc surtout pas la lire comme
    /// « jamais vu » quand le pair est hors ligne — on se tait plutôt que
    /// d'inventer une histoire.
    private static func offlineSince(_ lastSeen: String?) -> String {
        guard let lastSeen, lastSeen != "0001-01-01T00:00:00Z" else { return "" }
        guard let date = parseTailscaleDate(lastSeen) else { return "" }
        let days = Int(Date.now.timeIntervalSince(date) / 86400)
        guard days > 0 else { return "" }
        return " depuis \(days) jour\(days > 1 ? "s" : "")"
    }

    // MARK: - Maillon 3 : le port S3 en brut

    /// Une connexion TCP nue sur `hôte:port` — pas de TLS, pas de HTTP, juste
    /// la poignée de main. C'est la mesure la plus proche du câble.
    public static func s3Reachable(endpoint: String, timeout: TimeInterval) async -> LinkProbeResult {
        guard let (host, port) = parseHostPort(endpoint) else {
            return makeResult(
                .s3Reachable, .down,
                "L'adresse configurée « \(endpoint) » n'a pas la forme "
                    + "« hôte:port » attendue."
            )
        }

        let clock = ContinuousClock()
        let start = clock.now
        let outcome = await probeTCP(host: host, port: port, timeout: timeout)
        let latency = (clock.now - start).seconds

        switch outcome {
        case .connected:
            if latency > slowThreshold {
                return makeResult(
                    .s3Reachable, .degraded,
                    "Le port S3 (\(host):\(port)) a répondu, mais après "
                        + "\(formatSeconds(latency)) s — ligne lente, pas coupée.",
                    latency: latency
                )
            }
            return makeResult(
                .s3Reachable, .up,
                "Le port S3 (\(host):\(port)) accepte la connexion.",
                latency: latency
            )
        case .failed(let reason):
            return makeResult(
                .s3Reachable, .down,
                "Connexion refusée sur \(host):\(port) : \(reason). Tailscale ou "
                    + "MinIO est peut-être arrêté.",
                raw: reason, latency: latency
            )
        case .timedOut:
            return makeResult(
                .s3Reachable, .connecting,
                "Aucune réponse du port \(host):\(port) après \(Int(timeout)) s — "
                    + "indéterminé, peut-être une ligne lente depuis l'Indonésie, "
                    + "pas forcément coupée.",
                latency: latency
            )
        }
    }

    // MARK: - Maillon 4 : la santé MinIO

    /// `/minio/health/live` puis `/minio/health/ready`, dans cet ordre : le
    /// premier dit « le processus est debout », le second « il est prêt à
    /// servir ». Un serveur qui vient de démarrer peut légitimement répondre
    /// vivant sans être encore prêt — ce n'est pas la même gravité.
    public static func minioHealthy(
        endpoint: String,
        disableTLS: Bool,
        timeout: TimeInterval
    ) async -> LinkProbeResult {
        let scheme = disableTLS ? "http" : "https"
        guard let liveURL = URL(string: "\(scheme)://\(endpoint)/minio/health/live"),
              let readyURL = URL(string: "\(scheme)://\(endpoint)/minio/health/ready")
        else {
            return makeResult(
                .minioHealthy, .down,
                "L'adresse configurée « \(endpoint) » ne forme pas une URL valide."
            )
        }

        let clock = ContinuousClock()
        let start = clock.now
        let live = await httpGET(liveURL, timeout: timeout)

        switch live {
        case .response(let status, _) where status == 200:
            break
        case .response(let status, let body):
            let latency = (clock.now - start).seconds
            return makeResult(
                .minioHealthy, .down,
                "« /minio/health/live » répond \(status) au lieu de 200 — le "
                    + "processus MinIO signale un problème.",
                raw: bodyText(body), latency: latency
            )
        case .timedOut:
            let latency = (clock.now - start).seconds
            return makeResult(
                .minioHealthy, .connecting,
                "« /minio/health/live » n'a pas répondu en \(Int(timeout)) s — "
                    + "indéterminé.",
                latency: latency
            )
        case .transportError(let reason):
            let latency = (clock.now - start).seconds
            return makeResult(
                .minioHealthy, .down,
                "Impossible de joindre « /minio/health/live » sur \(endpoint) : "
                    + "\(reason).",
                raw: reason, latency: latency
            )
        }

        let ready = await httpGET(readyURL, timeout: timeout)
        let latency = (clock.now - start).seconds

        switch ready {
        case .response(let status, _) where status == 200:
            if latency > slowThreshold {
                return makeResult(
                    .minioHealthy, .degraded,
                    "MinIO est vivant et prêt, mais a répondu après "
                        + "\(formatSeconds(latency)) s — plus lent que la normale.",
                    latency: latency
                )
            }
            return makeResult(
                .minioHealthy, .up,
                "MinIO répond « vivant » et « prêt ».",
                latency: latency
            )
        case .response(let status, let body):
            return makeResult(
                .minioHealthy, .degraded,
                "MinIO est vivant mais « /minio/health/ready » répond \(status) au "
                    + "lieu de 200 — pas encore prêt à servir.",
                raw: bodyText(body), latency: latency
            )
        case .timedOut:
            return makeResult(
                .minioHealthy, .connecting,
                "« /minio/health/ready » n'a pas répondu en \(Int(timeout)) s — "
                    + "indéterminé.",
                latency: latency
            )
        case .transportError(let reason):
            return makeResult(
                .minioHealthy, .down,
                "MinIO est vivant (« /health/live » a répondu) mais "
                    + "« /minio/health/ready » est injoignable : \(reason).",
                raw: reason, latency: latency
            )
        }
    }

    // MARK: - Maillon 5 : le seau

    /// **La sonde qui s'écrit le plus facilement à l'envers.** Un `GET`
    /// anonyme sur le seau doit rendre **403** — c'est le succès : l'API S3
    /// répond, le seau existe, la lecture anonyme est refusée comme elle
    /// doit. `404` dit « seau absent », `200` dit « seau public » (une faute
    /// de configuration, pas une preuve de santé), et une erreur de transport
    /// dit qu'on n'a jamais atteint S3 — quatre situations, quatre messages,
    /// aucun des trois autres ne doit se lire comme un succès.
    public static func bucketReachable(
        endpoint: String,
        bucket: String,
        disableTLS: Bool,
        timeout: TimeInterval
    ) async -> LinkProbeResult {
        let scheme = disableTLS ? "http" : "https"
        guard let url = URL(string: "\(scheme)://\(endpoint)/\(bucket)/") else {
            return makeResult(
                .bucketReachable, .down,
                "L'adresse « \(endpoint) » ou le nom de seau « \(bucket) » ne "
                    + "forment pas une URL valide."
            )
        }

        let clock = ContinuousClock()
        let start = clock.now
        let outcome = await httpGET(url, timeout: timeout)
        let latency = (clock.now - start).seconds

        switch outcome {
        case .response(let status, let body):
            switch status {
            case 403:
                let state: LinkState = latency > slowThreshold ? .degraded : .up
                return makeResult(
                    .bucketReachable, state,
                    "Le seau « \(bucket) » répond 403 à une lecture anonyme : c'est "
                        + "le succès attendu — l'API S3 répond, le seau existe, et "
                        + "il refuse la lecture anonyme comme il doit.",
                    raw: bodyText(body), latency: latency
                )
            case 404:
                return makeResult(
                    .bucketReachable, .down,
                    "Le seau « \(bucket) » n'existe pas sur ce MinIO (404) — "
                        + "vérifier le nom du seau dans la configuration de la "
                        + "sauvegarde.",
                    raw: bodyText(body), latency: latency
                )
            case 200:
                // Rouge, pas vert : reachable ne veut pas dire sain, et un seau
                // public est une faute qu'il faut signaler fort, pas noyer dans
                // un `up` rassurant.
                return makeResult(
                    .bucketReachable, .degraded,
                    "Le seau « \(bucket) » répond 200 à une lecture anonyme : il "
                        + "est public. C'est une faute de configuration, pas une "
                        + "preuve de santé — n'importe qui peut lister son contenu. "
                        + "Corriger la politique d'accès du seau sur MinIO.",
                    raw: bodyText(body), latency: latency
                )
            default:
                return makeResult(
                    .bucketReachable, .down,
                    "Le seau « \(bucket) » a répondu \(status) — ni le succès "
                        + "(403), ni l'absence (404), ni la faute d'ouverture (200) "
                        + "attendus.",
                    raw: bodyText(body), latency: latency
                )
            }
        case .timedOut:
            return makeResult(
                .bucketReachable, .connecting,
                "Le seau « \(bucket) » n'a pas répondu en \(Int(timeout)) s — "
                    + "indéterminé, pas forcément coupé.",
                latency: latency
            )
        case .transportError(let reason):
            return makeResult(
                .bucketReachable, .down,
                "Impossible de joindre le seau « \(bucket) » sur \(endpoint) : "
                    + "\(reason). Le maillon S3 n'a jamais répondu — pas une "
                    + "question de seau, une question de réseau.",
                raw: reason, latency: latency
            )
        }
    }

    // MARK: - Un résultat, toujours complet

    private static func makeResult(
        _ link: ChainLink,
        _ state: LinkState,
        _ diagnostic: String,
        raw: String? = nil,
        latency: TimeInterval? = nil
    ) -> LinkProbeResult {
        LinkProbeResult(
            link: link, state: state, diagnostic: diagnostic,
            rawDetail: raw, latency: latency, measuredAt: .now
        )
    }

    private static func bodyText(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? "<corps illisible, \(data.count) octets>"
    }

    private static func formatSeconds(_ value: TimeInterval) -> String {
        String(format: "%.2f", value)
    }
}

// MARK: - Tailscale : lancer, décoder, interroger

/// Ce que `tailscale status --json` a rendu, avant tout jugement sur un
/// maillon en particulier — les deux sondes qui en dépendent partagent ce
/// classement, mais pas le texte qu'elles en tirent.
private enum TailscaleFetch: Sendable {
    case binaryMissing
    case timedOut
    case launchFailed(String)
    /// Sortie standard vide. Vécu : mauvais mot de passe de démon, service
    /// arrêté — le message utile est alors sur stderr, pas sur stdout.
    case emptyOutput(stderr: String, exitCode: Int32)
    case unreadableJSON(raw: String)
    case decoded(RawTailscaleStatus, raw: String)
}

/// Emplacements connus du client Tailscale sur macOS. **Pas de recherche dans
/// `PATH`** : sous launchd le `PATH` est minimal et n'y trouverait rien, et
/// pas de chemin d'utilisateur en dur — ce sont des emplacements
/// d'installation standard, valables sur n'importe quel Mac.
private let knownTailscaleBinaries = [
    // L'app du Mac App Store et l'app signée directement : le même binaire
    // sert de CLI quand on l'appelle avec `status --json`.
    "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
    // Homebrew, Apple Silicon puis Intel.
    "/opt/homebrew/bin/tailscale",
    "/usr/local/bin/tailscale",
]

// Pas `private` : `BackupProvisioning.deduceTailscalePeer(fromEndpoint:timeout:)`
// doit localiser le même binaire pour interroger `tailscale status --json`
// à l'import, et dupliquer cette liste d'emplacements serait la façon
// classique de les faire diverger en silence.
func locateTailscaleBinary() -> String? {
    knownTailscaleBinaries.first { FileManager.default.isExecutableFile(atPath: $0) }
}

/// Lance `tailscale status --json` et le décode.
///
/// **Le code de sortie et stderr ne comptent pour rien ici.** Relevé le
/// 02/09/2026 sur cette machine : le client en ligne de commande écrit
/// `Warning: client version … != tailscaled server version …` sur stderr à
/// chaque appel, tout en rendant un JSON parfaitement valide sur stdout. Ne
/// classer cet avertissement en échec, c'est justement ce qui distingue une
/// sonde honnête d'une sonde qui panique sur du bruit. Seule l'absence de
/// JSON exploitable sur stdout est un signal.
private func runTailscaleStatus(timeout: TimeInterval) async -> TailscaleFetch {
    guard let binary = locateTailscaleBinary() else { return .binaryMissing }

    let outcome = await runProcess(executable: binary, arguments: ["status", "--json"], timeout: timeout)
    switch outcome {
    case .timedOut:
        return .timedOut
    case .launchFailed(let reason):
        return .launchFailed(reason)
    case .finished(let exitCode, let stdout, let stderr):
        guard stdout.isEmpty == false else {
            let stderrText = String(data: stderr, encoding: .utf8) ?? "<sortie d'erreur illisible>"
            return .emptyOutput(stderr: stderrText, exitCode: exitCode)
        }
        do {
            let status = try JSONDecoder().decode(RawTailscaleStatus.self, from: stdout)
            return .decoded(status, raw: String(data: stdout, encoding: .utf8) ?? "<stdout illisible>")
        } catch {
            let raw = String(data: stdout, encoding: .utf8) ?? "<stdout illisible>"
            return .unreadableJSON(raw: "\(raw)\n[décodage] \(error.localizedDescription)")
        }
    }
}

/// Le sous-ensemble de `tailscale status --json` qui nous intéresse. Les noms
/// de champs suivent exactement la casse du JSON de Go — Tailscale ne les
/// renomme pas en camelCase — donc aucune `CodingKeys` n'est nécessaire.
struct RawTailscaleStatus: Decodable, Sendable {
    let BackendState: String?
    let `Self`: RawTailscaleSelf?
    let Peer: [String: RawTailscalePeer]?
}

struct RawTailscaleSelf: Decodable, Sendable {
    let Online: Bool?
}

struct RawTailscalePeer: Decodable, Sendable {
    let HostName: String?
    let DNSName: String?
    let Online: Bool?
    let LastSeen: String?
    /// Les adresses CGNAT (100.64.0.0/10) du pair dans le tailnet. Pas lu par
    /// ``ChainProbes/evaluatePeer(nodeName:status:raw:latency:)`` — le
    /// maillon 2 se sonde par nom, pas par adresse — mais nécessaire à
    /// `BackupProvisioning.deduceTailscalePeer(fromEndpoint:timeout:)`, qui
    /// fait le chemin inverse : retrouver le nom d'un pair à partir de
    /// l'adresse que porte `s3Endpoint`, pour un import qui n'a que celle-ci.
    let TailscaleIPs: [String]?
}

/// `Peer` est un dictionnaire indexé par **clé publique**, pas par nom : il
/// faut donc parcourir les valeurs. La comparaison ignore la casse — relevé
/// le 02/09/2026, le pair QNAP se présente `NAS831EFC` en majuscules alors
/// qu'il est configuré en minuscules — et regarde aussi `DNSName`, qui porte
/// le nom complet du tailnet (`minio-backup.tailXXXX.ts.net.`).
private func findPeer(named nodeName: String, in peers: [String: RawTailscalePeer]) -> RawTailscalePeer? {
    let target = nodeName.lowercased()
    return peers.values.first { peer in
        if let hostName = peer.HostName, hostName.lowercased() == target {
            return true
        }
        if let dnsName = peer.DNSName, dnsName.lowercased().hasPrefix("\(target).") {
            return true
        }
        return false
    }
}

/// `LastSeen` n'est qu'un enrichissement de message, jamais un verdict — voir
/// ``ChainProbes/offlineSince(_:)``. Go peut rendre 0, 6 ou 9 chiffres de
/// fraction de seconde selon le champ (même piège que documenté dans
/// `KopiaManifest`) ; deux tentatives, et si aucune ne lit, on se tait plutôt
/// que d'inventer une durée.
private func parseTailscaleDate(_ text: String) -> Date? {
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = iso.date(from: text) { return date }
    iso.formatOptions = [.withInternetDateTime]
    return iso.date(from: text)
}

// MARK: - TCP brut

private enum TCPOutcome: Sendable {
    case connected
    case failed(String)
    case timedOut
}

/// Une poignée de main TCP nue, sans rien au-dessus. `.waiting` n'est pas
/// traité comme un échec : une résolution DNS ou un handshake lent depuis
/// l'Indonésie y transite normalement, et c'est le délai `timeout` — pas cet
/// état intermédiaire — qui doit trancher.
private func probeTCP(host: String, port: UInt16, timeout: TimeInterval) async -> TCPOutcome {
    guard let nwPort = NWEndpoint.Port(rawValue: port) else {
        return .failed("port invalide")
    }

    return await withCheckedContinuation { continuation in
        let guardian = SingleResume(continuation)
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)

        // `nonisolated(unsafe)` parce que `DispatchWorkItem` n'est pas
        // `Sendable` et que la fermeture d'état de `NWConnection` l'est. Ce
        // n'est pas une échappatoire de confort : l'objet est créé ici, jamais
        // muté, et les deux seules choses qu'on lui fait — le programmer et
        // l'annuler — sont documentées par GCD comme sûres depuis n'importe
        // quel fil. C'est exactement le cas que cet attribut existe pour
        // couvrir, et l'écrire à la main vaut mieux que de recopier l'objet
        // dans une boîte qui n'apporterait aucune sûreté de plus.
        nonisolated(unsafe) let timeoutWork = DispatchWorkItem {
            connection.stateUpdateHandler = nil
            connection.cancel()
            guardian.resume(.timedOut)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutWork)

        // `stateUpdateHandler = nil` avant `cancel()`, dans les trois issues :
        // la fermeture capture `connection`, et `connection` retient sa
        // propre fermeture — un cycle de rétention qui ne se dénoue pas tout
        // seul tant qu'on ne l'a pas coupé à la main.
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                timeoutWork.cancel()
                connection.stateUpdateHandler = nil
                guardian.resume(.connected)
                connection.cancel()
            case .failed(let error):
                timeoutWork.cancel()
                connection.stateUpdateHandler = nil
                guardian.resume(.failed(error.localizedDescription))
                connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: .global())
    }
}

// MARK: - HTTP, sans cache et sans attendre la connectivité

private enum HTTPOutcome: Sendable {
    case response(status: Int, body: Data)
    case timedOut
    case transportError(String)
}

/// Une session éphémère par appel, jamais réutilisée : une réponse de santé
/// servie depuis un cache est exactement le mensonge que cette chaîne
/// traque — le maillon paraîtrait vivant alors qu'il est mort.
/// `waitsForConnectivity = false` pour la même raison du côté opposé : on
/// veut savoir maintenant que la ligne ne répond pas, pas être mis en
/// attente jusqu'à ce qu'elle remarche.
func ephemeralSession(timeout: TimeInterval) -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = timeout
    configuration.timeoutIntervalForResource = timeout
    configuration.waitsForConnectivity = false
    configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    configuration.urlCache = nil
    return URLSession(configuration: configuration)
}

/// Un `GET`, par le chemin qui convient au schéma.
///
/// ## Pourquoi le HTTP en clair ne passe pas par `URLSession`
///
/// **Trouvé en lançant la vraie sonde depuis le vrai paquet signé, le
/// 02/09/2026**, après que tout ait été écrit et compilé :
///
/// ```
/// Impossible de joindre « /minio/health/live » sur <hôte>:9000 :
/// The resource could not be loaded because the App Transport Security
/// policy requires the use of a secure connection.
/// ```
///
/// App Transport Security refuse le HTTP en clair depuis une application, et
/// il le refuse **avant** que le moindre paquet ne parte. `curl` passait, la
/// sonde non — c'est-à-dire que la mesure faite à la main depuis le terminal
/// ne disait rien de ce que l'application allait vivre. Deux maillons sur six
/// seraient restés rouges à perpétuité sur une chaîne parfaitement saine.
///
/// ## Ce qu'on n'a pas fait pour le régler
///
/// `NSAllowsArbitraryLoads` dans l'`Info.plist` aurait suffi, en une ligne —
/// et aurait désactivé ATS pour **toute** l'application, y compris pour les
/// envois au CRM qui, eux, n'ont aucune raison de sortir en clair. Une
/// exception nommée par domaine était exclue autrement : l'adresse du serveur
/// vient de la configuration de chaque utilisateur, elle n'existe pas à la
/// construction.
///
/// `NWConnection` n'est pas gouverné par ATS — c'est la couche en dessous.
/// Écrire la requête à la main coûte une quarantaine de lignes et laisse la
/// protection intacte partout ailleurs. Le compromis n'est pas une faiblesse
/// cachée : ce trafic-ci voyage déjà dans un tunnel WireGuard, et son contenu
/// est chiffré de bout en bout par Kopia par-dessus.
private func httpGET(_ url: URL, timeout: TimeInterval) async -> HTTPOutcome {
    if url.scheme == "http" {
        return await cleartextGET(url, timeout: timeout)
    }
    return await tlsGET(url, timeout: timeout)
}

/// Un `GET` en clair, écrit à la main sur une socket.
///
/// On ne lit que la **ligne de statut** — `HTTP/1.1 403 Forbidden` — et on
/// s'arrête là. Les sondes de cette chaîne ne s'intéressent qu'au code : la
/// santé de MinIO et l'existence du seau se lisent entièrement dedans. Ne pas
/// implémenter le découpage en morceaux (`chunked`) ni la longueur de contenu
/// n'est donc pas un raccourci — c'est refuser d'écrire un client HTTP dont
/// personne n'a besoin, et dont chaque ligne serait une occasion de se tromper.
private func cleartextGET(_ url: URL, timeout: TimeInterval) async -> HTTPOutcome {
    guard let host = url.host(), let port = NWEndpoint.Port(rawValue: UInt16(url.port ?? 80)) else {
        return .transportError("adresse inutilisable : \(url.absoluteString)")
    }
    let path = url.path().isEmpty ? "/" : url.path()
    let request = """
        GET \(path) HTTP/1.1\r
        Host: \(host):\(port.rawValue)\r
        User-Agent: bran\r
        Connection: close\r
        \r

        """

    return await withCheckedContinuation { continuation in
        let guardian = SingleResume(continuation)
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)

        nonisolated(unsafe) let timeoutWork = DispatchWorkItem {
            connection.stateUpdateHandler = nil
            connection.cancel()
            guardian.resume(.timedOut)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutWork)

        // `@Sendable` explicite : cette fermeture est appelée depuis les
        // rappels de `NWConnection`, qui sont eux-mêmes `@Sendable`. Tout ce
        // qu'elle capture l'est déjà — le gardien est verrouillé, la connexion
        // et l'élément de travail sont sûrs à annuler depuis n'importe quel
        // fil.
        let finish: @Sendable (HTTPOutcome) -> Void = { outcome in
            timeoutWork.cancel()
            connection.stateUpdateHandler = nil
            guardian.resume(outcome)
            connection.cancel()
        }

        // Boucle jusqu'à une ligne de statut **complète**, jamais un seul
        // `receive`. Même famille de bogue que celle documentée plus bas sur
        // `runProcess` (tube vidé trop tôt, sortie tronquée jugée entière) :
        // sur une ligne à latence réelle — le propriétaire travaille depuis
        // l'Indonésie — TCP peut très bien livrer « HTTP/1.1 40 » dans un
        // premier segment et couper avant le reste. `Int("40")` réussirait
        // alors : un nombre plausible qui n'est ni 200, ni 403, ni 404, et
        // qui tomberait dans le `default` de ``bucketReachable`` en annonçant
        // un seau « ni sain, ni absent, ni mal configuré » à tort. On
        // accumule donc jusqu'au premier `\r\n` (la ligne de statut est là en
        // entier) ou jusqu'à `isComplete` (le correspondant a fermé avant
        // même ça) ; le délai déjà armé au-dessus reste la seule limite de
        // temps, il n'est pas contourné.
        // **Une boîte plutôt qu'une fonction locale récursive**, parce que les
        // rappels de `NWConnection` sont `@Sendable` et qu'une fonction locale
        // ne l'est pas : elle capture son contexte, et le compilateur refuse de
        // la laisser franchir la frontière. La lier à une variable
        // explicitement `@Sendable` fait la même chose en le disant.
        //
        // L'auto-référence passe par une boîte parce qu'une fermeture ne peut
        // pas se nommer elle-même au moment où on l'écrit. Elle n'est assignée
        // qu'une fois, avant le premier `receive`, et lue depuis les rappels
        // — jamais mutée en concurrence.
        let recurse = SendableBox<@Sendable (Data) -> Void>()
        let receiveStatusLine: @Sendable (Data) -> Void = { accumulated in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isComplete, receiveError in
                if let receiveError {
                    finish(.transportError(receiveError.localizedDescription))
                    return
                }
                var buffer = accumulated
                if let data { buffer.append(data) }

                if let crlf = buffer.range(of: Data([0x0D, 0x0A])) {
                    // On ne décode que la ligne de statut elle-même, jamais
                    // tout le tampon : le corps qui la suit n'a aucune raison
                    // d'être de l'UTF-8 valide, et ce n'est pas lui qu'on
                    // juge ici.
                    guard let statusLine = String(data: buffer[buffer.startIndex..<crlf.lowerBound], encoding: .utf8),
                          let code = statusLine.split(separator: " ").dropFirst().first,
                          let status = Int(code)
                    else {
                        finish(.transportError("réponse sans ligne de statut lisible"))
                        return
                    }
                    finish(.response(status: status, body: buffer))
                    return
                }

                if isComplete {
                    finish(.transportError("connexion fermée avant la fin de la ligne de statut"))
                    return
                }

                recurse.value?(buffer)
            }
        }
        recurse.value = receiveStatusLine

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.send(content: Data(request.utf8), completion: .contentProcessed { error in
                    if let error {
                        finish(.transportError(error.localizedDescription))
                        return
                    }
                    receiveStatusLine(Data())
                })
            case .failed(let error):
                finish(.transportError(error.localizedDescription))
            default:
                break
            }
        }
        connection.start(queue: .global())
    }
}

private func tlsGET(_ url: URL, timeout: TimeInterval) async -> HTTPOutcome {
    let session = ephemeralSession(timeout: timeout)
    defer { session.invalidateAndCancel() }

    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

    do {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            return .transportError("réponse sans code HTTP")
        }
        return .response(status: http.statusCode, body: data)
    } catch let error as URLError where error.code == .timedOut {
        return .timedOut
    } catch {
        return .transportError(error.localizedDescription)
    }
}

// MARK: - Un processus qui ne peut pas bloquer l'application

enum ProcessRunOutcome: Sendable {
    case timedOut
    case launchFailed(String)
    case finished(exitCode: Int32, stdout: Data, stderr: Data)
}

/// Lance `executable`, capture stdout et stderr sans jamais s'endormir
/// dessus, et tue le processus s'il dépasse `timeout`.
///
/// **Pourquoi les tubes se vident au fil de l'eau et non à la fin.** Lire
/// avec `readDataToEndOfFile()` après la terminaison est le piège classique :
/// si l'enfant écrit plus que le tampon d'un tube (64 Ko) avant qu'on ne
/// commence à le lire, il se bloque en écriture, ne termine jamais, et
/// `terminationHandler` n'est donc jamais appelé — un interblocage. Un
/// `tailscale status --json` sur un tailnet chargé peut dépasser cette
/// taille ; `readabilityHandler` évite le piège en lisant dès que des octets
/// arrivent, quel que soit le volume final.
func runProcess(
    executable: String,
    arguments: [String],
    timeout: TimeInterval
) async -> ProcessRunOutcome {
    await withCheckedContinuation { continuation in
        let guardian = SingleResume(continuation)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        // Un `Pipe()` propre plutôt qu'une entrée héritée du parent : ce
        // dernier n'a aucune raison de lire quoi que ce soit ici, et
        // `RegionCapturer` documente déjà pourquoi partager un descripteur
        // avec `Process` est le genre d'économie qui coûte cher ailleurs.
        process.standardInput = Pipe()

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutBuffer = DataAccumulator()
        let stderrBuffer = DataAccumulator()

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
            } else {
                stdoutBuffer.append(chunk)
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
            } else {
                stderrBuffer.append(chunk)
            }
        }

        // `nonisolated(unsafe)` parce que `DispatchWorkItem` n'est pas
        // `Sendable` et que la fermeture d'état de `NWConnection` l'est. Ce
        // n'est pas une échappatoire de confort : l'objet est créé ici, jamais
        // muté, et les deux seules choses qu'on lui fait — le programmer et
        // l'annuler — sont documentées par GCD comme sûres depuis n'importe
        // quel fil. C'est exactement le cas que cet attribut existe pour
        // couvrir, et l'écrire à la main vaut mieux que de recopier l'objet
        // dans une boîte qui n'apporterait aucune sûreté de plus.
        nonisolated(unsafe) let timeoutWork = DispatchWorkItem {
            if process.isRunning { process.terminate() }
            guardian.resume(.timedOut)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutWork)

        process.terminationHandler = { finished in
            timeoutWork.cancel()
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil

            // **Vider les tubes après la terminaison, et c'est indispensable.**
            //
            // `terminationHandler` se déclenche quand le processus se termine,
            // pas quand ses tubes sont lus. Les `readabilityHandler` tournent
            // sur une autre file : au moment où l'on arrive ici, les derniers
            // paquets écrits par l'enfant peuvent parfaitement être encore dans
            // le tube, jamais remis à l'accumulateur. Couper la lecture et
            // photographier le tampon dans la foulée rendait donc une sortie
            // **tronquée**.
            //
            // Ça ne se voyait pas sur les petites sorties. Sur les 13 436
            // octets de `tailscale status --json`, en revanche, le JSON
            // arrivait coupé en plein milieu — et la sonde annonçait « la
            // sortie de tailscale est illisible, il a peut-être changé de
            // format » sur un tailnet parfaitement sain. Le maillon 1 restait
            // rouge en permanence, et avec lui toute la chaîne.
            //
            // Lire jusqu'à la fin ici ne peut pas bloquer : le processus est
            // mort, donc l'extrémité d'écriture est fermée et `EOF` arrive.
            stdoutBuffer.append(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            stderrBuffer.append(stderrPipe.fileHandleForReading.readDataToEndOfFile())

            guardian.resume(.finished(
                exitCode: finished.terminationStatus,
                stdout: stdoutBuffer.snapshot(),
                stderr: stderrBuffer.snapshot()
            ))
        }

        do {
            try process.run()
        } catch {
            timeoutWork.cancel()
            guardian.resume(.launchFailed(error.localizedDescription))
        }
    }
}

// MARK: - Utilitaires de concurrence partagés

/// Accumule des octets reçus depuis plusieurs appels de
/// `readabilityHandler`, qui peuvent tomber sur un fil différent de celui qui
/// lit `snapshot()`. `@unchecked Sendable` justifié comme dans
/// `SpeedProbe.Counter` : la seule voie d'accès à `data` passe par le verrou,
/// rien ne le laisse fuir sans lui.
final class DataAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func snapshot() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

/// Garde une seule reprise d'une continuation quand deux chemins peuvent
/// vouloir conclure la même attente — ici, l'échéance et la réponse du
/// réseau ou du processus arrivent en concurrence, et une continuation
/// reprise deux fois plante le programme sur place. Même patron que
/// `Pump.finish(with:)` dans `SpeedProbe`, généralisé au type de retour.
final class SingleResume<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false
    private let continuation: CheckedContinuation<T, Never>

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    // `sending` parce que la valeur franchit ici une frontière d'isolement :
    // elle est produite sur le fil du réseau ou du processus, et reprise sur
    // celui qui attend. Le compilateur veut la garantie qu'elle n'est plus
    // référencée par l'appelant — l'annoter la donne, sans exiger que `T` soit
    // `Sendable`, ce qu'un `NWError` traduit ne serait pas.
    func resume(_ value: sending T) {
        lock.lock()
        defer { lock.unlock() }
        guard used == false else { return }
        used = true
        continuation.resume(returning: value)
    }
}

// MARK: - Petits analyseurs

/// `endpoint` est toujours `hôte:port` (relevé réel : `"…:9000"`) — jamais un
/// port par défaut deviné : une configuration illisible est un échec nommé,
/// pas une supposition.
///
/// Pas `private` : `BackupProvisioning.deduceTailscalePeer(fromEndpoint:timeout:)`
/// a besoin du même découpage pour isoler l'hôte de `s3Endpoint` avant de
/// juger s'il a la forme d'une adresse Tailscale.
func parseHostPort(_ endpoint: String) -> (host: String, port: UInt16)? {
    guard let colonIndex = endpoint.lastIndex(of: ":") else { return nil }
    let host = String(endpoint[endpoint.startIndex..<colonIndex])
    let portText = String(endpoint[endpoint.index(after: colonIndex)...])
    guard host.isEmpty == false, let port = UInt16(portText) else { return nil }
    return (host, port)
}

// `private` et non `internal` : `NotchView.swift` porte déjà une extension
// `Duration.seconds` identique, elle aussi `private`. Deux extensions
// `private` du même type dans deux fichiers ne se voient jamais l'une
// l'autre, donc ne s'affrontent pas ; deux extensions visibles au niveau du
// module l'auraient fait — ambiguïté à la compilation dans les deux fichiers.
private extension Duration {
    /// Conversion vers `TimeInterval`, pour tenir les mesures de latence
    /// dans le type que porte déjà `LinkProbeResult`.
    var seconds: TimeInterval {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1_000_000_000_000_000_000
    }
}


/// Une case qu'on remplit une fois pour permettre à une fermeture de
/// s'appeler elle-même.
///
/// Une fermeture ne peut pas se nommer au moment où on l'écrit : il faut un
/// intermédiaire. `@unchecked Sendable` est honnête ici — l'écriture est unique
/// et précède toutes les lectures, qui viennent ensuite des rappels du réseau.
final class SendableBox<T>: @unchecked Sendable {
    var value: T?
}
