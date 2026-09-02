import Foundation
#if canImport(Darwin)
import Darwin
#endif
import BranBackup

// Le seul endroit du projet qui lance réellement `kopia`. Tout ce qui décode
// sa sortie — `KopiaManifest`, `KopiaProgressReader`, `KopiaFailureClassifier`
// — vit dans la cible pure `BranBackup` ; ce fichier ne fait qu'exécuter le
// processus et leur passer ses octets. La frontière est délibérée : un test
// contre une sortie de kopia figée n'a pas besoin de lancer quoi que ce soit,
// et ce fichier-ci ne se prouve qu'en tournant contre le vrai dépôt.
//
// **Le mot de passe ne passe jamais en `argv`.** Toujours via la variable
// d'environnement `KOPIA_PASSWORD` du processus enfant, jamais comme
// argument de `kopia`. Deux raisons, et aucune n'est un choix de goût :
// 1. `argv` est lisible par n'importe quel processus du même utilisateur via
//    `ps -ww -p <pid>` — un secret qui y transite est un secret publié.
// 2. Le Trousseau refuse de répondre hors session interactive déverrouillée ;
//    sous launchd — le contexte normal d'une sauvegarde planifiée, écran
//    verrouillé, personne devant le Mac — il n'y a pas d'autre canal que
//    l'environnement pour faire parvenir un secret déjà obtenu ailleurs à ce
//    processus enfant. Ce fichier ne lit donc jamais le Trousseau lui-même :
//    il reçoit le mot de passe d'un fournisseur (``KopiaPasswordProviding``)
//    écrit ailleurs, et ne le journalise jamais — les rares fois où ce
//    fichier construit un texte de diagnostic à la main, il passe par
//    `KopiaFailureClassifier.maskSecrets` avant de le poser dans un
//    `BackupFailure.rawOutput`, exactement comme le classifieur le fait pour
//    ses propres échecs.
//
// **stdout et stderr se lisent en continu, pendant que le processus tourne.**
// C'est le piège classique de `Process` : attendre `waitUntilExit()` puis
// lire les tuyaux avec `readDataToEndOfFile()` interbloque dès que la sortie
// dépasse le tampon noyau du tuyau — 64 Kio sur macOS. Un `snapshot create`
// sur une source de plusieurs centaines de gigaoctets écrit très largement
// plus que ça sur stderr (une ligne de progression par avancée de hachage,
// plus la maintenance qui peut se déclencher en cours de route) : sans
// lecture au fil de l'eau, kopia se bloque en écriture parce que personne ne
// vide le tuyau, et ce processus reste suspendu sur un `waitUntilExit()` qui
// n'arrivera jamais — invisible sur un run de test de trois fichiers, fatal
// au bout de trente heures sur la vraie source. `readabilityHandler`, posé
// sur les deux tuyaux avant `process.run()`, est ce qui évite ça.
//
// **Le code de sortie ne fait pas foi.** Mesuré sur ce Mac le 02/09/2026:
// `kopia repository status` avec un mauvais mot de passe écrit son erreur sur
// stderr et sort quand même avec le code 0. `KopiaFailureClassifier.classify`
// est donc appelé sur le texte avant tout examen du code de sortie, et un
// stdout vide ou non décodable est traité comme un échec même quand le
// classifieur n'a rien trouvé à y redire — jamais un `SnapshotProof` ou un
// `RepositoryStatus` plausible construit sur une sortie qu'on n'a pas pu
// lire.

// MARK: - Le fournisseur de mot de passe

/// Fournit le mot de passe du dépôt au moment de l'utiliser.
///
/// **Ce protocole, et non un accès direct au Trousseau, est la frontière
/// voulue.** L'implémentation réelle — probablement adossée à
/// `BackupSecrets.read(.repositoryPassword)` — vit ailleurs dans `BranApp` ;
/// ce fichier n'importe pas `Security` et ne sait pas ce qu'est un
/// `SecItemCopyMatching`. Ça garde `KopiaDriver` testable avec un fournisseur
/// factice, et ça évite qu'une deuxième politique de lecture du Trousseau
/// (verrouillé ? absent ? périmé ?) ne s'invente ici, en double de celle déjà
/// écrite à l'endroit qui la connaît vraiment.
public protocol KopiaPasswordProviding: Sendable {
    func kopiaPassword() async throws -> String
}

// MARK: - Où trouver le binaire

/// Pourquoi le binaire est introuvable, ou ne l'est qu'en apparence.
public enum KopiaBinaryFailure: Error, Sendable, Equatable, CustomStringConvertible {
    /// Ni dans le paquet applicatif, ni à un chemin configuré.
    case notFound
    /// Un chemin existe mais le fichier qui s'y trouve n'a pas le bit
    /// d'exécution — un binaire mal copié, un chemin qui pointe ailleurs.
    case notExecutable(path: String)

    public var description: String {
        switch self {
        case .notFound:
            "Le binaire kopia est introuvable — ni dans le paquet de l'application, ni à un chemin configuré."
        case .notExecutable(let path):
            "Le fichier à « \(path) » existe mais n'est pas exécutable."
        }
    }
}

/// Le binaire kopia, une fois localisé — jamais construit ailleurs qu'ici.
public struct KopiaExecutable: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// Cherche le binaire dans cet ordre, et dans aucun autre :
    /// 1. celui embarqué dans le paquet de l'application ;
    /// 2. un chemin configuré explicitement (réglages avancés, ou tests).
    ///
    /// **Jamais le `PATH`.** Sous launchd — le contexte d'une sauvegarde
    /// planifiée — le `PATH` hérité est minimal, pas celui d'un shell de
    /// connexion ; y chercher `kopia` reviendrait le plus souvent à ne rien
    /// trouver, et le jour où quelque chose y répond, rien ne garantit que
    /// c'est le binaire qu'on a testé plutôt qu'une version qu'un
    /// `brew upgrade` aurait posée sous nos pieds entre deux sauvegardes.
    /// Un chemin en dur (`/opt/homebrew/bin/kopia`) serait pire encore : il
    /// ne vaut même pas pour tous les Mac de ce projet — Homebrew installe en
    /// `/usr/local/bin` sur Intel, `/opt/homebrew/bin` sur Apple Silicon.
    public static func locate(configuredPath: String?, bundle: Bundle = .main) throws -> KopiaExecutable {
        if let resource = bundle.url(forResource: "kopia", withExtension: nil),
           FileManager.default.isExecutableFile(atPath: resource.path) {
            return KopiaExecutable(url: resource)
        }
        // Filet pour le cas où le binaire est bien copié dans le paquet mais
        // n'apparaît pas via l'API de ressources nommées — `Bundle.main`
        // s'appuie sur des métadonnées que le script d'empaquetage peut ne
        // pas renseigner pour un fichier ajouté après coup.
        if let resourceURL = bundle.resourceURL {
            let candidate = resourceURL.appending(path: "kopia")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return KopiaExecutable(url: candidate)
            }
        }
        if let configuredPath, !configuredPath.isEmpty {
            guard FileManager.default.isExecutableFile(atPath: configuredPath) else {
                throw KopiaBinaryFailure.notExecutable(path: configuredPath)
            }
            return KopiaExecutable(url: URL(filePath: configuredPath))
        }
        throw KopiaBinaryFailure.notFound
    }
}

