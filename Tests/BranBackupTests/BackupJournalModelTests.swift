import Foundation
import Testing
@testable import BranBackup

/// **Les manières dont un journal pourrait mentir sur son histoire**, et la
/// preuve qu'il ne le fait pas.
///
/// Le cas central de ce fichier n'est pas un cas limite : un journal en ajout
/// pur, écrit par deux processus qui ne se coordonnent jamais, a sa dernière
/// ligne tronquée chaque fois que la machine s'éteint en écrivant, et ses
/// lignes dans le désordre chaque fois que l'application et le job
/// `launchd` écrivent à quelques millisecondes d'écart. Ce fichier vérifie
/// que ni l'un ni l'autre ne fait disparaître ou mal classer une tentative.
@Suite("Le journal des tentatives")
struct BackupJournalModelTests {

    // MARK: - Constructeurs

    private func proof(
        id: String = "8145671624282e64839f6e3a98678616",
        errorCount: Int = 0,
        ignoredErrorCount: Int = 0,
        origin: ProofOrigin
    ) -> SnapshotProof {
        SnapshotProof(
            id: id,
            rootObjectID: "k348b268a5c35490f1cbaae28a7eb5588",
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

    private func attempt(
        id: UUID = UUID(),
        startedAt: Date,
        finishedAt: Date?,
        trigger: BackupTrigger = .manual,
        proof: SnapshotProof? = nil,
        failure: BackupFailure? = nil,
        uploadedBytes: Int64? = nil
    ) -> BackupAttempt {
        BackupAttempt(
            id: id, startedAt: startedAt, finishedAt: finishedAt, trigger: trigger,
            proof: proof, failure: failure, uploadedBytes: uploadedBytes
        )
    }

    // MARK: - Encodage et décodage

    @Test("Un aller-retour encode/décode ne perd rien")
    func roundTrip() throws {
        let original = attempt(
            startedAt: Date(timeIntervalSince1970: 1_788_000_000),
            finishedAt: Date(timeIntervalSince1970: 1_788_000_120),
            trigger: .scheduled,
            proof: proof(errorCount: 0, ignoredErrorCount: 0, origin: .confirmedInRepository),
            uploadedBytes: 240_000_000
        )
        let line = try BackupJournalModel.encode(original)
        // Le format entier repose sur « une ligne = une tentative ».
        #expect(!line.contains("\n"))
        #expect(try BackupJournalModel.decode(line: line) == original)
    }

    @Test("Un échec se relit aussi bien qu'un succès")
    func roundTripFailure() throws {
        let original = attempt(
            startedAt: .now,
            finishedAt: .now,
            failure: BackupFailure(
                kind: .partialSnapshot,
                summary: "Le snapshot existe mais 3 fichiers manquent : 3 fichiers illisibles.",
                rawOutput: "id x, errorCount 3, ignoredErrorCount 0, fileCount 12"
            )
        )
        let line = try BackupJournalModel.encode(original)
        #expect(try BackupJournalModel.decode(line: line) == original)
    }

    // MARK: - Un fichier abîmé

    @Test("Un fichier vide ne rend ni tentative ni ligne corrompue")
    func emptyFile() {
        let (attempts, corrupted) = BackupJournalModel.parse("")
        #expect(attempts.isEmpty)
        #expect(corrupted.isEmpty)
    }

    @Test("Une dernière ligne tronquée laisse les précédentes lisibles")
    func truncatedLastLine() throws {
        let first = attempt(startedAt: Date(timeIntervalSince1970: 1_788_000_000), finishedAt: .now)
        let second = attempt(startedAt: Date(timeIntervalSince1970: 1_788_001_000), finishedAt: .now)
        let firstLine = try BackupJournalModel.encode(first)
        let secondLine = try BackupJournalModel.encode(second)
        let thirdLine = try BackupJournalModel.encode(
            attempt(startedAt: Date(timeIntervalSince1970: 1_788_002_000), finishedAt: .now)
        )
        // La machine s'éteint au milieu de l'écriture de la troisième ligne :
        // pas de saut de ligne final, et le JSON coupé en plein milieu.
        let truncated = String(thirdLine.prefix(thirdLine.count / 2))
        let contents = [firstLine, secondLine, truncated].joined(separator: "\n")

        let (attempts, corrupted) = BackupJournalModel.parse(contents)
        #expect(attempts.count == 2)
        #expect(Set(attempts.map(\.id)) == Set([first.id, second.id]))
        #expect(corrupted.count == 1)
        #expect(corrupted.first == truncated)
    }

    @Test("Une ligne corrompue au milieu du fichier n'emporte ni celle d'avant ni celle d'après")
    func corruptedMiddleLine() throws {
        let first = attempt(startedAt: Date(timeIntervalSince1970: 1_788_000_000), finishedAt: .now)
        let third = attempt(startedAt: Date(timeIntervalSince1970: 1_788_002_000), finishedAt: .now)
        let garbage = "{ceci n'est pas du JSON valide"
        let contents = [
            try BackupJournalModel.encode(first),
            garbage,
            try BackupJournalModel.encode(third),
        ].joined(separator: "\n")

        let (attempts, corrupted) = BackupJournalModel.parse(contents)
        #expect(attempts.map(\.id) == [first.id, third.id])
        #expect(corrupted == [garbage])
    }

    // MARK: - Une ligne de version inconnue

    @Test("Une ligne écrite par un format futur se relit quand même")
    func futureFormatVersionStillDecodes() throws {
        let original = attempt(startedAt: .now, finishedAt: .now, uploadedBytes: 42)
        let encoded = try BackupJournalModel.encode(original)

        // Simule ce qu'une version future du format pourrait écrire : un
        // numéro de version supérieur et un champ que cette version-ci ne
        // connaît pas, glissé au même niveau que `formatVersion`.
        #expect(encoded.contains("\"formatVersion\":1"))
        let mutated = encoded.replacingOccurrences(
            of: "\"formatVersion\":1",
            with: "\"formatVersion\":2,\"champInconnuDUneVersionFuture\":true"
        )

        let decoded = try BackupJournalModel.decode(line: mutated)
        #expect(decoded == original)
    }

    // MARK: - lastSuccess

    @Test("lastSuccess ignore une tentative dont la preuve n'est que .reportedByCreate")
    func lastSuccessIgnoresUnconfirmedProof() {
        let onlyReported = attempt(
            startedAt: .now, finishedAt: .now,
            proof: proof(origin: .reportedByCreate)
        )
        #expect(onlyReported.succeeded == false)
        #expect(BackupJournalModel.lastSuccess(in: [onlyReported]) == nil)
    }

    @Test("lastSuccess trouve la bonne tentative même mêlée à des échecs et un rapport non confirmé")
    func lastSuccessFindsTheRealOne() {
        let failed = attempt(
            startedAt: Date(timeIntervalSince1970: 1_788_000_000), finishedAt: .now,
            failure: BackupFailure(kind: .network, summary: "x", rawOutput: "")
        )
        let reportedOnly = attempt(
            startedAt: Date(timeIntervalSince1970: 1_788_001_000), finishedAt: .now,
            proof: proof(origin: .reportedByCreate)
        )
        let real = attempt(
            startedAt: Date(timeIntervalSince1970: 1_788_002_000), finishedAt: .now,
            proof: proof(origin: .confirmedInRepository)
        )
        let success = BackupJournalModel.lastSuccess(in: [failed, reportedOnly, real])
        #expect(success?.id == real.id)
    }

    // MARK: - L'ordre n'est pas celui du fichier

    @Test("Les lignes dans le désordre n'inversent pas ce qui est le plus récent")
    func outOfOrderLinesStillSortCorrectly() {
        let older = attempt(
            startedAt: Date(timeIntervalSince1970: 1_788_000_000),
            finishedAt: Date(timeIntervalSince1970: 1_788_000_050)
        )
        let newer = attempt(
            startedAt: Date(timeIntervalSince1970: 1_788_005_000),
            finishedAt: Date(timeIntervalSince1970: 1_788_005_050)
        )
        // `newer` est écrite en premier dans le tableau — exactement ce qui
        // arriverait si le job `launchd` avait fini d'écrire avant que
        // l'application, lancée plus tôt, ait fini d'écrire la sienne.
        let attempts = [newer, older]

        #expect(BackupJournalModel.lastAttempt(in: attempts)?.id == newer.id)
        #expect(BackupJournalModel.history(in: attempts, limit: 2).map(\.id) == [newer.id, older.id])
    }

    @Test("history respecte la limite et l'ordre du plus récent au plus ancien")
    func historyRespectsLimitAndOrder() {
        let a = attempt(startedAt: Date(timeIntervalSince1970: 1_788_000_000), finishedAt: .now.addingTimeInterval(-300))
        let b = attempt(startedAt: Date(timeIntervalSince1970: 1_788_001_000), finishedAt: .now.addingTimeInterval(-200))
        let c = attempt(startedAt: Date(timeIntervalSince1970: 1_788_002_000), finishedAt: .now.addingTimeInterval(-100))
        let history = BackupJournalModel.history(in: [b, a, c], limit: 2)
        #expect(history.map(\.id) == [c.id, b.id])
    }

    // MARK: - failures

    @Test("failures écarte les tentatives seulement interrompues")
    func failuresExcludeInterruptions() {
        let real = attempt(
            startedAt: .now, finishedAt: .now,
            failure: BackupFailure(kind: .storage, summary: "disque plein", rawOutput: "")
        )
        let interrupted = attempt(
            startedAt: .now, finishedAt: .now,
            failure: BackupFailure(kind: .interrupted, summary: "annulée", rawOutput: "")
        )
        let result = BackupJournalModel.failures(in: [real, interrupted], since: .distantPast)
        #expect(result.map(\.id) == [real.id])
    }

    // MARK: - Le delta d'octets

    @Test("Le delta d'octets se calcule entre deux tentatives, jamais en inventant un zéro")
    func newBytesDelta() {
        let previous = attempt(startedAt: .now, finishedAt: .now, uploadedBytes: 240_000_000)
        let current = attempt(startedAt: .now, finishedAt: .now, uploadedBytes: 245_600_000)

        #expect(BackupJournalModel.newBytes(between: current, and: previous) == 5_600_000)
        // Rien à comparer : pas de zéro qui prétendrait qu'il ne s'est rien passé.
        #expect(BackupJournalModel.newBytes(between: current, and: nil) == nil)

        let unmeasured = attempt(startedAt: .now, finishedAt: .now, uploadedBytes: nil)
        #expect(BackupJournalModel.newBytes(between: unmeasured, and: previous) == nil)
    }

    @Test("Un delta négatif reste affiché tel quel : c'est le signal que l'ordre est faux")
    func newBytesDeltaCanBeNegative() {
        let previous = attempt(startedAt: .now, finishedAt: .now, uploadedBytes: 300_000_000)
        let current = attempt(startedAt: .now, finishedAt: .now, uploadedBytes: 100_000_000)
        #expect(BackupJournalModel.newBytes(between: current, and: previous) == -200_000_000)
    }

    @Test("newBytesSinceLastAttempt retrouve la bonne paire même dans le désordre")
    func newBytesSinceLastAttemptFindsTheRightPair() {
        let older = attempt(
            startedAt: Date(timeIntervalSince1970: 1_788_000_000),
            finishedAt: Date(timeIntervalSince1970: 1_788_000_050),
            uploadedBytes: 240_000_000
        )
        let newer = attempt(
            startedAt: Date(timeIntervalSince1970: 1_788_005_000),
            finishedAt: Date(timeIntervalSince1970: 1_788_005_050),
            uploadedBytes: 3_000_000
        )
        // La reprise, dédup aidant, ne monte presque rien la deuxième fois —
        // c'est justement ce que ce delta doit rendre visible.
        let delta = BackupJournalModel.newBytesSinceLastAttempt(in: [newer, older])
        #expect(delta == 3_000_000 - 240_000_000)
    }
}

/// **Le compteur qui décide du recul, et pourquoi il ne compte pas tout.**
///
/// Il a existé en deux exemplaires pendant une heure — un dans la cible pure,
/// un dans le run headless — avec deux sémantiques différentes. Ce fichier fige
/// celle qui a été retenue, pour que la deuxième ne repousse pas.
@Suite("Le comptage des échecs enchaînés")
struct ConsecutiveFailureTests {

    private func attempt(
        _ minutesAgo: Int,
        failure: FailureKind?,
        succeeded: Bool = false
    ) -> BackupAttempt {
        let when = Date(timeIntervalSince1970: 1_000_000 - Double(minutesAgo) * 60)
        let proof = succeeded
            ? SnapshotProof(
                id: "s\(minutesAgo)", rootObjectID: "k\(minutesAgo)", sourcePath: "/x",
                sourceHost: "h", sourceUser: "u", startTime: when, endTime: when,
                totalSize: 1, fileCount: 1, dirCount: 1, errorCount: 0,
                ignoredErrorCount: 0, origin: .confirmedInRepository)
            : nil
        return BackupAttempt(
            id: UUID(), startedAt: when, finishedAt: when, trigger: .scheduled,
            proof: proof,
            failure: failure.map {
                BackupFailure(kind: $0, summary: "…", rawOutput: "…")
            })
    }

    @Test("Trois pannes réseau d'affilée comptent trois")
    func retryableFailuresAccumulate() {
        let attempts = [
            attempt(30, failure: .network),
            attempt(20, failure: .network),
            attempt(10, failure: .network),
        ]
        #expect(BackupJournalModel.consecutiveFailures(in: attempts) == 3)
    }

    @Test("Un mauvais mot de passe ne gonfle pas le recul : il n'est pas réessayable")
    func nonRetryableFailureDoesNotCount() {
        // Le recul exponentiel sert à laisser un serveur redémarrer. Une clé
        // fausse ne devient pas juste en attendant : la compter ferait grandir
        // l'attente pour une raison qui n'a rien à voir avec la patience.
        let attempts = [
            attempt(20, failure: .network),
            attempt(10, failure: .authentication),
        ]
        #expect(BackupJournalModel.consecutiveFailures(in: attempts) == 0)
    }

    @Test("Une réussite remet le compteur à zéro")
    func successResets() {
        let attempts = [
            attempt(30, failure: .network),
            attempt(20, failure: .network),
            attempt(10, failure: nil, succeeded: true),
        ]
        #expect(BackupJournalModel.consecutiveFailures(in: attempts) == 0)
    }

    @Test("Une tentative encore en cours rompt la série au lieu de la prolonger")
    func inFlightAttemptBreaksTheChain() {
        // Ni preuve ni échec : elle n'a rien démontré. La prolonger
        // supposerait un échec qui n'a pas eu lieu.
        let attempts = [
            attempt(30, failure: .network),
            attempt(20, failure: .network),
            BackupAttempt(
                id: UUID(), startedAt: Date(timeIntervalSince1970: 999_400),
                finishedAt: nil, trigger: .manual),
        ]
        #expect(BackupJournalModel.consecutiveFailures(in: attempts) == 0)
    }

    @Test("Un journal vide ne compte aucun échec")
    func emptyJournalCountsNothing() {
        #expect(BackupJournalModel.consecutiveFailures(in: []) == 0)
    }
}
