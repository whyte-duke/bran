import CryptoKit
import Foundation
import Observation
import os

/// Le journal du magasin. Hors de la classe pour la même raison que celui de
/// `ContentStore` : un `Logger` est fait pour être partagé, pas reconstruit à
/// chaque ligne.
private let clipboardLog = Logger(subsystem: "com.opahventures.bran", category: "clipboard")

// MARK: - Ce qu'on donne au magasin à écrire

/// Un contenu lourd à poser dans `blobs/`, avant qu'il ait un nom.
///
/// **Le nom est calculé ici, pas fourni.** Le fichier est adressé par
/// l'empreinte de son contenu — voir `ClipboardBlobRef` — et laisser l'appelant
/// nommer reviendrait à laisser trois appelants hacher de trois façons. Le
/// magasin hache, le magasin nomme, et la déduplication à l'intérieur d'une
/// journée tombe toute seule : deux copies identiques écrivent le même fichier.
public struct ClipboardBlobPayload: Sendable, Equatable {

    /// Le contenu, déjà en mémoire. Le presse-papiers rend des `Data` ; il n'y a
    /// pas de flux à ménager, et `maximumBlobBytes` plafonne déjà la taille.
    public let data: Data

    /// L'extension, sans le point. Non décorative : c'est elle qui permet à
    /// Quick Look d'ouvrir le fichier depuis le Finder.
    public let ext: String

    public init(data: Data, ext: String) {
        self.data = data
        self.ext = ext
    }

    /// L'empreinte SHA-256 du contenu, en hexadécimal minuscule.
    ///
    /// Minuscule et fixée ici : le nom du fichier en dépend, et une casse qui
    /// changerait entre deux versions ferait réécrire toute la bibliothèque en
    /// double sur un système de fichiers sensible à la casse.
    public var hash: String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public var ref: ClipboardBlobRef {
        ClipboardBlobRef(hash: hash, ext: ext, bytes: data.count)
    }
}

// MARK: - Le magasin

/// L'historique du presse-papiers sur le disque : un dossier par jour, un
/// sidecar par entrée, un index dérivé par jour, et les contenus lourds à côté.
///
/// ```
/// ~/…/bran/Clipboard/
///   2026-08-10/
///     <uuid>.json                ← l'entrée, gardée pour toujours
///     index.jsonl                ← une ligne par entrée, dérivée, jetable
///     blobs/<sha256>.png         ← le contenu lourd, purgé après 30 jours
/// ```
///
/// ## Pourquoi pas `ContentStore`
///
/// Il a été extrait pour les captures et les dictées, et il ne va pas ici. Trois
/// désaccords, dont aucun ne se règle par un paramètre : il range tout à plat
/// dans un seul dossier alors que le presse-papiers écrit ~53 entrées par jour
/// — c'est ce volume qui a imposé les dossiers-jours ; il n'admet qu'**un**
/// fichier lourd par entrée alors qu'un `richText` en porte deux et une sélection
/// du Finder N ; et sa purge met `blobFileName` à `nil`, effaçant précisément la
/// référence morte que `ClipboardEntry.blobsPurgedAt` existe pour conserver.
/// Ce qui est partagé l'est vraiment : `ClipboardRetention` satisfait
/// `ContentRetentionPolicy` sans une ligne de changement.
///
/// ## L'ordre d'écriture, et ce qu'il achète
///
/// **Blob, puis sidecar, puis la ligne d'index.** Un plantage peut donc laisser
/// un blob que personne ne cite — ramassable, voir `collectOrphanedBlobs()` — ou
/// un sidecar absent de l'index — rattrapé à la lecture suivante, voir
/// `entries(on:)`. Il ne peut jamais laisser une ligne qui cite un fichier
/// absent, ce qui est le seul des trois désordres qui se voit à l'usage : un
/// bouton « coller » qui échoue au clic.
///
/// `Data.write(options: .atomic)` partout, pour les sidecars comme pour les
/// blobs. Un utilitaire `fsync` maison a été envisagé et écarté par
/// `ContentStore` pour une raison qui vaut ici mot pour mot : le mode de
/// défaillance annoncé est un plantage de l'application, pas une coupure de
/// courant.
///
/// L'ajout d'une ligne d'index est la seule écriture non atomique du magasin, et
/// c'est délibéré : réécrire 53 lignes à chaque copie pour protéger la dernière
/// serait payer sur le chemin chaud ce que la vérification de `entries(on:)`
/// répare gratuitement à la lecture.
///
/// ## L'index est dérivé, et le magasin en fait la preuve à chaque lecture
///
/// La vérité est l'ensemble des sidecars. L'index n'est qu'une concaténation qui
/// évite d'ouvrir 53 fichiers pour en lire un jour — le supprimer est une
/// opération sûre, et le laisser pourrir aussi. Chaque lecture d'un jour compare
/// les identifiants cités par l'index à la liste des `<uuid>.json` présents ; au
/// moindre désaccord — index absent, ligne coupée par un plantage, sidecar
/// ajouté par une restauration — l'index est reconstruit depuis les sidecars et
/// réécrit. La comparaison coûte un listage de dossier, que la lecture fait de
/// toute façon.
///
/// ## `@MainActor`, et le lourd ailleurs
///
/// Même forme que les quatre autres magasins, `root` compris : une fermeture et
/// non une `URL` figée, sinon changer le dossier dans les réglages ne
/// déménagerait la bibliothèque qu'au prochain lancement. Tout ce qui touche
/// vraiment le disque est une `nonisolated static` attendue depuis ici — le
/// motif de `RecordingStore.scan(root:)` — pour que hacher 32 Mio d'image ne
/// gèle pas le panneau.
@MainActor
@Observable
public final class ClipboardStore {

    // MARK: - Ce que l'interface lit

    /// La fenêtre en mémoire : les ~500 entrées les plus récentes, de la plus
    /// récente à la plus ancienne selon `lastCopiedAt`.
    ///
    /// **Le panneau ne doit jamais lire le disque en s'ouvrant.** C'est la seule
    /// exigence de performance de cette fonctionnalité : le geste est un
    /// raccourci clavier, et une liste qui apparaît en 200 ms se fait remplacer
    /// par celle qui apparaît tout de suite. La fenêtre est remplie une fois par
    /// `load()`, puis tenue à jour par les écritures.
    public private(set) var recent: [ClipboardEntry] = []

    /// Octets occupés par les contenus lourds, tous jours confondus. Affiché
    /// dans les réglages : une rétention se règle mieux quand on voit ce qu'elle
    /// coûte. Rafraîchi par `load()` et par la purge, pas à chaque copie — c'est
    /// un chiffre de réglages, pas un compteur temps réel.
    public private(set) var blobBytes: Int64 = 0

    /// **Ce qui empêche de lire ou d'écrire, quand quelque chose l'empêche.**
    ///
    /// Deux emplacements nommés derrière, comme chez `WatchStore` et
    /// `ContentStore`, parce qu'ils ne s'éteignent pas au même moment : une
    /// relecture qui repasse ne réfute pas un disque qui a refusé une écriture,
    /// et une écriture qui aboutit ne réfute pas un dossier illisible.
    public var problem: String? {
        [writeFailure, readProblem]
            .compactMap { $0 }
            .reduce(String?.none) { banner, message in
                FailureBanner.appending(message, to: banner)
            }
    }

    /// Ce que la **lecture** du dossier reproche. Effacé par la première lecture
    /// qui repasse : un volume remonté est une bonne nouvelle qui n'a pas besoin
    /// d'être acquittée.
    private(set) var readProblem: String?

