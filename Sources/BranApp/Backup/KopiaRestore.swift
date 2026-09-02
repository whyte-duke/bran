import Foundation
#if canImport(Darwin)
import Darwin
#endif
import BranBackup

// ============================================================================
// PROCÉDURE DE RÉCUPÉRATION DEPUIS ZÉRO — le Mac est perdu, bran n'existe
// plus nulle part. C'est le seul scénario qui compte vraiment : celui où
// cette sauvegarde a une raison d'exister. Toute la documentation suivante
// suppose qu'on part d'un Mac neuf, sans bran, sans Trousseau rempli, sans
// rien d'autre que l'accès réseau au QNAP et les trois informations que le
// propriétaire garde ailleurs que sur ce Mac : l'identifiant de clé d'accès
// S3, la clé secrète S3, et le mot de passe du dépôt kopia — ce dernier est
// aussi la clé de déchiffrement de bout en bout : sans lui, les octets du
// QNAP ne sont qu'un tas de contenus chiffrés, pour toujours.
//
// 1. Installer kopia sur le Mac de secours (n'importe quel Mac ayant accès
//    au réseau du QNAP — pas forcément celui qui sera restauré) :
//
//        brew install kopia
//
//    À défaut de Homebrew, le binaire seul se télécharge sur kopia.io — cette
//    procédure a été vérifiée avec kopia 0.23.1 (`KopiaDriver.expectedVersionPrefix`
//    dans `KopiaDriver.swift` fixe la version que bran embarque ; une version
//    de secours plus récente convient presque toujours, kopia garde une
//    compatibilité de dépôt ascendante).
//
// 2. Rejoindre le réseau qui porte le dépôt. Si le QNAP est joint par
//    Tailscale (le cas normal de bran), installer et connecter Tailscale
//    avec le compte du propriétaire — sans ça, l'étape 3 échouera par
//    « connection refused » ou « no route to host », pas par un problème de
//    kopia.
//
// 3. Se connecter au dépôt S3. Les valeurs `<bucket>`, `<endpoint>` et
//    `<région>` ne sont pas secrètes — elles vivent en clair dans
//    `BackupConfiguration` (voir `BackupContract.swift`) — mais ne sont pas
//    recopiées ici pour que cette procédure reste valable si elles changent
//    un jour sans qu'on pense à mettre ce commentaire à jour :
//
//        kopia repository connect s3 \
//          --bucket=<bucket, depuis BackupConfiguration.s3Bucket> \
//          --endpoint=<hôte:port, depuis BackupConfiguration.s3Endpoint> \
//          --region=<depuis BackupConfiguration.s3Region> \
//          --access-key=<depuis BackupConfiguration.s3AccessKeyID> \
//          --secret-access-key=<la clé secrète S3 — jamais sur ce Mac,
//                                seulement dans le gestionnaire de mots de
//                                passe du propriétaire> \
//          --disable-tls
//
//    (`--disable-tls` seulement si `BackupConfiguration.disableTLS` est
//    vrai — c'est le cas pour une connexion interne au tailnet, pas pour un
//    S3 exposé publiquement.) Kopia demande alors le mot de passe du dépôt
//    de façon interactive : c'est la clé de déchiffrement, distincte des
//    deux clés S3 données ci-dessus. Elle peut aussi être fournie via la
//    variable d'environnement `KOPIA_PASSWORD`, comme le fait ce fichier
//    pour bran lui-même — voir la note de `KopiaDriver.swift` sur pourquoi
//    ce canal et pas `argv`.
//
// 4. Vérifier ce qu'il y a à récupérer :
//
//        kopia snapshot list --all
//
//    Chaque ligne montre un identifiant de snapshot, la source d'origine
//    (`utilisateur@machine:/chemin`) et sa date. C'est cet identifiant — pas
//    un chemin — qu'on restaure à l'étape suivante.
//
// 5. Restaurer, vers un dossier **vide** créé pour l'occasion (jamais
//    directement vers un dossier personnel existant — voir plus bas
//    pourquoi) :
//
//        kopia restore <identifiant-de-snapshot> /chemin/vers/dossier/vide \
//          --no-overwrite-files --no-overwrite-directories --no-overwrite-symlinks
//
//    Ces trois drapeaux ne sont **pas** optionnels dans cette procédure :
//    sans eux, kopia écrase par défaut tout ce qui existerait déjà à cet
//    endroit — mesuré dans l'aide de kopia 0.23.1 elle-même. Une fois la
//    restauration terminée, kopia affiche une ligne « Restored N files, M
//    directories and K symbolic links (taille). » : c'est la seule preuve
//    que la restauration est allée à son terme. Toute autre fin — un exit
//    code différent de zéro, ou un silence sans cette ligne — veut dire que
//    le dossier restauré est **incomplet**, pas prêt à remplacer quoi que ce
//    soit. Relancer la même commande vers le **même** dossier échouera alors
//    sur les trois drapeaux ci-dessus (« non-empty directory already exists,
//    not overwriting it », mesuré) : repartir d'un dossier neuf, pas essayer
//    de « compléter » une restauration interrompue.
//
// Ce que fait le reste de ce fichier n'est rien d'autre qu'une automatisation
// de ces cinq étapes, appelée depuis l'application — avec la même prudence
// sur l'écrasement, et la même exigence de voir la ligne finale avant
// d'annoncer un succès.
// ============================================================================

