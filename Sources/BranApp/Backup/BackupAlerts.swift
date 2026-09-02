import BranBackup
import Foundation
import UserNotifications

/// Ce fichier ferme les deux trous décrits dans le briefing d'alerte de la
/// sauvegarde : un mot de passe de dépôt qui ne vit qu'à l'endroit qu'il
/// protège, et un Mac sans supervision qui ne dit jamais qu'il a cessé de
/// sauvegarder. Les deux se rejoignent sur une même contrainte : **une
/// alerte qui revient trop souvent apprend à la balayer sans la lire**, et
/// le jour où elle est vraie, personne ne la regarde plus. Tout ce qui suit
/// est construit contre ce risque-là autant que contre le silence.
///
/// ## Pourquoi la décision est une fonction pure
///
/// `decide(now:configuration:journal:coverage:lastAlertFiredAt:)` ne lit ni
/// l'horloge, ni le disque, ni le Trousseau : elle prend en entrée exactement
/// ce que `BackupController` et `BackupHeadlessRun` ont déjà sous la main —
/// le journal relu, la configuration, le dernier verdict de couverture, et
/// l'instant présent — et rend un verdict testable sans jamais notifier pour
/// de vrai. Seule `checkAndFireIfNeeded` touche le Trousseau système
/// (`UserNotifications`) et `UserDefaults` ; c'est la seule fonction de ce
/// fichier qui a un effet de bord, et c'est délibéré.
///
/// ## Pourquoi rien ici n'est isolé sur `@MainActor`
///
/// `BackupHeadlessRun.runIfRequested()` bloque le fil principal sur un
/// sémaphore pendant qu'une `Task` non isolée fait le travail réel — le même
/// patron que `BackupProvisioning.runSynchronously`. Si `checkAndFireIfNeeded`
/// exigeait `@MainActor`, l'appel depuis cette tâche tenterait de sauter sur
/// le fil principal, qui est bloqué sur `semaphore.wait()` et ne pompe aucune
/// file d'attente : blocage mutuel garanti, découvert en lisant
/// `BackupHeadlessRun.swift` avant d'écrire une seule ligne ici.
/// `UNUserNotificationCenter` et `UserDefaults` sont tous deux thread-safe
/// sans exiger le fil principal ; ce fichier s'en tient donc à du code
/// ordinaire, jamais isolé.
///
/// ## La cadence, et pourquoi elle est celle-ci
///
/// **Un seuil avant la première alerte, fondé sur `intervalHours` — jamais
/// un nombre inventé.** `max(intervalHours × 3, 24)` heures : trois échéances
/// manquées d'affilée, jamais moins d'une journée pleine. En dessous, une
/// seule échéance ratée — un portable fermé le soir, une sieste réseau de
/// quinze minutes — ne prouve rien ; c'est exactement ce que
/// `FailureKind.deservesRetry` distingue déjà côté `SchedulePolicy`, et ce
/// seuil applique la même prudence côté alerte, sans dupliquer sa logique de
/// recul exponentiel. Avec la cadence par défaut de ce Mac (48 h,
/// `BackupConfigurationStore.defaultConfiguration()`), le seuil tombe à
/// 144 h — six jours, le chiffre même que porte l'exemple du briefing.
///
/// **Une alerte par jour au maximum, ensuite.** Pas moins souvent : un vrai
/// incident d'une semaine mérite d'être répété, pas signalé une fois puis
/// oublié. Pas plus souvent : `BackupHeadlessRun` tourne toutes les heures,
/// et sans ce plancher, un run headless qui échoue en boucle enverrait une
/// notification par heure — la certitude d'apprendre à l'ignorer avant même
/// que l'incident ne soit réel.
///
/// **Le mot de passe de dépôt : une fois, au premier succès prouvé — jamais
/// au provisionnement.** Trois raisons. D'abord, au provisionnement, rien
/// n'est encore prouvé : avertir avant qu'un seul octet n'ait été confirmé
/// dans le dépôt reviendrait à parler d'un risque sur des données qui
/// n'existent pas encore ailleurs que sur ce Mac — le pire moment pour faire
/// prendre au sérieux un message qu'on entendra de toute façon quand il y
/// aura vraiment quelque chose à perdre. Ensuite, le premier succès est un
/// moment où l'utilisateur regarde déjà l'écran, satisfait — un message
/// qui arrive sur une victoire se lit, contrairement à un avertissement
/// perdu dans une suite d'écrans de configuration. Enfin, une seule fois :
/// un rappel qui reviendrait à chaque sauvegarde deviendrait exactement le
/// bruit que ce fichier existe pour éviter. Le texte survit quand même sous
/// deux autres formes, en continu et sans notification, voir plus bas.
enum BackupAlerts {

