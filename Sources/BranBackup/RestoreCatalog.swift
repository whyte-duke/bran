import Foundation

// Le décodage et la navigation pure d'un parcours de snapshot — ce que
// l'utilisateur voit quand il cherche « où est passé tel dossier » avant de
// le restaurer. Comme `KopiaManifest`, aucun `Process`, aucun disque : ce
// fichier prend des octets déjà lus et rend des types, ou un échec nommé.
//
// **Pourquoi ce n'est pas `kopia snapshot ls` qu'on décode ici.** Le nom
// suggérait un parcours de répertoire ; mesuré le 02/09/2026, `kopia
// snapshot ls` est un simple alias de `kopia snapshot list` — il liste
// l'historique des sauvegardes d'une source, pas le contenu d'un dossier. La
// commande qui parcourt vraiment l'arborescence d'un snapshot est `kopia
// show <object-id>` : rendue sur un identifiant de dossier, elle sort un
// objet JSON complet — `{"stream":"kopia:directory","entries":[…],
// "summary":{…}}` — avec un enfant par ligne d'`entries`, chacun portant son
// propre identifiant d'objet pour redescendre. `kopia ls` existe aussi, mais
// en texte seul (pas de `--json`, vérifié dans son aide) ; `show` est la
// seule des deux à donner une forme structurée, et c'est elle que ce fichier
// décode. Relevé réel, sur le snapshot Music de ce dépôt :
//
// ```json
// {"stream":"kopia:directory","entries":[
//   {"name":"Music","type":"d","mode":"0755","mtime":"2025-09-05T16:46:21.616375199Z",
//    "uid":501,"gid":20,"obj":"k02a9b0ce86f817c52eb9df017d84149d",
//    "summ":{"size":51264842,"files":102,"symlinks":0,"dirs":12,
//            "maxTime":"2026-09-02T12:42:44.135100517Z","numFailed":0}},
//   {"name":".localized","type":"f","mode":"0644","mtime":"2025-08-25T14:25:11.647535Z",
//    "uid":501,"gid":20,"obj":"48dbd261f5877b7144f240baa6457f1c"}
// ],"summary":{"size":51264842,"files":103,"symlinks":0,"dirs":13,
//              "maxTime":"2026-09-02T12:42:44.135100517Z","numFailed":0}}
// ```
//
// Notez `.localized` (0 octet) : **pas de clé `size`**. Un fichier non vide
// du même dépôt (`.env.example`, 171 octets) la porte toujours. C'est
// `omitempty` côté Go sur un entier isolé : absence et zéro sont la même
// chose pour ce champ précis. **Ce n'est pas la même règle que
// `rootEntry.summ.size` dans `BackupContract`/`KopiaManifest`**, où un bloc
// entier absent est une erreur de lecture et un `size: 0` explicite est une
// source vide légitime — là, l'absence du *bloc* est ambiguë et doit rester
// une erreur. Ici, c'est un *champ scalaire* d'un struct Go qui ne connaît
// qu'une valeur zéro ; il n'y a rien d'autre que cette valeur à représenter
// quand la clé manque. D'où ``RestoreEntry/fileSize`` résolu à `0` sans
// jamais lever, alors que ``RestoreDirectorySummary`` continue d'exiger
// chacun de ses champs.
//
// Aucun lien symbolique n'a été rencontré sur ce dépôt le 02/09/2026 malgré
// une recherche récursive sur plus de 49 000 entrées (Documents/QNAP et
// Pictures). `RestoreEntryKind.symlink` existe par construction du schéma —
// kopia ne connaît que trois types d'entrée de système de fichiers,
// dossier/fichier/lien — mais sa forme JSON exacte n'est pas mesurée ici ;
// elle est traitée comme un fichier (mêmes champs, `summ` absent), ce qui
// est cohérent avec ce que kopia documente de son propre format d'entrée
// mais reste une extrapolation, pas une lecture. Tout type inconnu — y
// compris si cette extrapolation se révèle fausse un jour — tombe dans
// `.other(String)` plutôt que de faire échouer tout le décodage : un type
// d'entrée que bran ne reconnaît pas encore ne doit pas empêcher de voir le
// reste du dossier.
public enum RestoreEntryKind: Codable, Sendable, Hashable {
    case directory
    case file
    /// Voir la note ci-dessus : jamais observé sur ce dépôt, traité comme un
    /// fichier faute de mieux.
    case symlink
    /// La lettre de type que kopia a écrite, telle quelle — jamais une
    /// supposition sur ce qu'elle pourrait vouloir dire.
    case other(String)
}

/// Ce que `summ` (par entrée) ou `summary` (en tête de sortie) dit d'un
/// dossier — l'arborescence entière en dessous, pas seulement ses enfants
/// directs.
public struct RestoreDirectorySummary: Codable, Sendable, Hashable {
    public var totalSize: Int64
    public var fileCount: Int
    public var dirCount: Int
    public var symlinkCount: Int
    /// Fichiers que kopia n'a pas pu lire **au moment de la sauvegarde**, à
    /// l'intérieur de ce sous-arbre. Distinct de ce qui pourrait manquer
    /// *maintenant* dans le dépôt — voir `SnapshotProof.errorCount` pour
    /// cette autre question.
    public var failedCount: Int
    /// La date de modification la plus récente sous ce dossier. `nil`
    /// seulement si kopia a omis `maxTime` — jamais observé, mais plausible
    /// pour un dossier vide, qui n'a rien dont tirer un maximum. Un
    /// `maxTime` *présent* mais illisible, en revanche, fait échouer tout le
    /// décodage : voir ``RestoreCatalog/decodeDirectoryListing(_:)``.
    public var lastModified: Date?

