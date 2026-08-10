import Foundation
import Testing
@testable import BranCore

/// Une racine que l'on peut déplacer en cours de route, comme le font les
/// réglages quand on change le dossier de destination. Même échafaudage que
/// `ContentStoreTests` — un magasin qui fige sa racine à la construction est un
/// défaut que ces deux suites doivent pouvoir attraper.
@MainActor
private final class Root {
    var url: URL
    init(_ url: URL) { self.url = url }
}

@Suite("Historique du presse-papiers sur disque")
@MainActor
struct ClipboardStoreTests {

    // MARK: - Échafaudage

    /// Le 10 août 2026 à midi, heure locale. Midi et non minuit : une date de
    /// bord tomberait dans un autre jour selon le fuseau du testeur, et la
    /// bibliothèque range par jour **local** — c'est écrit dans
    /// `ClipboardRetention.dayKey`.
    private static var noon: Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: DateComponents(year: 2026, month: 8, day: 10, hour: 12))!
    }

    private static let day: TimeInterval = 86_400

    private func makeRoot() throws -> URL {
        let url = URL.temporaryDirectory
            .appending(path: "ClipboardStoreTests", directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeStore(
        at root: URL,
        retention: ClipboardRetention = .default,
        windowSize: Int = ClipboardStore.windowSize
    ) -> ClipboardStore {
        ClipboardStore(root: { root }, retention: retention, windowSize: windowSize)
    }

    private func text(
        _ body: String, at date: Date = ClipboardStoreTests.noon, from app: String? = nil
    ) -> ClipboardEntry {
        ClipboardEntry(
            copiedAt: date,
            kind: .text,
            text: body,
            source: app.map { ClipboardSource(bundleIdentifier: "com.test.\($0)", name: $0) }
        )
    }

    private func payload(_ body: String, ext: String = "png") -> ClipboardBlobPayload {
        ClipboardBlobPayload(data: Data(body.utf8), ext: ext)
    }

    private func dayKey(_ date: Date) -> String {
        ClipboardRetention.dayKey(for: date)
    }

    private func names(in folder: URL) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(
            atPath: folder.path(percentEncoded: false)
        )) ?? [])
    }

    // MARK: - Aller-retour

    @Test("Une entrée écrite se relit à l'identique au lancement suivant")
    func allerRetour() async throws {
        let root = try makeRoot()
        let store = makeStore(at: root)

        let entry = text("Bonjour", from: "Chrome")
        await store.save(entry)

        let relu = makeStore(at: root)
        await relu.load()

        #expect(relu.recent.count == 1)
        #expect(relu.recent.first == entry)
        #expect(relu.recent.first?.source?.name == "Chrome")
    }

    @Test("Le dossier du jour porte les trois pièces attendues, et pas une de plus")
    func dispositionSurDisque() async throws {
        let root = try makeRoot()
        let store = makeStore(at: root)

        let entry = text("Avec image")
        let stored = await store.save(entry, payloads: [payload("PNG")])
        let folder = store.dayFolder(dayKey(Self.noon))

        #expect(names(in: folder) == [
            "\(entry.id.uuidString).json", "index.jsonl", "blobs",
        ])
        let ref = try #require(stored.blobs?.first)
        #expect(names(in: folder.appending(path: "blobs")) == [ref.fileName])
    }

    @Test("La ligne d'index tient sur une ligne, même pour un texte multiligne")
    func uneLigneParEntree() async throws {
        let root = try makeRoot()
        let store = makeStore(at: root)

        await store.save(text("premier\nsecond\ntroisième"))
        await store.save(text("encore", at: Self.noon.addingTimeInterval(1)))

        let url = store.dayFolder(dayKey(Self.noon)).appending(path: "index.jsonl")
        let raw = try String(contentsOf: url, encoding: .utf8)
        #expect(raw.split(whereSeparator: \.isNewline).count == 2)
    }

    @Test("Le sidecar est la vérité : l'index supprimé, rien n'est perdu")
    func indexSupprime() async throws {
        let root = try makeRoot()
        let store = makeStore(at: root)
        await store.save(text("un"))
        await store.save(text("deux", at: Self.noon.addingTimeInterval(1)))

        let folder = store.dayFolder(dayKey(Self.noon))
        try FileManager.default.removeItem(at: folder.appending(path: "index.jsonl"))

        let relu = makeStore(at: root)
        #expect(await relu.load() == 2)
        // Et il est reconstruit, pas seulement contourné : la lecture suivante
        // ne doit pas repayer la relecture de tous les sidecars.
        #expect(names(in: folder).contains("index.jsonl"))
        #expect(await relu.entries(on: dayKey(Self.noon)).count == 2)
    }

    // MARK: - Le changement de jour

    @Test("Deux jours, deux dossiers, et l'entrée ne change jamais du sien")
    func changementDeJour() async throws {
        let root = try makeRoot()
        let store = makeStore(at: root)

        let hier = Self.noon.addingTimeInterval(-Self.day)
        await store.save(text("hier", at: hier))
        await store.save(text("aujourd'hui"))

        #expect(await store.days() == [dayKey(Self.noon), dayKey(hier)].sorted(by: >))
        #expect(await store.entries(on: dayKey(hier)).count == 1)
        #expect(await store.entries(on: dayKey(Self.noon)).count == 1)
    }

    @Test("Recopier fait monter le compteur sans déménager la ligne")
    func recopieSansDemenagement() async throws {
        let root = try makeRoot()
        let store = makeStore(at: root)

        let hier = Self.noon.addingTimeInterval(-Self.day)
        let entry = await store.save(text("ancien", at: hier))
        let recopiee = try #require(await store.recopy(entry, at: Self.noon))

        #expect(recopiee.copyCount == 2)
        #expect(recopiee.dayFolderName() == dayKey(hier))
        // Aucun dossier du jour n'a été créé pour une entrée qui n'y vit pas.
        #expect(await store.days() == [dayKey(hier)])

        let relu = makeStore(at: root)
        await relu.load()
        #expect(relu.recent.first?.copyCount == 2)
        #expect(relu.recent.first?.copiedAt == hier)
    }

    @Test("La liste est triée par la copie la plus récente, pas par la première")
    func triParDerniereCopie() async throws {
        let root = try makeRoot()
        let store = makeStore(at: root)

        let ancienne = await store.save(text("ancienne", at: Self.noon))
        await store.save(text("récente", at: Self.noon.addingTimeInterval(60)))
        _ = await store.recopy(ancienne, at: Self.noon.addingTimeInterval(120))

        #expect(store.recent.first?.preview == "ancienne")
        let relu = makeStore(at: root)
        await relu.load()
        #expect(relu.recent.first?.preview == "ancienne")
    }

    // MARK: - L'index ne peut pas faire perdre une entrée

    @Test("Une ligne d'index abîmée est sautée, et le jour se reconstruit")
    func indexAbime() async throws {
        let root = try makeRoot()
        let store = makeStore(at: root)
        await store.save(text("un"))
        await store.save(text("deux", at: Self.noon.addingTimeInterval(1)))

        let url = store.dayFolder(dayKey(Self.noon)).appending(path: "index.jsonl")
        var raw = try String(contentsOf: url, encoding: .utf8)
        raw += "{\"id\":\"pas du JSON valide\n"
        try raw.write(to: url, atomically: true, encoding: .utf8)

        let relu = makeStore(at: root)
        #expect(await relu.load() == 2)
        // La reconstruction a réécrit l'index : la ligne folle n'est plus là.
        let apres = try String(contentsOf: url, encoding: .utf8)
        #expect(apres.contains("pas du JSON valide") == false)
        #expect(apres.split(whereSeparator: \.isNewline).count == 2)
    }

    @Test("Un index tronqué en plein milieu — le plantage pendant l'ajout — ne perd rien")
    func indexTronque() async throws {
        let root = try makeRoot()
        let store = makeStore(at: root)
        await store.save(text("un"))
        await store.save(text("deux", at: Self.noon.addingTimeInterval(1)))

        let url = store.dayFolder(dayKey(Self.noon)).appending(path: "index.jsonl")
        let raw = try String(contentsOf: url, encoding: .utf8)
        try String(raw.dropLast(40)).write(to: url, atomically: true, encoding: .utf8)

        let relu = makeStore(at: root)
        #expect(await relu.load() == 2)
    }

    @Test("Un index qui a oublié une entrée est corrigé, pas cru sur parole")
    func indexIncomplet() async throws {
        let root = try makeRoot()
        let store = makeStore(at: root)
        let premiere = await store.save(text("un"))
        await store.save(text("deux", at: Self.noon.addingTimeInterval(1)))

        // Le plantage entre le sidecar et la ligne : l'index ne cite que la
        // première entrée, le disque en porte deux.
        let folder = store.dayFolder(dayKey(Self.noon))
        let ligne = try ClipboardStore.lineEncoder.encode(premiere) + Data("\n".utf8)
        try ligne.write(to: folder.appending(path: "index.jsonl"), options: .atomic)

        let relu = makeStore(at: root)
        #expect(await relu.load() == 2)
    }

    @Test("Un sidecar illisible ne fait pas tomber sa journée")
    func sidecarAbime() async throws {
        let root = try makeRoot()
        let store = makeStore(at: root)
        let abimee = await store.save(text("celle qui casse"))
        await store.save(text("celle qui tient", at: Self.noon.addingTimeInterval(1)))

        let folder = store.dayFolder(dayKey(Self.noon))
        try Data("{ pas du JSON".utf8)
            .write(to: folder.appending(path: "\(abimee.id.uuidString).json"), options: .atomic)
        // L'index aussi, sinon il ferait office de sauvegarde et le test ne
        // vérifierait rien.
        try FileManager.default.removeItem(at: folder.appending(path: "index.jsonl"))

        let relu = makeStore(at: root)
        #expect(await relu.load() == 1)
        #expect(relu.recent.first?.preview == "celle qui tient")
        // Et le fichier abîmé est toujours là : il est peut-être réparable à la
        // main, et personne ne l'a supprimé pour nous rendre service.
        #expect(names(in: folder).contains("\(abimee.id.uuidString).json"))
    }

    // MARK: - Les contenus lourds

    @Test("Deux copies identiques dans la même journée écrivent un seul fichier")
    func deduplicationDansLaJournee() async throws {
        let root = try makeRoot()
        let store = makeStore(at: root)

        let premiere = await store.save(text("image A"), payloads: [payload("mêmes octets")])
        let seconde = await store.save(
            text("image A bis", at: Self.noon.addingTimeInterval(5)),
            payloads: [payload("mêmes octets")]
        )

        #expect(premiere.blobs?.first?.hash == seconde.blobs?.first?.hash)
        let blobs = store.dayFolder(dayKey(Self.noon)).appending(path: "blobs")
        #expect(names(in: blobs).count == 1)
    }

    @Test("Deux jours ne partagent pas leurs contenus, et c'est le prix assumé")
    func pasDeDeduplicationEntreJours() async throws {
        let root = try makeRoot()
        let store = makeStore(at: root)

        let hier = Self.noon.addingTimeInterval(-Self.day)
        await store.save(text("hier", at: hier), payloads: [payload("mêmes octets")])
        await store.save(text("aujourd'hui"), payloads: [payload("mêmes octets")])

        for jour in [dayKey(hier), dayKey(Self.noon)] {
            #expect(names(in: store.dayFolder(jour).appending(path: "blobs")).count == 1)
        }
    }

    @Test("Le nom d'un contenu est l'empreinte de ce qu'il contient")
    func nommageParEmpreinte() async throws {
        let root = try makeRoot()
        let store = makeStore(at: root)

        let charge = payload("contenu")
        let stored = await store.save(text("porte un blob"), payloads: [charge])
        let ref = try #require(stored.blobs?.first)

        #expect(ref.hash == charge.hash)
        #expect(ref.hash.count == 64)
        #expect(ref.bytes == charge.data.count)

        let url = try #require(store.blobURL(for: ref, of: stored))
        let relu = try Data(contentsOf: url)
        #expect(relu == charge.data)
    }

    @Test("Au-delà du plafond, rien n'est écrit et l'entrée le dit")
    func contenuRefuse() async throws {
        let root = try makeRoot()
        let store = makeStore(at: root)

        let trop = ClipboardBlobPayload(
            data: Data(count: ClipboardEntry.maximumBlobBytes + 1), ext: "png"
        )
        let stored = await store.save(text("trop gros"), payloads: [trop])

        #expect(stored.isRefused)
        #expect(stored.refusedBytes == ClipboardEntry.maximumBlobBytes + 1)
        #expect(stored.blobs == nil)
        #expect(names(in: store.dayFolder(dayKey(Self.noon))).contains("blobs") == false)
    }

    // MARK: - Suppression

    @Test("Supprimer retire le sidecar et réécrit l'index — de ce jour-là seulement")
    func suppressionCiblee() async throws {
        let root = try makeRoot()
        let store = makeStore(at: root)

        let hier = Self.noon.addingTimeInterval(-Self.day)
        await store.save(text("hier un", at: hier))
        await store.save(text("hier deux", at: hier.addingTimeInterval(1)))
        let condamnee = await store.save(text("aujourd'hui"))
        await store.save(text("aujourd'hui bis", at: Self.noon.addingTimeInterval(1)))

        let veille = store.dayFolder(dayKey(hier)).appending(path: "index.jsonl")
        let avant = try Data(contentsOf: veille)

        await store.delete(condamnee)

        #expect(store.recent.contains { $0.id == condamnee.id } == false)
        #expect(await store.entries(on: dayKey(Self.noon)).count == 1)
        let apres = try Data(contentsOf: veille)
        #expect(apres == avant)
        #expect(await store.entries(on: dayKey(hier)).count == 2)
        #expect(
            names(in: store.dayFolder(dayKey(Self.noon)))
                .contains("\(condamnee.id.uuidString).json") == false
        )
    }

    @Test("Une suppression survit au redémarrage — pas de pierre tombale à rejouer")
    func suppressionPersistante() async throws {
        let root = try makeRoot()
        let store = makeStore(at: root)
        let condamnee = await store.save(text("à supprimer"))
        await store.save(text("à garder", at: Self.noon.addingTimeInterval(1)))
        await store.delete(condamnee)

        let relu = makeStore(at: root)
        #expect(await relu.load() == 1)
        #expect(relu.recent.first?.preview == "à garder")
    }

    // MARK: - Purge

    @Test("La purge emporte le dossier des contenus, et lui seul")
    func purgeDunDossierDeJour() async throws {
        let root = try makeRoot()
        let store = makeStore(at: root, retention: .days(7))

        let vieux = Self.noon.addingTimeInterval(-30 * Self.day)
        let entry = await store.save(text("vieille image", at: vieux), payloads: [payload("PNG")])
        await store.load()

        #expect(await store.purgeExpired(now: Self.noon) == 1)

        let folder = store.dayFolder(dayKey(vieux))
        #expect(names(in: folder).contains("blobs") == false)
        // Le texte, lui, n'est jamais purgé : c'est toute la fonctionnalité.
        #expect(names(in: folder).contains("index.jsonl"))
        #expect(names(in: folder).contains("\(entry.id.uuidString).json"))

        let relu = makeStore(at: root)
        await relu.load()
        let purgee = try #require(relu.recent.first)
        #expect(purgee.blobsArePurged)
        #expect(purgee.blobs?.count == 1)          // la référence morte reste affichable
        #expect(purgee.totalBlobBytes == 3)
        #expect(relu.blobURL(for: purgee.blobs![0], of: purgee) == nil)
    }

    @Test("Le jour en cours n'est jamais purgé, même à zéro jour de rétention")
    func leJourVivantEstIntouchable() async throws {
        let root = try makeRoot()
        let store = makeStore(at: root, retention: .days(0))

        await store.save(text("de ce matin"), payloads: [payload("PNG")])
        await store.load()

        #expect(await store.purgeExpired(now: Self.noon) == 0)
        #expect(names(in: store.dayFolder(dayKey(Self.noon))).contains("blobs"))
    }

    @Test("Une entrée déjà purgée ne ressort pas au balayage suivant")
    func purgeIdempotente() async throws {
        let root = try makeRoot()
        let store = makeStore(at: root, retention: .days(7))
        await store.save(
            text("vieille", at: Self.noon.addingTimeInterval(-30 * Self.day)),
            payloads: [payload("PNG")]
        )
        await store.load()

        #expect(await store.purgeExpired(now: Self.noon) == 1)
        #expect(await store.purgeExpired(now: Self.noon) == 0)
    }

    // MARK: - Ce qu'on refuse de supprimer

    @Test("Un fichier qu'on ne sait pas classer survit à tout")
    func fichierEtrangerIntouchable() async throws {
        let root = try makeRoot()
        let store = makeStore(at: root, retention: .days(7))

        let vieux = Self.noon.addingTimeInterval(-30 * Self.day)
        await store.save(text("vieille", at: vieux), payloads: [payload("PNG")])
        await store.save(text("du jour"), payloads: [payload("PNG du jour")])

        // Quatre intrus, un par règle de refus.
        let intrus = store.dayFolder("à trier")
        try FileManager.default.createDirectory(at: intrus, withIntermediateDirectories: true)
        try Data("perso".utf8).write(to: intrus.appending(path: "notes.txt"))
        try Data("perso".utf8)
            .write(to: store.dayFolder(dayKey(Self.noon)).appending(path: "notes.txt"))
        try Data("perso".utf8).write(
            to: store.dayFolder(dayKey(Self.noon))
                .appending(path: "blobs")
                .appending(path: "capture d'écran.png")
        )
        try Data("perso".utf8).write(to: root.appending(path: "Clipboard/lisez-moi.txt"))

        await store.load()
        _ = await store.purgeExpired(now: Self.noon)
        _ = await store.collectOrphanedBlobs()

        #expect(names(in: intrus) == ["notes.txt"])
        #expect(names(in: store.dayFolder(dayKey(Self.noon))).contains("notes.txt"))
        #expect(
            names(in: store.dayFolder(dayKey(Self.noon)).appending(path: "blobs"))
                .contains("capture d'écran.png")
        )
        #expect(names(in: root.appending(path: "Clipboard")).contains("lisez-moi.txt"))
        // Et le dossier « à trier » n'est jamais devenu un jour de l'historique.
        #expect(await store.days().contains("à trier") == false)
    }

    @Test("Un dossier-jour dont un sidecar est illisible n'est pas ramassé du tout")
    func ramassageSuspenduSurUnJourDouteux() async throws {
        let root = try makeRoot()
        let store = makeStore(at: root)

        let vivante = await store.save(text("vivante"), payloads: [payload("gardé")])
        let abimee = await store.save(
            text("abîmée", at: Self.noon.addingTimeInterval(1)), payloads: [payload("orphelin")]
        )

        let folder = store.dayFolder(dayKey(Self.noon))
        try Data("{ cassé".utf8)
            .write(to: folder.appending(path: "\(abimee.id.uuidString).json"), options: .atomic)

        #expect(await store.collectOrphanedBlobs() == 0)
        #expect(names(in: folder.appending(path: "blobs")).count == 2)
        #expect(vivante.blobs?.count == 1)
    }

    // MARK: - Le plantage entre le blob et le sidecar

    @Test("Un contenu écrit sans son entrée est un orphelin ramassable, jamais une référence morte")
    func orphelinPlutotQueReferenceMorte() async throws {
        let root = try makeRoot()
        let store = makeStore(at: root)
        await store.save(text("l'entrée qui a abouti"), payloads: [payload("gardé")])

        // Le plantage simulé : le blob est sur le disque, aucun sidecar ne le
        // cite. C'est exactement ce que l'ordre blob → sidecar → index autorise.
        let orphelin = payload("jamais cité")
        let blobs = store.dayFolder(dayKey(Self.noon)).appending(path: "blobs")
        try orphelin.data.write(to: blobs.appending(path: orphelin.ref.fileName))
        #expect(names(in: blobs).count == 2)

        // Aucune entrée ne promet ce fichier : rien n'est cassé à l'affichage.
        let relu = makeStore(at: root)
        await relu.load()
        #expect(relu.recent.count == 1)
        // Une fermeture et non `\.canPaste` : le développement de `#expect`
        // passe le chemin de clé à `allSatisfy`, qui est `rethrows`, et le
        // compilateur en conclut que l'appel peut lancer.
        #expect(relu.recent.allSatisfy { $0.canPaste })

        #expect(await relu.collectOrphanedBlobs() == 1)
        #expect(names(in: blobs).count == 1)
        // Et l'entrée survivante n'a rien perdu.
        let ref = try #require(relu.recent.first?.blobs?.first)
        #expect(FileManager.default.fileExists(
            atPath: blobs.appending(path: ref.fileName).path(percentEncoded: false)
        ))
    }

    @Test("Un contenu devenu inutile après une suppression finit par être ramassé")
    func ramassageApresSuppression() async throws {
        let root = try makeRoot()
        let store = makeStore(at: root)
        let condamnee = await store.save(text("avec image"), payloads: [payload("unique")])
        await store.delete(condamnee)

        let blobs = store.dayFolder(dayKey(Self.noon)).appending(path: "blobs")
        #expect(names(in: blobs).count == 1)     // la suppression ne touche pas aux contenus
        #expect(await store.collectOrphanedBlobs() == 1)
        #expect(names(in: blobs).isEmpty)
    }

    @Test("Un contenu partagé par deux entrées survit à la suppression de l'une")
    func contenuPartageSurvit() async throws {
        let root = try makeRoot()
        let store = makeStore(at: root)
        let premiere = await store.save(text("A"), payloads: [payload("partagé")])
        await store.save(
            text("B", at: Self.noon.addingTimeInterval(1)), payloads: [payload("partagé")]
        )
        await store.delete(premiere)

        #expect(await store.collectOrphanedBlobs() == 0)
        #expect(names(in: store.dayFolder(dayKey(Self.noon)).appending(path: "blobs")).count == 1)
    }

    // MARK: - La fenêtre et la recherche

    @Test("La fenêtre en mémoire est bornée, et garde les plus récentes")
    func fenetreBornee() async throws {
        let root = try makeRoot()
        let store = makeStore(at: root, windowSize: 5)

        for index in 0..<9 {
            await store.save(text("copie \(index)", at: Self.noon.addingTimeInterval(Double(index))))
        }
        #expect(store.recent.count == 5)
        #expect(store.recent.first?.preview == "copie 8")
        #expect(store.recent.last?.preview == "copie 4")

        let relu = makeStore(at: root, windowSize: 5)
        #expect(await relu.load() == 5)
        #expect(relu.recent.first?.preview == "copie 8")

        // Le disque, lui, a tout gardé : la fenêtre borne la mémoire, pas
        // l'historique.
        #expect(await relu.entries(on: dayKey(Self.noon)).count == 9)
    }

    @Test("La recherche trouve une entrée que la fenêtre ne contient plus")
    func rechercheHorsFenetre() async throws {
        let root = try makeRoot()
        let store = makeStore(at: root)

        let vieux = Self.noon.addingTimeInterval(-40 * Self.day)
        await store.save(text("l'aiguille", at: vieux))
        for index in 0..<6 {
            await store.save(text("foin \(index)", at: Self.noon.addingTimeInterval(Double(index))))
        }

        let relu = makeStore(at: root, windowSize: 3)
        await relu.load()
        #expect(relu.recent.contains { $0.preview == "l'aiguille" } == false)

        let trouvees = await relu.search("aiguille")
        #expect(trouvees.count == 1)
        #expect(trouvees.first?.copiedAt == vieux)
    }

    @Test("La recherche ignore la casse et les accents, et sait chercher par application")
    func rechercheTolerante() async throws {
        let root = try makeRoot()
        let store = makeStore(at: root)
        await store.save(text("Résumé de la réunion", from: "Chrome"))
        await store.save(text("autre chose", at: Self.noon.addingTimeInterval(1), from: "Terminal"))

        #expect(await store.search("resume").count == 1)
        #expect(await store.search("RÉSUMÉ").count == 1)
        #expect(await store.search("Terminal").first?.preview == "autre chose")
        #expect(await store.search("   ").isEmpty)
    }

    @Test("La recherche ne rend pas deux fois la même entrée à cheval sur la fenêtre")
    func rechercheSansDoublon() async throws {
        let root = try makeRoot()
        let store = makeStore(at: root)
        for index in 0..<6 {
            await store.save(
                text("cible \(index)", at: Self.noon.addingTimeInterval(Double(index)))
            )
        }

        let relu = makeStore(at: root, windowSize: 3)
        await relu.load()
        let trouvees = await relu.search("cible")
        #expect(trouvees.count == 6)
        #expect(Set(trouvees.map(\.id)).count == 6)
    }

    // MARK: - Le dossier lui-même

    @Test("Un premier lancement ne se plaint de rien")
    func premierLancementSilencieux() async throws {
        let root = try makeRoot()
        let store = makeStore(at: root)
        #expect(await store.load() == 0)
        #expect(store.problem == nil)
    }

    @Test("Un dossier illisible se plaint, plutôt que de ressembler à une bibliothèque vide")
    func dossierIllisible() async throws {
        let root = try makeRoot()
        // Un fichier là où la bibliothèque attend un dossier : le cas le plus
        // simple à fabriquer, et il produit exactement la panne qu'on veut voir
        // dite plutôt qu'affichée en liste vide.
        try Data("pas un dossier".utf8).write(to: root.appending(path: "Clipboard"))

        let store = makeStore(at: root)
        #expect(await store.load() == 0)
        #expect(store.problem != nil)
    }

    @Test("Changer la racine dans les réglages déménage la bibliothèque tout de suite")
    func racineMobile() async throws {
        let premier = try makeRoot()
        let second = try makeRoot()
        let racine = Root(premier)
        let store = ClipboardStore(root: { racine.url })

        await store.save(text("dans le premier"))
        racine.url = second
        await store.save(text("dans le second", at: Self.noon.addingTimeInterval(1)))

        #expect(names(in: premier.appending(path: "Clipboard/\(dayKey(Self.noon))")).count == 2)
        #expect(names(in: second.appending(path: "Clipboard/\(dayKey(Self.noon))")).count == 2)
        // Et chacune est bien dans la sienne, pas dupliquée.
        #expect(await ClipboardStore(root: { premier }).load() == 1)
        #expect(await ClipboardStore(root: { second }).load() == 1)
    }

    @Test("Les octets des contenus sont comptés pour les réglages")
    func comptageDesOctets() async throws {
        let root = try makeRoot()
        let store = makeStore(at: root, retention: .days(7))

        await store.save(text("A"), payloads: [payload("douze octets")])
        await store.save(
            text("B", at: Self.noon.addingTimeInterval(-30 * Self.day)),
            payloads: [payload("PNG")]
        )
        await store.load()
        #expect(store.blobBytes == Int64(Data("douze octets".utf8).count + 3))

        _ = await store.purgeExpired(now: Self.noon)
        #expect(store.blobBytes == Int64(Data("douze octets".utf8).count))
    }

    // MARK: - Les noms qu'on reconnaît

    @Test("Seul un nom que le magasin aurait pu écrire est ramassable")
    func nomsRamassables() {
        let empreinte = String(repeating: "a1", count: 32)
        #expect(ClipboardStore.isSelfWritten("\(empreinte).png"))
        #expect(ClipboardStore.isSelfWritten(empreinte))
        #expect(ClipboardStore.isSelfWritten("\(empreinte).") == false)
        #expect(ClipboardStore.isSelfWritten("\(empreinte.uppercased()).png") == false)
        #expect(ClipboardStore.isSelfWritten("\(empreinte.dropLast()).png") == false)
        #expect(ClipboardStore.isSelfWritten("capture.png") == false)
        #expect(ClipboardStore.isSelfWritten("index.jsonl") == false)
    }

    // MARK: - Ce qu'une revue a trouvé, et que ces tests gèlent

    /// **Le pire des quatre : un dossier illisible faisait supprimer ses
    /// contenus.**
    ///
    /// `try? contentsOfDirectory ?? []` rendait la même chose pour « ce dossier
    /// est vide » et « je n'ai pas le droit de le lire ». Or le ramassage
    /// d'orphelins décide de supprimer **par l'absence d'une citation** : zéro
    /// sidecar lisible voulait dire zéro empreinte citée, donc tout le contenu
    /// du `blobs/` devenait orphelin. `chmod 300` suffit — le droit de traversée
    /// reste, donc `blobs/` se liste encore pendant que les sidecars ne se
    /// listent plus.
    @Test("Un dossier-jour illisible ne fait supprimer aucun contenu")
    func dossierJourIllisibleNeFaitRienSupprimer() async throws {
        let root = try makeRoot()
        let store = makeStore(at: root)
        await store.save(text("l'entrée qui cite son image"), payloads: [payload("des octets")])

        let jour = store.dayFolder(dayKey(Self.noon))
        let blobs = jour.appending(path: "blobs")
        #expect(names(in: blobs).count == 1)

        let manager = FileManager.default
        try manager.setAttributes([.posixPermissions: 0o300], ofItemAtPath: jour.path)
        defer { try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: jour.path) }

        // La condition du test : le dossier-jour ne se liste plus, mais son
        // `blobs/` s'ouvre encore par son nom. Sans ça le test ne prouverait
        // rien, puisque le balayage ne verrait aucun fichier à supprimer.
        #expect(ClipboardStore.listing(of: jour).unreadable)
        #expect(names(in: blobs).count == 1)

        #expect(await store.collectOrphanedBlobs() == 0)
        #expect(names(in: blobs).count == 1)
    }

    /// Le même dossier illisible ne doit pas non plus **effacer l'index**. La
    /// reconstruction se déclenche sur un désaccord entre l'index et les
    /// sidecars ; un dossier qu'on ne sait pas lister n'annonce aucun sidecar,
    /// donc l'index paraissait mentir et se faisait réécrire vide. Le jour
    /// disparaissait de l'historique sur une panne de droits.
    @Test("Un dossier-jour illisible ne fait pas réécrire son index à vide")
    func dossierJourIllisibleNeVidePasSonIndex() async throws {
        let root = try makeRoot()
        let store = makeStore(at: root)
        await store.save(text("ce que l'index cite"))

        let jour = store.dayFolder(dayKey(Self.noon))
        let index = jour.appending(path: ClipboardStore.indexFileName)
        let avant = try Data(contentsOf: index)

        let manager = FileManager.default
        try manager.setAttributes([.posixPermissions: 0o300], ofItemAtPath: jour.path)
        defer { try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: jour.path) }

        let relu = makeStore(at: root)
        #expect(await relu.load() == 1)                       // l'index sait encore le dire
        #expect(try Data(contentsOf: index) == avant)         // et il n'a pas été touché
    }

    /// **Un index qui ment durablement, et que rien ne rattrapait.** La
    /// vérification compare les identifiants ; une entrée réécrite — recopiée,
    /// purgée de ses blobs — garde le sien, donc un index resté à l'état
    /// précédent passait la vérification pour toujours. En cas d'échec de
    /// réécriture, l'index est donc **supprimé** : l'absence se répare à la
    /// lecture suivante, le mensonge non.
    ///
    /// La panne est fabriquée en mettant un dossier à la place de
    /// `index.jsonl` : `Data.write` ne peut pas l'écraser.
    @Test("Un index qu'on n'a pas pu réécrire est supprimé, jamais laissé périmé")
    func indexNonReecritEstSupprime() async throws {
        let root = try makeRoot()
        let store = makeStore(at: root)
        let entree = text("copiée une fois")
        await store.save(entree)

        let jour = store.dayFolder(dayKey(Self.noon))
        let index = jour.appending(path: ClipboardStore.indexFileName)
        try FileManager.default.removeItem(at: index)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)

        #expect(await store.rebuildIndex(on: dayKey(Self.noon)) == 1)
        #expect(store.problem != nil)
        #expect(FileManager.default.fileExists(atPath: index.path(percentEncoded: false)) == false)

        // Et l'absence se répare toute seule : les sidecars font foi.
        let relu = makeStore(at: root)
        #expect(await relu.load() == 1)
        #expect(relu.recent.first?.preview == "copiée une fois")
    }

    /// **Deux séquences disque qui s'entrelacent sur le même acteur.**
    ///
    /// `save` écrit le blob, puis le sidecar, puis la ligne d'index, avec un
    /// `await` entre chaque — et un `await` rend la main. Une purge réveillée
    /// entre deux pouvait supprimer le `blobs/` d'hier pendant qu'une copie de
    /// la veille s'y écrivait, laissant une entrée qui cite un fichier effacé.
    /// L'invariant vérifié ici est le seul qui compte : **aucune entrée vivante
    /// ne cite un fichier absent**, quel que soit l'ordre dans lequel la file
    /// les a exécutées.
    @Test("Une purge et une écriture concurrentes ne laissent aucune référence morte")
    func purgeEtEcritureConcurrentes() async throws {
        let root = try makeRoot()
        // Zéro jour : tout ce qui n'est pas d'aujourd'hui perd ses blobs au
        // premier balayage. C'est le réglage qui rend la fenêtre atteignable.
        let store = makeStore(at: root, retention: .days(0))
        let hier = Self.noon.addingTimeInterval(-Self.day)

        async let ecriture = store.save(
            ClipboardEntry(copiedAt: hier, kind: .image, preview: ""),
            payloads: [payload("l'image d'hier")]
        )
        async let purge = store.purgeExpired(now: Self.noon)
        _ = await (ecriture, purge)

        let relu = makeStore(at: root)
        await relu.load()
        for entree in relu.recent where entree.blobsArePurged == false {
            for reference in entree.blobs ?? [] {
                let url = try #require(relu.blobURL(for: reference, of: entree))
                #expect(
                    FileManager.default.fileExists(atPath: url.path(percentEncoded: false)),
                    "une entrée non purgée cite \(reference.fileName), qui n'existe pas"
                )
            }
        }
    }

    /// Le pendant du précédent, sur la purge seule : marquer d'abord, supprimer
    /// ensuite, et **ne rien supprimer si le marquage a échoué** — sans quoi
    /// l'inversion de l'ordre ne servait à rien. Le marquage est mis en échec
    /// avec la même astuce que plus haut.
    @Test("Une purge dont le marquage échoue ne supprime aucun contenu")
    func purgeSansMarquageNeSupprimeRien() async throws {
        let root = try makeRoot()
        let store = makeStore(at: root, retention: .days(0))
        let hier = Self.noon.addingTimeInterval(-Self.day)
        await store.save(
            ClipboardEntry(copiedAt: hier, kind: .image, preview: ""),
            payloads: [payload("l'image d'hier")]
        )

        let jour = store.dayFolder(dayKey(hier))
        let blobs = jour.appending(path: "blobs")
        #expect(names(in: blobs).count == 1)

        // L'index est rendu immuable : ni la suppression ni la réécriture
        // atomique ne peuvent l'emporter, donc la purge n'a rien pu annoncer.
        // Le dossier-jour, lui, reste inscriptible — sans quoi la suppression
        // des contenus échouerait d'elle-même et le test ne prouverait rien.
        let manager = FileManager.default
        let index = jour.appending(path: ClipboardStore.indexFileName)
        try manager.setAttributes([.immutable: true], ofItemAtPath: index.path)
        defer { try? manager.setAttributes([.immutable: false], ofItemAtPath: index.path) }

        #expect(await store.purgeExpired(now: Self.noon) == 0)
        #expect(store.problem != nil)
        #expect(names(in: blobs).count == 1, "le contenu a été supprimé sans que rien ne l'annonce")
    }
}
