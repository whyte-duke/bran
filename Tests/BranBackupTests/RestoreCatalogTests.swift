import Foundation
import Testing
@testable import BranBackup

/// Ce que ce fichier protège : que `RestoreCatalog` lise le parcours d'un
/// snapshot exactement comme kopia 0.23.1 l'écrit — pas comme on imagine
/// qu'il pourrait l'écrire — et que ses trois pièges mesurés restent fermés :
/// une taille de fichier absente qui veut dire zéro (jamais « inconnu »), un
/// identifiant d'objet qui peut se répéter entre deux entrées d'un même
/// dossier (donc impropre à servir d'identité de liste), et une restauration
/// qui ne peut jamais s'annoncer terminée sans avoir vu la ligne finale de
/// kopia. Les échantillons JSON et les lignes de progression viennent de
/// sorties réelles de `kopia show`/`kopia restore` 0.23.1, relevées le
/// 02/09/2026 sur le dépôt du propriétaire — reproduites ici littéralement,
/// sauf mention contraire.

// MARK: - Le décodage de `kopia show`

@Suite("Le décodage d'un dossier de snapshot")
struct RestoreCatalogDecodingTests {

    /// Capture verbatim de `kopia show k58930e93320b7ba9150e39a2808bf78f`
    /// (la racine du snapshot `Music` de ce dépôt), 02/09/2026.
    static let musicRootJSON = """
    {"stream":"kopia:directory","entries":[{"name":"Music","type":"d","mode":"0755","mtime":"2025-09-05T16:46:21.616375199Z","uid":501,"gid":20,"obj":"k02a9b0ce86f817c52eb9df017d84149d","summ":{"size":51264842,"files":102,"symlinks":0,"dirs":12,"maxTime":"2026-09-02T12:42:44.135100517Z","numFailed":0}},{"name":".localized","type":"f","mode":"0644","mtime":"2025-08-25T14:25:11.647535Z","uid":501,"gid":20,"obj":"48dbd261f5877b7144f240baa6457f1c"}],"summary":{"size":51264842,"files":103,"symlinks":0,"dirs":13,"maxTime":"2026-09-02T12:42:44.135100517Z","numFailed":0}}
    """

    @Test("Un dossier réel se décode entièrement : deux entrées, un genre chacune, la synthèse en tête")
    func decodesRealDirectory() throws {
        let listing = try RestoreCatalog.decodeDirectoryListing(Data(Self.musicRootJSON.utf8))

        #expect(listing.entries.count == 2)
        #expect(listing.summary.totalSize == 51264842)
        #expect(listing.summary.fileCount == 103)
        #expect(listing.summary.dirCount == 13)
        #expect(listing.summary.failedCount == 0)
        #expect(listing.summary.lastModified != nil)

        let directory = try #require(listing.entries.first { $0.name == "Music" })
        #expect(directory.kind == .directory)
        #expect(directory.isDirectory)
        #expect(directory.objectID == "k02a9b0ce86f817c52eb9df017d84149d")
        #expect(directory.fileSize == nil)
        #expect(directory.directorySummary?.totalSize == 51264842)
        #expect(directory.directorySummary?.fileCount == 102)

        let file = try #require(listing.entries.first { $0.name == ".localized" })
        #expect(file.kind == .file)
        #expect(!file.isDirectory)
        #expect(file.directorySummary == nil)
    }

    @Test("Un fichier de zéro octet omet la clé « size » — et ça se lit comme un zéro, pas comme une absence")
    func omittedSizeMeansZero() throws {
        let listing = try RestoreCatalog.decodeDirectoryListing(Data(Self.musicRootJSON.utf8))
        let file = try #require(listing.entries.first { $0.name == ".localized" })
        // Vérifié en comparant deux sorties réelles distinctes : un fichier
        // de 0 octet (celui-ci) omet totalement la clé JSON, un fichier non
        // vide la porte toujours (test suivant). `fileSize` doit donc valoir
        // 0 ici, jamais `nil` — `nil` est réservé aux dossiers, dont la
        // taille vit ailleurs (`directorySummary`).
        #expect(file.fileSize == 0)
    }

