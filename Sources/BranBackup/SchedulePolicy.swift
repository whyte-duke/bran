import Foundation

// Le décideur : à un instant donné, avec l'état qu'on connaît, faut-il lancer
// une sauvegarde ?
//
// **Pourquoi une fonction pure et pas un minuteur.** Un minuteur ne s'exécute
// que si l'application tourne — « toutes les 48 h » ne veut rien dire sur une
// machine qu'on éteint le soir, ce qui est le cas normal de ce Mac, pas un cas
// limite. La seule chose qui traverse une extinction est l'horloge murale :
// on compare donc systématiquement `now` à `lastSuccess`, jamais un compte à
// rebours qui aurait dû décrémenter pendant que rien ne tournait.
//
// **Pourquoi pas de `Date()` ici.** Toute la valeur de cette fonction est
// d'être rejouable sur une horloge figée : c'est ce qui permet de tester « le
// Mac était éteint une semaine » sans attendre une semaine. Une fonction qui
// lit l'horloge elle-même ne peut prouver ni l'un ni l'autre.

// MARK: - La décision

/// Ce que la politique de planification décide, et pourquoi.
///
/// Chaque cas d'attente porte de quoi afficher une promesse vérifiable, jamais
/// une boîte noire : une date pour `.wait` et `.waitForPower`, un diagnostic
/// nommé pour `.waitForNetwork`, une raison en français pour `.disabled`.
public enum ScheduleDecision: Sendable, Hashable {
    /// Lancer maintenant, avec la raison qui l'a déclenché — manuel, échéance,
    /// rattrapage, réseau revenu, ou reprise d'un run coupé.
    case backUpNow(BackupTrigger)
    /// Pas encore l'heure. `until` est l'échéance calculée depuis `lastSuccess`,
    /// jamais depuis `now` : c'est elle que l'interface affiche.
    case wait(until: Date, because: String)
    /// La chaîne réseau est rouge, ou pas encore sondée. `because` nomme le
    /// maillon fautif — jamais un simple « erreur ».
    case waitForNetwork(String)
    /// Sur batterie. `forceAt` est la date, absolue, au-delà de laquelle on
    /// sauvegarde quel que soit l'état de l'alimentation : un report sans borne
    /// est l'absence de sauvegarde, exactement la panne dont ce projet est né.
    case waitForPower(forceAt: Date, because: String)
    /// Configuration désactivée ou incomplète.
    case disabled(String)
    /// Un run occupe déjà le dépôt. Absolu, sans condition : c'est la moitié
    /// logique du verrou de simultanéité, l'autre moitié vivant dans `BranApp`.
    case alreadyRunning
}

// MARK: - La politique

public enum SchedulePolicy {

