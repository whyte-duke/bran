import Foundation
import Testing
@testable import BranBackup

/// **Le mensonge d'un étage au-dessus de « le snapshot est prouvé ».**
///
/// Un `SnapshotProof` peut être parfaitement `isTrustworthy` — relu dans le
/// dépôt, sans fichier manquant — et pourtant ne rien dire du dossier que
/// l'utilisateur a demandé de sauvegarder. Le cas mesuré sur ce Mac le 02/09
/// : la configuration vise tout le dossier personnel, environ 600 Go, jamais
/// envoyés une seule fois ; le dépôt ne contient qu'un snapshot de
/// `~/Music`, 51 Mo, réussi et confirmé. Chaque test ci-dessous reproduit une
/// façon dont `SourceCoverageEvaluator` aurait pu confondre les deux — et la
/// preuve que non.
private let referenceNow = Date(timeIntervalSince1970: 1_788_000_000)
private let referenceStaleAfter: TimeInterval = 172_800 // 48 h

private func makeProof(
    path: String,
    host: String = "macbook-pro-de-whyte-2",
    user: String = "whyteduke",
    end: Date = referenceNow,
    origin: ProofOrigin = .confirmedInRepository,
    errorCount: Int = 0,
    ignoredErrorCount: Int = 0
) -> SnapshotProof {
    SnapshotProof(
        id: UUID().uuidString, rootObjectID: "k348b268a5c", sourcePath: path,
        sourceHost: host, sourceUser: user,
        startTime: end.addingTimeInterval(-60), endTime: end,
        totalSize: 1, fileCount: 1, dirCount: 1,
        errorCount: errorCount, ignoredErrorCount: ignoredErrorCount, origin: origin
    )
}

private func makeAttempt(
    proof: SnapshotProof? = nil,
    uploadedBytes: Int64? = nil
) -> BackupAttempt {
    BackupAttempt(
        id: UUID(), startedAt: referenceNow, finishedAt: referenceNow,
        trigger: .manual, proof: proof, uploadedBytes: uploadedBytes
    )
}

@Suite("La couverture d'une source")
struct SourceCoverageTests {

    // MARK: - Le cas vécu

    @Test("Le dossier personnel n'a jamais été envoyé : un snapshot de Music ne le couvre pas")
    func homeDirectoryNeverCovered() {
        // Exactement la configuration et l'unique snapshot réels du dépôt de
        // ce Mac au 02/09/2026.
        let musicProof = makeProof(path: "/Users/quelquun/Music")

        let report = SourceCoverageEvaluator.evaluate(
            sourcePaths: ["/Users/quelquun/"],
            proofs: [musicProof],
            expectedHost: musicProof.sourceHost,
            expectedUser: musicProof.sourceUser,
            now: referenceNow,
            staleAfter: referenceStaleAfter
        )

        #expect(report.verdict == .notCovered)
        #expect(report.coverages.first?.state == .neverBackedUp)
        #expect(report.coverages.first?.lastProof == nil)
        // La phrase doit dire la vérité, pas la présence d'un snapshot
        // quelconque.
        #expect(report.headline.contains("Aucune sauvegarde"))
        #expect(report.headline.contains("porte sur d'autres dossiers"))
    }

    // MARK: - La correspondance des chemins

    @Test("Un snapshot de l'ancêtre couvre le descendant demandé")
    func ancestorCoversDescendant() {
        let homeProof = makeProof(path: "/Users/quelquun")

        let report = SourceCoverageEvaluator.evaluate(
            sourcePaths: ["/Users/quelquun/Music"],
            proofs: [homeProof],
            expectedHost: homeProof.sourceHost, expectedUser: homeProof.sourceUser,
            now: referenceNow, staleAfter: referenceStaleAfter
        )

        #expect(report.verdict == .fullyCovered)
        guard let first = report.coverages.first else {
            Issue.record("attendu une couverture")
            return
        }
        guard case .covered(let at) = first.state else {
            Issue.record("attendu .covered, obtenu \(first.state)")
            return
        }
        #expect(at == homeProof.endTime)
    }

