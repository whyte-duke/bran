import Foundation

// Les types que toute la sauvegarde partage. Ce fichier ne contient aucune
// logique : seulement les formes que les parseurs remplissent, que la machine à
// états consomme et que l'interface affiche.
//
// **Pourquoi un fichier de contrat plutôt que des types dispersés.** Cette
// fonction a une exigence qu'aucune autre de bran n'a : ne jamais annoncer un
// succès qu'elle n'a pas vérifié. Le propriétaire a déjà été trahi par une
// sauvegarde qui affichait « OK » — et ce dépôt-ci en porte la trace, mesurée le
// 02/09/2026 : 143,1 Go de blocs envoyés sur le réseau, 896 989 contenus
// orphelins, et **zéro manifeste de snapshot**. Rien n'était restaurable. Le
// pilote disait « prêt », le stockage était plein, et il n'y avait pas une seule
// sauvegarde.
//
// Cette classe de panne ne se corrige pas par de la vigilance : elle se corrige
// en rendant l'état mensonger **impossible à construire**. C'est le rôle de ce
// fichier, et c'est pour ça qu'il est écrit une fois, à un seul endroit.

// MARK: - La preuve

/// D'où vient une preuve de snapshot — et c'est la distinction qui porte toute
/// la fonction.
///
/// `kopia snapshot create` rend un manifeste quand il a terminé. Ce manifeste
/// prouve que **le processus a cru** avoir écrit un snapshot ; il ne prouve pas
/// qu'un snapshot **existe dans le dépôt**. Les deux divergent pour des raisons
/// banales : un index pas encore purgé, une écriture partielle sur un maillon
/// réseau qui a lâché à la dernière seconde, un manifeste perdu par une
/// maintenance concurrente. Le dépôt de cette machine en est la démonstration —
/// 140,3 Go de contenus écrits que plus aucun manifeste ne référence.
///
/// Un seul de ces deux états autorise à afficher « sauvegardé ».
public enum ProofOrigin: String, Codable, Sendable, Hashable {
    /// Rendu par `kopia snapshot create`. **Ne suffit pas.** C'est la parole du
    /// processus qui vient de terminer, pas celle du dépôt.
    case reportedByCreate

    /// Relu dans `kopia snapshot list` **après coup**, donc confirmé par le
    /// dépôt lui-même. C'est la seule origine qui vaut preuve.
    case confirmedInRepository
}

/// Un snapshot, tel que Kopia le décrit.
///
/// Les champs suivent le JSON réel de kopia 0.23.1, relevé le 02/09/2026 : le
/// bloc `stats` n'apparaît **que** dans `snapshot list`, jamais dans la sortie
/// de `snapshot create`, qui ne porte qu'un résumé `rootEntry.summ`. Les deux
/// chemins doivent donc pouvoir remplir ce type, et `origin` dit lequel a parlé.
public struct SnapshotProof: Codable, Sendable, Hashable, Identifiable {
    /// L'identifiant du manifeste — `8145671624282e64839f6e3a98678616`. C'est
    /// ce qu'on affiche à l'utilisateur quand il demande la preuve.
    public var id: String

    /// L'identifiant d'objet de la racine — `k348b268a5c…`. Adressé par
    /// contenu : deux snapshots identiques le partagent. C'est la preuve de
    /// niveau cryptographique, celle qu'on cite quand il faut convaincre.
    public var rootObjectID: String

    public var sourcePath: String
    public var sourceHost: String
    public var sourceUser: String

    public var startTime: Date
    public var endTime: Date

    /// Taille logique de l'arborescence — pas ce qui a transité, la dédup et la
    /// compression passent par-dessus.
    public var totalSize: Int64
    public var fileCount: Int
    public var dirCount: Int

    /// Le nombre de fichiers que Kopia n'a **pas** pu lire.
    ///
    /// **Le piège central.** `kopia snapshot create` sort avec le code 0 même
    /// quand il a échoué sur des fichiers : le snapshot existe, il est
    /// simplement incomplet. Un pilote qui regarde le code de sortie annonce un
    /// succès ; il faut regarder ce compteur.
    public var errorCount: Int