    public init(
        totalSize: Int64,
        fileCount: Int,
        dirCount: Int,
        symlinkCount: Int,
        failedCount: Int,
        lastModified: Date?
    ) {
        self.totalSize = totalSize
        self.fileCount = fileCount
        self.dirCount = dirCount
        self.symlinkCount = symlinkCount
        self.failedCount = failedCount
        self.lastModified = lastModified
    }
}

/// Une entrée du parcours d'un snapshot — un enfant direct du dossier qu'on
/// vient de lister.
public struct RestoreEntry: Codable, Sendable, Hashable, Identifiable {
    public var name: String
    public var kind: RestoreEntryKind
    /// L'identifiant à passer à `kopia show`/`kopia restore` pour aller plus
    /// loin — directement, sans reconstruire de chemin.
    public var objectID: String
    public var modifiedAt: Date
    /// Le texte octal brut (`"0755"`), jamais converti en entier : ce n'est
    /// pas un nombre, c'est un texte qu'on affiche ou qu'on ne lit pas.
    public var posixMode: String
    public var ownerUID: Int?
    public var ownerGID: Int?
    /// Octets, pour un fichier ou un lien. `nil` pour un dossier — sa taille
    /// vraie, celle de toute l'arborescence en dessous, vit dans
    /// ``directorySummary``, pas ici. Voir l'en-tête du fichier sur pourquoi
    /// l'absence de la clé JSON se résout à `0` et non à une erreur.
    public var fileSize: Int64?
    /// Présent seulement quand `kind == .directory` — vérifié sur toutes les
    /// entrées de ce genre relevées le 02/09/2026, jamais absent.
    public var directorySummary: RestoreDirectorySummary?

    /// **Le nom, pas l'identifiant d'objet.** Un identifiant d'objet est
    /// adressé par contenu : deux fichiers vides du même dossier — cas réel
    /// de ce dépôt, `.localized` en plusieurs endroits — partagent le même
    /// `obj`. L'utiliser comme identité SwiftUI ferait fusionner deux lignes
    /// distinctes dans une liste ; le nom, lui, est unique par construction
    /// du système de fichiers à l'intérieur d'un même dossier.
    public var id: String { name }

    public var isDirectory: Bool { kind == .directory }

    public init(
        name: String,
        kind: RestoreEntryKind,
        objectID: String,
        modifiedAt: Date,
        posixMode: String,
        ownerUID: Int?,
        ownerGID: Int?,
        fileSize: Int64?,
        directorySummary: RestoreDirectorySummary?
    ) {
        self.name = name
        self.kind = kind
        self.objectID = objectID
        self.modifiedAt = modifiedAt
        self.posixMode = posixMode
        self.ownerUID = ownerUID
        self.ownerGID = ownerGID
        self.fileSize = fileSize
        self.directorySummary = directorySummary
    }
}

/// Le contenu d'un dossier, tel que `kopia show <object-id>` le rend pour un
/// objet de type dossier.
public struct RestoreDirectoryListing: Codable, Sendable, Hashable {
    public var entries: [RestoreEntry]
    public var summary: RestoreDirectorySummary

    public init(entries: [RestoreEntry], summary: RestoreDirectorySummary) {
        self.entries = entries
        self.summary = summary
    }
}

// MARK: - La navigation

/// Un cran du fil d'Ariane : le nom affiché, et l'identifiant d'objet qui
/// permet d'y redescendre directement sans reconstruire de chemin.
public struct RestoreBreadcrumb: Codable, Sendable, Hashable {
    public var name: String
    public var objectID: String

    public init(name: String, objectID: String) {
        self.name = name
        self.objectID = objectID
    }
}

/// Où en est la navigation dans un snapshot : sa racine, et le chemin
/// parcouru depuis.
public struct RestoreLocation: Sendable, Hashable {
    public var snapshotID: String
    public var rootObjectID: String
    public var breadcrumb: [RestoreBreadcrumb]

    public init(snapshotID: String, rootObjectID: String, breadcrumb: [RestoreBreadcrumb] = []) {
        self.snapshotID = snapshotID
        self.rootObjectID = rootObjectID
        self.breadcrumb = breadcrumb
    }

    /// L'identifiant à passer à `kopia show` pour lister ce niveau, ou à
    /// `kopia restore` pour tout restaurer à partir d'ici.
    public var currentObjectID: String { breadcrumb.last?.objectID ?? rootObjectID }

    public var isAtRoot: Bool { breadcrumb.isEmpty }

    /// Le chemin affiché à l'utilisateur — vide à la racine, sinon les noms
    /// joints par `/`. Purement pour l'affichage : ce n'est **pas** ce qu'on
    /// passe à kopia, qui reçoit toujours un identifiant d'objet direct.
    public var displayPath: String {
        breadcrumb.map(\.name).joined(separator: "/")
    }

    /// Descend dans une entrée du dossier courant.
    ///
    /// Refuse explicitement sur une entrée qui n'est pas un dossier plutôt
    /// que de construire un emplacement dont l'identifiant d'objet ne
    /// désignerait rien de navigable — descendre dans un fichier n'a pas de
    /// sens, et le faire silencieusement produirait un `RestoreLocation` qui
    /// échouerait plus tard, loin de la décision qui l'a causé.
    public func descending(into entry: RestoreEntry) throws -> RestoreLocation {
        guard entry.isDirectory else {
            throw RestoreNavigationFailure.notADirectory(name: entry.name)
        }
        var next = self
        next.breadcrumb.append(RestoreBreadcrumb(name: entry.name, objectID: entry.objectID))
        return next
    }