    /// Fragment réel de `kopia show k70d5c99a8a9da89c0c2fbb0b5ad22349`
    /// (dossier `claude/gstack` d'un autre snapshot), 02/09/2026 : un fichier
    /// non vide porte bien sa taille. Assemblé avec un `summary` minimal pour
    /// isoler ce seul comportement dans un document autonome — le fragment
    /// d'entrée lui-même n'a pas été modifié.
    static let nonEmptyFileJSON = """
    {"stream":"kopia:directory","entries":[\
    {"name":".env.example","type":"f","mode":"0644","size":171,"mtime":"2026-03-21T11:25:24.817855291Z","uid":501,"gid":20,"obj":"9079f3485cbdbae753a4961966090141"}\
    ],"summary":{"size":171,"files":1,"symlinks":0,"dirs":0,"maxTime":"2026-03-21T11:25:24.817855291Z","numFailed":0}}
    """

    @Test("Un fichier non vide porte toujours sa taille — le zéro du test précédent n'est pas une coïncidence de décodage")
    func presentSizeIsRead() throws {
        let listing = try RestoreCatalog.decodeDirectoryListing(Data(Self.nonEmptyFileJSON.utf8))
        let file = try #require(listing.entries.first)
        #expect(file.fileSize == 171)
    }

    @Test("Un type d'entrée inconnu ne fait pas échouer tout le dossier — il tombe dans .other, le reste se lit")
    func unknownEntryTypeSurvives() throws {
        let json = """
        {"stream":"kopia:directory","entries":[\
        {"name":"pipe-nomme","type":"p","mode":"0644","mtime":"2026-01-01T00:00:00Z","uid":501,"gid":20,"obj":"deadbeef"}\
        ],"summary":{"size":0,"files":0,"symlinks":0,"dirs":0,"numFailed":0}}
        """
        let listing = try RestoreCatalog.decodeDirectoryListing(Data(json.utf8))
        let entry = try #require(listing.entries.first)
        #expect(entry.kind == .other("p"))
        #expect(!entry.isDirectory)
    }

    @Test("Une entrée « summary » sans « maxTime » n'est pas une erreur — un dossier vide n'a rien dont tirer un maximum")
    func absentMaxTimeIsTolerated() throws {
        let json = """
        {"stream":"kopia:directory","entries":[],"summary":{"size":0,"files":0,"symlinks":0,"dirs":0,"numFailed":0}}
        """
        let listing = try RestoreCatalog.decodeDirectoryListing(Data(json.utf8))
        #expect(listing.entries.isEmpty)
        #expect(listing.summary.lastModified == nil)
    }
}

@Suite("Les refus nommés du décodage — jamais un dossier à moitié rempli")
struct RestoreCatalogDecodingFailureTests {

    @Test("Une sortie vide est un échec nommé, pas un dossier vide")
    func emptyOutputFails() throws {
        do {
            _ = try RestoreCatalog.decodeDirectoryListing(Data())
            Issue.record("aurait dû échouer : sortie vide")
        } catch let failure as KopiaDecodingFailure {
            guard case .emptyOutput = failure else {
                Issue.record("mauvais cas : \(failure)")
                return
            }
        }
    }

    @Test("Un JSON tronqué (kopia tué en plein `show`) échoue nommément, jamais un dossier partiel silencieux")
    func truncatedJSONFails() throws {
        let truncated = """
        {"stream":"kopia:directory","entries":[{"name":"a","type":"f","mode":"0644","mtime":"2026
        """
        do {
            _ = try RestoreCatalog.decodeDirectoryListing(Data(truncated.utf8))
            Issue.record("aurait dû échouer : JSON coupé en plein milieu")
        } catch is KopiaDecodingFailure {
            // Nommée, et c'est tout ce qu'on demande : jamais un dossier
            // partiel construit sur une ligne incomplète.
        }
    }

