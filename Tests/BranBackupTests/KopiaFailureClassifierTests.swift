import Foundation
import Testing
@testable import BranBackup

/// **Ce que ce fichier protège** : que le classifieur ne se trompe jamais
/// dans le sens de l'optimisme. Chaque cas ici reproduit un piège documenté
/// dans `KopiaFailureClassifier` — un code de sortie qui ment, un résumé
/// d'agrégation qui masque la vraie cause, de la maintenance qui ressemble à
/// une erreur, un secret qui traîne dans le texte qu'on va journaliser. Les
/// trois premiers textes sont ceux réellement relevés le 02/09/2026 sur ce
/// dépôt avec kopia 0.23.1 ; les familles de transport et les refus S3 sont
/// construits sur la forme connue des messages de l'AWS SDK que kopia
/// relaie, faute d'avoir pu les provoquer sur ce Mac sans casser MinIO.
@Suite("Le classement des échecs de Kopia")
struct KopiaFailureClassifierTests {

    // MARK: - Les trois textes réels

    @Test("Un mauvais mot de passe de dépôt se classe en authentification, sur le maillon d'ouverture")
    func realPasswordError() {
        let raw = """
        failed to open repository: unable to create format manager: invalid repository password
        open repository: unable to open repository: unable to create format manager: invalid repository password
        """
        let failure = KopiaFailureClassifier.classify(
            stderr: raw, exitCode: 2, wasCancelled: false, signal: nil)
        #expect(failure?.kind == .authentication)
        #expect(failure?.link == .repositoryOpens)
        #expect(failure?.kind.deservesRetry == false)
        #expect(failure?.summary.isEmpty == false)
        // rawOutput porte le texte intégral, pas un résumé.
        #expect(failure?.rawOutput.contains("invalid repository password") == true)
    }

    @Test("Une source absente se classe en stockage, et nomme le chemin en cause")
    func realSourceError() {
        let raw = """
        Snapshotting quelquun@mac-de-quelquun:/chemin/qui/nexiste/pas ...
        encountered 2 errors:
        failed to prepare source: unable to get local filesystem entry: resolveSymlink: stat: lstat /chemin/qui/nexiste/pas: no such file or directory
        upload error: unsupported source: quelquun@mac-de-quelquun:/chemin/qui/nexiste/pas
        """
        let failure = KopiaFailureClassifier.classify(
            stderr: raw, exitCode: 1, wasCancelled: false, signal: nil)
        #expect(failure?.kind == .storage)
        #expect(failure?.kind.deservesRetry == false)
        // Le chemin réel est extrait du texte, jamais recopié en dur ici.
        #expect(failure?.summary.contains("/chemin/qui/nexiste/pas") == true)
    }

    @Test("Un dépôt jamais connecté se classe en configuration manquante")
    func realNotConnectedError() {
        let raw = "open repository: repository is not connected. See https://kopia.io/docs/repositories/"
        let failure = KopiaFailureClassifier.classify(
            stderr: raw, exitCode: 1, wasCancelled: false, signal: nil)
        #expect(failure?.kind == .notConfigured)
        #expect(failure?.kind.deservesRetry == false)
    }

    // MARK: - Le code de sortie ment

    @Test("Un code de sortie 0 accompagné d'un texte d'erreur reconnu donne quand même un échec")
    func exitZeroWithKnownErrorTextIsStillAFailure() {
        // Mesuré sur ce Mac : `kopia repository status` avec un mauvais mot
        // de passe a écrit son erreur alors que le shell a vu un code 0.
        let raw = "open repository: unable to open repository: unable to create format manager: invalid repository password"
        let failure = KopiaFailureClassifier.classify(
            stderr: raw, exitCode: 0, wasCancelled: false, signal: nil)
        #expect(failure != nil)
        #expect(failure?.kind == .authentication)
    }

    @Test("Une sortie vraiment propre, code 0 et rien à lire, ne produit aucun échec")
    func trulyCleanOutputProducesNothing() {
        let failure = KopiaFailureClassifier.classify(
            stderr: "", exitCode: 0, wasCancelled: false, signal: nil)
        #expect(failure == nil)
    }