    /// Remonte de `levels` niveaux. Remonter au-delà de la racine s'arrête à
    /// la racine — ce n'est pas une erreur utilisateur, juste « déjà en
    /// haut ».
    public func ascending(levels: Int = 1) -> RestoreLocation {
        var next = self
        next.breadcrumb.removeLast(min(max(levels, 0), breadcrumb.count))
        return next
    }
}

public enum RestoreNavigationFailure: Error, Sendable, Equatable, CustomStringConvertible {
    case notADirectory(name: String)

    public var description: String {
        switch self {
        case .notADirectory(let name):
            "« \(name) » n'est pas un dossier : impossible d'y descendre."
        }
    }
}

// MARK: - Le décodage de `kopia show`

public enum RestoreCatalog {

    /// Décode la sortie de `kopia show <object-id>` sur un objet de type
    /// dossier.
    ///
    /// **Pas la même isolation que `KopiaManifest`.** Cette sortie n'a rien
    /// à filtrer : appelée avec `--no-progress` sur une commande qui ne
    /// sauvegarde rien, elle n'écrit jamais de bannière de progression ni de
    /// ligne de maintenance sur stdout — vérifié à chaque appel réel du
    /// 02/09/2026, stdout ne portait que le JSON. Chercher quand même une
    /// ligne candidate ajouterait une étape qui ne protège de rien de
    /// mesuré ; en échange, toute défaillance de décodage reste nommée via
    /// `KopiaDecodingFailure`, le même type que `KopiaManifest` utilise pour
    /// les trois autres sorties de kopia.
    public static func decodeDirectoryListing(_ data: Data) throws -> RestoreDirectoryListing {
        let context = "kopia show (parcours d'un dossier de snapshot)"
        guard !data.isEmpty else {
            throw KopiaDecodingFailure.emptyOutput(context: context)
        }

        let raw: RawDirectoryStream
        do {
            raw = try JSONDecoder().decode(RawDirectoryStream.self, from: data)
        } catch {
            guard String(data: data, encoding: .utf8) != nil else {
                throw KopiaDecodingFailure.notUTF8(context: context)
            }
            throw KopiaDecodingFailure.truncatedJSON(context: context, underlying: String(describing: error))
        }

        // `show` répond aussi sur des objets qui ne sont pas des dossiers
        // (un fichier, un flux de métadonnées) avec une forme différente.
        // Confondre l'un pour l'autre — parce qu'on a demandé `show` sur un
        // identifiant qui n'était pas celui qu'on croyait — ne doit jamais
        // rendre une liste vide silencieuse : ça doit nommer l'écart.
        guard raw.stream == "kopia:directory" else {
            throw KopiaDecodingFailure.missingField(path: "stream", context: context)
        }
        guard let rawEntries = raw.entries else {
            throw KopiaDecodingFailure.missingField(path: "entries", context: context)
        }
        let entries = try rawEntries.map { try buildEntry(from: $0, context: context) }
        guard let rawSummary = raw.summary else {
            throw KopiaDecodingFailure.missingField(path: "summary", context: context)
        }
        let summary = try buildSummary(from: rawSummary, path: "summary", context: context)

        return RestoreDirectoryListing(entries: entries, summary: summary)
    }

    private static func buildEntry(from raw: RawDirEntry, context: String) throws -> RestoreEntry {
        guard let name = raw.name else {
            throw KopiaDecodingFailure.missingField(path: "entries[].name", context: context)
        }
        guard let typeText = raw.type else {
            throw KopiaDecodingFailure.missingField(path: "entries[].type", context: context)
        }
        guard let modeText = raw.mode else {
            throw KopiaDecodingFailure.missingField(path: "entries[].mode", context: context)
        }
        guard let mtimeRaw = raw.mtime else {
            throw KopiaDecodingFailure.missingField(path: "entries[].mtime", context: context)
        }
        guard let mtime = KopiaManifest.parseTimestamp(mtimeRaw) else {
            throw KopiaDecodingFailure.unparsableTimestamp(path: "entries[].mtime", value: mtimeRaw)
        }
        guard let objectID = raw.obj else {
            throw KopiaDecodingFailure.missingField(path: "entries[].obj", context: context)
        }

        let kind: RestoreEntryKind
        switch typeText {
        case "d": kind = .directory
        case "f": kind = .file
        case "s": kind = .symlink
        default: kind = .other(typeText)
        }

        var fileSize: Int64?
        var directorySummary: RestoreDirectorySummary?

        if kind == .directory {
            guard let rawSumm = raw.summ else {
                throw KopiaDecodingFailure.missingField(path: "entries[\(name)].summ", context: context)
            }
            directorySummary = try buildSummary(from: rawSumm, path: "entries[\(name)].summ", context: context)
        } else {
            // Voir l'en-tête du fichier : l'absence de `size` sur un fichier
            // (ou un lien) est un zéro explicite côté kopia, jamais une
            // absence de mesure. `?? 0` est donc justifié ici — précisément
            // parce que la sémantique de ce champ précis a été vérifiée, pas
            // supposée.
            let size = raw.size ?? 0
            // Même refus que dans `buildSummary` : une taille négative
            // remonterait jusqu'à `validateDestination`, où elle rendrait une
            // marge négative — donc « il y a la place » sur un volume qu'on
            // n'a pas mesuré.
            guard size >= 0 else {
                throw KopiaDecodingFailure.implausibleCounter(
                    path: "entries[\(name)].size", value: String(size), context: context
                )
            }
            fileSize = size
        }

        return RestoreEntry(
            name: name,
            kind: kind,
            objectID: objectID,
            modifiedAt: mtime,
            posixMode: modeText,
            ownerUID: raw.uid,
            ownerGID: raw.gid,
            fileSize: fileSize,
            directorySummary: directorySummary
        )
    }