// La contrepartie de `KopiaDriver.swift` pour la lecture : parcourir un
// snapshot (`kopia show`) et en restaurer un morceau (`kopia restore`).
//
// **Pourquoi ce fichier ne réutilise pas `KopiaDriver.run(...)`.** Ce serait
// la façon la plus courte de tenir la promesse « exactement le même modèle
// que `createSnapshot` » — mais `run`, `classifiedFailure`, `OutputCollector`
// et les boîtes de passage de `KopiaDriver.swift` sont `private`, donc
// invisibles même à une extension écrite dans un autre fichier du même
// module : `private` en Swift borne à la déclaration **et au fichier**, pas
// au module. Le briefing interdit d'éditer `KopiaDriver.swift` pour élargir
// leur visibilité — plusieurs agents y travaillent en parallèle. Ce fichier
// reconstruit donc la même architecture (lecture non bloquante de stdout et
// stderr, attente des trois signaux avant de conclure, SIGTERM puis SIGKILL
// de secours) sous un acteur voisin, `KopiaRestoreDriver`, qui partage en
// revanche tout ce qui est réellement public : `KopiaExecutable`,
// `KopiaPasswordProviding`, `KopiaFailureClassifier`, `KopiaDecodingFailure`.
//
// **Ce que ça laisse ouvert, et qui mérite d'être su avant de brancher ce
// fichier dans l'application.** `KopiaDriver` et `KopiaRestoreDriver` sont
// deux acteurs indépendants, chacun avec son propre verrou de concurrence
// (`isRunning`). Rien n'empêche donc, au niveau de ce fichier, un appel à
// `KopiaDriver.createSnapshot` et un appel à `KopiaRestoreDriver.restore` de
// tourner en même temps — deux processus kopia contre le même dépôt et le
// même cache local. kopia est conçu pour tolérer des lecteurs concurrents
// (`browse` ne mute rien), mais une restauration qui écrit pendant qu'une
// sauvegarde écrit aussi n'a pas été mesurée ici et n'est pas une
// configuration à tenter sans y avoir réfléchi. C'est à l'appelant (la
// machine à états de `BackupController`, hors du périmètre de ce fichier) de
// s'assurer qu'une restauration ne démarre pas pendant que `BackupPhase.isBusy`
// est vrai.

// MARK: - Le fournisseur de faits sur la destination

/// Mesure ce qu'il faut savoir d'un dossier de destination avant de lancer
/// une restauration — la seule partie de la garde qui touche au disque, donc
/// qui ne peut pas vivre dans `BranBackup`.
public enum RestoreDestinationInspector {
    /// Le volume disponible est mesuré sur le premier ancêtre du chemin qui
    /// existe déjà : si la destination elle-même n'existe pas encore, kopia
    /// la créera, mais c'est le volume de son dossier parent (ou grand-
    /// parent, etc.) qui porte réellement l'espace disponible.
    public static func inspect(_ destination: URL) -> RestoreDestinationFacts {
        let fileManager = FileManager.default
        var isDirectoryFlag: ObjCBool = false
        let exists = fileManager.fileExists(atPath: destination.path, isDirectory: &isDirectoryFlag)
        let isDirectory = isDirectoryFlag.boolValue

        let isWritable: Bool
        var isEmpty: Bool?
        if exists {
            isWritable = fileManager.isWritableFile(atPath: destination.path)
            if isDirectory {
                if let contents = try? fileManager.contentsOfDirectory(atPath: destination.path) {
                    isEmpty = contents.isEmpty
                }
            }
        } else {
            isWritable = fileManager.isWritableFile(atPath: nearestExistingAncestor(of: destination).path)
        }

        let availableBytes = availableCapacity(at: exists ? destination : nearestExistingAncestor(of: destination))

        return RestoreDestinationFacts(
            exists: exists,
            isDirectory: exists ? isDirectory : false,
            isWritable: isWritable,
            isEmpty: isEmpty,
            availableBytes: availableBytes
        )
    }

