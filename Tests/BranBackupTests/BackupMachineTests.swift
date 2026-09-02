import Foundation
import Testing
@testable import BranBackup

/// **Les manières dont une machine à états pourrait afficher « sauvegardé »
/// à tort**, et la preuve qu'elle ne les prend pas.
///
/// Chaque cas de ce fichier reproduit un chemin par lequel `createReturned`,
/// `repositoryConfirmed` ou une transition hors d'ordre pourrait faire
/// franchir `.success` sans preuve méritée. Les identifiants et volumes
/// réutilisés ici viennent des sorties réelles de kopia 0.23.1 relevées le
/// 02/09/2026 (`snapshot create` / `snapshot list`) ; le reste — hôte,
/// utilisateur, chemin — est fictif.
@Suite("La machine à états de la sauvegarde")
struct BackupMachineTests {

    // MARK: - Constructeurs

    private func proof(
        id: String = "8145671624282e64839f6e3a98678616",
        rootObjectID: String = "k348b268a5c35490f1cbaae28a7eb5588",
        errorCount: Int = 0,
        ignoredErrorCount: Int = 0,
        origin: ProofOrigin
    ) -> SnapshotProof {
        SnapshotProof(
            id: id,
            rootObjectID: rootObjectID,
            sourcePath: "/Users/exemple/Documents",
            sourceHost: "mac-de-test",
            sourceUser: "exemple",
            startTime: Date(timeIntervalSince1970: 1_788_000_000),
            endTime: Date(timeIntervalSince1970: 1_788_000_100),
            totalSize: 3_000_064,
            fileCount: 3,
            dirCount: 2,
            errorCount: errorCount,
            ignoredErrorCount: ignoredErrorCount,
            origin: origin
        )
    }

    private func greenVerdict() -> ChainVerdict {
        ChainVerdict(results: [], firstFailure: nil, headline: "Tout est vert.", canBackUp: true)
    }

    private func redVerdict(on link: ChainLink, rawDetail: String = "détail brut de la sonde") -> ChainVerdict {
        let result = LinkProbeResult(
            link: link, state: .down, diagnostic: "en panne", rawDetail: rawDetail, measuredAt: .now
        )
        return ChainVerdict(
            results: [result], firstFailure: link, headline: "\(link) est en panne.", canBackUp: false
        )
    }

    /// Une machine amenée jusqu'à `.running`, prête pour `createReturned`.
    private func runningMachine() -> BackupMachine {
        var machine = BackupMachine()
        machine.chainCheckStarted()
        machine.chainEvaluated(greenVerdict())
        machine.runStarted()
        return machine
    }

    // MARK: - Le cœur du fichier : create ne prouve rien

    @Test("createReturned ne mène jamais à .success, même sur une preuve parfaite")
    func createReturnedNeverSucceeds() {
        var machine = runningMachine()
        machine.createReturned(proof(errorCount: 0, ignoredErrorCount: 0, origin: .reportedByCreate))

        #expect(machine.phase == .verifying)
        #expect(machine.canDisplaySaved == false)
        if case .success = machine.phase {
            Issue.record("createReturned a fait passer la machine en .success")
        }
    }

    @Test("Le chemin complet légitime mène à .success, et seulement lui")
    func legitimatePathReachesSuccess() {
        var machine = runningMachine()
        machine.progressed(BackupProgress(hashingFiles: 2, hashedFiles: 1, hashedBytes: 500_000))

        let created = proof(errorCount: 0, ignoredErrorCount: 0, origin: .reportedByCreate)
        machine.createReturned(created)
        #expect(machine.phase == .verifying)

        let confirmed = proof(errorCount: 0, ignoredErrorCount: 0, origin: .confirmedInRepository)
        machine.repositoryConfirmed([confirmed])

        #expect(machine.phase == .success(confirmed))
        #expect(machine.canDisplaySaved)
    }

    @Test("L'identifiant créé absent de la liste relue donne un échec explicite, pas un succès optimiste")
    func missingIDIsAnExplicitFailure() {
        var machine = runningMachine()
        machine.createReturned(proof(id: "8145671624282e64839f6e3a98678616", origin: .reportedByCreate))

        // Le dépôt ne rend que d'autres snapshots — un id qui ne correspond
        // à rien de ce que `create` a annoncé.
        machine.repositoryConfirmed([proof(id: "3bc941641015a70b0b1835f3b7e2b9da", origin: .confirmedInRepository)])

        guard case .failed(let failure) = machine.phase else {
            Issue.record("attendu .failed, obtenu \(machine.phase)")
            return
        }
        #expect(failure.kind == .unparseable)
        #expect(failure.summary.contains("ne contient pas le snapshot"))
        #expect(machine.canDisplaySaved == false)
    }