    @Test("Un code non nul sans une ligne exploitable reste un échec, pas un succès qu'on invente")
    func nonZeroExitWithNoTextIsUnparseableNotSilent() {
        let failure = KopiaFailureClassifier.classify(
            stderr: "   \n  ", exitCode: 1, wasCancelled: false, signal: nil)
        #expect(failure?.kind == .unparseable)
    }

    // MARK: - Le résumé d'agrégation

    @Test("« encountered N errors: » se classe sur la première cause nommée, pas sur le résumé")
    func aggregatedErrorsUseTheFirstCause() {
        // Construit pour que les deux causes appartiennent à deux genres
        // différents : si le classifieur regardait la deuxième ligne, ou une
        // combinaison des deux, ce test échouerait sur `.network` plutôt que
        // sur `.authentication`.
        let raw = """
        encountered 2 errors:
        open repository: unable to open repository: unable to create format manager: invalid repository password
        dial tcp 10.0.0.5:9000: connect: connection refused
        """
        let failure = KopiaFailureClassifier.classify(
            stderr: raw, exitCode: 1, wasCancelled: false, signal: nil)
        #expect(failure?.kind == .authentication)
        #expect(failure?.link == .repositoryOpens)
    }

    @Test("Le texte réel de source absente se classe bien sur sa première cause, malgré deux motifs")
    func realAggregatedSourceErrorAlsoUsesTheFirstCause() {
        // Ici les deux lignes de cause donnent le même genre (`.storage`)
        // dans le texte réel — ce test garantit que ce n'est pas un hasard
        // d'implémentation : la première ligne matchée est bien celle du
        // `lstat`, dont le chemin apparaît dans le résumé.
        let raw = """
        Snapshotting quelquun@mac-de-quelquun:/chemin/qui/nexiste/pas ...
        encountered 2 errors:
        failed to prepare source: unable to get local filesystem entry: resolveSymlink: stat: lstat /chemin/qui/nexiste/pas: no such file or directory
        upload error: unsupported source: quelquun@mac-de-quelquun:/chemin/qui/nexiste/pas
        """
        let failure = KopiaFailureClassifier.classify(
            stderr: raw, exitCode: 1, wasCancelled: false, signal: nil)
        #expect(failure?.summary.contains("lstat") == false)
        #expect(failure?.summary.contains("/chemin/qui/nexiste/pas") == true)
    }

    // MARK: - Les familles de transport

    @Test("Connexion refusée : réseau, maillon S3, réessai mérité")
    func connectionRefused() {
        let raw = "open repository: unable to open repository: unable to create storage: dial tcp 10.0.0.5:9000: connect: connection refused"
        let failure = KopiaFailureClassifier.classify(
            stderr: raw, exitCode: 1, wasCancelled: false, signal: nil)
        #expect(failure?.kind == .network)
        #expect(failure?.link == .s3Reachable)
        #expect(failure?.kind.deservesRetry == true)
        // Le port est extrait du texte : le message nomme où ça casse.
        #expect(failure?.summary.contains("9000") == true)
    }

    @Test("Pas de route vers l'hôte : réseau")
    func noRouteToHost() {
        let raw = "dial tcp 10.0.0.5:9000: connect: no route to host"
        let failure = KopiaFailureClassifier.classify(
            stderr: raw, exitCode: 1, wasCancelled: false, signal: nil)
        #expect(failure?.kind == .network)
        #expect(failure?.kind.deservesRetry == true)
    }

    @Test("Délai d'attente TCP : réseau")
    func ioTimeout() {
        let raw = "dial tcp 10.0.0.5:9000: i/o timeout"
        let failure = KopiaFailureClassifier.classify(
            stderr: raw, exitCode: 1, wasCancelled: false, signal: nil)
        #expect(failure?.kind == .network)
        #expect(failure?.kind.deservesRetry == true)
    }