    private static func nearestExistingAncestor(of url: URL) -> URL {
        var candidate = url
        while !FileManager.default.fileExists(atPath: candidate.path) {
            let parent = candidate.deletingLastPathComponent()
            // `deletingLastPathComponent` sur la racine (`/`) se rend elle-même :
            // la remontée doit s'arrêter là plutôt que boucler.
            if parent.path == candidate.path { return parent }
            candidate = parent
        }
        return candidate
    }

    private static func availableCapacity(at url: URL) -> Int64? {
        // `.volumeAvailableCapacityForImportantUsageKey` plutôt que l'ancien
        // `NSFileSystemFreeSize` : ce dernier compte l'espace « purgeable »
        // (caches système que macOS peut vider sous pression) comme libre,
        // ce qui gonfle artificiellement la marge sur un disque système
        // presque plein — exactement le genre d'optimisme que ce contrôle
        // existe pour ne pas avoir.
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let capacity = values.volumeAvailableCapacityForImportantUsage
        else { return nil }
        return capacity
    }
}

// MARK: - Les échecs propres à la restauration

public enum KopiaRestoreFailure: Error, Sendable, CustomStringConvertible {
    /// Le dépôt est déjà occupé — une sauvegarde tourne, ou une autre
    /// restauration. Ce n'est pas une panne : c'est une information, et le
    /// geste à faire est d'attendre.
    case repositoryBusy

    case binary(KopiaBinaryFailure)
    case launchFailed(underlying: String)
    case alreadyRunning
    case destinationInvalid([RestoreDestinationProblem])
    case decodingFailed(KopiaDecodingFailure, rawOutput: String)
    case restore(BackupFailure)
    /// Le processus s'est terminé sans erreur reconnue, mais sans jamais
    /// avoir affiché la ligne « Restored N files… » qui seule prouve qu'une
    /// restauration est allée à son terme. Voir l'en-tête de ce fichier :
    /// un exit code 0 n'est jamais, à lui seul, une preuve de succès.
    case completionNotConfirmed(rawOutput: String)

    public var description: String {
        switch self {
        case .binary(let failure): failure.description
        case .launchFailed(let underlying): "Impossible de lancer kopia : \(underlying)."
        case .alreadyRunning: "Une commande de restauration est déjà en cours sur ce pilote."
        case .repositoryBusy:
            "Le dépôt est occupé par une sauvegarde en cours. La restauration "
                + "démarrera dès qu'elle sera terminée ou annulée."
        case .destinationInvalid(let problems):
            "Destination refusée : " + problems.map(\.description).joined(separator: " ")
        case .decodingFailed(let failure, _): failure.description
        case .restore(let failure): failure.summary
        case .completionNotConfirmed:
            "kopia s'est arrêté sans confirmer la fin de la restauration : "
                + "les fichiers déjà écrits sont incomplets, ne pas les utiliser tels quels."
        }
    }

    /// Ramène tout ce fichier au même type d'échec que le reste de bran —
    /// même logique que `KopiaDriverFailure.asBackupFailure`.
    public var asBackupFailure: BackupFailure {
        switch self {
        case .repositoryBusy:
            // `.interrupted` et non un genre d'erreur : rien n'est cassé, le
            // dépôt est simplement pris. C'est le seul genre du contrat qui
            // porte « ça se reprendra tout seul » sans annoncer une panne.
            BackupFailure(
                kind: .interrupted,
                summary: "Le dépôt est occupé par une sauvegarde en cours.",
                suggestedAction: "Attendre la fin de la sauvegarde, ou l'annuler, puis relancer la restauration.",
                rawOutput: "")
        case .restore(let failure):
            failure
        case .binary(let failure):
            BackupFailure(
                kind: .notConfigured,
                summary: failure.description,
                suggestedAction: "Réinstaller bran, ou renseigner le chemin du binaire kopia dans les réglages avancés.",
                rawOutput: failure.description
            )
        case .launchFailed(let underlying):
            BackupFailure(kind: .storage, summary: "kopia n'a pas pu être lancé : \(underlying)", rawOutput: underlying)
        case .alreadyRunning:
            BackupFailure(
                kind: .storage,
                summary: "Une commande de restauration est déjà en cours sur ce pilote.",
                rawOutput: ""
            )
        case .destinationInvalid(let problems):
            BackupFailure(
                kind: .storage,
                summary: problems.map(\.description).joined(separator: " "),
                suggestedAction: "Choisir un autre dossier de destination.",
                rawOutput: ""
            )
        case .decodingFailed(let failure, let rawOutput):
            failure.asBackupFailure(rawOutput: rawOutput)
        case .completionNotConfirmed(let rawOutput):
            BackupFailure(
                kind: .interrupted,
                summary: description,
                suggestedAction: "Relancer la restauration vers un dossier neuf — ne pas réutiliser celui-ci tel quel.",
                rawOutput: rawOutput
            )
        }
    }
}

