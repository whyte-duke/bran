import BranBackup
import Darwin
import Foundation
import Security

/// Deux façons d'obtenir une `BackupConfiguration` provisionnée : la tirer du
/// dépôt Kopia déjà connecté sur ce Mac (a), ou la saisir à la main pour une
/// autre machine — typiquement celle du frère du propriétaire, avec **son**
/// seau, **ses** clés, **son** mot de passe de dépôt (b).
///
/// **Aucun des deux chemins n'écrit un secret sans l'avoir vérifié.** Écrire
/// des identifiants qui ont l'air bons et qui ne marchent pas, c'est fabriquer
/// la panne que ce projet combat depuis son premier octet — voir l'en-tête de
/// `BackupContract.swift`. Les deux fonctions publiques d'écriture appellent
/// donc `KopiaDriver.repositoryStatus()` avant de considérer quoi que ce soit
/// comme acquis, et annulent tout ce qu'elles ont écrit — Trousseau compris —
/// si ce dépôt-là ne s'ouvre pas.
///
/// **Dépendance non résolue à la date d'écriture de ce fichier.** `KopiaDriver`
/// est écrit par un autre agent, en parallèle. Ce fichier l'appelle par la
/// seule signature donnée dans le briefing commun,
/// `KopiaDriver.repositoryStatus() async throws -> RepositoryStatus`, lue sur
/// `RepositoryStatus` dans `BackupContract.swift` — et ne compilera pas tant
/// que ce type n'existe pas. Voir le rapport de cet agent.
enum BackupProvisioning {

    // MARK: - a) Importer la configuration Kopia existante

    /// Ce que l'import a appris, une fois `secretAccessKey` ôté vers le
    /// Trousseau et le mot de passe de dépôt cherché.
    struct ImportOutcome {
        var configuration: BackupConfiguration
        /// Ce que `KopiaDriver.repositoryStatus()` a confirmé du dépôt —
        /// affiché à l'utilisateur pour qu'il vérifie que c'est bien *son*
        /// seau, pas seulement qu'un dépôt quelconque s'est ouvert.
        var verifiedStatus: RepositoryStatus
    }

    /// Lit `~/Library/Application Support/kopia/repository.config`, dépose la
    /// clé secrète S3 au Trousseau, cherche le mot de passe de dépôt dans
    /// celui de KopiaUI, et **vérifie que le dépôt s'ouvre** avant d'activer
    /// quoi que ce soit.
    ///
    /// Lance `ProvisioningFailure.repositoryPasswordNotRecovered` quand le
    /// mot de passe n'a pas été retrouvé — la clé S3 et la configuration
    /// réseau restent alors écrites, mais désactivées, en attendant qu'on
    /// fournisse ce mot de passe par un autre canal (`--backup-provision`, ou
    /// un futur écran de réglages).
    static func importFromExistingKopiaConfiguration() throws -> ImportOutcome {
        let url = try kopiaRepositoryConfigURL()
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            throw ProvisioningFailure.noExistingKopiaConfiguration(path: url.path(percentEncoded: false))
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ProvisioningFailure.unreadableKopiaConfiguration(underlying: error)
        }

        let (rawConfiguration, secretAccessKey) = try configuration(fromKopiaConfig: data)

        // `repository.config` de Kopia ne porte aucune métadonnée Tailscale
        // — seulement `endpoint` — donc `configuration(fromKopiaConfig:)`
        // laisse toujours `tailscaleMinioNodeName` et `minioTailscaleIP` à
        // vide. Sans eux, les maillons 1 et 2 de la chaîne (Tailscale local,
        // pair MinIO en ligne) n'ont ni pair ni adresse à sonder, et un
        // import qui les laisserait vides s'annoncerait réussi tout en
        // produisant une chaîne à moitié aveugle. On tente donc de les
        // déduire ici, avant la moindre écriture, pour pouvoir refuser
        // proprement si la déduction échoue plutôt que de laisser une
        // configuration à moitié provisionnée derrière soi.
        let parsedConfiguration = try resolvedConfigurationWithTailscalePeer(rawConfiguration)