// MARK: - Les échecs propres au pilote

/// Ce qui peut échouer dans ce fichier et qui n'est pas déjà un
/// `BackupFailure` produit par `BranBackup`. `asBackupFailure` ramène tous
/// les cas à la même forme, pour que l'appelant n'ait jamais à distinguer
/// « erreur du pilote » d'« erreur classée par le contrat » — les deux se
/// consomment de la même façon.
public enum KopiaDriverFailure: Error, Sendable, CustomStringConvertible {
    case binary(KopiaBinaryFailure)
    case launchFailed(underlying: String)
    /// `createSnapshot` appelé sans aucun dossier à sauvegarder — pas une
    /// panne de kopia, une configuration incomplète en amont.
    case noSourcePaths
    /// `kopia --version` n'a rien écrit sur stdout.
    case emptyVersionOutput
    /// Un run est déjà en cours sur ce pilote. Ce n'est pas au pilote de
    /// mettre en file d'attente des commandes concurrentes — c'est à
    /// l'appelant de sérialiser via `BackupPhase.isBusy` — mais laisser deux
    /// runs se marcher dessus perdrait la cible d'annulation du premier :
    /// `currentProcess` ne peut désigner qu'un seul processus kopia à la
    /// fois. Voir la réservation de `isRunning` dans `run(...)`.
    case alreadyRunning
    /// La commande n'a pas rendu la main dans le délai total qui lui était
    /// accordé, et a été terminée. **Ne concerne jamais `snapshot create`**,
    /// qui n'a pas de délai total — voir la note dans `createSnapshot`.
    case timedOut(command: String, seconds: TimeInterval)
    case backup(BackupFailure)

    public var description: String {
        switch self {
        case .binary(let failure): failure.description
        case .launchFailed(let underlying): "Impossible de lancer kopia : \(underlying)."
        case .noSourcePaths: "Aucun dossier à sauvegarder n'a été fourni."
        case .emptyVersionOutput: "« kopia --version » n'a rien écrit."
        case .alreadyRunning: "Une commande kopia est déjà en cours sur ce pilote."
        case .timedOut(let command, let seconds):
            "« kopia \(command) » n'a pas répondu en \(Int(seconds)) s et a été arrêté."
        case .backup(let failure): failure.summary
        }
    }

    /// Traduit ce cas en `BackupFailure`, pour que tout le reste de
    /// l'application n'ait qu'un seul type d'échec de sauvegarde à afficher.
    public var asBackupFailure: BackupFailure {
        switch self {
        case .backup(let failure):
            failure
        case .binary(let failure):
            BackupFailure(
                kind: .notConfigured,
                summary: failure.description,
                suggestedAction: "Réinstaller bran, ou renseigner le chemin du binaire kopia dans les réglages avancés.",
                rawOutput: failure.description
            )
        case .launchFailed(let underlying):
            BackupFailure(
                kind: .storage,
                summary: "kopia n'a pas pu être lancé : \(underlying)",
                suggestedAction: nil,
                rawOutput: underlying
            )
        case .noSourcePaths:
            BackupFailure(
                kind: .notConfigured,
                summary: "Aucun dossier à sauvegarder n'a été configuré.",
                suggestedAction: "Ajouter au moins un dossier à sauvegarder dans les réglages.",
                rawOutput: ""
            )
        case .emptyVersionOutput:
            BackupFailure(
                kind: .unparseable,
                summary: "« kopia --version » n'a rien écrit.",
                suggestedAction: nil,
                rawOutput: ""
            )
        case .alreadyRunning:
            BackupFailure(
                kind: .storage,
                summary: "Une commande kopia est déjà en cours sur ce pilote.",
                suggestedAction: nil,
                rawOutput: ""
            )
        case .timedOut(let command, let seconds):
            BackupFailure(
                kind: .network,
                summary: description,
                suggestedAction: "Vérifier la chaîne réseau, ou allonger « Ouverture du dépôt » dans les "
                    + "réglages de sauvegarde si la ligne est légitimement lente.",
                rawOutput: "commande « \(command) », délai total \(Int(seconds)) s"
            )
        }
    }
}

// MARK: - Le pilote