    private static func buildSummary(
        from raw: RawSumm, path: String, context: String
    ) throws -> RestoreDirectorySummary {
        guard let size = raw.size else {
            throw KopiaDecodingFailure.missingField(path: "\(path).size", context: context)
        }
        guard let files = raw.files else {
            throw KopiaDecodingFailure.missingField(path: "\(path).files", context: context)
        }
        guard let dirs = raw.dirs else {
            throw KopiaDecodingFailure.missingField(path: "\(path).dirs", context: context)
        }
        guard let symlinks = raw.symlinks else {
            throw KopiaDecodingFailure.missingField(path: "\(path).symlinks", context: context)
        }
        // Le même piège que `SnapshotProof.errorCount` dans `BackupContract` :
        // ce compteur ne doit jamais se replier sur zéro par défaut, sous
        // peine de faire disparaître des fichiers réellement en échec.
        guard let numFailed = raw.numFailed else {
            throw KopiaDecodingFailure.missingField(path: "\(path).numFailed", context: context)
        }

        // Le type ne dit rien de la plausibilité : `Int64` accepte `-1`, et
        // une taille négative traverserait jusqu'à la garde disque, où elle
        // rendrait une marge négative — donc « il y a la place », pour un
        // volume qu'on n'a pas mesuré. Un compteur de fichiers négatif
        // ferait la même chose à l'affichage. On refuse au décodage, une
        // fois, plutôt que de se défendre à chaque usage.
        for (field, value) in [
            ("size", size), ("files", Int64(files)), ("dirs", Int64(dirs)),
            ("symlinks", Int64(symlinks)), ("numFailed", Int64(numFailed)),
        ] where value < 0 {
            throw KopiaDecodingFailure.implausibleCounter(
                path: "\(path).\(field)", value: String(value), context: context
            )
        }

        var lastModified: Date?
        if let maxTimeRaw = raw.maxTime {
            guard let parsed = KopiaManifest.parseTimestamp(maxTimeRaw) else {
                throw KopiaDecodingFailure.unparsableTimestamp(path: "\(path).maxTime", value: maxTimeRaw)
            }
            lastModified = parsed
        }

        return RestoreDirectorySummary(
            totalSize: size,
            fileCount: files,
            dirCount: dirs,
            symlinkCount: symlinks,
            failedCount: numFailed,
            lastModified: lastModified
        )
    }
}

/// Tout optionnel, comme les formes brutes de `KopiaManifest` — la validation
/// nommée se fait dans `buildEntry`/`buildSummary`, jamais dans le decoder
/// synthétisé.
private struct RawDirectoryStream: Decodable {
    let stream: String?
    let entries: [RawDirEntry]?
    let summary: RawSumm?
}

private struct RawDirEntry: Decodable {
    let name: String?
    let type: String?
    let mode: String?
    let size: Int64?
    let mtime: String?
    let uid: Int?
    let gid: Int?
    let obj: String?
    let summ: RawSumm?
}

private struct RawSumm: Decodable {
    let size: Int64?
    let files: Int?
    let dirs: Int?
    let symlinks: Int?
    let maxTime: String?
    let numFailed: Int?
}

// MARK: - La progression d'une restauration

/// Un instantané de progression, extrait de la ligne d'état que `kopia
/// restore` réécrit sur **stderr** — même mécanisme que `BackupProgress`
/// pour `snapshot create`, mais un format différent, mesuré séparément.
///
/// Relevé réel (restauration de 2,6 Mo, 12 fichiers) :
/// ```
/// Restoring to local filesystem (/…/dest) with parallelism=8...
/// \rProcessed 6 (33.3 KB) of 12 (2.6 MB).
/// \rProcessed 11 (0.9 MB) of 12 (2.6 MB) 752.9 KB/s (35.4%) remaining 1s.
/// \rProcessed 13 (2.6 MB) of 12 (2.6 MB) 2 MB/s (100.0%) remaining 0s.
/// Restored 9 files, 4 directories and 0 symbolic links (2.6 MB).
/// ```
/// Comme pour `snapshot create`, deux régimes : un compte encore approximatif
/// (`totalEntries`/`totalBytes` sans débit ni pourcentage), puis un compte
/// affiné avec débit et temps restant. `totalEntries`/`totalBytes` peuvent
/// être **dépassés** par les valeurs traitées (13 traités sur "12" annoncés,
/// vu tel quel) : ce ne sont que des estimations initiales, jamais une borne
/// dure.
public struct RestoreProgress: Sendable, Hashable, Codable {
    public var processedEntries: Int
    public var processedBytes: Int64
    public var totalEntries: Int
    public var totalBytes: Int64
    /// Octets par seconde, arrondi comme toute autre taille de ce fichier —
    /// jamais un `Double` brut : un débit de « 752.9 KB/s » n'a pas besoin
    /// d'une précision que kopia lui-même n'affiche pas, et un entier évite
    /// toute comparaison d'égalité fragile sur un nombre à virgule flottante
    /// ailleurs dans le code qui consomme cette valeur.
    public var throughputBytesPerSecond: Int64?
    public var secondsRemaining: TimeInterval?

    /// Bornée à 1, pour la même raison que `BackupProgress.fraction` : le
    /// compte total est une estimation qui se corrige, et une barre qui
    /// dépasse son cadre est un défaut visible.
    public var fraction: Double? {
        guard totalBytes > 0 else { return nil }
        return min(1, Double(processedBytes) / Double(totalBytes))
    }