    /// Le nombre de fichiers que Kopia a échoué à lire **et dont il a décidé de
    /// ne pas se plaindre**.
    ///
    /// **Ce champ existe parce que son absence était un trou dans ce contrat**,
    /// trouvé le 02/09/2026 en lisant la politique globale réelle du dépôt :
    ///
    /// ```
    /// Error handling policy:
    ///   Ignore file read errors:              true
    ///   Ignore directory read errors:         true
    /// ```
    ///
    /// Avec ce réglage — qui est celui de ce Mac — un fichier illisible
    /// n'incrémente pas `errorCount` mais `ignoredErrorCount`, et Kopia sort
    /// avec le code 0. Une sauvegarde qui aurait sauté dix mille fichiers
    /// verrouillés se présenterait donc avec `errorCount == 0`, un manifeste
    /// valide, un code de sortie nul — et l'écran afficherait un vert franc sur
    /// une sauvegarde trouée. C'est la même famille de mensonge que celle qui a
    /// coûté 143 Go pour zéro snapshot, avec un compteur de plus.
    ///
    /// On le lit donc, et ``isComplete`` le refuse.
    public var ignoredErrorCount: Int

    public var origin: ProofOrigin

    /// Vrai quand le snapshot couvre la source sans trou.
    ///
    /// Les **deux** compteurs doivent être nuls. Les ignorer à moitié serait
    /// pire que de ne pas les lire : ça donnerait la façade d'une vérification.
    ///
    /// Ne dit rien de l'origine : un snapshot peut être complet **et** non
    /// confirmé. Les deux conditions se cumulent, voir ``isTrustworthy``.
    public var isComplete: Bool { errorCount == 0 && ignoredErrorCount == 0 }

    /// Le nombre de fichiers manquants, toutes causes confondues. Ce que
    /// l'interface affiche quand elle doit dire « incomplète, et voilà de
    /// combien ».
    public var missingFileCount: Int { errorCount + ignoredErrorCount }

    /// La seule condition qui autorise à écrire « sauvegardé » à l'écran.
    public var isTrustworthy: Bool {
        isComplete && origin == .confirmedInRepository
    }

    public var duration: TimeInterval { endTime.timeIntervalSince(startTime) }

    public init(
        id: String,
        rootObjectID: String,
        sourcePath: String,
        sourceHost: String,
        sourceUser: String,
        startTime: Date,
        endTime: Date,
        totalSize: Int64,
        fileCount: Int,
        dirCount: Int,
        errorCount: Int,
        ignoredErrorCount: Int,
        origin: ProofOrigin
    ) {
        self.id = id
        self.rootObjectID = rootObjectID
        self.sourcePath = sourcePath
        self.sourceHost = sourceHost
        self.sourceUser = sourceUser
        self.startTime = startTime
        self.endTime = endTime
        self.totalSize = totalSize
        self.fileCount = fileCount
        self.dirCount = dirCount
        self.errorCount = errorCount
        self.ignoredErrorCount = ignoredErrorCount
        self.origin = origin
    }
}

/// Ce que `kopia repository status --json` apprend du dépôt.
///
/// Sert à deux choses et pas une de plus : prouver que le dépôt s'ouvre (maillon
/// 6), et afficher à l'utilisateur *à quel* dépôt il parle — un pilote qui
/// sauvegarde consciencieusement dans le mauvais seau est le deuxième mensonge
/// le plus coûteux après « OK » sans données.
public struct RepositoryStatus: Codable, Sendable, Hashable {
    public var uniqueID: String
    public var bucket: String
    public var endpoint: String
    public var storageType: String
    public var hostname: String
    public var username: String
    public var encryption: String
    public var hash: String

    public init(
        uniqueID: String,
        bucket: String,
        endpoint: String,
        storageType: String,
        hostname: String,
        username: String,
        encryption: String,
        hash: String
    ) {
        self.uniqueID = uniqueID
        self.bucket = bucket
        self.endpoint = endpoint
        self.storageType = storageType
        self.hostname = hostname
        self.username = username
        self.encryption = encryption
        self.hash = hash
    }
}

// MARK: - La progression