// MARK: - Le pilote de restauration

/// Parcourt un snapshot (`kopia show`) et en restaure un morceau (`kopia
/// restore`) — jamais de JSON ni de ligne de log brute côté appelant, sur le
/// même principe que `KopiaDriver`.
public actor KopiaRestoreDriver {
    private let executable: KopiaExecutable
    private let configFileURL: URL?
    private let passwordProvider: KopiaPasswordProviding

    private var isRunning = false
    private var currentProcess: Process?
    private var cancellationRequested = false
    private var stallDetected = false

    /// Au-delà de ce silence sur stderr sans aucune progression décodée,
    /// ``restore(objectID:to:requiredBytes:overwrite:stallThreshold:onProgress:)``
    /// considère que kopia est bloqué. Même valeur que `KopiaDriver.defaultProgressStallThreshold`
    /// et pour la même raison : fondée sur l'absence de progression, jamais
    /// sur une durée totale, parce qu'un premier gros volume peut légitimement
    /// prendre des heures au débit mesuré vers ce MinIO (5,5 Mo/s).
    public static let defaultProgressStallThreshold: TimeInterval = 600

    public init(
        executable: KopiaExecutable,
        configFileURL: URL? = nil,
        passwordProvider: KopiaPasswordProviding
    ) {
        self.executable = executable
        self.configFileURL = configFileURL
        self.passwordProvider = passwordProvider
    }

    // MARK: - Parcourir un snapshot

    /// Liste le contenu d'un dossier de snapshot — `objectID` est soit
    /// l'identifiant racine d'un snapshot (`SnapshotProof.id` ou
    /// `.rootObjectID`, les deux fonctionnent, mesuré), soit celui d'un
    /// enfant obtenu d'un appel précédent, via `RestoreEntry.objectID`.
    public func browse(objectID: String) async throws -> RestoreDirectoryListing {
        let result = try await run(arguments: ["show", objectID, "--no-progress"], needsPassword: true)

        if let browseSpecific = Self.classifyBrowseSpecificFailure(stderr: result.stderr, objectID: objectID) {
            throw KopiaRestoreFailure.restore(browseSpecific)
        }
        if let failure = KopiaFailureClassifier.classify(
            stderr: result.stderr, exitCode: result.exitCode,
            wasCancelled: result.wasCancelled, signal: result.signal
        ) {
            throw KopiaRestoreFailure.restore(failure)
        }
        guard !result.stdoutOverflowed else {
            throw KopiaRestoreFailure.restore(BackupFailure(
                kind: .unparseable,
                summary: "Le listing de « \(objectID) » dépasse "
                    + "\(BoundedOutputBuffer.defaultStdoutLimit / (1024 * 1024)) Mo : bran a cessé de "
                    + "l'accumuler et refuse de décoder un document tronqué.",
                suggestedAction: "Descendre dans un sous-dossier plutôt que de lister celui-ci en entier.",
                rawOutput: KopiaFailureClassifier.maskSecrets(in: result.stderr)
            ))
        }
        guard !result.stdout.isEmpty else {
            throw KopiaRestoreFailure.restore(BackupFailure(
                kind: .unparseable,
                summary: "kopia n'a rien écrit en listant « \(objectID) », sans erreur reconnue.",
                suggestedAction: "Copier le journal brut ci-dessous : ce cas n'est pas encore reconnu par bran.",
                rawOutput: KopiaFailureClassifier.maskSecrets(in: result.stderr)
            ))
        }
        do {
            return try RestoreCatalog.decodeDirectoryListing(result.stdout)
        } catch let decodingFailure as KopiaDecodingFailure {
            throw KopiaRestoreFailure.decodingFailed(decodingFailure, rawOutput: maskedStdoutText(result))
        }
    }

    // MARK: - Restaurer

    /// Le cœur de la restauration, **privé** : voir ``restore(objectID:to:requiredBytes:overwrite:stallThreshold:onProgress:)``,
    /// seule porte d'entrée publique. La garder privée est le mécanisme, pas
    /// juste la recommandation, qui rend la validation de la destination
    /// impossible à sauter — même en connaissant cette fonction, un appelant
    /// hors de ce fichier ne peut pas la contourner.
    private func performRestore(
        objectID: String,
        to destination: URL,
        overwrite: RestoreOverwritePolicy,
        stallThreshold: TimeInterval,
        onProgress: @escaping @Sendable (RestoreProgress) -> Void
    ) async throws -> RestoreSummary {
        // Pas de création préalable du dossier ici : kopia s'en charge lui-
        // même quand la destination n'existe pas encore (documenté dans son
        // aide, « the target path will be created … if it does not exist »).
        // Un `try?` qui créerait le dossier par avance et avalerait l'échec
        // serait exactement le genre d'optimisme que ce module s'interdit —
        // et masquerait, par exemple, une destination qui existe déjà sous
        // forme de fichier plutôt que de dossier.
        var arguments = ["restore", objectID, destination.path(percentEncoded: false)]
        arguments += overwrite.kopiaFlags
        // `--write-files-atomically` : chaque fichier est écrit dans un
        // temporaire puis renommé, jamais visible à moitié écrit — mesuré
        // dans l'aide de kopia comme prévenant « partially written files ».
        // Ça ne protège qu'un fichier à la fois : ça n'empêche pas un
        // dossier de rester lui-même incomplet si l'ensemble du run est
        // interrompu avant la fin — voir la garde du résumé final plus bas,
        // qui est le vrai filet pour ce cas-là.
        arguments += ["--write-files-atomically", "--progress"]

        let result = try await run(
            arguments: arguments, needsPassword: true, stallThreshold: stallThreshold, onProgress: onProgress
        )

        if result.stallDetected {
            throw KopiaRestoreFailure.restore(BackupFailure(
                kind: .interrupted,
                summary: "Aucune progression depuis plus de \(Int(stallThreshold / 60)) minutes : "
                    + "la restauration a été arrêtée. Les fichiers déjà écrits dans « \(destination.path) » "
                    + "sont incomplets — ne pas les utiliser tels quels.",
                suggestedAction: "Relancer la restauration vers un dossier neuf.",
                rawOutput: KopiaFailureClassifier.maskSecrets(in: result.stderr)
            ))
        }
        if let restoreSpecific = Self.classifyRestoreSpecificFailure(stderr: result.stderr) {
            throw KopiaRestoreFailure.restore(restoreSpecific)
        }
        if let failure = KopiaFailureClassifier.classify(
            stderr: result.stderr, exitCode: result.exitCode,
            wasCancelled: result.wasCancelled, signal: result.signal
        ) {
            throw KopiaRestoreFailure.restore(failure)
        }

        // **Le garde-fou central de ce fichier.** Un exit code 0 et un
        // stderr sans erreur reconnue ne suffisent pas : voir l'en-tête sur
        // ce qu'un `kopia restore` tué en plein milieu (SIGTERM, veille du
        // Mac, coupure secteur) laisse derrière lui sans jamais afficher sa
        // ligne finale — des fichiers réels, mais un sous-ensemble
        // incomplet de la source, sans aucun marqueur sur le disque qui le
        // dise. La seule preuve qu'une restauration est allée à son terme
        // est cette ligne, jamais l'absence d'échec.
        guard let summary = Self.finalSummary(fromStderr: result.stderr) else {
            throw KopiaRestoreFailure.completionNotConfirmed(
                rawOutput: KopiaFailureClassifier.maskSecrets(in: result.stderr)
            )
        }
        return summary
    }

    /// Restaure `objectID` (un dossier ou un fichier de snapshot, identifié
    /// exactement comme pour ``browse(objectID:)``) vers `destination`.
    ///
    /// **Seule porte d'entrée pour restaurer.** `requiredBytes` (le volume
    /// logique de ce qu'on restaure — voir
    /// `RestoreCatalog.validateDestination(_:requiredBytes:overwrite:)`) et
    /// `overwrite` (voir `RestoreOverwritePolicy`) n'ont ni l'un ni l'autre
    /// de valeur par défaut : un appelant ne peut matériellement pas lancer
    /// une restauration sans avoir choisi combien d'espace elle exige et ce
    /// qu'elle a le droit d'écraser. La destination est validée ici, avant
    /// tout lancement de kopia — jamais après coup, jamais en rattrapant un
    /// échec de kopia qui aurait déjà commencé à écrire.
    public func restore(
        objectID: String,
        to destination: URL,
        requiredBytes: Int64,
        overwrite: RestoreOverwritePolicy,
        stallThreshold: TimeInterval = KopiaRestoreDriver.defaultProgressStallThreshold,
        onProgress: @escaping @Sendable (RestoreProgress) -> Void
    ) async throws -> RestoreSummary {
        let facts = RestoreDestinationInspector.inspect(destination)
        var problems = RestoreCatalog.validateDestination(facts, requiredBytes: requiredBytes, overwrite: overwrite)

        // **Un contenu inconnu n'est pas un dossier vide.**
        //
        // `RestoreCatalog.validateDestination` ne pose `.notEmpty` que sur
        // `facts.isEmpty == false` : un dossier dont `contentsOfDirectory` a
        // échoué porte `isEmpty == nil` et **passe la garde**. Le cas est réel
        // — un dossier exécutable mais non listable (bit `x` sans bit `r`, ACL
        // inhabituelle sur un volume externe) est exactement celui que
        // `RestoreDestinationFacts.isEmpty` documente comme rendant `nil`.
        // kopia partait alors sur une destination dont personne ne savait ce
        // qu'elle contenait, avec `--no-overwrite-*` : au mieux il échoue à
        // mi-parcours en laissant une restauration incomplète mêlée à des
        // fichiers préexistants, au pire on a demandé « écraser » et il
        // écrase ce qu'on n'a pas pu voir.
        //
        // Corrigé ici plutôt que dans `validateDestination` : cette fonction
        // vit dans `BranBackup`, hors du périmètre de cette correction. La
        // vraie place du garde-fou est là-bas (`facts.isEmpty != true` au lieu
        // de `facts.isEmpty == false`) — voir le rapport.
        //
        // Seulement en mode « ne rien écraser » : c'est le mode dont toute la
        // prémisse est « ce dossier est vide ». En mode « écraser », un
        // contenu inconnu ne change rien à ce que l'appelant a déjà accepté.
        if overwrite == .refuseIfNotEmpty, facts.exists, facts.isDirectory, facts.isEmpty == nil,
           problems.contains(.notEmpty(policy: overwrite)) == false {
            problems.append(.notEmpty(policy: overwrite))
        }

        guard problems.isEmpty else {
            throw KopiaRestoreFailure.destinationInvalid(problems)
        }
        // **Le même verrou que la sauvegarde, et il manquait.**
        //
        // Signalé par l'auteur de ce fichier lui-même : `KopiaDriver` et
        // `KopiaRestoreDriver` sont deux acteurs distincts, avec chacun son
        // garde-fou de simultanéité — donc rien n'empêchait un `kopia restore`
        // de démarrer pendant qu'un `kopia snapshot create` tournait. Deux
        // processus kopia sur le même dépôt et le même cache local, c'est un
        // conflit de verrou côté dépôt et, au pire, une réparation à la main.
        //
        // Le verrou est celui de `BackupRunLock` — le même fichier que celui
        // que prennent le bouton « Sauvegarder maintenant » et le job launchd.
        // Une restauration devient donc, pour eux, un run comme un autre : ils
        // attendent, et le disent.
        //
        // `flock` et non un témoin : le noyau le rend à la mort du processus,
        // quelle qu'en soit la cause. Une restauration interrompue par une
        // panne de courant ne laisse pas le dépôt verrouillé pour toujours.
        guard let lock = BackupRunLock.acquire() else {
            throw KopiaRestoreFailure.repositoryBusy
        }
        defer { lock.release() }

        return try await performRestore(
            objectID: objectID, to: destination, overwrite: overwrite,
            stallThreshold: stallThreshold, onProgress: onProgress
        )
    }

    // MARK: - L'annulation

    /// Termine proprement le run en cours, s'il y en a un — même politique
    /// que `KopiaDriver.cancelCurrentRun()` : SIGTERM d'abord, SIGKILL après
    /// un délai de grâce, pour laisser kopia fermer son cache local avant de
    /// sortir plutôt que de le couper net.
    public func cancelCurrentRun() async {
        guard let process = currentProcess else { return }
        cancellationRequested = true
        await terminateGracefully(process)
    }

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

    // MARK: - Le classement d'un échec propre à la restauration

    /// Les messages mesurés de `kopia show` sur un identifiant qui ne
    /// désigne pas un dossier lisible — même raison d'être que
    /// ``classifyRestoreSpecificFailure(stderr:)``, pour une autre commande.
    /// Relevé réel : `kopia show ffffffff…` (identifiant inexistant) rend
    /// « … is not a directory object » ; descendre dans un sous-chemin
    /// disparu rend « error reading directory: entry not found ».
    private static func classifyBrowseSpecificFailure(stderr: String, objectID: String) -> BackupFailure? {
        let lines = stderr.components(separatedBy: "\n").flatMap { $0.components(separatedBy: "\r") }
        for line in lines {
            if line.contains("is not a directory object") || line.contains("entry not found")
                || line.contains("object not found") {
                return BackupFailure(
                    kind: .unparseable,
                    summary: "« \(objectID) » ne désigne pas (ou plus) un dossier lisible dans ce dépôt.",
                    suggestedAction: "Revenir au dossier précédent — cette entrée a peut-être disparu depuis "
                        + "que la liste a été affichée.",
                    rawOutput: KopiaFailureClassifier.maskSecrets(in: stderr)
                )
            }
        }
        return nil
    }

    /// Les messages mesurés de `kopia restore` que `KopiaFailureClassifier`
    /// ne connaît pas — il a été écrit pour `snapshot create`/`repository
    /// status`/`snapshot list`, pas pour les refus d'écrasement. Essayé
    /// avant le classifieur générique : une ligne comme « unable to create
    /// "…/a.txt", it already exists » ne doit pas finir en `.unparseable`
    /// faute d'un motif dédié.
    private static func classifyRestoreSpecificFailure(stderr: String) -> BackupFailure? {
        let lines = stderr.components(separatedBy: "\n").flatMap { $0.components(separatedBy: "\r") }
        for line in lines {
            if line.contains("not overwriting it") {
                return BackupFailure(
                    kind: .storage,
                    summary: "Le dossier de destination contient déjà des fichiers, et la restauration a "
                        + "demandé à ne rien écraser.",
                    suggestedAction: "Choisir un dossier de destination vide, ou repasser explicitement en "
                        + "mode « écraser ».",
                    rawOutput: KopiaFailureClassifier.maskSecrets(in: stderr)
                )
            }
            if line.contains("it already exists") {
                return BackupFailure(
                    kind: .storage,
                    summary: "Un fichier existe déjà à la destination, et la restauration a demandé à ne "
                        + "rien écraser.",
                    suggestedAction: "Choisir un dossier de destination vide, ou repasser explicitement en "
                        + "mode « écraser ».",
                    rawOutput: KopiaFailureClassifier.maskSecrets(in: stderr)
                )
            }
        }
        return nil
    }

    /// Rejoue tout stderr à travers `RestoreProgressReader` pour retrouver
    /// l'éventuel événement `.completed` — utilisé une fois le run terminé,
    /// sur le texte complet plutôt qu'en direct, pour ne dépendre d'aucun
    /// découpage particulier des paquets reçus pendant le run.
    private static func finalSummary(fromStderr stderr: String) -> RestoreSummary? {
        var reader = RestoreProgressReader()
        // Le `\n` final garantit qu'une dernière ligne sans séparateur de fin
        // (le cas normal : kopia ne réécrit pas après sa ligne « Restored »)
        // est bien livrée par `accept`, qui n'émet que sur un séparateur vu.
        for event in reader.accept(stderr + "\n") {
            if case .completed(let summary) = event { return summary }
        }
        return nil
    }

    private func maskedStdoutText(_ result: ProcessResult) -> String {
        let text = String(data: result.stdout, encoding: .utf8)
            ?? "<sortie non-UTF8, \(result.stdout.count) octets>"
        return KopiaFailureClassifier.maskSecrets(in: text)
    }

    // MARK: - Exécuter kopia

    private struct ProcessResult {
        var exitCode: Int32
        var stdout: Data
        var stderr: String
        var wasCancelled: Bool
        var signal: Int32?
        var stallDetected: Bool
        /// Vrai quand stdout a dépassé le plafond de `BoundedOutputBuffer` :
        /// le listing rendu est un préfixe, jamais un document à décoder.
        var stdoutOverflowed: Bool
    }

    /// Reconstruit, pour `show` et `restore`, exactement la discipline
    /// documentée dans `KopiaDriver.run(...)` : lecture non bloquante des
    /// deux tuyaux pendant que le processus tourne (sans quoi un `show` sur
    /// un dossier à dix mille enfants, ou un `restore` de plusieurs heures,
    /// interbloquerait dès que le tampon noyau du tuyau — 64 Kio — serait
    /// plein), et attente des trois signaux (fin de process, EOF stdout, EOF
    /// stderr) avant de conclure.
    private func run(
        arguments: [String],
        needsPassword: Bool,
        stallThreshold: TimeInterval? = nil,
        onProgress: (@Sendable (RestoreProgress) -> Void)? = nil
    ) async throws -> ProcessResult {
        guard !isRunning else {
            throw KopiaRestoreFailure.alreadyRunning
        }
        isRunning = true
        defer { isRunning = false }

        cancellationRequested = false
        stallDetected = false

        var fullArguments: [String] = []
        if let configFileURL {
            fullArguments += ["--config-file", configFileURL.path(percentEncoded: false)]
        }
        fullArguments += arguments

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

        let collector = RestoreOutputCollector(onProgress: onProgress)
        let terminationBox = RestoreTerminationBox()

        let group = DispatchGroup()
        group.enter()
        group.enter()
        group.enter()

        process.terminationHandler = { finished in
            terminationBox.exitCode = finished.terminationStatus
            terminationBox.reason = finished.terminationReason
            group.leave()
        }

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
            throw KopiaRestoreFailure.launchFailed(underlying: error.localizedDescription)
        }

        currentProcess = process
        defer { currentProcess = nil }

        let watchdogTask: Task<Void, Never>?
        if let stallThreshold, onProgress != nil {
            let processBox = RestoreProcessBox(process)
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

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            group.notify(queue: .global()) { continuation.resume() }
        }

        let signal = terminationBox.reason == .uncaughtSignal ? terminationBox.exitCode : nil
        let wasCancelled = cancellationRequested
        let wasStalled = stallDetected
        cancellationRequested = false
        stallDetected = false

        return ProcessResult(
            exitCode: terminationBox.exitCode,
            stdout: collector.stdoutData,
            stderr: collector.stderrText,
            wasCancelled: wasCancelled,
            signal: signal,
            stallDetected: wasStalled,
            stdoutOverflowed: collector.stdoutOverflowed
        )
    }
}