    @Test("errorCount > 0 confirmé donne quand même un échec partiel")
    func confirmedErrorCountStillFails() {
        var machine = runningMachine()
        machine.createReturned(proof(errorCount: 0, origin: .reportedByCreate))
        machine.repositoryConfirmed([proof(errorCount: 3, ignoredErrorCount: 0, origin: .confirmedInRepository)])

        guard case .failed(let failure) = machine.phase else {
            Issue.record("attendu .failed, obtenu \(machine.phase)")
            return
        }
        #expect(failure.kind == .partialSnapshot)
        #expect(failure.summary.contains("3"))
        #expect(machine.canDisplaySaved == false)
    }

    @Test("ignoredErrorCount seul, confirmé et sans errorCount, refuse aussi .success")
    func confirmedIgnoredErrorCountStillFails() {
        // Le faux vert que le champ existe pour fermer : un fichier verrouillé
        // n'incrémente que `ignoredErrorCount`, kopia sort avec le code 0, et
        // un contrôle qui ne lirait que `errorCount` verrait un vert faux.
        var machine = runningMachine()
        machine.createReturned(proof(errorCount: 0, ignoredErrorCount: 0, origin: .reportedByCreate))
        machine.repositoryConfirmed([
            proof(errorCount: 0, ignoredErrorCount: 340, origin: .confirmedInRepository),
        ])

        guard case .failed(let failure) = machine.phase else {
            Issue.record("attendu .failed, obtenu \(machine.phase)")
            return
        }
        #expect(failure.kind == .partialSnapshot)
        // Les deux causes sont distinguées, pas fondues en un seul nombre.
        #expect(failure.summary.contains("340"))
        #expect(failure.summary.contains("ignoré"))
        #expect(machine.canDisplaySaved == false)
    }

    @Test("Les deux compteurs cumulés se distinguent dans le message, pas seulement dans le total")
    func bothCountersAreNamedSeparately() {
        var machine = runningMachine()
        machine.createReturned(proof(origin: .reportedByCreate))
        machine.repositoryConfirmed([
            proof(errorCount: 12, ignoredErrorCount: 340, origin: .confirmedInRepository),
        ])

        guard case .failed(let failure) = machine.phase else {
            Issue.record("attendu .failed, obtenu \(machine.phase)")
            return
        }
        #expect(failure.summary.contains("12"))
        #expect(failure.summary.contains("illisible"))
        #expect(failure.summary.contains("340"))
        #expect(failure.summary.contains("ignoré"))
        // Le total des deux causes, cité explicitement.
        #expect(failure.summary.contains("352"))
    }

    @Test("Une preuve .reportedByCreate glissée directement en confirmation est refusée")
    func reportedByCreateSlippedIntoConfirmationIsRejected() {
        var machine = runningMachine()
        let created = proof(errorCount: 0, ignoredErrorCount: 0, origin: .reportedByCreate)
        machine.createReturned(created)

        // Un appelant qui, par erreur, repasse la preuve de `create` telle
        // quelle au lieu du résultat d'une vraie relecture du dépôt.
        machine.repositoryConfirmed([created])

        guard case .failed(let failure) = machine.phase else {
            Issue.record("attendu .failed, obtenu \(machine.phase)")
            return
        }
        #expect(failure.kind == .unparseable)
        #expect(machine.canDisplaySaved == false)
        if case .success = machine.phase {
            Issue.record("une preuve .reportedByCreate a été acceptée comme confirmation")
        }
    }

    // MARK: - Transitions impossibles

    @Test("Une progression reçue hors d'un run n'invente pas de run et ne plante pas")
    func progressedOutsideARunIsIgnored() {
        var machine = BackupMachine()
        machine.progressed(BackupProgress(hashingFiles: 1))
        #expect(machine.phase == .idle)
    }

    @Test("runStarted sans chaîne vérifiée est ignoré")
    func runStartedWithoutAVerifiedChainIsIgnored() {
        var machine = BackupMachine()
        machine.runStarted()
        #expect(machine.phase == .idle)
    }

    @Test("createReturned hors d'un run est ignoré")
    func createReturnedOutsideARunIsIgnored() {
        var machine = BackupMachine()
        machine.createReturned(proof(origin: .reportedByCreate))
        #expect(machine.phase == .idle)
    }