/// Un instantané de progression, extrait de la ligne d'état de Kopia.
///
/// Kopia écrit sa progression sur **stderr**, sur une seule ligne réécrite par
/// retours chariot, préfixée d'un caractère de rotation. Relevé réel :
///
/// ```
/// - 5 hashing, 7 hashed (233 MB), 0 cached (0 B), uploaded 215.2 MB, estimated 240 MB (97.1%) 0s left
/// ```
///
/// Deux régimes se succèdent : d'abord `estimating...`, où le total est inconnu
/// et où une barre de progression serait un mensonge ; puis l'estimation, qui
/// reste une **estimation** et peut se corriger à la hausse en cours de route.
/// D'où `estimatedBytes` optionnel : l'absence de total est un état à afficher,
/// pas un zéro à diviser.
public struct BackupProgress: Codable, Sendable, Hashable {
    /// Fichiers en cours de hachage à cet instant.
    public var hashingFiles: Int
    /// Fichiers hachés depuis le début, et leur volume.
    public var hashedFiles: Int
    public var hashedBytes: Int64
    /// Ce que la dédup a évité de relire. C'est ce chiffre qui rend une reprise
    /// visible : au deuxième passage, il porte l'essentiel du volume.
    public var cachedBytes: Int64
    /// Ce qui est réellement parti sur le réseau.
    public var uploadedBytes: Int64
    /// Le total estimé, quand Kopia a fini d'estimer.
    public var estimatedBytes: Int64?
    /// Le reste à faire selon Kopia, en secondes.
    public var secondsRemaining: TimeInterval?

    /// La fraction accomplie, ou `nil` tant qu'aucun total n'est connu.
    ///
    /// Bornée à 1 : l'estimation de Kopia se corrige en cours de route et une
    /// barre qui dépasse son cadre est un défaut visible. Elle n'est **pas**
    /// bornée en bas au-delà de zéro, et elle peut reculer — c'est honnête.
    public var fraction: Double? {
        guard let estimatedBytes, estimatedBytes > 0 else { return nil }
        return min(1, Double(hashedBytes + cachedBytes) / Double(estimatedBytes))
    }

    public init(
        hashingFiles: Int = 0,
        hashedFiles: Int = 0,
        hashedBytes: Int64 = 0,
        cachedBytes: Int64 = 0,
        uploadedBytes: Int64 = 0,
        estimatedBytes: Int64? = nil,
        secondsRemaining: TimeInterval? = nil
    ) {
        self.hashingFiles = hashingFiles
        self.hashedFiles = hashedFiles
        self.hashedBytes = hashedBytes
        self.cachedBytes = cachedBytes
        self.uploadedBytes = uploadedBytes
        self.estimatedBytes = estimatedBytes
        self.secondsRemaining = secondsRemaining
    }
}

// MARK: - La chaîne

/// Les six maillons entre ce Mac et les octets posés sur le QNAP.
///
/// Ils sont ordonnés du plus proche au plus lointain, et cet ordre est
/// significatif : quand plusieurs sont rouges, le premier est la cause et les
/// suivants n'en sont que l'écho. L'interface ne doit accuser que le premier.
public enum ChainLink: String, Codable, Sendable, Hashable, CaseIterable, Comparable {
    /// Le démon Tailscale de ce Mac est-il debout et authentifié.
    case tailscaleLocal
    /// Le pair `minio-backup` est-il en ligne dans le tailnet.
    case minioNodeOnline
    /// Le port 9000 accepte-t-il une connexion.
    case s3Reachable
    /// `/minio/health/live` puis `/ready`.
    case minioHealthy
    /// L'API S3 répond sur ce seau et refuse la lecture anonyme. Un `GET`
    /// **anonyme** sur le seau doit rendre 403 : un 404 dirait « seau absent »
    /// sur ce MinIO, un 200 dirait « seau public » — une faute de
    /// configuration, pas une preuve de santé —, et une erreur de transport
    /// dirait qu'on n'a jamais atteint S3.
    ///
    /// **Ce maillon ne dit rien des identifiants, et sa documentation
    /// affirmait le contraire.** Elle disait « le seau existe et les
    /// identifiants sont valides » ; la sonde n'envoie aucune clé S3. Des clés
    /// Kopia expirées, avec un MinIO qui refuse correctement l'accès anonyme,
    /// donnaient donc un maillon « Seau » vert et une chaîne dont l'échec
    /// n'apparaissait qu'au maillon suivant — avec, entre les deux, un
    /// diagnostic qui accusait le mauvais endroit.
    ///
    /// **Seul ``repositoryOpens`` prouve les identifiants**, parce que lui
    /// seul ouvre le dépôt avec eux. C'est aussi pour ça qu'il est le dernier
    /// de la chaîne, et le plus cher.
    case bucketReachable
    /// `kopia repository status` s'ouvre. La vérité, et la plus chère.
    case repositoryOpens