    @Test("Un snapshot du descendant ne couvre pas l'ancêtre — c'est le défaut vécu, à l'envers")
    func descendantDoesNotCoverAncestor() {
        let musicProof = makeProof(path: "/Users/quelquun/Music")

        let report = SourceCoverageEvaluator.evaluate(
            sourcePaths: ["/Users/quelquun"],
            proofs: [musicProof],
            expectedHost: musicProof.sourceHost, expectedUser: musicProof.sourceUser,
            now: referenceNow, staleAfter: referenceStaleAfter
        )

        #expect(report.verdict == .notCovered)
    }

    @Test("Le préfixe de chaîne ne trompe pas : /Users/xavier ne couvre pas /Users/x")
    func stringPrefixTrapAvoided() {
        // Si la comparaison se faisait par `hasPrefix` sur des chaînes brutes
        // plutôt que par composants, ce cas passerait à tort pour couvert.
        let xavierProof = makeProof(path: "/Users/xavier")

        let report = SourceCoverageEvaluator.evaluate(
            sourcePaths: ["/Users/x"],
            proofs: [xavierProof],
            expectedHost: xavierProof.sourceHost, expectedUser: xavierProof.sourceUser,
            now: referenceNow, staleAfter: referenceStaleAfter
        )

        #expect(report.verdict == .notCovered)
    }

    @Test("La barre oblique finale ne change pas le dossier : /Users/x/ et /Users/x sont le même")
    func trailingSlashIsIgnored() {
        // La configuration réelle de ce Mac porte `sourcePaths` avec la barre
        // finale — voir `config.json` — ce n'est pas une hypothèse d'école.
        let proofWithoutSlash = makeProof(path: "/Users/x")

        let report = SourceCoverageEvaluator.evaluate(
            sourcePaths: ["/Users/x/"],
            proofs: [proofWithoutSlash],
            expectedHost: proofWithoutSlash.sourceHost, expectedUser: proofWithoutSlash.sourceUser,
            now: referenceNow, staleAfter: referenceStaleAfter
        )

        #expect(report.verdict == .fullyCovered)
    }

    @Test("La casse distingue les chemins, par prudence : /users/x ne couvre pas /Users/x")
    func caseIsSignificant() {
        // Décision délibérée, documentée dans `SourceCoverage.swift` : entre
        // sur-déclarer une couverture (dangereux) et la sous-déclarer
        // (seulement frustrant), ce fichier choisit toujours la seconde
        // option. Une comparaison insensible à la casse ferait le premier
        // choix sur un volume APFS sensible à la casse.
        let lowercasedProof = makeProof(path: "/users/x")

        let report = SourceCoverageEvaluator.evaluate(
            sourcePaths: ["/Users/x"],
            proofs: [lowercasedProof],
            expectedHost: lowercasedProof.sourceHost, expectedUser: lowercasedProof.sourceUser,
            now: referenceNow, staleAfter: referenceStaleAfter
        )

        #expect(report.verdict == .notCovered)
    }

    // MARK: - Plusieurs sources

    @Test("Plusieurs dossiers configurés : certains couverts, d'autres jamais envoyés")
    func multipleSourcesPartiallyCovered() {
        let musicProof = makeProof(path: "/Users/quelquun/Music")

        let report = SourceCoverageEvaluator.evaluate(
            sourcePaths: ["/Users/quelquun/Music", "/Users/quelquun/Documents"],
            proofs: [musicProof],
            expectedHost: musicProof.sourceHost, expectedUser: musicProof.sourceUser,
            now: referenceNow, staleAfter: referenceStaleAfter
        )

        #expect(report.verdict == .partiallyCovered)
        #expect(report.coverages.first { $0.path == "/Users/quelquun/Music" }?.isCovered == true)
        #expect(report.coverages.first { $0.path == "/Users/quelquun/Documents" }?.isCovered == false)
        #expect(report.headline.contains("1 sur 2"))
        #expect(report.headline.contains("Documents"))
    }

    // MARK: - L'identité de la machine

    @Test("Un snapshot d'un autre Mac ne couvre rien ici")
    func differentHostCoversNothing() {
        // Le dépôt peut contenir des snapshots d'un autre Mac — le frère du
        // propriétaire a la même application, le même seau.
        let otherHostProof = makeProof(path: "/Users/quelquun", host: "autre-mac")

        let report = SourceCoverageEvaluator.evaluate(
            sourcePaths: ["/Users/quelquun"],
            proofs: [otherHostProof],
            expectedHost: "macbook-pro-de-whyte-2", expectedUser: otherHostProof.sourceUser,
            now: referenceNow, staleAfter: referenceStaleAfter
        )

        #expect(report.verdict == .notCovered)
    }