    @Test("repositoryConfirmed sans createReturned préalable est ignoré")
    func repositoryConfirmedWithoutAPendingProofIsIgnored() {
        var machine = runningMachine()
        // On saute directement de .running à repositoryConfirmed, sans passer
        // par createReturned : il n'y a rien à confirmer.
        machine.repositoryConfirmed([proof(origin: .confirmedInRepository)])
        #expect(machine.phase == .running(BackupProgress()))
    }

    @Test("failed hors de toute tentative est ignoré")
    func failedOutsideAnAttemptIsIgnored() {
        var machine = BackupMachine()
        machine.failed(BackupFailure(kind: .storage, summary: "disque plein", rawOutput: ""))
        #expect(machine.phase == .idle)
    }

    @Test("Démarrer une vérification de chaîne pendant un run en cours est ignoré")
    func chainCheckStartedWhileBusyIsIgnored() {
        var machine = runningMachine()
        machine.chainCheckStarted()
        #expect(machine.phase == .running(BackupProgress()))
    }

    // MARK: - Annulation

    @Test("L'annulation donne .interrupted, jamais .failed")
    func cancellationIsInterruptedNotFailed() {
        var machine = runningMachine()
        machine.cancelled()

        guard case .interrupted(let failure) = machine.phase else {
            Issue.record("attendu .interrupted, obtenu \(machine.phase)")
            return
        }
        #expect(failure.kind == .interrupted)
        #expect(failure.kind.deservesRetry)
        if case .failed = machine.phase {
            Issue.record("l'annulation a produit .failed")
        }
        #expect(machine.canDisplaySaved == false)
    }

    @Test("cancelled() hors de toute tentative est ignoré")
    func cancelledOutsideAnAttemptIsIgnored() {
        var machine = BackupMachine()
        machine.cancelled()
        #expect(machine.phase == .idle)
    }

    // MARK: - La chaîne réseau

    @Test("Un maillon réseau rouge attend, il n'échoue pas")
    func networkLinkDownWaits() {
        var machine = BackupMachine()
        machine.chainCheckStarted()
        machine.chainEvaluated(redVerdict(on: .s3Reachable))

        guard case .waitingForNetwork = machine.phase else {
            Issue.record("attendu .waitingForNetwork, obtenu \(machine.phase)")
            return
        }
    }

    @Test("Le dépôt qui ne s'ouvre pas est un échec, pas une attente")
    func repositoryOpenFailureIsAFailureNotAWait() {
        var machine = BackupMachine()
        machine.chainCheckStarted()
        machine.chainEvaluated(redVerdict(on: .repositoryOpens, rawDetail: "invalid repository password"))

        guard case .failed(let failure) = machine.phase else {
            Issue.record("attendu .failed, obtenu \(machine.phase)")
            return
        }
        #expect(failure.kind == .repository)
        #expect(failure.rawOutput.contains("invalid repository password"))
    }

    // MARK: - La propriété qui protège l'écran

    @Test("canDisplaySaved est faux dans toutes les phases qui ne sont pas un succès prouvé")
    func canDisplaySavedIsFalseEverywhereButATrustworthySuccess() {
        #expect(BackupMachine(phase: .idle).canDisplaySaved == false)
        #expect(BackupMachine(phase: .checkingChain).canDisplaySaved == false)
        #expect(BackupMachine(phase: .running(BackupProgress())).canDisplaySaved == false)
        #expect(BackupMachine(phase: .verifying).canDisplaySaved == false)
        #expect(BackupMachine(phase: .failed(
            BackupFailure(kind: .storage, summary: "x", rawOutput: "")
        )).canDisplaySaved == false)
        #expect(BackupMachine(phase: .waitingForNetwork(greenVerdict())).canDisplaySaved == false)
        #expect(BackupMachine(phase: .interrupted(
            BackupFailure(kind: .interrupted, summary: "x", rawOutput: "")
        )).canDisplaySaved == false)
    }

    @Test("canDisplaySaved revérifie la preuve elle-même, pas seulement la forme de .success")
    func canDisplaySavedRevalidatesTheProofNotJustTheCase() {
        // Une phase .success construite à la main, en contournant toutes les
        // transitions de ce fichier — exactement ce que `init(phase:)` public
        // permet, et exactement pourquoi `canDisplaySaved` ne se contente pas
        // de vérifier que la phase est un .success.
        let untrustworthy = proof(errorCount: 0, ignoredErrorCount: 1, origin: .reportedByCreate)
        #expect(BackupMachine(phase: .success(untrustworthy)).canDisplaySaved == false)

        let trustworthy = proof(errorCount: 0, ignoredErrorCount: 0, origin: .confirmedInRepository)
        #expect(BackupMachine(phase: .success(trustworthy)).canDisplaySaved)
    }
}