    @Test("« show » appelé sur un objet qui n'est pas un dossier (mauvais stream) est refusé, pas interprété comme vide")
    func wrongStreamFails() throws {
        let json = """
        {"stream":"kopia:file","entries":[],"summary":{"size":0,"files":0,"symlinks":0,"dirs":0,"numFailed":0}}
        """
        do {
            _ = try RestoreCatalog.decodeDirectoryListing(Data(json.utf8))
            Issue.record("aurait dû échouer : stream n'est pas « kopia:directory »")
        } catch let failure as KopiaDecodingFailure {
            guard case .missingField(let path, _) = failure else {
                Issue.record("mauvais cas : \(failure)")
                return
            }
            #expect(path == "stream")
        }
    }

    @Test("Un dossier sans son bloc « summ » échoue — jamais une taille de zéro inventée pour un sous-dossier")
    func missingDirectorySummaryFails() throws {
        let json = """
        {"stream":"kopia:directory","entries":[\
        {"name":"sous-dossier","type":"d","mode":"0755","mtime":"2026-01-01T00:00:00Z","uid":501,"gid":20,"obj":"kabc"}\
        ],"summary":{"size":0,"files":0,"symlinks":0,"dirs":1,"numFailed":0}}
        """
        do {
            _ = try RestoreCatalog.decodeDirectoryListing(Data(json.utf8))
            Issue.record("aurait dû échouer : entries[].summ absent sur un dossier")
        } catch let failure as KopiaDecodingFailure {
            guard case .missingField(let path, _) = failure else {
                Issue.record("mauvais cas : \(failure)")
                return
            }
            #expect(path == "entries[sous-dossier].summ")
        }
    }

    @Test("« numFailed » absent du résumé échoue — jamais un zéro par défaut sur un compteur d'échecs")
    func missingNumFailedFails() throws {
        let json = """
        {"stream":"kopia:directory","entries":[],"summary":{"size":0,"files":0,"symlinks":0,"dirs":0}}
        """
        do {
            _ = try RestoreCatalog.decodeDirectoryListing(Data(json.utf8))
            Issue.record("aurait dû échouer : summary.numFailed absent")
        } catch let failure as KopiaDecodingFailure {
            guard case .missingField(let path, _) = failure else {
                Issue.record("mauvais cas : \(failure)")
                return
            }
            #expect(path == "summary.numFailed")
        }
    }
}

// MARK: - La navigation

@Suite("La navigation dans un snapshot")
struct RestoreLocationTests {

    @Test("À la racine, le chemin affiché est vide et l'objet courant est celui du snapshot")
    func rootLocation() {
        let location = RestoreLocation(snapshotID: "816c623c78cd713c659482b16180efb1", rootObjectID: "k58930e93320b7ba9150e39a2808bf78f")
        #expect(location.isAtRoot)
        #expect(location.displayPath == "")
        #expect(location.currentObjectID == "k58930e93320b7ba9150e39a2808bf78f")
    }

    @Test("Descendre dans un dossier ajoute un cran au fil d'Ariane et change l'objet courant")
    func descendingIntoDirectory() throws {
        let location = RestoreLocation(snapshotID: "s", rootObjectID: "root")
        let entry = RestoreEntry(
            name: "Music", kind: .directory, objectID: "k02a9b0ce86f817c52eb9df017d84149d",
            modifiedAt: Date(), posixMode: "0755", ownerUID: 501, ownerGID: 20,
            fileSize: nil, directorySummary: RestoreDirectorySummary(
                totalSize: 51264842, fileCount: 102, dirCount: 12, symlinkCount: 0, failedCount: 0, lastModified: nil
            )
        )
        let deeper = try location.descending(into: entry)
        #expect(!deeper.isAtRoot)
        #expect(deeper.displayPath == "Music")
        #expect(deeper.currentObjectID == "k02a9b0ce86f817c52eb9df017d84149d")
        // La racine d'origine, elle, n'a pas changé — `descending` rend un
        // nouvel emplacement, il ne mute rien en place.
        #expect(location.isAtRoot)
    }