    /// Ce que le disque a refusé. Survit aux relectures, s'efface à la première
    /// écriture qui aboutit entièrement.
    private(set) var writeFailure: String?

    // MARK: - Réglages du rangement

    /// **Les trois noms sont `nonisolated`, et ce n'est pas une formalité.** La
    /// classe est `@MainActor`, ce qui isole aussi ses membres statiques ; or
    /// tout ce qui touche vraiment le disque ici est `nonisolated` par
    /// conception — c'est le motif de `RecordingStore.scan(root:)`, et c'est ce
    /// qui empêche de hacher 32 Mio d'image sur le fil de l'interface. Ces
    /// fonctions-là ont besoin de savoir comment le rangement s'appelle. Les
    /// laisser isolées obligerait à recopier « index.jsonl » et « blobs » dans
    /// le code d'écriture, c'est-à-dire à avoir deux vérités pour un nom que la
    /// documentation utilisateur promet stable.
    ///
    /// Le coût est nul : ce sont des chaînes constantes, donc `Sendable`, donc
    /// lisibles de partout sans course possible.

    /// Le sous-dossier sous la racine des réglages.
    public nonisolated static let folderName = "Clipboard"

    /// Le nom de l'index d'un jour. Public parce que la documentation
    /// utilisateur promet un dossier lisible, et qu'un nom promis est un nom
    /// qu'on ne change pas sans le voir dans un diff.
    public nonisolated static let indexFileName = "index.jsonl"

    /// Le sous-dossier des contenus lourds, à l'intérieur du dossier-jour.
    public nonisolated static let blobsFolderName = "blobs"

    /// Combien d'entrées la fenêtre garde en mémoire.
    ///
    /// ~500, soit une dizaine de jours au rythme mesuré de 53 entrées par jour.
    /// Assez pour que la recherche du quotidien n'ouvre aucun fichier, assez peu
    /// pour que le chargement au lancement reste sous les 50 ms. Au-delà, la
    /// recherche descend sur le disque — voir `search(_:limit:)`.
    public static let windowSize = 500

    private let root: @MainActor () -> URL
    private var retention: ClipboardRetention

    /// La taille effective de la fenêtre. Paramétrable **pour les tests
    /// seulement** : borner la fenêtre est un comportement, et le vérifier en
    /// écrivant 501 entrées transformerait une suite de tests d'une milliseconde
    /// en une suite de plusieurs secondes. Aucun appelant de production ne passe
    /// autre chose que le défaut.
    private let window: Int

    public init(
        root: @escaping @MainActor () -> URL,
        retention: ClipboardRetention = .default,
        windowSize: Int = ClipboardStore.windowSize
    ) {
        self.root = root
        self.retention = retention
        self.window = Swift.max(1, windowSize)
    }

    /// La racine de la bibliothèque du presse-papiers.
    public var folder: URL {
        root().appending(path: Self.folderName, directoryHint: .isDirectory)
    }

    /// Le dossier d'un jour, `AAAA-MM-JJ`.
    public func dayFolder(_ day: String) -> URL {
        folder.appending(path: day, directoryHint: .isDirectory)
    }

    /// L'emplacement d'un contenu lourd, ou `nil` s'il n'y a plus rien à ouvrir.
    ///
    /// **Rend `nil` pour une entrée purgée sans toucher au disque.** Le bouton
    /// qui en dépend se désactive avec sa raison — « purgée le 10 août », que
    /// `ClipboardEntry` sait formuler — plutôt que d'échouer au clic. Ne teste
    /// pas l'existence du fichier : ce serait un accès disque par ligne
    /// affichée, et la référence morte est déjà déclarée dans l'entrée.
    public func blobURL(for ref: ClipboardBlobRef, of entry: ClipboardEntry) -> URL? {
        guard entry.blobsArePurged == false else { return nil }
        return dayFolder(entry.dayFolderName())
            .appending(path: Self.blobsFolderName, directoryHint: .isDirectory)
            .appending(path: ref.fileName)
    }

    /// Change la politique et applique tout de suite ce qu'elle rend caduc :
    /// raccourcir la rétention dans les réglages doit libérer le disque à cet
    /// instant, pas au prochain lancement. Même parti pris que
    /// `ContentStore.setRetention`.
    public func setRetention(_ policy: ClipboardRetention) {
        retention = policy
        Task { await purgeExpired() }
    }

    public var currentRetention: ClipboardRetention { retention }

    // MARK: - Une opération disque à la fois

    /// La queue de la file des opérations. Chaque nouvelle attend la précédente.
    private var queue: Task<Void, Never> = Task {}

    /// Exécute `work` après tout ce qui a été demandé avant lui.
    ///
    /// **`@MainActor` ne sérialise pas une séquence, il sérialise une
    /// instruction.** C'est la confusion que ce petit mécanisme corrige, et elle
    /// coûtait une entrée fausse pour toujours. `save` fait trois gestes séparés
    /// par des `await` — écrire les blobs, écrire le sidecar, ajouter la ligne
    /// d'index — et chaque `await` rend la main : une autre méthode du magasin
    /// peut s'exécuter **entre** deux d'entre eux, sur le même acteur, sans
    /// qu'aucun `Sendable` ni aucun verrou n'ait été violé.
    ///
    /// Le cas mesurable, trouvé en revue : une copie faite juste avant minuit et
    /// écrite juste après, avec une rétention à zéro jour. `save` pose le blob
    /// dans le dossier d'hier ; `purgeExpired`, qui vient de se réveiller,
    /// supprime le `blobs/` d'hier ; `save` reprend et écrit un sidecar et une
    /// ligne d'index qui citent un fichier déjà effacé. C'est exactement la
    /// référence morte que l'ordre blob → sidecar → index existe pour rendre
    /// impossible, obtenue en passant par-dessous.
    ///
    /// **Un `actor` aurait le même trou.** La réentrance sur `await` n'est pas
    /// une faiblesse du main actor, c'est la sémantique de tous les acteurs
    /// Swift : un acteur garantit qu'un seul fil touche l'état, jamais qu'une
    /// suite d'`await` est atomique. Ce qu'il faut est une file d'attente, et
    /// c'est ce qu'est cette propriété.
    ///
    /// La tâche est **non structurée exprès** : l'annulation ne s'y hérite pas,
    /// donc un appelant qui renonce n'interrompt pas une écriture à mi-chemin ni
    /// ne casse la chaîne pour les suivants.
    private func serialized<T: Sendable>(_ work: @escaping @MainActor () async -> T) async -> T {
        let previous = queue
        let task = Task { @MainActor in
            await previous.value
            return await work()
        }
        queue = Task { @MainActor in _ = await task.value }
        return await task.value
    }

    // MARK: - Lecture

    /// Remplit la fenêtre en mémoire, en remontant les jours du plus récent au
    /// plus ancien jusqu'à `windowSize` entrées.
    ///
    /// Appelée une fois au lancement. **Pas à chaque ouverture du panneau** : le
    /// panneau lit `recent`, qui est tenu à jour par les écritures, et c'est tout
    /// l'intérêt d'avoir une fenêtre.
    ///
    /// S'arrête dès que la fenêtre est pleine : au rythme mesuré, elle l'est au
    /// bout d'une dizaine de jours, donc dix `index.jsonl` lus et 355 dossiers
    /// jamais ouverts. C'est ce qui tient la promesse des 50 ms.
    ///
    /// - Returns: le nombre d'entrées chargées.
    @discardableResult
    public func load() async -> Int {
        await serialized { await self.performLoad() }
    }

