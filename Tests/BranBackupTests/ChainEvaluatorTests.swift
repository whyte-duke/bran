import Foundation
import Testing
@testable import BranBackup

/// **Le registre des mensonges que la panne des 35 jours a rendus possibles**,
/// et la preuve que `ChainEvaluator` les ferme.
///
/// Le conteneur MinIO est resté arrêté 35 jours pendant que la configuration
/// locale disait « prêt » : personne n'a jamais regardé les six maillons
/// ensemble, et rien n'a distingué une vieille vérité d'une mesure du jour.
/// Chaque cas ci-dessous reproduit une façon dont un verdict aurait pu
/// afficher « ça va » — ou « c'est cassé » au mauvais endroit — sans que
/// personne ne le remarque.
@Suite("Le verdict sur la chaîne réseau")
struct ChainEvaluatorTests {

    private static let now = Date(timeIntervalSince1970: 1_788_000_000)
    private static let freshness: TimeInterval = 300

    private func result(
        _ link: ChainLink,
        _ state: LinkState,
        diagnostic: String = "",
        latency: TimeInterval? = nil,
        measuredAt: Date = ChainEvaluatorTests.now
    ) -> LinkProbeResult {
        LinkProbeResult(
            link: link, state: state, diagnostic: diagnostic,
            latency: latency, measuredAt: measuredAt
        )
    }

    // MARK: - La chaîne saine

    @Test("Les six maillons verts, aux latences réellement mesurées, autorisent la sauvegarde")
    func sixGreenLinksAllow() {
        let results = [
            result(.tailscaleLocal, .up, diagnostic: "Tailscale actif."),
            result(.minioNodeOnline, .up, diagnostic: "Pair minio-backup en ligne."),
            result(.s3Reachable, .up, diagnostic: "Port 9000 ouvert.", latency: 0.38),
            result(.minioHealthy, .up, diagnostic: "/health/live puis /ready répondent.", latency: 0.194),
            result(.bucketReachable, .up, diagnostic: "403 sur le seau, attendu.", latency: 0.109),
            result(.repositoryOpens, .up, diagnostic: "Le dépôt s'ouvre.", latency: 1.2),
        ]

        let verdict = ChainEvaluator.evaluate(results, now: Self.now, freshness: Self.freshness)

        #expect(verdict.canBackUp)
        #expect(verdict.firstFailure == nil)
        #expect(verdict.results.count == 6)
        #expect(verdict.results.map(\.link) == ChainLink.allCases)
    }

    // MARK: - La cause, pas l'écho

    @Test("Le scénario des 35 jours accuse le maillon 2, jamais ses échos en aval")
    func rootCauseNotEcho() {
        let results = [
            result(.tailscaleLocal, .up, diagnostic: "Tailscale actif."),
            result(.minioNodeOnline, .down,
                   diagnostic: "Le conteneur MinIO est hors ligne, probablement arrêté sur le Proxmox."),
            result(.s3Reachable, .down, diagnostic: "Connexion refusée sur le port 9000."),
            result(.minioHealthy, .down, diagnostic: "/health/live ne répond pas."),
            result(.bucketReachable, .down, diagnostic: "Aucune réponse S3."),
            result(.repositoryOpens, .down, diagnostic: "Le dépôt ne s'ouvre pas."),
        ]

        let verdict = ChainEvaluator.evaluate(results, now: Self.now, freshness: Self.freshness)

        #expect(verdict.firstFailure == .minioNodeOnline)
        #expect(verdict.headline == "Le conteneur MinIO est hors ligne, probablement arrêté sur le Proxmox.")
        #expect(verdict.canBackUp == false)

        #expect(ChainEvaluator.isConsequence(.tailscaleLocal, of: verdict) == false)
        #expect(ChainEvaluator.isConsequence(.minioNodeOnline, of: verdict) == false)
        #expect(ChainEvaluator.isConsequence(.s3Reachable, of: verdict))
        #expect(ChainEvaluator.isConsequence(.minioHealthy, of: verdict))
        #expect(ChainEvaluator.isConsequence(.bucketReachable, of: verdict))
        #expect(ChainEvaluator.isConsequence(.repositoryOpens, of: verdict))
    }

    // MARK: - L'ignorance n'est pas verte

    @Test("Un seul maillon inconnu suffit à interdire la sauvegarde")
    func unknownAloneForbids() {
        let results = [
            result(.tailscaleLocal, .up),
            result(.minioNodeOnline, .up),
            result(.s3Reachable, .up),
            result(.minioHealthy, .up),
            result(.bucketReachable, .unknown, diagnostic: "Sonde jamais lancée depuis le dernier lancement."),
            result(.repositoryOpens, .up),
        ]

        let verdict = ChainEvaluator.evaluate(results, now: Self.now, freshness: Self.freshness)

        #expect(verdict.canBackUp == false)
        #expect(verdict.firstFailure == nil)
        #expect(verdict.headline == "Sonde jamais lancée depuis le dernier lancement.")
    }

    @Test("Une liste vide ne rend rien vert : les six maillons redeviennent inconnus")
    func emptyListAllowsNothing() {
        let verdict = ChainEvaluator.evaluate([], now: Self.now, freshness: Self.freshness)

        #expect(verdict.canBackUp == false)
        #expect(verdict.results.count == 6)
        #expect(verdict.results.allSatisfy { $0.state == .unknown })
        #expect(verdict.results.map(\.link) == ChainLink.allCases)
    }

