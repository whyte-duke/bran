import Foundation
import Testing
@testable import BranBackup

/// **Le piège numéro un de toute la fonctionnalité**, et la preuve qu'on ne le
/// prend pas.
///
/// Un minuteur dans l'application ne s'exécute que si l'application tourne :
/// « tous les deux jours » ne veut rien dire sur un Mac qu'on éteint le soir —
/// et ce dépôt-ci en porte la trace, 143 Go d'orphelins et zéro snapshot. La
/// décision doit donc se prendre sur l'horloge réelle (`now` contre
/// `lastSuccess`), jamais sur un compte à rebours. Chaque cas ici rejoue une
/// horloge entièrement simulée : rien n'attend, rien ne dépend de quand ce
/// test tourne réellement.
@Suite("Quand faut-il sauvegarder")
struct SchedulePolicyTests {

    // MARK: - Fabriques

    private func configuration(
        intervalHours: Double = 48,
        onBatteryPolicy: BatteryPolicy = .always,
        isEnabled: Bool = true,
        sourcePaths: [String] = ["/Users/quelquun/Documents"],
        s3Endpoint: String = "minio-backup.tailnet:9000",
        s3Bucket: String = "bran",
        s3AccessKeyID: String = "AKIA…",
        tailscaleMinioNodeName: String = "minio-backup",
        minioTailscaleIP: String = "100.64.0.1"
    ) -> BackupConfiguration {
        BackupConfiguration(
            s3Endpoint: s3Endpoint,
            s3Bucket: s3Bucket,
            s3Region: "us-east-1",
            disableTLS: true,
            s3AccessKeyID: s3AccessKeyID,
            sourcePaths: sourcePaths,
            ignoreRules: [],
            intervalHours: intervalHours,
            tailscaleMinioNodeName: tailscaleMinioNodeName,
            minioTailscaleIP: minioTailscaleIP,
            onBatteryPolicy: onBatteryPolicy,
            probeTimeout: 5,
            repositoryTimeout: 30,
            isEnabled: isEnabled
        )
    }

    /// Une chaîne où les six maillons sont verts.
    private func greenChain(now: Date) -> ChainVerdict {
        let results = ChainLink.allCases.map { link in
            LinkProbeResult(link: link, state: .up, diagnostic: "bon", measuredAt: now)
        }
        return ChainVerdict(results: results, firstFailure: nil, headline: "Tout est vert.", canBackUp: true)
    }

    /// Une chaîne rouge sur un seul maillon nommé, avec son diagnostic propre.
    private func redChain(failing link: ChainLink, diagnostic: String, now: Date) -> ChainVerdict {
        let results = ChainLink.allCases.map { candidate -> LinkProbeResult in
            if candidate == link {
                return LinkProbeResult(link: candidate, state: .down, diagnostic: diagnostic, measuredAt: now)
            }
            // Les maillons après le premier rouge ne sont que l'écho, non
            // sondés — `unknown` reflète ça, et ne compte pas pour vert.
            let state: LinkState = candidate < link ? .up : .unknown
            return LinkProbeResult(link: candidate, state: state, diagnostic: "bon", measuredAt: now)
        }
        return ChainVerdict(results: results, firstFailure: link, headline: diagnostic, canBackUp: false)
    }

    private func attempt(
        startedAt: Date,
        finishedAt: Date?,
        failure: BackupFailure? = nil,
        proof: SnapshotProof? = nil
    ) -> BackupAttempt {
        BackupAttempt(
            id: UUID(), startedAt: startedAt, finishedAt: finishedAt,
            trigger: .scheduled, proof: proof, failure: failure
        )
    }

    private func failure(_ kind: FailureKind, summary: String = "échec") -> BackupFailure {
        BackupFailure(kind: kind, summary: summary, rawOutput: "raw")
    }

    // MARK: - Aucun succès jamais

