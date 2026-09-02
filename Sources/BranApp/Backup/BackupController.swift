import AppKit
import BranBackup
import Foundation
import Observation
import os

/// Ce que `launchd` sait vraiment du job de sauvegarde — voir
/// `BackupController.launchAgentStatus` pour la panne que ce type ferme.
enum LaunchAgentStatus: Equatable {
    /// Sauvegarde désactivée : pas de job à surveiller.
    case notApplicable
    /// Installé, et `launchctl print` le confirme chargé.
    case running
    /// `BackupAgentInstaller.install()` ou `.uninstall()` a levé une erreur.
    case installFailed(String)
    /// Le plist s'est écrit sans erreur, mais `launchctl print` ne voit
    /// aucun job chargé sous ce label. C'est le cas que `log.error` seul
    /// laissait invisible : rien n'a levé, et pourtant rien ne tourne.
    case notLoaded(String)
}

/// Ce que l'interface regarde, et la seule chose qu'elle regarde.
///
/// ## Ce qu'il fait, et surtout ce qu'il ne fait pas
///
/// Il assemble : les sondes de `ChainProbes`, le pilote `KopiaDriver`, le
/// journal sur disque, et les quatre pièces pures de `BranBackup` — la machine
/// à états, l'évaluateur de chaîne, la politique de planification, le modèle du
/// journal. **Il ne décide rien lui-même.**
///
/// Cette distinction n'est pas de la coquetterie d'architecture. La question
/// « cette sauvegarde a-t-elle réussi » a exactement une réponse dans ce
/// programme : `BackupAttempt.succeeded`, c'est-à-dire une preuve relue dans le
/// dépôt et sans fichier manquant. Un contrôleur qui répondrait *aussi* à cette
/// question — même correctement le premier jour — en ferait deux, et les deux
/// divergeraient. C'est exactement comme ça qu'un tableau de bord finit par
/// afficher du vert sur un dépôt vide.
///
/// ## Le rythme n'est pas ici non plus
///
/// **Ce contrôleur n'est pas le planificateur, et il ne doit jamais le
/// devenir.** Il ne vit que pendant que l'application tourne ; le vrai rythme
/// est tenu par le LaunchAgent de `BackupAgentInstaller`, qui appelle le même
/// binaire en `--backup-run` que la fenêtre soit ouverte ou non. Ce Mac a passé
/// des semaines avec une planification à 48 h dans sa configuration et zéro
/// sauvegarde exécutée, parce que le seul processus capable de l'exécuter ne
/// tournait pas. Un minuteur d'interface aurait reproduit la panne à
/// l'identique.
///
/// Ce que fait le contrôleur, c'est **proposer** : quand la fenêtre est
/// ouverte, il regarde s'il y a du retard et peut lancer un rattrapage. Le job
/// launchd fait la même chose, en permanence, et le verrou de simultanéité fait
/// qu'ils ne se marchent jamais dessus.
@MainActor
@Observable
final class BackupController {

    // MARK: - Ce que l'interface lit

    private(set) var phase: BackupPhase

    /// Modifiable : les réglages l'éditent directement par `@Bindable`.
    ///
    /// **Accesseurs écrits à la main, et il n'y avait pas le choix.** Un
    /// `didSet` sur une propriété d'un type `@Observable` ne compile pas : le
    /// macro réécrit le stockage, et le corps de l'observateur se retrouve hors
    /// de portée de ce qui l'entoure. Le motif ci-dessous — champ ignoré par
    /// l'observation, plus `access` et `withMutation` posés à la main — est
    /// celui que la documentation d'`Observation` prévoit pour ce cas.
    ///
    /// Ce qu'on y gagne vaut le détour : **toute** écriture est persistée, d'où
    /// qu'elle vienne. Un réglage modifié puis perdu par une fermeture de
    /// fenêtre serait, dans ce module précis, une sauvegarde qui pointe encore
    /// sur l'ancien seau sans que personne ne l'ait voulu.
    @ObservationIgnored private var storedConfiguration: BackupConfiguration

    var configuration: BackupConfiguration {
        get {
            access(keyPath: \.configuration)
            return storedConfiguration
        }
        set {
            guard newValue != storedConfiguration else { return }
            withMutation(keyPath: \.configuration) {
                storedConfiguration = newValue
            }
            persistConfiguration()
        }
    }

    /// Écrit la configuration sur disque, tout de suite.
    ///
    /// Un échec ne se tait pas et ne remonte pas non plus en exception : un
    /// champ de texte ne peut rien faire d'une erreur levée pendant la frappe.
    /// Il est journalisé, et le prochain démarrage butera dessus franchement
    /// plutôt que de repartir sur des défauts silencieux.
    private func persistConfiguration() {
        do {
            try BackupConfigurationStore.save(storedConfiguration)
        } catch {
            log.error("configuration de sauvegarde non écrite : \(String(describing: error), privacy: .public)")
        }
        // L'activation vient de changer, ou le chemin de l'exécutable a pu
        // bouger : le job doit suivre, sans quoi le réglage dirait une chose et
        // le système en ferait une autre.
        syncLaunchAgent()
    }

    /// `nil` tant qu'aucune sonde n'a tourné. **Distinct d'une chaîne
    /// rouge** : on ne sait pas encore, ce qui n'autorise ni le vert ni
    /// l'alarme.
    private(set) var chainVerdict: ChainVerdict?

    /// Les tentatives, telles que le journal les rend. L'interface ne les lit
    /// jamais directement : elle passe par `BackupJournalModel`, qui déduplique
    /// et trie.
    private(set) var history: [BackupAttempt] = []

    private(set) var repositoryStatus: RepositoryStatus?

    /// La taille occupée dans le dépôt, quand on a pu la mesurer.
    ///
    /// Reste `nil` tant qu'on ne l'a pas : l'interface masque alors la ligne.
    /// Afficher 0 pour « pas encore mesuré » ferait croire à un dépôt vide —
    /// et sur cette machine, un dépôt qui paraît vide a déjà voulu dire
    /// quelque chose de bien précis.
    private(set) var repositorySizeBytes: Int64?

    private(set) var scheduleDecision: ScheduleDecision = .disabled("Sauvegarde non configurée.")

    /// **La réponse à « mes fichiers sont-ils à l'abri », et non à « un
    /// snapshot a-t-il réussi ».**
    ///
    /// Les deux ont divergé en vrai, le 02/09/2026 : un snapshot de `~/Music`
    /// de 51 Mo faisait afficher « Dernière sauvegarde réussie il y a 21 min »
    /// alors que la source configurée était le dossier personnel entier, jamais
    /// envoyé une seule fois. Le propriétaire l'a relevé lui-même — et il avait
    /// raison, c'était le dernier faux vert du dispositif, un étage au-dessus
    /// de ceux que le contrat avait fermés.
    ///
    /// L'interface doit lire **ceci** pour décider d'écrire « à l'abri », et
    /// jamais `lastSuccess` seul.
    private(set) var coverage: SourceCoverageReport?

    /// Où en est le tout premier envoi, chemin par chemin. `nil` quand tout est
    /// déjà couvert.
    private(set) var firstUploads: [FirstUploadTracking] = []

    /// Des lignes de journal illisibles, comptées à la dernière lecture. Zéro
    /// est le cas normal ; autre chose mérite d'être dit, pas caché.
    private(set) var unreadableJournalLines = 0