        // L'état précédent, capturé avant toute écriture, pour pouvoir tout
        // remettre en place si la vérification échoue plus bas — jamais
        // remplacer un dépôt qui fonctionnait par un import qui ne s'ouvre
        // pas. `load()` lance déjà une erreur nommée sur un config.json
        // corrompu plutôt que de rendre les valeurs par défaut : on ne veut
        // pas hériter de cette confusion ici.
        let previousConfiguration = try mappedConfigurationLoadFailure { try BackupConfigurationStore.load() }
        let previousSecretKeyRead = BackupSecrets.read(.s3SecretAccessKey)
        let previousPasswordRead = BackupSecrets.read(.repositoryPassword)

        guard case .saved = BackupSecrets.write(secretAccessKey, for: .s3SecretAccessKey) else {
            throw ProvisioningFailure.secretNotStored(secret: .s3SecretAccessKey)
        }

        let passwordRecovered: Bool
        switch findKopiaUIRepositoryPassword() {
        case .found(let password):
            guard case .saved = BackupSecrets.write(password, for: .repositoryPassword) else {
                restore(previousSecretKeyRead, to: .s3SecretAccessKey)
                throw ProvisioningFailure.secretNotStored(secret: .repositoryPassword)
            }
            passwordRecovered = true
        case .notFound:
            // Dit proprement, comme demandé : ce n'est pas un échec de
            // l'import, c'est distinct d'un Trousseau qui refuse de
            // répondre — voir `KopiaUILookup`.
            passwordRecovered = false
        case .denied(let error):
            restore(previousSecretKeyRead, to: .s3SecretAccessKey)
            throw ProvisioningFailure.repositoryPasswordAccessDenied(underlying: error)
        }

        // Écrite désactivée : tant que la vérification n'a pas parlé, rien ne
        // doit pouvoir déclencher un run sur cette configuration.
        var provisional = parsedConfiguration
        provisional.isEnabled = false
        do {
            try BackupConfigurationStore.save(provisional)
        } catch {
            restore(previousSecretKeyRead, to: .s3SecretAccessKey)
            if passwordRecovered { restore(previousPasswordRead, to: .repositoryPassword) }
            throw ProvisioningFailure.configurationNotStored(underlying: error)
        }

        guard passwordRecovered else {
            // La config et la clé S3 restent sur disque et au Trousseau,
            // désactivées : rien ne peut se déclencher dessus tant que le mot
            // de passe manque, mais rien n'est perdu non plus si l'appelant
            // le fournit juste après par un autre chemin.
            throw ProvisioningFailure.repositoryPasswordNotRecovered
        }