    @Test("Délai de contexte dépassé : réseau")
    func contextDeadlineExceeded() {
        let raw = #"Get "http://10.0.0.5:9000/example-bucket/": context deadline exceeded"#
        let failure = KopiaFailureClassifier.classify(
            stderr: raw, exitCode: 1, wasCancelled: false, signal: nil)
        #expect(failure?.kind == .network)
        #expect(failure?.kind.deservesRetry == true)
    }

    @Test("Coupure EOF en plein transfert : réseau")
    func unexpectedEOF() {
        let raw = #"Put "http://10.0.0.5:9000/example-bucket/xyz": unexpected EOF"#
        let failure = KopiaFailureClassifier.classify(
            stderr: raw, exitCode: 1, wasCancelled: false, signal: nil)
        #expect(failure?.kind == .network)
        #expect(failure?.kind.deservesRetry == true)
    }

    // MARK: - Les refus S3

    @Test("Identifiants S3 refusés : authentification, maillon du compartiment")
    func s3AccessDenied() {
        let raw = "open repository: unable to open repository: unable to create storage: AccessDenied: Access Denied status code: 403, request id: ABCDEF"
        let failure = KopiaFailureClassifier.classify(
            stderr: raw, exitCode: 1, wasCancelled: false, signal: nil)
        #expect(failure?.kind == .authentication)
        #expect(failure?.link == .bucketReachable)
        #expect(failure?.kind.deservesRetry == false)
    }

    @Test("Compartiment introuvable : configuration manquante, pas dépôt corrompu")
    func s3NoSuchBucket() {
        let raw = "open repository: unable to open repository: unable to create storage: NoSuchBucket: The specified bucket does not exist status code: 404"
        let failure = KopiaFailureClassifier.classify(
            stderr: raw, exitCode: 1, wasCancelled: false, signal: nil)
        #expect(failure?.kind == .notConfigured)
        #expect(failure?.link == .bucketReachable)
    }

    // MARK: - Le stockage local

    @Test("Disque plein : stockage")
    func diskFull() {
        let raw = "unable to write pack: no space left on device"
        let failure = KopiaFailureClassifier.classify(
            stderr: raw, exitCode: 1, wasCancelled: false, signal: nil)
        #expect(failure?.kind == .storage)
        #expect(failure?.kind.deservesRetry == false)
    }

    @Test("Quota disque dépassé : stockage")
    func quotaExceeded() {
        let raw = "unable to write pack: disk quota exceeded"
        let failure = KopiaFailureClassifier.classify(
            stderr: raw, exitCode: 1, wasCancelled: false, signal: nil)
        #expect(failure?.kind == .storage)
        #expect(failure?.kind.deservesRetry == false)
    }

    // MARK: - L'interruption

    @Test("Un SIGTERM se classe en interruption, pas en échec, et mérite un réessai")
    func sigterm() {
        let failure = KopiaFailureClassifier.classify(
            stderr: "", exitCode: -1, wasCancelled: false, signal: 15)
        #expect(failure?.kind == .interrupted)
        #expect(failure?.kind.deservesRetry == true)
        #expect(failure?.suggestedAction == nil)
    }

    @Test("Une annulation sans signal — veille, bouton annuler — se classe aussi en interruption")
    func cancelledWithoutSignal() {
        let failure = KopiaFailureClassifier.classify(
            stderr: "some partial output", exitCode: -1, wasCancelled: true, signal: nil)
        #expect(failure?.kind == .interrupted)
        #expect(failure?.kind.deservesRetry == true)
    }

    @Test("L'interruption prime sur tout texte d'erreur qui aurait eu le temps de s'écrire")
    func interruptionOutranksErrorText() {
        // Le processus tué a quand même eu le temps d'écrire une ligne
        // d'erreur réseau avant de mourir ; ce n'est pas ça qu'il faut
        // annoncer, mais l'interruption elle-même.
        let raw = "dial tcp 10.0.0.5:9000: connect: connection refused"
        let failure = KopiaFailureClassifier.classify(
            stderr: raw, exitCode: -1, wasCancelled: false, signal: 9)
        #expect(failure?.kind == .interrupted)
    }

    // MARK: - La maintenance n'est pas une erreur