    private func performLoad() async -> Int {
        let base = folder
        let days = await Self.dayFolderNames(in: base)

        var gathered: [ClipboardEntry] = []
        var faults = 0

        for day in days {
            let read = await Self.readDay(dayFolder: base.appending(path: day), day: day)
            faults += read.faults
            if read.rebuilt {
                clipboardLog.notice("Index reconstruit depuis les sidecars : \(day, privacy: .public)")
            }
            gathered.append(contentsOf: read.entries)
            if gathered.count >= window { break }
        }

        recent = Self.ordered(gathered).prefix(window).map { $0 }
        blobBytes = await Self.totalBlobBytes(in: base, days: days)

        // Un dossier absent est normal — c'est le premier lancement. Un dossier
        // présent et illisible ne doit jamais ressembler à une bibliothèque
        // vide : c'est la pire forme d'un défaut de lecture, elle a l'air d'une
        // perte de données.
        readProblem = Self.readProblem(for: base)
        if faults > 0 {
            clipboardLog.error("\(faults, privacy: .public) entrée(s) illisible(s) au chargement")
        }
        return recent.count
    }

    /// Les jours présents sur le disque, du plus récent au plus ancien.
    ///
    /// Ne rend que ce qui est **manifestement** une date. Un `.DS_Store`, un
    /// dossier « à trier » déposé par l'utilisateur, un fichier posé à la racine :
    /// tout cela n'est pas un jour, donc n'est jamais lu, donc n'est jamais
    /// supprimé. La validation est celle de `ClipboardRetention.day(from:)`, et
    /// c'est volontairement la même que celle de la purge — deux copies de la
    /// règle divergeraient au premier correctif.
    public func days() async -> [String] {
        await Self.dayFolderNames(in: folder)
    }

    /// Toutes les entrées d'un jour, index vérifié et reconstruit s'il ment.
    ///
    /// C'est ici que l'index rend des comptes. Le dossier est listé — un seul
    /// appel — et l'ensemble des `<uuid>.json` présents est comparé à l'ensemble
    /// des identifiants que l'index cite. Égalité : l'index est cru, et un seul
    /// fichier a été ouvert. Désaccord : les sidecars sont lus un à un, l'index
    /// est réécrit, et c'est la lecture des sidecars qui est rendue.
    ///
    /// Le désaccord n'est pas théorique. Il arrive à chaque plantage entre le
    /// sidecar et la ligne, à chaque `rm index.jsonl` de l'utilisateur, à chaque
    /// restauration partielle depuis une sauvegarde. Aucun des trois ne doit
    /// coûter une entrée.
    public func entries(on day: String) async -> [ClipboardEntry] {
        let read = await Self.readDay(dayFolder: dayFolder(day), day: day)
        if read.rebuilt {
            clipboardLog.notice("Index reconstruit depuis les sidecars : \(day, privacy: .public)")
        }
        return read.entries
    }

    /// Reconstruit l'index d'un jour depuis ses sidecars, qu'il mente ou non.
    ///
    /// Exposée pour ce que la vérification automatique ne couvre pas : une
    /// réparation demandée à la main, et les tests. La lecture normale n'a pas
    /// besoin qu'on l'appelle — `entries(on:)` le fait quand il le faut.
    @discardableResult
    public func rebuildIndex(on day: String) async -> Int {
        await serialized { await self.performRebuildIndex(on: day) }
    }

    private func performRebuildIndex(on day: String) async -> Int {
        let folder = dayFolder(day)
        let entries = await Self.readSidecars(in: folder).entries
        do {
            try await Self.rewriteIndex(Self.ordered(entries), in: folder)
            writeFailure = nil
        } catch {
            writeFailure = "Index du \(day) non réécrit : \(error.localizedDescription)"
        }
        return entries.count
    }

    /// Cherche dans la fenêtre, puis sur le disque si besoin.
    ///
    /// **La fenêtre d'abord, et sans toucher au disque.** C'est le cas normal :
    /// ce qu'on cherche dans un historique de presse-papiers a presque toujours
    /// été copié dans la semaine. La descente sur le disque ne se fait que si la
    /// fenêtre ne suffit pas, et elle lit un `index.jsonl` par jour — 365 petits
    /// fichiers pour une année, ce qui est tenable **hors du chemin du geste**.
    /// Appeler cette méthode à chaque frappe serait un contresens : elle est
    /// faite pour être appelée quand l'utilisateur valide sa recherche.
    ///
    /// La comparaison porte sur `preview` et sur le nom de la source — les deux
    /// choses dont on se souvient trois semaines plus tard. Insensible à la casse
    /// et aux diacritiques : chercher « resume » doit trouver « résumé », sinon
    /// la recherche punit de taper vite.
    public func search(_ query: String, limit: Int = 200) async -> [ClipboardEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard needle.isEmpty == false else { return [] }

        var found = recent.filter { Self.matches($0, needle) }
        guard found.count < limit else { return Array(found.prefix(limit)) }

        // Au-delà de la fenêtre : les jours plus anciens que le plus ancien
        // qu'elle contient. Relire les jours déjà en mémoire donnerait des
        // doublons et coûterait des fichiers pour rien.
        let base = folder
        let known = Set(recent.map(\.id))
        let covered = recent.last.map { $0.dayFolderName() }
        for day in await Self.dayFolderNames(in: base) {
            // Les jours plus récents que le plus ancien de la fenêtre y sont
            // entièrement — elle est remplie du plus récent au plus ancien, sans
            // trou. Le jour du bord, lui, est relu : la fenêtre peut s'être
            // arrêtée en plein milieu.
            if let covered, day > covered { continue }
            let read = await Self.readDay(dayFolder: base.appending(path: day), day: day)
            found.append(contentsOf: read.entries.filter {
                known.contains($0.id) == false && Self.matches($0, needle)
            })
            if found.count >= limit { break }
        }

        return Array(Self.ordered(found).prefix(limit))
    }

    // MARK: - Écriture

    /// Écrit une entrée : les blobs, puis le sidecar, puis la ligne d'index.
    ///
    /// - Parameters:
    ///   - entry: l'entrée telle que la capture l'a construite. Son `copiedAt`
    ///     décide du dossier-jour, et il n'en changera plus.
    ///   - payloads: les contenus lourds à poser. Le magasin les hache, les
    ///     nomme et renseigne `blobs` lui-même — **la valeur rendue est celle
    ///     qui est sur le disque**, pas celle qu'on lui a donnée.
    ///
    /// **Le refus de taille est décidé ici et il est global à l'entrée.** Si un
    /// seul contenu dépasse `maximumBlobBytes`, aucun n'est écrit et l'entrée
    /// naît avec `refusedBytes` : écrire le RTF d'un `richText` et refuser son
    /// HTML produirait une entrée à moitié vraie, dont l'interface ne saurait
    /// dire ni qu'elle est complète ni qu'elle est refusée. La somme est refusée,
    /// et la taille refusée est annoncée.
    ///
    /// **La déduplication est un effet du nommage, pas une étape.** Deux copies
    /// identiques dans la même journée calculent la même empreinte, donc écrivent
    /// le même fichier. Il n'y a pas de compteur de références à tenir : savoir
    /// si un blob sert encore, c'est demander si son empreinte est encore citée.
    ///
    /// - Returns: l'entrée réellement écrite.
    @discardableResult
    public func save(
        _ entry: ClipboardEntry,
        payloads: [ClipboardBlobPayload] = []
    ) async -> ClipboardEntry {
        await serialized { await self.performSave(entry, payloads: payloads) }
    }