    @Test("Un snapshot d'un autre utilisateur sur la même machine ne couvre rien ici")
    func differentUserCoversNothing() {
        let otherUserProof = makeProof(path: "/Users/quelquun", user: "quelquun-dautre")

        let report = SourceCoverageEvaluator.evaluate(
            sourcePaths: ["/Users/quelquun"],
            proofs: [otherUserProof],
            expectedHost: otherUserProof.sourceHost, expectedUser: "whyteduke",
            now: referenceNow, staleAfter: referenceStaleAfter
        )

        #expect(report.verdict == .notCovered)
    }

    // MARK: - La preuve, pas seulement le chemin

    @Test("Une preuve seulement rendue par create ne couvre pas — elle n'a pas été relue dans le dépôt")
    func unconfirmedProofDoesNotCover() {
        let reportedOnly = makeProof(path: "/Users/quelquun", origin: .reportedByCreate)

        let report = SourceCoverageEvaluator.evaluate(
            sourcePaths: ["/Users/quelquun"],
            proofs: [reportedOnly],
            expectedHost: reportedOnly.sourceHost, expectedUser: reportedOnly.sourceUser,
            now: referenceNow, staleAfter: referenceStaleAfter
        )

        #expect(report.verdict == .notCovered)
    }

    @Test("Un snapshot avec des fichiers en échec ne couvre pas, même confirmé dans le dépôt")
    func incompleteSnapshotDoesNotCover() {
        let incomplete = makeProof(path: "/Users/quelquun", errorCount: 3)

        let report = SourceCoverageEvaluator.evaluate(
            sourcePaths: ["/Users/quelquun"],
            proofs: [incomplete],
            expectedHost: incomplete.sourceHost, expectedUser: incomplete.sourceUser,
            now: referenceNow, staleAfter: referenceStaleAfter
        )

        #expect(report.verdict == .notCovered)
    }

    @Test("Des erreurs ignorées par la politique du dépôt comptent autant que des erreurs déclarées")
    func ignoredErrorsAlsoBreakCoverage() {
        // Le piège documenté dans `BackupContract.swift` : ce Mac ignore les
        // erreurs de lecture, donc `errorCount` peut rester à zéro pendant
        // que `ignoredErrorCount` grimpe. Un évaluateur qui ne lirait que le
        // premier compteur afficherait « couvert » sur une source trouée.
        let ignoredErrors = makeProof(path: "/Users/quelquun", ignoredErrorCount: 500)

        let report = SourceCoverageEvaluator.evaluate(
            sourcePaths: ["/Users/quelquun"],
            proofs: [ignoredErrors],
            expectedHost: ignoredErrors.sourceHost, expectedUser: ignoredErrors.sourceUser,
            now: referenceNow, staleAfter: referenceStaleAfter
        )

        #expect(report.verdict == .notCovered)
    }

    // MARK: - La fraîcheur

    @Test("Passé le seuil de fraîcheur, un chemin couvert devient périmé, jamais « jamais couvert »")
    func staleAfterThreshold() {
        let old = makeProof(path: "/Users/quelquun", end: referenceNow.addingTimeInterval(-referenceStaleAfter - 1))

        let report = SourceCoverageEvaluator.evaluate(
            sourcePaths: ["/Users/quelquun"],
            proofs: [old],
            expectedHost: old.sourceHost, expectedUser: old.sourceUser,
            now: referenceNow, staleAfter: referenceStaleAfter
        )

        // Périmé n'est pas jamais-couvert : le verdict global reste
        // « entièrement couverte », seule la fraîcheur manque.
        #expect(report.verdict == .fullyCovered)
        guard let first = report.coverages.first else {
            Issue.record("attendu une couverture")
            return
        }
        guard case .coveredButStale(let since) = first.state else {
            Issue.record("attendu .coveredButStale, obtenu \(first.state)")
            return
        }
        #expect(since == old.endTime)
        #expect(report.headline.contains("date"))
    }

    @Test("Sous le seuil de fraîcheur, un chemin couvert reste simplement couvert")
    func freshCoverageStaysFresh() {
        let recent = makeProof(path: "/Users/quelquun", end: referenceNow.addingTimeInterval(-1))

        let report = SourceCoverageEvaluator.evaluate(
            sourcePaths: ["/Users/quelquun"],
            proofs: [recent],
            expectedHost: recent.sourceHost, expectedUser: recent.sourceUser,
            now: referenceNow, staleAfter: referenceStaleAfter
        )

        #expect(report.coverages.first?.state == .covered(at: recent.endTime))
        #expect(report.headline == "Toutes vos sources ont déjà été sauvegardées.")
    }