    @Test("Les lignes de maintenance en cours de run ne produisent aucun échec")
    func maintenanceLinesProduceNoFailure() {
        let raw = """
        Running full maintenance...
        GC found 896989 unused contents (140.3 GB)
        Compacting an eligible uncompacted epoch...
        Finished full maintenance.
        """
        let failure = KopiaFailureClassifier.classify(
            stderr: raw, exitCode: 0, wasCancelled: false, signal: nil)
        #expect(failure == nil)
    }

    @Test("La progression de « snapshot verify » ne produit aucun échec")
    func verifyProgressProducesNoFailure() {
        let raw = """
        Processed 7 objects (23 MB). Read 4 files (23 MB).
        Processed 8 objects (43 MB). Read 5 files (43 MB).
        Finished processing 18 objects (243 MB). Read 15 files (243 MB).
        """
        let failure = KopiaFailureClassifier.classify(
            stderr: raw, exitCode: 0, wasCancelled: false, signal: nil)
        #expect(failure == nil)
    }

    @Test("La bannière de début de snapshot, seule, ne produit aucun échec")
    func snapshottingBannerAloneProducesNoFailure() {
        let raw = "Snapshotting quelquun@mac-de-quelquun:/private/tmp/src ..."
        let failure = KopiaFailureClassifier.classify(
            stderr: raw, exitCode: 0, wasCancelled: false, signal: nil)
        #expect(failure == nil)
    }

    // MARK: - L'inconnu

    @Test("Une sortie inconnue donne .unparseable, jamais un genre inventé par optimisme")
    func unknownOutputIsUnparseable() {
        let raw = "kopia: something-nobody-has-seen-before happened, code XKCD-42"
        let failure = KopiaFailureClassifier.classify(
            stderr: raw, exitCode: 1, wasCancelled: false, signal: nil)
        #expect(failure?.kind == .unparseable)
        #expect(failure?.link == nil)
        #expect(failure?.kind.deservesRetry == false)
        // Le texte brut reste intégral : c'est la seule chose qu'on peut
        // montrer à l'utilisateur pour un cas qu'on ne sait pas nommer.
        #expect(failure?.rawOutput == raw)
    }

    @Test("Du texte inconnu mêlé à de la maintenance reste non reconnu, pas absous")
    func unknownTextAmongMaintenanceStillCounts() {
        let raw = """
        Running full maintenance...
        GC found 896989 unused contents (140.3 GB)
        a completely new diagnostic line kopia never wrote before
        Finished full maintenance.
        """
        let failure = KopiaFailureClassifier.classify(
            stderr: raw, exitCode: 0, wasCancelled: false, signal: nil)
        #expect(failure?.kind == .unparseable)
    }

    // MARK: - deservesRetry, exactement sur ce qui doit l'être

    @Test("deservesRetry n'est vrai que pour le réseau et l'interruption parmi les cas produits ici")
    func deservesRetryIsPreciselyTargeted() {
        let retryable: [BackupFailure] = [
            KopiaFailureClassifier.classify(
                stderr: "dial tcp 10.0.0.5:9000: connect: connection refused",
                exitCode: 1, wasCancelled: false, signal: nil)!,
            KopiaFailureClassifier.classify(
                stderr: "", exitCode: -1, wasCancelled: true, signal: nil)!,
        ]
        for failure in retryable {
            #expect(failure.kind.deservesRetry == true)
        }

        let notRetryable: [BackupFailure] = [
            KopiaFailureClassifier.classify(
                stderr: "invalid repository password", exitCode: 1, wasCancelled: false, signal: nil)!,
            KopiaFailureClassifier.classify(
                stderr: "unable to write pack: no space left on device",
                exitCode: 1, wasCancelled: false, signal: nil)!,
            KopiaFailureClassifier.classify(
                stderr: "repository is not connected", exitCode: 1, wasCancelled: false, signal: nil)!,
            KopiaFailureClassifier.classify(
                stderr: "kopia: totally unknown output", exitCode: 1, wasCancelled: false, signal: nil)!,
            KopiaFailureClassifier.partialSnapshotFailure(errorCount: 2, rawOutput: "id: abc"),
        ]
        for failure in notRetryable {
            #expect(failure.kind.deservesRetry == false)
        }
    }