    public init(
        processedEntries: Int,
        processedBytes: Int64,
        totalEntries: Int,
        totalBytes: Int64,
        throughputBytesPerSecond: Int64? = nil,
        secondsRemaining: TimeInterval? = nil
    ) {
        self.processedEntries = processedEntries
        self.processedBytes = processedBytes
        self.totalEntries = totalEntries
        self.totalBytes = totalBytes
        self.throughputBytesPerSecond = throughputBytesPerSecond
        self.secondsRemaining = secondsRemaining
    }
}

/// Ce que la ligne finale — « Restored N files, M directories and K symbolic
/// links (Z). » — dit d'une restauration qui est allée à son terme.
///
/// **C'est la seule preuve qu'une restauration a fini.** Un exit code 0 ne
/// suffit pas à lui seul : voir l'en-tête de `KopiaRestore.swift` sur ce
/// qu'un run tué au milieu laisse derrière lui, sans cette ligne.
public struct RestoreSummary: Sendable, Hashable, Codable {
    public var restoredFiles: Int
    public var restoredDirectories: Int
    public var restoredSymlinks: Int
    public var restoredBytes: Int64

    public init(restoredFiles: Int, restoredDirectories: Int, restoredSymlinks: Int, restoredBytes: Int64) {
        self.restoredFiles = restoredFiles
        self.restoredDirectories = restoredDirectories
        self.restoredSymlinks = restoredSymlinks
        self.restoredBytes = restoredBytes
    }
}

/// Un événement que la lecture en direct de stderr peut produire : soit un
/// point de progression, soit la confirmation finale.
public enum RestoreProgressEvent: Sendable, Hashable {
    case progress(RestoreProgress)
    case completed(RestoreSummary)
}

/// Découpe et interprète le flux de progression de `kopia restore`, ligne
/// par ligne, sur le même principe de tamponnage que `KopiaProgressReader` —
/// dupliqué plutôt que partagé : `KopiaProgressReader` est écrit pour la
/// grammaire de `snapshot create` (marqueur de rotation, « X hashed », «
/// estimated » / « estimating... »), qui n'est pas celle de `restore` (pas de
/// marqueur de rotation, « Processed X of Y », « remaining Ts » sans le
/// suffixe « left »). Les deux formats se ressemblent assez pour tenter une
/// grammaire commune, et assez peu pour qu'une grammaire commune devienne le
/// genre de code que personne n'ose plus toucher une fois qu'il gère les
/// deux à la fois.
public struct RestoreProgressReader: Sendable {
    private var buffer: String = ""

    public init() {}

    public mutating func accept(_ chunk: String) -> [RestoreProgressEvent] {
        buffer += chunk

        var events: [RestoreProgressEvent] = []
        while let separator = buffer.firstIndex(where: { $0 == "\r" || $0 == "\n" }) {
            let line = String(buffer[buffer.startIndex..<separator])
            buffer = String(buffer[buffer.index(after: separator)...])
            if let event = RestoreProgressReader.parse(line: line) {
                events.append(event)
            }
        }
        return events
    }

    public static func parse(line: String) -> RestoreProgressEvent? {
        if let summary = parseCompletion(line) { return .completed(summary) }
        if let progress = parseProgress(line) { return .progress(progress) }
        return nil
    }

    /// « Processed 6 (33.3 KB) of 12 (2.6 MB). » ou, une fois le débit connu,
    /// « Processed 11 (0.9 MB) of 12 (2.6 MB) 752.9 KB/s (35.4%) remaining 1s. »
    private static func parseProgress(_ line: String) -> RestoreProgress? {
        var content = Substring(line)
        // Même nettoyage que `KopiaProgressReader` : kopia efface la ligne
        // précédente par-dessus puis complète d'espaces si la nouvelle est
        // plus courte.
        while content.hasSuffix(" ") { content.removeLast() }

        let prefix = "Processed "
        guard content.hasPrefix(prefix) else { return nil }
        content = content.dropFirst(prefix.count)

        guard let (processedCount, afterProcessed) = parseLeadingInt(content) else { return nil }
        guard afterProcessed.hasPrefix(" (") else { return nil }
        var rest = afterProcessed.dropFirst(2)
        guard let close1 = rest.firstIndex(of: ")") else { return nil }
        guard let processedBytes = parseSize(String(rest[rest.startIndex..<close1])) else { return nil }
        rest = rest[rest.index(after: close1)...]

        let ofPrefix = " of "
        guard rest.hasPrefix(ofPrefix) else { return nil }
        rest = rest.dropFirst(ofPrefix.count)
        guard let (totalCount, afterTotal) = parseLeadingInt(rest) else { return nil }
        guard afterTotal.hasPrefix(" (") else { return nil }
        rest = afterTotal.dropFirst(2)
        guard let close2 = rest.firstIndex(of: ")") else { return nil }
        guard let totalBytes = parseSize(String(rest[rest.startIndex..<close2])) else { return nil }
        rest = rest[rest.index(after: close2)...]

        if rest == "." {
            return RestoreProgress(
                processedEntries: processedCount,
                processedBytes: processedBytes,
                totalEntries: totalCount,
                totalBytes: totalBytes
            )
        }

        guard rest.hasPrefix(" "), rest.hasSuffix(".") else { return nil }
        let tail = rest.dropFirst().dropLast()
        let tokens = tail.split(separator: " ", omittingEmptySubsequences: true)
        guard tokens.count == 5 else { return nil }
        guard let throughput = parseRate(value: tokens[0], unit: tokens[1]) else { return nil }
        guard tokens[2].hasPrefix("("), tokens[2].hasSuffix("%)"),
              Double(tokens[2].dropFirst().dropLast(2)) != nil
        else { return nil }
        guard tokens[3] == "remaining" else { return nil }
        guard let remaining = parseRemainingDuration(tokens[4]) else { return nil }

        return RestoreProgress(
            processedEntries: processedCount,
            processedBytes: processedBytes,
            totalEntries: totalCount,
            totalBytes: totalBytes,
            throughputBytesPerSecond: throughput,
            secondsRemaining: remaining
        )
    }