        do {
            let status = try runSynchronously { try await BackupEngine.driver().repositoryStatus() }
            var verified = provisional
            verified.isEnabled = true
            try BackupConfigurationStore.save(verified)
            return ImportOutcome(configuration: verified, verifiedStatus: status)
        } catch {
            // Le dépôt ne s'ouvre pas avec ce qu'on vient d'écrire : tout
            // annuler plutôt que laisser une configuration qui a l'air
            // provisionnée et qui ne marche pas.
            rollback(
                to: previousConfiguration,
                previousSecretKeyRead: previousSecretKeyRead,
                previousPasswordRead: previousPasswordRead
            )
            throw ProvisioningFailure.repositoryDoesNotOpen(underlying: error)
        }
    }

    /// Le décodage pur du `repository.config` de Kopia — aucun Trousseau,
    /// aucun disque au-delà de la `Data` déjà lue.
    ///
    /// **Testable sans disque ni Trousseau**, sur un `Data` littéral copié
    /// depuis une vraie sortie de kopia 0.23.1. Cette fonction vit dans
    /// `BranApp` et non `BranBackup` — c'est le fichier que ce prompt m'a
    /// demandé d'écrire — donc aucun fichier de test ne l'accompagne ici ;
    /// voir le rapport de cet agent pour l'échantillon à utiliser.
    ///
    /// **`type` doit valoir `"s3"`.** Un dépôt filesystem ou B2 a une forme de
    /// `storage.config` entièrement différente ; en extraire `bucket` ou
    /// `endpoint` quand même produirait une configuration à moitié remplie
    /// qui ressemblerait à un S3 sans en être un. Refus explicite à la place,
    /// jamais une valeur devinée.
    static func configuration(fromKopiaConfig data: Data) throws -> (BackupConfiguration, String) {
        let raw: RawKopiaRepositoryConfig
        do {
            raw = try JSONDecoder().decode(RawKopiaRepositoryConfig.self, from: data)
        } catch {
            throw ProvisioningFailure.corruptKopiaConfiguration(underlying: error)
        }

        guard let storage = raw.storage else {
            throw ProvisioningFailure.missingKopiaConfigField(path: "storage")
        }
        guard let type = storage.type else {
            throw ProvisioningFailure.missingKopiaConfigField(path: "storage.type")
        }
        guard type == "s3" else {
            throw ProvisioningFailure.unsupportedStorageType(type)
        }
        guard let config = storage.config else {
            throw ProvisioningFailure.missingKopiaConfigField(path: "storage.config")
        }
        guard let bucket = config.bucket else {
            throw ProvisioningFailure.missingKopiaConfigField(path: "storage.config.bucket")
        }
        guard let endpoint = config.endpoint else {
            throw ProvisioningFailure.missingKopiaConfigField(path: "storage.config.endpoint")
        }
        guard let doNotUseTLS = config.doNotUseTLS else {
            throw ProvisioningFailure.missingKopiaConfigField(path: "storage.config.doNotUseTLS")
        }
        guard let accessKeyID = config.accessKeyID else {
            throw ProvisioningFailure.missingKopiaConfigField(path: "storage.config.accessKeyID")
        }
        guard let secretAccessKey = config.secretAccessKey else {
            throw ProvisioningFailure.missingKopiaConfigField(path: "storage.config.secretAccessKey")
        }
        guard let region = config.region else {
            throw ProvisioningFailure.missingKopiaConfigField(path: "storage.config.region")
        }

        var configuration = BackupConfigurationStore.defaultConfiguration()
        configuration.s3Endpoint = endpoint
        configuration.s3Bucket = bucket
        configuration.s3Region = region
        configuration.disableTLS = doNotUseTLS
        configuration.s3AccessKeyID = accessKeyID
        return (configuration, secretAccessKey)
    }

    // MARK: - Le pair Tailscale, déduit et non lu

    /// Complète `tailscaleMinioNodeName` et `minioTailscaleIP` quand
    /// `configuration(fromKopiaConfig:)` les a laissés vides — ce qu'elle
    /// fait toujours, faute de matière première dans `repository.config`.
    ///
    /// **Mesuré avant d'écrire cette fonction :**
    /// `ChainProbes.minioNodeOnline(nodeName: "", …)` ne rend pas un
    /// `unknown` silencieux sur un nom vide. Elle appelle `findPeer(named:
    /// "", in:)`, qui ne matche jamais — `HostName == ""` n'existe sur aucun
    /// pair réel, et `DNSName.hasPrefix(".")` non plus — et retombe donc sur
    /// le message générique « Aucun pair nommé « » dans ce tailnet ». C'est
    /// un rouge explicite, pas un mensonge : la chaîne ne prétendrait pas
    /// aller bien. Mais rien n'y nomme le champ manquant ni son rôle, et
    /// rien n'explique qu'il vient d'un import qui n'a jamais pu le remplir
    /// — ce qui laisserait l'utilisateur deviner. C'est ce que cette
    /// fonction referme : soit elle déduit les deux champs pour de bon, soit
    /// l'import s'arrête avec un message qui dit exactement quoi manque et
    /// pourquoi, avant qu'une configuration à moitié aveugle ne s'active.
    ///
    /// Ne modifie rien sur disque ni au Trousseau : appelée avant toute
    /// écriture, pour pouvoir refuser proprement.
    private static func resolvedConfigurationWithTailscalePeer(
        _ configuration: BackupConfiguration
    ) throws -> BackupConfiguration {
        guard configuration.tailscaleMinioNodeName.isEmpty || configuration.minioTailscaleIP.isEmpty else {
            return configuration
        }
        guard let deduced = try runSynchronously({
            await deduceTailscalePeer(fromEndpoint: configuration.s3Endpoint, timeout: configuration.probeTimeout)
        })
        else {
            throw ProvisioningFailure.tailscalePeerNotResolved(endpoint: configuration.s3Endpoint)
        }
        var resolved = configuration
        resolved.tailscaleMinioNodeName = deduced.nodeName
        resolved.minioTailscaleIP = deduced.ip
        return resolved
    }

    /// Résultat d'une déduction réussie. Un type nommé plutôt qu'un tuple :
    /// ``resolvedConfigurationWithTailscalePeer(_:)`` le fait traverser
    /// `runSynchronously`, dont la contrainte générique exige une
    /// conformité `Sendable` nominale — un tuple ne peut pas en porter une.
    private struct DeducedTailscalePeer: Sendable {
        let nodeName: String
        let ip: String
    }

    /// Interroge `tailscale status --json` pour trouver qui, dans ce
    /// tailnet, porte l'adresse que `s3Endpoint` désigne — la seule source
    /// disponible à l'import, puisque `repository.config` n'en dit rien.
    ///
    /// `nil` chaque fois que la déduction n'est pas sûre — adresse hors de
    /// l'espace Tailscale, binaire absent, sortie illisible, aucun pair ne
    /// portant cette adresse — jamais une valeur devinée : c'est
    /// exactement la discipline que ``configuration(fromKopiaConfig:)``
    /// applique déjà champ par champ.
    private static func deduceTailscalePeer(
        fromEndpoint endpoint: String,
        timeout: TimeInterval
    ) async -> DeducedTailscalePeer? {
        guard let (host, _) = parseHostPort(endpoint), isTailscaleAddress(host) else { return nil }
        guard let binary = locateTailscaleBinary() else { return nil }

        let outcome = await runProcess(executable: binary, arguments: ["status", "--json"], timeout: timeout)
        guard case .finished(_, let stdout, _) = outcome, stdout.isEmpty == false,
              let status = try? JSONDecoder().decode(RawTailscaleStatus.self, from: stdout),
              let peers = status.Peer
        else {
            return nil
        }

        for peer in peers.values {
            guard let ips = peer.TailscaleIPs, ips.contains(host) else { continue }
            if let hostName = peer.HostName, hostName.isEmpty == false {
                return DeducedTailscalePeer(nodeName: hostName, ip: host)
            }
            // À défaut de `HostName`, le premier segment de `DNSName`
            // (`minio-backup.tailXXXX.ts.net.` → `minio-backup`) — même
            // repli que documenté sur `findPeer(named:in:)` dans
            // `ChainProbes.swift`.
            if let dnsName = peer.DNSName, let short = dnsName.split(separator: ".").first {
                return DeducedTailscalePeer(nodeName: String(short), ip: host)
            }
        }
        return nil
    }

    /// Vrai quand `host` est une IPv4 littérale dans 100.64.0.0/10 —
    /// l'espace CGNAT que Tailscale attribue à chaque nœud du tailnet. Un
    /// nom DNS ou une IP publique rend faux : ni l'un ni l'autre ne prouve
    /// qu'on parle à un pair Tailscale, donc ni l'un ni l'autre ne justifie
    /// d'aller interroger `tailscale status`.
    private static func isTailscaleAddress(_ host: String) -> Bool {
        let octets = host.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else { return false }
        return octets[0] == 100 && (64...127).contains(octets[1])
    }

    // MARK: - b) La sous-commande headless

    static let provisionFlag = "--backup-provision"

    /// Provisionne bran pour un autre Mac — celui du frère du propriétaire,
    /// avec son seau, ses clés, son mot de passe de dépôt — sans interface.
    /// Sur le motif de `PasteboardAccessProbe.runIfRequested()`.
    ///
    /// - Returns: `true` quand le drapeau était présent, auquel cas le
    ///   processus s'est déjà arrêté (`exit`) avant que cette fonction ne
    ///   rende la main — le code de sortie porte le verdict pour un script
    ///   appelant.
    static func runIfRequested() -> Bool {
        guard CommandLine.arguments.contains(provisionFlag) else { return false }

        do {
            let status = try provisionFromEnvironmentOrStandardInput()
            let message = """
                Dépôt vérifié et provisionnement enregistré.
                seau       : \(status.bucket)
                point d'accès : \(status.endpoint)
                hôte       : \(status.hostname)
                """
            FileHandle.standardError.write(Data((message + "\n").utf8))

            // **Le seul avertissement qui ne se rattrape pas après coup.**
            //
            // Ce chemin sert à provisionner une machine par script, parfois par
            // SSH, parfois sur un Mac dont personne n'ouvrira jamais
            // l'interface — celui d'un proche, par exemple, avec ses propres
            // clés. Personne n'y verra la notification système ni le texte
            // permanent des réglages.
            //
            // Or ce qui vient d'être enregistré est une clé de chiffrement de
            // bout en bout que personne au monde ne peut réinitialiser : ni
            // bran, ni Kopia, ni l'administrateur du serveur. Perdue avec la
            // machine, elle transforme des centaines de gigaoctets en octets
            // aléatoires, définitivement. Le dire coûte quatre lignes sur la
            // sortie d'erreur ; ne pas le dire coûte tout.
            FileHandle.standardError.write(
                Data(("\n" + BackupAlerts.repositoryPasswordReminderText + "\n").utf8))
            exit(EXIT_SUCCESS)
        } catch {
            FileHandle.standardError.write(Data("Provisionnement refusé : \(error)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    /// Chaque valeur vient d'abord d'une variable d'environnement — usage
    /// scripté, par exemple un déploiement par SSH sans TTY — puis, si elle
    /// manque, d'une invite sur l'entrée standard. Les deux secrets ne
    /// s'affichent **jamais** en écho, y compris à la saisie interactive.
    private static func provisionFromEnvironmentOrStandardInput() throws -> RepositoryStatus {
        let s3Endpoint = try requiredValue(envKey: "BRAN_BACKUP_S3_ENDPOINT", prompt: "Point d'accès S3 (hôte:port) : ")
        let s3Bucket = try requiredValue(envKey: "BRAN_BACKUP_S3_BUCKET", prompt: "Seau S3 : ")
        let s3Region = try requiredValue(envKey: "BRAN_BACKUP_S3_REGION", prompt: "Région S3 : ")
        let disableTLSRaw = try requiredValue(envKey: "BRAN_BACKUP_S3_DISABLE_TLS", prompt: "Désactiver TLS (o/n) : ")
        let disableTLS = try parseBoolean(disableTLSRaw)
        let s3AccessKeyID = try requiredValue(envKey: "BRAN_BACKUP_S3_ACCESS_KEY_ID", prompt: "Identifiant de clé S3 : ")
        let s3SecretAccessKey = try requiredSecret(envKey: "BRAN_BACKUP_S3_SECRET_ACCESS_KEY", prompt: "Clé secrète S3 : ")
        let repositoryPassword = try requiredSecret(envKey: "BRAN_BACKUP_REPOSITORY_PASSWORD", prompt: "Mot de passe de dépôt : ")
        let tailscaleNodeName = try requiredValue(envKey: "BRAN_BACKUP_TAILSCALE_NODE_NAME", prompt: "Nom du pair Tailscale MinIO : ")
        let minioTailscaleIP = try requiredValue(envKey: "BRAN_BACKUP_MINIO_TAILSCALE_IP", prompt: "Adresse Tailscale de MinIO : ")

        var candidate = BackupConfigurationStore.defaultConfiguration()
        candidate.s3Endpoint = s3Endpoint
        candidate.s3Bucket = s3Bucket
        candidate.s3Region = s3Region
        candidate.disableTLS = disableTLS
        candidate.s3AccessKeyID = s3AccessKeyID
        candidate.tailscaleMinioNodeName = tailscaleNodeName
        candidate.minioTailscaleIP = minioTailscaleIP
        candidate.isEnabled = false

        let previousConfiguration = try mappedConfigurationLoadFailure { try BackupConfigurationStore.load() }
        let previousSecretKeyRead = BackupSecrets.read(.s3SecretAccessKey)
        let previousPasswordRead = BackupSecrets.read(.repositoryPassword)

        guard case .saved = BackupSecrets.write(s3SecretAccessKey, for: .s3SecretAccessKey) else {
            throw ProvisioningFailure.secretNotStored(secret: .s3SecretAccessKey)
        }
        guard case .saved = BackupSecrets.write(repositoryPassword, for: .repositoryPassword) else {
            restore(previousSecretKeyRead, to: .s3SecretAccessKey)
            throw ProvisioningFailure.secretNotStored(secret: .repositoryPassword)
        }

        do {
            try BackupConfigurationStore.save(candidate)
        } catch {
            restore(previousSecretKeyRead, to: .s3SecretAccessKey)
            restore(previousPasswordRead, to: .repositoryPassword)
            throw ProvisioningFailure.configurationNotStored(underlying: error)
        }

        do {
            let status = try runSynchronously { try await BackupEngine.driver().repositoryStatus() }
            var verified = candidate
            verified.isEnabled = true
            try BackupConfigurationStore.save(verified)
            return status
        } catch {
            // Écrire des identifiants sans les avoir essayés, c'est fabriquer
            // la panne qu'on combat : tout revient à l'état précédent plutôt
            // que de laisser une configuration qui a l'air bonne et qui ne
            // marche pas.
            rollback(
                to: previousConfiguration,
                previousSecretKeyRead: previousSecretKeyRead,
                previousPasswordRead: previousPasswordRead
            )
            throw ProvisioningFailure.repositoryDoesNotOpen(underlying: error)
        }
    }

    // MARK: - La saisie

    /// Une valeur non secrète : variable d'environnement d'abord, sinon une
    /// invite sur l'entrée standard. Une chaîne blanche après avoir ôté les
    /// espaces compte comme absente ; bran ne devine jamais qu'elle voulait
    /// dire quelque chose.
    private static func requiredValue(envKey: String, prompt: String) throws -> String {
        if let fromEnvironment = ProcessInfo.processInfo.environment[envKey],
           !fromEnvironment.trimmingCharacters(in: .whitespaces).isEmpty {
            return fromEnvironment
        }
        print(prompt, terminator: "")
        guard let line = readLine(strippingNewline: true),
              !line.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ProvisioningFailure.missingInput(field: envKey)
        }
        return line
    }

    /// Une valeur secrète : variable d'environnement d'abord — un script
    /// n'affiche rien de toute façon —, sinon une invite qui coupe l'écho du
    /// terminal. **Jamais de `readLine()` nu pour un secret** : ce serait
    /// l'afficher en clair pendant la saisie, exactement ce que ce fichier
    /// s'engage à ne jamais faire.
    private static func requiredSecret(envKey: String, prompt: String) throws -> String {
        if let fromEnvironment = ProcessInfo.processInfo.environment[envKey], !fromEnvironment.isEmpty {
            return fromEnvironment
        }
        let value = readSecret(prompt: prompt)
        guard !value.isEmpty else {
            throw ProvisioningFailure.missingInput(field: envKey)
        }
        return value
    }

    /// Lit une ligne avec l'écho du terminal coupé, et le remet en place dans
    /// tous les cas — y compris si l'entrée standard n'est pas un vrai
    /// terminal (redirigée depuis un fichier ou un tube), auquel cas couper
    /// l'écho n'a ni sens ni effet et on ne le tente pas.
    private static func readSecret(prompt: String) -> String {
        FileHandle.standardError.write(Data(prompt.utf8))

        var original = termios()
        let hasTTY = tcgetattr(STDIN_FILENO, &original) == 0
        if hasTTY {
            var silenced = original
            silenced.c_lflag &= ~tcflag_t(ECHO)
            tcsetattr(STDIN_FILENO, TCSANOW, &silenced)
        }

        let value = readLine(strippingNewline: true) ?? ""

        if hasTTY {
            tcsetattr(STDIN_FILENO, TCSANOW, &original)
        }
        FileHandle.standardError.write(Data("\n".utf8))
        return value
    }

    private static func parseBoolean(_ raw: String) throws -> Bool {
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "o", "oui", "y", "yes", "true", "1": return true
        case "n", "non", "no", "false", "0": return false
        default: throw ProvisioningFailure.unparsableBoolean(raw)
        }
    }

    // MARK: - Le mot de passe de dépôt dans le Trousseau de KopiaUI

    private enum KopiaUILookup {
        case found(String)
        case notFound
        case denied(BackupSecretsError)
    }

    /// Cherche le mot de passe de dépôt dans le Trousseau de KopiaUI.
    ///
    /// **Une lecture, pas une propriété.** Ce n'est pas un secret de bran :
    /// bran n'écrit jamais sous le service `kopia`, ne le modifie jamais, ne
    /// le supprime jamais — `BackupSecrets` reste seul maître de ce que bran
    /// possède. Ceci n'est qu'une consultation, l'équivalent Swift d'un
    /// `security find-generic-password -s kopia` lancé depuis le Terminal.
    ///
    /// **`kSecAttrAccount` n'est volontairement pas fixé.** L'identifiant
    /// exact que KopiaUI utilise comme compte n'est documenté nulle part et
    /// n'a pas été mesuré sur cette machine ; contraindre la requête dessus
    /// risquerait de ne jamais trouver un élément qui existe pourtant sous ce
    /// service. Un `kSecMatchLimitOne` sans compte rend le premier élément du
    /// service, ce qui suffit tant qu'un seul dépôt KopiaUI est configuré sur
    /// la machine — l'hypothèse raisonnable pour un Mac qu'on vient de
    /// monter.
    private static func findKopiaUIRepositoryPassword() -> KopiaUILookup {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "kopia",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecItemNotFound:
            return .notFound
        case errSecSuccess:
            guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
                return .denied(BackupSecretsError(status: errSecDecode, context: "trousseau kopia illisible"))
            }
            return .found(value)
        default:
            return .denied(BackupSecretsError(status: status, context: "trousseau kopia"))
        }
    }

    // MARK: - Annuler proprement

    /// Remet un compte du Trousseau dans l'état où `BackupSecrets.read`
    /// l'avait trouvé avant qu'on écrive dessus. N'est appelée que sur un
    /// chemin d'échec, jamais en chemin heureux.
    private static func restore(_ previous: BackupSecrets.ReadOutcome, to secret: BackupSecrets.Secret) {
        switch previous {
        case .found(let value):
            BackupSecrets.write(value, for: secret)
        case .absent:
            BackupSecrets.delete(secret)
        case .denied:
            // Le Trousseau refusait déjà de répondre avant qu'on touche à
            // quoi que ce soit : il n'y a rien à restaurer que l'écriture
            // qu'on vient de faire n'a pas pu empirer plus que l'état où on
            // l'a trouvé.
            break
        }
    }

    private static func rollback(
        to previousConfiguration: BackupConfiguration,
        previousSecretKeyRead: BackupSecrets.ReadOutcome,
        previousPasswordRead: BackupSecrets.ReadOutcome
    ) {
        restore(previousSecretKeyRead, to: .s3SecretAccessKey)
        restore(previousPasswordRead, to: .repositoryPassword)
        do {
            try BackupConfigurationStore.save(previousConfiguration)
        } catch {
            // On est déjà dans le chemin d'échec : l'erreur qui compte pour
            // l'appelant est celle du dépôt qui ne s'ouvre pas, et c'est elle
            // qui sera lancée juste après. Celle-ci ne doit pas se perdre en
            // silence pour autant.
            FeatureLog.record("Provisionnement de sauvegarde : restauration de la configuration précédente a échoué", error: error)
        }
    }

    // MARK: - Le chemin du fichier Kopia existant

    private static func kopiaRepositoryConfigURL() throws -> URL {
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else {
            throw ProvisioningFailure.applicationSupportUnavailable
        }
        return support.appending(path: "kopia/repository.config", directoryHint: .notDirectory)
    }

    /// `BackupConfigurationStore.load()` distingue déjà « rien n'existe » de
    /// « ça existe et c'est corrompu » ; ce fichier ne fait que renommer la
    /// seconde catégorie en une erreur de provisionnement, pour que
    /// l'appelant n'ait qu'un seul type d'erreur (`ProvisioningFailure`) à
    /// traiter plutôt que deux.
    private static func mappedConfigurationLoadFailure(
        _ load: () throws -> BackupConfiguration
    ) throws -> BackupConfiguration {
        do {
            return try load()
        } catch {
            throw ProvisioningFailure.existingConfigurationCorrupted(underlying: error)
        }
    }

    // MARK: - Le pont synchrone

    /// Attend une opération asynchrone depuis un contexte synchrone.
    ///
    /// `runIfRequested()` est appelée avant que SwiftUI ne démarre, depuis un
    /// `main()` non asynchrone — le même endroit que
    /// `PasteboardAccessProbe.runIfRequested()`. `KopiaDriver.repositoryStatus()`
    /// doit lancer un `Process` et attendre sa sortie, donc être asynchrone ;
    /// ce pont est ce qui permet à une sous-commande synchrone de l'attendre
    /// sans réécrire tout le point d'entrée de bran en `async`.
    private static func runSynchronously<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var outcome: Result<T, Error>?
        Task {
            do {
                outcome = .success(try await operation())
            } catch {
                outcome = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        guard let outcome else {
            // Ne peut pas arriver par construction : la tâche signale
            // toujours après avoir écrit `outcome`, jamais avant. Un
            // `fatalError` nommé est plus honnête ici qu'une erreur inventée
            // qui prétendrait connaître une cause qu'on n'a pas.
            fatalError("runSynchronously : le sémaphore s'est libéré sans résultat écrit.")
        }
        return try outcome.get()
    }
}