    // MARK: - Le snapshot partiel

    @Test("Un snapshot partiel se formule au singulier et au pluriel, et ne réessaie pas")
    func partialSnapshotWording() {
        let one = KopiaFailureClassifier.partialSnapshotFailure(errorCount: 1, rawOutput: "id: abc")
        #expect(one.kind == .partialSnapshot)
        #expect(one.summary.contains("1 fichier n'a pas"))
        #expect(one.kind.deservesRetry == false)

        let many = KopiaFailureClassifier.partialSnapshotFailure(errorCount: 3, rawOutput: "id: abc")
        #expect(many.summary.contains("3 fichiers n'a pas") == false)
        #expect(many.summary.contains("3 fichiers"))
    }

    // MARK: - Le masquage des secrets

    @Test("Une clé secrète S3 suivie d'une valeur est masquée")
    func secretAccessKeyIsMasked() {
        let raw = #"{"bucket":"example-bucket","accessKeyID":"AKIAIOSFODNN7EXAMPLE","secretAccessKey":"wJalrXUtnFEMIkAKIAIOSFODNN7SECRET"}"#
        let masked = KopiaFailureClassifier.maskSecrets(in: raw)
        #expect(masked.contains("wJalrXUtnFEMIkAKIAIOSFODNN7SECRET") == false)
        #expect(masked.contains("********"))
        // L'identifiant de clé n'est pas un secret et doit rester lisible —
        // c'est ce qui permet de vérifier qu'on parle au bon compte S3.
        #expect(masked.contains("AKIAIOSFODNN7EXAMPLE"))
    }

    @Test("Une variable d'environnement KOPIA_PASSWORD recopiée dans un journal est masquée")
    func kopiaPasswordEnvVarIsMasked() {
        let raw = "child process launched with KOPIA_PASSWORD=hunter2ExtremelyLongSecretValue in its environment"
        let masked = KopiaFailureClassifier.maskSecrets(in: raw)
        #expect(masked.contains("hunter2ExtremelyLongSecretValue") == false)
        #expect(masked.contains("KOPIA_PASSWORD"))
    }

    @Test("Un en-tête Authorization est masqué")
    func authorizationHeaderIsMasked() {
        let raw = "request failed: Authorization: eyJhbGciOiJIUzI1NiJ9.longtoken.value rejected by server"
        let masked = KopiaFailureClassifier.maskSecrets(in: raw)
        #expect(masked.contains("eyJhbGciOiJIUzI1NiJ9.longtoken.value") == false)
    }

    /// **Le jeton à deux mots, qui passait entier.** Le motif de masquage
    /// s'arrêtait au premier espace : sur `Authorization: Bearer <jeton>`,
    /// seul le mot `Bearer` était remplacé et le jeton continuait sa route
    /// dans `rawOutput`, dans le journal, et dans le presse-papiers du bouton
    /// « copier le diagnostic ».
    @Test("Un jeton Bearer, qui vient après un espace, est masqué lui aussi")
    func bearerTokenAfterASpaceIsMasked() {
        let raw = "PUT failed: Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.charge.utile"
        let masked = KopiaFailureClassifier.maskSecrets(in: raw)
        #expect(masked.contains("eyJhbGciOiJIUzI1NiJ9.charge.utile") == false)
        #expect(masked.contains("Bearer") == false)
        // Le nom de l'en-tête reste lisible : c'est lui qui dit de quelle
        // requête on parle.
        #expect(masked.contains("Authorization"))
    }