    /// Les secrets présents au trousseau, relus rarement — voir
    /// ``hasStoredSecret(_:)``.
    private(set) var storedSecrets: Set<BackupSecrets.Secret> = []

    /// Ce que `launchd` sait vraiment du job, pas ce que l'écriture du plist
    /// a supposé.
    ///
    /// **Pourquoi cet état existe.** `BackupAgentInstaller.install()` peut
    /// rendre sans lever : le plist s'écrit, `launchctl bootstrap` sort avec
    /// le code 0, et pourtant rien n'est chargé — chemin d'exécutable
    /// invalide, argument malformé, droits refusés sur `~/Library/LaunchAgents`
    /// après coup. Un contrôleur qui se contente de ne pas avoir vu d'erreur
    /// affiche « activée » pendant que rien ne tournera jamais, en silence,
    /// jour après jour. C'est exactement la panne fondatrice de ce projet,
    /// une case plus loin : plus « OK sans données », mais « activée sans
    /// job ». `verifyLaunchAgent()` relit l'état réel via `launchctl print`
    /// et c'est cette relecture, jamais l'absence d'erreur, qui remplit ce
    /// champ.
    private(set) var launchAgentStatus: LaunchAgentStatus = .notApplicable

    // MARK: - Ce qu'il garde pour lui

    private var machine = BackupMachine()
    private var runTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var sleepObservers: [NSObjectProtocol] = []

    /// Le pilote du run en cours, le temps qu'il tourne — et seulement ce
    /// temps-là.
    ///
    /// `BackupEngine.driver()` fabrique une instance neuve à chaque appel :
    /// sans cette référence, rien dans le contrôleur ne pourrait désigner le
    /// processus `kopia` que `watchChainDuringRun()` doit pouvoir tuer.
    /// Effacée dès que le run quitte le bloc `do` de `performRun` (succès,
    /// échec ou coupure), pour qu'une surveillance en retard ne tienne
    /// jamais la cible d'un run déjà terminé.
    private var activeDriver: KopiaDriver?

    /// Posé juste avant `activeDriver?.cancelCurrentRun()`, lu par
    /// `performRun` dès que `createSnapshot` rend la main.
    ///
    /// **C'est lui qui distingue, dans le journal, une coupure décidée par
    /// bran d'un vrai plantage de Kopia.** Sans ce relais, l'erreur qui
    /// remonte après un `SIGTERM` volontaire est indiscernable de celle
    /// qu'aurait rendue un Kopia qui s'est arrêté tout seul — un
    /// classificateur ne sait pas lire une intention, seulement du texte.
    private var networkCutReason: String?

    /// Le dernier instant où la progression a été publiée. Voir
    /// ``progressPublishInterval``.
    private var lastProgressPublish = Date.distantPast

    private let log = Logger(subsystem: "com.opahventures.bran", category: "backup")

    // MARK: - Les cadences, et pourquoi celles-là

    /// Les cinq premiers maillons, toutes les 45 s.
    ///
    /// Ils coûtent peu — 0,38 s pour le TCP, autour de 0,1 s pour les requêtes
    /// HTTP, mesuré le 02/09/2026. Assez fréquent pour qu'une coupure se voie
    /// avant qu'on ne s'interroge, assez espacé pour ne pas marteler un serveur
    /// qui redémarre.
    private static let fastProbeInterval: TimeInterval = 45

    /// Le sixième maillon — l'ouverture du dépôt — toutes les dix minutes.
    ///
    /// **Il est d'une autre nature que les cinq autres.** Il ouvre vraiment le
    /// dépôt : 1,2 s sur cette machine avec un cache chaud, des dizaines de
    /// secondes à froid depuis l'Indonésie. Le sonder toutes les 45 s ferait
    /// tourner un processus `kopia` en permanence pour une information qui ne
    /// change presque jamais. Il est de toute façon sondé **systématiquement
    /// avant chaque sauvegarde**, qui est le seul moment où sa réponse engage
    /// quelque chose.
    private static let repositoryProbeInterval: TimeInterval = 600

    /// Au-delà, une mesure n'est plus une mesure : `ChainEvaluator` la
    /// rétrograde en `unknown`. Un peu plus du double de la cadence rapide,
    /// pour qu'un cycle manqué ne périme pas tout l'écran.
    private static let chainFreshness: TimeInterval = 120

    /// Quatre publications par seconde pendant un run, pas davantage.
    ///
    /// Kopia émet un état toutes les quelques centaines de millisecondes. Tout
    /// republier redessinerait la fenêtre en continu **pendant des heures** —
    /// pour une barre dont l'œil ne distingue pas deux positions séparées d'un
    /// quart de seconde. Le coût serait réel, le gain nul.
    private static let progressPublishInterval: TimeInterval = 0.25

    /// Pendant qu'un run tourne, les cinq maillons rapides toutes les 30 s —
    /// plus serré que la cadence d'inactivité (45 s).
    ///
    /// **Pourquoi plus serré, et pas le même chiffre.** Une sauvegarde
    /// initiale dure de l'ordre de dix à quinze heures sur ce Mac : ce
    /// n'est plus une fenêtre fermée qu'on rouvrira dans une minute, c'est
    /// un transfert qui ne peut pas s'apercevoir tout seul qu'il parle dans
    /// le vide — Kopia s'entête et ne rend une erreur de transport qu'au
    /// bout d'un délai indéterminé. Le coût d'une sonde reste le même
    /// (~0,4 s pour les cinq), donc 30 s au lieu de 45 s ne coûte
    /// pratiquement rien de plus (~1,3 % du temps sondé) et raccourcit
    /// d'autant le délai avant qu'une vraie coupure ne soit détectée.
    private static let duringRunProbeInterval: TimeInterval = 30

    /// Il faut quatre sondes `down` d'affilée — environ deux minutes à
    /// 30 s — avant de couper un run en cours.
    ///
    /// **Le nombre qui protège contre le rouge nerveux.** Le propriétaire
    /// travaille depuis l'Indonésie, où la latence varie du simple au
    /// double d'une heure à l'autre (mesuré, voir la note sur
    /// `LinkState.connecting`) ; un hoquet de trois secondes n'est pas une
    /// coupure, et couper dessus transformerait un aléa sans conséquence en
    /// interruption d'un transfert de dix heures — le remède serait pire
    /// que le mal. Quatre mesures **consécutives**, chacune espacée de 30 s,
    /// exigent une panne qui tient sur toute une fenêtre de deux minutes :
    /// large marge sur un hoquet, mais encore court à l'échelle d'un run
    /// qui se compte en heures.
    private static let networkCutStreak = 4

    /// À quelle fréquence on relit l'état réel du job `launchd` auprès du
    /// système, plutôt que de faire confiance à l'absence d'erreur au
    /// moment de l'écriture du plist.
    ///
    /// Même ordre de grandeur que le maillon 6 : ce que `launchctl print`
    /// répond ne change presque jamais entre deux sondes, et une relecture
    /// est un `Process` de plus, synchrone, sur le fil principal (même motif
    /// que ``powerState()``) — inutile de la répéter à la cadence des
    /// sondes réseau.
    private static let launchAgentVerifyInterval: TimeInterval = 600

    // MARK: - Naissance