    @Test("Descendre dans un fichier est refusé — jamais un emplacement qui pointerait sur du vide")
    func descendingIntoFileFails() throws {
        let location = RestoreLocation(snapshotID: "s", rootObjectID: "root")
        let file = RestoreEntry(
            name: ".localized", kind: .file, objectID: "48dbd261f5877b7144f240baa6457f1c",
            modifiedAt: Date(), posixMode: "0644", ownerUID: 501, ownerGID: 20,
            fileSize: 0, directorySummary: nil
        )
        do {
            _ = try location.descending(into: file)
            Issue.record("aurait dû échouer : « .localized » est un fichier, pas un dossier")
        } catch let failure as RestoreNavigationFailure {
            guard case .notADirectory(let name) = failure else {
                Issue.record("mauvais cas : \(failure)")
                return
            }
            #expect(name == ".localized")
        }
    }

    @Test("Remonter au-delà de la racine s'arrête à la racine — remonter trop n'est pas une erreur")
    func ascendingPastRootStopsAtRoot() {
        let location = RestoreLocation(
            snapshotID: "s", rootObjectID: "root",
            breadcrumb: [RestoreBreadcrumb(name: "Music", objectID: "k1")]
        )
        let tooFar = location.ascending(levels: 5)
        #expect(tooFar.isAtRoot)
        #expect(tooFar.currentObjectID == "root")
    }

    @Test("Deux entrées vides d'un même dossier peuvent partager un identifiant d'objet — le nom reste l'identité")
    func duplicateObjectIDsDoNotCollideByName() {
        // Cas réel de ce dépôt : plusieurs fichiers `.localized` de 0 octet à
        // des endroits différents partagent le même identifiant d'objet
        // (`48dbd261f5877b7144f240baa6457f1c`), parce que kopia adresse le
        // contenu, pas l'emplacement. `RestoreEntry.id` doit rester distinct
        // pour deux telles entrées d'un même dossier.
        let a = RestoreEntry(
            name: "premier.vide", kind: .file, objectID: "48dbd261f5877b7144f240baa6457f1c",
            modifiedAt: Date(), posixMode: "0644", ownerUID: nil, ownerGID: nil, fileSize: 0, directorySummary: nil
        )
        let b = RestoreEntry(
            name: "second.vide", kind: .file, objectID: "48dbd261f5877b7144f240baa6457f1c",
            modifiedAt: Date(), posixMode: "0644", ownerUID: nil, ownerGID: nil, fileSize: 0, directorySummary: nil
        )
        #expect(a.objectID == b.objectID)
        #expect(a.id != b.id)
    }
}

// MARK: - La progression d'une restauration

@Suite("La lecture de la progression de « kopia restore »")
struct RestoreProgressReaderTests {

    @Test("La forme sans débit se lit : compte et volumes, rien d'inventé pour le reste")
    func parsesEarlyForm() {
        let event = RestoreProgressReader.parse(line: "Processed 6 (33.3 KB) of 12 (2.6 MB).")
        guard case .progress(let progress) = event else {
            Issue.record("attendu un événement de progression")
            return
        }
        #expect(progress.processedEntries == 6)
        #expect(progress.processedBytes == 33_300)
        #expect(progress.totalEntries == 12)
        #expect(progress.totalBytes == 2_600_000)
        #expect(progress.throughputBytesPerSecond == nil)
        #expect(progress.secondsRemaining == nil)
    }

    @Test("La forme enrichie porte le débit, le temps restant, et la fraction s'en déduit")
    func parsesRichForm() throws {
        let event = RestoreProgressReader.parse(
            line: "Processed 11 (0.9 MB) of 12 (2.6 MB) 752.9 KB/s (35.4%) remaining 1s."
        )
        guard case .progress(let progress) = event else {
            Issue.record("attendu un événement de progression")
            return
        }
        #expect(progress.throughputBytesPerSecond == 752_900)
        #expect(progress.secondsRemaining == 1)
        let fraction = try #require(progress.fraction)
        #expect(fraction > 0.3 && fraction < 0.4)
    }

