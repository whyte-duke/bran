import Foundation
import Testing
@testable import BranCore

// MARK: - Le contenu de laboratoire
//
// Un type d'entrée neutre plutôt que `SnippetEntry` ou `TranscriptEntry` : ces
// deux-là vivent dans `BranVision` et `BranSpeech`, et tester la générique à
// travers l'un d'eux ferait passer les tests de la mécanique de rangement pour
// des tests de la capture ou de la dictée. `Note` n'a que ce que
// `ContentEntry` exige, plus un champ optionnel ajouté « après coup » pour le
// test de compatibilité descendante.

private struct Note: ContentEntry, Equatable {
    var id = UUID()
    var createdAt: Date
    var text: String
    var blobFileName: String?

    /// Le champ qui n'existait pas dans la première version du format.
    var tag: String?
}

/// Purge le fichier lourd au-delà d'un âge, et seulement lui — la forme exacte
/// de `SnapshotRetention` et de `RetentionPolicy`, comparaison sur `>=`
/// comprise.
private struct BlobAge: ContentRetentionPolicy {
    var lifetime: TimeInterval

    func entriesToPurge(from entries: [Note], now: Date) -> [Note] {
        entries.filter { entry in
            guard entry.blobFileName != nil else { return false }
            return now.timeIntervalSince(entry.createdAt) >= lifetime
        }
    }

    func expiryDate(for entry: Note) -> Date {
        entry.createdAt.addingTimeInterval(lifetime)
    }
}

/// Purge l'entrée entière au-delà d'un âge, qu'elle porte un fichier ou non.
/// C'est la seconde famille que la générique doit savoir servir sans que la
/// première change de comportement.
private struct EntryAge: ContentRetentionPolicy {
    var lifetime: TimeInterval

    func entriesToPurge(from entries: [Note], now: Date) -> [Note] {
        entries.filter { now.timeIntervalSince($0.createdAt) >= lifetime }
    }

    func expiryDate(for entry: Note) -> Date {
        entry.createdAt.addingTimeInterval(lifetime)
    }
}

/// Une racine que l'on peut déplacer en cours de route, comme le font les
/// réglages quand on change le dossier de destination.
@MainActor
private final class Root {
    var url: URL
    init(_ url: URL) { self.url = url }
}

@Suite("Bibliothèque sur disque")
@MainActor
struct ContentStoreTests {

    private static let epoch = Date(timeIntervalSince1970: 1_800_000_000)
    private static let day: TimeInterval = 86_400

    // MARK: - Échafaudage

    private func makeRoot() throws -> URL {
        let url = URL.temporaryDirectory
            .appending(path: "ContentStoreTests", directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeShape(
        purge: ContentPurge = .blobOnly,
        blobFailureMessage: String? = "Fichier non conservé"
    ) -> ContentShape {
        ContentShape(
            folderName: "Notes",
            blobExtension: "bin",
            purge: purge,
            inaccessibleFolderMessage: "Dossier des notes inaccessible",
            blobFailureMessage: blobFailureMessage
        )
    }

    private func makeStore(
        root: URL,
        purge: ContentPurge = .blobOnly,
        blobFailureMessage: String? = "Fichier non conservé",
        lifetime: TimeInterval = 7 * ContentStoreTests.day
    ) -> ContentStore<Note> {
        ContentStore(
            root: { root },
            shape: makeShape(purge: purge, blobFailureMessage: blobFailureMessage),
            retention: BlobAge(lifetime: lifetime)
        )
    }

    private func note(daysAgo: Double, text: String = "bonjour") -> Note {
        Note(createdAt: Self.epoch.addingTimeInterval(-daysAgo * Self.day), text: text)
    }

    /// Un écrivain de fichier lourd qui, comme les vrais, crée son dossier
    /// parent : c'est le contrat de `ContentBlobWriter`.
    private func writer(bytes: Int) -> ContentBlobWriter {
        { url in
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(repeating: 0x41, count: bytes).write(to: url, options: .atomic)
        }
    }

    private var failingWriter: ContentBlobWriter {
        { _ in throw CocoaError(.fileWriteUnknown) }
    }

    /// Le sidecar d'un fichier lourd, retrouvé comme le store le retrouve :
    /// même nom, extension différente. C'est ce qui permet à un test de casser
    /// exactement une moitié de la paire.
    private func sidecar(of blob: URL) -> URL {
        blob.deletingPathExtension().appendingPathExtension("json")
    }

    private func names(in folder: URL) -> [String] {
        let found = try? FileManager.default.contentsOfDirectory(
            atPath: folder.path(percentEncoded: false)
        )
        return (found ?? []).sorted()
    }

    // MARK: - Lecture

    @Test("Un dossier absent est un premier lancement, pas un problème")
    func emptyFolderIsNotAProblem() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = makeStore(root: root)
        await store.reload()

        #expect(store.entries.isEmpty)
        #expect(store.problem == nil)
        #expect(store.blobBytes == 0)
    }

    /// Un volume démonté, des droits retirés, un chemin devenu un fichier : la
    /// bibliothèque doit le **dire**. Une liste vide ressemble à une perte de
    /// données, et on cherche alors le problème là où il n'est pas.
    @Test("Un dossier illisible se dit au lieu de rendre une liste vide")
    func unreadableFolderIsReported() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        // Un fichier là où le dossier devrait être : `createDirectory` échoue.
        try Data("pas un dossier".utf8).write(to: root.appending(path: "Notes"))

        let store = makeStore(root: root)
        await store.reload()

        #expect(store.entries.isEmpty)
        #expect(store.problem?.hasPrefix("Dossier des notes inaccessible : ") == true)
    }