    /// « Restored 9 files, 4 directories and 0 symbolic links (2.6 MB). »
    /// Kopia n'accorde jamais ces mots au singulier — « 1 directories » vu
    /// tel quel — ce qui simplifie l'analyse : la forme est fixe, quel que
    /// soit le compte.
    private static func parseCompletion(_ line: String) -> RestoreSummary? {
        var content = Substring(line)
        while content.hasSuffix(" ") { content.removeLast() }

        let prefix = "Restored "
        guard content.hasPrefix(prefix) else { return nil }
        content = content.dropFirst(prefix.count)
        guard content.hasSuffix(".") else { return nil }
        content = content.dropLast()

        guard content.hasSuffix(")"), let openParen = content.lastIndex(of: "(") else { return nil }
        let sizeText = content[content.index(after: openParen)..<content.index(before: content.endIndex)]
        guard let bytes = parseSize(String(sizeText)) else { return nil }

        let countsText = content[content.startIndex..<openParen]
        guard countsText.hasSuffix(" ") else { return nil }
        let counts = countsText.dropLast()

        let parts = counts.components(separatedBy: ", ")
        guard parts.count == 2 else { return nil }
        guard let files = parseLeadingCount(parts[0], suffix: " files") else { return nil }

        guard let andRange = parts[1].range(of: " and ") else { return nil }
        let dirsText = String(parts[1][parts[1].startIndex..<andRange.lowerBound])
        let symlinksText = String(parts[1][andRange.upperBound...])
        guard let dirs = parseLeadingCount(dirsText, suffix: " directories") else { return nil }
        guard let symlinks = parseLeadingCount(symlinksText, suffix: " symbolic links") else { return nil }

        return RestoreSummary(
            restoredFiles: files, restoredDirectories: dirs, restoredSymlinks: symlinks, restoredBytes: bytes
        )
    }

    private static func parseLeadingInt(_ text: Substring) -> (Int, Substring)? {
        var index = text.startIndex
        while index < text.endIndex, text[index].isNumber { index = text.index(after: index) }
        guard index > text.startIndex, let value = Int(text[text.startIndex..<index]) else { return nil }
        return (value, text[index...])
    }

    private static func parseLeadingCount(_ text: String, suffix: String) -> Int? {
        guard text.hasSuffix(suffix) else { return nil }
        return Int(text.dropLast(suffix.count))
    }

    /// « 33.3 KB » → 33 300. Puissances de 1000, comme partout ailleurs chez
    /// kopia — voir `KopiaProgressReader.parseSize`, dont c'est ici une
    /// version indépendante mais au même comportement mesuré.
    private static func parseSize(_ text: String) -> Int64? {
        let parts = text.split(separator: Character(" "))
        guard parts.count == 2, let value = Double(parts[0]) else { return nil }
        guard let multiplier = unitMultiplier(String(parts[1])) else { return nil }
        return octets(value * multiplier)
    }

    /// « 752.9 » + « KB/s » → 752 900 (octets par seconde).
    private static func parseRate(value: Substring, unit: Substring) -> Int64? {
        guard let amount = Double(value) else { return nil }
        guard unit.hasSuffix("/s") else { return nil }
        guard let multiplier = unitMultiplier(String(unit.dropLast(2))) else { return nil }
        return octets(amount * multiplier)
    }

    /// La conversion finale, isolée pour que `parseSize` et `parseRate` la
    /// fassent de la même façon.
    ///
    /// **`Int64(_:)` d'un `Double` non fini ou hors plage est une erreur
    /// fatale, pas un `nil`.** `Double("nan")` rend `nan` et `Double("1e400")`
    /// rend `+∞`, tous deux sans se plaindre — mesuré. La ligne
    /// `Processed 1 (nan MB) of 2 (1 MB).`, parfaitement bien formée, arrêtait
    /// donc le processus au milieu d'une restauration. Même famille que le
    /// défaut corrigé dans `KopiaProgressReader.parseSize`, à l'autre bout du
    /// même moteur.
    private static func octets(_ value: Double) -> Int64? {
        let rounded = value.rounded()
        guard rounded.isFinite,
              rounded >= Double(Int64.min),
              rounded <= Double(Int64.max)
        else { return nil }
        return Int64(rounded)
    }

    /// **`TB` et `PB` manquaient, et leur absence tuait la restauration.**
    /// C'est très exactement le défaut corrigé dans
    /// `KopiaProgressReader.parseSize` — le même mécanisme, le même moteur,
    /// l'autre sens du transfert :
    ///
    ///     Processed 12 (1.5 TB) of 40 (2 TB).   →  nil
    ///
    /// `parseProgress` rend alors `nil`, `accept()` un tableau vide, et
    /// `KopiaRestoreDriver` ne rafraîchit son horloge que sur un événement
    /// **décodé** (`if !events.isEmpty { lastProgress = Date() }`). Passé
    /// `defaultProgressStallThreshold`, son chien de garde conclut « aucune
    /// progression » et tue une restauration qui avançait — c'est-à-dire
    /// précisément la restauration d'un Mac de plus d'un téraoctet, le jour
    /// où on en a besoin.
    private static func unitMultiplier(_ unit: String) -> Double? {
        switch unit {
        case "B": 1
        case "KB": 1_000
        case "MB": 1_000_000
        case "GB": 1_000_000_000
        case "TB": 1_000_000_000_000
        case "PB": 1_000_000_000_000_000
        default: nil
        }
    }