    /// La même fuite, dans sa forme S3 : une signature AWS SigV4 est faite de
    /// quatre composants séparés par des espaces et des virgules. Le motif
    /// étroit n'en masquait que le nom de l'algorithme.
    @Test("Une signature AWS à plusieurs composants est masquée en entier")
    func awsSignatureIsFullyMasked() {
        let raw = "Authorization=AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20260902/us-east-1/s3/aws4_request, "
            + "SignedHeaders=host;x-amz-date, Signature=b4f2c1d0e9a8b7c6d5e4f3a2b1c0d9e8f7a6b5c4d3e2f1a0b9c8d7e6f5a4b3c2"
        let masked = KopiaFailureClassifier.maskSecrets(in: raw)
        #expect(masked.contains("b4f2c1d0e9a8b7c6d5e4f3a2b1c0d9e8f7a6b5c4d3e2f1a0b9c8d7e6f5a4b3c2") == false)
        #expect(masked.contains("SignedHeaders") == false)
        #expect(masked.contains("AWS4-HMAC-SHA256") == false)
    }

    /// La contrepartie assumée : le masquage s'arrête à la fin de ligne, il
    /// n'avale pas le reste du diagnostic. C'est cette borne qui rend le
    /// compromis acceptable — un stderr de kopia fait des dizaines de lignes,
    /// une seule est sacrifiée.
    @Test("Le masquage d'un en-tête Authorization s'arrête à la fin de sa ligne")
    func authorizationMaskingStopsAtEndOfLine() {
        let raw = "Authorization: Bearer secretvaluehere\nerror: AccessDenied status code: 403"
        let masked = KopiaFailureClassifier.maskSecrets(in: raw)
        #expect(masked.contains("secretvaluehere") == false)
        #expect(masked.contains("AccessDenied status code: 403"))
    }

    @Test("Le mot « password » employé seul dans une phrase, sans valeur derrière, n'est pas mutilé")
    func bareWordPasswordSurvives() {
        // C'est le texte réel du dépôt : si le masquage était trop large, ce
        // diagnostic deviendrait illisible pour l'utilisateur.
        let raw = "unable to create format manager: invalid repository password"
        let masked = KopiaFailureClassifier.maskSecrets(in: raw)
        #expect(masked == raw)
    }

    @Test("Le masquage s'applique au rawOutput porté par un échec classé, pas seulement en test isolé")
    func classifiedFailureCarriesMaskedRawOutput() {
        let raw = #"open repository: unable to create storage: AccessDenied status code: 403; secretAccessKey:AKIAWOULDBESECRETVALUE12345"#
        let failure = KopiaFailureClassifier.classify(
            stderr: raw, exitCode: 1, wasCancelled: false, signal: nil)
        #expect(failure?.rawOutput.contains("AKIAWOULDBESECRETVALUE12345") == false)
    }
}

/// **La sortie d'un run qui a vraiment réussi, et qui a vraiment été classée
/// en échec.**
///
/// Relevée le 02/09/2026 dans le journal de bran, au premier `--backup-run`
/// exécuté depuis le paquet signé. Le snapshot était complet — 51,3 Mo montés,
/// 103 fichiers, la maintenance rapide passée derrière — et l'écran a annoncé
/// « Kopia a rendu un message que bran ne sait pas encore interpréter ».
///
/// Deux causes, toutes deux invisibles aux échantillons figés : le découpage
/// ne se faisait que sur les sauts de ligne alors que la progression est
/// séparée par des retours chariot, et la liste des lignes de maintenance ne
/// portait que le cycle complet, pas le cycle rapide.
///
/// Ce test existe pour que ce run-là reste, pour toujours, un succès.
@Suite("La sortie d'un run réussi n'est pas un échec")
struct SuccessfulRunIsNotAFailureTests {

    /// Le texte exact, retours chariot compris.
    private static let realSuccessStderr =
        "Snapshotting quelquun@mac-de-quelquun:/Users/…/Music ...\n"
        + "\r | 4 hashing, 0 hashed (309 B), 0 cached (0 B), uploaded 0 B, estimating..."
        + "\r / 1 hashing, 96 hashed (23.7 MB), 0 cached (0 B), uploaded 21.3 MB, estimated 51.3 MB (46.3%) 21s left"
        + "\r - 0 hashing, 103 hashed (51.3 MB), 0 cached (0 B), uploaded 46.3 MB, estimated 51.3 MB (100.0%) 0s left"
        + "\r * 0 hashing, 103 hashed (51.3 MB), 0 cached (0 B), uploaded 46.3 MB, estimated 51.3 MB (100.0%) 0s left\n"
        + "Running quick maintenance...\n"
        + "Compacting an eligible uncompacted epoch...\n"
        + "Advancing epoch markers...\n"
        + "Finished quick maintenance.\n"