    /// L'initialiseur complet, celui dont les prévisualisations se servent.
    init(
        phase: BackupPhase = .idle,
        configuration: BackupConfiguration,
        chainVerdict: ChainVerdict? = nil,
        history: [BackupAttempt] = [],
        repositoryStatus: RepositoryStatus? = nil,
        repositorySizeBytes: Int64? = nil,
        scheduleDecision: ScheduleDecision = .disabled("Sauvegarde non configurée."),
        // **Injectables uniquement pour les prévisualisations.** En
        // fonctionnement, ces deux valeurs sont calculées par
        // `refreshCoverage()` à partir du journal ; les passer ici permet à un
        // `#Preview` de montrer un état de couverture sans journal sur disque,
        // sans que la vue ait à recalculer quoi que ce soit de son côté — ce
        // qui aurait été un deuxième avis sur la question la plus sensible de
        // tout l'écran.
        coverage: SourceCoverageReport? = nil,
        firstUploads: [FirstUploadTracking] = []
    ) {
        self.phase = phase
        self.storedConfiguration = configuration
        self.chainVerdict = chainVerdict
        self.history = history
        self.repositoryStatus = repositoryStatus
        self.repositorySizeBytes = repositorySizeBytes
        self.scheduleDecision = scheduleDecision
        self.coverage = coverage
        self.firstUploads = firstUploads
        self.machine = BackupMachine(phase: phase)
    }

    /// L'initialiseur de l'application : lit la configuration sur disque.
    ///
    /// **Une configuration illisible n'est pas une configuration absente.** La
    /// première signifie qu'un fichier existe et qu'on n'a pas su le lire —
    /// repartir des valeurs par défaut effacerait silencieusement un seau déjà
    /// saisi. On garde donc les défauts *désactivés* et on dit pourquoi.
    convenience init() {
        do {
            self.init(configuration: try BackupConfigurationStore.load())
        } catch {
            var fallback = BackupConfigurationStore.defaultConfiguration()
            fallback.isEnabled = false
            self.init(
                configuration: fallback,
                scheduleDecision: .disabled(
                    "La configuration de sauvegarde est illisible : \(error). "
                    + "Rien n'est lancé tant qu'elle n'est pas réparée ou ressaisie."
                )
            )
        }
    }

    /// Démarre la surveillance. Appelé une fois, par `AppModel`.
    func start() {
        reloadJournal()
        refreshStoredSecrets()
        syncLaunchAgent()
        observeSleepAndWake()
        pollTask = Task { [weak self] in await self?.pollLoop() }
    }

    /// Met le LaunchAgent en accord avec la configuration : installé quand la
    /// sauvegarde est active, retiré sinon.
    ///
    /// **Appelé au démarrage et à chaque écriture de la configuration, et ce
    /// n'est pas une précaution excessive.** Le plist porte le chemin réel de
    /// l'exécutable : une application déplacée de `~/Applications` vers
    /// `/Applications`, ou remplacée par une mise à jour Sparkle, laisserait
    /// derrière elle un job qui pointe dans le vide. `launchd` ne s'en
    /// plaindrait à personne — il échouerait simplement à lancer, en silence,
    /// tous les deux jours.
    ///
    /// C'est la même famille de panne que celle qui a coûté à ce Mac des
    /// semaines sans sauvegarde : une planification qui existe sur le papier
    /// et que rien n'exécute. Réécrire le plist coûte quelques millisecondes ;
    /// ne pas le faire coûte de ne jamais s'en apercevoir.
    private func syncLaunchAgent() {
        guard configuration.isEnabled else {
            do {
                try BackupAgentInstaller.uninstall()
            } catch {
                log.error("LaunchAgent de sauvegarde (retrait) : \(String(describing: error), privacy: .public)")
                // Un retrait raté laisse un job actif alors que l'écran va
                // afficher « désactivée » — l'inverse exact de la panne
                // qu'on chasse, mais la même famille : dire une chose,
                // faire l'autre. On le montre, on ne le tait pas.
                launchAgentStatus = .installFailed(String(describing: error))
                return
            }
            launchAgentStatus = .notApplicable
            return
        }
        do {
            try BackupAgentInstaller.install()
        } catch {
            // **Le cœur du correctif.** `log.error` seul est invisible hors
            // de Console.app : l'écran continuait à dire « activée » alors
            // que rien n'était installé. `launchAgentStatus` est ce que
            // l'interface peut afficher à la place — un job absent doit se
            // voir aussi franchement qu'un maillon réseau rouge.
            log.error("LaunchAgent de sauvegarde (installation) : \(String(describing: error), privacy: .public)")
            launchAgentStatus = .installFailed(String(describing: error))
            return
        }
        // L'écriture du plist n'est pas une preuve que le job tourne — voir
        // la documentation de `launchAgentStatus`. On relit tout de suite,
        // pas seulement au prochain passage de `pollLoop`.
        verifyLaunchAgent()
    }

    /// Relit l'état réel du job auprès de `launchd`, jamais une supposition
    /// que l'installation a suffi.
    ///
    /// **Détecte aussi le cas que `syncLaunchAgent()` seul ne peut pas
    /// voir : un job chargé au démarrage puis mort en cours de route.**
    /// `launchctl bootstrap` réussissant à l'installation ne garantit rien
    /// sur l'instant présent — c'est pour ça que `pollLoop` rappelle cette
    /// fonction de temps en temps plutôt que de ne la lancer qu'une fois.
    private func verifyLaunchAgent() {
        guard configuration.isEnabled else {
            launchAgentStatus = .notApplicable
            return
        }
        let result = BackupAgentInstaller.verifyInstalled()
        launchAgentStatus = result.isLoaded ? .running : .notLoaded(result.rawOutput)
    }

    /// Retire les observateurs de veille.
    ///
    /// **Pas dans `deinit`.** Un `deinit` n'est pas isolé au fil principal et
    /// ne peut donc pas lire un état qui l'est ; le contourner par un
    /// `assumeIsolated` serait une affirmation fausse, puisqu'un objet peut
    /// être libéré depuis n'importe quel fil. Ce contrôleur vit de toute façon
    /// aussi longtemps que l'application — il n'y a pas de cycle de vie à
    /// gérer, seulement un arrêt propre à offrir si un jour il en faut un.
    func stop() {
        pollTask?.cancel()
        runTask?.cancel()
        for observer in sleepObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        sleepObservers.removeAll()
    }

    /// Ce que porte la pastille de la colonne, ou `nil` quand il n'y a rien à
    /// signaler — voir `SectionSidebar.badge`.
    ///
    /// **Deux cas, et ils ne se confondent pas.** « Aucune sauvegarde prouvée,
    /// jamais » n'est pas un retard de N jours : c'est un état sans repère, et
    /// le compter en jours donnerait un nombre absurde ou, pire, un zéro
    /// rassurant. Il porte donc un « ! », qui ne se lit pas comme une quantité.
    var badgeText: String? {
        guard configuration.isEnabled else { return nil }
        guard let last = BackupJournalModel.lastSuccess(in: history),
              let when = last.proof?.endTime ?? last.finishedAt
        else {
            return "!"
        }
        let overdue = Date().timeIntervalSince(when) - configuration.intervalHours * 3600
        guard overdue > 0 else { return nil }
        return "\(max(1, Int(overdue / 86_400))) j"
    }