    public static func < (lhs: ChainLink, rhs: ChainLink) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

/// L'état d'un maillon.
///
/// **`connecting` n'est pas une nuance de confort.** Le propriétaire travaille
/// depuis l'Indonésie ; une première ouverture de dépôt peut prendre des
/// dizaines de secondes sans que rien ne soit cassé. Confondre « lent » et
/// « mort » ferait clignoter du rouge sur une chaîne saine, et un rouge qui
/// ment est exactement ce qu'on cherche à éliminer — dans les deux sens.
public enum LinkState: String, Codable, Sendable, Hashable {
    /// Mesuré, et bon.
    case up
    /// Sonde encore en vol, ou lenteur sans verdict. Ni bon ni mauvais : en
    /// cours.
    case connecting
    /// Répond, mais dégradé — au-delà du seuil de latence, ou santé partielle.
    case degraded
    /// Mesuré, et mauvais.
    case down
    /// Jamais sondé depuis le lancement. Distinct de `down` : on ne sait pas.
    case unknown
}

/// Le résultat d'une sonde sur un maillon.
public struct LinkProbeResult: Codable, Sendable, Hashable, Identifiable {
    public var link: ChainLink
    public var state: LinkState
    /// Ce qu'on montre à l'utilisateur quand le maillon n'est pas vert. Doit
    /// nommer **où** ça casse et **quoi faire**, jamais « erreur ».
    public var diagnostic: String
    /// Le texte brut de l'outil, conservé pour le bouton « copier le
    /// diagnostic ». Jamais résumé, jamais nettoyé — c'est la pièce à
    /// conviction.
    public var rawDetail: String?
    public var latency: TimeInterval?
    public var measuredAt: Date

    public var id: ChainLink { link }

    public init(
        link: ChainLink,
        state: LinkState,
        diagnostic: String,
        rawDetail: String? = nil,
        latency: TimeInterval? = nil,
        measuredAt: Date
    ) {
        self.link = link
        self.state = state
        self.diagnostic = diagnostic
        self.rawDetail = rawDetail
        self.latency = latency
        self.measuredAt = measuredAt
    }
}

/// Le verdict d'ensemble sur la chaîne.
public struct ChainVerdict: Codable, Sendable, Hashable {
    public var results: [LinkProbeResult]
    /// Le premier maillon rouge dans l'ordre de la chaîne — la cause, pas
    /// l'écho.
    public var firstFailure: ChainLink?
    /// Le message à afficher en tête. Reprend le diagnostic de `firstFailure`,
    /// ou constate que tout est vert.
    public var headline: String
    /// Vrai seulement si **aucun** maillon n'est `down`, `unknown` ni
    /// `connecting` : on ne sauvegarde pas sur une ignorance. Un maillon
    /// `degraded` — une ligne lente, mesurée lente — est le seul état non vert
    /// qui laisse passer.
    ///
    /// La formulation précédente disait « tous les maillons sont `up` », et ce
    /// n'était pas seulement imprécis : `ChainEvaluator` ne regardait que le
    /// premier maillon non vert, de sorte qu'un `degraded` en amont rendait
    /// vrai ce champ sans que personne ne voie un `unknown` en aval. La
    /// documentation décrivait l'intention, le code faisait autre chose.
    public var canBackUp: Bool

    public init(
        results: [LinkProbeResult],
        firstFailure: ChainLink?,
        headline: String,
        canBackUp: Bool
    ) {
        self.results = results
        self.firstFailure = firstFailure
        self.headline = headline
        self.canBackUp = canBackUp
    }
}

// MARK: - L'échec

/// La famille d'un échec, qui décide de ce qu'on en fait.
///
/// La distinction qui compte n'est pas cosmétique : elle sépare ce qu'il faut
/// **réessayer** de ce qu'il faut **montrer**. Un réseau tombé n'est pas une
/// panne, c'est une attente ; l'afficher en rouge définitif apprend à
/// l'utilisateur à ignorer le rouge, et le jour où le rouge est vrai il ne le
/// regarde plus.
public enum FailureKind: String, Codable, Sendable, Hashable {
    /// Réseau, DNS, TCP, Tailscale. Transitoire par nature → réessai.
    case network
    /// Identifiants S3 ou mot de passe de dépôt. Ne se répare pas tout seul.
    case authentication
    /// Le dépôt s'ouvre mal, format ou index. Grave.
    case repository
    /// Disque plein, cache saturé, droits.
    case storage
    /// Le run a été tué — veille, extinction, annulation. Pas un échec de la
    /// sauvegarde : une interruption, dont on reprendra.
    case interrupted
    /// Le snapshot existe mais Kopia n'a pas pu lire tous les fichiers.
    case partialSnapshot
    /// Kopia a rendu quelque chose qu'on n'a pas su lire. **Ne jamais
    /// interpréter au bénéfice du doute.**
    case unparseable
    /// Une échéance est passée sans que le Mac soit allumé.
    case missedSchedule
    /// Pas encore configuré.
    case notConfigured