    // MARK: - Les cas vides, traités et non tus

    @Test("Une configuration sans aucun dossier le dit explicitement, plutôt qu'un tableau vide muet")
    func emptySourcePathsIsExplicit() {
        let report = SourceCoverageEvaluator.evaluate(
            sourcePaths: [],
            proofs: [],
            expectedHost: "h", expectedUser: "u",
            now: referenceNow, staleAfter: referenceStaleAfter
        )

        #expect(report.coverages.isEmpty)
        #expect(report.verdict == .notCovered)
        #expect(report.headline.contains("Aucun dossier n'est configuré"))
    }

    @Test("Un dépôt vide se dit autrement qu'un dépôt qui pointe ailleurs")
    func emptyRepositoryPhrasedDifferently() {
        let report = SourceCoverageEvaluator.evaluate(
            sourcePaths: ["/Users/quelquun"],
            proofs: [],
            expectedHost: "h", expectedUser: "u",
            now: referenceNow, staleAfter: referenceStaleAfter
        )

        #expect(report.headline.contains("ne contient encore aucun snapshot"))
    }
}

/// **Le suivi du premier gros envoi**, entre deux lancements de bran — pas
/// seulement pendant qu'une tentative tourne. La question posée par le
/// propriétaire : « je dois pouvoir suivre notamment le premier envoi, gros,
/// vers mon NAS ». Ces tests protègent surtout un piège inverse : additionner
/// `uploadedBytes` de toutes les tentatives sans dire ce que ça mesure
/// vraiment donnerait un chiffre qui a l'air d'une progression alors qu'il
/// compte, en partie, le même octet deux fois.
@Suite("Le suivi du premier envoi")
struct FirstUploadTests {

    @Test("Sans aucune tentative, le premier envoi n'a jamais commencé")
    func neverStarted() {
        let tracking = FirstUploadEvaluator.track(
            path: "/Users/quelquun", coverage: .neverBackedUp,
            attempts: [], sourcePaths: ["/Users/quelquun"]
        )

        #expect(tracking.state == .neverStarted)
        #expect(FirstUploadEvaluator.summary(tracking).contains("jamais commencé"))
    }

    @Test("Le cumul des reprises est honnête : la somme des tentatives, reprises comprises")
    func inProgressSumsAcrossAttempts() {
        // Deux tentatives : la première interrompue après 50 Go, la seconde
        // reprend et n'en envoie que 4 grâce à la dédup — exactement le
        // scénario que le propriétaire veut voir, pas repartir de zéro.
        let interrupted = makeAttempt(uploadedBytes: 50_000_000_000)
        let resumed = makeAttempt(uploadedBytes: 4_000_000_000)

        let tracking = FirstUploadEvaluator.track(
            path: "/Users/quelquun", coverage: .neverBackedUp,
            attempts: [interrupted, resumed], sourcePaths: ["/Users/quelquun"]
        )

        guard case .inProgress(let attemptCount, let bytes, let unknown) = tracking.state else {
            Issue.record("attendu .inProgress")
            return
        }
        #expect(attemptCount == 2)
        #expect(bytes == 54_000_000_000)
        #expect(unknown == 0)

        let text = FirstUploadEvaluator.summary(tracking)
        #expect(text.contains("2 tentatives"))
        #expect(text.contains("reprises comprises"))
        #expect(text.contains("réseau"))
        // Le mot qui prétendrait que ces octets sont à l'abri — ce que ce
        // chiffre ne garantit précisément pas.
        #expect(text.contains("sauvegardé") == false)
    }