    private func performSave(
        _ entry: ClipboardEntry,
        payloads: [ClipboardBlobPayload]
    ) async -> ClipboardEntry {
        var stored = entry
        var everythingWritten = true

        let day = entry.dayFolderName()
        let target = dayFolder(day)

        let oversized = payloads.first { ClipboardEntry.isTooLarge(bytes: $0.data.count) }
        if let oversized {
            // L'entrée existe quand même, avec son type et sa taille : c'est
            // plus honnête qu'un silence, et c'est ce qui empêche un historique
            // de presse-papiers de remplir un disque.
            stored.blobs = nil
            stored.refusedBytes = oversized.data.count
        } else if payloads.isEmpty == false {
            do {
                stored.blobs = try await Self.writeBlobs(payloads, in: target)
            } catch {
                // Le contenu lourd est un confort ; l'entrée est l'essentiel. On
                // la garde sans ses fichiers plutôt que de tout perdre — et sans
                // les citer, parce qu'une ligne qui cite un fichier absent est
                // exactement le désordre que l'ordre d'écriture existe pour
                // rendre impossible.
                stored.blobs = nil
                everythingWritten = false
                writeFailure = "Contenu non conservé : \(error.localizedDescription)"
            }
        }

        do {
            try await Self.writeSidecar(stored, in: target)
            try await Self.appendIndexLine(stored, in: target)
        } catch {
            everythingWritten = false
            writeFailure = "Écriture impossible : \(error.localizedDescription)"
        }

        if everythingWritten { writeFailure = nil }
        insert(stored)
        return stored
    }

    /// Fait monter le compteur d'une entrée déjà écrite : sidecar réécrit, index
    /// du jour réécrit.
    ///
    /// **L'index est réécrit et non complété.** Une seconde ligne pour le même
    /// identifiant serait lisible — le lecteur garde la dernière — mais elle
    /// ferait grossir l'index d'une ligne à chaque recopie, pour un fichier
    /// qu'on relit en entier. 53 lignes réécrites hors du chemin de la capture
    /// coûtent moins que la complexité de la compaction qu'il faudrait sinon.
    ///
    /// Une entrée dont le dossier n'existe plus est ignorée sans bruit :
    /// l'appelant travaille sur une ligne qu'une purge ou une suppression
    /// concurrente peut avoir retirée.
    @discardableResult
    public func recopy(_ entry: ClipboardEntry, at date: Date = .now) async -> ClipboardEntry? {
        await serialized { await self.performRecopy(entry, at: date) }
    }

    private func performRecopy(_ entry: ClipboardEntry, at date: Date) async -> ClipboardEntry? {
        let updated = entry.recopied(at: date)
        guard await rewrite(updated) else { return nil }
        insert(updated)
        return updated
    }

    /// Supprime une entrée : son sidecar, puis l'index de son jour réécrit.
    ///
    /// **Pas de pierre tombale, pas de compacteur.** Cette machinerie a été
    /// conçue pour un journal en ajout seul, où l'on ne peut pas retirer une
    /// ligne sans réécrire le fichier entier — ce qui, pour un journal d'une
    /// année, était rédhibitoire. Le rangement par jour supprime le besoin :
    /// l'unité de vérité est un fichier par entrée, la retirer est un
    /// `removeItem`, et le fichier à réécrire derrière est celui d'un seul jour.
    ///
    /// **Les blobs ne sont pas supprimés ici.** Une empreinte peut être citée par
    /// une autre entrée du même jour — c'est tout l'intérêt de l'adressage par
    /// contenu — et vérifier au moment de la suppression demanderait de relire le
    /// jour pour compter les citations. Le blob devenu inutile est ramassé par
    /// `collectOrphanedBlobs()`, qui a justement l'ensemble complet sous les yeux.
    public func delete(_ entry: ClipboardEntry) async {
        await serialized { await self.performDelete(entry) }
    }

    private func performDelete(_ entry: ClipboardEntry) async {
        let day = entry.dayFolderName()
        let target = dayFolder(day)

        do {
            try await Self.removeSidecar(entry, in: target)
            let survivors = Self.ordered(await Self.readSidecars(in: target).entries)
            try await Self.rewriteIndex(survivors, in: target)
            writeFailure = nil
        } catch {
            writeFailure = "Suppression incomplète : \(error.localizedDescription)"
        }

        recent.removeAll { $0.id == entry.id }
    }

    // MARK: - Purge

    /// Supprime les contenus lourds arrivés à échéance, dossier-jour par
    /// dossier-jour, et marque les entrées concernées.
    ///
    /// **Ce qui disparaît est le sous-dossier `blobs/` d'un jour, jamais le jour
    /// lui-même.** C'est le contrat de `ClipboardRetention`, et c'est toute la
    /// fonctionnalité : Maccy oublie au bout de 4,7 jours mesurés, et un outil
    /// qui oublie ne remplace pas la mémoire, il la simule. Le texte n'est jamais
    /// purgé. Ce sont les images qui pèsent — 99 % du volume pour moins de 10 %
    /// des lignes.
    ///
    /// **Le choix des dossiers se fait sur les noms, sans un seul accès disque.**
    /// `ClipboardRetention.dayFoldersToPurge` prend une liste de noms et rend une
    /// liste de noms ; tout ce qui ne s'analyse pas en `AAAA-MM-JJ` n'est pas un
    /// jour, donc survit. Le jour en cours n'est jamais touché — c'est celui dans
    /// lequel la capture écrit à l'instant, et supprimer sous les pieds de
    /// l'écrivain est une course, pas une purge.
    ///
    /// **Les entrées sont marquées, pas amputées.** Leurs `ClipboardBlobRef`
    /// restent, avec le type et la taille de ce qui a disparu, et
    /// `blobsPurgedAt` dit quand : l'interface peut écrire « Image de 1,2 Mo,
    /// purgée le 10 août » au lieu de « rien ». C'est exactement ce que
    /// `ContentStore` ne sait pas faire, puisqu'il met le nom de fichier à `nil`.
    ///
    /// - Returns: le nombre d'entrées dont les blobs viennent de partir.
    @discardableResult
    public func purgeExpired(now: Date = .now) async -> Int {
        await serialized { await self.performPurgeExpired(now: now) }
    }

    private func performPurgeExpired(now: Date) async -> Int {
        let base = folder
        let names = await Self.dayFolderNames(in: base)
        let today = ClipboardRetention.dayKey(for: now)
        let doomed = retention.dayFoldersToPurge(from: names, today: today)
        guard doomed.isEmpty == false else { return 0 }

        var marked = 0
        for day in doomed {
            let target = base.appending(path: day, directoryHint: .isDirectory)
            let read = await Self.readDay(dayFolder: target, day: day)
            let expired = retention.entriesToPurge(from: read.entries, now: now)

            // **Marquer d'abord, supprimer ensuite — l'ordre inverse de la
            // première version, et le choix a été retourné par une revue.**
            //
            // L'argument d'origine était qu'une entrée ne doit pas annoncer une
            // purge qui n'a pas eu lieu. Il pèse moins que son symétrique. Les
            // deux ordres laissent la même fenêtre — un plantage, un volume
            // démonté, un disque plein entre les deux gestes — mais pas le même
            // dégât :
            //
            // - supprimer d'abord et échouer à marquer laisse des entrées qui
            //   promettent un contenu **effacé**. `canPaste` répond vrai,
            //   `blobURL` rend un chemin, et le bouton « coller » échoue au
            //   clic. C'est précisément la référence morte que l'ordre
            //   d'écriture de ce fichier existe pour rendre impossible ;
            // - marquer d'abord et échouer à supprimer laisse des fichiers que
            //   plus personne ne réclame. L'utilisateur voit « purgée le 10
            //   août » pour une image encore sur le disque : il perd des octets,
            //   pas un geste.
            //
            // Et les deux se réparent au balayage suivant — la suppression du
            // dossier est retentée à chaque passage, qu'il reste ou non des
            // entrées à marquer. On choisit donc l'ordre dont la panne coûte de
            // la place plutôt que celui dont la panne coûte une promesse.
            var announced = true
            if expired.isEmpty == false {
                let purged = Set(expired.map(\.id))
                let updated = read.entries.map { entry in
                    purged.contains(entry.id) ? entry.purgingBlobs(at: now) : entry
                }
                do {
                    await Self.invalidateIndex(in: target)
                    for entry in updated where purged.contains(entry.id) {
                        try await Self.writeSidecar(entry, in: target)
                    }
                    try await Self.rewriteIndex(Self.ordered(updated), in: target)
                    for entry in updated where purged.contains(entry.id) { replaceInWindow(entry) }
                    marked += expired.count
                } catch {
                    announced = false
                    writeFailure = "Entrées du \(day) non mises à jour : \(error.localizedDescription)"
                }
            }

            // **Rien n'est supprimé tant que les entrées n'ont pas dit qu'elles
            // le seraient.** Inverser l'ordre ne suffisait pas : supprimer quand
            // même après un marquage en échec reconstruisait exactement la
            // référence morte qu'on venait d'éliminer. Le marquage est la
            // condition, pas une étape parallèle.
            //
            // Renoncer ne perd rien : le jour reste périmé, et le balayage
            // suivant refera les deux gestes dans le même ordre.
            guard announced else { continue }

            do {
                try await Self.removeBlobsFolder(in: target)
            } catch {
                writeFailure = "Contenus du \(day) non supprimés : \(error.localizedDescription)"
            }
        }

        blobBytes = await Self.totalBlobBytes(in: base, days: names)
        return marked
    }