    // MARK: - La boucle de surveillance

    private func pollLoop() async {
        var lastRepositoryProbe = Date.distantPast
        var lastLaunchAgentVerify = Date.distantPast

        while !Task.isCancelled {
            if case .running = phase {
                // Pendant qu'un run transfère des données, c'est
                // `watchChainDuringRun()` qui sonde les cinq maillons
                // rapides — sonder ici aussi doublerait chaque mesure sans
                // rien apprendre de plus, et ferait vivre deux compteurs de
                // sondes consécutives qui s'ignorent l'un l'autre. Le
                // maillon 6 non plus ne doit pas être touché : `performRun`
                // tient déjà le dépôt ouvert via `kopia snapshot create`.
            } else {
                let needsRepository = !phase.isBusy
                    && Date().timeIntervalSince(lastRepositoryProbe) >= Self.repositoryProbeInterval
                await probeChain(includingRepository: needsRepository)
                if needsRepository { lastRepositoryProbe = Date() }
            }

            if Date().timeIntervalSince(lastLaunchAgentVerify) >= Self.launchAgentVerifyInterval {
                verifyLaunchAgent()
                lastLaunchAgentVerify = Date()
            }

            refreshScheduleDecision()
            // Ne relance que si la fenêtre est ouverte — ce qui est
            // toujours le cas ici, puisque `pollLoop` ne tourne que le temps
            // de l'application. Le job launchd fait la même proposition en
            // notre absence ; les deux ne se marchent jamais dessus grâce
            // au verrou de simultanéité.
            maybeResumeAfterNetworkReturn()

            try? await Task.sleep(for: .seconds(Self.fastProbeInterval))
        }
    }

    /// Sonde la chaîne et publie le verdict.
    ///
    /// Le maillon 6 n'est pas resondé à chaque tour : son dernier résultat est
    /// reconduit. C'est légitime **parce que `ChainEvaluator` connaît l'âge de
    /// chaque mesure** et rétrograde tout seul ce qui a dépassé la fraîcheur —
    /// on ne rejoue donc jamais une vérité périmée en la faisant passer pour
    /// fraîche.
    private func probeChain(includingRepository: Bool) async {
        guard configuration.isEnabled else { return }

        var results = await probeFastLinks()

        if includingRepository {
            results.append(await probeRepository())
        } else if let previous = chainVerdict?.results.first(where: { $0.link == .repositoryOpens }) {
            results.append(previous)
        }

        chainVerdict = ChainEvaluator.evaluate(
            results, now: Date(), freshness: Self.chainFreshness)
    }

    /// Les cinq maillons rapides, et rien de plus.
    ///
    /// Partagée par `probeChain(includingRepository:)`, qui l'utilise hors
    /// d'un run, et `watchChainDuringRun()`, qui l'utilise pendant : c'est
    /// la même mesure, écrite à un seul endroit du fichier plutôt que
    /// dupliquée entre l'inactivité et le run.
    private func probeFastLinks() async -> [LinkProbeResult] {
        let config = configuration
        async let tailscale = ChainProbes.tailscaleLocal(timeout: config.probeTimeout)
        async let node = ChainProbes.minioNodeOnline(
            nodeName: config.tailscaleMinioNodeName, timeout: config.probeTimeout)
        async let reachable = ChainProbes.s3Reachable(
            endpoint: config.s3Endpoint, timeout: config.probeTimeout)
        async let healthy = ChainProbes.minioHealthy(
            endpoint: config.s3Endpoint, disableTLS: config.disableTLS, timeout: config.probeTimeout)
        async let bucket = ChainProbes.bucketReachable(
            endpoint: config.s3Endpoint, bucket: config.s3Bucket,
            disableTLS: config.disableTLS, timeout: config.probeTimeout)
        return await [tailscale, node, reachable, healthy, bucket]
    }

    /// Le sixième maillon : ouvrir réellement le dépôt.
    ///
    /// **Jamais appelée pendant un run.** `performRun` tient déjà le dépôt
    /// ouvert via le `kopia snapshot create` en vol ; un second `kopia`
    /// lancé ici entrerait en concurrence sur le même dépôt pour une
    /// information que le run confirmera de toute façon à sa prochaine
    /// vérification. C'est pour ça que `pollLoop` saute cette fonction tant
    /// que `phase` est occupée, et que `watchChainDuringRun()` ne la
    /// connaît même pas.
    private func probeRepository() async -> LinkProbeResult {
        let start = Date()
        do {
            let status = try await BackupEngine.driver().repositoryStatus()
            repositoryStatus = status
            return LinkProbeResult(
                link: .repositoryOpens,
                state: .up,
                diagnostic: "Le dépôt s'ouvre — seau « \(status.bucket) », chiffrement \(status.encryption).",
                latency: Date().timeIntervalSince(start),
                measuredAt: Date()
            )
        } catch {
            return LinkProbeResult(
                link: .repositoryOpens,
                state: .down,
                diagnostic: "Le dépôt ne s'ouvre pas : \(error)",
                rawDetail: KopiaFailureClassifier.maskSecrets(in: String(describing: error)),
                latency: Date().timeIntervalSince(start),
                measuredAt: Date()
            )
        }
    }

    // MARK: - La surveillance pendant un run