    @Test("Un temps restant à plusieurs composantes (« 12m54s ») se lit entièrement")
    func parsesCompositeDuration() {
        let event = RestoreProgressReader.parse(
            line: "Processed 1596 (5.1 MB) of 30146 (3.9 GB) 5 MB/s (0.1%) remaining 12m54s."
        )
        guard case .progress(let progress) = event else {
            Issue.record("attendu un événement de progression")
            return
        }
        // `TimeInterval(...)` explicite, et ce n'est pas de la cérémonie : la
        // même assertion écrite `== 12 * 60 + 54` échoue, alors que le parseur
        // rend bien 774,0 — vérifié en imprimant la valeur. L'expression
        // entière s'infère en `Int` et la comparaison avec un `Double?` part de
        // travers dans l'expansion de la macro. Nommer le type coûte huit
        // caractères et supprime un faux échec qui aurait fait douter du
        // parseur plutôt que de l'assertion.
        #expect(progress.secondsRemaining == TimeInterval(12 * 60 + 54))
    }

    @Test("La ligne finale « Restored … » se lit comme la confirmation de fin, pas comme une ligne de progression")
    func parsesCompletionLine() {
        let event = RestoreProgressReader.parse(
            line: "Restored 9 files, 4 directories and 0 symbolic links (2.6 MB)."
        )
        guard case .completed(let summary) = event else {
            Issue.record("attendu un événement de fin")
            return
        }
        #expect(summary.restoredFiles == 9)
        #expect(summary.restoredDirectories == 4)
        #expect(summary.restoredSymlinks == 0)
        #expect(summary.restoredBytes == 2_600_000)
    }

    @Test("La bannière « Restoring to … » n'est ni une progression ni une fin — elle ne produit aucun événement")
    func bannerLineProducesNoEvent() {
        #expect(RestoreProgressReader.parse(line: "Restoring to local filesystem (/tmp/x) with parallelism=8...") == nil)
    }

    @Test("Un flux réel, livré en plusieurs paquets coupés au milieu d'un nombre, se reconstitue sans rien perdre")
    func reassemblesRealStreamAcrossChunks() {
        // Capture verbatim (bytes réels, `\r`/`\n` compris) d'une restauration
        // de 2,6 Mo / 12 fichiers, 02/09/2026 — coupée ici en deux paquets
        // arbitraires, au milieu de « 752.9 KB/s », pour simuler ce qu'un
        // `Process` livre vraiment : jamais aligné sur une frontière de ligne.
        let full =
            "Restoring to local filesystem (/private/tmp/bran_restore_probe8_39574) with parallelism=8...\n"
            + "\rProcessed 6 (33.3 KB) of 12 (2.6 MB).\rProcessed 9 (441.8 KB) of 12 (2.6 MB)."
            + "\rProcessed 11 (0.9 MB) of 12 (2.6 MB) 752.9 KB/s (35.4%) remaining 1s."
            + "\rProcessed 13 (2.6 MB) of 12 (2.6 MB) 2 MB/s (100.0%) remaining 0s.\n"
            + "Restored 9 files, 4 directories and 0 symbolic links (2.6 MB).\n\n"
        let splitPoint = full.range(of: "752.9 K")!.upperBound
        let firstChunk = String(full[full.startIndex..<splitPoint])
        let secondChunk = String(full[splitPoint...])

        var reader = RestoreProgressReader()
        let firstEvents = reader.accept(firstChunk)
        let secondEvents = reader.accept(secondChunk)
        let allEvents = firstEvents + secondEvents

        let progressCount = allEvents.reduce(into: 0) { count, event in
            if case .progress = event { count += 1 }
        }
        #expect(progressCount == 4)

        var completions: [RestoreSummary] = []
        for event in allEvents {
            if case .completed(let summary) = event { completions.append(summary) }
        }
        #expect(completions.count == 1)
        #expect(completions.first?.restoredFiles == 9)
    }