    /// Ramasse les contenus lourds que plus aucune entrée ne cite.
    ///
    /// Appelée au lancement et une fois par jour, à côté de la purge — **jamais
    /// depuis une lecture**. Un ramassage est une suppression décidée par une
    /// absence, et une absence n'est une information que si l'on sait avoir tout
    /// lu ; ici « tout » veut dire tous les sidecars d'un jour, ce que cette
    /// méthode relit exprès plutôt que de faire confiance à l'index.
    ///
    /// ## Ce qu'il refuse de toucher
    ///
    /// Le dossier est délibérément un dossier ordinaire, que l'utilisateur est
    /// invité à ouvrir, à déplacer et à sauvegarder. **Supprimer le fichier d'un
    /// tiers parce qu'il traînait chez nous serait un défaut bien pire que celui
    /// qu'on corrige.** Ce qu'on ne sait pas classer reste, pour toujours :
    ///
    /// - tout ce qui est hors d'un `blobs/` — un sidecar, un `index.jsonl`, un
    ///   `notes.txt` posé à la main dans un dossier-jour ;
    /// - tout ce qui est dans un dossier dont le nom n'est pas une date ;
    /// - tout ce qui n'est pas un fichier régulier : un dossier nommé
    ///   `abcd.png` serait emporté avec son contenu par `removeItem` ;
    /// - tout ce qui ne porte pas **un nom que ce magasin aurait pu écrire**,
    ///   c'est-à-dire 64 caractères hexadécimaux et une extension. Une image
    ///   glissée à la main, ou l'un de nos fichiers renommé pour le retrouver,
    ///   échoue au test et reste ;
    /// - **tout le jour** dès qu'un seul de ses sidecars est illisible. Celui-là
    ///   est le piège : l'entrée n'a pas décodé, donc personne ne cite son blob,
    ///   donc la soustraction le donne orphelin. Or un `.json` abîmé est peut-être
    ///   récupérable à la main, et détruire l'image qui va avec transformerait
    ///   une panne réparable en perte sèche. Même verdict que `ContentStore`, qui
    ///   l'a appris à ses dépens.
    ///
    /// Une ligne de journal, et rien dans `problem` : un bandeau annonçant
    /// « 3 fichiers récupérés » parlerait de fichiers dont l'utilisateur ignore
    /// l'existence, sans rien à en faire, en occupant le seul canal réservé aux
    /// pannes qui demandent une action.
    ///
    /// - Returns: le nombre de fichiers ramassés. Zéro dans la vie normale.
    @discardableResult
    public func collectOrphanedBlobs() async -> Int {
        await serialized { await self.performCollectOrphanedBlobs() }
    }

    private func performCollectOrphanedBlobs() async -> Int {
        let base = folder
        let days = await Self.dayFolderNames(in: base)
        var collected = 0
        var reclaimed: Int64 = 0

        for day in days {
            let target = base.appending(path: day, directoryHint: .isDirectory)
            let read = await Self.readSidecars(in: target)

            // Un sidecar illisible épargne le jour entier : on ne sait pas ce
            // qu'il citait.
            guard read.faults == 0 else {
                clipboardLog.notice(
                    "Ramassage suspendu sur \(day, privacy: .public) : \(read.faults, privacy: .public) sidecar(s) illisible(s)"
                )
                continue
            }

            // **Et une liste qu'on n'a pas pu obtenir épargne le jour a
            // fortiori.** C'est le cas le plus dangereux des deux, parce qu'il
            // ne ressemble à rien : zéro entrée, zéro panne, donc « personne ne
            // cite rien », donc tout est orphelin. Une méthode qui décide de
            // supprimer par l'absence d'une citation n'a le droit de conclure
            // que si elle sait avoir tout lu.
            guard read.unreadable == false else {
                clipboardLog.notice(
                    "Ramassage suspendu sur \(day, privacy: .public) : dossier illisible"
                )
                continue
            }

            let claimed = Set(read.entries.flatMap { ($0.blobs ?? []).map(\.fileName) })
            let swept = await Self.sweepBlobs(in: target, claimed: claimed, day: day)
            collected += swept.count
            reclaimed += swept.bytes
        }

        if collected > 0 {
            clipboardLog.notice(
                "\(collected, privacy: .public) contenu(s) sans entrée ramassé(s), \(reclaimed, privacy: .public) octets"
            )
            blobBytes = await Self.totalBlobBytes(in: base, days: days)
        }
        return collected
    }

    // MARK: - La fenêtre en mémoire

    /// Insère ou remplace, en gardant l'ordre que `load()` reconstruirait.
    ///
    /// **L'ordre suit `lastCopiedAt`, pas l'ordre d'arrivée.** Insérer en tête
    /// sans regarder la date donnerait une liste que le prochain lancement ne
    /// reproduirait pas, et le symptôme — une liste qui se réordonne toute seule
    /// au redémarrage — ne se relie à rien. `ContentStore` a fait l'erreur ; elle
    /// y tenait par chance, parce que ses deux appelants écrivaient `.now`.
    private func insert(_ entry: ClipboardEntry) {
        recent.removeAll { $0.id == entry.id }
        let index = recent.firstIndex { $0.lastCopiedAt <= entry.lastCopiedAt } ?? recent.count
        recent.insert(entry, at: index)
        if recent.count > window { recent.removeLast(recent.count - window) }
    }

    /// Remplace une entrée déjà dans la fenêtre, sans l'y faire entrer si elle
    /// n'y était pas. La purge s'en sert : marquer les blobs d'une entrée de
    /// l'an dernier ne doit pas la remonter dans le panneau.
    private func replaceInWindow(_ entry: ClipboardEntry) {
        guard let index = recent.firstIndex(where: { $0.id == entry.id }) else { return }
        recent[index] = entry
    }