    /// Tourne pendant tout `.running`, et seulement `.running` : sonde les
    /// cinq maillons rapides toutes les ``duringRunProbeInterval``, et coupe
    /// le run après ``networkCutStreak`` mesures `down` consécutives — voir
    /// leurs deux documentations pour la cadence et le seuil, et pourquoi
    /// ils ont été choisis ainsi plutôt qu'un autre chiffre.
    ///
    /// **S'arrête d'elle-même dès que `phase` quitte `.running`**, en plus
    /// d'être annulée par le `defer` de `performRun`. Les deux protections
    /// ne se recouvrent pas par accident : celle-ci évite qu'une itération
    /// déjà en vol ne coupe un run qui vient de se conclure autrement
    /// (succès, échec de vérification…) entre deux sondes ; l'autre garantit
    /// qu'aucune tâche ne continue de tourner une fois `performRun` sorti,
    /// quel que soit le chemin de sortie.
    private func watchChainDuringRun() async {
        var consecutiveDown = 0

        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Self.duringRunProbeInterval))
            if Task.isCancelled { return }
            guard case .running = phase else { return }

            var results = await probeFastLinks()
            if let previousRepository = chainVerdict?.results.first(where: { $0.link == .repositoryOpens }) {
                // Reconduit tel quel, jamais resondé — voir la note sur
                // `probeRepository()`.
                results.append(previousRepository)
            }
            let verdict = ChainEvaluator.evaluate(results, now: Date(), freshness: Self.chainFreshness)
            chainVerdict = verdict

            // `ChainEvaluator` ne désigne `firstFailure` que sur une mesure
            // `down` — jamais `connecting` ni `degraded`, voir sa
            // documentation. Le garde-fou sur `.repositoryOpens` est une
            // ceinture par-dessus des bretelles déjà solides : ce maillon
            // n'est jamais resondé ici, donc jamais mesuré `down` par cette
            // fonction ; il ne devrait structurellement jamais atteindre ce
            // point, et s'il y arrivait quand même, on refuse d'y réagir
            // plutôt que de couper un run sur un maillon qu'on n'a pas le
            // droit de juger pendant qu'il tourne.
            guard let firstFailure = verdict.firstFailure, firstFailure != .repositoryOpens else {
                consecutiveDown = 0
                continue
            }

            consecutiveDown += 1
            guard consecutiveDown >= Self.networkCutStreak else { continue }

            await cutRunForNetworkLoss(link: firstFailure, verdict: verdict)
            return
        }
    }

    /// Arrête proprement le run en cours parce que `link` est tombé de
    /// façon soutenue — jamais un `kill -9` direct : `cancelCurrentRun()`
    /// envoie `SIGTERM` et laisse à Kopia sa chance de refermer ses index
    /// locaux, `SIGKILL` restant le filet de sécurité après le délai de
    /// grâce. Voir sa documentation dans `KopiaDriver`.
    private func cutRunForNetworkLoss(link: ChainLink, verdict: ChainVerdict) async {
        guard let driver = activeDriver else { return }
        let diagnostic = verdict.results.first(where: { $0.link == link })?.diagnostic ?? verdict.headline
        // Le texte doit se lire, dans le journal, sans ambiguïté possible
        // avec un plantage de Kopia : c'est bran qui a choisi d'arrêter,
        // pas Kopia qui s'est arrêté tout seul.
        networkCutReason =
            "bran a arrêté la sauvegarde parce que le maillon « \(link.rawValue) » est tombé "
            + "(\(Self.networkCutStreak) sondes consécutives) : \(diagnostic)"
        await driver.cancelCurrentRun()
    }

    // MARK: - La décision

    /// Redemande à la politique ce qu'il faudrait faire, et publie sa réponse.
    ///
    /// **Publier la décision et ne pas l'exécuter est délibéré.** Ce qui
    /// exécute, c'est le job launchd ; ce qui s'affiche ici, c'est « voilà ce
    /// qui est prévu, et voilà pourquoi ». Un utilisateur doit pouvoir lire
    /// « en attente du secteur, forcée au plus tard mercredi 14 h » plutôt que
    /// de deviner.
    /// Recalcule la couverture depuis le journal et la configuration.
    ///
    /// Appelée partout où `refreshScheduleDecision()` l'est : ce sont les deux
    /// faces de la même question, et les laisser se désynchroniser ferait
    /// exactement ce qu'on cherche à empêcher — un écran qui répond à une
    /// question avec la réponse d'une autre.
    private func refreshCoverage() {
        let proofs = history.compactMap(\.proof)
        // L'hôte et l'utilisateur viennent du dépôt lui-même quand on a pu
        // l'ouvrir. Sans lui, on prend ceux de la machine : un dépôt partagé
        // peut contenir les snapshots d'un autre Mac, et ils ne couvrent rien
        // ici.
        let host = repositoryStatus?.hostname ?? ProcessInfo.processInfo.hostName
        let user = repositoryStatus?.username ?? NSUserName()
        let report = SourceCoverageEvaluator.evaluate(
            sourcePaths: configuration.sourcePaths,
            proofs: proofs,
            expectedHost: host,
            expectedUser: user,
            now: Date(),
            staleAfter: configuration.stalenessThreshold
        )
        coverage = report

        // **L'alerte système part d'ici, et pas de l'écran.** Un tableau de bord
        // ne prévient que ceux qui l'ouvrent ; or la panne à craindre est
        // précisément celle qu'on ne regarde pas — ce Mac a passé 35 jours avec
        // un serveur arrêté sans que rien ne le dise. La décision elle-même est
        // pure et se relit dans `BackupAlerts.decide` ; ici on ne fait que la
        // déclencher au moment où l'état vient de changer.
        let snapshotOfState = (configuration, history, report)
        Task {
            await BackupAlerts.checkAndFireIfNeeded(
                now: Date(),
                configuration: snapshotOfState.0,
                journal: snapshotOfState.1,
                coverage: snapshotOfState.2)
        }

        firstUploads = report.coverages.map {
            FirstUploadEvaluator.track(
                path: $0.path,
                coverage: $0.state,
                attempts: history,
                sourcePaths: configuration.sourcePaths)
        }
    }

    private func refreshScheduleDecision() {
        refreshCoverage()
        let attempts = history
        let (isOnBattery, level) = Self.powerState()
        scheduleDecision = SchedulePolicy.decide(
            now: Date(),
            lastSuccess: BackupJournalModel.lastSuccess(in: attempts)
                .flatMap { $0.proof?.endTime ?? $0.finishedAt },
            lastAttempt: BackupJournalModel.lastAttempt(in: attempts),
            configuration: configuration,
            chain: chainVerdict,
            isOnBattery: isOnBattery,
            batteryFraction: level,
            isRunning: phase.isBusy,
            consecutiveFailures: BackupJournalModel.consecutiveFailures(in: attempts)
        )
    }

    // MARK: - Les actions

    /// « Sauvegarder maintenant ».
    func backUpNow() {
        startRun(trigger: .manual)
    }

    /// Lance un run pour n'importe quel déclencheur — le bouton comme la
    /// reprise automatique de ``maybeResumeAfterNetworkReturn()``.
    ///
    /// Signature interne seulement : `backUpNow()` reste la seule façade
    /// publique, sans paramètre, pour ne rien changer à ce que l'écran
    /// appelle déjà.
    private func startRun(trigger: BackupTrigger) {
        guard runTask == nil, !phase.isBusy else { return }
        runTask = Task { [weak self] in
            await self?.performRun(trigger: trigger)
            self?.runTask = nil
        }
    }

    /// Relance dès que la chaîne redevient verte après un échec réseau —
    /// que ce soit une tentative jamais partie (chaîne rouge au moment de
    /// cliquer « sauvegarder », `BackupTrigger.networkReturned`) ou un run
    /// coupé en plein transfert par `watchChainDuringRun()`
    /// (`BackupTrigger.resume`).
    ///
    /// **Ne fait aucun calcul lui-même.** `SchedulePolicy.decide(...)`
    /// porte déjà le recul exponentiel et sait qu'une reprise ne doit pas en
    /// subir un — dédupliquer la rend bon marché, contrairement à une
    /// tentative jamais commencée. Doubler ce calcul ici referait, sur ce
    /// fichier précis, l'erreur qu'il existe pour éviter : deux avis sur la
    /// même question, qui finissent par diverger. On se contente donc de
    /// lire `scheduleDecision`, déjà republié à chaque tour de `pollLoop`,
    /// et de proposer le déclenchement qu'il indique — jamais `.catchUp` ni
    /// `.scheduled`, qui restent le ressort du job launchd et ne regardent
    /// pas le réseau.
    private func maybeResumeAfterNetworkReturn() {
        guard case .backUpNow(let trigger) = scheduleDecision,
              trigger == .resume || trigger == .networkReturned
        else { return }
        startRun(trigger: trigger)
    }

    func cancel() {
        runTask?.cancel()

        // **`runTask.cancel()` seul ne coupe rien, et le bouton mentait.**
        //
        // Annuler une `Task` ne fait que poser un drapeau. Ce que fait le
        // pilote, lui, c'est attendre la fin du processus sur une
        // `withCheckedContinuation` reprise par un `DispatchGroup` — une
        // attente qui n'écoute pas l'annulation et qui ne rend la main que
        // lorsque kopia a terminé. L'utilisateur cliquait « Annuler » sur une
        // sauvegarde de quinze heures, l'écran passait à autre chose, et
        // kopia continuait à lire, chiffrer et transférer jusqu'au bout : la
        // batterie, le réseau et le disque avec lui.
        //
        // `cancelCurrentRun()` est la seule chose qui l'arrête vraiment —
        // SIGTERM d'abord, pour que kopia referme ses index locaux, SIGKILL
        // après le délai de grâce. Elle existait déjà, complète et
        // documentée ; seule la coupure automatique sur perte réseau
        // l'appelait (`cutRunForNetworkLoss`). Le geste de l'utilisateur, non.
        if let driver = activeDriver {
            Task { await driver.cancelCurrentRun() }
        }
    }

    /// Resonde les six maillons tout de suite, dépôt compris.
    func verifyChainNow() {
        Task { [weak self] in
            await self?.probeChain(includingRepository: true)
            self?.refreshScheduleDecision()
        }
    }

    /// La séquence complète, et l'ordre des étapes **est** la fonctionnalité.
    private func performRun(trigger: BackupTrigger) async {
        // **Avant même le verrou.** `configuration` peut changer pendant les
        // 45 s qui séparent deux rafraîchissements de `chainVerdict`, et le
        // bouton « Sauvegarder maintenant » reste cliquable jusqu'à ce que
        // `phase` reparte de `.idle`. Sans ce garde, désactiver la
        // sauvegarde n'empêcherait pas un `kopia snapshot create` déjà en
        // vol de démarrer sur la foi d'un verdict de chaîne vieux de
        // quarante secondes.
        guard configuration.isEnabled else {
            log.info("sauvegarde désactivée — tentative abandonnée avant de commencer")
            return
        }

        // Le verrou ensuite. Le job launchd peut être en train de sauvegarder :
        // deux `kopia` sur le même dépôt, c'est un conflit de verrou côté
        // dépôt, et potentiellement une réparation à la main.
        guard let lock = BackupRunLock.acquire() else {
            log.info("sauvegarde déjà en cours ailleurs — le bouton ne fait rien")
            return
        }
        defer { lock.release() }
        // Jamais hérité d'une tentative précédente : sans cette remise à
        // zéro, une coupure réseau qui aurait laissé ce champ posé (chemin
        // imprévu, futur bug) ferait passer l'échec d'un tout autre run pour
        // une interruption réseau qu'il n'est pas.
        networkCutReason = nil

        let attemptID = UUID()
        let startedAt = Date()
        // Déclaré ici, hors du `do` qui suit, pour rester lisible depuis ses
        // `catch` : un run annulé ou coupé en plein transfert garde ainsi le
        // seul chiffre qui montre qu'une reprise sera bon marché, au lieu de
        // le perdre parce qu'il n'existait que dans le bloc `do`.
        var uploaded: Int64 = 0
        // Relevée pendant le run et écrite dans la tentative : c'est le
        // dénominateur qui manque au lendemain matin, quand l'application a
        // redémarré et que `BackupProgress` a disparu avec le processus.
        var estimated: Int64?

        // 1. La chaîne, dépôt compris. Sonder après coup ne servirait à rien :
        //    c'est avant de lancer qu'il faut savoir.
        machine.chainCheckStarted()
        phase = machine.phase
        await probeChain(includingRepository: true)

        guard let verdict = chainVerdict else {
            // Ne devrait plus arriver maintenant que `isEnabled` est vérifié
            // ci-dessus — `probeChain` publie toujours un verdict quand la
            // configuration est active. On ne laisse quand même jamais
            // `phase` scotchée sur « vérification en cours » sur la seule
            // foi de ce raisonnement : un futur appelant qui changerait
            // cette garde ne doit pas réintroduire l'écran bloqué que ce
            // correctif ferme.
            let failure = BackupFailure(
                kind: .unparseable,
                summary: "La chaîne n'a rendu aucun verdict après sondage.",
                rawOutput: "chainVerdict est resté nil après probeChain(includingRepository: true)")
            machine.failed(failure)
            phase = machine.phase
            record(BackupAttempt(
                id: attemptID, startedAt: startedAt, finishedAt: Date(),
                trigger: trigger, failure: failure))
            return
        }
        machine.chainEvaluated(verdict)
        phase = machine.phase
        guard verdict.canBackUp else {
            record(BackupAttempt(
                id: attemptID, startedAt: startedAt, finishedAt: Date(),
                trigger: trigger,
                failure: BackupFailure(
                    kind: .network,
                    summary: verdict.headline,
                    suggestedAction: "La sauvegarde repartira dès que la chaîne sera de nouveau verte.",
                    rawOutput: verdict.results.map(\.diagnostic).joined(separator: "\n"),
                    link: verdict.firstFailure)))
            return
        }

        do {
            let driver = try BackupEngine.driver()
            activeDriver = driver
            machine.runStarted()
            phase = machine.phase

            // Surveillance dédiée : les cinq maillons rapides sont resondés
            // pendant tout le transfert, qui peut durer dix à quinze heures
            // sur ce Mac. Sans elle, une coupure Tailscale à la troisième
            // heure ne se verrait qu'au bout d'un délai indéterminé — le
            // temps que Kopia s'entête et rende enfin une erreur de
            // transport. Le `defer` ci-dessous couvre les trois sorties du
            // bloc `do` (succès, `.verifying` en échec, exception) : aucun
            // chemin ne doit laisser cette tâche courir après la fin du run.
            let watchdog = Task { [weak self] in await self?.watchChainDuringRun() }
            defer {
                watchdog.cancel()
                activeDriver = nil
            }

            // 2. Le run. La progression est publiée au compte-gouttes.
            let reported = try await driver.createSnapshot(
                paths: configuration.sourcePaths,
                onProgress: { [weak self] progress in
                    Task { @MainActor in self?.publish(progress, uploaded: &uploaded, estimated: &estimated) }
                })
            uploaded = max(uploaded, 0)

            // 3. **L'étape qu'un pilote naïf saute.** Ce que `create` a rendu
            //    n'est que la parole du processus qui vient de finir. On relit
            //    le dépôt, et c'est la machine — pas ce fichier — qui décide si
            //    l'identifiant s'y trouve.
            machine.createReturned(reported)
            phase = machine.phase

            let confirmed = try await driver.listSnapshots()
            machine.repositoryConfirmed(confirmed)
            phase = machine.phase

            switch machine.phase {
            case .success(let proof):
                record(BackupAttempt(
                    id: attemptID, startedAt: startedAt, finishedAt: Date(),
                    trigger: trigger, proof: proof, uploadedBytes: uploaded, estimatedBytes: estimated))
            case .failed(let failure), .interrupted(let failure):
                record(BackupAttempt(
                    id: attemptID, startedAt: startedAt, finishedAt: Date(),
                    trigger: trigger, failure: failure, uploadedBytes: uploaded, estimatedBytes: estimated))
            default:
                // La machine n'a conclu ni dans un sens ni dans l'autre. On
                // n'invente pas la conclusion manquante : on l'écrit telle
                // quelle, comme un état qu'on n'a pas su lire.
                record(BackupAttempt(
                    id: attemptID, startedAt: startedAt, finishedAt: Date(),
                    trigger: trigger,
                    failure: BackupFailure(
                        kind: .unparseable,
                        summary: "La sauvegarde s'est terminée dans un état que bran n'a pas su conclure.",
                        rawOutput: String(describing: machine.phase),
                        link: nil),
                    uploadedBytes: uploaded, estimatedBytes: estimated))
            }
        } catch {
            if let reason = networkCutReason {
                // **Coupure décidée par bran, pas un plantage de Kopia.**
                // `machine.cancelled(reason:)` est la seule façon, dans ce
                // contrat, de faire passer `phase` en `.interrupted` plutôt
                // qu'en `.failed` — jamais l'inverse : une coupure réseau
                // n'est pas un échec de sauvegarde, Kopia reprendra et la
                // déduplication rendra la reprise bon marché. Ce que
                // `error` contient précisément (SIGTERM, sortie du process,
                // texte de stderr en cours de mort) n'a pas besoin d'être
                // lu : `reason` porte déjà le maillon fautif, ce que
                // `KopiaFailureClassifier` ne pourrait pas deviner depuis la
                // seule sortie brute d'un process qu'on vient de tuer
                // nous-mêmes.
                networkCutReason = nil
                machine.cancelled(reason: reason)
                phase = machine.phase
                if case .interrupted(let failure) = phase {
                    record(BackupAttempt(
                        id: attemptID, startedAt: startedAt, finishedAt: Date(),
                        trigger: trigger, failure: failure, uploadedBytes: uploaded, estimatedBytes: estimated))
                }
                // Bascule l'affichage sur « en attente réseau » plutôt que
                // de laisser l'écran scotché sur « interrompu » : la coupure
                // elle-même vient d'être actée dans le journal ci-dessus, ce
                // qui reste à montrer maintenant c'est qu'on guette
                // activement le retour, pas qu'on est resté planté. Le
                // même verdict rouge qui a justifié la coupure suffit à
                // `chainEvaluated` pour produire cet état — voir sa
                // documentation dans le contrat.
                if let redVerdict = chainVerdict {
                    machine.chainCheckStarted()
                    machine.chainEvaluated(redVerdict)
                    phase = machine.phase
                }
            } else if error is CancellationError {
                let failure = BackupFailure(
                    kind: .interrupted,
                    summary: "Sauvegarde annulée. Elle reprendra où elle en était.",
                    suggestedAction: nil,
                    rawOutput: "annulation demandée depuis l'interface")
                machine.failed(failure)
                phase = machine.phase
                record(BackupAttempt(
                    id: attemptID, startedAt: startedAt, finishedAt: Date(),
                    trigger: trigger, failure: failure, uploadedBytes: uploaded, estimatedBytes: estimated))
            } else {
                let failure = Self.classify(error)
                machine.failed(failure)
                phase = machine.phase
                record(BackupAttempt(
                    id: attemptID, startedAt: startedAt, finishedAt: Date(),
                    trigger: trigger, failure: failure, uploadedBytes: uploaded, estimatedBytes: estimated))
            }
        }
    }

    /// Publie un état de progression, au plus quatre fois par seconde.
    private func publish(_ progress: BackupProgress, uploaded: inout Int64, estimated: inout Int64?) {
        uploaded = progress.uploadedBytes
        // On garde la dernière estimation connue plutôt que la première :
        // Kopia la corrige en cours de route, à la hausse comme à la baisse.
        if let total = progress.estimatedBytes { estimated = total }
        let now = Date()
        guard now.timeIntervalSince(lastProgressPublish) >= Self.progressPublishInterval else { return }
        lastProgressPublish = now
        machine.progressed(progress)
        phase = machine.phase
    }

    /// Traduit une erreur du pilote en échec présentable.
    ///
    /// **Ne devine jamais.** Une erreur d'un type imprévu donne
    /// `.unparseable`, pas un genre plausible : classer au hasard produirait un
    /// message rassurant sur une panne qu'on n'a pas comprise.
    private static func classify(_ error: Error) -> BackupFailure {
        if let driverFailure = error as? KopiaDriverFailure,
           case .backup(let failure) = driverFailure {
            return failure
        }
        let text = String(describing: error)
        if let classified = KopiaFailureClassifier.classify(
            stderr: text, exitCode: 0, wasCancelled: false, signal: nil) {
            return classified
        }
        return BackupFailure(
            kind: .unparseable,
            summary: "La sauvegarde a échoué pour une raison que bran n'a pas su classer.",
            suggestedAction: "Copiez le diagnostic ci-dessous et regardez le journal de Kopia.",
            rawOutput: KopiaFailureClassifier.maskSecrets(in: text))
    }

    // MARK: - Le journal

    /// Écrit la tentative, puis relit le fichier.
    ///
    /// La relecture n'est pas de la superstition : le job launchd écrit dans le
    /// même fichier, et l'écran doit montrer les deux écrivains, pas seulement
    /// celui qui est devant l'utilisateur.
    private func record(_ attempt: BackupAttempt) {
        do {
            try BackupJournal.append(attempt)
        } catch {
            // Une écriture de journal ratée ne se tait pas. Confondre « je n'ai
            // pas pu noter » avec « rien à noter » referait, à l'échelle de
            // l'historique, la panne que tout ce module combat.
            log.error("journal de sauvegarde non écrit : \(String(describing: error), privacy: .public)")
        }
        reloadJournal()
        refreshScheduleDecision()
    }

    private func reloadJournal() {
        let result = BackupJournal.readAll()
        history = result.attempts
        unreadableJournalLines = result.unreadableLineCount
    }

    // MARK: - Les secrets

    /// Vrai quand le secret est **présent et lisible**.
    ///
    /// ## Pourquoi c'est une valeur en cache et pas une lecture
    ///
    /// Cette fonction est appelée depuis le corps de deux vues. Le corps d'une
    /// vue SwiftUI est réévalué à chaque changement d'un état observé — et sur
    /// cet écran, l'état change en permanence : la progression, les latences
    /// des six maillons, l'horloge du bandeau. Chaque réévaluation faisait donc
    /// un `SecItemCopyMatching`.
    ///
    /// **Et chacun peut lever une demande d'autorisation du trousseau.** Le
    /// propriétaire a vu la fenêtre « bran veut accéder au trousseau » revenir
    /// toutes les minutes ; ce n'était pas une cadence de sondage mal réglée,
    /// c'était le nombre de fois où la vue se redessinait. Un accès au
    /// trousseau depuis un corps de vue est un défaut de la même famille qu'un
    /// accès disque ou réseau : ce qui s'y trouve doit être une valeur déjà
    /// connue, jamais une opération.
    ///
    /// Le cache est rafraîchi au démarrage, après une écriture de secret, et
    /// sur demande explicite — c'est-à-dire à tous les moments où la réponse
    /// peut réellement avoir changé.
    ///
    /// Un trousseau verrouillé rend `false` : dire « enregistré » sur un secret
    /// qu'on ne peut pas lire ferait croire à une sauvegarde armée alors
    /// qu'elle échouera. L'état réel est nommé dans le diagnostic du maillon 6.
    func hasStoredSecret(_ secret: BackupSecrets.Secret) -> Bool {
        storedSecrets.contains(secret)
    }

    /// Relit le trousseau. **Une opération, appelée depuis un endroit qui a le
    /// droit d'en faire une** — jamais depuis une vue.
    private func refreshStoredSecrets() {
        var found: Set<BackupSecrets.Secret> = []
        for secret in BackupSecrets.Secret.allCases {
            // `exists` et non `read` : la question posée est « ce secret
            // est-il enregistré », pas « quelle est sa valeur ». Demander la
            // valeur au Trousseau est précisément ce qui peut lever une
            // demande d'autorisation — payer ce risque pour une réponse dont
            // on n'a pas besoin serait gratuit.
            if case .present = BackupSecrets.exists(secret) { found.insert(secret) }
        }
        storedSecrets = found
    }

    /// Enregistre un secret. Rend `false` si le trousseau a refusé.
    func renewSecret(_ secret: BackupSecrets.Secret, to value: String) -> Bool {
        guard !value.isEmpty else { return false }
        if case .saved = BackupSecrets.write(value, for: secret) {
            refreshStoredSecrets()
            // Le mot de passe retenu en mémoire est périmé à la seconde où il
            // est remplacé. L'oublier ici évite un échec d'authentification
            // juste après une saisie que l'utilisateur sait correcte.
            if secret == .repositoryPassword { KeychainKopiaPassword.forget() }
            // Le secret a changé : ce que la chaîne disait de lui ne vaut plus.
            verifyChainNow()
            return true
        }
        return false
    }

    // MARK: - Veille et réveil

    private func observeSleepAndWake() {
        let center = NSWorkspace.shared.notificationCenter
        sleepObservers.append(center.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // On ne tue rien : Kopia sera suspendu avec la machine, et un
                // run coupé se **reprend**. La déduplication fait que la
                // reprise ne recommence pas le travail déjà monté.
                self?.log.info("veille pendant une sauvegarde : elle reprendra au réveil")
            }
        })
        sleepObservers.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // **Resonder avant de conclure quoi que ce soit.** Le verdict
                // d'avant la veille décrit un réseau qui n'existe peut-être
                // plus — autre lieu, autre Wi-Fi, tunnel Tailscale à refaire.
                // Le rejouer tel quel est la panne des 35 jours en miniature.
                self.chainVerdict = nil
                self.verifyChainNow()
            }
        })
    }

    /// L'état de l'alimentation, pour la politique batterie.
    private static func powerState() -> (onBattery: Bool, fraction: Double?) {
        // `IOPSCopyPowerSourcesInfo` demanderait IOKit ; `pmset` répond en une
        // ligne et ce chiffre n'est lu qu'une fois toutes les 45 s. Quand la
        // sortie n'est pas celle qu'on attend, on rend « pas sur batterie » —
        // c'est le repli qui ne bloque jamais une sauvegarde par ignorance.
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/pmset")
        process.arguments = ["-g", "batt"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard let text = String(data: data, encoding: .utf8) else { return (false, nil) }
            let onBattery = text.contains("Battery Power")
            let percent = text.firstMatch(of: /(\d{1,3})%/).map { Double($0.1)! / 100 }
            return (onBattery, percent)
        } catch {
            return (false, nil)
        }
    }
}