    /// Décide s'il faut sauvegarder maintenant, et pourquoi (pas).
    ///
    /// - Parameters:
    ///   - now: L'instant présent, tel que l'appelant le connaît. Jamais lu ici.
    ///   - lastSuccess: La date du dernier `BackupAttempt.succeeded == true`.
    ///     `nil` veut dire : aucun succès dans toute l'histoire du dépôt — l'état
    ///     exact de ce Mac aujourd'hui, à traiter comme urgent, pas comme
    ///     un début tranquille.
    ///   - lastAttempt: La dernière tentative consignée, réussie ou non. Sert à
    ///     détecter une reprise à faire ou un échec à ne pas rejouer en boucle.
    ///   - configuration: Les réglages de ce Mac.
    ///   - chain: Le dernier verdict de la chaîne réseau. `nil` veut dire
    ///     « jamais sondée depuis le lancement » — distinct d'une chaîne rouge.
    ///   - isOnBattery: Vrai si le Mac tourne sur sa batterie à cet instant.
    ///   - batteryFraction: Le niveau de batterie, quand on le connaît. Purement
    ///     informatif : il n'entre dans aucune condition, seulement dans le
    ///     message affiché — la promesse du seuil qui force ne dépend pas du
    ///     niveau restant.
    ///   - isRunning: Vrai si un run occupe déjà le dépôt.
    ///   - consecutiveFailures: Le nombre d'échecs réessayables qui se sont
    ///     enchaînés jusqu'à `lastAttempt` compris. Le journal les compte ;
    ///     cette fonction n'en garde aucune trace elle-même — elle resterait
    ///     pure sans lui.
    public static func decide(
        now: Date,
        lastSuccess: Date?,
        lastAttempt: BackupAttempt?,
        configuration: BackupConfiguration,
        chain: ChainVerdict?,
        isOnBattery: Bool,
        batteryFraction: Double?,
        isRunning: Bool,
        consecutiveFailures: Int = 0
    ) -> ScheduleDecision {
        // Absolu : un run en cours répond à tout, avant même de regarder si la
        // configuration a un sens.
        if isRunning { return .alreadyRunning }

        if let reason = configurationProblem(configuration) {
            return .disabled(reason)
        }

        guard let chain else {
            // Ne jamais lancer sur une ignorance : on ne sait pas encore si le
            // dépôt est joignable, donc on le dit plutôt que de deviner « vert ».
            return .waitForNetwork(
                "la chaîne réseau n'a pas encore été sondée depuis le lancement ; mesure en cours avant toute tentative"
            )
        }
        if !chain.canBackUp {
            // Le diagnostic du premier maillon fautif, pas un résumé générique :
            // c'est lui qui dit où ça casse et quoi faire.
            let diagnostic = chain.firstFailure
                .flatMap { link in chain.results.first { $0.link == link }?.diagnostic }
                ?? chain.headline
            return .waitForNetwork(diagnostic)
        }

        switch resolveIntent(
            now: now,
            lastSuccess: lastSuccess,
            lastAttempt: lastAttempt,
            configuration: configuration,
            consecutiveFailures: consecutiveFailures
        ) {
        case let .wait(until, because):
            return .wait(until: until, because: because)
        case let .run(trigger, dueSince):
            return gateOnBattery(
                trigger: trigger,
                dueSince: dueSince,
                now: now,
                configuration: configuration,
                isOnBattery: isOnBattery,
                batteryFraction: batteryFraction
            )
        }
    }

    // MARK: - Ce qu'on ferait si l'alimentation n'entrait pas en jeu

    /// Ce que veut la seule horloge, avant toute considération de batterie.
    private enum Intent: Sendable {
        /// Sauvegarder, et depuis quand c'est dû — c'est cette date qui ancre
        /// le calcul du seuil qui force, plus bas dans `gateOnBattery`.
        case run(BackupTrigger, dueSince: Date)
        case wait(until: Date, because: String)
    }

    private static func resolveIntent(
        now: Date,
        lastSuccess: Date?,
        lastAttempt: BackupAttempt?,
        configuration: BackupConfiguration,
        consecutiveFailures: Int
    ) -> Intent {
        if let attempt = lastAttempt, !attempt.succeeded {
            // N'est pertinente que la tentative postérieure au dernier succès :
            // une vieille panne déjà couverte par un succès plus récent ne doit
            // pas rouvrir une attente.
            let isRelevant = lastSuccess.map { attempt.startedAt > $0 } ?? true
            if isRelevant {
                return intentForFailedAttempt(
                    attempt,
                    now: now,
                    configuration: configuration,
                    consecutiveFailures: consecutiveFailures
                )
            }
        }
        return scheduleIntent(now: now, lastSuccess: lastSuccess, configuration: configuration)
    }

    private static func intentForFailedAttempt(
        _ attempt: BackupAttempt,
        now: Date,
        configuration: BackupConfiguration,
        consecutiveFailures: Int
    ) -> Intent {
        // Pas de date de fin, ou explicitement coupée : la reprise prime sur
        // l'attente. La déduplication de Kopia rend une reprise bon marché — ce
        // n'est pas un nouvel essai complet, seulement la suite.
        if attempt.finishedAt == nil || attempt.failure?.kind == .interrupted {
            return .run(.resume, dueSince: attempt.startedAt)
        }

        guard let failure = attempt.failure else {
            // Terminé, non réussi, mais sans échec consigné : une incohérence
            // du journal, pas un succès qu'on suppose. Même repli qu'un échec
            // non réessayable — l'échéance normale, jamais une boucle sur un
            // état qu'on ne comprend pas.
            return nonRetryableIntent(
                anchor: attempt.finishedAt ?? attempt.startedAt,
                configuration: configuration,
                now: now,
                reason: "la dernière tentative s'est terminée sans preuve ni échec consigné"
            )
        }

        if failure.kind.deservesRetry {
            return retryIntent(
                anchor: attempt.finishedAt ?? attempt.startedAt,
                failureKind: failure.kind,
                now: now,
                consecutiveFailures: consecutiveFailures
            )
        }

        return nonRetryableIntent(
            anchor: attempt.finishedAt ?? attempt.startedAt,
            configuration: configuration,
            now: now,
            reason: "le dernier échec (\(failure.kind.rawValue)) ne se répare pas tout seul"
        )
    }