    /// « 1s », « 12m54s », « 2h5m » → des secondes. Même grammaire que
    /// `KopiaProgressReader.parseDuration`, mais sans le suffixe « left » —
    /// ici le mot d'introduction (« remaining ») est déjà consommé comme un
    /// jeton séparé, et il ne reste que la durée.
    private static func parseRemainingDuration(_ text: Substring) -> TimeInterval? {
        var remainder = text
        guard !remainder.isEmpty else { return nil }

        var seconds: Double = 0
        var consumedAny = false

        if let hIndex = remainder.firstIndex(of: "h") {
            guard let hours = Double(remainder[remainder.startIndex..<hIndex]) else { return nil }
            seconds += hours * 3_600
            remainder = remainder[remainder.index(after: hIndex)...]
            consumedAny = true
        }
        if let mIndex = remainder.firstIndex(of: "m") {
            guard let minutes = Double(remainder[remainder.startIndex..<mIndex]) else { return nil }
            seconds += minutes * 60
            remainder = remainder[remainder.index(after: mIndex)...]
            consumedAny = true
        }
        if let sIndex = remainder.firstIndex(of: "s") {
            guard let secs = Double(remainder[remainder.startIndex..<sIndex]) else { return nil }
            seconds += secs
            remainder = remainder[remainder.index(after: sIndex)...]
            consumedAny = true
        }

        guard consumedAny, remainder.isEmpty else { return nil }
        return seconds
    }
}

// MARK: - L'écrasement, explicite et obligatoire

/// Ce que fait `kopia restore` quand la destination contient déjà quelque
/// chose. **Aucune valeur par défaut nulle part dans ce fichier ni dans
/// `KopiaRestore.swift`** : toute fonction qui lance une restauration exige
/// ce paramètre en position, sans valeur implicite — un appelant pressé ne
/// peut pas oublier de choisir.
///
/// Mesuré le 02/09/2026, 0.23.1 : sans aucun drapeau, `kopia restore`
/// **écrase par défaut** — c'est écrit noir sur blanc dans son aide (« the
/// restore will attempt to overwrite, unless one or more of the following
/// flags has been set »). C'est exactement l'inverse de ce que ce module
/// doit garantir, d'où l'absence de tout appel à `kopia restore` sans l'un
/// de ces deux jeux de drapeaux explicitement choisi.
///
/// **`--skip-existing` a été essayé et écarté.** Son aide promet de « passer
/// les fichiers et liens qui existent déjà dans la sortie ». Mesuré trois
/// fois sur ce dépôt : combiné à `--no-overwrite-files`, il ne change rien
/// — l'erreur « it already exists » tombe quand même. Combiné à
/// `--overwrite-files`, il n'empêche pas non plus l'écrasement — le fichier
/// préexistant est bel et bien remplacé. Dans aucune combinaison essayée il
/// ne « saute » un fichier existant comme son texte le promet. Un drapeau
/// dont le comportement mesuré contredit sa propre documentation n'a pas sa
/// place dans une API qui doit rendre l'écrasement impossible à déclencher
/// par accident — il est donc absent de ``kopiaFlags``.
public enum RestoreOverwritePolicy: Sendable, Hashable, Codable {
    /// Refuse tout si la destination contient déjà quoi que ce soit.
    ///
    /// **Le seul mode sans risque de perte, et il l'est par construction
    /// mesurée** : avec ces trois drapeaux, kopia refuse même de commencer
    /// dès que le dossier cible existe et n'est pas vide — vu tel quel :
    /// « non-empty directory already exists, not overwriting it », avant
    /// qu'un seul octet n'ait été écrit. La restauration est donc atomique
    /// dans ce mode — soit rien n'est tenté, soit tout part d'un dossier
    /// vide — ce qui est précisément ce qu'exige la garde de destination
    /// (voir ``RestoreCatalog/validateDestination(_:requiredBytes:overwrite:)``).
    case refuseIfNotEmpty

    /// Écrase fichiers, dossiers et liens déjà présents à la destination.
    /// **Irréversible.**
    case overwriteExisting

    public var kopiaFlags: [String] {
        switch self {
        case .refuseIfNotEmpty:
            ["--no-overwrite-files", "--no-overwrite-directories", "--no-overwrite-symlinks"]
        case .overwriteExisting:
            ["--overwrite-files", "--overwrite-directories", "--overwrite-symlinks"]
        }
    }
}

// MARK: - La garde de destination

/// Ce qu'on sait d'un dossier de destination avant de lancer quoi que ce
/// soit — mesuré par l'appelant (accès disque, donc hors de cette cible
/// pure) et remis ici pour décision.
public struct RestoreDestinationFacts: Sendable, Hashable {
    public var exists: Bool
    /// Sans objet si `exists == false`.
    public var isDirectory: Bool
    public var isWritable: Bool
    /// `nil` quand le contenu n'a pas pu être énuméré (droits insuffisants
    /// pour lister, bien que `isWritable` soit vrai — un cas rare mais réel
    /// sur un volume aux ACL inhabituelles), ou quand `exists == false`.
    public var isEmpty: Bool?
    /// Octets disponibles sur le volume qui porte la destination. `nil` si
    /// la mesure a échoué — jamais remplacé par une grande valeur optimiste.
    public var availableBytes: Int64?

    public init(exists: Bool, isDirectory: Bool, isWritable: Bool, isEmpty: Bool?, availableBytes: Int64?) {
        self.exists = exists
        self.isDirectory = isDirectory
        self.isWritable = isWritable
        self.isEmpty = isEmpty
        self.availableBytes = availableBytes
    }
}