    // MARK: - Ce qu'une alerte porte

    struct Content: Sendable, Equatable {
        var identifier: String
        var title: String
        var body: String
    }

    /// Le verdict pur. `.silence` porte toujours une raison en français : ce
    /// n'est pas pour l'utilisateur, c'est pour le journal système et pour
    /// quiconque relit ce fichier et se demande pourquoi rien n'est parti.
    enum Decision: Sendable, Equatable {
        case silence(String)
        case notify(Content)
    }

    // MARK: - La décision : sauvegarde en retard ou source non couverte

    /// - Parameters:
    ///   - journal: L'historique tel que `BackupJournal.readAll().attempts`
    ///     le rend — dans n'importe quel ordre, dédupliqué ou non : les
    ///     questions posées ici passent toutes par `BackupJournalModel`, qui
    ///     s'en charge.
    ///   - coverage: Le dernier verdict de `SourceCoverageEvaluator`, quand
    ///     l'appelant a pu le calculer. `nil` veut dire « pas mesuré cette
    ///     fois » — jamais interprété comme « tout va bien » : voir la garde
    ///     plus bas, qui ne regarde `coverage` que s'il existe.
    ///   - lastAlertFiredAt: La date de la dernière notification réellement
    ///     envoyée par ce fichier — jamais une tentative de sauvegarde.
    ///     `nil` la première fois.
    ///   - watchingSince: Le premier instant où ce Mac a été vu avec une
    ///     sauvegarde **activée** — retenu par `checkAndFireIfNeeded` dans
    ///     `UserDefaults`, remis à zéro quand la sauvegarde est éteinte. C'est
    ///     la date de départ qui manquait pour pouvoir alerter sur un journal
    ///     **vide**. Voir plus bas.
    static func decide(
        now: Date,
        configuration: BackupConfiguration,
        journal: [BackupAttempt],
        coverage: SourceCoverageReport?,
        lastAlertFiredAt: Date?,
        watchingSince: Date? = nil
    ) -> Decision {
        guard configuration.isEnabled else {
            // Une configuration éteinte est un choix, pas une panne. L'alerte
            // existe pour un silence qu'on n'a pas demandé, jamais pour un
            // silence qu'on a choisi.
            return .silence("la sauvegarde n'est pas activée")
        }

        if let lastAlertFiredAt, now.timeIntervalSince(lastAlertFiredAt) < reminderCooldown {
            return .silence("une alerte a déjà été envoyée il y a moins de 24 h ; on ne double pas")
        }

        // **Le compteur repart du dernier *succès*, jamais de la dernière
        // *activité* — et c'est la correction qui rendait ce fichier muet.**
        //
        // L'ancienne mesure prenait `journal.map(activityDate).max()`,
        // c'est-à-dire la tentative la plus récente, réussie ou non. Or le job
        // launchd tourne **toutes les heures** et journalise chaque échec :
        // un serveur MinIO éteint produisait donc une tentative ratée par
        // heure, chacune repoussant `mostRecentActivity` à moins d'une heure,
        // donc toujours en dessous du seuil de 144 h. Plus la panne durait,
        // plus elle rafraîchissait le compteur censé la détecter. Ce Mac
        // pouvait rester 35 jours sans une seule sauvegarde en émettant
        // 840 échecs et zéro alerte — précisément la panne fondatrice du
        // projet, cette fois du côté du signal plutôt que du côté du stockage.
        //
        // Trois origines possibles pour l'instant de départ, dans cet ordre :
        //  1. le dernier succès prouvé — la seule chose qui remette vraiment
        //     le compteur à zéro ;
        //  2. à défaut, la **première** tentative connue : « jamais réussi
        //     depuis N jours » se mesure depuis le premier essai, pas depuis
        //     le dernier ;
        //  3. à défaut de tout journal, l'instant où ce Mac a été vu avec la
        //     sauvegarde activée. C'est ce troisième cas qui manquait : sans
        //     lui, un Mac dont **aucune** tentative n'aboutit jamais à une
        //     ligne de journal — chaîne rouge en permanence, verrou
        //     inaccessible, binaire kopia absent — restait silencieux pour
        //     toujours, sous prétexte qu'il n'y avait « rien à mesurer ».
        let reference: Date
        let referenceLabel: String
        if let lastSuccess = BackupJournalModel.lastSuccess(in: journal) {
            reference = referenceDate(for: lastSuccess)
            referenceLabel = "le dernier succès"
        } else if let firstAttempt = journal.map(\.startedAt).min() {
            reference = firstAttempt
            referenceLabel = "la première tentative"
        } else if let watchingSince {
            reference = watchingSince
            referenceLabel = "l'activation de la sauvegarde"
        } else {
            return .silence("aucune tentative n'a encore été consignée et aucune date d'activation n'est connue")
        }

        let elapsed = now.timeIntervalSince(reference)
        let threshold = max(configuration.intervalHours * staleMultiplier, minimumThresholdHours) * 3600
        guard elapsed >= threshold else {
            return .silence("\(referenceLabel) date de moins de \(Int(threshold / 3600)) h")
        }

        // La couverture prime sur l'ancienneté d'un succès : c'est elle qui
        // referme le mensonge documenté dans `BackupController` — un
        // snapshot de `~/Music` qui affiche « réussi » pendant que le
        // dossier personnel entier n'a jamais été envoyé. Un succès récent
        // sur le mauvais chemin ne doit pas rendre ce fichier muet.
        if let coverage, coverage.verdict != .fullyCovered {
            return .notify(coverageGapContent(coverage: coverage))
        }

        let days = max(Int(elapsed / 86400), 1)
        let lastFailure = BackupJournalModel.lastAttempt(in: journal)?.failure
        guard BackupJournalModel.lastSuccess(in: journal) != nil else {
            return .notify(neverSucceededContent(
                days: days, hasAnyAttempt: !journal.isEmpty, lastFailure: lastFailure))
        }
        return .notify(staleBackupContent(daysSinceSuccess: days, lastFailure: lastFailure))
    }

