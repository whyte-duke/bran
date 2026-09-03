import BranBackup
import Darwin
import Foundation
import IOKit.ps
import os

/// **La sous-commande headless de la sauvegarde**, sur le motif de
/// `PasteboardAccessProbe.runIfRequested()` : un drapeau explicite, et une
/// sortie sans jamais afficher d'interface — pas de SwiftUI, pas de
/// `NSApplication`. C'est elle que le `LaunchAgent` installé par
/// `BackupAgentInstaller` invoque, une fois par heure, que bran soit ouvert
/// ou non.
///
/// ```
///   ./bran --backup-run
/// ```
///
/// ## La règle qui compte double ici
///
/// **Elle n'écrit jamais un succès qu'elle n'a pas confirmé.** C'est la même
/// règle que partout ailleurs dans cette fonctionnalité, mais ici elle pèse
/// plus : un run manuel affiche son résultat à l'écran, où un mensonge se
/// voit. Un run headless ne s'affiche nulle part — personne ne regarde cet
/// écran. Le journal qu'il écrit *est* la seule trace, et c'est pour ça
/// qu'aucun chemin de ce fichier ne doit pouvoir y déposer une preuve non
/// vérifiée.
///
/// ## Ce que ce fichier appelle, et qui l'écrit
///
/// `BackupConfigurationStore`, `ChainProbes`, `SchedulePolicy`,
/// `ChainEvaluator`, `BackupJournalModel`, `KopiaDriver`, `KopiaDriverFailure`
/// et `BackupEngine` viennent tous d'autres agents ; tous ont pu être lus tels
/// qu'écrits avant d'être appelés ici. Reste non vérifié à la relecture : le
/// maillon 6 (``repositoryOpensProbe()``) reconstruit un `LinkProbeResult` à
/// la main plutôt que d'appeler un éventuel `ChainProbes.repositoryOpens`,
/// que `ChainProbes.swift` suggère sans le fournir — voir le rapport de cet
/// agent.
enum BackupHeadlessRun {

    static let flag = "--backup-run"

    /// Passe outre l'échéance — voir la note dans ``runWithLockHeld(forced:)``.
    static let forceFlag = "--force"

    private static let log = Logger(subsystem: "com.opahventures.bran", category: "backup-headless")

    // MARK: - Les codes de sortie

    /// Distincts et documentés, pour qu'un `launchctl` ou un humain qui lit
    /// `launchctl list` puisse les lire sans rouvrir ce fichier.
    private enum ExitCode: Int32 {
        /// Une sauvegarde a été tentée, son snapshot a été relu dans le
        /// dépôt et il est digne de confiance (`SnapshotProof.isTrustworthy`).
        case success = 0
        /// Rien à faire maintenant : `SchedulePolicy` a dit d'attendre —
        /// échéance pas arrivée, réseau pas prêt, batterie, ou sauvegarde
        /// désactivée. Ce n'est **pas** une erreur : c'est une décision, sur
        /// l'horloge réelle, et rien n'a été tenté ni journalisé.
        case notDue = 1
        /// Le verrou de simultanéité était déjà tenu par un autre run —
        /// l'interface ou une exécution précédente encore en cours. Sortie
        /// volontaire, rien n'a été tenté ni journalisé.
        case alreadyRunning = 2
        /// La configuration existe mais n'a pas pu être lue (JSON corrompu,
        /// disque inaccessible) — distinct de « désactivée », qui n'est pas
        /// une erreur. Un opérateur doit regarder celui-ci.
        case configurationUnreadable = 3
        /// Une sauvegarde a été tentée et a échoué, ou son snapshot n'a pas
        /// pu être confirmé dans le dépôt. Le détail est dans le journal —
        /// `BackupJournal.readAll()` — jamais seulement dans ce code.
        case backupFailed = 4
        /// Un problème qu'aucun des cas ci-dessus ne nomme : le verrou
        /// lui-même n'a pas pu être pris (E/S), ou une incohérence interne.
        /// Filet de sécurité, pas un verdict sur la sauvegarde.
        case internalError = 5
    }

    // MARK: - Le point d'entrée