/// Pourquoi une destination a été refusée, avant tout lancement de kopia.
public enum RestoreDestinationProblem: Sendable, Hashable, CustomStringConvertible {
    case pathIsAFile
    case notWritable
    case notEmpty(policy: RestoreOverwritePolicy)
    case unknownFreeSpace
    case insufficientSpace(requiredBytes: Int64, availableBytes: Int64)

    public var description: String {
        switch self {
        case .pathIsAFile:
            "La destination existe déjà et c'est un fichier, pas un dossier."
        case .notWritable:
            "bran n'a pas le droit d'écrire à cet endroit."
        case .notEmpty:
            "Le dossier de destination contient déjà des fichiers : restaurer sans écraser exige un dossier vide."
        case .unknownFreeSpace:
            "Impossible de mesurer la place disponible sur le volume de destination."
        case .insufficientSpace(let required, let available):
            "Il faut environ \(required) octets et le volume de destination n'en offre que \(available) : "
                + "la restauration échouerait de toute façon, mais après avoir commencé à écrire."
        }
    }
}

extension RestoreCatalog {
    /// Décide si une restauration peut commencer, **avant** de lancer kopia.
    ///
    /// **C'est tout le sens de ce contrôle** : restaurer 400 Go dans un
    /// volume qui en offre 12 doit échouer ici, tout de suite, pas au bout
    /// de trois heures de transfert quand le disque se remplit au milieu
    /// d'un fichier. kopia lui-même ne fait cette vérification nulle part —
    /// mesuré : `kopia restore` n'a aucun drapeau ni aucune étape qui
    /// contrôle l'espace disque avant d'écrire. Cette fonction est donc la
    /// seule ligne de défense pour ce piège précis.
    ///
    /// `requiredBytes` doit être le volume **logique** de ce qu'on restaure
    /// (`RestoreDirectorySummary.totalSize`, ou `RestoreEntry.fileSize` pour
    /// un seul fichier) — c'est le nombre d'octets que kopia écrit
    /// réellement sur disque au moment de la restauration : la déduplication
    /// et la compression ne jouent que côté dépôt, jamais sur ce qui sort.
    public static func validateDestination(
        _ facts: RestoreDestinationFacts,
        requiredBytes: Int64,
        overwrite: RestoreOverwritePolicy
    ) -> [RestoreDestinationProblem] {
        var problems: [RestoreDestinationProblem] = []

        if facts.exists, !facts.isDirectory {
            problems.append(.pathIsAFile)
        }
        if !facts.isWritable {
            problems.append(.notWritable)
        }
        if facts.exists, overwrite == .refuseIfNotEmpty, facts.isEmpty == false {
            problems.append(.notEmpty(policy: overwrite))
        }

        guard let available = facts.availableBytes else {
            problems.append(.unknownFreeSpace)
            return problems
        }
        // Marge de 5 % : kopia recrée aussi les métadonnées de chaque entrée
        // (attributs, structures de répertoire) en plus des octets de
        // contenu, et un volume tout juste à la bonne taille échouerait sur
        // le dernier fichier plutôt qu'avant le premier — exactement le
        // défaut que ce contrôle existe pour fermer.
        let requiredWithMargin = withFivePercentMargin(requiredBytes)
        if available < requiredWithMargin {
            problems.append(.insufficientSpace(requiredBytes: requiredWithMargin, availableBytes: available))
        }
        return problems
    }

    /// `requiredBytes` majoré de 5 %, en arithmétique entière, sans jamais
    /// piéger.
    ///
    /// **Le calcul précédent était `Int64((Double(requiredBytes) * 1.05).rounded(.up))`,
    /// et il arrêtait l'application.** Mesuré : `Double(Int64.max) * 1.05`
    /// vaut 9,684 540 638 697 515 × 10¹⁸, une valeur parfaitement finie mais
    /// supérieure à `Int64.max` — et `Int64(_:)` d'un `Double` hors plage est
    /// une erreur fatale, pas une troncature. Il suffisait donc que kopia
    /// rende le manifeste
    ///
    ///     {"stream":"kopia:directory","entries":[],
    ///      "summary":{"size":9223372036854775807,…}}
    ///
    /// — décodé sans erreur, `Int64` étant justement le type du champ — pour
    /// que le clic sur « restaurer » tue le processus **avant** que kopia
    /// soit lancé. Une garde écrite pour éviter d'échouer au milieu d'un
    /// transfert échouait plus tôt et plus mal.
    ///
    /// On sature à `Int64.max` en cas de débordement plutôt que de refuser :
    /// c'est le sens de risque de cette fonction. Une arborescence annoncée à
    /// 8 Eio ne tient sur aucun volume, `insufficientSpace` est le bon
    /// verdict, et l'utilisateur lit un refus argumenté au lieu de perdre sa
    /// session.
    private static func withFivePercentMargin(_ requiredBytes: Int64) -> Int64 {
        // Une taille négative n'a pas de sens physique ; elle ne peut venir
        // que d'un manifeste corrompu. Zéro la rend inoffensive ici — c'est au
        // décodage de la refuser, pas à la garde disque de la deviner.
        guard requiredBytes > 0 else { return 0 }
        let (product, overflowed) = requiredBytes.multipliedReportingOverflow(by: 105)
        guard !overflowed else { return .max }
        // Division entière tronquée puis arrondi au supérieur, pour reproduire
        // exactement le `.rounded(.up)` d'avant sans passer par un `Double`.
        return product / 100 + (product % 100 == 0 ? 0 : 1)
    }
}