    /// Vrai quand réessayer plus tard a un sens.
    public var deservesRetry: Bool {
        switch self {
        case .network, .interrupted, .missedSchedule: true
        case .authentication, .repository, .storage, .partialSnapshot,
             .unparseable, .notConfigured: false
        }
    }
}

/// Un échec, avec de quoi le comprendre sans relancer quoi que ce soit.
public struct BackupFailure: Codable, Sendable, Hashable {
    public var kind: FailureKind
    /// Une phrase pour l'utilisateur, en français, qui dit ce qui s'est passé.
    public var summary: String
    /// Ce qu'il peut faire. Vide quand il n'y a rien à faire que d'attendre.
    public var suggestedAction: String?
    /// La sortie brute de l'outil. Non tronquée, non reformulée.
    public var rawOutput: String
    /// Le maillon en cause, quand on sait le désigner.
    public var link: ChainLink?

    public init(
        kind: FailureKind,
        summary: String,
        suggestedAction: String? = nil,
        rawOutput: String,
        link: ChainLink? = nil
    ) {
        self.kind = kind
        self.summary = summary
        self.suggestedAction = suggestedAction
        self.rawOutput = rawOutput
        self.link = link
    }
}

// MARK: - La machine

/// Où en est la sauvegarde.
///
/// **`success` porte une preuve, et c'est la garantie structurelle de tout le
/// dispositif.** On ne peut pas construire l'état « réussi » sans exhiber un
/// `SnapshotProof` ; et la machine refuse d'y entrer si cette preuve n'est pas
/// `isTrustworthy`, c'est-à-dire relue dans le dépôt et sans fichier manquant.
/// Un développeur pressé — humain ou non — ne peut donc pas afficher un vert
/// qu'il n'a pas mérité : il n'a rien à mettre dans le cas.
public enum BackupPhase: Codable, Sendable, Hashable {
    /// Rien en cours. Ce que dit le bandeau vient alors du journal, pas d'ici.
    case idle
    /// Les six sondes tournent.
    case checkingChain
    /// `kopia snapshot create` tourne.
    case running(BackupProgress)
    /// Le manifeste est rendu, on relit le dépôt pour le confirmer. Cet état
    /// existe pour lui-même : c'est l'étape qu'un pilote naïf saute.
    case verifying
    /// Terminé, et prouvé.
    case success(SnapshotProof)
    /// Terminé sur un échec.
    case failed(BackupFailure)
    /// La chaîne est rouge sur un maillon transitoire ; on attend qu'elle
    /// reverdisse. **Distinct de `failed`** : rien n'est cassé, on patiente.
    case waitingForNetwork(ChainVerdict)
    /// Le run a été coupé. Il reprendra, et la dédup fera que la reprise est
    /// bon marché.
    case interrupted(BackupFailure)

    /// Vrai quand quelque chose occupe le dépôt. Le verrou de simultanéité s'en
    /// sert, l'interface aussi pour désactiver « sauvegarder maintenant ».
    public var isBusy: Bool {
        switch self {
        case .checkingChain, .running, .verifying: true
        case .idle, .success, .failed, .waitingForNetwork, .interrupted: false
        }
    }
}

/// Une ligne du journal : une tentative, du début à son issue.
///
/// Écrite en ajout atomique à chaque transition durable, pour que l'historique
/// survive à un crash et pour que le rattrapage puisse relire « dernier succès »
/// sans ouvrir le dépôt.
public struct BackupAttempt: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var startedAt: Date
    public var finishedAt: Date?
    /// Ce qui l'a déclenchée — l'utilisateur, l'horloge, le rattrapage.
    public var trigger: BackupTrigger
    public var proof: SnapshotProof?
    public var failure: BackupFailure?
    /// Le volume réellement monté sur le réseau pendant cette tentative.
    /// Distinct de `proof.totalSize` : c'est lui qui montre qu'une reprise a
    /// coûté peu.
    public var uploadedBytes: Int64?