// MARK: - Les petites boîtes qui traversent la frontière de concurrence
//
// Mêmes rôles que `TerminationBox`/`ProcessBox`/`OutputCollector` dans
// `KopiaDriver.swift`, renommées pour ne pas laisser croire qu'il s'agit du
// même type — ce sont deux implémentations indépendantes, voir l'en-tête.

private final class RestoreTerminationBox: @unchecked Sendable {
    var exitCode: Int32 = 0
    var reason: Process.TerminationReason = .exit
}

private final class RestoreProcessBox: @unchecked Sendable {
    let process: Process
    init(_ process: Process) { self.process = process }
}

/// **Les deux tampons sont plafonnés**, même raison et même chiffre que
/// `KopiaDriver.OutputCollector` — voir `BoundedOutputBuffer`. Une
/// restauration de plusieurs centaines de gigaoctets publie autant de lignes
/// de progression qu'une sauvegarde, et n'a pas plus le droit qu'elle de les
/// garder toutes en mémoire.
///
/// La queue compte double ici : c'est dans les dernières lignes de stderr que
/// vit « Restored N files… », la **seule** preuve qu'une restauration est
/// allée à son terme (voir `finalSummary(fromStderr:)`). Une troncature
/// aveugle qui garderait la tête ferait échouer toutes les restaurations
/// longues en `completionNotConfirmed`, sur des fichiers pourtant complets.
private final class RestoreOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let stdout = BoundedOutputBuffer.stdout()
    private let stderr = BoundedOutputBuffer.stderr()
    private var progressReader = RestoreProgressReader()
    private var lastProgress = Date()
    private let onProgress: (@Sendable (RestoreProgress) -> Void)?

    init(onProgress: (@Sendable (RestoreProgress) -> Void)?) {
        self.onProgress = onProgress
    }

    func appendStdout(_ data: Data) {
        stdout.append(data)
    }

    func appendStderr(_ data: Data) {
        stderr.append(data)

        guard let onProgress else { return }
        // Décodage indulgent pour cette lecture en direct seulement, même
        // raison que `KopiaDriver.OutputCollector` : un paquet peut couper
        // une séquence UTF-8 multi-octets en plein milieu (un nom de fichier
        // accentué dans « Restoring to … »). Les champs que
        // `RestoreProgressReader` sait lire sont tous ASCII.
        let chunkText = String(decoding: data, as: UTF8.self)
        lock.lock()
        let events = progressReader.accept(chunkText)
        if !events.isEmpty { lastProgress = Date() }
        lock.unlock()
        for event in events {
            if case .progress(let progress) = event {
                onProgress(progress)
            }
        }
    }

    var stdoutData: Data {
        stdout.snapshot()
    }

    var stdoutOverflowed: Bool {
        stdout.didOverflow
    }

    var stderrText: String {
        stderr.text()
    }

    var lastProgressAt: Date {
        lock.lock(); defer { lock.unlock() }
        return lastProgress
    }
}