    /// Réécrit sidecar et index pour une entrée qui existe déjà.
    private func rewrite(_ entry: ClipboardEntry) async -> Bool {
        let target = dayFolder(entry.dayFolderName())
        guard await Self.sidecarExists(entry, in: target) else { return false }
        do {
            // L'index part avant le sidecar : voir `invalidateIndex(in:)`. Une
            // recopie garde son identifiant, donc un index périmé sur elle ne
            // se détecte pas — il faut l'empêcher, pas le rattraper.
            await Self.invalidateIndex(in: target)
            try await Self.writeSidecar(entry, in: target)
            let all = Self.ordered(await Self.readSidecars(in: target).entries)
            try await Self.rewriteIndex(all, in: target)
            writeFailure = nil
            return true
        } catch {
            writeFailure = "Écriture impossible : \(error.localizedDescription)"
            return false
        }
    }

    /// L'ordre de la liste : la copie la plus récente en premier.
    ///
    /// `lastCopiedAt` et non `copiedAt` — c'est ce que `ClipboardEntry` désigne
    /// comme l'ordre d'affichage, et c'est le seul endroit où le tri est écrit.
    /// À égalité, l'identifiant départage, pour que deux copies de la même
    /// seconde ne changent pas d'ordre entre deux lectures.
    ///
    /// `nonisolated` pour la même raison que les noms de dossiers : la lecture
    /// d'un jour trie ses entrées hors du main actor, et c'est justement là
    /// qu'il ne faut pas d'une deuxième définition de l'ordre.
    nonisolated static func ordered(_ entries: [ClipboardEntry]) -> [ClipboardEntry] {
        entries.sorted {
            $0.lastCopiedAt == $1.lastCopiedAt
                ? $0.id.uuidString > $1.id.uuidString
                : $0.lastCopiedAt > $1.lastCopiedAt
        }
    }

    /// Insensible à la casse **et aux diacritiques** : chercher « resume » doit
    /// trouver « résumé ». Une recherche qui punit de taper vite n'est pas
    /// utilisée deux fois.
    static func matches(_ entry: ClipboardEntry, _ needle: String) -> Bool {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        if entry.preview.range(of: needle, options: options) != nil { return true }
        if let name = entry.source?.name,
           name.range(of: needle, options: options) != nil { return true }
        return false
    }

    // MARK: - Le disque

    /// Ce qu'une lecture de jour a trouvé.
    struct DayRead: Sendable {

        /// Les entrées, dans l'ordre d'affichage.
        let entries: [ClipboardEntry]

        /// Combien de fichiers ont refusé de se décoder. Non bloquant : les
        /// autres entrées du jour s'affichent normalement — une ligne abîmée ne
        /// doit pas emporter la journée.
        let faults: Int

        /// L'index a-t-il dû être reconstruit ? Vrai dit qu'il mentait.
        let rebuilt: Bool
    }

    /// Lit un jour, en vérifiant que son index dit la vérité.
    ///
    /// La vérification est un listage de dossier, que la lecture fait de toute
    /// façon pour savoir ce qu'il y a. Comparer deux ensembles d'identifiants
    /// coûte donc zéro accès disque de plus, et c'est ce qui rend défendable de
    /// croire l'index le reste du temps.
    ///
    /// **Le nombre ne suffit pas, il faut les identifiants.** Un sidecar
    /// supprimé et un autre ajouté dans le même intervalle laissent le compte
    /// inchangé et l'index faux. C'est le genre de coïncidence qui n'arrive
    /// jamais jusqu'au jour où une restauration depuis une sauvegarde la
    /// fabrique.
    /// **Un dossier illisible n'est jamais traité comme un dossier vide.** C'est
    /// la distinction que `listing(of:)` existe pour faire, et sans elle la
    /// reconstruction se retournait contre les données : un jour dont les
    /// sidecars ne se listent pas rendait un ensemble vide, l'index paraissait
    /// mentir, et on réécrivait un `index.jsonl` **vide** par-dessus un index
    /// parfaitement exact. Le jour disparaissait de l'historique sur une panne
    /// de droits, sans un mot. Illisible, on rend donc ce que l'index dit et on
    /// ne touche à rien.
    nonisolated static func readDay(dayFolder: URL, day: String) async -> DayRead {
        let listing = self.listing(of: dayFolder)
        let indexed = readIndex(in: dayFolder)

        guard listing.unreadable == false else {
            clipboardLog.error("Dossier-jour illisible : \(day, privacy: .public)")
            return DayRead(entries: ordered(indexed.entries), faults: 1, rebuilt: false)
        }

        let sidecars = Set(
            listing.names.filter { $0.hasSuffix(".json") }
                .compactMap { UUID(uuidString: String($0.dropLast(5))) }
        )

        if indexed.faults == 0, Set(indexed.entries.map(\.id)) == sidecars {
            return DayRead(entries: ordered(indexed.entries), faults: 0, rebuilt: false)
        }

        // L'index ment, est absent, ou porte une ligne coupée. Les sidecars font
        // foi ; l'index se refait à partir d'eux, et le refaire est gratuit
        // puisqu'on vient de tout lire.
        let truth = await readSidecars(in: dayFolder)
        let sorted = ordered(truth.entries)
        let worthRewriting = truth.entries.isEmpty == false || indexed.entries.isEmpty == false
        if worthRewriting { try? rewriteIndexSync(sorted, in: dayFolder) }
        return DayRead(entries: sorted, faults: truth.faults, rebuilt: worthRewriting)
    }

    /// Le contenu d'un dossier, en distinguant « vide » de « illisible ».
    ///
    /// **La distinction que `try? … ?? []` efface, et ce qu'elle coûtait.** Un
    /// dossier absent et un dossier dont les droits ont été retirés rendaient
    /// tous les deux la liste vide. Trois conséquences, dont la dernière est une
    /// perte de données : un jour illisible disparaissait de l'historique en
    /// silence ; `readDay` réécrivait par-dessus son index un fichier vide ; et
    /// `collectOrphanedBlobs`, qui décide de supprimer **par l'absence d'une
    /// citation**, concluait que plus personne ne citait rien et balayait tous
    /// les contenus lourds du jour. Il suffisait pour cela que le dossier-jour
    /// perde son droit de lecture en gardant son droit de traversée — `chmod
    /// 300` — pour que `blobs/` reste listable pendant que les sidecars ne le
    /// sont plus.
    ///
    /// Une absence reste une absence : `unreadable` n'est vrai que si le chemin
    /// existe et refuse de se lire. Le premier lancement, lui, n'a rien à
    /// signaler.
    nonisolated static func listing(of folder: URL) -> (names: [String], unreadable: Bool) {
        let manager = FileManager.default
        var path = folder.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        do {
            return (try manager.contentsOfDirectory(atPath: path), false)
        } catch {
            return ([], manager.fileExists(atPath: path))
        }
    }

    /// Lit `index.jsonl`, une ligne à la fois.
    ///
    /// **Une ligne illisible est sautée avec une trace, jamais avalée.** C'est la
    /// leçon de `swift-codable-ignore-defaults` : un lecteur tolérant plus un
    /// champ non optionnel ajouté au format efface un mois d'historique sans un
    /// seul message. La tolérance est nécessaire — un plantage pendant l'ajout
    /// laisse une demi-ligne — mais elle doit être bruyante, sinon elle devient
    /// le mécanisme d'une perte silencieuse. Ici la trace part au journal *et* le
    /// jour est reconstruit depuis ses sidecars, ce qui répare le cas où la ligne
    /// était simplement coupée.
    ///
    /// Le dernier exemplaire d'un identifiant gagne : un index où une réécriture
    /// aurait laissé deux lignes pour la même entrée rend l'état le plus récent
    /// plutôt qu'un doublon.
    nonisolated static func readIndex(in dayFolder: URL) -> (entries: [ClipboardEntry], faults: Int) {
        let url = dayFolder.appending(path: indexFileName)
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
        else { return ([], 0) }

        let decoder = Self.decoder
        var byID: [UUID: ClipboardEntry] = [:]
        var order: [UUID] = []
        var faults = 0

        for line in text.split(whereSeparator: \.isNewline) {
            let raw = Data(line.utf8)
            guard let entry = try? decoder.decode(ClipboardEntry.self, from: raw) else {
                faults += 1
                let name = dayFolder.lastPathComponent
                clipboardLog.error(
                    "Ligne d'index illisible dans \(name, privacy: .public) (\(raw.count, privacy: .public) octets), reconstruction depuis les sidecars"
                )
                continue
            }
            if byID.updateValue(entry, forKey: entry.id) == nil { order.append(entry.id) }
        }

        return (order.compactMap { byID[$0] }, faults)
    }