    /// Le total que Kopia estimait avoir à traiter, relevé pendant le run.
    ///
    /// **Il existe pour survivre à l'extinction de l'application.** Ce chiffre
    /// ne vit autrement que dans `BackupProgress`, qui meurt avec le processus.
    /// Sans lui, l'écran peut afficher « 612 Go envoyés » le lendemain matin,
    /// mais pas « sur environ 680 » — c'est-à-dire un numérateur sans
    /// dénominateur, sur une première sauvegarde qui durera des dizaines
    /// d'heures et sera reprise des dizaines de fois. Or c'est exactement la
    /// question qu'on se pose en ouvrant la fenêtre : où ça en est.
    ///
    /// Optionnel, et il doit le rester : Kopia met plusieurs minutes à estimer,
    /// une tentative coupée avant peut n'avoir jamais rien su. Une absence
    /// s'affiche comme une absence, jamais comme un zéro.
    public var estimatedBytes: Int64?

    /// **La seule définition de « réussi » du dépôt.** Elle exige la preuve
    /// *et* sa confirmation. Le journal, l'interface et la politique de
    /// planification passent tous par ici — il n'y a pas de deuxième avis.
    public var succeeded: Bool { proof?.isTrustworthy == true }

    public init(
        id: UUID,
        startedAt: Date,
        finishedAt: Date? = nil,
        trigger: BackupTrigger,
        proof: SnapshotProof? = nil,
        failure: BackupFailure? = nil,
        uploadedBytes: Int64? = nil,
        estimatedBytes: Int64? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.trigger = trigger
        self.proof = proof
        self.failure = failure
        self.uploadedBytes = uploadedBytes
        self.estimatedBytes = estimatedBytes
    }
}

/// Ce qui a lancé une tentative.
public enum BackupTrigger: String, Codable, Sendable, Hashable {
    /// Le bouton « sauvegarder maintenant ».
    case manual
    /// L'échéance planifiée est arrivée pendant que la machine tournait.
    case scheduled
    /// L'échéance était passée depuis longtemps — Mac éteint, veille prolongée.
    case catchUp
    /// La chaîne est repassée verte après une attente réseau.
    case networkReturned
    /// Reprise d'un run interrompu.
    case resume
}

// MARK: - L'état partagé entre les deux processus

/// L'instantané léger qu'un run sans interface publie pendant qu'il travaille.
///
/// `BackupPhase` reste l'état complet d'une tentative pilotée par la fenêtre.
/// Le LaunchAgent, lui, vit dans un autre processus : sans un petit contrat sur
/// disque, sa progression meurt dans sa propre mémoire et l'interface affiche
/// « Sauvegarder maintenant » pendant que Kopia travaille déjà. Ce type ne
/// porte que ce que l'autre processus peut affirmer à l'instant présent.
public struct BackupRuntimeStatus: Codable, Sendable, Hashable {
    public enum Stage: String, Codable, Sendable, Hashable {
        case running
        case verifying
    }

    public var attemptID: UUID
    public var trigger: BackupTrigger
    public var startedAt: Date
    public var updatedAt: Date
    public var stage: Stage
    public var progress: BackupProgress

    public init(
        attemptID: UUID,
        trigger: BackupTrigger,
        startedAt: Date,
        updatedAt: Date,
        stage: Stage,
        progress: BackupProgress = BackupProgress()
    ) {
        self.attemptID = attemptID
        self.trigger = trigger
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.stage = stage
        self.progress = progress
    }

    /// La forme déjà comprise par toutes les vues de progression.
    public var phase: BackupPhase {
        switch stage {
        case .running: .running(progress)
        case .verifying: .verifying
        }
    }
}

// MARK: - La configuration