    /// Trois échéances manquées, jamais moins d'un jour plein — voir l'en-tête
    /// du fichier pour la justification complète.
    private static let staleMultiplier: Double = 3
    private static let minimumThresholdHours: Double = 24
    private static let reminderCooldown: TimeInterval = 24 * 3600

    /// L'instant qui fait foi pour un succès : celui où le dépôt l'a
    /// confirmé, pas celui où la ligne de journal a été écrite. Même choix
    /// que `BackupHeadlessRun.probeChain` fait pour `SchedulePolicy.decide`,
    /// reproduit ici pour que l'alerte et le planificateur comptent les jours
    /// de la même façon.
    private static func referenceDate(for attempt: BackupAttempt) -> Date {
        attempt.proof?.endTime ?? attempt.finishedAt ?? attempt.startedAt
    }

    // MARK: - Les textes

    private static let healthAlertIdentifier = "com.opahventures.bran.backup.health"

    private static func staleBackupContent(daysSinceSuccess: Int, lastFailure: BackupFailure?) -> Content {
        let dayWord = daysSinceSuccess > 1 ? "jours" : "jour"
        var body = "Vos fichiers ne sont plus sauvegardés depuis \(daysSinceSuccess) \(dayWord)"
        if let lastFailure {
            body += " — \(lastFailure.summary)."
            body += lastFailure.kind.deservesRetry
                ? " bran réessaiera automatiquement dès que la connexion reviendra."
                : lastFailure.suggestedAction.map { " \($0)" } ?? ""
        } else {
            body += "."
        }
        return Content(identifier: healthAlertIdentifier, title: "Sauvegarde en retard", body: body)
    }