    /// Lit tous les sidecars d'un jour. C'est la vérité, et c'est cher : un
    /// fichier ouvert par entrée. N'est appelée que quand l'index a démérité, à
    /// la suppression, et au ramassage.
    ///
    /// Un sidecar illisible est compté, pas silencieux, et pas fatal : les autres
    /// entrées du jour restent lisibles.
    ///
    /// **`unreadable` n'est pas la même chose que `faults`, et confondre les
    /// deux perdrait des fichiers.** `faults` dit « j'ai vu ces entrées et l'une
    /// d'elles ne décode pas » ; `unreadable` dit « je n'ai pas pu voir la
    /// liste ». Seul le second interdit de conclure quoi que ce soit d'une
    /// absence — et le ramassage d'orphelins ne décide que par des absences.
    nonisolated static func readSidecars(
        in dayFolder: URL
    ) async -> (entries: [ClipboardEntry], faults: Int, unreadable: Bool) {
        let listing = self.listing(of: dayFolder)
        let decoder = Self.decoder
        var entries: [ClipboardEntry] = []
        var faults = 0

        for name in listing.names where name.hasSuffix(".json") && name != indexFileName {
            guard UUID(uuidString: String(name.dropLast(5))) != nil else {
                // Un `.json` qui ne porte pas un UUID n'est pas des nôtres. Il
                // n'est ni lu ni compté comme une panne — et surtout jamais
                // supprimé.
                continue
            }
            let url = dayFolder.appending(path: name)
            guard let data = try? Data(contentsOf: url),
                  let entry = try? decoder.decode(ClipboardEntry.self, from: data)
            else {
                faults += 1
                clipboardLog.error("Sidecar illisible : \(name, privacy: .public)")
                continue
            }
            entries.append(entry)
        }

        return (entries, faults, listing.unreadable)
    }

    /// Les noms de dossiers-jours, du plus récent au plus ancien.
    ///
    /// Le tri est lexicographique, ce qui est exactement le tri chronologique
    /// pour `AAAA-MM-JJ` — c'est la moitié de la raison d'avoir choisi ce format.
    nonisolated static func dayFolderNames(in folder: URL) async -> [String] {
        listing(of: folder).names
            .compactMap { ClipboardRetention.day(from: $0) }
            .sorted(by: >)
    }

    /// Écrit les contenus lourds, dédupliqués par leur empreinte.
    ///
    /// Un fichier déjà présent n'est pas réécrit : même empreinte, même contenu,
    /// et réécrire coûterait le double sur une image de 2 Mio recopiée. C'est la
    /// déduplication intra-journée, et elle ne demande aucun registre.
    nonisolated static func writeBlobs(
        _ payloads: [ClipboardBlobPayload], in dayFolder: URL
    ) async throws -> [ClipboardBlobRef] {
        let manager = FileManager.default
        let blobs = dayFolder.appending(path: blobsFolderName, directoryHint: .isDirectory)
        try manager.createDirectory(at: blobs, withIntermediateDirectories: true)

        var refs: [ClipboardBlobRef] = []
        for payload in payloads {
            let ref = payload.ref
            let url = blobs.appending(path: ref.fileName)
            if manager.fileExists(atPath: url.path(percentEncoded: false)) == false {
                try payload.data.write(to: url, options: .atomic)
            }
            refs.append(ref)
        }
        return refs
    }

    /// Pose le sidecar. `.atomic` : un `<uuid>.json` à moitié écrit serait une
    /// entrée que la reconstruction compterait comme une panne à chaque lecture.
    nonisolated static func writeSidecar(_ entry: ClipboardEntry, in dayFolder: URL) async throws {
        try FileManager.default.createDirectory(at: dayFolder, withIntermediateDirectories: true)
        let data = try Self.sidecarEncoder.encode(entry)
        try data.write(to: sidecarURL(entry, in: dayFolder), options: .atomic)
    }

    /// Retire l'index d'un jour, pour que plus rien ne le croie.
    ///
    /// **À appeler avant de modifier un sidecar déjà écrit, jamais après.** La
    /// vérification de `readDay` compare les identifiants cités par l'index à
    /// ceux des sidecars présents ; elle attrape une entrée ajoutée ou
    /// supprimée, et **ne peut pas** attraper une entrée réécrite — recopiée,
    /// purgée de ses blobs — puisqu'elle garde son identifiant. Un plantage
    /// entre la réécriture du sidecar et celle de l'index laisserait donc un
    /// index qui ment sans que rien ne s'en aperçoive, pour toujours.
    ///
    /// En le supprimant d'abord, la panne devient « index absent », que la
    /// lecture suivante répare gratuitement en relisant les sidecars. On échange
    /// un mensonge permanent contre une reconstruction, c'est-à-dire contre le
    /// coût que ce fichier accepte déjà de payer à chaque désaccord.
    ///
    /// L'échec de la suppression n'est pas propagé : il n'y a rien de mieux à
    /// faire, et la réécriture qui suit reste la voie normale.
    nonisolated static func invalidateIndex(in dayFolder: URL) async {
        try? FileManager.default.removeItem(at: dayFolder.appending(path: indexFileName))
    }