/// Lance `kopia` et rend des types de `BranBackup` — jamais du JSON, jamais
/// une ligne de log brute côté appelant.
///
/// Un `actor` plutôt qu'une classe verrouillée à la main : les commandes
/// s'exécutent l'une après l'autre par construction (`currentProcess` ne peut
/// désigner qu'un seul run), et `cancelCurrentRun()` doit pouvoir s'exécuter
/// **pendant** qu'un `createSnapshot` est suspendu à attendre la fin du
/// processus — exactement ce que permet la réentrance d'un acteur aux points
/// de suspension, sans qu'aucun verrou explicite n'ait à être posé ici.
public actor KopiaDriver {
    private let executable: KopiaExecutable
    private let configFileURL: URL?
    private let passwordProvider: KopiaPasswordProviding

    /// Réservé de façon synchrone, avant tout `await`, dès l'entrée dans
    /// `run()` — voir la note à cet endroit sur la raison précise.
    private var isRunning = false
    /// Le processus kopia en vol, le temps qu'il tourne — `nil` sinon. C'est
    /// la seule cible que connaît `cancelCurrentRun()`.
    private var currentProcess: Process?
    /// Vrai entre le moment où une annulation (utilisateur ou détection de
    /// blocage) a été demandée et la fin du `run()` qui la consomme.
    private var cancellationRequested = false
    /// Vrai quand c'est le détecteur de blocage, et non l'utilisateur, qui a
    /// mis fin au run. Distingue le message qu'affichera `createSnapshot`.
    private var stallDetected = false
    /// Vrai quand c'est le **délai total** — et non l'absence de progression,
    /// ni l'utilisateur — qui a mis fin au run. Voir ``run(arguments:needsPassword:totalTimeout:stallThreshold:onProgress:)``.
    private var totalTimeoutExpired = false

    /// La version pour laquelle ce pilote a été écrit et vérifié le
    /// 02/09/2026. Un écart n'empêche jamais de continuer — rien ici ne
    /// bloque dessus — mais mérite un signal avant qu'un changement de
    /// format de sortie ne se découvre au milieu d'une vraie sauvegarde.
    /// Voir ``matchesExpectedVersion()``.
    public static let expectedVersionPrefix = "0.23.1"

    /// Au-delà de ce silence sur stderr **sans aucune progression décodée**,
    /// `createSnapshot` considère que kopia est bloqué et met fin au run.
    ///
    /// **Fondé sur l'absence de progression, jamais sur la durée totale** :
    /// au débit mesuré vers ce MinIO (5,5 Mo/s), une première sauvegarde
    /// d'environ 600 Go dure de l'ordre de 30 heures, et un délai fondé sur
    /// la durée transformerait cette lenteur normale en fausse panne. Kopia
    /// réécrit sa ligne de progression à un rythme bien plus rapide que cette
    /// dizaine de minutes tant qu'il travaille — le silence, lui, ne dit
    /// jamais « c'est juste lent », il dit « plus rien n'avance ». Dix
    /// minutes laisse une marge large au-dessus du bruit normal (un très gros
    /// fichier isolé à hacher, un `stat` lent sur un point de montage réseau)
    /// tout en repérant un blocage bien avant qu'un humain ne perde patience.
    public static let defaultProgressStallThreshold: TimeInterval = 600

    /// Le délai **total** accordé aux commandes courtes — celles qui n'ont
    /// aucune progression à publier, donc que ``defaultProgressStallThreshold``
    /// ne protège pas.
    ///
    /// **Le trou que ce chiffre bouche.** Le chien de garde d'absence de
    /// progression ne s'arme que `if let stallThreshold, onProgress != nil` :
    /// il ne couvre donc que `snapshot create`. `repository status`, lui,
    /// n'écrit aucune progression — un dépôt qui n'accuse jamais réception
    /// (pair Tailscale endormi en plein handshake, MinIO qui accepte la
    /// connexion TCP puis se tait) laissait le `Process` suspendu **pour
    /// toujours** : l'interface reste sur « vérification de la chaîne… » et le
    /// job planifié tient le verrou de simultanéité indéfiniment, ce qui
    /// empêche aussi toutes les sauvegardes suivantes. Une seule ouverture de
    /// dépôt bloquée suffisait à arrêter la sauvegarde de ce Mac sans qu'aucun
    /// écran ne dise pourquoi.
    ///
    /// Ce défaut n'est qu'un filet : l'appelant passe normalement
    /// `BackupConfiguration.repositoryTimeout`, le réglage que l'écran affiche
    /// — et qui, jusqu'ici, n'était lu par personne.
    public static let defaultTotalTimeout: TimeInterval = 45

    public init(
        executable: KopiaExecutable,
        configFileURL: URL? = nil,
        passwordProvider: KopiaPasswordProviding
    ) {
        self.executable = executable
        self.configFileURL = configFileURL
        self.passwordProvider = passwordProvider
    }

    // MARK: - La version

    /// La sortie brute de `kopia --version` — `"0.23.1 build: … from: "`.
    ///
    /// Le délai est court à dessein : `--version` ne touche ni le réseau ni le
    /// dépôt. S'il ne répond pas en dix secondes, ce n'est pas une ligne lente,
    /// c'est un binaire qui ne va pas.
    public func version(timeout: TimeInterval = 10) async throws -> String {
        let result = try await run(
            arguments: ["--version"], needsPassword: false, totalTimeout: timeout)
        guard let text = String(data: result.stdout, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw KopiaDriverFailure.emptyVersionOutput
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Ce que la version installée vaut par rapport à celle contre laquelle ce
    /// pilote a été écrit — **trois réponses, jamais deux**.
    ///
    /// « Version non validée » et « version incompatible connue » ne se
    /// confondent pas : la première dit qu'on n'a pas éprouvé ce binaire-là et
    /// que le format de sortie pourrait avoir bougé ; la seconde dirait qu'on
    /// sait qu'il ne marchera pas. bran ne connaît aujourd'hui aucune version
    /// *incompatible* — il n'en a mesuré qu'une, `expectedVersionPrefix` — donc
    /// ce type ne rend jamais `.incompatible` de lui-même. Le cas existe pour
    /// que le jour où une version cassée est identifiée, elle se dise
    /// autrement qu'un simple « pas la même », et pour que l'écran n'ait pas à
    /// inventer cette nuance.
    public enum VersionStanding: Sendable, Equatable {
        /// Le binaire annonce exactement la version éprouvée.
        case matchesExpected(String)
        /// Une autre version. Rien ne prouve qu'elle est cassée — kopia garde
        /// une compatibilité de dépôt ascendante — mais rien ne prouve non
        /// plus que le format de ses sorties est celui que les décodeurs de
        /// `BranBackup` savent lire.
        case unvalidated(found: String, expected: String)
        /// Une version dont on sait qu'elle ne marche pas avec ce pilote.
        case incompatible(found: String, reason: String)
        /// La version n'a pas pu être lue du tout : binaire absent, non
        /// exécutable, ou muet. Distinct des trois ci-dessus — on ne sait pas.
        case unreadable(String)
    }

    /// Vrai quand la version installée correspond à celle attendue. Ne lève
    /// jamais sur un simple écart : c'est à l'appelant de décider quoi en
    /// faire (avertir, journaliser) — cette fonction ne fait que mesurer.
    public func matchesExpectedVersion() async throws -> Bool {
        try await version().hasPrefix(Self.expectedVersionPrefix)
    }

    /// La même mesure, mais qui ne lève jamais et qui **nomme** ce qu'elle a
    /// trouvé. C'est celle que l'application appelle : un pilote qui lève au
    /// démarrage parce que le binaire n'est pas là empêcherait d'afficher
    /// l'écran qui explique justement que le binaire n'est pas là.
    public func versionStanding() async -> VersionStanding {
        do {
            let found = try await version()
            if found.hasPrefix(Self.expectedVersionPrefix) {
                return .matchesExpected(found)
            }
            return .unvalidated(found: found, expected: Self.expectedVersionPrefix)
        } catch {
            return .unreadable(String(describing: error))
        }
    }

    // MARK: - Le statut du dépôt

    /// - Parameter timeout: le délai **total** au-delà duquel la commande est
    ///   arrêtée. Vient normalement de `BackupConfiguration.repositoryTimeout`
    ///   — voir ``defaultTotalTimeout`` pour ce que son absence coûtait.
    public func repositoryStatus(
        timeout: TimeInterval = KopiaDriver.defaultTotalTimeout
    ) async throws -> RepositoryStatus {
        let result = try await run(
            arguments: ["repository", "status", "--json", "--no-progress"],
            needsPassword: true,
            totalTimeout: timeout
        )
        if result.totalTimeoutExpired {
            throw KopiaDriverFailure.timedOut(command: "repository status", seconds: timeout)
        }
        if let failure = classifiedFailure(from: result) {
            throw KopiaDriverFailure.backup(failure)
        }
        if let failure = overflowFailure(result, command: "repository status") {
            throw KopiaDriverFailure.backup(failure)
        }
        // Le garde-fou qui referme le piège du mot de passe invalide : kopia
        // sort avec le code 0 et n'écrit rien sur stdout dans ce cas précis,
        // et `classify` ci-dessus n'a pas forcément reconnu le texte exact
        // d'une version future de kopia. Un stdout vide en sortie de
        // `repository status` n'est **jamais** un dépôt sain : la commande
        // rend toujours un objet, même pour un dépôt tout juste créé.
        guard !result.stdout.isEmpty else {
            throw KopiaDriverFailure.backup(emptyStdoutFailure(
                summary: "kopia n'a rien écrit sur stdout en ouvrant le dépôt, sans qu'aucune erreur reconnue ne l'explique.",
                result: result,
                link: .repositoryOpens
            ))
        }
        do {
            return try KopiaManifest.decodeRepositoryStatus(result.stdout)
        } catch let decodingFailure as KopiaDecodingFailure {
            throw KopiaDriverFailure.backup(decodingFailure.asBackupFailure(rawOutput: maskedStdoutText(result)))
        }
    }

    // MARK: - La liste des snapshots

    public func listSnapshots(
        timeout: TimeInterval = KopiaDriver.defaultTotalTimeout
    ) async throws -> [SnapshotProof] {
        let result = try await run(
            arguments: ["snapshot", "list", "--all", "--json", "--no-progress"],
            needsPassword: true,
            totalTimeout: timeout
        )
        if result.totalTimeoutExpired {
            throw KopiaDriverFailure.timedOut(command: "snapshot list", seconds: timeout)
        }
        if let failure = classifiedFailure(from: result) {
            throw KopiaDriverFailure.backup(failure)
        }
        if let failure = overflowFailure(result, command: "snapshot list") {
            throw KopiaDriverFailure.backup(failure)
        }
        // **Pas de garde « stdout vide = échec » ici.** Un dépôt sain sans
        // aucun snapshot rend un stdout vide ou `[]` selon la version — vécu
        // tel quel sur ce Mac le 02/09/2026 — et `decodeSnapshotList` le sait
        // déjà. Ajouter le même garde-fou que `repositoryStatus` ici
        // transformerait un dépôt tout neuf en fausse panne, exactement le
        // défaut inverse de celui que ce fichier existe pour fermer.
        do {
            return try KopiaManifest.decodeSnapshotList(result.stdout)
        } catch let decodingFailure as KopiaDecodingFailure {
            throw KopiaDriverFailure.backup(decodingFailure.asBackupFailure(rawOutput: maskedStdoutText(result)))
        }
    }

    // MARK: - Les règles d'exclusion

    /// Écrit les règles d'exclusion de la configuration dans la **politique
    /// kopia** de chaque source, avant de sauvegarder.
    ///
    /// ## Pourquoi ça ne peut pas être un drapeau de `snapshot create`
    ///
    /// `kopia snapshot create` n'en a aucun : mesuré dans l'aide de kopia
    /// 0.23.1, l'exclusion se règle exclusivement par la politique du dépôt
    /// (`kopia policy set <source> --add-ignore=…`). Tant que personne ne
    /// l'appelait, `BackupConfiguration.ignoreRules` était un réglage
    /// **mort** : l'écran le proposait, le disque le conservait, et
    /// `createSnapshot` construisait `["snapshot", "create", "--json",
    /// "--progress"] + paths` sans jamais le lire. Un dossier explicitement
    /// exclu partait quand même dans le dépôt — et un utilisateur qui exclut
    /// un dossier a en général une raison qui n'est pas la place disque.
    ///
    /// ## Pourquoi `--clear-ignore` d'abord, à chaque fois
    ///
    /// La politique kopia est **persistante dans le dépôt**, pas dans
    /// `config.json` : elle survit à une désinstallation de bran. Sans remise à
    /// zéro, une règle retirée de l'écran resterait active pour toujours dans
    /// le dépôt, et l'écran mentirait dans l'autre sens — il n'afficherait plus
    /// une exclusion qui, elle, s'appliquerait encore. `--clear-ignore` puis
    /// les `--add-ignore` de la configuration font que la politique du dépôt
    /// est, à chaque run, exactement ce que l'écran montre.
    ///
    /// ## Pourquoi un échec ici arrête le run
    ///
    /// Cette fonction lève, et son appelant ne rattrape pas. Sauvegarder
    /// quand même, avec une politique qu'on n'a pas su écrire, enverrait dans
    /// le dépôt les dossiers que l'utilisateur avait demandé d'en tenir
    /// dehors — une fuite silencieuse, pas une simple imprécision.
    public func applyIgnoreRules(
        _ rules: [String],
        to paths: [String],
        timeout: TimeInterval = KopiaDriver.defaultTotalTimeout
    ) async throws {
        guard !paths.isEmpty else { return }
        // Les motifs vides sont écartés ici plutôt qu'envoyés à kopia : un
        // `--add-ignore=` sans valeur est accepté par kingpin et poserait une
        // règle vide dans la politique du dépôt, invisible dans l'écran qui
        // filtre déjà les lignes vides.
        let patterns = rules.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }

        for path in paths {
            var arguments = ["policy", "set", "--no-progress", "--clear-ignore"]
            arguments += patterns.map { "--add-ignore=\($0)" }
            arguments.append(path)

            let result = try await run(
                arguments: arguments, needsPassword: true, totalTimeout: timeout)
            if result.totalTimeoutExpired {
                throw KopiaDriverFailure.timedOut(command: "policy set", seconds: timeout)
            }
            // **`KopiaFailureClassifier` n'est délibérément pas appelé ici**,
            // seul endroit de ce fichier où il ne l'est pas.
            //
            // Il a été écrit pour `snapshot create`, `repository status` et
            // `snapshot list` : tout ce qu'il ne reconnaît pas et qui n'est pas
            // du bruit connu (`isIgnorable`) devient `.unparseable`, par
            // doctrine — ne jamais interpréter au bénéfice du doute. Or
            // `policy set` écrit son résumé de politique sur stderr en marche
            // **normale**, dans un format qu'aucun de ses motifs ne connaît :
            // le passer au classifieur ferait échouer chaque écriture réussie,
            // donc chaque sauvegarde, sur une politique parfaitement écrite.
            // Le remède serait pire que le mal qu'il ferme.
            //
            // Le code de sortie suffit ici, contrairement à `repository
            // status` : le cas mesuré où kopia sort en 0 en ayant échoué est
            // celui du mauvais mot de passe sur `repository status`, et ce
            // cas-là est de toute façon rattrapé à la commande suivante — le
            // `snapshot create` qui suit immédiatement ne s'ouvrira pas
            // davantage.
            guard result.exitCode == 0 else {
                throw KopiaDriverFailure.backup(BackupFailure(
                    kind: .unparseable,
                    summary: "Les règles d'exclusion n'ont pas pu être appliquées à « \(path) » "
                        + "(kopia est sorti avec le code \(result.exitCode)).",
                    suggestedAction: "Corriger ou vider les règles d'exclusion dans les réglages de "
                        + "sauvegarde : bran refuse de sauvegarder tant qu'il n'est pas sûr que ce qui "
                        + "doit être exclu le sera.",
                    rawOutput: KopiaFailureClassifier.maskSecrets(in: result.stderr)
                ))
            }
        }
    }

    // MARK: - La sauvegarde

    /// Lance `kopia snapshot create` et rend son manifeste, avec `origin ==
    /// .reportedByCreate` — **jamais** `.confirmedInRepository` : cette
    /// fonction ne relit pas le dépôt après coup, elle ne fait que rapporter
    /// ce que le processus qui vient de terminer croit avoir écrit. C'est à
    /// l'appelant (la machine à états) d'appeler ensuite ``listSnapshots()``
    /// pour obtenir la preuve qui vaut vraiment, comme le décrit
    /// `BackupPhase.verifying`.
    public func createSnapshot(
        paths: [String],
        stallThreshold: TimeInterval = KopiaDriver.defaultProgressStallThreshold,
        onProgress: @escaping @Sendable (BackupProgress) -> Void
    ) async throws -> SnapshotProof {
        guard !paths.isEmpty else {
            throw KopiaDriverFailure.noSourcePaths
        }

        // `--progress` explicite, comme chaque drapeau de cette commande :
        // compter sur un défaut de kopia qui pourrait changer d'une version
        // à l'autre laisserait la progression disparaître sans qu'aucun test
        // ne le remarque avant une vraie sauvegarde. Les sources en dernier,
        // après les drapeaux : c'est l'ordre que l'usage de kopia lui-même
        // documente (`kopia snapshot create [<flags>] [<source>...]`).
        //
        // **Aucun délai global sur cette commande.** Au débit mesuré vers ce
        // MinIO (5,5 Mo/s), ~600 Go durent de l'ordre de 30 heures : un délai
        // fondé sur la durée transformerait cette lenteur normale en fausse
        // panne. La seule protection est `stallThreshold`, fondée sur
        // l'absence de progression — voir ``defaultProgressStallThreshold``.
        let arguments = ["snapshot", "create", "--json", "--progress"] + paths

        let result = try await run(
            arguments: arguments,
            needsPassword: true,
            stallThreshold: stallThreshold,
            onProgress: onProgress
        )

        // Le blocage détecté prime sur tout le reste : le processus a bien
        // été terminé par un signal (SIGTERM, ou SIGKILL après le délai de
        // grâce), donc `classifiedFailure` le classerait de toute façon en
        // `.interrupted` générique — mais avec un message qui parlerait
        // d'une annulation, ce qu'aucun utilisateur n'a demandée ici.
        if result.stallDetected {
            throw KopiaDriverFailure.backup(BackupFailure(
                kind: .interrupted,
                summary: "Aucune progression depuis plus de \(Int(stallThreshold / 60)) minutes : "
                    + "kopia a été arrêté. La sauvegarde reprendra au prochain lancement — la "
                    + "déduplication rendra la reprise bon marché.",
                suggestedAction: nil,
                rawOutput: KopiaFailureClassifier.maskSecrets(in: result.stderr),
                link: nil
            ))
        }

        // **Le manifeste d'abord, le diagnostic ensuite — et cet ordre est la
        // doctrine de l'écran Sauvegarde, pas une commodité.**
        //
        // « Ce que Kopia a réellement écrit dans le dépôt, jamais ce qu'il
        // croit avoir écrit. » Un manifeste décodable sur stdout **est** ce
        // que kopia a écrit : il porte l'identifiant du snapshot, sa taille,
        // ses compteurs d'erreurs. Rien sur stderr, ni un code de sortie, ne
        // peut le contredire — au mieux ils l'expliquent.
        //
        // L'ordre était inverse, et il a coûté la première sauvegarde réussie
        // de ce Mac. Relevé le 02/09/2026 : 1 571 967 fichiers, 70 minutes,
        // snapshot `k89c30b3c…` relu sans erreur par `snapshot verify` sur
        // 1 448 825 objets. Kopia sort en code non nul dès qu'il a ignoré des
        // erreurs de lecture — ce que la politique lui demande de faire — donc
        // `classifiedFailure` levait, et le manifeste posé juste à côté sur
        // stdout n'était jamais lu. L'écran affichait « message non
        // interprété » au-dessus d'une sauvegarde parfaitement utilisable.
        //
        // Le compte des fichiers sautés n'est pas perdu pour autant : il est
        // dans le manifeste, ``SnapshotProof/isComplete`` exige qu'il soit
        // nul, et l'appelant dira « incomplète, et voilà de combien ». C'est
        // la place juste pour ce chiffre — pas un échec sans nom.
        //
        // Un stdout tronqué est exclu de cette porte : un préfixe de JSON
        // n'est pas un manifeste, et `overflowFailure` reste seul juge.
        if result.stdoutOverflowed == false,
           result.stdout.isEmpty == false,
           let manifest = try? KopiaManifest.decodeCreatedSnapshot(result.stdout) {
            return manifest
        }

        // Pas de manifeste exploitable : c'est seulement maintenant qu'il faut
        // chercher pourquoi.
        if let failure = classifiedFailure(from: result) {
            throw KopiaDriverFailure.backup(failure)
        }
        if let failure = overflowFailure(result, command: "snapshot create") {
            throw KopiaDriverFailure.backup(failure)
        }
        guard !result.stdout.isEmpty else {
            throw KopiaDriverFailure.backup(emptyStdoutFailure(
                summary: "kopia s'est terminé sans erreur reconnue, mais sans manifeste de snapshot sur stdout.",
                result: result,
                link: nil
            ))
        }

        // **Rendu tel quel, complet ou non — décision volontaire.** Un
        // manifeste avec `errorCount > 0` n'est pas une panne de cette
        // fonction : kopia a fini, il a bien écrit un snapshot, il dit
        // lui-même combien de fichiers il a sautés. Le transformer ici en
        // échec ferait disparaître l'`id` et les statistiques du manifeste —
        // exactement ce qu'un utilisateur veut voir sur un snapshot qui
        // existe mais qu'il faut examiner, pas un texte d'erreur générique
        // sans rien pour le retrouver. `BackupAttempt` porte `proof` et
        // `failure` comme deux champs indépendants précisément pour ce cas ;
        // c'est à l'appelant de lire ``SnapshotProof/isComplete`` (donc
        // ``SnapshotProof/isTrustworthy``, qui l'exige) et de décider, avec
        // `KopiaFailureClassifier.partialSnapshotFailure` à disposition pour
        // formuler le message s'il choisit d'en faire un échec affiché.
        // **Ce que cette fonction refuse, en revanche, c'est un manifeste
        // absent** — voir le garde-fou sur `result.stdout.isEmpty` ci-dessus
        // : un stdout vide n'est jamais un succès, complet ou non.
        do {
            return try KopiaManifest.decodeCreatedSnapshot(result.stdout)
        } catch let decodingFailure as KopiaDecodingFailure {
            throw KopiaDriverFailure.backup(decodingFailure.asBackupFailure(rawOutput: maskedStdoutText(result)))
        }
    }

    // MARK: - La vérification

    /// La sortie brute (texte) de `kopia snapshot verify`.
    ///
    /// **Pas de `--json` ici, à dessein** — cette sous-commande en propose un
    /// dans l'aide de kopia 0.23.1, mais la sortie relevée le 02/09/2026 sur
    /// ce Mac, celle que `KopiaFailureClassifier` sait reconnaître comme
    /// bruit inoffensif (`isIgnorable`, préfixes `"Processed "` /
    /// `"Finished processing "`), est le texte qu'on obtient sans lui. Suivre
    /// le relevé réel plutôt que l'aide de la commande.
    /// - Parameter timeout: le délai **total**. Beaucoup plus large que celui
    ///   d'une ouverture de dépôt : `snapshot verify` relit les métadonnées de
    ///   tous les snapshots, ce qui se compte en minutes sur un dépôt fourni,
    ///   pas en secondes. Mais borné quand même — sans borne, cette commande
    ///   n'a aucune progression à publier et rejouerait exactement le blocage
    ///   décrit dans ``defaultTotalTimeout``.
    public func verify(timeout: TimeInterval = 900) async throws -> String {
        let result = try await run(
            arguments: ["snapshot", "verify", "--no-progress"],
            needsPassword: true,
            totalTimeout: timeout
        )
        if result.totalTimeoutExpired {
            throw KopiaDriverFailure.timedOut(command: "snapshot verify", seconds: timeout)
        }
        if let failure = classifiedFailure(from: result) {
            throw KopiaDriverFailure.backup(failure)
        }
        return result.stderr
    }

    // MARK: - L'annulation

    /// Termine proprement le run en cours, s'il y en a un. Ne lève jamais :
    /// annuler un run déjà fini, ou appeler ceci hors de tout run, ne fait
    /// rien.
    public func cancelCurrentRun() async {
        guard let process = currentProcess else { return }
        cancellationRequested = true
        await terminateGracefully(process)
    }

    /// SIGTERM d'abord, SIGKILL seulement après un délai de grâce.
    ///
    /// **Kopia intercepte SIGTERM pour fermer proprement ses index locaux
    /// avant de sortir.** Le tuer directement par SIGKILL lui retirerait
    /// cette chance et risquerait de laisser un état local incohérent, que
    /// la prochaine ouverture du dépôt devrait détecter et réparer. Kopia est
    /// conçu pour être repris : un run tué reprend au suivant grâce à la
    /// déduplication par contenu, ce qui rend cette interruption bon marché à
    /// rattraper plutôt que dangereuse. `SIGKILL` n'est que le filet de
    /// sécurité pour un process qui n'aurait pas obtempéré — jamais observé
    /// ici, mais sans ce filet un process récalcitrant bloquerait
    /// `cancelCurrentRun()` pour toujours.
    ///
    /// `Process.terminate()` envoie SIGTERM, pas SIGKILL — c'est le
    /// comportement documenté de `Process` sur Darwin, et c'est pour ça que
    /// le filet de sécurité en dessous appelle `kill(_:SIGKILL)` directement
    /// : `Process` n'expose aucune API pour envoyer SIGKILL lui-même.
    private func terminateGracefully(_ process: Process, gracePeriod: TimeInterval = 5) async {
        guard process.isRunning else { return }
        process.terminate()
        try? await Task.sleep(nanoseconds: UInt64(max(0, gracePeriod) * 1_000_000_000))
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }

    private func markStalled(process: Process) async {
        guard process.isRunning else { return }
        stallDetected = true
        cancellationRequested = true
        await terminateGracefully(process)
    }

    /// Le délai total est écoulé : on arrête, en le distinguant d'une
    /// annulation utilisateur et d'un blocage sans progression, parce que les
    /// trois n'appellent pas le même message.
    private func markTotalTimeout(process: Process) async {
        guard process.isRunning else { return }
        totalTimeoutExpired = true
        cancellationRequested = true
        await terminateGracefully(process)
    }

    // MARK: - Le classement d'un résultat

    private func classifiedFailure(from result: ProcessResult) -> BackupFailure? {
        KopiaFailureClassifier.classify(
            stderr: result.stderr,
            exitCode: result.exitCode,
            wasCancelled: result.wasCancelled,
            signal: result.signal
        )
    }

    /// stdout a dépassé son plafond : les octets reçus sont un préfixe, pas un
    /// document. Les décoder rendrait au mieux une erreur de syntaxe, au pire
    /// un objet partiel qu'un décodeur indulgent accepterait — c'est-à-dire
    /// une preuve fabriquée sur une sortie qu'on n'a pas lue en entier. On
    /// refuse à la place.
    private func overflowFailure(_ result: ProcessResult, command: String) -> BackupFailure? {
        guard result.stdoutOverflowed else { return nil }
        return BackupFailure(
            kind: .unparseable,
            summary: "« kopia \(command) » a écrit plus de "
                + "\(BoundedOutputBuffer.defaultStdoutLimit / (1024 * 1024)) Mo sur sa sortie standard : "
                + "bran a cessé de l'accumuler et refuse de décoder un document tronqué.",
            suggestedAction: "Vérifier que le binaire kopia utilisé est bien celui du paquet de bran.",
            rawOutput: KopiaFailureClassifier.maskSecrets(in: result.stderr)
        )
    }

    private func emptyStdoutFailure(summary: String, result: ProcessResult, link: ChainLink?) -> BackupFailure {
        BackupFailure(
            kind: .unparseable,
            summary: summary,
            suggestedAction: "Copier le journal brut ci-dessous : ce cas n'est pas encore reconnu par bran.",
            rawOutput: KopiaFailureClassifier.maskSecrets(in: result.stderr),
            link: link
        )
    }

    /// Le texte de stdout, tel qu'un échec de décodage doit le montrer :
    /// c'est lui qui a échoué à se lire, pas stderr. Masqué par précaution
    /// même si aucun secret n'y est attendu — le coût est nul, la fuite
    /// qu'il évite ne l'est pas.
    private func maskedStdoutText(_ result: ProcessResult) -> String {
        let text = String(data: result.stdout, encoding: .utf8)
            ?? "<sortie non-UTF8, \(result.stdout.count) octets>"
        return KopiaFailureClassifier.maskSecrets(in: text)
    }

    // MARK: - Exécuter kopia

    /// Ce qu'un run a produit, sans jugement dessus — c'est aux appelants de
    /// ``run(arguments:needsPassword:stallThreshold:onProgress:)`` de décider
    /// ce que ces octets veulent dire.
    private struct ProcessResult {
        var exitCode: Int32
        var stdout: Data
        /// Texte, jamais brut : ces octets ont été décodés une seule fois,
        /// depuis le tampon complet, jamais recollés à partir de fragments
        /// dont un caractère multi-octets aurait pu être coupé en deux.
        var stderr: String
        var wasCancelled: Bool
        var signal: Int32?
        var stallDetected: Bool
        var totalTimeoutExpired: Bool
        /// Vrai quand stdout a dépassé le plafond de `BoundedOutputBuffer` :
        /// les octets rendus sont alors **incomplets**, et aucun décodeur ne
        /// doit les lire comme s'ils étaient entiers.
        var stdoutOverflowed: Bool
    }

    /// Construit les arguments, l'environnement, lance `kopia`, et attend —
    /// en lisant stdout et stderr au fil de l'eau — qu'il ait vraiment fini :
    /// processus terminé **et** les deux tuyaux vidés jusqu'à leur `EOF`, pas
    /// seulement le premier des deux à se manifester. Un dernier paquet de
    /// stderr peut arriver après que `terminationHandler` se soit déclenché ;
    /// attendre les trois signaux (fin de process, EOF stdout, EOF stderr)
    /// avant de rendre la main est ce qui garantit qu'aucune ligne n'est
    /// perdue dans cette course.
    ///
    /// - Parameter totalTimeout: le délai au-delà duquel la commande est
    ///   arrêtée quoi qu'il arrive. **Jamais passé par `createSnapshot`** —
    ///   voir la note dans cette fonction : au débit mesuré vers ce MinIO
    ///   (5,5 Mo/s), ~600 Go durent une trentaine d'heures, et un délai fondé
    ///   sur la durée transformerait cette lenteur normale en fausse panne.
    ///   Pour toutes les autres commandes, à l'inverse, il n'existe **aucune**
    ///   autre protection : `stallThreshold` ne s'arme que si `onProgress` est
    ///   fourni, ce qu'elles ne font pas.
    private func run(
        arguments: [String],
        needsPassword: Bool,
        totalTimeout: TimeInterval? = nil,
        stallThreshold: TimeInterval? = nil,
        onProgress: (@Sendable (BackupProgress) -> Void)? = nil
    ) async throws -> ProcessResult {
        // **Réservé ici, avant le premier `await`, et pas seulement en
        // comparant `currentProcess` à `nil`.** `currentProcess` n'est posé
        // qu'après le lancement effectif du processus, plus bas — entre ce
        // point et ce lancement, `passwordProvider.kopiaPassword()` suspend
        // cette fonction. Un acteur redonne la main à un autre appelant à
        // chaque suspension : un deuxième `run()` lancé pendant cette
        // attente verrait, lui aussi, `currentProcess == nil` et passerait le
        // même garde-fou, avant qu'aucun des deux n'ait eu la chance de
        // réserver quoi que ce soit. Les deux processus kopia se
        // lanceraient alors réellement, et le second à écrire
        // `currentProcess` écraserait la cible d'annulation du premier — le
        // garde-fou existerait sur le papier sans rien empêcher. `isRunning`
        // se pose ici, avant tout `await`, dans le même tronçon synchrone que
        // la vérification : aucune autre méthode de cet acteur ne peut
        // s'intercaler entre les deux.
        guard !isRunning else {
            throw KopiaDriverFailure.alreadyRunning
        }
        isRunning = true
        defer { isRunning = false }

        cancellationRequested = false
        stallDetected = false
        totalTimeoutExpired = false

        var fullArguments: [String] = []
        if let configFileURL {
            fullArguments += ["--config-file", configFileURL.path(percentEncoded: false)]
        }
        fullArguments += arguments

        // On part de l'environnement hérité plutôt que d'en construire un
        // minimal : kopia s'appuie sur `HOME`/`TMPDIR` pour son cache de
        // contenu local même quand `--config-file` lui dit où trouver le
        // dépôt, et priver le processus de ces variables casserait des
        // choses que ce fichier n'a aucune raison de connaître en détail.
        var environment = ProcessInfo.processInfo.environment
        if needsPassword {
            environment["KOPIA_PASSWORD"] = try await passwordProvider.kopiaPassword()
        }

        let process = Process()
        process.executableURL = executable.url
        process.arguments = fullArguments
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let collector = OutputCollector(onProgress: onProgress)
        let terminationBox = TerminationBox()

        // Un compte à trois : fin de process, EOF stdout, EOF stderr. Les
        // trois doivent être passés avant de considérer ce run terminé —
        // voir la note au-dessus de cette fonction sur la course entre
        // `terminationHandler` et le dernier paquet en vol sur un tuyau.
        let group = DispatchGroup()
        group.enter()
        group.enter()
        group.enter()

        process.terminationHandler = { finished in
            terminationBox.exitCode = finished.terminationStatus
            terminationBox.reason = finished.terminationReason
            group.leave()
        }

        // **Le cœur du contournement de l'interblocage.** `availableData`
        // bloque jusqu'à au moins un octet ou l'`EOF` du tuyau, mais elle le
        // fait sur la file d'exécution de `Process`, pas sur celle-ci : le
        // processus kopia peut donc continuer à écrire pendant que ce
        // gestionnaire vide le tuyau au fur et à mesure, au lieu d'attendre
        // que kopia ait fini pour commencer à lire — ce qui est justement le
        // scénario qui interbloque.
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                group.leave()
            } else {
                collector.appendStdout(data)
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                group.leave()
            } else {
                collector.appendStderr(data)
            }
        }

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw KopiaDriverFailure.launchFailed(underlying: error.localizedDescription)
        }

        currentProcess = process
        defer { currentProcess = nil }

        // Le détecteur de blocage : seulement quand `onProgress` est fourni,
        // c'est-à-dire seulement pour `createSnapshot` — les autres commandes
        // sont courtes et n'ont pas cette exposition à un blocage de trente
        // heures. Vérifié à un rythme largement plus lent que le seuil lui-
        // même, pour ne jamais devenir la cause d'une fausse alerte.
        let watchdogTask: Task<Void, Never>?
        if let stallThreshold, onProgress != nil {
            let processBox = ProcessBox(process)
            watchdogTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 30_000_000_000)
                    if Task.isCancelled { return }
                    guard let self else { return }
                    let elapsed = Date().timeIntervalSince(collector.lastProgressAt)
                    if elapsed > stallThreshold {
                        await self.markStalled(process: processBox.process)
                        return
                    }
                }
            }
        } else {
            watchdogTask = nil
        }
        defer { watchdogTask?.cancel() }

        // Le délai total, pour les commandes que le détecteur de blocage ne
        // couvre pas. Une tâche distincte de celle du blocage, et pas un
        // paramètre de plus sur la même : les deux mesurent des choses
        // différentes (une horloge absolue contre un silence de progression)
        // et peuvent parfaitement coexister sur une commande qui aurait les
        // deux — ce qui n'est le cas d'aucune aujourd'hui, mais le jour où ça
        // arrivera, rien ne sera à démêler.
        let deadlineTask: Task<Void, Never>?
        if let totalTimeout {
            let processBox = ProcessBox(process)
            deadlineTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(0, totalTimeout) * 1_000_000_000))
                if Task.isCancelled { return }
                guard let self else { return }
                await self.markTotalTimeout(process: processBox.process)
            }
        } else {
            deadlineTask = nil
        }
        defer { deadlineTask?.cancel() }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            group.notify(queue: .global()) { continuation.resume() }
        }

        let signal = terminationBox.reason == .uncaughtSignal ? terminationBox.exitCode : nil
        let wasCancelled = cancellationRequested
        let wasStalled = stallDetected
        let didTimeOut = totalTimeoutExpired
        cancellationRequested = false
        stallDetected = false
        totalTimeoutExpired = false

        return ProcessResult(
            exitCode: terminationBox.exitCode,
            stdout: collector.stdoutData,
            stderr: collector.stderrText,
            wasCancelled: wasCancelled,
            signal: signal,
            stallDetected: wasStalled,
            totalTimeoutExpired: didTimeOut,
            stdoutOverflowed: collector.stdoutOverflowed
        )
    }
}