    @Test("Une restauration tuée en plein milieu ne produit jamais d'événement de fin — c'est tout le point")
    func killedRunNeverConfirmsCompletion() {
        // Capture verbatim (structure réelle : mêmes séparateurs `\r`,
        // absence de ligne finale) d'un `kopia restore` terminé par SIGTERM
        // au milieu d'une restauration de 3,9 Go, 02/09/2026 — le processus
        // s'est arrêté après la quatrième ligne de progression, sans jamais
        // écrire « Restored … ».
        let partial =
            "Restoring to local filesystem (/private/tmp/bran_restore_kill_39647) with parallelism=8...\n"
            + "\rProcessed 1536 (2.6 MB) of 30146 (3.9 GB)."
            + "\rProcessed 1570 (2.9 MB) of 30146 (3.9 GB)."
            + "\rProcessed 1596 (5.1 MB) of 30146 (3.9 GB) 5 MB/s (0.1%) remaining 12m54s."
            + "\rProcessed 1615 (5.1 MB) of 30146 (3.9 GB) 3.8 MB/s (0.1%) remaining 16m59s."

        var reader = RestoreProgressReader()
        let events = reader.accept(partial)

        let hasCompletion = events.contains { event in
            if case .completed = event { return true }
            return false
        }
        #expect(!hasCompletion)

        // La dernière ligne de progression reste dans le tampon interne tant
        // qu'aucun séparateur ne l'a close (`\r` ou `\n` suivant, jamais
        // arrivé ici) — même si on force sa clôture après coup, ce doit
        // rester une ligne de progression, jamais une confirmation de fin
        // inventée à partir d'un flux coupé.
        let finalEvents = reader.accept("\n")
        let finalHasCompletion = finalEvents.contains { event in
            if case .completed = event { return true }
            return false
        }
        #expect(!finalHasCompletion)
    }

    @Test("Une ligne dont le total dépasse le compte annoncé au départ reste lisible — ce n'est qu'une estimation")
    func processedCanExceedAnnouncedTotal() {
        // Vu tel quel : « Processed 13 … of 12 … » — le total initial de 12
        // était une estimation, corrigée en cours de route.
        let event = RestoreProgressReader.parse(line: "Processed 13 (2.6 MB) of 12 (2.6 MB) 2 MB/s (100.0%) remaining 0s.")
        guard case .progress(let progress) = event else {
            Issue.record("attendu un événement de progression")
            return
        }
        #expect(progress.processedEntries == 13)
        #expect(progress.totalEntries == 12)
        // La fraction reste bornée à 1 malgré le dépassement.
        #expect(progress.fraction == 1)
    }
}

// MARK: - L'écrasement

@Suite("La politique d'écrasement")
struct RestoreOverwritePolicyTests {

    @Test("Le mode sans écrasement passe les trois drapeaux « --no-overwrite-* », rien de plus")
    func refuseFlags() {
        #expect(RestoreOverwritePolicy.refuseIfNotEmpty.kopiaFlags == [
            "--no-overwrite-files", "--no-overwrite-directories", "--no-overwrite-symlinks",
        ])
    }

    @Test("Le mode d'écrasement explicite passe les trois drapeaux « --overwrite-* », jamais « --skip-existing »")
    func overwriteFlags() {
        let flags = RestoreOverwritePolicy.overwriteExisting.kopiaFlags
        #expect(flags == ["--overwrite-files", "--overwrite-directories", "--overwrite-symlinks"])
        // Mesuré : `--skip-existing` ne fait pas ce que son aide promet — voir
        // la doc de `RestoreOverwritePolicy`. Il ne doit jamais apparaître.
        #expect(!flags.contains("--skip-existing"))
    }
}

// MARK: - La garde de destination

@Suite("La garde de destination, avant tout lancement de kopia")
struct RestoreDestinationValidationTests {

    @Test("Un dossier vide, avec assez de place, ne pose aucun problème")
    func emptyDestinationWithSpacePasses() {
        let facts = RestoreDestinationFacts(exists: true, isDirectory: true, isWritable: true, isEmpty: true, availableBytes: 1_000_000_000)
        let problems = RestoreCatalog.validateDestination(facts, requiredBytes: 500_000_000, overwrite: .refuseIfNotEmpty)
        #expect(problems.isEmpty)
    }