    @Test("Progression et maintenance rapide ne produisent aucun échec")
    func realSuccessProducesNoFailure() {
        let verdict = KopiaFailureClassifier.classify(
            stderr: Self.realSuccessStderr, exitCode: 0, wasCancelled: false, signal: nil)
        #expect(verdict == nil)
    }

    @Test("Une vraie erreur noyée dans la progression est quand même trouvée")
    func realErrorSurvivesTheNoise() {
        // Le correctif ne doit pas transformer le flux en angle mort : c'est
        // le risque exact d'élargir une liste de « lignes inoffensives ».
        let polluted = Self.realSuccessStderr
            + "failed to open repository: unable to create format manager: invalid repository password\n"
        let verdict = KopiaFailureClassifier.classify(
            stderr: polluted, exitCode: 0, wasCancelled: false, signal: nil)
        #expect(verdict?.kind == .authentication)
    }

    @Test("Une ligne inconnue contenant « hashing » n'est pas prise pour de la progression")
    func lookalikeIsNotProgress() {
        // La reconnaissance porte sur la forme complète, préfixe de rotation
        // compris — pas sur la présence du mot.
        let verdict = KopiaFailureClassifier.classify(
            stderr: "internal error while hashing, aborting\n",
            exitCode: 1, wasCancelled: false, signal: nil)
        #expect(verdict?.kind == .unparseable)
    }
}

/// **Les trois chiffres qui traversent un compteur.**
///
/// Trouvé par une relecture adverse, jamais par une exécution : `classifyLine`
/// cherchait « 403 » et « 404 » en sous-chaîne, sur toutes les lignes, avant
/// même le filtre du bruit. Or les compteurs de Kopia défilent pendant des
/// heures — qu'un seul passe par 1403 ou 40412 n'est pas une éventualité,
/// c'est une certitude.
///
/// Le coût aurait dépassé le message faux : `.authentication` ne se réessaie
/// pas, donc un chiffre malheureux désarmait la reprise automatique d'un run
/// par ailleurs sain.
@Suite("Un compteur de progression n'est pas un code HTTP")
struct HTTPStatusLookalikeTests {