/// Le verrou de simultanéité, du côté de l'interface.
///
/// **Le même fichier que celui de `BackupHeadlessRun`**, et c'est tout
/// l'intérêt : le bouton « sauvegarder maintenant » et le job launchd se
/// disputent le même verrou, donc ils ne peuvent pas lancer deux `kopia` sur le
/// même dépôt.
///
/// `flock` et jamais un fichier-témoin portant un PID : le noyau libère un
/// verrou `flock` à la mort du processus qui le tenait, quelle qu'en soit la
/// cause. Un témoin, lui, survit à un `kill -9` et bloque la sauvegarde pour
/// toujours — un verrou qui devient une panne.
enum BackupRunLock {

    struct Held {
        fileprivate let fileDescriptor: Int32
        func release() {
            flock(fileDescriptor, LOCK_UN)
            close(fileDescriptor)
        }
    }

    /// Ce qu'une tentative de prise du verrou a appris — **trois issues, pas
    /// deux**.
    ///
    /// **Ce que l'ancien `Held?` confondait.** Il rendait `nil` aussi bien
    /// quand une autre sauvegarde tenait le verrou que quand `open()` ou
    /// `flock()` avaient échoué pour une tout autre raison : droits retirés sur
    /// `~/Library/Application Support/bran/backup`, disque plein, volume monté
    /// en lecture seule, dossier remplacé par un fichier. L'appelant écrivait
    /// alors « sauvegarde déjà en cours ailleurs » dans le journal système et
    /// ne tentait rien — silencieusement, à chaque échéance, indéfiniment. Une
    /// panne de disque déguisée en contention normale est exactement la
    /// famille de mensonge que ce module combat : la sauvegarde s'arrête, et
    /// le seul message dit que tout va bien.
    ///
    /// `EWOULDBLOCK` (`EAGAIN` sur Darwin) est le **seul** code que `flock` en
    /// mode `LOCK_NB` rend pour une contention. Tout le reste est une panne.
    enum Outcome {
        case acquired(Held)
        /// Un autre processus — l'interface ou le job launchd — tient le
        /// verrou. Ce n'est pas une panne : c'est une information.
        case heldByAnotherProcess
        /// Le verrou n'a pas pu être **tenté** : `errno` dit pourquoi.
        case failed(operation: String, errno: Int32)
    }