    /// - Parameters:
    ///   - days: le nombre de jours **depuis le début du silence** — la
    ///     première tentative connue, ou l'activation de la sauvegarde quand
    ///     aucune tentative n'a jamais été consignée. Jamais « depuis la
    ///     dernière tentative » : un job qui échoue toutes les heures rendrait
    ///     ce nombre éternellement égal à 1, ce qui minimise exactement ce
    ///     qu'il faut signaler.
    ///   - hasAnyAttempt: faux quand le journal est vide. Les deux situations
    ///     n'appellent pas le même geste : « ça échoue » se diagnostique avec
    ///     le dernier message d'erreur, « rien n'est jamais parti » se
    ///     diagnostique en ouvrant bran.
    private static func neverSucceededContent(
        days: Int, hasAnyAttempt: Bool, lastFailure: BackupFailure?
    ) -> Content {
        let dayWord = days > 1 ? "jours" : "jour"
        guard hasAnyAttempt else {
            return Content(
                identifier: healthAlertIdentifier,
                title: "Aucune sauvegarde n'a démarré",
                body: "La sauvegarde est activée depuis \(days) \(dayWord), et aucune tentative n'a jamais "
                    + "été consignée — pas même un échec. Ouvrez bran : la chaîne réseau, le Trousseau ou "
                    + "le job planifié empêchent le démarrage."
            )
        }
        var body = "Vos fichiers n'ont jamais été sauvegardés avec succès, malgré des tentatives "
            + "depuis \(days) \(dayWord)"
        body += lastFailure.map { " — \($0.summary)." } ?? "."
        return Content(identifier: healthAlertIdentifier, title: "Aucune sauvegarde réussie", body: body)
    }

    /// `coverage.headline` porte déjà une phrase française exacte et
    /// spécifique — quel dossier manque, combien sont couverts. Ce fichier ne
    /// la reformule pas : la répéter avec d'autres mots créerait deux
    /// versions de la même vérité, susceptibles de diverger un jour.
    private static func coverageGapContent(coverage: SourceCoverageReport) -> Content {
        Content(
            identifier: healthAlertIdentifier,
            title: "Sauvegarde incomplète",
            body: coverage.headline + " Ouvrez bran pour vérifier la configuration."
        )
    }

    // MARK: - Le mot de passe de dépôt

    private static let repositoryPasswordIdentifier = "com.opahventures.bran.backup.repository-password"

    /// Vrai exactement une fois dans la vie d'une installation : au premier
    /// instant où le journal contient un succès prouvé, et où ce fichier n'a
    /// encore jamais averti. `alreadyWarned` est fourni par l'appelant — la
    /// persistance elle-même (`UserDefaults`) est un effet de bord, tenu à
    /// l'écart de cette fonction pour qu'elle reste testable sur un simple
    /// booléen.
    static func shouldWarnAboutRepositoryPassword(alreadyWarned: Bool, journal: [BackupAttempt]) -> Bool {
        guard !alreadyWarned else { return false }
        return BackupJournalModel.lastSuccess(in: journal) != nil
    }

    private static let repositoryPasswordContent = Content(
        identifier: repositoryPasswordIdentifier,
        title: "Un mot de passe à mettre en sécurité",
        body: "Votre première sauvegarde chiffrée est confirmée. Le mot de passe du dépôt ne peut être "
            + "réinitialisé par personne : s'il est perdu avec ce Mac, ces fichiers deviennent illisibles "
            + "pour toujours. Notez-le, ou copiez-le, en dehors de cette machine."
    )

    /// Le même avertissement, pour les deux endroits qui ne notifient pas.
    ///
    /// **Réglages**, en continu : contrairement à la notification, un texte
    /// affiché en permanence ne se ferme pas une fois lu — voir l'en-tête du
    /// fichier sur le risque d'une fenêtre qu'on apprend à balayer. C'est ce
    /// qui couvre le cas du frère du propriétaire s'il ouvre un jour les
    /// réglages sans avoir vu la notification.
    ///
    /// **`BackupProvisioning.runIfRequested()`**, sur la sortie d'erreur : la
    /// seule installation qui peut ne *jamais* ouvrir de fenêtre — un
    /// provisionnement scripté par SSH, sur un Mac qui ne lancera peut-être
    /// l'interface que bien plus tard, voire jamais. Ce fichier n'écrit pas
    /// dans `BackupProvisioning.swift` — un autre agent y travaille en
    /// parallèle sur un objet différent — donc cette constante n'est
    /// qu'exposée ; le rapport de cette mission en donne la ligne de
    /// câblage.
    static let repositoryPasswordReminderText =
        "Le mot de passe de dépôt chiffre vos sauvegardes de bout en bout. Il n'existe nulle part ailleurs "
        + "que sur ce Mac : s'il est perdu, ces fichiers ne pourront plus jamais être relus, par personne — "
        + "pas même vous. Conservez-en une copie en dehors de cette machine."

    // MARK: - Le seul point d'entrée à câbler