/// Tout ce qui distingue ce Mac d'un autre. **Aucun secret ici.**
///
/// Les deux secrets — la clé secrète S3 et le mot de passe de dépôt, qui est
/// aussi la clé de chiffrement de bout en bout — vivent dans le trousseau et
/// nulle part ailleurs. Ce type est sérialisé en clair dans le dossier de
/// support de l'application ; ce qu'il contient doit pouvoir être lu par-dessus
/// l'épaule sans conséquence.
///
/// **`sourcePaths` n'a pas de valeur par défaut littérale** : le dossier
/// personnel se résout à l'exécution. Le frère du propriétaire a la même
/// application, son seau, ses clés, son mot de passe de dépôt — un seul chemin
/// écrit en dur ici et l'application ne serait juste que sur une machine.
public struct BackupConfiguration: Codable, Sendable, Hashable {
    public var s3Endpoint: String
    public var s3Bucket: String
    public var s3Region: String
    public var disableTLS: Bool
    /// L'**identifiant** de clé, qui n'est pas un secret. La clé secrète est au
    /// trousseau.
    public var s3AccessKeyID: String

    public var sourcePaths: [String]
    public var ignoreRules: [String]

    /// L'intervalle voulu entre deux sauvegardes réussies.
    public var intervalHours: Double

    /// Le nom du pair Tailscale à surveiller (maillon 2) et son adresse
    /// (maillons 3 à 5).
    public var tailscaleMinioNodeName: String
    public var minioTailscaleIP: String

    public var onBatteryPolicy: BatteryPolicy
    /// Le délai au-delà duquel une sonde est déclarée morte. Généreux sur le
    /// dépôt, serré sur le TCP.
    public var probeTimeout: TimeInterval
    public var repositoryTimeout: TimeInterval

    /// Le délai au-delà duquel une sauvegarde cesse d'être « à jour ».
    ///
    /// **Le double de l'intervalle promis, et il n'y a qu'un endroit qui le
    /// décide.** La formule vivait en deux exemplaires — dans le contrôleur et
    /// dans la vue — et deux exemplaires d'une même règle finissent toujours
    /// par diverger : c'est déjà arrivé dans ce module avec le comptage des
    /// échecs consécutifs.
    ///
    /// Pourquoi le double : une échéance manquée arrive pour mille raisons
    /// banales — le portable était fermé, le réseau a sauté un quart d'heure.
    /// Deux d'affilée ne sont plus une coïncidence.
    public var stalenessThreshold: TimeInterval { intervalHours * 2 * 3600 }

    /// Faux tant que l'utilisateur n'a pas terminé le provisionnement. Une
    /// configuration incomplète ne doit jamais faire tourner un run.
    public var isEnabled: Bool

    public init(
        s3Endpoint: String,
        s3Bucket: String,
        s3Region: String,
        disableTLS: Bool,
        s3AccessKeyID: String,
        sourcePaths: [String],
        ignoreRules: [String],
        intervalHours: Double,
        tailscaleMinioNodeName: String,
        minioTailscaleIP: String,
        onBatteryPolicy: BatteryPolicy,
        probeTimeout: TimeInterval,
        repositoryTimeout: TimeInterval,
        isEnabled: Bool
    ) {
        self.s3Endpoint = s3Endpoint
        self.s3Bucket = s3Bucket
        self.s3Region = s3Region
        self.disableTLS = disableTLS
        self.s3AccessKeyID = s3AccessKeyID
        self.sourcePaths = sourcePaths
        self.ignoreRules = ignoreRules
        self.intervalHours = intervalHours
        self.tailscaleMinioNodeName = tailscaleMinioNodeName
        self.minioTailscaleIP = minioTailscaleIP
        self.onBatteryPolicy = onBatteryPolicy
        self.probeTimeout = probeTimeout
        self.repositoryTimeout = repositoryTimeout
        self.isEnabled = isEnabled
    }
}

/// Ce qu'on fait sur batterie.
///
/// **Le seuil de secours n'est pas un détail.** Différer sur batterie est
/// raisonnable une journée ; le faire sans borne transforme un réglage de
/// confort en absence de sauvegarde, et personne ne s'en aperçoit — c'est
/// littéralement la panne dont ce projet est né. Au-delà de
/// `forceAfterHours`, on sauvegarde quel que soit l'état de l'alimentation.
public enum BatteryPolicy: Codable, Sendable, Hashable {
    /// Sauvegarder sans regarder l'alimentation.
    case always
    /// Attendre le secteur, mais pas au-delà de `forceAfterHours` de retard.
    case waitForPower(forceAfterHours: Double)
}