    static func acquire() -> Outcome {
        let directory = BackupJournal.directory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return .failed(operation: "création du dossier du verrou", errno: (error as NSError).code == NSFileWriteNoPermissionError ? EACCES : EIO)
        }
        let url = directory.appending(path: "run.lock", directoryHint: .notDirectory)
        let fd = open(url.path(percentEncoded: false), O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else {
            return .failed(operation: "ouverture du fichier de verrou", errno: errno)
        }
        // `LOCK_NB` : on ne veut pas attendre. Un run peut durer des heures, et
        // un bouton qui reste enfoncé tout ce temps ne serait pas un bouton.
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(fd)
            if code == EWOULDBLOCK { return .heldByAnotherProcess }
            return .failed(operation: "pose du verrou", errno: code)
        }
        return .acquired(Held(fileDescriptor: fd))
    }

    /// Vrai quand une sauvegarde tourne **dans un autre processus** — le job
    /// launchd, typiquement, pendant que la fenêtre est ouverte.
    ///
    /// Sert à ne pas recharger le `LaunchAgent` sous les pieds d'un run en
    /// cours : `launchctl bootout` tuerait le processus que launchd a démarré,
    /// donc le `kopia snapshot create` qu'il tient. La mesure est fatalement
    /// datée d'un instant — un run peut démarrer juste après —, mais combinée
    /// au fait qu'on ne recharge plus **que** si la définition a changé, la
    /// fenêtre de course se réduit à un cas qui demande de modifier un réglage
    /// à la milliseconde près où un run démarre.
    static func isHeldByAnotherProcess() -> Bool {
        switch acquire() {
        case .acquired(let held):
            held.release()
            return false
        case .heldByAnotherProcess:
            return true
        case .failed:
            // On ne sait pas. Répondre « occupé » diffère une resynchronisation
            // du job ; répondre « libre » risque de couper une sauvegarde. Le
            // premier tort se rattrape au tour suivant, le second non.
            return true
        }
    }
}
