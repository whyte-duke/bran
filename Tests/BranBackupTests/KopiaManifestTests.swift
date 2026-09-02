import Foundation
import Testing
@testable import BranBackup

/// **Les manières dont un manifeste de Kopia peut mentir**, et la preuve qu'on
/// ne les prend pas.
///
/// Chaque cas de ce fichier rejoue une sortie réelle de kopia 0.23.1, relevée
/// le 02/09/2026 (`create.json`, `create2.json`, `list.json`), ou une variante
/// délibérément cassée d'une de ces sorties — tronquée, polluée, privée d'un
/// champ, chargée d'un compteur d'erreurs non nul. Un décodeur JSON est
/// exactement le genre de fonction qui affiche « tout va bien » sur une entrée
/// qu'il n'a pas comprise ; ce fichier vérifie qu'il échoue nommément à la
/// place, ou qu'il porte la mauvaise nouvelle jusqu'au bout plutôt que de
/// l'arrondir.
@Suite("Le décodage des manifestes de Kopia")
struct KopiaManifestTests {

    // MARK: - Les sorties réelles, textuellement

    /// `kopia snapshot create --json`, relevé le 02/09/2026 (`fixtures/create.json`).
    private let createJSON = Data(#"""
    {"id":"8145671624282e64839f6e3a98678616","source":{"host":"mac-de-quelquun","userName":"quelquun","path":"/tmp/fixtures/src"},"description":"","startTime":"2026-09-02T12:43:37.888422Z","endTime":"2026-09-02T12:43:38.02194Z","rootEntry":{"name":"src","type":"d","mode":"0755","mtime":"2026-09-02T12:43:37.193919479Z","uid":501,"obj":"k348b268a5c35490f1cbaae28a7eb5588","summ":{"size":3000064,"files":3,"symlinks":0,"dirs":2,"maxTime":"2026-09-02T12:43:37.20781277Z","numFailed":0}}}
    """#.utf8)

    /// Même commande, second run (`fixtures/create2.json`).
    private let create2JSON = Data(#"""
    {"id":"3bc941641015a70b0b1835f3b7e2b9da","source":{"host":"mac-de-quelquun","userName":"quelquun","path":"/tmp/fixtures/src2"},"description":"","startTime":"2026-09-02T12:45:02.91771Z","endTime":"2026-09-02T12:45:46.504903Z","rootEntry":{"name":"src2","type":"d","mode":"0755","mtime":"2026-09-02T12:44:58.753389536Z","uid":501,"obj":"k685ab07c96a179909a2fd1cd9f804668","summ":{"size":240000000,"files":12,"symlinks":0,"dirs":1,"maxTime":"2026-09-02T12:44:58.830870891Z","numFailed":0}}}
    """#.utf8)

    /// `kopia snapshot list --all --json`, les deux mêmes runs relus dans le
    /// dépôt (`fixtures/list.json`).
    private let listJSON = Data(#"""
    [
     {"id":"8145671624282e64839f6e3a98678616","source":{"host":"mac-de-quelquun","userName":"quelquun","path":"/tmp/fixtures/src"},"description":"","startTime":"2026-09-02T12:43:37.888422Z","endTime":"2026-09-02T12:43:38.02194Z","stats":{"totalSize":3000064,"excludedTotalSize":0,"fileCount":3,"cachedFiles":0,"nonCachedFiles":3,"dirCount":2,"excludedFileCount":0,"excludedDirCount":0,"ignoredErrorCount":0,"errorCount":0},"rootEntry":{"name":"src","type":"d","mode":"0755","mtime":"2026-09-02T12:43:37.193919479Z","uid":501,"obj":"k348b268a5c35490f1cbaae28a7eb5588","summ":{"size":3000064,"files":3,"symlinks":0,"dirs":2,"maxTime":"2026-09-02T12:43:37.20781277Z","numFailed":0}},"retentionReason":["latest-1","hourly-1","daily-1","weekly-1","monthly-1","annual-1"]},
     {"id":"3bc941641015a70b0b1835f3b7e2b9da","source":{"host":"mac-de-quelquun","userName":"quelquun","path":"/tmp/fixtures/src2"},"description":"","startTime":"2026-09-02T12:45:02.91771Z","endTime":"2026-09-02T12:45:46.504903Z","stats":{"totalSize":240000000,"excludedTotalSize":0,"fileCount":12,"cachedFiles":0,"nonCachedFiles":12,"dirCount":1,"excludedFileCount":0,"excludedDirCount":0,"ignoredErrorCount":0,"errorCount":0},"rootEntry":{"name":"src2","type":"d","mode":"0755","mtime":"2026-09-02T12:44:58.753389536Z","uid":501,"obj":"k685ab07c96a179909a2fd1cd9f804668","summ":{"size":240000000,"files":12,"symlinks":0,"dirs":1,"maxTime":"2026-09-02T12:44:58.830870891Z","numFailed":0}},"retentionReason":["latest-1","hourly-1","daily-1","weekly-1","monthly-1","annual-1"]}
    ]
    """#.utf8)

    /// `kopia repository status --json`, relevé le 02/09/2026 (les valeurs déjà
    /// masquées par kopia lui-même le restent ici, telles quelles).
    private let repositoryStatusJSON = Data(#"""
    {"configFile":"/Users/…/repository.config","uniqueIDHex":"ac295293cfa4014861a78a39ed1fa97bcfef09b7669fe762554d692c010ff120","clientOptions":{"hostname":"mac-de-quelquun","username":"quelquun","description":"Sauvegarde du Mac","enableActions":false,"formatBlobCacheDuration":900000000000},"storage":{"type":"s3","config":{"bucket":"seau-de-ce-mac","endpoint":"…:9000","doNotUseTLS":true,"accessKeyID":"…","secretAccessKey":"**********************","sessionToken":"","roleARN":"","sessionName":"","duration":"0s","roleEndpoint":"","roleRegion":"","region":"us-east-1"}},"contentFormat":{"hash":"BLAKE2B-256-128","encryption":"AES256-GCM-HMAC-SHA256","version":3,"maxPackSize":20971520,"indexVersion":2,"epochParameters":{"Enabled":true,"EpochRefreshFrequency":1200000000000,"FullCheckpointFrequency":7,"CleanupSafetyMargin":14400000000000,"MinEpochDuration":86400000000000,"EpochAdvanceOnCountThreshold":20,"EpochAdvanceOnTotalSizeBytesThreshold":10485760,"DeleteParallelism":4},"enablePasswordChange":true},"objectFormat":{"splitter":"DYNAMIC-4M-BUZHASH"},"blobRetention":{}}
    """#.utf8)

    /// Remplace la **première** occurrence seulement — utile pour blesser une
    /// entrée d'un tableau de deux sans toucher l'autre, et prouver que le
    /// décodeur les traite indépendamment plutôt que d'appliquer un défaut
    /// global.
    private func replacingFirstOccurrence(of target: String, with replacement: String, in text: String) -> String {
        guard let range = text.range(of: target) else { return text }
        var text = text
        text.replaceSubrange(range, with: replacement)
        return text
    }

    // MARK: - Les trois sorties réelles, décodées correctement

    @Test("create.json donne une preuve reportée, jamais confirmée")
    func decodesRealCreateOutput() throws {
        let proof = try KopiaManifest.decodeCreatedSnapshot(createJSON)
        #expect(proof.id == "8145671624282e64839f6e3a98678616")
        #expect(proof.rootObjectID == "k348b268a5c35490f1cbaae28a7eb5588")
        #expect(proof.fileCount == 3)
        #expect(proof.totalSize == 3_000_064)
        #expect(proof.dirCount == 2)
        #expect(proof.errorCount == 0)
        #expect(proof.origin == .reportedByCreate)
        // Reportée mais jamais relue : pas digne de confiance, quoi qu'elle dise.
        #expect(proof.isTrustworthy == false)
    }

    @Test("create2.json donne les mêmes garanties sur un second run, avec d'autres nombres")
    func decodesRealSecondCreateOutput() throws {
        let proof = try KopiaManifest.decodeCreatedSnapshot(create2JSON)
        #expect(proof.id == "3bc941641015a70b0b1835f3b7e2b9da")
        #expect(proof.rootObjectID == "k685ab07c96a179909a2fd1cd9f804668")
        #expect(proof.fileCount == 12)
        #expect(proof.totalSize == 240_000_000)
        #expect(proof.dirCount == 1)
        #expect(proof.errorCount == 0)
    }

    @Test("list.json confirme les deux mêmes snapshots depuis le dépôt")
    func decodesRealListOutput() throws {
        let proofs = try KopiaManifest.decodeSnapshotList(listJSON)
        #expect(proofs.count == 2)

        let first = try #require(proofs.first { $0.id == "8145671624282e64839f6e3a98678616" })
        #expect(first.rootObjectID == "k348b268a5c35490f1cbaae28a7eb5588")
        #expect(first.fileCount == 3)
        #expect(first.totalSize == 3_000_064)
        #expect(first.origin == .confirmedInRepository)
        #expect(first.isTrustworthy)

        let second = try #require(proofs.first { $0.id == "3bc941641015a70b0b1835f3b7e2b9da" })
        #expect(second.fileCount == 12)
        #expect(second.totalSize == 240_000_000)
        #expect(second.origin == .confirmedInRepository)
        #expect(second.isTrustworthy)
    }

    @Test("Le statut du dépôt expose le seau, l'hôte et le chiffrement, jamais les secrets")
    func decodesRealRepositoryStatus() throws {
        let status = try KopiaManifest.decodeRepositoryStatus(repositoryStatusJSON)
        #expect(status.uniqueID == "ac295293cfa4014861a78a39ed1fa97bcfef09b7669fe762554d692c010ff120")
        #expect(status.storageType == "s3")
        #expect(status.bucket == "seau-de-ce-mac")
        #expect(status.endpoint == "…:9000")
        #expect(status.hostname == "mac-de-quelquun")
        #expect(status.username == "quelquun")
        #expect(status.encryption == "AES256-GCM-HMAC-SHA256")
        #expect(status.hash == "BLAKE2B-256-128")
    }

    // MARK: - Les dates : 0, 3, 6, 9 décimales, et une longueur irrégulière vue en vrai

    /// Le 2 septembre 2026, 12:43:37 UTC, sans fraction — le repère contre
    /// lequel chaque variante se compare.
    private func baseInstant() -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        var components = DateComponents()
        components.year = 2026
        components.month = 9
        components.day = 2
        components.hour = 12
        components.minute = 43
        components.second = 37
        return calendar.date(from: components)!
    }

    private func minimalCreateJSON(startTime: String) -> Data {
        Data(#"""
        {"id":"x","source":{"host":"h","userName":"u","path":"/p"},"startTime":"\#(startTime)","endTime":"\#(startTime)","rootEntry":{"obj":"k1","summ":{"size":1,"files":1,"dirs":1,"numFailed":0}}}
        """#.utf8)
    }

    @Test("Une date sans fraction se lit — zéro décimale n'est pas un format à part")
    func zeroFractionalDigits() throws {
        let proof = try KopiaManifest.decodeCreatedSnapshot(minimalCreateJSON(startTime: "2026-09-02T12:43:37Z"))
        #expect(abs(proof.startTime.timeIntervalSince(baseInstant())) < 0.000_001)
    }

    @Test("Trois décimales — la milliseconde — se lisent sans perte")
    func threeFractionalDigits() throws {
        let proof = try KopiaManifest.decodeCreatedSnapshot(minimalCreateJSON(startTime: "2026-09-02T12:43:37.888Z"))
        #expect(abs(proof.startTime.timeIntervalSince(baseInstant()) - 0.888) < 0.000_001)
    }

    @Test("Six décimales — la microseconde réelle de startTime — se lisent sans perte")
    func sixFractionalDigits() throws {
        // La valeur exacte de `create.json`, reprise littéralement.
        let proof = try KopiaManifest.decodeCreatedSnapshot(
            minimalCreateJSON(startTime: "2026-09-02T12:43:37.888422Z"))
        #expect(abs(proof.startTime.timeIntervalSince(baseInstant()) - 0.888422) < 0.000_001)
    }

    @Test("Neuf décimales — la nanoseconde réelle de mtime — ne font pas échouer le décodage")
    func nineFractionalDigits() throws {
        // La valeur exacte de `mtime` dans `create.json`, reprise littéralement
        // — c'est la précision qui est testée ici, pas le champ `mtime` lui-même,
        // que `SnapshotProof` ne porte pas.
        let proof = try KopiaManifest.decodeCreatedSnapshot(
            minimalCreateJSON(startTime: "2026-09-02T12:43:37.193919479Z"))
        #expect(abs(proof.startTime.timeIntervalSince(baseInstant()) - 0.193919479) < 0.000_001)
    }

    @Test("Une longueur de fraction irrégulière — cinq chiffres, vue sur le vrai endTime — se lit aussi")
    func fiveFractionalDigitsFromRealEndTime() throws {
        // `create.json` porte réellement "38.02194Z" sur `endTime` : cinq
        // chiffres, ni 3, ni 6, ni 9. Un décodeur qui ne tolérerait que les
        // trois longueurs annoncées casserait sur cette sortie précise, celle
        // qu'on décode vraiment.
        let proof = try KopiaManifest.decodeCreatedSnapshot(createJSON)
        let oneSecondLater = baseInstant().addingTimeInterval(1) // 12:43:38
        #expect(abs(proof.endTime.timeIntervalSince(oneSecondLater) - 0.02194) < 0.000_001)
    }

    // MARK: - Le piège central : numFailed, errorCount, ignoredErrorCount

    @Test("Un numFailed non nul, dans create.json, interdit isComplete")
    func numFailedBreaksCompleteness() throws {
        let text = replacingFirstOccurrence(
            of: #""numFailed":0"#, with: #""numFailed":2"#,
            in: String(decoding: createJSON, as: UTF8.self)
        )
        let proof = try KopiaManifest.decodeCreatedSnapshot(Data(text.utf8))
        #expect(proof.errorCount == 2)
        #expect(proof.isComplete == false)
        #expect(proof.isTrustworthy == false)
    }

    @Test("Un ignoredErrorCount non nul, dans list.json, interdit isComplete même confirmé")
    func ignoredErrorCountBreaksCompletenessEvenConfirmed() throws {
        // La politique réelle de ce dépôt ignore les erreurs de lecture
        // (« Ignore file/directory read errors: true ») : un fichier verrouillé
        // incrémente ce compteur-là, jamais `errorCount`, et kopia sort quand
        // même avec le code 0. C'est le trou que le contrat a fermé après
        // coup — ce test prouve qu'il reste fermé. On ne blesse que la
        // première entrée : la seconde doit rester intacte, preuve que les
        // deux sont vraiment lues indépendamment.
        let text = replacingFirstOccurrence(
            of: #""ignoredErrorCount":0,"errorCount":0"#,
            with: #""ignoredErrorCount":7,"errorCount":0"#,
            in: String(decoding: listJSON, as: UTF8.self)
        )
        let proofs = try KopiaManifest.decodeSnapshotList(Data(text.utf8))

        let first = try #require(proofs.first { $0.id == "8145671624282e64839f6e3a98678616" })
        #expect(first.ignoredErrorCount == 7)
        #expect(first.errorCount == 0)
        #expect(first.isComplete == false)
        #expect(first.missingFileCount == 7)
        // Confirmée par le dépôt, mais trouée quand même : la confirmation ne
        // rachète pas un fichier tu.
        #expect(first.origin == .confirmedInRepository)
        #expect(first.isTrustworthy == false)

        let second = try #require(proofs.first { $0.id == "3bc941641015a70b0b1835f3b7e2b9da" })
        #expect(second.ignoredErrorCount == 0)
        #expect(second.isComplete)
        #expect(second.isTrustworthy)
    }

    @Test("kopia snapshot create ne sait pas dire ignoredErrorCount : la preuve reste non digne de confiance, pas fausse")
    func createOutputHasNoIgnoredErrorCount() throws {
        // `create.json` ne porte ni `stats`, ni aucun équivalent de
        // `ignoredErrorCount` : ce chemin ne peut tout simplement pas le
        // mesurer. Ce test fige la décision prise dans `KopiaManifest.buildProof`
        // — la valeur posée est 0, mais ce n'est jamais elle qui protège contre
        // un faux « complet » : c'est `origin`, qui reste `.reportedByCreate`
        // et que `isTrustworthy` exclut quoi qu'il arrive tant que `list` n'a
        // pas confirmé.
        let proof = try KopiaManifest.decodeCreatedSnapshot(createJSON)
        #expect(proof.ignoredErrorCount == 0)
        #expect(proof.origin == .reportedByCreate)
        #expect(proof.isTrustworthy == false)
    }

    // MARK: - Champ absent vs champ à zéro

    @Test("Une taille à zéro est une source vide légitime, pas un échec de lecture")
    func zeroSizeIsLegitimate() throws {
        let json = Data(#"""
        {"id":"x","source":{"host":"h","userName":"u","path":"/p"},"startTime":"2026-09-02T12:43:37Z","endTime":"2026-09-02T12:43:37Z","rootEntry":{"obj":"k1","summ":{"size":0,"files":0,"dirs":1,"numFailed":0}}}
        """#.utf8)
        let proof = try KopiaManifest.decodeCreatedSnapshot(json)
        #expect(proof.totalSize == 0)
        #expect(proof.fileCount == 0)
    }

    @Test("Une taille absente est un JSON qu'on n'a pas compris, jamais un zéro silencieux")
    func missingSizeIsAFailure() throws {
        let json = Data(#"""
        {"id":"x","source":{"host":"h","userName":"u","path":"/p"},"startTime":"2026-09-02T12:43:37Z","endTime":"2026-09-02T12:43:37Z","rootEntry":{"obj":"k1","summ":{"files":0,"dirs":1,"numFailed":0}}}
        """#.utf8)
        do {
            _ = try KopiaManifest.decodeCreatedSnapshot(json)
            Issue.record("aurait dû échouer : rootEntry.summ.size est absent")
        } catch let failure as KopiaDecodingFailure {
            guard case .missingField(let path, _) = failure else {
                Issue.record("mauvais cas : \(failure)")
                return
            }
            #expect(path == "rootEntry.summ.size")
        }
    }

    // MARK: - Un champ obligatoire absent, ailleurs dans l'arbre

    @Test("Un identifiant de snapshot absent produit une erreur nommée, jamais une preuve à moitié remplie")
    func missingIdIsNamed() throws {
        let json = Data(#"""
        {"source":{"host":"h","userName":"u","path":"/p"},"startTime":"2026-09-02T12:43:37Z","endTime":"2026-09-02T12:43:38Z","rootEntry":{"obj":"k1","summ":{"size":10,"files":1,"dirs":1,"numFailed":0}}}
        """#.utf8)
        do {
            _ = try KopiaManifest.decodeCreatedSnapshot(json)
            Issue.record("aurait dû échouer : id est absent")
        } catch let failure as KopiaDecodingFailure {
            guard case .missingField(let path, _) = failure else {
                Issue.record("mauvais cas : \(failure)")
                return
            }
            #expect(path == "id")
        }
    }

    // MARK: - JSON tronqué

    @Test("Un kopia tué en plein --json lève une erreur nommée, jamais un manifeste partiel")
    func truncatedJSONFails() throws {
        // La moitié de `create.json`, coupée en plein milieu d'une chaîne — le
        // JSON qu'écrirait un processus tué avant d'avoir fini sa ligne.
        let half = createJSON.prefix(createJSON.count / 2)
        do {
            _ = try KopiaManifest.decodeCreatedSnapshot(half)
            Issue.record("aurait dû échouer : JSON coupé en plein milieu")
        } catch is KopiaDecodingFailure {
            // Nommée, et c'est tout ce qu'on demande ici : jamais un
            // `SnapshotProof` construit sur une ligne incomplète.
        }
    }

    // MARK: - Tableau vide

    @Test("Un dépôt sain et vide rend « aucun snapshot », jamais une erreur de dépôt")
    func emptyRepositoryIsNotAnError() throws {
        // Vécu tel quel sur ce Mac le 02/09/2026 : dépôt sain, zéro snapshot,
        // et pourtant 143,1 Go déjà envoyés — la preuve que « vide » et
        // « cassé » sont deux choses différentes qu'il ne fallait pas confondre.
        let bracketForm = try KopiaManifest.decodeSnapshotList(Data("[]".utf8))
        #expect(bracketForm.isEmpty)

        let blankForm = try KopiaManifest.decodeSnapshotList(Data("".utf8))
        #expect(blankForm.isEmpty)
    }

    // MARK: - Sortie polluée

    @Test("Une ligne de log avant le JSON n'empêche pas de lire le manifeste")
    func pollutedStdoutIsIsolated() throws {
        let polluted = Data(("Loading cache from disk...\n" + String(decoding: createJSON, as: UTF8.self)).utf8)
        let proof = try KopiaManifest.decodeCreatedSnapshot(polluted)
        #expect(proof.id == "8145671624282e64839f6e3a98678616")
        #expect(proof.rootObjectID == "k348b268a5c35490f1cbaae28a7eb5588")
    }

    /// **Le repli savait retirer le bruit d'avant, jamais celui d'après.** Il
    /// reconstruisait `lines[startIndex...]` jusqu'à la fin de la sortie, donc
    /// tout texte placé après le JSON restait dans le payload et faisait
    /// échouer `JSONDecoder`. Un dépôt sain et vide ressortait « JSON
    /// tronqué », donc `.unparseable`, donc un rouge sur un écran où rien
    /// n'est cassé — exactement la confusion que `emptyRepositoryIsNotAnError`
    /// existe pour empêcher, remise en place par le chemin d'à côté.
    @Test("Un message de maintenance après le JSON ne le rend pas tronqué")
    func trailingNoiseAfterJSONIsDropped() throws {
        let snapshots = try KopiaManifest.decodeSnapshotList(Data("[]\nFinished maintenance.\n".utf8))
        #expect(snapshots.isEmpty)
    }

    @Test("Un message après un manifeste complet ne l'empêche pas d'être lu")
    func trailingNoiseAfterACreateManifestIsDropped() throws {
        let noisy = Data(
            (String(decoding: createJSON, as: UTF8.self) + "\nFinished maintenance.\n").utf8
        )
        let proof = try KopiaManifest.decodeCreatedSnapshot(noisy)
        #expect(proof.id == "8145671624282e64839f6e3a98678616")
    }

    /// Le piège de l'isolation par balayage : un `]` ou un `}` **dans une
    /// chaîne** n'est pas un délimiteur. S'arrêter dessus couperait le JSON en
    /// plein milieu, c'est-à-dire reproduirait dans l'autre sens le défaut
    /// qu'on vient de fermer. Le chemin de source ci-dessous en porte un,
    /// échappé qui plus est.
    @Test("Un crochet à l'intérieur d'un nom de dossier ne coupe pas le manifeste")
    func bracketsInsideStringsDoNotEndTheJSON() throws {
        let json = Data(#"""
        [{"id":"x","source":{"host":"h","userName":"u","path":"/p/dossier [bis] \"cité\"/fin"},"startTime":"2026-09-02T12:43:37Z","endTime":"2026-09-02T12:43:37Z","stats":{"errorCount":0,"ignoredErrorCount":0},"rootEntry":{"obj":"k1","summ":{"size":10,"files":1,"dirs":1,"numFailed":0}}}]
        Finished maintenance.
        """#.utf8)
        let proofs = try KopiaManifest.decodeSnapshotList(json)
        #expect(proofs.count == 1)
        #expect(proofs.first?.sourcePath == #"/p/dossier [bis] "cité"/fin"#)
    }

    @Test("Une sortie qui ne contient aucun JSON échoue proprement, sans deviner")
    func noJSONAtAllFails() throws {
        // Une vraie ligne d'erreur de kopia, sans aucun JSON — le mauvais mot
        // de passe relevé le 02/09/2026.
        let text = Data(
            "failed to open repository: unable to create format manager: invalid repository password".utf8)
        do {
            _ = try KopiaManifest.decodeCreatedSnapshot(text)
            Issue.record("aurait dû échouer : aucun JSON dans cette sortie")
        } catch let failure as KopiaDecodingFailure {
            guard case .noRecognizableJSON(_) = failure else {
                Issue.record("mauvais cas : \(failure)")
                return
            }
        }
    }

    // MARK: - La conversion en BackupFailure

    @Test("Un échec de décodage se convertit en BackupFailure de genre unparseable")
    func convertsToUnparseableBackupFailure() {
        let failure = KopiaDecodingFailure.missingField(path: "id", context: "kopia snapshot create --json")
        let backupFailure = failure.asBackupFailure(rawOutput: "{}")
        #expect(backupFailure.kind == .unparseable)
        #expect(backupFailure.rawOutput == "{}")
        #expect(backupFailure.summary.contains("id"))
    }
}

/// **Le chiffre que la déduplication rend faux, et d'où il faut le lire.**
///
/// Le JSON ci-dessous est la sortie réelle de `kopia snapshot list --json`
/// pour le premier snapshot que bran ait produit lui-même, le 02/09/2026. Les
/// deux blocs disent des choses différentes du même snapshot :
///
/// ```
/// stats.fileCount   0     ← les fichiers réellement relus ce coup-ci
/// stats.cachedFiles 103   ← ceux que la déduplication a évités
/// summ.files        103   ← ce que le snapshot contient
/// ```
///
/// Préférer `stats` faisait afficher « 0 fichier » sur une sauvegarde
/// parfaitement saine — et sur toutes les sauvegardes incrémentales, c'est-à-dire
/// toutes sauf la première.
@Suite("Le nombre de fichiers ne vient pas de stats")
struct FileCountSourceTests {

    private static let dedupedSnapshot = """
    [
     {"id":"72a009b9f21f584db105c8193911d7ec","source":{"host":"mac-de-quelquun","userName":"quelquun","path":"/tmp/fixtures/musique"},"description":"","startTime":"2026-09-02T14:11:53.402512Z","endTime":"2026-09-02T14:11:54.905441Z","stats":{"totalSize":51264842,"excludedTotalSize":0,"fileCount":0,"cachedFiles":103,"nonCachedFiles":0,"dirCount":13,"excludedFileCount":0,"excludedDirCount":0,"ignoredErrorCount":0,"errorCount":0},"rootEntry":{"name":"musique","type":"d","mode":"0700","mtime":"2026-09-02T12:42:44.135100517Z","uid":501,"obj":"k58930e93320b7ba9150e39a2808bf78f","summ":{"size":51264842,"files":103,"symlinks":0,"dirs":13,"maxTime":"2026-09-02T12:42:44.135100517Z","numFailed":0}}}
    ]
    """

    @Test("Un snapshot entièrement dédupliqué contient quand même ses 103 fichiers")
    func dedupedSnapshotKeepsItsFileCount() throws {
        let proofs = try KopiaManifest.decodeSnapshotList(Data(Self.dedupedSnapshot.utf8))
        let proof = try #require(proofs.first)
        // 103, jamais 0 — c'est tout l'objet de ce test.
        #expect(proof.fileCount == 103)
        #expect(proof.dirCount == 13)
        #expect(proof.totalSize == 51_264_842)
    }

    @Test("Les deux compteurs d'erreurs continuent, eux, de venir de stats")
    func errorCountsStillComeFromStats() throws {
        // `rootEntry.summ` ne porte que `numFailed` ; la distinction entre
        // fichiers illisibles et fichiers ignorés par la politique n'existe
        // que dans `stats`, et c'est elle qui décide de `isComplete`.
        let proofs = try KopiaManifest.decodeSnapshotList(Data(Self.dedupedSnapshot.utf8))
        let proof = try #require(proofs.first)
        #expect(proof.errorCount == 0)
        #expect(proof.ignoredErrorCount == 0)
        #expect(proof.isTrustworthy)
    }
}

// MARK: - Les compteurs qui ne comptent rien

/// **Ce que ce fichier protège** : que le diagnostic d'un snapshot incomplet
/// ne tue pas l'application au moment précis où il allait servir.
///
/// `SnapshotProof.missingFileCount` vaut `errorCount + ignoredErrorCount`,
/// avec l'addition piégeante de Swift. Les deux compteurs venaient tels quels
/// d'un JSON où `Int64` accepte `9223372036854775807` sans broncher. Un
/// manifeste de `snapshot list` portant cette valeur deux fois décodait donc
/// sans erreur, puis arrêtait le processus dès que quelqu'un demandait de
/// combien de fichiers le snapshot était troué.
@Suite("Les compteurs d'un manifeste, quand ils ne décrivent aucun snapshot réel")
struct KopiaManifestCounterTests {

    private func listJSON(errorCount: String, ignoredErrorCount: String) -> Data {
        Data("""
        [{"id":"x","source":{"host":"h","userName":"u","path":"/p"},\
        "startTime":"2026-09-02T12:43:37Z","endTime":"2026-09-02T12:43:37Z",\
        "stats":{"errorCount":\(errorCount),"ignoredErrorCount":\(ignoredErrorCount)},\
        "rootEntry":{"obj":"k1","summ":{"size":10,"files":1,"dirs":1,"numFailed":0}}}]
        """.utf8)
    }

    @Test("Deux compteurs d'erreur à Int64.max sont refusés, au lieu de faire déborder l'addition")
    func overflowingErrorCountSumIsRefused() throws {
        let json = listJSON(
            errorCount: "9223372036854775807", ignoredErrorCount: "9223372036854775807"
        )
        do {
            _ = try KopiaManifest.decodeSnapshotList(json)
            Issue.record("aurait dû échouer : la somme des compteurs déborde")
        } catch let failure as KopiaDecodingFailure {
            guard case .implausibleCounter(let path, _, _) = failure else {
                Issue.record("mauvais cas : \(failure)")
                return
            }
            #expect(path == "stats.errorCount + stats.ignoredErrorCount")
        }
    }

    @Test("Un compteur d'erreur négatif est refusé, au lieu d'annoncer moins zéro fichier manquant")
    func negativeErrorCountIsRefused() throws {
        do {
            _ = try KopiaManifest.decodeSnapshotList(listJSON(errorCount: "-1", ignoredErrorCount: "0"))
            Issue.record("aurait dû échouer : compteur négatif")
        } catch let failure as KopiaDecodingFailure {
            guard case .implausibleCounter(let path, _, _) = failure else {
                Issue.record("mauvais cas : \(failure)")
                return
            }
            #expect(path == "stats.errorCount")
        }
    }

    /// Sur le chemin `create`, le compteur d'erreurs vient d'ailleurs — le
    /// refus doit nommer le champ que l'utilisateur peut réellement aller
    /// regarder dans la sortie, pas celui de l'autre commande.
    @Test("Sur un manifeste de create, le refus nomme rootEntry.summ.numFailed")
    func createPathNamesItsOwnField() throws {
        let json = Data(#"""
        {"id":"x","source":{"host":"h","userName":"u","path":"/p"},"startTime":"2026-09-02T12:43:37Z","endTime":"2026-09-02T12:43:37Z","rootEntry":{"obj":"k1","summ":{"size":10,"files":1,"dirs":1,"numFailed":-2}}}
        """#.utf8)
        do {
            _ = try KopiaManifest.decodeCreatedSnapshot(json)
            Issue.record("aurait dû échouer : numFailed négatif")
        } catch let failure as KopiaDecodingFailure {
            guard case .implausibleCounter(let path, _, _) = failure else {
                Issue.record("mauvais cas : \(failure)")
                return
            }
            #expect(path == "rootEntry.summ.numFailed")
        }
    }

    @Test("Une taille négative est refusée, au lieu de descendre jusqu'à l'affichage")
    func negativeSizeIsRefused() throws {
        let json = Data(#"""
        {"id":"x","source":{"host":"h","userName":"u","path":"/p"},"startTime":"2026-09-02T12:43:37Z","endTime":"2026-09-02T12:43:37Z","rootEntry":{"obj":"k1","summ":{"size":-1,"files":1,"dirs":1,"numFailed":0}}}
        """#.utf8)
        do {
            _ = try KopiaManifest.decodeCreatedSnapshot(json)
            Issue.record("aurait dû échouer : taille négative")
        } catch let failure as KopiaDecodingFailure {
            guard case .implausibleCounter(let path, _, _) = failure else {
                Issue.record("mauvais cas : \(failure)")
                return
            }
            #expect(path == "rootEntry.summ.size")
        }
    }

    /// La contrepartie à ne pas casser : un compteur grand mais plausible —
    /// dix mille fichiers verrouillés, cas réel de la politique « ignore read
    /// errors » de ce dépôt — doit continuer à passer, et à rendre le snapshot
    /// incomplet plutôt qu'illisible.
    @Test("Dix mille fichiers ignorés restent lisibles, et rendent le snapshot incomplet")
    func plausibleLargeCounterStillDecodes() throws {
        let proofs = try KopiaManifest.decodeSnapshotList(
            listJSON(errorCount: "0", ignoredErrorCount: "10000")
        )
        let proof = try #require(proofs.first)
        #expect(proof.ignoredErrorCount == 10_000)
        #expect(proof.missingFileCount == 10_000)
        #expect(proof.isComplete == false)
    }
}

// MARK: - Les garde-fous jamais exercés

/// **Ce que ce fichier protège** : que chaque champ déclaré obligatoire le
/// reste, et le dise avec son chemin exact.
///
/// Les tests de champ absent ne couvraient que `rootEntry.summ.size` et `id`.
/// Le scénario que ça laisse ouvert : un jour, quelqu'un remplace
/// `stats.ignoredErrorCount` par un `?? 0` — pour « simplifier » —, kopia omet
/// ce champ après avoir ignoré des fichiers, la preuve devient « complète », et
/// **tous les tests restent verts**. C'est la panne des 143 Go pour zéro
/// snapshot avec un compteur de plus : un vert qui ne prouve rien.
///
/// On ne fige donc pas les champs pour la beauté du tableau, mais ceux dont
/// l'absence changerait une décision : ce que l'écran affiche, ce que
/// `isComplete` conclut, et à quel dépôt on croit parler.
@Suite("Chaque champ obligatoire absent nomme son propre chemin")
struct KopiaManifestRequiredFieldTests {

    /// Un manifeste de `snapshot list` complet, dont chaque test retire une
    /// clé. Volontairement minimal : ce qui n'y figure pas n'est pas
    /// obligatoire, et le tableau ci-dessous le dit par construction.
    private static let completeListEntry = #"""
    [{"id":"x","source":{"host":"h","userName":"u","path":"/p"},"startTime":"2026-09-02T12:43:37Z","endTime":"2026-09-02T12:43:38Z","stats":{"errorCount":0,"ignoredErrorCount":0},"rootEntry":{"obj":"k1","summ":{"size":10,"files":1,"dirs":1,"numFailed":0}}}]
    """#

    /// Chaque paire : le fragment JSON à retirer, et le chemin que le refus
    /// doit nommer.
    @Test("Retirer une clé obligatoire d'un manifeste de liste nomme exactement ce champ", arguments: [
        (#""id":"x","#, "id"),
        (#""source":{"host":"h","userName":"u","path":"/p"},"#, "source"),
        (#""host":"h","#, "source.host"),
        (#""userName":"u","#, "source.userName"),
        (#""path":"/p""#, "source.path"),
        (#""startTime":"2026-09-02T12:43:37Z","#, "startTime"),
        (#""endTime":"2026-09-02T12:43:38Z","#, "endTime"),
        (#""errorCount":0,"#, "stats.errorCount"),
        (#""ignoredErrorCount":0"#, "stats.ignoredErrorCount"),
        (#""obj":"k1","#, "rootEntry.obj"),
        (#""summ":{"size":10,"files":1,"dirs":1,"numFailed":0}"#, "rootEntry.summ"),
        (#""size":10,"#, "rootEntry.summ.size"),
        (#""files":1,"#, "rootEntry.summ.files"),
        (#""dirs":1,"#, "rootEntry.summ.dirs"),
    ])
    func removingARequiredListFieldNamesIt(fragment: String, expectedPath: String) throws {
        let mutilated = Self.completeListEntry.replacingOccurrences(of: fragment, with: "")
        // Le fragment doit vraiment avoir disparu, sans quoi le test
        // vérifierait le décodage d'un manifeste intact.
        #expect(mutilated != Self.completeListEntry)
        do {
            _ = try KopiaManifest.decodeSnapshotList(Data(mutilated.utf8))
            Issue.record("aurait dû échouer : « \(expectedPath) » est absent")
        } catch let failure as KopiaDecodingFailure {
            guard case .missingField(let path, _) = failure else {
                Issue.record("mauvais cas pour « \(expectedPath) » : \(failure)")
                return
            }
            #expect(path == expectedPath)
        }
    }

    /// `snapshot create` n'a pas de bloc `stats` : c'est `numFailed` qui porte
    /// le compteur d'erreurs, et son absence doit être aussi fatale que celle
    /// d'`errorCount` de l'autre côté. C'est le garde-fou dont la disparition
    /// laisserait un snapshot troué se présenter comme complet.
    @Test("Retirer une clé obligatoire d'un manifeste de create nomme exactement ce champ", arguments: [
        (#""rootEntry":{"obj":"k1","summ":{"size":10,"files":1,"dirs":1,"numFailed":0}}"#, "rootEntry"),
        (#""numFailed":0"#, "rootEntry.summ.numFailed"),
        (#""summ":{"size":10,"files":1,"dirs":1,"numFailed":0}"#, "rootEntry.summ"),
    ])
    func removingARequiredCreateFieldNamesIt(fragment: String, expectedPath: String) throws {
        let complete = #"""
        {"id":"x","source":{"host":"h","userName":"u","path":"/p"},"startTime":"2026-09-02T12:43:37Z","endTime":"2026-09-02T12:43:38Z","rootEntry":{"obj":"k1","summ":{"size":10,"files":1,"dirs":1,"numFailed":0}}}
        """#
        let mutilated = complete.replacingOccurrences(of: fragment, with: "")
        #expect(mutilated != complete)
        do {
            _ = try KopiaManifest.decodeCreatedSnapshot(Data(mutilated.utf8))
            Issue.record("aurait dû échouer : « \(expectedPath) » est absent")
        } catch let failure as KopiaDecodingFailure {
            guard case .missingField(let path, _) = failure else {
                Issue.record("mauvais cas pour « \(expectedPath) » : \(failure)")
                return
            }
            #expect(path == expectedPath)
        }
    }

    /// Le statut du dépôt décide de ce à quoi on croit parler : le seau,
    /// l'endpoint, et surtout l'identité de la machine, dont `SourceCoverage`
    /// se sert pour filtrer les preuves. Un champ manquant qui se replierait
    /// sur une valeur par défaut ferait comparer les snapshots d'un autre Mac
    /// aux dossiers de celui-ci.
    @Test("Retirer une clé obligatoire du statut du dépôt nomme exactement ce champ", arguments: [
        (#""uniqueIDHex":"ac29","#, "uniqueIDHex"),
        (#""hostname":"h","#, "clientOptions.hostname"),
        (#""username":"u""#, "clientOptions.username"),
        (#""bucket":"seau","#, "storage.config.bucket"),
        (#""endpoint":"h:9000""#, "storage.config.endpoint"),
        (#""type":"s3","#, "storage.type"),
        (#""encryption":"AES256-GCM-HMAC-SHA256","#, "contentFormat.encryption"),
        (#""hash":"BLAKE2B-256-128""#, "contentFormat.hash"),
        (#""clientOptions":{"hostname":"h","username":"u"},"#, "clientOptions"),
        (#""contentFormat":{"encryption":"AES256-GCM-HMAC-SHA256","hash":"BLAKE2B-256-128"}"#, "contentFormat"),
    ])
    func removingARequiredStatusFieldNamesIt(fragment: String, expectedPath: String) throws {
        let complete = #"""
        {"uniqueIDHex":"ac29","clientOptions":{"hostname":"h","username":"u"},"storage":{"type":"s3","config":{"bucket":"seau","endpoint":"h:9000"}},"contentFormat":{"encryption":"AES256-GCM-HMAC-SHA256","hash":"BLAKE2B-256-128"}}
        """#
        let mutilated = complete.replacingOccurrences(of: fragment, with: "")
        #expect(mutilated != complete)
        do {
            _ = try KopiaManifest.decodeRepositoryStatus(Data(mutilated.utf8))
            Issue.record("aurait dû échouer : « \(expectedPath) » est absent")
        } catch let failure as KopiaDecodingFailure {
            guard case .missingField(let path, _) = failure else {
                Issue.record("mauvais cas pour « \(expectedPath) » : \(failure)")
                return
            }
            #expect(path == expectedPath)
        }
    }

    /// Les dates ne sont pas seulement obligatoires, elles doivent être
    /// lisibles : une date remplacée par `Date()` afficherait dans l'historique
    /// une heure qui n'est jamais arrivée.
    @Test("Une date présente mais illisible est un refus nommé, jamais une date inventée", arguments: [
        (#""startTime":"2026-09-02T12:43:37Z""#, #""startTime":"hier matin""#, "startTime"),
        (#""endTime":"2026-09-02T12:43:38Z""#, #""endTime":"hier soir""#, "endTime"),
    ])
    func unreadableTimestampIsNamed(original: String, replacement: String, expectedPath: String) throws {
        let complete = #"""
        {"id":"x","source":{"host":"h","userName":"u","path":"/p"},"startTime":"2026-09-02T12:43:37Z","endTime":"2026-09-02T12:43:38Z","rootEntry":{"obj":"k1","summ":{"size":10,"files":1,"dirs":1,"numFailed":0}}}
        """#
        let mutilated = complete.replacingOccurrences(of: original, with: replacement)
        #expect(mutilated != complete)
        do {
            _ = try KopiaManifest.decodeCreatedSnapshot(Data(mutilated.utf8))
            Issue.record("aurait dû échouer : « \(expectedPath) » est illisible")
        } catch let failure as KopiaDecodingFailure {
            guard case .unparsableTimestamp(let path, _) = failure else {
                Issue.record("mauvais cas pour « \(expectedPath) » : \(failure)")
                return
            }
            #expect(path == expectedPath)
        }
    }
}