    nonisolated static func removeSidecar(_ entry: ClipboardEntry, in dayFolder: URL) async throws {
        let url = sidecarURL(entry, in: dayFolder)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return }
        try FileManager.default.removeItem(at: url)
    }

    nonisolated static func sidecarExists(_ entry: ClipboardEntry, in dayFolder: URL) async -> Bool {
        FileManager.default.fileExists(
            atPath: sidecarURL(entry, in: dayFolder).path(percentEncoded: false)
        )
    }

    nonisolated static func sidecarURL(_ entry: ClipboardEntry, in dayFolder: URL) -> URL {
        dayFolder.appending(path: "\(entry.id.uuidString).json")
    }

    /// Ajoute une ligne à l'index du jour.
    ///
    /// **La seule écriture non atomique du magasin.** Un plantage au milieu
    /// laisse une demi-ligne, que `readIndex` saute en le disant et que la
    /// vérification d'identifiants fait réparer à la lecture suivante. L'entrée,
    /// elle, est déjà sur le disque dans son sidecar : rien n'est perdu, jamais.
    /// C'est précisément ce que l'ordre blob → sidecar → index achète.
    nonisolated static func appendIndexLine(_ entry: ClipboardEntry, in dayFolder: URL) async throws {
        let url = dayFolder.appending(path: indexFileName)
        let manager = FileManager.default
        var line = try Self.lineEncoder.encode(entry)
        line.append(0x0A)

        guard manager.fileExists(atPath: url.path(percentEncoded: false)) else {
            try line.write(to: url, options: .atomic)
            return
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }

    /// Réécrit l'index d'un jour entier, de façon atomique.
    ///
    /// Un index vide est écrit plutôt que supprimé : un fichier de zéro octet dit
    /// « ce jour n'a plus d'entrée », alors qu'un fichier absent est indiscernable
    /// d'un index jamais écrit et relance une reconstruction à chaque lecture.
    ///
    /// **Un échec emporte l'index avec lui.** Sans ça, une réécriture qui échoue
    /// laissait en place l'exemplaire précédent — et cet exemplaire-là ment
    /// *durablement*, ce que la vérification de `readDay` ne rattrape pas : elle
    /// compare des identifiants, et une entrée recopiée ou purgée garde le sien.
    /// L'index annoncerait donc pour toujours l'ancien compte de copies, ou un
    /// contenu lourd déjà parti. Le supprimer est explicitement une opération
    /// sûre — c'est tout le sens d'un index dérivé —, donc en cas d'échec on
    /// préfère l'absence, qui se répare toute seule à la lecture suivante, au
    /// mensonge, qui ne se répare jamais.
    nonisolated static func rewriteIndex(_ entries: [ClipboardEntry], in dayFolder: URL) async throws {
        do {
            try rewriteIndexSync(entries, in: dayFolder)
        } catch {
            try? FileManager.default.removeItem(at: dayFolder.appending(path: indexFileName))
            throw error
        }
    }

    private nonisolated static func rewriteIndexSync(
        _ entries: [ClipboardEntry], in dayFolder: URL
    ) throws {
        try FileManager.default.createDirectory(at: dayFolder, withIntermediateDirectories: true)
        let encoder = Self.lineEncoder
        var payload = Data()
        for entry in entries {
            payload.append(try encoder.encode(entry))
            payload.append(0x0A)
        }
        try payload.write(to: dayFolder.appending(path: indexFileName), options: .atomic)
    }

    /// Supprime le `blobs/` d'un jour, avec tout ce qu'il contient. C'est le
    /// `rm -rf` de la purge, et il est cadré au sous-dossier : l'`index.jsonl` et
    /// les sidecars du jour restent, parce que le texte n'est jamais purgé.
    nonisolated static func removeBlobsFolder(in dayFolder: URL) async throws {
        let url = dayFolder.appending(path: blobsFolderName, directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return }
        try FileManager.default.removeItem(at: url)
    }

    /// Supprime, dans le `blobs/` d'un jour, les fichiers que l'ensemble
    /// `claimed` ne cite pas. Les conditions de refus sont dans la doc de
    /// `collectOrphanedBlobs()` ; ici seulement leur application.
    nonisolated static func sweepBlobs(
        in dayFolder: URL, claimed: Set<String>, day: String
    ) async -> (count: Int, bytes: Int64) {
        let manager = FileManager.default
        let blobs = dayFolder.appending(path: blobsFolderName, directoryHint: .isDirectory)
        let urls = (try? manager.contentsOfDirectory(
            at: blobs,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        var count = 0
        var bytes: Int64 = 0
        for url in urls where claimed.contains(url.lastPathComponent) == false {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true,
                  isSelfWritten(url.lastPathComponent)
            else { continue }

            do {
                try manager.removeItem(at: url)
                count += 1
                bytes += Int64(values?.fileSize ?? 0)
            } catch {
                // Le nom est une empreinte : il ne nomme personne, et c'est la
                // seule information qui rende le ménage possible à la main.
                clipboardLog.error(
                    "Orphelin non supprimé dans \(day, privacy: .public) : \(url.lastPathComponent, privacy: .public) — \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        return (count, bytes)
    }

    /// Ce nom aurait-il pu être écrit par ce magasin ?
    ///
    /// 64 caractères hexadécimaux, un point, une extension non vide — ce
    /// qu'assemble `ClipboardBlobRef.fileName`, vérifié en le redécomposant.
    /// Volontairement plus strict que « c'est dans `blobs/` » : une image glissée
    /// à la main dans le dossier échoue au test et reste. Un fichier de trop
    /// coûte des octets ; un fichier de tiers supprimé coûte la confiance dans un
    /// dossier qu'on invite justement à ouvrir.
    nonisolated static func isSelfWritten(_ name: String) -> Bool {
        let parts = name.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        // Une extension vide est possible — `ClipboardBlobRef.fileName` rend
        // alors l'empreinte nue — mais un point suivi de rien ne l'est pas.
        guard parts.count <= 2, parts.count == 1 || parts[1].isEmpty == false else { return false }
        let hash = parts[0]
        guard hash.count == 64 else { return false }
        return hash.allSatisfy(\.isHexDigit) && hash.allSatisfy { $0.isUppercase == false }
    }

    /// Le total des octets occupés par les `blobs/`, tous jours confondus.
    ///
    /// Compte **tout** ce qui est dans un `blobs/`, y compris ce que nous
    /// n'aurions pas écrit : se tromper d'un fichier dans une somme est un défaut
    /// d'affichage, se tromper d'un fichier dans un `removeItem` ne se rattrape
    /// pas. Le ramassage, lui, est exigeant.
    nonisolated static func totalBlobBytes(in folder: URL, days: [String]) async -> Int64 {
        let manager = FileManager.default
        var total: Int64 = 0
        for day in days {
            let blobs = folder
                .appending(path: day, directoryHint: .isDirectory)
                .appending(path: blobsFolderName, directoryHint: .isDirectory)
            let urls = (try? manager.contentsOfDirectory(
                at: blobs, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]
            )) ?? []
            for url in urls {
                total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            }
        }
        return total
    }

    /// Ce qui empêche de lire la racine, ou `nil` si rien ne l'empêche.
    ///
    /// **Un dossier absent est normal** : c'est le premier lancement, avant la
    /// première copie. Tout le reste — volume démonté, droits retirés, chemin
    /// devenu un fichier — est un problème et doit se dire, parce qu'une
    /// bibliothèque illisible qui s'affiche vide ressemble à une perte de
    /// données. Même distinction que `RecordingStore.scan`.
    ///
    /// **La barre finale est retirée, et sans ça la moitié de la fonction ne
    /// sert à rien.** `folder` est construit avec `directoryHint: .isDirectory`,
    /// donc son chemin se termine par `/`. Mesuré sur macOS 26.5 : avec cette
    /// barre, `fileExists` rend **`false` sur un fichier régulier** — la couche
    /// POSIX en dessous refuse `stat("chemin/")` quand la cible n'est pas un
    /// répertoire. Le cas « un fichier occupe déjà ce chemin » était donc
    /// indiscernable de « rien n'existe encore », c'est-à-dire diagnostiqué
    /// comme un premier lancement : exactement la bibliothèque vide et muette
    /// que cette fonction existe pour empêcher.
    nonisolated static func readProblem(for folder: URL) -> String? {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        var path = folder.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        guard manager.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
        guard isDirectory.boolValue else {
            return "Dossier du presse-papiers illisible : un fichier occupe déjà ce chemin"
        }
        do {
            _ = try manager.contentsOfDirectory(atPath: path)
            return nil
        } catch {
            return "Dossier du presse-papiers illisible : \(error.localizedDescription)"
        }
    }

    // MARK: - JSON

    /// Le sidecar est lisible à l'œil : c'est l'exemplaire que l'utilisateur
    /// ouvrira s'il ouvre quelque chose, et celui à partir duquel une
    /// récupération à la main est possible.
    nonisolated static var sidecarEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    /// La ligne d'index, elle, tient sur une ligne — sans `.prettyPrinted`, un
    /// `JSONEncoder` n'émet aucun saut de ligne, et les sauts de ligne présents
    /// *dans* le texte sont échappés en `\n` par le format lui-même.
    nonisolated static var lineEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    nonisolated static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