    /// Un échec réessayable revient après un recul exponentiel borné — voir
    /// ``retryDelay(consecutiveFailures:)``. Sans ce recul, une ligne qui
    /// clignote produirait une tentative toutes les quelques secondes et
    /// noierait le journal exactement comme un mot de passe faux le ferait.
    private static func retryIntent(
        anchor: Date,
        failureKind: FailureKind,
        now: Date,
        consecutiveFailures: Int
    ) -> Intent {
        let delay = retryDelay(consecutiveFailures: consecutiveFailures)
        let nextRetry = anchor.addingTimeInterval(delay)
        guard now >= nextRetry else {
            return .wait(
                until: nextRetry,
                because: "échec réseau précédent : nouvel essai après un recul de \(Int(delay)) s"
            )
        }
        // `missedSchedule` décrit une échéance manquée faute de machine allumée,
        // donc un rattrapage ; les autres échecs réessayables (réseau,
        // interruption déjà traitée plus haut) redémarrent comme un retour de
        // réseau.
        let trigger: BackupTrigger = failureKind == .missedSchedule ? .catchUp : .networkReturned
        return .run(trigger, dueSince: nextRetry)
    }

    /// Un échec qui ne se répare pas tout seul (mot de passe, dépôt corrompu,
    /// disque plein…) ne se rejoue pas en boucle : on retombe sur la cadence
    /// normale plutôt que sur un recul court fait pour le réseau.
    private static func nonRetryableIntent(
        anchor: Date,
        configuration: BackupConfiguration,
        now: Date,
        reason: String
    ) -> Intent {
        let until = anchor.addingTimeInterval(configuration.intervalHours * 3600)
        guard now >= until else {
            return .wait(until: until, because: "\(reason) ; nouvelle tentative à l'échéance normale, pas en boucle")
        }
        return .run(.catchUp, dueSince: until)
    }

    /// La règle de rattrapage pure : compare `now` à `lastSuccess`, jamais un
    /// minuteur. Couvre aussi bien « en retard de six heures » que « le Mac
    /// était éteint une semaine ».
    private static func scheduleIntent(
        now: Date,
        lastSuccess: Date?,
        configuration: BackupConfiguration
    ) -> Intent {
        guard let lastSuccess else {
            // Aucun succès de toute l'histoire : c'est l'état de ce Mac
            // aujourd'hui, 143 Go d'orphelins et zéro snapshot. Ce n'est pas
            // « on vient de commencer », c'est urgent.
            return .run(.catchUp, dueSince: now)
        }

        let elapsed = now.timeIntervalSince(lastSuccess)
        let intervalSeconds = configuration.intervalHours * 3600

        // Une horloge qui recule (réveil, resynchronisation NTP) rend `elapsed`
        // négatif. Un petit recul est une dérive normale — on le plie à zéro
        // sans y voir une avance, voir plus bas. Un grand recul est une
        // horloge suspecte, et là un `.wait` calculé depuis `now` ne suffit
        // pas à éviter le gel : tant que `lastSuccess` reste daté dans un
        // futur lointain et que rien d'autre ne le corrige, chaque appel
        // suivant retomberait dans cette même branche, pour une durée réelle
        // égale à l'ampleur de la corruption — potentiellement des mois. La
        // seule sortie qui garantit une résolution immédiate est de ne plus
        // faire confiance du tout à ce `lastSuccess` : on le traite comme
        // s'il n'existait pas, et on sauvegarde, comme pour « aucun succès
        // dans l'histoire ». Le coût d'un rattrapage inutile sur une dérive
        // mineure est borné par la déduplication ; le coût de l'attendre pour
        // de vrai ne l'est pas.
        if elapsed < -clockSkewTolerance {
            return .run(.catchUp, dueSince: now)
        }
        let boundedElapsed = max(0, elapsed)

        guard boundedElapsed >= intervalSeconds else {
            let until = lastSuccess.addingTimeInterval(intervalSeconds)
            return .wait(until: until, because: "prochaine sauvegarde à l'échéance normale")
        }

        let overdueBy = boundedElapsed - intervalSeconds
        // En deçà d'une heure de retard, l'échéance est probablement arrivée
        // pendant que la machine tournait — c'est `.scheduled`. Au-delà, elle a
        // été manquée : la machine était éteinte ou en veille, c'est
        // `.catchUp`, et c'est le cas courant, pas l'exception.
        let trigger: BackupTrigger = overdueBy > catchUpGraceSeconds ? .catchUp : .scheduled
        return .run(trigger, dueSince: lastSuccess.addingTimeInterval(intervalSeconds))
    }