    @Test("Un maillon absent de la liste ressort quand même, en inconnu")
    func missingLinkIsCompletedAsUnknown() {
        let results = [
            result(.tailscaleLocal, .up),
            result(.minioNodeOnline, .up),
        ]

        let verdict = ChainEvaluator.evaluate(results, now: Self.now, freshness: Self.freshness)

        #expect(verdict.results.count == 6)
        let completedLinks: Set<ChainLink> = [.s3Reachable, .minioHealthy, .bucketReachable, .repositoryOpens]
        for link in completedLinks {
            let entry = verdict.results.first { $0.link == link }
            #expect(entry?.state == .unknown)
            #expect(entry?.diagnostic.isEmpty == false)
        }
        #expect(verdict.canBackUp == false)
    }

    // MARK: - `connecting` ne ment pas dans l'autre sens

    @Test("Une connexion en cours sur le dépôt s'annonce comme telle, jamais comme un échec")
    func connectingIsNotFailure() {
        let results = [
            result(.tailscaleLocal, .up),
            result(.minioNodeOnline, .up),
            result(.s3Reachable, .up),
            result(.minioHealthy, .up),
            result(.bucketReachable, .up),
            result(.repositoryOpens, .connecting,
                   diagnostic: "Ouverture du dépôt en cours (dépôt froid, ça peut prendre du temps)."),
        ]

        let verdict = ChainEvaluator.evaluate(results, now: Self.now, freshness: Self.freshness)

        #expect(verdict.canBackUp == false)
        #expect(verdict.firstFailure == nil)
        #expect(verdict.headline.localizedCaseInsensitiveContains("connexion en cours"))
        #expect(verdict.headline.localizedCaseInsensitiveContains("échec") == false)
        #expect(verdict.headline.localizedCaseInsensitiveContains("erreur") == false)
    }

    // MARK: - La fraîcheur

    @Test("Une mesure périmée redevient inconnue et le dit, au lieu de rejouer l'ancien verdict")
    func staleMeasurementBecomesUnknown() {
        let staleMeasuredAt = Self.now.addingTimeInterval(-(Self.freshness + 100))
        let results = [
            result(.tailscaleLocal, .up),
            result(.minioNodeOnline, .up),
            // Mesuré « bon » il y a longtemps — exactement la configuration qui a
            // laissé croire, 35 jours durant, qu'un conteneur arrêté était prêt.
            result(.s3Reachable, .up, diagnostic: "Port 9000 ouvert.", measuredAt: staleMeasuredAt),
            result(.minioHealthy, .up),
            result(.bucketReachable, .up),
            result(.repositoryOpens, .up),
        ]

        let verdict = ChainEvaluator.evaluate(results, now: Self.now, freshness: Self.freshness)

        let downgraded = verdict.results.first { $0.link == .s3Reachable }
        #expect(downgraded?.state == .unknown)
        #expect(downgraded?.diagnostic.localizedCaseInsensitiveContains("périmée") == true)
        #expect(verdict.canBackUp == false)
        #expect(verdict.headline.localizedCaseInsensitiveContains("périmée"))
    }

    @Test("Une mesure pile à la limite de fraîcheur n'est pas encore périmée")
    func exactlyAtFreshnessLimitStillCounts() {
        let boundary = Self.now.addingTimeInterval(-Self.freshness)
        let results = ChainLink.allCases.map { result($0, .up, measuredAt: boundary) }

        let verdict = ChainEvaluator.evaluate(results, now: Self.now, freshness: Self.freshness)

        #expect(verdict.canBackUp)
        #expect(verdict.results.allSatisfy { $0.state == .up })
    }

    // MARK: - Doublons

    @Test("Deux résultats pour le même maillon : le plus récent gagne, même s'il est moins bon")
    func duplicatesKeepTheMostRecent() {
        let older = result(
            .repositoryOpens, .up, diagnostic: "Le dépôt s'ouvre.",
            measuredAt: Self.now.addingTimeInterval(-10)
        )
        let newer = result(
            .repositoryOpens, .down, diagnostic: "Le dépôt refuse le mot de passe.",
            measuredAt: Self.now
        )
        let results = [
            result(.tailscaleLocal, .up), result(.minioNodeOnline, .up),
            result(.s3Reachable, .up), result(.minioHealthy, .up),
            result(.bucketReachable, .up),
            older, newer,
        ]

        let verdict = ChainEvaluator.evaluate(results, now: Self.now, freshness: Self.freshness)

        let kept = verdict.results.first { $0.link == .repositoryOpens }
        #expect(kept?.state == .down)
        #expect(kept?.diagnostic == "Le dépôt refuse le mot de passe.")
        #expect(verdict.firstFailure == .repositoryOpens)
    }

    // MARK: - `degraded` reste franchissable

    @Test("Un maillon dégradé laisse sauvegarder, mais le bandeau le signale")
    func degradedAllowsButSignals() {
        let results = [
            result(.tailscaleLocal, .up),
            result(.minioNodeOnline, .up),
            result(.s3Reachable, .up),
            result(.minioHealthy, .degraded, diagnostic: "Santé de MinIO partielle, latence 900 ms."),
            result(.bucketReachable, .up),
            result(.repositoryOpens, .up),
        ]

        let verdict = ChainEvaluator.evaluate(results, now: Self.now, freshness: Self.freshness)

        #expect(verdict.canBackUp)
        #expect(verdict.firstFailure == nil)
        #expect(verdict.headline.localizedCaseInsensitiveContains("dégrad"))
    }
}