    @Test("Une ligne de progression qui contient « 403 » ne devient pas une erreur d'identifiants")
    func progressCounterIsNotAnAuthFailure() {
        let stderr = "\r - 5 hashing, 1403 hashed (233 MB), 0 cached (0 B), uploaded 215.2 MB, estimated 240 MB (97.1%) 0s left\n"
        #expect(KopiaFailureClassifier.classify(
            stderr: stderr, exitCode: 0, wasCancelled: false, signal: nil) == nil)
    }

    @Test("Une ligne de progression qui contient « 404 » ne devient pas un seau introuvable")
    func progressCounterIsNotAMissingBucket() {
        let stderr = "\r / 2 hashing, 40412 hashed (9.4 GB), 0 cached (0 B), uploaded 8.1 GB, estimated 12 GB (78.0%) 9m2s left\n"
        #expect(KopiaFailureClassifier.classify(
            stderr: stderr, exitCode: 0, wasCancelled: false, signal: nil) == nil)
    }

    @Test("Un vrai 403 annoncé comme code de statut est toujours reconnu")
    func realStatusCodeIsStillCaught() {
        let stderr = "error uploading blob: RequestError: send request failed, status code: 403\n"
        #expect(KopiaFailureClassifier.classify(
            stderr: stderr, exitCode: 1, wasCancelled: false, signal: nil)?.kind == .authentication)
    }

    @Test("Un vrai 404 annoncé comme code de statut est toujours reconnu")
    func realNotFoundIsStillCaught() {
        let stderr = "unable to list blobs: HTTP 404\n"
        #expect(KopiaFailureClassifier.classify(
            stderr: stderr, exitCode: 1, wasCancelled: false, signal: nil)?.kind == .notConfigured)
    }

    @Test("Les noms d'erreur S3 restent reconnus sans dépendre d'un chiffre")
    func namedS3ErrorsStillWork() {
        #expect(KopiaFailureClassifier.classify(
            stderr: "AccessDenied: signature mismatch\n", exitCode: 1,
            wasCancelled: false, signal: nil)?.kind == .authentication)
        #expect(KopiaFailureClassifier.classify(
            stderr: "NoSuchBucket: the specified bucket does not exist\n", exitCode: 1,
            wasCancelled: false, signal: nil)?.kind == .notConfigured)
    }

    // MARK: - Les erreurs ignorées ne sont pas des échecs

    /// **La sortie réelle du premier snapshot réussi de ce Mac**, copiée du
    /// journal de bran le 02/09/2026. Kopia avait écrit 1 571 967 fichiers et
    /// `snapshot verify` les relisait sans une seule erreur — pourtant
    /// `classify` rendait `.unparseable`, parce que la politique porte
    /// `Ignore file read errors: true`, que kopia obéit en annonçant chaque
    /// fichier sauté, et qu'il sort alors en code non nul.
    @Test("Une sortie qui n'annonce que des erreurs ignorées n'est pas un échec")
    func ignoredErrorsAreNotAFailure() {
        let stderr = """
        Snapshotting whyteduke@macbook-pro-de-whyte-2:/Users/whyteduke ...
        ! Ignored error when processing "Library/Application Support/FileProvider/AC36B9EA/wharf/tombstone/a": unable to open file: unable to open local file
        ! Ignored error when processing "Library/Application Support/FileProvider/D0184045/wharf/tombstone/a": unable to open file: unable to open local file
        Ignored 132 error(s) while snapshotting whyteduke@macbook-pro-de-whyte-2:/Users/whyteduke.
        Running quick maintenance...
        Compacting an eligible uncompacted epoch...
        Advancing epoch markers...
        Finished quick maintenance.
        """
        #expect(KopiaFailureClassifier.classify(
            stderr: stderr, exitCode: 1, wasCancelled: false, signal: nil) == nil)
    }

    /// L'élision est le texte de bran, pas celui de kopia : ne pas la
    /// reconnaître revenait à traiter sa propre sortie comme un message
    /// inconnu. Le fragment de ligne de progression qu'elle laisse derrière
    /// elle — privé de son caractère de rotation — tombait dans le même trou.
    @Test("Le marqueur d'élision de bran et le fragment qu'il laisse ne sont pas des échecs")
    func branOwnElisionMarkerIsNotAFailure() {
        let stderr = """
        Snapshotting whyteduke@macbook-pro-de-whyte-2:/Users/whyteduke ...
        … [829755 octets de sortie élidés par bran — tête et fin conservées] …
        (132 errors ignored), estimating...
        Ignored 132 error(s) while snapshotting whyteduke@macbook-pro-de-whyte-2:/Users/whyteduke.
        """
        #expect(KopiaFailureClassifier.classify(
            stderr: stderr, exitCode: 1, wasCancelled: false, signal: nil) == nil)
    }

    /// Le contrepoint indispensable : écarter le bruit ne doit pas rendre
    /// sourd. Une vraie cause nommée, noyée au milieu des mêmes lignes
    /// ignorées, doit toujours ressortir.
    @Test("Une vraie erreur au milieu des erreurs ignorées se voit encore")
    func realFailureAmongIgnoredErrorsIsStillSeen() {
        let stderr = """
        Snapshotting whyteduke@macbook-pro-de-whyte-2:/Users/whyteduke ...
        ! Ignored error when processing "Library/Foo/bar": unable to open file
        NoSuchBucket: the specified bucket does not exist
        Ignored 3 error(s) while snapshotting whyteduke@macbook-pro-de-whyte-2:/Users/whyteduke.
        """
        #expect(KopiaFailureClassifier.classify(
            stderr: stderr, exitCode: 1, wasCancelled: false, signal: nil)?.kind == .notConfigured)
    }
}