    @Test("Les entrées reviennent de la plus récente à la plus ancienne")
    func entriesComeBackNewestFirst() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let writing = makeStore(root: root)
        await writing.save(note(daysAgo: 3, text: "avant-hier"))
        await writing.save(note(daysAgo: 10, text: "il y a longtemps"))
        await writing.save(note(daysAgo: 1, text: "hier"))

        let reading = makeStore(root: root)
        await reading.reload()

        #expect(reading.entries.map(\.text) == ["hier", "avant-hier", "il y a longtemps"])
    }

    /// La leçon de `RecordingMetadata.segmentCount`, transformée en test pour la
    /// générique : le `Decodable` synthétisé ignore les valeurs par défaut, et
    /// `reload()` avale les échecs de décodage. Un champ non optionnel ajouté au
    /// format effacerait l'historique sans un seul message.
    @Test("Un sidecar écrit par une version antérieure reste lisible")
    func legacySidecarStillDecodes() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let folder = root.appending(path: "Notes", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let legacy = """
        {
          "id": "9F2B4C1E-0000-4000-8000-000000000001",
          "createdAt": 771000000,
          "text": "écrit par la version d'avant"
        }
        """
        try Data(legacy.utf8).write(to: folder.appending(path: "ancien.json"))

        let store = makeStore(root: root)
        await store.reload()

        #expect(store.entries.count == 1)
        #expect(store.entries.first?.text == "écrit par la version d'avant")
        #expect(store.entries.first?.tag == nil)
        #expect(store.entries.first?.blobFileName == nil)
        #expect(store.problem == nil)
    }

    @Test("Un sidecar illisible est ignoré sans emporter le reste du dossier")
    func brokenSidecarIsSkipped() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let writing = makeStore(root: root)
        await writing.save(note(daysAgo: 1, text: "intacte"))

        let folder = writing.folder
        try Data("{ ceci n'est pas du JSON".utf8).write(to: folder.appending(path: "cassé.json"))

        let reading = makeStore(root: root)
        await reading.reload()

        #expect(reading.entries.map(\.text) == ["intacte"])
        #expect(reading.problem == nil)
    }

    /// **Un fichier manquant est un état à afficher, pas un défaut à
    /// prévenir.** Supprimer le fichier lourd dans le Finder doit rendre
    /// l'entrée non-relisable, pas la faire disparaître ni planter au clic.
    @Test("Un fichier lourd supprimé à la main laisse l'entrée en vie, sans fichier")
    func missingBlobIsTolerated() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let writing = makeStore(root: root)
        await writing.save(note(daysAgo: 1), blob: writer(bytes: 32))
        let saved = try #require(writing.entries.first)
        let blob = try #require(writing.blobURL(for: saved))

        try FileManager.default.removeItem(at: blob)

        let reading = makeStore(root: root)
        await reading.reload()

        let reread = try #require(reading.entries.first)
        #expect(reading.entries.count == 1)
        #expect(reread.blobFileName == nil)
        #expect(reading.blobURL(for: reread) == nil)
        #expect(reading.blobBytes == 0)
        #expect(reading.problem == nil)
    }

    @Test("Seuls les fichiers lourds sont comptés, jamais les sidecars")
    func onlyBlobsAreWeighed() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let writing = makeStore(root: root)
        await writing.save(note(daysAgo: 1), blob: writer(bytes: 100))
        await writing.save(note(daysAgo: 2), blob: writer(bytes: 40))
        await writing.save(note(daysAgo: 3))

        #expect(writing.blobBytes == 140)

        let reading = makeStore(root: root)
        await reading.reload()
        #expect(reading.blobBytes == 140)
    }

    // MARK: - Écriture

    @Test("Une entrée enregistrée se relit depuis le dossier")
    func savedEntrySurvivesAReload() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let writing = makeStore(root: root)
        await writing.save(note(daysAgo: 1, text: "à relire"), blob: writer(bytes: 8))

        let reading = makeStore(root: root)
        await reading.reload()

        #expect(reading.entries.count == 1)
        #expect(reading.entries.first?.text == "à relire")
        #expect(reading.entries.first?.blobFileName != nil)
    }

    /// Le dossier doit se lire à l'œil : le sidecar et son fichier lourd portent
    /// le même nom à l'extension près, préfixé d'un horodatage triable.
    @Test("Le sidecar et le fichier lourd partagent le même nom")
    func sidecarAndBlobShareTheirName() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let writing = makeStore(root: root)
        await writing.save(note(daysAgo: 1), blob: writer(bytes: 8))

        let found = names(in: writing.folder)
        #expect(found.count == 2)
        let stems = Set(found.map { ($0 as NSString).deletingPathExtension })
        #expect(stems.count == 1)
        #expect(Set(found.map { ($0 as NSString).pathExtension }) == ["bin", "json"])
    }

    @Test("Sans fichier lourd à écrire, seul le sidecar est posé")
    func savingWithoutABlobWritesOnlyTheSidecar() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let writing = makeStore(root: root)
        await writing.save(note(daysAgo: 1))

        #expect(names(in: writing.folder).count == 1)
        #expect(writing.entries.first?.blobFileName == nil)
        #expect(writing.problem == nil)
    }

    /// Le fichier lourd est un confort, l'entrée est l'essentiel : on garde
    /// l'entrée sans son fichier plutôt que de tout perdre.
    @Test("Un échec d'écriture du fichier lourd garde l'entrée et dit pourquoi")
    func blobFailureKeepsTheEntryAndExplains() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let writing = makeStore(root: root)
        await writing.save(note(daysAgo: 1, text: "sauvée"), blob: failingWriter)

        #expect(writing.entries.map(\.text) == ["sauvée"])
        #expect(writing.entries.first?.blobFileName == nil)
        #expect(writing.problem?.hasPrefix("Fichier non conservé : ") == true)

        let reading = makeStore(root: root)
        await reading.reload()
        #expect(reading.entries.map(\.text) == ["sauvée"])
    }

    /// L'autre moitié du même choix : une bibliothèque dont le fichier lourd
    /// n'est qu'un agrément se tait, et ne fait pas douter d'un enregistrement
    /// qui n'a rien perdu. C'est le cas de la dictée.
    @Test("Une bibliothèque silencieuse n'annonce pas l'échec du fichier lourd")
    func silentLibrarySaysNothing() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let writing = makeStore(root: root, blobFailureMessage: nil)
        await writing.save(note(daysAgo: 1), blob: failingWriter)

        #expect(writing.entries.count == 1)
        #expect(writing.entries.first?.blobFileName == nil)
        #expect(writing.problem == nil)
    }

    /// L'invariant qui tenait par chance : les deux appelants d'origine
    /// n'enregistrent que des entrées datées de maintenant, donc l'insertion en
    /// tête donnait toujours le bon ordre. Un historique qui importerait
    /// l'existant obtiendrait une liste en mémoire que la relecture
    /// réordonnerait au redémarrage — sans que rien ne relie le symptôme à sa
    /// cause.
    @Test("Une entrée antidatée se range à sa date, pas en tête")
    func backdatedEntryLandsAtItsDate() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let writing = makeStore(root: root)
        await writing.save(note(daysAgo: 1, text: "hier"))
        await writing.save(note(daysAgo: 30, text: "le mois dernier"))
        await writing.save(note(daysAgo: 0, text: "à l'instant"))

        #expect(writing.entries.map(\.text) == ["à l'instant", "hier", "le mois dernier"])

        // La seule vérification qui compte : la mémoire dit ce que le disque
        // dira au prochain lancement.
        let reading = makeStore(root: root)
        await reading.reload()
        #expect(reading.entries.map(\.text) == writing.entries.map(\.text))
    }

    @Test("Modifier une entrée réécrit son sidecar")
    func mutationReachesTheDisk() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let writing = makeStore(root: root)
        await writing.save(note(daysAgo: 1, text: "brouillon"))
        let id = try #require(writing.entries.first?.id)

        writing.mutate(id) { $0.text = "corrigé"; $0.tag = "relu" }

        let reading = makeStore(root: root)
        await reading.reload()
        #expect(reading.entries.first?.text == "corrigé")
        #expect(reading.entries.first?.tag == "relu")
    }

    @Test("Modifier une entrée inconnue ne fait rien")
    func mutatingAnUnknownEntryIsHarmless() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let writing = makeStore(root: root)
        await writing.save(note(daysAgo: 1, text: "intacte"))

        writing.mutate(UUID()) { $0.text = "ne doit jamais arriver" }

        #expect(writing.entries.map(\.text) == ["intacte"])
        #expect(names(in: writing.folder).count == 1)
    }

    @Test("Supprimer efface l'entrée, son sidecar et son fichier lourd")
    func deleteRemovesBothFiles() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let writing = makeStore(root: root)
        await writing.save(note(daysAgo: 1), blob: writer(bytes: 16))
        let entry = try #require(writing.entries.first)

        await writing.delete(entry)

        #expect(writing.entries.isEmpty)
        #expect(names(in: writing.folder).isEmpty)
        #expect(writing.blobBytes == 0)
    }

    // MARK: - Purge

    /// La limite exacte. Sans ce test, un `>` au lieu d'un `>=` ferait traîner
    /// un fichier une journée de plus pour une raison inexplicable.
    @Test("Pile à la limite, le fichier lourd est purgé")
    func purgesExactlyAtBoundary() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let writing = makeStore(root: root, lifetime: 7 * Self.day)
        await writing.save(note(daysAgo: 7), blob: writer(bytes: 64))

        let count = await writing.purgeExpired(now: Self.epoch)

        #expect(count == 1)
        #expect(writing.blobBytes == 0)
    }

    /// L'invariant que la générique n'avait pas le droit d'aplatir : côté
    /// capture et côté dictée, **le texte n'est jamais concerné par la purge**.
    @Test("La purge d'un fichier lourd laisse l'entrée et son texte sur le disque")
    func blobOnlyPurgeKeepsTheEntry() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let writing = makeStore(root: root, purge: .blobOnly, lifetime: 7 * Self.day)
        await writing.save(note(daysAgo: 400, text: "vieux mais précieux"), blob: writer(bytes: 64))

        await writing.purgeExpired(now: Self.epoch)

        #expect(writing.entries.map(\.text) == ["vieux mais précieux"])
        #expect(writing.entries.first?.blobFileName == nil)

        // Le sidecar est resté, le fichier lourd est parti.
        let remaining = names(in: writing.folder)
        #expect(remaining.count == 1)
        #expect(remaining.allSatisfy { $0.hasSuffix(".json") })

        // L'oubli du fichier doit avoir été réécrit : sinon la prochaine
        // lecture redemanderait un fichier qui n'existe plus.
        let reading = makeStore(root: root)
        await reading.reload()
        #expect(reading.entries.map(\.text) == ["vieux mais précieux"])
        #expect(reading.entries.first?.blobFileName == nil)
    }

    /// L'autre famille, celle qu'un historique de presse-papiers demandera :
    /// l'entrée entière s'en va, sidecar compris.
    @Test("La purge d'une bibliothèque périssable efface l'entrée entière")
    func wholeEntryPurgeRemovesEverything() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let writing = ContentStore<Note>(
            root: { root },
            shape: makeShape(purge: .wholeEntry),
            retention: EntryAge(lifetime: 7 * Self.day)
        )
        await writing.save(note(daysAgo: 400), blob: writer(bytes: 64))
        await writing.save(note(daysAgo: 1, text: "fraîche"))

        let count = await writing.purgeExpired(now: Self.epoch)

        #expect(count == 1)
        #expect(writing.entries.map(\.text) == ["fraîche"])
        #expect(names(in: writing.folder).count == 1)
    }

    @Test("Une entrée encore fraîche n'est pas purgée")
    func freshEntrySurvives() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let writing = makeStore(root: root, lifetime: 7 * Self.day)
        await writing.save(note(daysAgo: 2), blob: writer(bytes: 64))

        let count = await writing.purgeExpired(now: Self.epoch)

        #expect(count == 0)
        #expect(writing.entries.first?.blobFileName != nil)
        #expect(writing.blobBytes == 64)
    }

    @Test("Une entrée déjà purgée n'est pas repurgée")
    func alreadyPurgedEntryIsSkipped() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let writing = makeStore(root: root, lifetime: 7 * Self.day)
        await writing.save(note(daysAgo: 400))

        let count = await writing.purgeExpired(now: Self.epoch)
        #expect(count == 0)
    }

    @Test("L'URL du fichier lourd est nulle une fois qu'il a été purgé")
    func blobURLDisappearsWithTheBlob() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let writing = makeStore(root: root, lifetime: 7 * Self.day)
        await writing.save(note(daysAgo: 9), blob: writer(bytes: 8))
        let before = try #require(writing.entries.first)
        #expect(writing.blobURL(for: before) != nil)

        await writing.purgeExpired(now: Self.epoch)

        let after = try #require(writing.entries.first)
        #expect(writing.blobURL(for: after) == nil)
    }

    @Test("La date d'échéance suit la politique en vigueur")
    func expiryFollowsTheCurrentPolicy() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let writing = makeStore(root: root, lifetime: 7 * Self.day)
        let entry = note(daysAgo: 0)

        #expect(writing.expiryDate(for: entry) == entry.createdAt.addingTimeInterval(7 * Self.day))

        writing.setRetention(BlobAge(lifetime: 30 * Self.day))

        #expect(writing.expiryDate(for: entry) == entry.createdAt.addingTimeInterval(30 * Self.day))
    }

    // MARK: - Ramassage des fichiers sans entrée
    //
    // Le défaut que cette section couvre : la purge parcourait `entries`, donc
    // un fichier lourd dont le sidecar n'avait jamais été écrit — écriture
    // ratée, plantage entre les deux fichiers — n'était plus jamais vu. Les
    // tests disent les deux moitiés de la réconciliation : ce qu'elle ramasse,
    // et surtout ce à quoi elle refuse de toucher.

    /// Le sidecar disparu, l'image reste : c'est exactement l'état que laisse un
    /// plantage entre les deux écritures.
    @Test("Un fichier lourd sans entrée est ramassé à la relecture")
    func orphanedBlobIsCollected() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let writing = makeStore(root: root)
        await writing.save(note(daysAgo: 1), blob: writer(bytes: 64))
        let entry = try #require(writing.entries.first)
        let blob = try #require(writing.blobURL(for: entry))
        try FileManager.default.removeItem(at: sidecar(of: blob))

        let reading = makeStore(root: root)
        let collected = await reading.reload()

        #expect(collected == 1)
        #expect(names(in: reading.folder).isEmpty)
        #expect(reading.problem == nil)
    }

    /// Le chiffre affiché dans les réglages sert à décider d'une rétention. Un
    /// fichier que personne ne peut plus supprimer, et qui pèse quand même dans
    /// la somme, transforme ce chiffre en reproche sans recours.
    @Test("Un orphelin cesse d'être compté dans les octets")
    func orphanStopsWeighing() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let writing = makeStore(root: root)
        await writing.save(note(daysAgo: 1, text: "vivante"), blob: writer(bytes: 100))
        await writing.save(note(daysAgo: 2, text: "perdue"), blob: writer(bytes: 40))

        let doomed = try #require(writing.entries.first { $0.text == "perdue" })
        let blob = try #require(writing.blobURL(for: doomed))
        try FileManager.default.removeItem(at: sidecar(of: blob))

        let reading = makeStore(root: root)
        let collected = await reading.reload()

        #expect(collected == 1)
        #expect(reading.entries.map(\.text) == ["vivante"])
        #expect(reading.blobBytes == 100)
    }

    @Test("Un fichier lourd encore réclamé n'est jamais ramassé")
    func claimedBlobStays() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let writing = makeStore(root: root)
        await writing.save(note(daysAgo: 1), blob: writer(bytes: 64))

        let reading = makeStore(root: root)
        let collected = await reading.reload()

        #expect(collected == 0)
        #expect(names(in: reading.folder).count == 2)
        #expect(reading.blobBytes == 64)
        #expect(reading.entries.first?.blobFileName != nil)
    }

    /// L'autre moitié du défaut, celle qu'une règle plus simple — « un fichier
    /// lourd dont le sidecar voisin manque » — aurait laissée passer : la
    /// suppression a échoué, l'entrée a quand même oublié son fichier, et le
    /// fichier que la rétention avait promis d'effacer est toujours là.
    @Test("Un fichier lourd que plus personne ne réclame part, même avec son sidecar")
    func unclaimedBlobGoesEvenWithItsSidecar() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let writing = makeStore(root: root)
        await writing.save(note(daysAgo: 1, text: "toujours là"), blob: writer(bytes: 64))
        let entry = try #require(writing.entries.first)
        let blob = try #require(writing.blobURL(for: entry))

        // Ce que laisse une purge dont le `removeItem` a échoué en silence.
        writing.mutate(entry.id) { $0.blobFileName = nil }
        #expect(FileManager.default.fileExists(atPath: blob.path(percentEncoded: false)))

        let reading = makeStore(root: root)
        let collected = await reading.reload()

        #expect(collected == 1)
        #expect(reading.entries.map(\.text) == ["toujours là"])
        #expect(names(in: reading.folder).allSatisfy { $0.hasSuffix(".json") })
    }

    /// **Le test le plus important de la série.** La bibliothèque est un dossier
    /// ordinaire, qu'on invite l'utilisateur à ouvrir et à sauvegarder.
    /// Supprimer le fichier d'un tiers parce qu'il traînait chez nous serait un
    /// défaut bien pire que celui qu'on corrige.
    @Test("Un fichier d'une autre extension n'est jamais touché")
    func foreignExtensionIsNeverTouched() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let writing = makeStore(root: root)
        await writing.save(note(daysAgo: 1))
        let folder = writing.folder
        try Data("mes notes à moi".utf8).write(to: folder.appending(path: "à lire.txt"))
        try Data(repeating: 0x42, count: 12).write(to: folder.appending(path: "capture.png"))

        let reading = makeStore(root: root)
        let collected = await reading.reload()

        #expect(collected == 0)
        #expect(names(in: folder).contains("à lire.txt"))
        #expect(names(in: folder).contains("capture.png"))
    }

    /// La bonne extension ne suffit pas : il faut un nom que ce store aurait pu
    /// écrire. Une image glissée à la main n'en a pas — et l'un de nos fichiers
    /// renommé par l'utilisateur pour le retrouver n'en a plus.
    @Test("Un fichier lourd déposé ou renommé à la main garde sa place")
    func handPlacedBlobIsSpared() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let writing = makeStore(root: root)
        await writing.save(note(daysAgo: 1))
        let folder = writing.folder

        let strangers = [
            "vacances.bin",
            // Renommé : l'identité est restée, l'horodatage est parti.
            "chat-9F2B4C1E-0000-4000-8000-000000000003.bin",
            // Horodaté sans identité : ce n'est pas non plus une de nos formes.
            "2026-08-05T20-47-11-pas-un-uuid.bin",
        ]
        for name in strangers {
            try Data(repeating: 0x43, count: 5).write(to: folder.appending(path: name))
        }

        let reading = makeStore(root: root)
        let collected = await reading.reload()

        #expect(collected == 0)
        #expect(strangers.allSatisfy { names(in: folder).contains($0) })
        // Ils pèsent, eux : la somme reste franche même quand le ramassage
        // s'abstient.
        #expect(reading.blobBytes == 15)
    }

    /// `removeItem` sur un dossier emporte tout ce qu'il contient. Un dossier
    /// porte ici le nom exact d'un de nos fichiers — seule la vérification
    /// « fichier régulier » le sauve.
    @Test("Un dossier nommé comme un fichier lourd n'est pas emporté")
    func directoryShapedLikeABlobIsSpared() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let writing = makeStore(root: root)
        await writing.save(note(daysAgo: 1))

        let decoy = writing.folder.appending(
            path: "2026-08-05T20-47-11-9F2B4C1E-0000-4000-8000-000000000002.bin",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: decoy, withIntermediateDirectories: true)
        try Data("précieux".utf8).write(to: decoy.appending(path: "dedans.txt"))

        let reading = makeStore(root: root)
        let collected = await reading.reload()

        #expect(collected == 0)
        #expect(names(in: decoy) == ["dedans.txt"])
    }

    @Test("Un sidecar n'est jamais pris pour un fichier lourd")
    func sidecarIsNeverMistakenForABlob() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let writing = makeStore(root: root)
        await writing.save(note(daysAgo: 1, text: "une"))
        await writing.save(note(daysAgo: 2, text: "deux"))
        await writing.save(note(daysAgo: 3, text: "trois"))

        let reading = makeStore(root: root)
        let collected = await reading.reload()

        #expect(collected == 0)
        #expect(reading.entries.count == 3)
        #expect(names(in: reading.folder).count == 3)
    }

    /// Un `.json` abîmé est peut-être récupérable à la main — `SidecarFault` le
    /// dit déjà. Son entrée n'a pas décodé, donc personne ne réclame l'image :
    /// la soustraction la donnerait orpheline. La détruire transformerait une
    /// panne réparable en perte sèche.
    @Test("Le fichier lourd d'un sidecar illisible est épargné")
    func blobOfBrokenSidecarIsSpared() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let writing = makeStore(root: root)
        await writing.save(note(daysAgo: 1), blob: writer(bytes: 64))
        let entry = try #require(writing.entries.first)
        let blob = try #require(writing.blobURL(for: entry))
        try Data("{ ceci n'est pas du JSON".utf8).write(to: sidecar(of: blob))

        let reading = makeStore(root: root)
        let collected = await reading.reload()

        #expect(collected == 0)
        #expect(reading.entries.isEmpty)
        #expect(FileManager.default.fileExists(atPath: blob.path(percentEncoded: false)))
    }

    @Test("Un dossier vide n'a rien à ramasser")
    func emptyFolderSweepsToNothing() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = makeStore(root: root)
        let collected = await store.reload()

        #expect(collected == 0)
        #expect(store.blobBytes == 0)
        #expect(store.problem == nil)
    }

    @Test("Le ramassage repassé une seconde fois ne fait plus rien")
    func sweepingTwiceIsHarmless() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let writing = makeStore(root: root)
        await writing.save(note(daysAgo: 1, text: "gardée"))
        await writing.save(note(daysAgo: 2), blob: writer(bytes: 64))
        let doomed = try #require(writing.entries.last)
        let blob = try #require(writing.blobURL(for: doomed))
        try FileManager.default.removeItem(at: sidecar(of: blob))

        let reading = makeStore(root: root)
        let first = await reading.reload()
        let second = await reading.reload()

        #expect(first == 1)
        #expect(second == 0)
        #expect(reading.entries.map(\.text) == ["gardée"])
        #expect(names(in: reading.folder).count == 1)
    }

    // MARK: - Racine mobile

    /// Le dossier suit la racine choisie dans les réglages. Une `URL` figée à
    /// l'initialisation garderait l'ancien dossier jusqu'au prochain lancement,
    /// ce qui est précisément le défaut que la fermeture évite.
    @Test("Changer la racine change le dossier tout de suite")
    func folderFollowsTheMovingRoot() async throws {
        let first = try makeRoot()
        let second = try makeRoot()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }

        let root = Root(first)
        let store = ContentStore<Note>(
            root: { root.url },
            shape: makeShape(),
            retention: BlobAge(lifetime: 7 * Self.day)
        )

        await store.save(note(daysAgo: 1, text: "dans le premier dossier"))
        #expect(names(in: first.appending(path: "Notes")).count == 1)

        root.url = second
        await store.reload()

        #expect(store.entries.isEmpty)
        #expect(names(in: second.appending(path: "Notes")).isEmpty)
    }

    // MARK: - Le message d'erreur

    /// **Le piège que la séparation en deux emplacements existe pour éviter.**
    /// `SnapshotStore` appelle `report(_:)` *juste avant* un `save` sans fichier
    /// lourd — l'ordre est chez lui, et on ne peut pas le changer d'ici. Si une
    /// réussite d'écriture effaçait les constatations comme elle efface les
    /// échecs, ce message-là mourrait une microseconde après sa pose, et
    /// personne ne saurait jamais pourquoi ses captures n'ont plus d'image.
    ///
    /// Et il survit à la relecture, pour la même raison que les échecs : les
    /// deux panneaux relisent le dossier à leur apparition, donc l'utilisateur
    /// qui ouvre la bibliothèque pour comprendre effacerait le message en
    /// l'ouvrant.
    @Test("Une constatation survit à l'enregistrement qu'elle commente, et à la relecture")
    func noticeOutlivesTheSaveItComments() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = makeStore(root: root)
        store.report("la durée de conservation est réglée sur zéro")

        await store.save(note(daysAgo: 1))
        #expect(store.problem == "la durée de conservation est réglée sur zéro")
        #expect(store.writeFailure == nil)

        await store.reload()
        #expect(store.problem == "la durée de conservation est réglée sur zéro")
        #expect(store.readProblem == nil)
    }

    /// La seule chose qui contredise « aucun fichier n'a été conservé » est un
    /// fichier conservé. Sans cet effacement-là, une rétention remontée au-dessus
    /// de zéro laisserait le message parler d'un réglage qui n'existe plus.
    @Test("Un fichier lourd conservé réfute la constatation qui disait le contraire")
    func aKeptBlobRefutesTheNotice() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = makeStore(root: root)
        store.report("Fichier non conservé : la durée de conservation est réglée sur zéro.")
        await store.save(note(daysAgo: 2))
        #expect(store.problem != nil)

        await store.save(note(daysAgo: 1), blob: writer(bytes: 8))
        #expect(store.notice == nil)
        #expect(store.problem == nil)
    }

    /// L'autre moitié : un volume remonté est une bonne nouvelle qui n'a pas
    /// besoin d'être acquittée. La lecture efface ce que la lecture avait dit,
    /// et rien d'autre.
    @Test("Un dossier redevenu lisible efface son propre reproche")
    func readProblemClearsWhenTheFolderComesBack() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let obstacle = root.appending(path: "Notes")
        try Data("pas un dossier".utf8).write(to: obstacle)

        let store = makeStore(root: root)
        await store.reload()
        #expect(store.problem?.hasPrefix("Dossier des notes inaccessible : ") == true)

        try FileManager.default.removeItem(at: obstacle)
        await store.reload()
        #expect(store.problem == nil)
    }

    /// Un reproche qui survit à sa propre réfutation apprend à ne plus lire le
    /// bandeau. Le fichier lourd enfin écrit est cette réfutation.
    @Test("Un fichier lourd enfin écrit efface le reproche du précédent")
    func aWrittenBlobClearsTheReproach() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = makeStore(root: root)
        await store.save(note(daysAgo: 2), blob: failingWriter)
        #expect(store.problem?.hasPrefix("Fichier non conservé : ") == true)

        await store.save(note(daysAgo: 1), blob: writer(bytes: 8))
        #expect(store.problem == nil)
    }

    /// L'autre moitié du même reproche, et celle qui manquait : le sidecar. Un
    /// disque plein à 10 h et libre à 10 h 05 se plaignait encore à 18 h, parce
    /// que rien n'effaçait jamais « Écriture impossible ».
    @Test("Un sidecar enfin écrit efface le reproche du précédent")
    func aWrittenSidecarClearsTheReproach() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        // Un fichier ordinaire là où le dossier devrait être : la création du
        // dossier échoue, donc le sidecar aussi.
        let obstacle = root.appending(path: "Notes")
        try Data("pas un dossier".utf8).write(to: obstacle)

        let store = makeStore(root: root)
        await store.save(note(daysAgo: 2))
        #expect(store.problem?.hasPrefix("Écriture impossible : ") == true)

        try FileManager.default.removeItem(at: obstacle)
        await store.save(note(daysAgo: 1))
        #expect(store.writeFailure == nil)
        #expect(store.problem == nil)
    }

    /// La propriété que le correctif précédent avait installée, et que celui-ci
    /// ne doit pas reprendre : les deux panneaux relisent le dossier à leur
    /// apparition, donc une relecture réussie ne prouve rien sur l'écriture.
    @Test("Un reproche d'écriture survit à une relecture réussie")
    func aWriteFailureSurvivesAReload() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = makeStore(root: root)
        await store.save(note(daysAgo: 1), blob: failingWriter)
        #expect(store.problem?.hasPrefix("Fichier non conservé : ") == true)

        await store.reload()
        #expect(store.readProblem == nil)
        #expect(store.problem?.hasPrefix("Fichier non conservé : ") == true)
    }

    /// Un échec effacé est effacé pour de bon. Le sidecar ne garde aucune trace
    /// de la panne, donc rien ne peut la faire revenir — et si un jour quelque
    /// chose le pouvait, ce test le dirait.
    @Test("Un reproche réfuté ne ressuscite pas à la relecture suivante")
    func aRefutedFailureDoesNotComeBack() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = makeStore(root: root)
        await store.save(note(daysAgo: 3), blob: failingWriter)
        #expect(store.problem != nil)

        await store.save(note(daysAgo: 2), blob: writer(bytes: 8))
        #expect(store.problem == nil)

        await store.reload()
        #expect(store.problem == nil)
        #expect(store.writeFailure == nil)
    }

    /// **Les deux emplacements ne se marchent pas dessus.** Une constatation
    /// posée, puis un échec réel : l'échec ne doit pas écraser la constatation,
    /// et le sidecar posé sans encombre *dans le même `save`* ne doit pas
    /// effacer l'échec du fichier lourd qui vient d'être écrit une ligne plus
    /// haut.
    @Test("Une constatation et un échec coexistent sans s'effacer")
    func aNoticeAndAFailureCoexist() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = makeStore(root: root)
        store.report("Image non conservée : la durée de conservation est réglée sur zéro.")
        await store.save(note(daysAgo: 1), blob: failingWriter)

        #expect(store.notice == "Image non conservée : la durée de conservation est réglée sur zéro.")
        #expect(store.writeFailure?.hasPrefix("Fichier non conservé : ") == true)

        let shown = try #require(store.problem)
        #expect(shown.components(separatedBy: "\n").count == 2)
        #expect(shown.contains("la durée de conservation est réglée sur zéro"))
        #expect(shown.contains("Fichier non conservé : "))
    }

    /// Le silence de la dictée n'est pas une réfutation. Un échec muet ne dit
    /// rien de neuf, et il n'a surtout pas le droit d'effacer ce qui était dit —
    /// alors même que le sidecar, lui, s'écrit très bien dans le même `save`.
    @Test("Un échec silencieux n'efface pas le reproche précédent")
    func aSilentFailureClearsNothing() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let obstacle = root.appending(path: "Notes")
        try Data("pas un dossier".utf8).write(to: obstacle)

        let store = makeStore(root: root, blobFailureMessage: nil)
        await store.save(note(daysAgo: 2))
        let reproach = try #require(store.writeFailure)
        #expect(reproach.hasPrefix("Écriture impossible : "))

        try FileManager.default.removeItem(at: obstacle)
        await store.save(note(daysAgo: 1), blob: failingWriter)

        #expect(store.writeFailure == reproach)
    }

    /// Deux pannes à la fois : la seconde ne doit pas effacer la première avant
    /// que personne ne l'ait lue. C'est la raison d'être de `FailureBanner`, et
    /// la raison pour laquelle `problem` est calculé à partir de deux canaux.
    @Test("Un reproche d'écriture et un reproche de lecture s'affichent ensemble")
    func bothChannelsAreShown() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = makeStore(root: root)
        store.report("Fichier non conservé : disque plein")
        try Data("pas un dossier".utf8).write(to: root.appending(path: "Notes"))

        await store.reload()

        let shown = try #require(store.problem)
        #expect(shown.contains("Fichier non conservé : disque plein"))
        #expect(shown.contains("Dossier des notes inaccessible"))
        #expect(shown.components(separatedBy: "\n").count == 2)
    }
}