    private static let lastFiredDefaultsKey = "bran.backup.alerts.lastFiredAt"
    private static let passwordWarnedDefaultsKey = "bran.backup.alerts.repositoryPasswordWarned"
    private static let watchingSinceDefaultsKey = "bran.backup.alerts.watchingSince"

    /// Ce que `BackupController` (après chaque rafraîchissement) et
    /// `BackupHeadlessRun` (après chaque tentative) doivent appeler — la
    /// seule fonction de ce fichier qui touche `UserNotifications` et
    /// `UserDefaults`, donc la seule à ne jamais appeler depuis un test.
    ///
    /// Idempotente à l'échelle de la minute où elle est appelée plusieurs
    /// fois de suite : `decide` relit `lastAlertFiredAt` à chaque appel, donc
    /// un deuxième appel immédiat retombe sur `.silence` du cooldown.
    static func checkAndFireIfNeeded(
        now: Date,
        configuration: BackupConfiguration,
        journal: [BackupAttempt],
        coverage: SourceCoverageReport?,
        defaults: UserDefaults = .standard,
        center: UNUserNotificationCenter = .current()
    ) async {
        if shouldWarnAboutRepositoryPassword(
            alreadyWarned: defaults.bool(forKey: passwordWarnedDefaultsKey),
            journal: journal
        ) {
            if await fire(repositoryPasswordContent, center: center) {
                defaults.set(true, forKey: passwordWarnedDefaultsKey)
            }
        }

        // **La date de départ qui manquait.** Tant qu'aucune tentative n'a été
        // consignée, il n'existe dans le programme aucun instant auquel
        // comparer `now` — ni la configuration ni le journal n'en portent un —
        // et `decide` se taisait donc pour toujours sur le pire cas de tous :
        // une sauvegarde activée dont rien ne part jamais. On retient ici, une
        // fois, l'instant où ce Mac a été vu avec la sauvegarde active. Effet
        // de bord assumé, à la frontière — la décision, elle, reste pure et
        // reçoit cet instant en paramètre.
        //
        // Remis à zéro dès que la sauvegarde est désactivée : réactiver plus
        // tard doit repartir d'aujourd'hui, pas réveiller une alerte fondée sur
        // une activation d'il y a six mois.
        let watchingSince: Date?
        if configuration.isEnabled {
            if let stored = defaults.object(forKey: watchingSinceDefaultsKey) as? Date {
                watchingSince = stored
            } else {
                defaults.set(now, forKey: watchingSinceDefaultsKey)
                watchingSince = now
            }
        } else {
            defaults.removeObject(forKey: watchingSinceDefaultsKey)
            watchingSince = nil
        }

        let lastAlertFiredAt = defaults.object(forKey: lastFiredDefaultsKey) as? Date
        switch decide(
            now: now, configuration: configuration, journal: journal, coverage: coverage,
            lastAlertFiredAt: lastAlertFiredAt, watchingSince: watchingSince
        ) {
        case .silence:
            break
        case .notify(let content):
            if await fire(content, center: center) {
                defaults.set(now, forKey: lastFiredDefaultsKey)
            }
        }
    }

    /// Émet une notification, en remplaçant d'abord toute notification
    /// délivrée sous le même identifiant.
    ///
    /// **Sans ce retrait, les rappels s'empileraient dans le centre de
    /// notifications** — `add(_:)` ne remplace que les requêtes encore en
    /// attente, jamais celles déjà présentées, et le déclencheur `nil` de
    /// bran les présente immédiatement. Après une semaine d'incident, sept
    /// bannières identiques ne rendraient pas l'alerte plus vraie, seulement
    /// plus facile à ignorer d'un geste — exactement ce que ce fichier existe
    /// pour éviter.
    ///
    /// Ne demande jamais l'autorisation elle-même : `NotificationService`
    /// s'en charge déjà au lancement de l'interface. Un Mac qui n'aurait
    /// jamais ouvert l'interface au moins une fois ne verra donc aucune de
    /// ces notifications — voir le rapport de mission.
    @discardableResult
    private static func fire(_ content: Content, center: UNUserNotificationCenter) async -> Bool {
        center.removeDeliveredNotifications(withIdentifiers: [content.identifier])

        let notification = UNMutableNotificationContent()
        notification.title = content.title
        notification.body = content.body
        notification.sound = .default

        let request = UNNotificationRequest(identifier: content.identifier, content: notification, trigger: nil)
        do {
            try await center.add(request)
            return true
        } catch {
            return false
        }
    }
}