    @Test("Un dossier non vide est refusé sans écrasement explicite")
    func nonEmptyDestinationIsRefusedWithoutOverwrite() {
        let facts = RestoreDestinationFacts(exists: true, isDirectory: true, isWritable: true, isEmpty: false, availableBytes: 1_000_000_000)
        let problems = RestoreCatalog.validateDestination(facts, requiredBytes: 1_000, overwrite: .refuseIfNotEmpty)
        #expect(problems.contains { if case .notEmpty = $0 { true } else { false } })
    }

    @Test("Le même dossier non vide est accepté quand l'écrasement est explicitement choisi")
    func nonEmptyDestinationIsAcceptedWithOverwrite() {
        let facts = RestoreDestinationFacts(exists: true, isDirectory: true, isWritable: true, isEmpty: false, availableBytes: 1_000_000_000)
        let problems = RestoreCatalog.validateDestination(facts, requiredBytes: 1_000, overwrite: .overwriteExisting)
        #expect(problems.isEmpty)
    }

    @Test("Restaurer 400 Go dans un volume qui en offre 12 échoue ici, avant tout octet écrit")
    func insufficientSpaceIsCaughtBeforeStarting() {
        let facts = RestoreDestinationFacts(exists: true, isDirectory: true, isWritable: true, isEmpty: true, availableBytes: 12_000_000_000)
        let problems = RestoreCatalog.validateDestination(facts, requiredBytes: 400_000_000_000, overwrite: .refuseIfNotEmpty)
        #expect(problems.contains { if case .insufficientSpace = $0 { true } else { false } })
    }

    @Test("Une marge de sécurité s'ajoute au volume requis — tout juste assez ne suffit pas")
    func marginIsApplied() {
        let facts = RestoreDestinationFacts(exists: true, isDirectory: true, isWritable: true, isEmpty: true, availableBytes: 1_000)
        let problems = RestoreCatalog.validateDestination(facts, requiredBytes: 1_000, overwrite: .refuseIfNotEmpty)
        #expect(problems.contains { if case .insufficientSpace = $0 { true } else { false } })
    }

    @Test("Une place disponible qu'on n'a pas su mesurer est un problème nommé, jamais une hypothèse optimiste")
    func unknownSpaceIsNamedAsAProblem() {
        let facts = RestoreDestinationFacts(exists: true, isDirectory: true, isWritable: true, isEmpty: true, availableBytes: nil)
        let problems = RestoreCatalog.validateDestination(facts, requiredBytes: 1, overwrite: .refuseIfNotEmpty)
        #expect(problems.contains { if case .unknownFreeSpace = $0 { true } else { false } })
    }

    @Test("Une destination non inscriptible est refusée même si elle est vide et qu'il y a de la place")
    func notWritableIsRefused() {
        let facts = RestoreDestinationFacts(exists: true, isDirectory: true, isWritable: false, isEmpty: true, availableBytes: 1_000_000_000)
        let problems = RestoreCatalog.validateDestination(facts, requiredBytes: 1, overwrite: .refuseIfNotEmpty)
        #expect(problems.contains { if case .notWritable = $0 { true } else { false } })
    }

    @Test("Une destination qui existe déjà en tant que fichier est refusée")
    func destinationIsAFileIsRefused() {
        let facts = RestoreDestinationFacts(exists: true, isDirectory: false, isWritable: true, isEmpty: nil, availableBytes: 1_000_000_000)
        let problems = RestoreCatalog.validateDestination(facts, requiredBytes: 1, overwrite: .refuseIfNotEmpty)
        #expect(problems.contains { if case .pathIsAFile = $0 { true } else { false } })
    }

    @Test("Une destination qui n'existe pas encore n'est pas refusée pour absence de contenu — kopia la créera")
    func nonExistentDestinationIsNotRefusedForEmptiness() {
        let facts = RestoreDestinationFacts(exists: false, isDirectory: false, isWritable: true, isEmpty: nil, availableBytes: 1_000_000_000)
        let problems = RestoreCatalog.validateDestination(facts, requiredBytes: 1_000, overwrite: .refuseIfNotEmpty)
        #expect(problems.isEmpty)
    }
}