// MARK: - Les petites boîtes qui traversent la frontière de concurrence

/// Ce que `terminationHandler` dépose, lu par l'acteur seulement après que
/// `group.notify` a confirmé que ce dépôt a bien eu lieu — l'ordonnancement
/// du `DispatchGroup` fait office de barrière mémoire entre les deux.
private final class TerminationBox: @unchecked Sendable {
    var exitCode: Int32 = 0
    var reason: Process.TerminationReason = .exit
}

/// `Process` n'est pas `Sendable`, mais doit pouvoir être capturé dans la
/// tâche du détecteur de blocage, qui vit hors de l'isolation de l'acteur le
/// temps de vérifier périodiquement une horloge. La boîte ne fait rien d'autre
/// que porter la référence à travers cette frontière ; elle n'est jamais
/// utilisée pour lire ou écrire un état partagé sans passer par l'acteur.
private final class ProcessBox: @unchecked Sendable {
    let process: Process
    init(_ process: Process) { self.process = process }
}

/// Accumule stdout et stderr pendant qu'un run tourne, et pousse chaque
/// morceau de stderr dans `KopiaProgressReader` pour en tirer la progression
/// en direct.
///
/// **Pourquoi une classe verrouillée, et pas un état sur l'acteur.**
/// `readabilityHandler` s'exécute hors de l'isolation de `KopiaDriver`, sur
/// la file interne de `Process` — y faire entrer chaque paquet reçu
/// obligerait à sauter sur l'acteur à chaque appel (`Task { await … }`), ce
/// qui réordonnerait des paquets qui doivent impérativement rester dans
/// l'ordre où le tuyau les a livrés : `KopiaProgressReader` dépend de cet
/// ordre pour recoller une ligne coupée en plein milieu. Un verrou simple,
/// tenu le temps d'un `append`, ne pose pas ce problème parce qu'il ne
/// réordonne rien — il protège seulement les octets accumulés.
///
/// **Les deux tampons sont plafonnés** — voir `BoundedOutputBuffer` pour le
/// chiffre et pour la panne : un `snapshot create` de trente heures écrit
/// assez de lignes de progression sur stderr pour que « tout garder » se
/// compte en gigaoctets résidents.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let stdout = BoundedOutputBuffer.stdout()
    private let stderr = BoundedOutputBuffer.stderr()
    private var progressReader = KopiaProgressReader()
    private var lastProgress = Date()
    private let onProgress: (@Sendable (BackupProgress) -> Void)?

    init(onProgress: (@Sendable (BackupProgress) -> Void)?) {
        self.onProgress = onProgress
    }

    func appendStdout(_ data: Data) {
        stdout.append(data)
    }

    func appendStderr(_ data: Data) {
        stderr.append(data)

        // **Le chien de garde se réarme sur toute sortie, jamais sur les
        // seules lignes que le lecteur a su décoder.**
        //
        // Deux fois déjà, un run parfaitement sain a été tué parce qu'une
        // ligne de progression avait changé de forme sans que rien ne
        // s'arrête : d'abord l'unité `TB` absente du `switch`, puis le
        // suffixe `(127 errors ignored)` accolé au champ `uploaded`. Dans les
        // deux cas Kopia écrivait, travaillait, envoyait des gigaoctets — et
        // `lastProgress` restait figé parce que `parse(line:)` rendait `nil`.
        // Lier la preuve de vie à la fidélité du parseur, c'est faire d'un
        // défaut d'affichage une panne de sauvegarde.
        //
        // Ce que le contrat dit vraiment, et qui ne dépend d'aucun format :
        // « le silence ne dit jamais "c'est juste lent", il dit "plus rien
        // n'avance" ». Un octet reçu sur stderr est une preuve de vie ; sa
        // lisibilité est une autre question, qui a le droit d'échouer sans
        // tuer le run. `lastProgress` mesure donc désormais le silence, ce
        // qu'il aurait toujours dû mesurer.
        lock.lock()
        lastProgress = Date()
        lock.unlock()

        guard let onProgress else { return }
        // Décodage indulgent, uniquement pour cette lecture en direct : un
        // paquet peut couper une séquence UTF-8 multi-octets en plein milieu
        // (un chemin accentué dans la bannière « Snapshotting … »). Les
        // champs que `KopiaProgressReader` sait vraiment lire — chiffres,
        // unités, mots anglais — sont tous ASCII et jamais affectés ; une
        // coupure ne peut abîmer qu'un fragment de texte que le lecteur de
        // progression ignore de toute façon. Le texte qui compte pour de
        // vrai — celui qu'on classe en échec — est redécodé une seule fois à
        // la fin, depuis `stderrText`, jamais depuis ces fragments.
        let chunkText = String(decoding: data, as: UTF8.self)
        lock.lock()
        let progresses = progressReader.accept(chunkText)
        lock.unlock()
        for progress in progresses { onProgress(progress) }
    }

    var stdoutData: Data {
        stdout.snapshot()
    }

    var stdoutOverflowed: Bool {
        stdout.didOverflow
    }

    /// Décodé une seule fois, depuis les octets complets — jamais recollé à
    /// partir des fragments passés à `KopiaProgressReader` en direct. Un
    /// texte qui n'est pas de l'UTF-8 valide devient un texte qui le dit :
    /// jamais un décodage silencieusement approximatif pour ce qui alimente
    /// `KopiaFailureClassifier` et peut finir affiché comme diagnostic.
    var stderrText: String {
        stderr.text()
    }

    var lastProgressAt: Date {
        lock.lock(); defer { lock.unlock() }
        return lastProgress
    }
}
