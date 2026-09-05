import Foundation
import Testing
@testable import BranBackup

@Suite("Le contrat tient debout")
struct ContractSmokeTests {
    @Test("Une preuve rendue par create ne vaut pas preuve")
    func createAloneIsNotProof() {
        let proof = SnapshotProof(
            id: "a", rootObjectID: "k1", sourcePath: "/x", sourceHost: "h",
            sourceUser: "u", startTime: .now, endTime: .now, totalSize: 1,
            fileCount: 1, dirCount: 1, errorCount: 0, ignoredErrorCount: 0,
            origin: .reportedByCreate)
        #expect(proof.isComplete)
        #expect(!proof.isTrustworthy)
    }

    @Test("L'état partagé restitue la progression du processus automatique")
    func runtimeStatusMapsToRunningPhase() throws {
        let progress = BackupProgress(
            hashingFiles: 3, hashedFiles: 42, hashedBytes: 8_000,
            cachedBytes: 6_000, uploadedBytes: 2_000,
            estimatedBytes: 10_000, secondsRemaining: 12)
        let status = BackupRuntimeStatus(
            attemptID: UUID(), trigger: .catchUp,
            startedAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 110),
            stage: .running, progress: progress)

        let decoded = try JSONDecoder().decode(
            BackupRuntimeStatus.self,
            from: JSONEncoder().encode(status))

        #expect(decoded == status)
        #expect(decoded.phase == .running(progress))
    }

    @Test("La confirmation publiée ne réutilise pas une fausse progression")
    func runtimeStatusMapsToVerifyingPhase() {
        let status = BackupRuntimeStatus(
            attemptID: UUID(), trigger: .scheduled,
            startedAt: .now, updatedAt: .now, stage: .verifying,
            progress: BackupProgress(uploadedBytes: 123))

        #expect(status.phase == .verifying)
    }
}