// MARK: - Les échecs de provisionnement

/// Ce qui a empêché un provisionnement d'aboutir, nommé précisément — jamais
/// un simple « erreur ».
enum ProvisioningFailure: Error, CustomStringConvertible {
    case applicationSupportUnavailable
    case noExistingKopiaConfiguration(path: String)
    case unreadableKopiaConfiguration(underlying: Error)
    case corruptKopiaConfiguration(underlying: Error)
    case missingKopiaConfigField(path: String)
    case unsupportedStorageType(String)
    case tailscalePeerNotResolved(endpoint: String)
    case existingConfigurationCorrupted(underlying: Error)
    case secretNotStored(secret: BackupSecrets.Secret)
    case repositoryPasswordAccessDenied(underlying: BackupSecretsError)
    case repositoryPasswordNotRecovered
    case configurationNotStored(underlying: Error)
    case repositoryDoesNotOpen(underlying: Error)
    case missingInput(field: String)
    case unparsableBoolean(String)

    var description: String {
        switch self {
        case .applicationSupportUnavailable:
            "macOS ne rend aucun dossier de support applicatif pour cette session."
        case .noExistingKopiaConfiguration(let path):
            "Aucune configuration Kopia trouvée à \(path)."
        case .unreadableKopiaConfiguration(let underlying):
            "repository.config existe mais n'a pas pu être lu : \(underlying)."
        case .corruptKopiaConfiguration(let underlying):
            "repository.config n'est pas un JSON exploitable : \(underlying)."
        case .missingKopiaConfigField(let path):
            "repository.config : le champ « \(path) » est absent ou du mauvais type."
        case .unsupportedStorageType(let type):
            "Ce dépôt Kopia est de type « \(type) », pas « s3 » : import refusé plutôt qu'une configuration à moitié remplie."
        case .tailscalePeerNotResolved(let endpoint):
            "Le nom du pair Tailscale et son adresse n'ont pas pu être déduits de « \(endpoint) » — repository.config de Kopia ne les porte jamais. « tailscaleMinioNodeName » et « minioTailscaleIP » servent à surveiller si Tailscale tourne et si le pair MinIO est en ligne (les deux premiers maillons de la chaîne) ; sans eux, l'import s'arrête plutôt que d'activer une chaîne qui ne peut rien dire sur ces deux maillons. Rien n'a été écrit : les renseigner dans les réglages de sauvegarde, ou relancer l'import une fois Tailscale joignable."
        case .existingConfigurationCorrupted(let underlying):
            "La configuration de sauvegarde déjà sur disque est illisible, provisionnement interrompu avant d'y toucher : \(underlying)."
        case .secretNotStored(let secret):
            "\(secret.rawValue) n'a pas pu être écrit dans le Trousseau."
        case .repositoryPasswordAccessDenied(let underlying):
            "Le Trousseau de KopiaUI a refusé la lecture du mot de passe de dépôt : \(underlying)."
        case .repositoryPasswordNotRecovered:
            "Le mot de passe de dépôt n'est pas dans repository.config et n'a pas été trouvé dans le Trousseau de KopiaUI. La clé S3 et la configuration réseau sont enregistrées, désactivées ; le mot de passe reste à fournir."
        case .configurationNotStored(let underlying):
            "La configuration n'a pas pu être écrite sur disque : \(underlying)."
        case .repositoryDoesNotOpen(let underlying):
            "Le dépôt ne s'ouvre pas avec ces identifiants ; rien n'a été conservé. Détail : \(underlying)."
        case .missingInput(let field):
            "\(field) : aucune valeur reçue, ni en variable d'environnement ni sur l'entrée standard."
        case .unparsableBoolean(let raw):
            "« \(raw) » n'est ni oui ni non."
        }
    }
}

// MARK: - Les formes brutes de repository.config

/// Tout optionnel, à dessein — même discipline que `KopiaManifest.RawSnapshot`
/// dans `BranBackup` : une clé absente devient `nil`, jamais une erreur de
/// décodage opaque, et c'est `configuration(fromKopiaConfig:)` qui décide,
/// champ par champ, ce qui est vraiment obligatoire.
private struct RawKopiaRepositoryConfig: Decodable {
    let storage: RawKopiaStorage?
}

private struct RawKopiaStorage: Decodable {
    let type: String?
    let config: RawKopiaStorageConfig?
}

private struct RawKopiaStorageConfig: Decodable {
    let bucket: String?
    let endpoint: String?
    let doNotUseTLS: Bool?
    let accessKeyID: String?
    let secretAccessKey: String?
    let region: String?
}