    /// - Returns: en pratique, ne rend jamais la main quand le drapeau est
    ///   présent : le processus sort (`exit`) avec un code de `ExitCode`
    ///   avant d'y revenir. C'est plus fort que « retourne `true` » — voir
    ///   `PasteboardAccessProbe` pour le patron dont celui-ci s'écarte
    ///   volontairement sur ce point, précisément parce qu'un `launchctl`
    ///   doit pouvoir lire un code de sortie distinct par issue.
    static func runIfRequested() -> Bool {
        guard CommandLine.arguments.contains(flag) else { return false }

        // `main()` est synchrone ; toute la logique ici est asynchrone
        // (réseau, disque, sous-processus). Le pont est celui de
        // `SpeedProbeReport.runIfRequested()` : un sémaphore qui bloque le
        // fil principal jusqu'à ce que la tâche ait fini.
        //
        // Le code de sortie traverse une frontière de fil : il est écrit dans
        // la tâche, lu sur le fil principal. Une variable capturée ne peut pas
        // faire ça sous concurrence stricte — pas même avec
        // `nonisolated(unsafe)`, qui couvre la variable mais laisse la
        // fermeture non `Sendable`. Une petite boîte verrouillée le dit
        // franchement et coûte trois lignes.
        //
        // Le sémaphore reste ce qui établit l'ordre : `wait()` ne rend la main
        // qu'après le `signal()` qui suit l'écriture. Le verrou n'est là que
        // pour que ce raisonnement n'ait pas à être cru sur parole.
        let outcome = ExitCodeBox()
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            outcome.set(await run())
            semaphore.signal()
        }
        semaphore.wait()
        exit(outcome.value)
    }

    /// Les octets montés, relevés depuis les rappels de progression.
    ///
    /// Ces rappels arrivent depuis les fils de lecture des tubes du
    /// sous-processus, d'où le verrou. On garde le **maximum** vu et non le
    /// dernier : Kopia republie un compteur cumulé, mais deux rappels peuvent
    /// se croiser, et un chiffre qui reculerait ferait sous-estimer ce qui est
    /// réellement parti.
    private final class UploadedBytesBox: @unchecked Sendable {
        private let lock = NSLock()
        private var highest: Int64 = 0
        private var estimate: Int64?

        func record(_ progress: BackupProgress) {
            lock.lock()
            highest = max(highest, progress.uploadedBytes)
            // La dernière estimation connue, pas la première : Kopia la corrige
            // en cours de route. Elle est écrite dans la tentative pour que
            // l'écran puisse dire « X sur environ Y » le lendemain matin, alors
            // que `BackupProgress` sera mort avec le processus.
            if let total = progress.estimatedBytes { estimate = total }
            lock.unlock()
        }

        var value: Int64 {
            lock.lock()
            defer { lock.unlock() }
            return highest
        }

        var estimated: Int64? {
            lock.lock()
            defer { lock.unlock() }
            return estimate
        }
    }

    /// Le code de sortie, transporté de la tâche vers le fil qui attend.
    private final class ExitCodeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = ExitCode.internalError.rawValue

        /// Par défaut, une erreur interne. **Le défaut compte** : si la tâche
        /// meurt sans rien écrire, on sort en erreur, jamais en succès.
        var value: Int32 {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }

        func set(_ code: Int32) {
            lock.lock()
            stored = code
            lock.unlock()
        }
    }

    // MARK: - La séquence

    private static func run() async -> Int32 {
        switch acquireLock() {
        case .failed(let error):
            log.error("verrou de sauvegarde : \(String(describing: error), privacy: .public)")
            print("impossible de prendre le verrou de sauvegarde : \(error)")
            return ExitCode.internalError.rawValue

        case .heldByAnotherProcess:
            // Sortie propre, sans rien écrire au journal : aucune tentative
            // n'a eu lieu, il n'y a donc rien à consigner. Écrire un échec
            // ici transformerait une contention normale — l'interface et le
            // job qui se chevauchent — en un faux signal d'alarme dans
            // l'historique.
            log.notice("un run de sauvegarde est déjà en cours ; abandon volontaire")
            print("un run de sauvegarde est déjà en cours ; on ne double pas kopia sur le même dépôt.")
            return ExitCode.alreadyRunning.rawValue

        case .acquired(let lock):
            defer { lock.release() }
            return await runWithLockHeld(forced: CommandLine.arguments.contains(forceFlag))
        }
    }

    private static func runWithLockHeld(forced: Bool) async -> Int32 {
        let configuration: BackupConfiguration
        do {
            configuration = try BackupConfigurationStore.load()
        } catch {
            log.error("configuration illisible : \(String(describing: error), privacy: .public)")
            print("configuration de sauvegarde illisible : \(error)")
            return ExitCode.configurationUnreadable.rawValue
        }

        guard configuration.isEnabled else {
            log.notice("sauvegarde désactivée ; rien à faire")
            print("la sauvegarde n'est pas activée ; rien à faire.")
            // Appelé même ici : c'est ce qui remet à zéro la date d'activation
            // retenue par `BackupAlerts`, pour qu'une réactivation dans six
            // mois ne réveille pas une alerte fondée sur l'ancienne.
            await BackupAlerts.checkAndFireIfNeeded(
                now: Date(), configuration: configuration,
                journal: BackupJournal.readAll().attempts, coverage: nil)
            return ExitCode.notDue.rawValue
        }

        // **L'évaluateur d'alerte tourne à chaque passage, pas seulement après
        // un succès.**
        //
        // Il n'était appelé que dans la branche qui vient de prouver un
        // snapshot — c'est-à-dire précisément le cas où il n'y a rien à
        // signaler. Toutes les issues qui *méritent* une alerte le
        // court-circuitaient : chaîne rouge (« pas encore l'heure »,
        // « chaîne réseau indisponible »), batterie, échec de kopia, verrou
        // pris. Un Mac dont le serveur est éteint pendant cinq semaines
        // repassait ici 840 fois sans jamais atteindre la seule ligne capable
        // de prévenir quelqu'un.
        //
        // Ce `defer` couvre **tous** les chemins de sortie de cette fonction,
        // y compris ceux ajoutés plus tard. Il relit le journal après coup :
        // `performBackup` a pu y écrire entre-temps, et l'alerte doit juger
        // sur l'état final, pas sur celui d'avant la tentative.
        //
        // `defer` ne peut pas contenir d'`await` : la notification est donc
        // envoyée juste avant chaque `return` par cette fonction-ci, appelée à
        // travers `finish(_:)`.
        func finish(_ code: Int32) async -> Int32 {
            await BackupAlerts.checkAndFireIfNeeded(
                now: Date(),
                configuration: configuration,
                journal: BackupJournal.readAll().attempts,
                // La couverture n'est pas recalculée ici : elle exige de relire
                // le dépôt (`listSnapshots`), ce qu'on ne fait pas sur un
                // chemin qui n'a rien tenté. `nil` veut dire « pas mesuré cette
                // fois » et n'est jamais lu comme « tout va bien » — voir la
                // garde dans `BackupAlerts.decide`.
                coverage: nil)
            return code
        }

        let chainVerdict = await probeChain(configuration: configuration)

        let journal = BackupJournal.readAll()
        if journal.unreadableLineCount > 0 {
            log.error("\(journal.unreadableLineCount) ligne(s) du journal illisibles, ignorées")
            print("attention : \(journal.unreadableLineCount) ligne(s) du journal de sauvegarde illisibles, ignorées.")
        }
        let attempts = journal.attempts
        // `BackupJournalModel` déduplique par identifiant et trie sur la
        // date d'issue — jamais l'ordre d'écriture sur disque, qui n'est pas
        // chronologique entre deux écrivains concurrents.
        //
        // Les trois questions posées ici vivent toutes dans le modèle, et
        // c'est délibéré : `consecutiveFailures` a existé un moment en double,
        // ici et là-bas, avec deux définitions différentes de ce qu'est un
        // échec. Un compteur qui décide de la cadence des tentatives n'a
        // qu'un seul droit de réponse.
        let lastAttempt = BackupJournalModel.lastAttempt(in: attempts)
        let lastSuccess = BackupJournalModel.lastSuccess(in: attempts)
        let consecutiveFailures = BackupJournalModel.consecutiveFailures(in: attempts)

        let (isOnBattery, batteryFraction) = batteryStatus()

        let decision = SchedulePolicy.decide(
            now: Date(),
            // La politique raisonne sur des instants ; le journal rend une
            // tentative. L'instant qui fait foi est celui où le dépôt a
            // confirmé le snapshot — `endTime` de la preuve — et non l'heure
            // à laquelle la ligne a été écrite.
            lastSuccess: lastSuccess?.proof?.endTime ?? lastSuccess?.finishedAt,
            lastAttempt: lastAttempt,
            configuration: configuration,
            chain: chainVerdict,
            isOnBattery: isOnBattery,
            batteryFraction: batteryFraction,
            // Vrai par construction : on tient le verrou de simultanéité, et
            // c'est la seule preuve dont `SchedulePolicy` a besoin — pas une
            // supposition, l'état qu'on vient soi-même d'établir.
            isRunning: false,
            consecutiveFailures: consecutiveFailures
        )

        // **`--force` court-circuite l'échéance, jamais la chaîne.**
        //
        // Ce qu'il contourne, c'est « ce n'est pas encore l'heure » et « le
        // dernier échec ne se répare pas tout seul » — deux décisions de
        // rythme, dont l'utilisateur a le droit de passer outre : c'est
        // exactement ce que fait le bouton « Sauvegarder maintenant » de la
        // fenêtre, et il n'y avait aucune raison que la ligne de commande en
        // soit privée.
        //
        // Ce qu'il ne contourne pas : le verrou de simultanéité, pris plus
        // haut, et l'état de la chaîne, vérifié plus bas dans `performBackup`.
        // Forcer une sauvegarde sur un maillon mort ne produirait pas une
        // sauvegarde, seulement un échec de plus dans le journal.
        if forced, case .wait = decision {
            log.notice("échéance forcée par --force")
            return await finish(await performBackup(trigger: .manual, configuration: configuration))
        }

        switch decision {
        case .backUpNow(let trigger):
            log.notice("déclenchement d'une sauvegarde (\(trigger.rawValue, privacy: .public))")
            return await finish(await performBackup(trigger: trigger, configuration: configuration))

        case .wait(let until, let because):
            log.notice("pas encore l'heure : \(because, privacy: .public)")
            print("pas encore l'heure (\(because)) ; prochaine échéance \(until).")
            return await finish(ExitCode.notDue.rawValue)

        case .waitForNetwork(let because):
            log.notice("chaîne réseau indisponible : \(because, privacy: .public)")
            print("chaîne réseau indisponible : \(because)")
            return await finish(ExitCode.notDue.rawValue)

        case .waitForPower(let forceAt, let because):
            log.notice("attente secteur : \(because, privacy: .public)")
            print("sur batterie (\(because)) ; forcé au plus tard \(forceAt) si le secteur ne revient pas avant.")
            return await finish(ExitCode.notDue.rawValue)

        case .disabled(let reason):
            log.notice("désactivé : \(reason, privacy: .public)")
            print("désactivé : \(reason)")
            return await finish(ExitCode.notDue.rawValue)

        case .alreadyRunning:
            // Ne devrait jamais arriver : on vient de prouver le contraire
            // en tenant le verrou. Si `SchedulePolicy` le disait quand même,
            // mieux vaut le traiter comme « rien à faire » que de forcer un
            // run sur la foi d'un désaccord qu'on ne comprend pas.
            log.error("SchedulePolicy signale un run en cours, en contradiction avec le verrou tenu")
            print("incohérence : SchedulePolicy signale un run en cours alors que le verrou vient d'être pris ; on n'agit pas.")
            return await finish(ExitCode.alreadyRunning.rawValue)
        }
    }

    // MARK: - La chaîne réseau

    /// Sonde les six maillons. Les cinq premiers sont ceux de `ChainProbes` ;
    /// le sixième (`repositoryOpens`) est reconstruit ici à partir de la
    /// seule signature confirmée de `KopiaDriver` au moment de l'écriture —
    /// voir le rapport de cet agent.
    private static func probeChain(configuration: BackupConfiguration) async -> ChainVerdict {
        async let tailscale = ChainProbes.tailscaleLocal(timeout: configuration.probeTimeout)
        async let peer = ChainProbes.minioNodeOnline(
            nodeName: configuration.tailscaleMinioNodeName, timeout: configuration.probeTimeout
        )
        async let port = ChainProbes.s3Reachable(endpoint: configuration.s3Endpoint, timeout: configuration.probeTimeout)
        async let health = ChainProbes.minioHealthy(
            endpoint: configuration.s3Endpoint, disableTLS: configuration.disableTLS, timeout: configuration.probeTimeout
        )
        async let bucket = ChainProbes.bucketReachable(
            endpoint: configuration.s3Endpoint, bucket: configuration.s3Bucket,
            disableTLS: configuration.disableTLS, timeout: configuration.probeTimeout
        )
        async let repository = repositoryOpensProbe(timeout: configuration.repositoryTimeout)

        let results = [await tailscale, await peer, await port, await health, await bucket, await repository]
        return ChainEvaluator.evaluate(results, now: Date(), freshness: chainFreshness)
    }

    /// Les sondes viennent d'être mesurées à l'instant : cette fraîcheur ne
    /// sert qu'à couvrir le temps que les six prennent elles-mêmes à
    /// s'exécuter (jusqu'à `probeTimeout` ou `repositoryTimeout` chacune),
    /// pas à tolérer un résultat vieux — `probeChain` ne réutilise jamais
    /// une mesure d'un appel précédent.
    private static let chainFreshness: TimeInterval = 120

    /// Le maillon 6. `KopiaDriver.repositoryStatus()` est la seule
    /// signature de `KopiaDriver` confirmée par un autre fichier de ce
    /// dépôt (`BackupProvisioning.swift`) au moment où celui-ci est écrit ;
    /// ce maillon s'y accroche plutôt que de supposer l'existence d'un
    /// `ChainProbes.repositoryOpens` non vérifié.
    private static func repositoryOpensProbe(timeout: TimeInterval) async -> LinkProbeResult {
        let start = Date()
        do {
            // `repositoryTimeout` est enfin lu : sans lui, un dépôt qui accepte
            // la connexion puis se tait suspendait ce processus pour toujours,
            // **le verrou de simultanéité tenu**. Le job launchd repassant
            // toutes les heures, le suivant sortait aussitôt en
            // `alreadyRunning` : plus jamais une sauvegarde, et pas une ligne
            // pour le dire.
            let status = try await BackupEngine.driver().repositoryStatus(timeout: timeout)
            return LinkProbeResult(
                link: .repositoryOpens,
                state: .up,
                diagnostic: "Le dépôt Kopia s'ouvre (seau « \(status.bucket) » sur \(status.endpoint)).",
                latency: Date().timeIntervalSince(start),
                measuredAt: Date()
            )
        } catch {
            let failure = classify(error)
            return LinkProbeResult(
                link: .repositoryOpens,
                state: .down,
                diagnostic: "Le dépôt Kopia ne s'ouvre pas : \(failure.summary)",
                rawDetail: failure.rawOutput,
                latency: Date().timeIntervalSince(start),
                measuredAt: Date()
            )
        }
    }

    // MARK: - La sauvegarde elle-même

    private static func performBackup(
        trigger: BackupTrigger,
        configuration: BackupConfiguration
    ) async -> Int32 {
        let attemptID = UUID()
        let startedAt = Date()
        // Déclarée **hors** du bloc `do` : sur une interruption — le cas le
        // plus intéressant de tous — c'est le `catch` qui écrit la tentative,
        // et c'est là que le nombre d'octets déjà montés a le plus de valeur.
        // C'est lui qui, comparé au run suivant, prouve qu'une reprise ne
        // recommence pas le travail.
        let uploaded = UploadedBytesBox()

        do {
            // 1. Lancer. Ce que `KopiaDriver` rend ici n'est que la parole du
            //    processus qui vient de terminer (`origin == .reportedByCreate`)
            //    — voir `ProofOrigin` dans `BackupContract`. Ça ne suffit
            //    jamais à afficher « sauvegardé ».
            let driver = try BackupEngine.driver()
            // Hors interface, personne ne regarde la progression défiler —
            // mais on la consomme pour deux raisons. Elle alimente le
            // détecteur de blocage du pilote, qui sans consommateur ne verrait
            // jamais un run figé. Et elle porte le seul chiffre qui rende une
            // **reprise** visible dans l'historique : les octets réellement
            // montés sur le réseau. Sans lui, un run repris après coupure et
            // un run complet se ressemblent trait pour trait dans le journal,
            // et la promesse « ça reprend sans tout refaire » devient
            // invérifiable.
            // Les règles d'exclusion, d'abord : `snapshot create` n'a aucun
            // drapeau pour ça, tout passe par la politique du dépôt. Sans cet
            // appel, `configuration.ignoreRules` restait un réglage mort et un
            // dossier explicitement exclu partait quand même — voir
            // `KopiaDriver.applyIgnoreRules`. Un échec ici arrête le run
            // plutôt que de sauvegarder ce qu'on avait demandé d'exclure.
            try await driver.applyIgnoreRules(
                configuration.ignoreRules,
                to: configuration.sourcePaths,
                timeout: configuration.repositoryTimeout)

// **La notification part ici, pas au début du run.** Entre
// l'appui sur le bouton et cette ligne il y a la chaîne réseau et
// l'écriture de la politique, qui peuvent l'une comme l'autre
// refuser. Annoncer « sauvegarde démarrée » avant elles, c'est
// promettre un travail qui n'aura peut-être pas lieu — et
// rejouer, en petit, le défaut que tout cet écran combat.
await BackupAlerts.notifyBackupStarted(trigger: trigger)

            let reported = try await driver.createSnapshot(
                paths: configuration.sourcePaths,
                onProgress: { progress in uploaded.record(progress) }
            )

            // 2. Confirmer. Relire le dépôt est l'étape qu'un pilote naïf
            //    saute — c'est exactement elle qui a manqué le 02/09/2026 :
            //    143,1 Go envoyés, zéro manifeste retrouvable.
            // Quatre fois le budget d'une ouverture : `snapshot list --all`
            // relit tous les manifestes, pas seulement l'en-tête du dépôt.
            let confirmed = try await driver.listSnapshots(timeout: configuration.repositoryTimeout * 4)

            guard let matched = confirmed.first(where: { $0.id == reported.id }) else {
                // Le manifeste existe selon `create` ; `list` ne le
                // retrouve pas dans le dépôt. C'est la panne fondatrice au
                // mot près : on ne l'appelle jamais un succès.
                let failure = BackupFailure(
                    kind: .unparseable,
                    summary: "le manifeste rendu par « kopia snapshot create » n'a pas été retrouvé en relisant le dépôt",
                    suggestedAction: "relancer une sauvegarde ; si ça persiste, vérifier l'état du dépôt avec « kopia repository status »",
                    rawOutput: "id attendu \(reported.id), absent de « kopia snapshot list --all --json »"
                )
                recordAttempt(id: attemptID, startedAt: startedAt, trigger: trigger, proof: nil, failure: failure, uploadedBytes: uploaded.value, estimatedBytes: uploaded.estimated)
                log.error("snapshot non confirmé dans le dépôt (id \(reported.id, privacy: .public))")
                return ExitCode.backupFailed.rawValue
            }

            guard matched.isTrustworthy else {
                // Confirmé, mais incomplet : des fichiers manqués, comptés
                // ou ignorés selon la politique du dépôt — voir
                // `SnapshotProof.ignoredErrorCount`. Un snapshot troué n'est
                // pas un snapshot réussi.
                let failure = BackupFailure(
                    kind: .partialSnapshot,
                    summary: "le snapshot est confirmé dans le dépôt mais incomplet : \(matched.missingFileCount) fichier(s) manquant(s)",
                    rawOutput: "errorCount=\(matched.errorCount) ignoredErrorCount=\(matched.ignoredErrorCount)"
                )
                recordAttempt(id: attemptID, startedAt: startedAt, trigger: trigger, proof: matched, failure: failure, uploadedBytes: uploaded.value, estimatedBytes: uploaded.estimated)
                log.error("snapshot confirmé mais incomplet : \(matched.missingFileCount) fichier(s) manquant(s)")
                return ExitCode.backupFailed.rawValue
            }

            let recorded = recordAttempt(id: attemptID, startedAt: startedAt, trigger: trigger, proof: matched, failure: nil, uploadedBytes: uploaded.value, estimatedBytes: uploaded.estimated)
            // **Un succès non consigné n'est pas un succès à rendre à
            // `launchd`.** Le journal est la seule trace qu'un run headless
            // laisse : personne ne regarde cet écran. Sortir en 0 après une
            // écriture ratée annoncerait au système que tout va bien, pendant
            // que `BackupJournal.readAll()` continue de répondre « aucune
            // sauvegarde réussie » — donc que `SchedulePolicy` relance sans
            // fin, et que l'alerte finira par prévenir d'un retard qui
            // n'existe pas. Le code 5 dit la seule chose vraie : le snapshot
            // est bien dans le dépôt, mais bran n'a pas pu l'écrire, et c'est
            // le disque local qu'il faut regarder.
            guard recorded else {
                log.fault("snapshot confirmé (\(matched.id, privacy: .public)) mais journal non écrit")
                print("sauvegarde confirmée dans le dépôt (\(matched.id)), mais le journal n'a pas pu être "
                    + "écrit : bran ne pourra pas le prouver au prochain démarrage.")
                return ExitCode.internalError.rawValue
            }

            // **C'est ici que l'alerte compte le plus.** Ce chemin tourne sous
            // launchd, sans interface et sans personne devant l'écran : si la
            // couverture reste incomplète run après run, la notification est le
            // seul canal qui reste. On calcule la couverture sur ce que le dépôt
            // vient de rendre, plutôt que de passer `nil` et de rendre ce
            // chemin-là aveugle au mensonge que tout le module combat.
            await BackupAlerts.checkAndFireIfNeeded(
                now: Date(),
                configuration: configuration,
                journal: BackupJournal.readAll().attempts,
                coverage: SourceCoverageEvaluator.evaluate(
                    sourcePaths: configuration.sourcePaths,
                    proofs: confirmed,
                    expectedHost: matched.sourceHost,
                    expectedUser: matched.sourceUser,
                    now: Date(),
                    staleAfter: configuration.stalenessThreshold))
            log.notice("sauvegarde réussie et confirmée (snapshot \(matched.id, privacy: .public))")
            print("sauvegarde réussie, confirmée dans le dépôt : \(matched.id)")
            return ExitCode.success.rawValue

        } catch {
            // `BackupEngine.driver()` et les méthodes de `KopiaDriver` ne
            // lèvent jamais directement un `BackupFailure` : trois origines
            // distinctes peuvent atteindre ce point — `KopiaBinaryFailure`
            // (binaire introuvable, avant même qu'un pilote existe),
            // `BackupWiringFailure` (le trousseau, au moment de fournir le
            // mot de passe) et `KopiaDriverFailure` (le pilote lui-même, qui
            // sait déjà se convertir via `asBackupFailure`). `classify(_:)`
            // les ramène tous à la même forme ; un type qu'aucun des trois
            // ne reconnaît n'est jamais interprété au bénéfice du doute.
            let failure = classify(error)
            recordAttempt(id: attemptID, startedAt: startedAt, trigger: trigger, proof: nil, failure: failure, uploadedBytes: uploaded.value, estimatedBytes: uploaded.estimated)
            log.error("sauvegarde en échec (\(failure.kind.rawValue, privacy: .public))")
            print("sauvegarde en échec : \(failure.summary)")
            return ExitCode.backupFailed.rawValue
        }
    }

    /// Ramène n'importe quelle erreur remontée par le pilote Kopia ou son
    /// raccordement (`BackupWiring`) à la forme unique du contrat. Voir le
    /// commentaire du seul appelant pour les trois origines possibles.
    private static func classify(_ error: Error) -> BackupFailure {
        if let driverFailure = error as? KopiaDriverFailure {
            return driverFailure.asBackupFailure
        }
        if let binaryFailure = error as? KopiaBinaryFailure {
            return BackupFailure(
                kind: .notConfigured,
                summary: binaryFailure.description,
                suggestedAction: "Réinstaller bran, ou renseigner le chemin du binaire kopia dans les réglages avancés.",
                rawOutput: binaryFailure.description
            )
        }
        if let wiringFailure = error as? BackupWiringFailure {
            return BackupFailure(
                kind: .authentication,
                summary: wiringFailure.description,
                rawOutput: wiringFailure.description
            )
        }
        // Un cas non prévu par les trois origines connues. On ne l'interprète
        // jamais au bénéfice du doute — jamais un succès implicite.
        return BackupFailure(
            kind: .unparseable,
            summary: "erreur inattendue pendant la sauvegarde : \(error)",
            rawOutput: String(describing: error)
        )
    }

    /// Écrit la tentative au journal — dans tous les cas, succès comme
    /// échec, dès qu'une sauvegarde a réellement été tentée.
    ///
    /// Une écriture qui échoue n'est **jamais** avalée en silence : elle est
    /// signalée haut et fort sur l'erreur standard, même si le run continue
    /// et rend son code de sortie normal. Confondre « le journal n'a pas pu
    /// être écrit » avec « rien à signaler » referait, à l'échelle du
    /// journal cette fois, exactement le mensonge que cette fonctionnalité
    /// existe pour fermer.
    /// - Returns: vrai quand la ligne a bien été écrite. **L'appelant du
    ///   chemin heureux doit le lire** — voir la garde après le succès
    ///   confirmé.
    @discardableResult
    private static func recordAttempt(
        id: UUID,
        startedAt: Date,
        trigger: BackupTrigger,
        proof: SnapshotProof?,
        failure: BackupFailure?,
        uploadedBytes: Int64? = nil,
        estimatedBytes: Int64? = nil
    ) -> Bool {
        let attempt = BackupAttempt(
            id: id,
            startedAt: startedAt,
            finishedAt: Date(),
            trigger: trigger,
            proof: proof,
            failure: failure,
            // Renseigné depuis la progression, y compris ici où personne ne la
            // regarde défiler : c'est le seul chiffre qui distingue une
            // reprise bon marché d'un transfert complet dans l'historique.
            uploadedBytes: uploadedBytes,
            estimatedBytes: estimatedBytes
        )
        do {
            try BackupJournal.append(attempt)
            return true
        } catch {
            log.fault("écriture au journal impossible : \(String(describing: error), privacy: .public)")
            FileHandle.standardError.write(Data("échec d'écriture au journal de sauvegarde : \(error)\n".utf8))
            return false
        }
    }

    // MARK: - La batterie

    /// Vrai si le Mac tourne sur sa batterie, et le niveau quand on le
    /// connaît. `nil`/`false` par défaut quand la lecture échoue ou que la
    /// machine n'a pas de batterie interne (Mac de bureau) : un défaut « pas
    /// sur batterie » n'expose qu'à sauvegarder un peu plus tôt que prévu
    /// sur un portable dont on n'a pas su lire l'état, jamais à en retarder
    /// une indéfiniment — c'est le sens dans lequel une politique
    /// d'alimentation a le droit de se tromper ici.
    private static func batteryStatus() -> (isOnBattery: Bool, fraction: Double?) {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else {
            return (false, nil)
        }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any]
            else { continue }
            guard let type = description[kIOPSTypeKey as String] as? String, type == kIOPSInternalBatteryType
            else { continue }

            let state = description[kIOPSPowerSourceStateKey as String] as? String
            let isOnBattery = state == kIOPSBatteryPowerValue

            var fraction: Double?
            if let current = description[kIOPSCurrentCapacityKey as String] as? Int,
               let maximum = description[kIOPSMaxCapacityKey as String] as? Int,
               maximum > 0 {
                fraction = Double(current) / Double(maximum)
            }
            return (isOnBattery, fraction)
        }

        // Aucune batterie interne trouvée dans la liste : un Mac de bureau,
        // toujours sur secteur.
        return (false, nil)
    }

    // MARK: - Le verrou de simultanéité

    /// **La pièce critique de ce fichier.** L'interface (un run manuel) et
    /// le job `launchd` peuvent se déclencher au même instant ; deux
    /// `kopia` sur le même dépôt, c'est un conflit de verrou côté Kopia et
    /// potentiellement un dépôt à réparer à la main.
    ///
    /// **Jamais un fichier-témoin avec un PID.** Un processus tué —
    /// `kill -9`, une extinction brutale, un crash — laisserait le témoin en
    /// place pour toujours : un verrou qui ne se libère jamais devient une
    /// panne à lui seul, exactement la même famille de mensonge que celle
    /// que ce projet combat, version « verrou » plutôt que version
    /// « snapshot ». `flock` n'a pas ce défaut : le noyau libère un verrou
    /// posé par un descripteur dès que ce descripteur se ferme, y compris
    /// par la mort du processus qui le tenait, quelle qu'en soit la cause.
    /// `release()` ci-dessous n'est donc qu'une politesse pour le chemin
    /// heureux — sa non-exécution ne bloque jamais un run futur.
    fileprivate struct SingleFlightLock {
        // `fileprivate` et non `private` : l'initialiseur implicite hérite de
        // la visibilité du champ, et c'est la fonction de prise du verrou —
        // hors du type — qui le construit.
        fileprivate let fileDescriptor: Int32

        func release() {
            flock(fileDescriptor, LOCK_UN)
            close(fileDescriptor)
        }
    }

    private enum LockOutcome {
        case acquired(SingleFlightLock)
        case heldByAnotherProcess
        case failed(Error)
    }

    private enum LockError: Error, CustomStringConvertible {
        case cannotCreateDirectory(String)
        case cannotOpen(errno: Int32)
        case cannotLock(errno: Int32)

        var description: String {
            switch self {
            case let .cannotCreateDirectory(reason): "dossier du verrou introuvable : \(reason)"
            case let .cannotOpen(code): "ouverture du fichier de verrou impossible (errno \(code))"
            case let .cannotLock(code): "flock a échoué pour une raison autre que la contention (errno \(code))"
            }
        }
    }

    /// Le verrou vit à côté du journal — même dossier, fichier dédié — mais
    /// jamais le journal lui-même : le prendre ne doit jamais impliquer
    /// d'ouvrir le journal en écriture.
    private static func acquireLock() -> LockOutcome {
        do {
            try FileManager.default.createDirectory(at: BackupJournal.directory, withIntermediateDirectories: true)
        } catch {
            return .failed(LockError.cannotCreateDirectory(String(describing: error)))
        }

        let lockURL = BackupJournal.directory.appending(path: "run.lock", directoryHint: .notDirectory)
        let fd = open(lockURL.path(percentEncoded: false), O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else { return .failed(LockError.cannotOpen(errno: errno)) }

        // Non bloquant (`LOCK_NB`) : un job `launchd` qui chevauche le
        // bouton « sauvegarder maintenant » de l'interface doit repartir
        // tout de suite, pas attendre une hypothétique libération pendant
        // potentiellement 30 heures.
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            return .acquired(SingleFlightLock(fileDescriptor: fd))
        }

        let failureCode = errno
        close(fd)
        if failureCode == EWOULDBLOCK {
            return .heldByAnotherProcess
        }
        return .failed(LockError.cannotLock(errno: failureCode))
    }
}
