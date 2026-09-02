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
}