    @Test("Aucun succès dans toute l'histoire : on sauvegarde tout de suite, ce n'est pas un début tranquille")
    func neverSucceededBacksUpImmediately() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let decision = SchedulePolicy.decide(
            now: now, lastSuccess: nil, lastAttempt: nil,
            configuration: configuration(), chain: greenChain(now: now),
            isOnBattery: false, batteryFraction: nil, isRunning: false
        )
        guard case let .backUpNow(trigger) = decision else {
            Issue.record("attendu backUpNow, obtenu \(decision)")
            return
        }
        #expect(trigger == .catchUp)
    }

    // MARK: - Le rattrapage sur l'horloge

    @Test("Échéance dépassée d'une semaine — le Mac était éteint, le cas normal, pas l'exception")
    func overdueByAWeekCatchesUp() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        // 48 h d'intervalle, dernier succès il y a 7 jours + 48 h.
        let lastSuccess = now.addingTimeInterval(-(7 * 24 + 48) * 3600)
        let decision = SchedulePolicy.decide(
            now: now, lastSuccess: lastSuccess, lastAttempt: nil,
            configuration: configuration(intervalHours: 48), chain: greenChain(now: now),
            isOnBattery: false, batteryFraction: nil, isRunning: false
        )
        #expect(decision == .backUpNow(.catchUp))
    }

    @Test("Échéance non atteinte : on attend, et la date affichée est la bonne")
    func notYetDueWaitsUntilTheRightDate() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let lastSuccess = now.addingTimeInterval(-10 * 3600)
        let decision = SchedulePolicy.decide(
            now: now, lastSuccess: lastSuccess, lastAttempt: nil,
            configuration: configuration(intervalHours: 48), chain: greenChain(now: now),
            isOnBattery: false, batteryFraction: nil, isRunning: false
        )
        guard case let .wait(until, because) = decision else {
            Issue.record("attendu wait, obtenu \(decision)")
            return
        }
        #expect(until == lastSuccess.addingTimeInterval(48 * 3600))
        #expect(because.isEmpty == false)
    }

    // MARK: - Le verrou de simultanéité

    @Test("Un run en cours répond alreadyRunning, sans condition — même sur une config désactivée")
    func runningWinsOverEverything() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let decision = SchedulePolicy.decide(
            now: now, lastSuccess: nil, lastAttempt: nil,
            configuration: configuration(isEnabled: false), chain: nil,
            isOnBattery: false, batteryFraction: nil, isRunning: true
        )
        #expect(decision == .alreadyRunning)
    }

    // MARK: - La configuration

    @Test("Configuration désactivée : disabled, avec la raison")
    func disabledConfigurationIsNamed() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let decision = SchedulePolicy.decide(
            now: now, lastSuccess: nil, lastAttempt: nil,
            configuration: configuration(isEnabled: false), chain: nil,
            isOnBattery: false, batteryFraction: nil, isRunning: false
        )
        guard case let .disabled(reason) = decision else {
            Issue.record("attendu disabled, obtenu \(decision)")
            return
        }
        #expect(reason.isEmpty == false)
    }

    @Test("Configuration incomplète — aucune source — est aussi disabled, pas une chaîne à sonder")
    func incompleteConfigurationIsDisabled() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let decision = SchedulePolicy.decide(
            now: now, lastSuccess: nil, lastAttempt: nil,
            configuration: configuration(sourcePaths: []), chain: nil,
            isOnBattery: false, batteryFraction: nil, isRunning: false
        )
        guard case .disabled = decision else {
            Issue.record("attendu disabled, obtenu \(decision)")
            return
        }
    }

    // MARK: - La chaîne réseau

    @Test("Chaîne jamais sondée : on ne lance pas, mais on dit qu'on mesure d'abord")
    func unknownChainWaitsToMeasureFirst() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let decision = SchedulePolicy.decide(
            now: now, lastSuccess: nil, lastAttempt: nil,
            configuration: configuration(), chain: nil,
            isOnBattery: false, batteryFraction: nil, isRunning: false
        )
        guard case let .waitForNetwork(message) = decision else {
            Issue.record("attendu waitForNetwork, obtenu \(decision)")
            return
        }
        #expect(message.contains("sondée") || message.contains("mesure"))
    }

    @Test("Chaîne rouge : waitForNetwork porte le diagnostic du maillon fautif, jamais un échec")
    func redChainCarriesTheRightDiagnostic() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let chain = redChain(
            failing: .s3Reachable,
            diagnostic: "le port 9000 ne répond pas sur minio-backup",
            now: now
        )
        let decision = SchedulePolicy.decide(
            now: now, lastSuccess: now.addingTimeInterval(-100 * 3600), lastAttempt: nil,
            configuration: configuration(intervalHours: 48), chain: chain,
            isOnBattery: false, batteryFraction: nil, isRunning: false
        )
        guard case let .waitForNetwork(diagnostic) = decision else {
            Issue.record("attendu waitForNetwork, obtenu \(decision)")
            return
        }
        // C'est le diagnostic du maillon précis qui doit remonter, pas un texte
        // générique — sinon l'utilisateur ne sait toujours pas où ça casse.
        #expect(diagnostic == "le port 9000 ne répond pas sur minio-backup")
    }

    // MARK: - La batterie, où on ment le plus facilement

    @Test("Sur batterie : on diffère jusqu'au seuil, puis on force — un report sans borne est l'absence de sauvegarde")
    func batteryDefersThenForces() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let lastSuccess = now.addingTimeInterval(-60 * 3600) // dû depuis 12 h sur un intervalle de 48 h
        let config = configuration(intervalHours: 48, onBatteryPolicy: .waitForPower(forceAfterHours: 14))

        // Sous le seuil : on attend le secteur, avec une date de bascule lisible.
        let deferred = SchedulePolicy.decide(
            now: now, lastSuccess: lastSuccess, lastAttempt: nil,
            configuration: config, chain: greenChain(now: now),
            isOnBattery: true, batteryFraction: 0.4, isRunning: false
        )
        guard case let .waitForPower(forceAt, because) = deferred else {
            Issue.record("attendu waitForPower, obtenu \(deferred)")
            return
        }
        let dueSince = lastSuccess.addingTimeInterval(48 * 3600)
        #expect(forceAt == dueSince.addingTimeInterval(14 * 3600))
        #expect(because.isEmpty == false)

        // Juste avant le seuil : encore une attente.
        let stillWaiting = SchedulePolicy.decide(
            now: forceAt.addingTimeInterval(-1), lastSuccess: lastSuccess, lastAttempt: nil,
            configuration: config, chain: greenChain(now: now),
            isOnBattery: true, batteryFraction: 0.1, isRunning: false
        )
        guard case .waitForPower = stillWaiting else {
            Issue.record("attendu waitForPower juste avant le seuil, obtenu \(stillWaiting)")
            return
        }

        // Le seuil est franchi : on sauvegarde sur batterie, quel que soit le
        // niveau restant — la promesse ne dépend pas de ça.
        let forced = SchedulePolicy.decide(
            now: forceAt, lastSuccess: lastSuccess, lastAttempt: nil,
            configuration: config, chain: greenChain(now: now),
            isOnBattery: true, batteryFraction: 0.03, isRunning: false
        )
        guard case let .backUpNow(trigger) = forced else {
            Issue.record("attendu backUpNow au seuil, obtenu \(forced)")
            return
        }
        #expect(trigger == .catchUp)
    }

    @Test("Politique « toujours » : la batterie ne diffère jamais")
    func alwaysPolicyIgnoresBattery() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let lastSuccess = now.addingTimeInterval(-60 * 3600)
        let decision = SchedulePolicy.decide(
            now: now, lastSuccess: lastSuccess, lastAttempt: nil,
            configuration: configuration(intervalHours: 48, onBatteryPolicy: .always),
            chain: greenChain(now: now),
            isOnBattery: true, batteryFraction: 0.5, isRunning: false
        )
        #expect(decision == .backUpNow(.catchUp))
    }

    // MARK: - La reprise prime sur l'attente

    @Test("Run interrompu : reprise immédiate, sans attendre l'échéance suivante")
    func interruptedRunResumesImmediately() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        // Interrompu il y a une heure ; l'échéance de 48 h, elle, est loin
        // d'être là — la preuve que c'est bien la reprise qui décide.
        let interruptedAt = now.addingTimeInterval(-3600)
        let lastSuccess = now.addingTimeInterval(-2 * 3600)
        let cutRun = attempt(
            startedAt: interruptedAt.addingTimeInterval(-1800),
            finishedAt: interruptedAt,
            failure: failure(.interrupted, summary: "veille pendant le transfert")
        )
        let decision = SchedulePolicy.decide(
            now: now, lastSuccess: lastSuccess, lastAttempt: cutRun,
            configuration: configuration(intervalHours: 48), chain: greenChain(now: now),
            isOnBattery: false, batteryFraction: nil, isRunning: false
        )
        #expect(decision == .backUpNow(.resume))
    }

    @Test("Un run sans date de fin — coupé sans avoir pu se consigner — reprend aussi")
    func unfinishedAttemptAlsoResumes() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let lastSuccess = now.addingTimeInterval(-2 * 3600)
        let crashedRun = attempt(startedAt: now.addingTimeInterval(-1800), finishedAt: nil)
        let decision = SchedulePolicy.decide(
            now: now, lastSuccess: lastSuccess, lastAttempt: crashedRun,
            configuration: configuration(intervalHours: 48), chain: greenChain(now: now),
            isOnBattery: false, batteryFraction: nil, isRunning: false
        )
        #expect(decision == .backUpNow(.resume))
    }

    @Test("Un run interrompu avant le dernier succès n'est plus pertinent, il n'ouvre pas de reprise")
    func staleInterruptionDoesNotResume() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let oldCut = attempt(
            startedAt: now.addingTimeInterval(-1000 * 3600),
            finishedAt: now.addingTimeInterval(-999 * 3600),
            failure: failure(.interrupted)
        )
        // Un succès est arrivé après cette interruption : elle est couverte.
        let lastSuccess = now.addingTimeInterval(-10 * 3600)
        let decision = SchedulePolicy.decide(
            now: now, lastSuccess: lastSuccess, lastAttempt: oldCut,
            configuration: configuration(intervalHours: 48), chain: greenChain(now: now),
            isOnBattery: false, batteryFraction: nil, isRunning: false
        )
        guard case let .wait(until, _) = decision else {
            Issue.record("attendu wait, obtenu \(decision)")
            return
        }
        #expect(until == lastSuccess.addingTimeInterval(48 * 3600))
    }

    // MARK: - Un échec non réessayable ne boucle pas

    @Test("Mot de passe faux : on n'y retourne pas toutes les minutes")
    func nonRetryableFailureDoesNotLoop() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let badAuth = attempt(
            startedAt: now.addingTimeInterval(-120),
            finishedAt: now.addingTimeInterval(-60),
            failure: failure(.authentication, summary: "mot de passe de dépôt refusé")
        )
        let decision = SchedulePolicy.decide(
            now: now, lastSuccess: nil, lastAttempt: badAuth,
            configuration: configuration(intervalHours: 48), chain: greenChain(now: now),
            isOnBattery: false, batteryFraction: nil, isRunning: false
        )
        guard case let .wait(until, because) = decision else {
            Issue.record("attendu wait — pas de boucle —, obtenu \(decision)")
            return
        }
        // Le recul retombe sur la cadence normale, pas sur un recul de réseau
        // de quelques secondes : rien ne va réparer un mot de passe tout seul.
        #expect(until == badAuth.finishedAt!.addingTimeInterval(48 * 3600))
        #expect(because.isEmpty == false)
    }

    @Test("Passé l'échéance normale, un échec non réessayable finit tout de même par retenter")
    func nonRetryableFailureEventuallyRetries() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let badAuth = attempt(
            startedAt: now.addingTimeInterval(-50 * 3600),
            finishedAt: now.addingTimeInterval(-49 * 3600),
            failure: failure(.authentication)
        )
        let decision = SchedulePolicy.decide(
            now: now, lastSuccess: nil, lastAttempt: badAuth,
            configuration: configuration(intervalHours: 48), chain: greenChain(now: now),
            isOnBattery: false, batteryFraction: nil, isRunning: false
        )
        #expect(decision == .backUpNow(.catchUp))
    }

    // MARK: - Le recul exponentiel des échecs réessayables

    @Test("Recul exponentiel borné : il double, puis plafonne")
    func exponentialBackoffIsCappedAndTested() {
        #expect(SchedulePolicy.retryDelay(consecutiveFailures: 0) == 60)
        #expect(SchedulePolicy.retryDelay(consecutiveFailures: 1) == 60)
        #expect(SchedulePolicy.retryDelay(consecutiveFailures: 2) == 120)
        #expect(SchedulePolicy.retryDelay(consecutiveFailures: 3) == 240)
        #expect(SchedulePolicy.retryDelay(consecutiveFailures: 4) == 480)
        // Assez d'échecs pour que la formule brute dépasse largement le
        // plafond — c'est lui qui doit répondre, pas `pow`.
        #expect(SchedulePolicy.retryDelay(consecutiveFailures: 20) == 6 * 3600)
        #expect(SchedulePolicy.retryDelay(consecutiveFailures: 500) == 6 * 3600)
    }

    @Test("Un échec réseau attend son recul, puis repart en networkReturned une fois la chaîne verte")
    func networkFailureRetriesAfterBackoff() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let failedAt = now.addingTimeInterval(-30)
        let networkFail = attempt(
            startedAt: failedAt.addingTimeInterval(-10),
            finishedAt: failedAt,
            failure: failure(.network, summary: "Tailscale injoignable")
        )
        // Deuxième échec d'affilée : recul de 120 s, on n'y est pas encore à 30 s.
        let tooSoon = SchedulePolicy.decide(
            now: now, lastSuccess: nil, lastAttempt: networkFail,
            configuration: configuration(intervalHours: 48), chain: greenChain(now: now),
            isOnBattery: false, batteryFraction: nil, isRunning: false,
            consecutiveFailures: 2
        )
        guard case let .wait(until, _) = tooSoon else {
            Issue.record("attendu wait avant la fin du recul, obtenu \(tooSoon)")
            return
        }
        #expect(until == failedAt.addingTimeInterval(120))

        // Le recul est passé : nouvel essai, marqué comme un retour de réseau.
        let after = SchedulePolicy.decide(
            now: failedAt.addingTimeInterval(120), lastSuccess: nil, lastAttempt: networkFail,
            configuration: configuration(intervalHours: 48), chain: greenChain(now: now),
            isOnBattery: false, batteryFraction: nil, isRunning: false,
            consecutiveFailures: 2
        )
        #expect(after == .backUpNow(.networkReturned))
    }

    // MARK: - Le décalage de fuseau

    @Test("Un décalage de fuseau de 7 h — Indonésie contre France — ne change aucune décision")
    func timeZoneShiftChangesNothing() {
        // La fonction ne raisonne qu'en instants absolus (`Date`,
        // `TimeInterval`) : ni `Calendar` ni l'heure locale n'entrent dans le
        // calcul, donc traduire toute l'horloge de 7 h — `now` et
        // `lastSuccess` ensemble — doit rendre exactement la même décision,
        // à la même translation près sur les dates qu'elle porte.
        let sevenHours: TimeInterval = 7 * 3600
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let lastSuccess = base.addingTimeInterval(-10 * 3600)
        let config = configuration(intervalHours: 48)

        let here = SchedulePolicy.decide(
            now: base, lastSuccess: lastSuccess, lastAttempt: nil,
            configuration: config, chain: greenChain(now: base),
            isOnBattery: false, batteryFraction: nil, isRunning: false
        )
        let shifted = SchedulePolicy.decide(
            now: base.addingTimeInterval(sevenHours),
            lastSuccess: lastSuccess.addingTimeInterval(sevenHours),
            lastAttempt: nil,
            configuration: config, chain: greenChain(now: base.addingTimeInterval(sevenHours)),
            isOnBattery: false, batteryFraction: nil, isRunning: false
        )

        guard case let .wait(untilHere, becauseHere) = here,
              case let .wait(untilShifted, becauseShifted) = shifted else {
            Issue.record("attendu wait des deux côtés, obtenu \(here) et \(shifted)")
            return
        }
        #expect(becauseHere == becauseShifted)
        // La date affichée se translate avec l'horloge — ce n'est pas la même
        // date absolue, c'est la même distance à `now`.
        #expect(untilShifted == untilHere.addingTimeInterval(sevenHours))
    }

    @Test("Le même décalage, côté rattrapage : catchUp reste catchUp après translation")
    func timeZoneShiftPreservesCatchUp() {
        let sevenHours: TimeInterval = 7 * 3600
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let lastSuccess = base.addingTimeInterval(-(9 * 24) * 3600)
        let config = configuration(intervalHours: 48)

        let here = SchedulePolicy.decide(
            now: base, lastSuccess: lastSuccess, lastAttempt: nil,
            configuration: config, chain: greenChain(now: base),
            isOnBattery: false, batteryFraction: nil, isRunning: false
        )
        let shifted = SchedulePolicy.decide(
            now: base.addingTimeInterval(sevenHours),
            lastSuccess: lastSuccess.addingTimeInterval(sevenHours),
            lastAttempt: nil,
            configuration: config, chain: greenChain(now: base.addingTimeInterval(sevenHours)),
            isOnBattery: false, batteryFraction: nil, isRunning: false
        )
        #expect(here == .backUpNow(.catchUp))
        #expect(shifted == .backUpNow(.catchUp))
    }

    // MARK: - L'horloge qui recule

    @Test("Un petit recul (dérive NTP de deux minutes) reste dans la tolérance : échéance normale")
    func smallBackwardsClockIsTolerated() {
        let lastSuccess = Date(timeIntervalSince1970: 1_800_000_000)
        // L'horloge a reculé de deux minutes après le dernier succès.
        let now = lastSuccess.addingTimeInterval(-120)
        let decision = SchedulePolicy.decide(
            now: now, lastSuccess: lastSuccess, lastAttempt: nil,
            configuration: configuration(intervalHours: 48), chain: greenChain(now: now),
            isOnBattery: false, batteryFraction: nil, isRunning: false
        )
        guard case let .wait(until, _) = decision else {
            Issue.record("attendu wait, obtenu \(decision)")
            return
        }
        #expect(until == lastSuccess.addingTimeInterval(48 * 3600))
    }

    @Test("Une horloge qui recule franchement ne gèle pas la sauvegarde pour toujours")
    func largeBackwardsClockDoesNotFreezeForever() {
        // `lastSuccess` est daté un an dans le « futur » de `now` — le genre
        // d'incohérence qu'une resynchronisation ratée produit. Un calcul
        // naïf (`now - lastSuccess`) resterait négatif, donc « pas encore
        // l'heure », et ne proposerait jamais de sauvegarde : c'est le gel à
        // éviter. Attendre depuis `now` ne suffirait pas non plus — tant que
        // `lastSuccess` reste dans un futur lointain, chaque nouvel appel
        // retomberait dans le même cas, pour une durée réelle égale à
        // l'ampleur de la corruption. La seule sortie qui résout
        // immédiatement : ne plus faire confiance du tout à ce
        // `lastSuccess`, et sauvegarder, comme s'il n'y avait jamais eu de
        // succès.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let lastSuccess = now.addingTimeInterval(365 * 24 * 3600)
        let config = configuration(intervalHours: 48)
        let decision = SchedulePolicy.decide(
            now: now, lastSuccess: lastSuccess, lastAttempt: nil,
            configuration: config, chain: greenChain(now: now),
            isOnBattery: false, batteryFraction: nil, isRunning: false
        )
        #expect(decision == .backUpNow(.catchUp))
    }

    @Test("Une horloge à peine suspecte (six minutes) bascule déjà dans le même traitement que l'absence de succès")
    func justPastToleranceIsAlreadySuspicious() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let lastSuccess = now.addingTimeInterval(6 * 60)
        let decision = SchedulePolicy.decide(
            now: now, lastSuccess: lastSuccess, lastAttempt: nil,
            configuration: configuration(intervalHours: 48), chain: greenChain(now: now),
            isOnBattery: false, batteryFraction: nil, isRunning: false
        )
        #expect(decision == .backUpNow(.catchUp))
    }
}