    @Test("Une tentative sans volume connu ne se compte pas comme zéro octet")
    func unknownBytesAreNotZero() {
        let known = makeAttempt(uploadedBytes: 10_000_000_000)
        let unknownAttempt = makeAttempt(uploadedBytes: nil)

        let tracking = FirstUploadEvaluator.track(
            path: "/Users/quelquun", coverage: .neverBackedUp,
            attempts: [known, unknownAttempt], sourcePaths: ["/Users/quelquun"]
        )

        guard case .inProgress(let attemptCount, let bytes, let unknown) = tracking.state else {
            Issue.record("attendu .inProgress")
            return
        }
        // Si l'absence valait zéro, la somme serait déjà correcte par
        // accident — c'est `unknown` qui prouve que ce n'est pas le cas.
        #expect(attemptCount == 2)
        #expect(bytes == 10_000_000_000)
        #expect(unknown == 1)
        #expect(FirstUploadEvaluator.summary(tracking).contains("sans volume connu"))
    }

    @Test("Une source couverte a un premier envoi terminé, daté de la couverture — pas de la dernière tentative")
    func completedFollowsCoverage() {
        let confirmedAt = Date(timeIntervalSince1970: 1_788_000_000)

        let tracking = FirstUploadEvaluator.track(
            path: "/Users/quelquun", coverage: .covered(at: confirmedAt),
            attempts: [], sourcePaths: ["/Users/quelquun"]
        )

        #expect(tracking.state == .completed(confirmedAt: confirmedAt))
        #expect(FirstUploadEvaluator.summary(tracking).contains("terminé"))
    }

    @Test("Un chemin périmé compte quand même comme un premier envoi terminé")
    func staleCoverageStillCompletesTheFirstUpload() {
        let since = Date(timeIntervalSince1970: 1_788_000_000)

        let tracking = FirstUploadEvaluator.track(
            path: "/Users/quelquun", coverage: .coveredButStale(since: since),
            attempts: [], sourcePaths: ["/Users/quelquun"]
        )

        #expect(tracking.state == .completed(confirmedAt: since))
    }

    // MARK: - La limite de l'attribution à plusieurs sources

    @Test("Plusieurs dossiers configurés : une tentative sans preuve n'est jamais attribuée au hasard")
    func multiSourceAttributionIsCautious() {
        // Rien dans `BackupAttempt` ne dit quel chemin cette tentative visait
        // — elle a échoué avant tout manifeste. Avec un seul chemin
        // configuré ce serait sans ambiguïté ; ici, avec deux, l'attribuer à
        // l'un plutôt qu'à l'autre serait une invention.
        let unattributable = makeAttempt(uploadedBytes: 99_000_000_000)

        let tracking = FirstUploadEvaluator.track(
            path: "/Users/quelquun/Music", coverage: .neverBackedUp,
            attempts: [unattributable],
            sourcePaths: ["/Users/quelquun/Music", "/Users/quelquun/Documents"]
        )

        #expect(tracking.state == .neverStarted)
    }

    @Test("Plusieurs dossiers configurés : une tentative dont le proof porte le bon chemin est comptée")
    func multiSourceAttributionUsesProofPath() {
        // Un proof `reportedByCreate` ne suffit pas à couvrir une source —
        // voir `SourceCoverageTests` — mais il suffit à dire quel chemin
        // cette tentative visait, ce qui est tout ce qu'on lui demande ici.
        let matchingProof = makeProof(path: "/Users/quelquun/Music", origin: .reportedByCreate)
        let attempt = makeAttempt(proof: matchingProof, uploadedBytes: 5_000_000_000)

        let tracking = FirstUploadEvaluator.track(
            path: "/Users/quelquun/Music", coverage: .neverBackedUp,
            attempts: [attempt],
            sourcePaths: ["/Users/quelquun/Music", "/Users/quelquun/Documents"]
        )

        guard case .inProgress(let attemptCount, let bytes, _) = tracking.state else {
            Issue.record("attendu .inProgress")
            return
        }
        #expect(attemptCount == 1)
        #expect(bytes == 5_000_000_000)
    }

    @Test("Un seul dossier configuré : toute tentative du journal lui est attribuée, même sans preuve")
    func singleSourceAttributesEveryAttempt() {
        let a = makeAttempt(uploadedBytes: 1_000_000_000)
        let b = makeAttempt(uploadedBytes: 2_000_000_000)

        let tracking = FirstUploadEvaluator.track(
            path: "/Users/quelquun", coverage: .neverBackedUp,
            attempts: [a, b], sourcePaths: ["/Users/quelquun"]
        )

        guard case .inProgress(let attemptCount, let bytes, _) = tracking.state else {
            Issue.record("attendu .inProgress")
            return
        }
        #expect(attemptCount == 2)
        #expect(bytes == 3_000_000_000)
    }
}