    // MARK: - La batterie

    /// N'applique la politique batterie qu'au moment où on s'apprête
    /// réellement à lancer un run — jamais pendant l'attente normale, qui n'a
    /// rien à voir avec l'alimentation.
    private static func gateOnBattery(
        trigger: BackupTrigger,
        dueSince: Date,
        now: Date,
        configuration: BackupConfiguration,
        isOnBattery: Bool,
        batteryFraction: Double?
    ) -> ScheduleDecision {
        guard isOnBattery else { return .backUpNow(trigger) }

        switch configuration.onBatteryPolicy {
        case .always:
            return .backUpNow(trigger)

        case let .waitForPower(forceAfterHours):
            let forceAt = dueSince.addingTimeInterval(forceAfterHours * 3600)
            if now >= forceAt {
                // Le report a une borne, et elle est franchie : on sauvegarde
                // sur batterie. Un report sans borne **est** l'absence de
                // sauvegarde — la panne dont ce projet est né.
                return .backUpNow(trigger)
            }
            let level = batteryFraction.map { " (batterie à \(Int(($0 * 100).rounded()))\u{202F}%)" } ?? ""
            return .waitForPower(
                forceAt: forceAt,
                because: "sur batterie\(level) ; en attente du secteur, sauvegarde forcée à la date indiquée si elle ne vient pas avant"
            )
        }
    }

    // MARK: - Le recul exponentiel

    /// Le délai avant un nouvel essai après `consecutiveFailures` échecs
    /// réessayables d'affilée. Fonction pure, testée pour elle-même : c'est
    /// elle qui empêche un réseau qui clignote de noyer le journal, sans
    /// jamais faire attendre plus que `retryMaxDelay`.
    static func retryDelay(consecutiveFailures: Int) -> TimeInterval {
        guard consecutiveFailures > 0 else { return retryBaseDelay }
        // Borné à 20 pour ne jamais approcher l'overflow de `pow` — le
        // plafond `retryMaxDelay` est de toute façon atteint bien avant.
        let exponent = Double(min(consecutiveFailures - 1, 20))
        return min(retryBaseDelay * pow(2, exponent), retryMaxDelay)
    }

    // MARK: - La configuration

    private static func configurationProblem(_ configuration: BackupConfiguration) -> String? {
        guard configuration.isEnabled else {
            return "la sauvegarde n'est pas activée"
        }
        if configuration.sourcePaths.isEmpty {
            return "aucun dossier source n'est configuré"
        }
        if configuration.s3Endpoint.isEmpty || configuration.s3Bucket.isEmpty
            || configuration.s3AccessKeyID.isEmpty {
            return "les informations du dépôt S3 sont incomplètes"
        }
        if configuration.tailscaleMinioNodeName.isEmpty || configuration.minioTailscaleIP.isEmpty {
            return "le nœud Tailscale du serveur de sauvegarde n'est pas renseigné"
        }
        return nil
    }

    // MARK: - Les constantes

    /// Au-delà, un écart négatif entre `now` et `lastSuccess` n'est plus une
    /// dérive NTP ordinaire — voir ``scheduleIntent(now:lastSuccess:configuration:)``.
    private static let clockSkewTolerance: TimeInterval = 5 * 60
    /// Le partage entre « l'échéance est arrivée en cours de route » et
    /// « elle a été manquée ». Voir ``scheduleIntent(now:lastSuccess:configuration:)``.
    private static let catchUpGraceSeconds: TimeInterval = 3600
    private static let retryBaseDelay: TimeInterval = 60
    private static let retryMaxDelay: TimeInterval = 6 * 3600
}
