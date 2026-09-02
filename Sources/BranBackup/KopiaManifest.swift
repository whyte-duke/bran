import Foundation

// Le décodage des sorties JSON de kopia 0.23.1 — `snapshot create --json`,
// `snapshot list --all --json`, `repository status --json`.
//
// **Pourquoi ce fichier ne fait pas confiance à `JSONDecoder.dateDecodingStrategy
// .iso8601`.** Kopia écrit des fractions de seconde à précision variable —
// 0, 5, 6 ou 9 chiffres selon le champ, relevé réel à l'appui : `endTime` sort
// en 5 chiffres (`38.02194Z`), `startTime` en 6 (`37.888422Z`), `mtime` en 9
// (`37.193919479Z`). La stratégie `.iso8601` de Foundation, même avec
// `.withFractionalSeconds`, échoue net sur une fraction qui n'est pas de
// longueur fixe. Une date qu'on ne sait pas lire et qu'on remplacerait par
// `Date()` ou par un champ ignoré serait un mensonge silencieux : l'historique
// afficherait une heure qui n'est jamais arrivée. Donc : un décodeur écrit à la
// main, qui échoue nommément plutôt que d'inventer une date.
//
// **Pourquoi la sortie brute est décodée dans des types à champs optionnels
// avant d'être validée.** Le décodeur synthétisé de Swift échoue sur la
// première clé manquante sans dire clairement laquelle des dix qui suivent
// aurait posé le même problème, et il ne permet pas de choisir *quel* champ est
// vraiment obligatoire pour telle sortie et pas pour telle autre — `stats`
// n'existe que dans `snapshot list`, jamais dans `snapshot create`. En
// décodant d'abord dans une forme tout-optionnel, puis en validant à la main
// avec un chemin nommé (`"rootEntry.summ.size"`, pas juste "size"), chaque
// absence produit une erreur qui dit exactement où elle a manqué.
public enum KopiaManifest {

    // MARK: - Les trois sorties

    /// La sortie d'une ligne de `kopia snapshot create --json`.
    ///
    /// **N'a pas de bloc `stats`** — seulement `rootEntry.summ`. Un manifeste
    /// rendu ici porte l'origine `.reportedByCreate` : c'est ce que le
    /// processus qui vient de terminer *croit* avoir écrit, pas ce que le
    /// dépôt confirme. Voir `ProofOrigin`.
    public static func decodeCreatedSnapshot(_ data: Data) throws -> SnapshotProof {
        let context = "kopia snapshot create --json"
        let raw = try decodeIsolated(RawSnapshot.self, from: data, leadingDelimiter: "{", context: context)
        return try buildProof(from: raw, origin: .reportedByCreate, context: context)
    }

    /// La sortie de `kopia snapshot list --all --json`.
    ///
    /// **Le tableau vide est un cas normal, pas une erreur.** Un dépôt sain et
    /// sans aucun snapshot rend `[]`, ou parfois une chaîne carrément vide selon
    /// la version — vécu tel quel sur ce Mac le 02/09/2026, dépôt sain, zéro
    /// snapshot. Le confondre avec un JSON illisible ferait remonter « problème
    /// de dépôt » alors qu'il n'y a rien de cassé : c'est vérifié **avant**
    /// toute tentative de décodage JSON, pas en rattrapant une erreur.
    public static func decodeSnapshotList(_ data: Data) throws -> [SnapshotProof] {
        let context = "kopia snapshot list --all --json"
        guard let text = String(data: data, encoding: .utf8) else {
            throw KopiaDecodingFailure.notUTF8(context: context)
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return []
        }
        let rawList = try decodeIsolated([RawSnapshot].self, from: data, leadingDelimiter: "[", context: context)
        // Chaque entrée a été relue dans le dépôt par `list` lui-même : c'est
        // la seule origine qui vaut preuve.
        return try rawList.map { try buildProof(from: $0, origin: .confirmedInRepository, context: context) }
    }

    /// La sortie de `kopia repository status --json`.
    public static func decodeRepositoryStatus(_ data: Data) throws -> RepositoryStatus {
        let context = "kopia repository status --json"
        let raw = try decodeIsolated(RawRepositoryStatus.self, from: data, leadingDelimiter: "{", context: context)

        guard let uniqueID = raw.uniqueIDHex else {
            throw KopiaDecodingFailure.missingField(path: "uniqueIDHex", context: context)
        }
        guard let storage = raw.storage else {
            throw KopiaDecodingFailure.missingField(path: "storage", context: context)
        }
        guard let storageType = storage.type else {
            throw KopiaDecodingFailure.missingField(path: "storage.type", context: context)
        }
        guard let config = storage.config else {
            throw KopiaDecodingFailure.missingField(path: "storage.config", context: context)
        }
        guard let bucket = config.bucket else {
            throw KopiaDecodingFailure.missingField(path: "storage.config.bucket", context: context)
        }
        guard let endpoint = config.endpoint else {
            throw KopiaDecodingFailure.missingField(path: "storage.config.endpoint", context: context)
        }
        guard let clientOptions = raw.clientOptions else {
            throw KopiaDecodingFailure.missingField(path: "clientOptions", context: context)
        }
        guard let hostname = clientOptions.hostname else {
            throw KopiaDecodingFailure.missingField(path: "clientOptions.hostname", context: context)
        }
        guard let username = clientOptions.username else {
            throw KopiaDecodingFailure.missingField(path: "clientOptions.username", context: context)
        }
        guard let contentFormat = raw.contentFormat else {
            throw KopiaDecodingFailure.missingField(path: "contentFormat", context: context)
        }
        guard let encryption = contentFormat.encryption else {
            throw KopiaDecodingFailure.missingField(path: "contentFormat.encryption", context: context)
        }
        guard let hash = contentFormat.hash else {
            throw KopiaDecodingFailure.missingField(path: "contentFormat.hash", context: context)
        }

        return RepositoryStatus(
            uniqueID: uniqueID,
            bucket: bucket,
            endpoint: endpoint,
            storageType: storageType,
            hostname: hostname,
            username: username,
            encryption: encryption,
            hash: hash
        )
    }

    // MARK: - La validation, champ par champ

    /// Transforme la forme brute — tout optionnel — en `SnapshotProof`, ou
    /// échoue en nommant le premier champ manquant.
    ///
    /// **Les deux blocs ne mesurent pas la même chose, et les confondre
    /// produit un chiffre faux sur un écran de preuve.**
    ///
    /// Cette fonction a d'abord préféré `stats` à `rootEntry.summ` partout où
    /// les deux existaient, sur l'idée que `stats` vient de la relecture du
    /// dépôt. Le premier vrai snapshot l'a démenti — voici sa sortie, telle
    /// que Kopia l'a rendue le 02/09/2026 :
    ///
    /// ```json
    /// "stats": { "totalSize": 51264842, "fileCount": 0,
    ///            "cachedFiles": 103, "nonCachedFiles": 0, "dirCount": 13 }
    /// "summ":  { "size": 51264842, "files": 103, "dirs": 13 }
    /// ```
    ///
    /// `stats.fileCount` ne compte que les fichiers **réellement relus** :
    /// tout ce que la déduplication a évité tombe dans `cachedFiles`. Sur une
    /// sauvegarde incrémentale — c'est-à-dire toutes sauf la première — il
    /// vaut donc quasiment zéro. L'écran aurait annoncé « 0 fichier » sur un
    /// snapshot qui en contient 103, ce qui est précisément le genre de
    /// chiffre qui fait douter d'une sauvegarde saine.
    ///
    /// La règle est donc : **`rootEntry.summ` pour ce qu'un snapshot
    /// contient** (taille, fichiers, dossiers), **`stats` pour ce que la
    /// lecture a raté** (`errorCount`, `ignoredErrorCount`), qui n'existe
    /// nulle part ailleurs. `stats` reste absent de `create`, et son absence
    /// n'est jamais un motif d'échec.
    private static func buildProof(
        from raw: RawSnapshot,
        origin: ProofOrigin,
        context: String
    ) throws -> SnapshotProof {
        guard let id = raw.id else {
            throw KopiaDecodingFailure.missingField(path: "id", context: context)
        }
        guard let source = raw.source else {
            throw KopiaDecodingFailure.missingField(path: "source", context: context)
        }
        guard let sourceHost = source.host else {
            throw KopiaDecodingFailure.missingField(path: "source.host", context: context)
        }
        guard let sourceUser = source.userName else {
            throw KopiaDecodingFailure.missingField(path: "source.userName", context: context)
        }
        guard let sourcePath = source.path else {
            throw KopiaDecodingFailure.missingField(path: "source.path", context: context)
        }
        guard let startTimeRaw = raw.startTime else {
            throw KopiaDecodingFailure.missingField(path: "startTime", context: context)
        }
        guard let startTime = parseTimestamp(startTimeRaw) else {
            throw KopiaDecodingFailure.unparsableTimestamp(path: "startTime", value: startTimeRaw)
        }
        guard let endTimeRaw = raw.endTime else {
            throw KopiaDecodingFailure.missingField(path: "endTime", context: context)
        }
        guard let endTime = parseTimestamp(endTimeRaw) else {
            throw KopiaDecodingFailure.unparsableTimestamp(path: "endTime", value: endTimeRaw)
        }
        guard let rootEntry = raw.rootEntry else {
            throw KopiaDecodingFailure.missingField(path: "rootEntry", context: context)
        }
        guard let rootObjectID = rootEntry.obj else {
            throw KopiaDecodingFailure.missingField(path: "rootEntry.obj", context: context)
        }

        let totalSize: Int64
        let fileCount: Int
        let dirCount: Int
        let errorCount: Int
        let ignoredErrorCount: Int
        // Le chemin JSON d'où vient le compteur d'erreurs diffère selon la
        // commande : `stats.errorCount` pour `snapshot list`,
        // `rootEntry.summ.numFailed` pour `snapshot create`. On le retient
        // pour que le refus plus bas nomme le champ que l'utilisateur peut
        // effectivement aller regarder.
        let errorCountPath: String

        if let stats = raw.stats {
            // La taille, les fichiers et les dossiers viennent de `summ` — ce
            // que l'arborescence contient — et non de `stats`, qui ne compte
            // que ce qui a été relu ce coup-ci. Voir l'en-tête.
            guard let summary = raw.rootEntry?.summ else {
                throw KopiaDecodingFailure.missingField(path: "rootEntry.summ", context: context)
            }
            guard let size = summary.size else {
                throw KopiaDecodingFailure.missingField(path: "rootEntry.summ.size", context: context)
            }
            guard let files = summary.files else {
                throw KopiaDecodingFailure.missingField(path: "rootEntry.summ.files", context: context)
            }
            guard let dirs = summary.dirs else {
                throw KopiaDecodingFailure.missingField(path: "rootEntry.summ.dirs", context: context)
            }
            guard let errors = stats.errorCount else {
                throw KopiaDecodingFailure.missingField(path: "stats.errorCount", context: context)
            }
            // La politique réelle de ce dépôt ignore les erreurs de lecture
            // (« Ignore file/directory read errors: true ») : un fichier
            // verrouillé incrémente `ignoredErrorCount`, pas `errorCount`, et
            // kopia sort quand même avec le code 0. Le lire avec la même
            // rigueur que `errorCount` — jamais un `?? 0` — est ce qui empêche
            // dix mille fichiers sautés de se présenter comme un succès.
            guard let ignored = stats.ignoredErrorCount else {
                throw KopiaDecodingFailure.missingField(path: "stats.ignoredErrorCount", context: context)
            }
            totalSize = size
            fileCount = files
            dirCount = dirs
            errorCount = errors
            ignoredErrorCount = ignored
            errorCountPath = "stats.errorCount"
        } else {
            guard let summ = rootEntry.summ else {
                throw KopiaDecodingFailure.missingField(path: "rootEntry.summ", context: context)
            }
            // `size: 0` est une source vide légitime (un dossier créé mais
            // inoccupé) ; `size` absent est un JSON qu'on n'a pas compris.
            // `Int64?` porte exactement cette distinction — ne jamais la
            // réduire avec un `?? 0`.
            guard let size = summ.size else {
                throw KopiaDecodingFailure.missingField(path: "rootEntry.summ.size", context: context)
            }
            guard let files = summ.files else {
                throw KopiaDecodingFailure.missingField(path: "rootEntry.summ.files", context: context)
            }
            guard let dirs = summ.dirs else {
                throw KopiaDecodingFailure.missingField(path: "rootEntry.summ.dirs", context: context)
            }
            // Le piège central du contrat : `numFailed` doit remonter tel quel
            // dans `errorCount`, jamais être ignoré ou mis à zéro par défaut —
            // c'est lui qui empêche `isComplete` de mentir sur un snapshot troué.
            guard let failed = summ.numFailed else {
                throw KopiaDecodingFailure.missingField(path: "rootEntry.summ.numFailed", context: context)
            }
            totalSize = size
            fileCount = files
            dirCount = dirs
            errorCount = failed
            // `kopia snapshot create --json` n'expose ni `stats.ignoredErrorCount`
            // ni son équivalent dans `rootEntry.summ` : ce chemin ne peut tout
            // simplement pas savoir combien de fichiers ont été tus par la
            // politique « ignore read errors ». `0` ici n'est **pas** une
            // mesure de zéro fichier ignoré — c'est une valeur qu'on n'a pas
            // et que le type `Int` non optionnel du contrat n'a pas d'autre
            // façon d'exprimer. Ce n'est pas dangereux : l'origine de cette
            // preuve est `.reportedByCreate`, et `isTrustworthy` l'exclut déjà
            // quoi qu'il arrive tant qu'elle n'a pas été relue par `list`, seul
            // chemin qui rapporte ce compteur pour de vrai.
            ignoredErrorCount = 0
            errorCountPath = "rootEntry.summ.numFailed"
        }

        // **Le type ne suffit pas, et l'aval en meurt.** `Int64` accepte `-1`
        // et `Int64.max` sans broncher, mais `SnapshotProof` fait ensuite
        // `errorCount + ignoredErrorCount` avec l'addition piégeante de Swift
        // pour rendre `missingFileCount`. Un manifeste de `snapshot list`
        // portant
        //
        //     "stats":{"errorCount":9223372036854775807,
        //              "ignoredErrorCount":9223372036854775807}
        //
        // décodait donc sans erreur, puis arrêtait l'application au moment
        // exact où `BackupMachine.partialSnapshotSummary` allait annoncer le
        // snapshot incomplet — c'est-à-dire au seul moment où ce compteur sert
        // à quelque chose.
        //
        // On refuse ici plutôt que de saturer : un compteur négatif ou une
        // somme qui déborde ne décrit aucun snapshot réel, et le contrat de ce
        // fichier interdit d'interpréter au bénéfice du doute. Une future
        // version de kopia qui dépasserait vraiment la borne serait refusée
        // explicitement, avec le chemin du champ en cause.
        for (path, value) in [
            ("rootEntry.summ.size", Int64(totalSize)),
            ("rootEntry.summ.files", Int64(fileCount)),
            ("rootEntry.summ.dirs", Int64(dirCount)),
            (errorCountPath, Int64(errorCount)),
            ("stats.ignoredErrorCount", Int64(ignoredErrorCount)),
        ] where value < 0 {
            throw KopiaDecodingFailure.implausibleCounter(
                path: path, value: String(value), context: context
            )
        }
        let (_, sumOverflowed) = errorCount.addingReportingOverflow(ignoredErrorCount)
        if sumOverflowed {
            throw KopiaDecodingFailure.implausibleCounter(
                path: "\(errorCountPath) + stats.ignoredErrorCount",
                value: "\(errorCount) + \(ignoredErrorCount)",
                context: context
            )
        }

        return SnapshotProof(
            id: id,
            rootObjectID: rootObjectID,
            sourcePath: sourcePath,
            sourceHost: sourceHost,
            sourceUser: sourceUser,
            startTime: startTime,
            endTime: endTime,
            totalSize: totalSize,
            fileCount: fileCount,
            dirCount: dirCount,
            errorCount: errorCount,
            ignoredErrorCount: ignoredErrorCount,
            origin: origin
        )
    }

    // MARK: - Isoler le JSON dans une sortie éventuellement polluée

    /// Décode `T`, et si la tentative directe échoue, cherche la première
    /// ligne qui commence — une fois les espaces ôtés — par le délimiteur
    /// attendu (`{` ou `[`) et retente depuis là.
    ///
    /// **Pourquoi chercher une ligne qui *commence* par le délimiteur, et pas
    /// juste la position du premier caractère qui lui ressemble.** Une ligne de
    /// maintenance réelle — `Running full maintenance...` — ne contient aucune
    /// accolade, mais rien ne garantit qu'une future version de kopia n'en
    /// écrive pas une au milieu d'une phrase de log. Ancrer la recherche en
    /// début de ligne évite de prendre un fragment de texte pour du JSON parce
    /// qu'il contient le bon caractère au mauvais endroit — c'est la différence
    /// entre isoler et deviner.
    ///
    /// Si aucune ligne ne convient, ou si la ligne trouvée reste illisible une
    /// fois isolée, l'échec est nommé : jamais un `SnapshotProof` à moitié
    /// rempli, jamais une valeur plausible construite sur un JSON coupé en
    /// plein milieu par un `kopia` tué en cours de route.
    private static func decodeIsolated<T: Decodable>(
        _ type: T.Type,
        from data: Data,
        leadingDelimiter: Character,
        context: String
    ) throws -> T {
        guard !data.isEmpty else {
            throw KopiaDecodingFailure.emptyOutput(context: context)
        }
        if let value = try? JSONDecoder().decode(T.self, from: data) {
            return value
        }

        guard let text = String(data: data, encoding: .utf8) else {
            throw KopiaDecodingFailure.notUTF8(context: context)
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let startIndex = lines.firstIndex(where: {
            String($0).trimmingCharacters(in: .whitespaces).first == leadingDelimiter
        }) else {
            throw KopiaDecodingFailure.noRecognizableJSON(context: context)
        }

        let payloadText = lines[startIndex...].joined(separator: "\n")
        guard let payload = payloadText.data(using: .utf8) else {
            throw KopiaDecodingFailure.notUTF8(context: context)
        }
        do {
            return try JSONDecoder().decode(T.self, from: payload)
        } catch {
            throw KopiaDecodingFailure.truncatedJSON(context: context, underlying: String(describing: error))
        }
    }

    // MARK: - Les dates

    /// Analyse `"2026-09-02T12:43:37.888422Z"` — et tout aussi bien sans
    /// fraction, ou avec 1 à 9 chiffres. `ISO8601DateFormatter` échoue sur une
    /// fraction absente si `.withFractionalSeconds` est activé, et sur une
    /// fraction présente sinon ; l'activer ne suffit pas non plus, il tronque
    /// silencieusement au-delà de trois chiffres sur certaines versions de
    /// Foundation. `JSONDecoder.DateDecodingStrategy.iso8601` a le même défaut,
    /// puisqu'il délègue au même formatter. D'où ce parseur écrit à la main,
    /// sans dépendance à un formatter dont le comportement a changé d'une
    /// version de Foundation à l'autre.
    ///
    /// Kopia écrit toujours en UTC (`Z`) dans toutes les sorties relevées ; un
    /// décalage horaire explicite n'a jamais été vu et n'est pas accepté ici —
    /// l'accepter sans l'avoir observé serait deviner un format, pas le lire.
    static func parseTimestamp(_ raw: String) -> Date? {
        guard raw.hasSuffix("Z") else { return nil }
        let body = raw.dropLast()
        guard body.count >= 19 else { return nil }

        let wholeSeconds = body.prefix(19)
        let fraction = body.dropFirst(19)

        let segments = wholeSeconds.split(separator: "T")
        guard segments.count == 2 else { return nil }
        let dateParts = segments[0].split(separator: "-")
        let timeParts = segments[1].split(separator: ":")
        guard dateParts.count == 3, timeParts.count == 3 else { return nil }
        guard
            let year = Int(dateParts[0]), let month = Int(dateParts[1]), let day = Int(dateParts[2]),
            let hour = Int(timeParts[0]), let minute = Int(timeParts[1]), let second = Int(timeParts[2])
        else { return nil }

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utcTimeZone
        guard let base = calendar.date(from: components) else { return nil }

        guard !fraction.isEmpty else { return base }
        guard fraction.first == "." else { return nil }
        let digits = fraction.dropFirst()
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }

        // Complétée à droite jusqu'à neuf chiffres — la nanoseconde qu'a
        // vraiment écrite kopia — puis convertie en secondes. Un `Double` à
        // cette magnitude (secondes depuis 2001) n'a de toute façon pas la
        // résolution pour distinguer la dernière nanoseconde de la précédente ;
        // ce que ce séquençage garantit, c'est que la fraction lue est celle
        // qui a été écrite, pas une version tronquée par un formatter tiers.
        let padded = String((String(digits) + String(repeating: "0", count: 9)).prefix(9))
        guard let nanoseconds = Int(padded) else { return nil }
        return base.addingTimeInterval(Double(nanoseconds) / 1_000_000_000)
    }

    private static let utcTimeZone = TimeZone(identifier: "UTC")!
}

// MARK: - Les formes brutes du JSON de kopia

/// Tout optionnel, à dessein : une clé absente devient `nil`, jamais une
/// erreur de décodage. C'est `KopiaManifest.buildProof` qui décide, champ par
/// champ, ce qui est vraiment obligatoire — et qui le dit par son nom quand ça
/// manque.
private struct RawSnapshot: Decodable {
    let id: String?
    let source: RawSource?
    let startTime: String?
    let endTime: String?
    let rootEntry: RawRootEntry?
    let stats: RawStats?
}

private struct RawSource: Decodable {
    let host: String?
    let userName: String?
    let path: String?
}

private struct RawRootEntry: Decodable {
    let obj: String?
    let summ: RawSummary?
}

private struct RawSummary: Decodable {
    let size: Int64?
    let files: Int?
    let dirs: Int?
    let numFailed: Int?
}

private struct RawStats: Decodable {
    let totalSize: Int64?
    let fileCount: Int?
    let dirCount: Int?
    let errorCount: Int?
    let ignoredErrorCount: Int?
}

private struct RawRepositoryStatus: Decodable {
    let uniqueIDHex: String?
    let clientOptions: RawClientOptions?
    let storage: RawStorage?
    let contentFormat: RawContentFormat?
}

private struct RawClientOptions: Decodable {
    let hostname: String?
    let username: String?
}

private struct RawStorage: Decodable {
    let type: String?
    let config: RawStorageConfig?
}

private struct RawStorageConfig: Decodable {
    let bucket: String?
    let endpoint: String?
}

private struct RawContentFormat: Decodable {
    let hash: String?
    let encryption: String?
}

// MARK: - L'échec de décodage

/// Ce qui a manqué, précisément — jamais un simple « JSON invalide ».
///
/// Chaque cas porte de quoi désigner l'endroit exact : le chemin du champ
/// (`"rootEntry.summ.size"`, pas juste « size »), ou la commande kopia dont la
/// sortie venait (`context`). Un pilote qui affiche cette erreur brute donne à
/// l'utilisateur — ou au journal qu'il copiera — de quoi comprendre ce qui a
/// cassé sans deviner.
public enum KopiaDecodingFailure: Error, Equatable, Sendable, CustomStringConvertible {
    /// La sortie est vide alors qu'un JSON était attendu. **Ne s'applique pas**
    /// à `decodeSnapshotList`, qui traite une sortie vide comme « aucun
    /// snapshot » avant même d'en arriver là — voir sa documentation.
    case emptyOutput(context: String)

    /// Les octets ne sont pas de l'UTF-8 valide.
    case notUTF8(context: String)

    /// Aucune ligne ne commence par le délimiteur JSON attendu : ni pollution
    /// isolable, ni JSON reconnaissable.
    case noRecognizableJSON(context: String)

    /// Une ligne candidate a été isolée mais son JSON reste invalide ou coupé —
    /// le cas d'un `kopia` tué en plein `--json`.
    case truncatedJSON(context: String, underlying: String)

    /// Un champ requis manque, ou est du mauvais type.
    case missingField(path: String, context: String)

    /// Une date ne suit aucun des formats connus (0 à 9 décimales, suffixe `Z`).
    case unparsableTimestamp(path: String, value: String)

    /// Un compteur ou une taille est du bon type JSON mais désigne une
    /// quantité qui n'existe pas : un nombre de fichiers négatif, une taille
    /// négative, ou deux compteurs d'erreur dont la somme déborde `Int`.
    ///
    /// **Ce cas existe parce que le type ne suffit pas.** `Int64` accepte
    /// `-1` et `9223372036854775807` sans broncher ; c'est l'aval qui tombe.
    /// Un manifeste portant `"errorCount":9223372036854775807` et
    /// `"ignoredErrorCount":9223372036854775807` décodait sans erreur, puis
    /// `SnapshotProof.missingFileCount` faisait l'addition et arrêtait
    /// l'application — au moment précis où elle allait annoncer un snapshot
    /// incomplet. Refuser ici, une fois, vaut mieux que se défendre partout.
    case implausibleCounter(path: String, value: String, context: String)

    public var description: String {
        switch self {
        case .emptyOutput(let context):
            "\(context) : kopia n'a rien écrit alors qu'un JSON était attendu."
        case .notUTF8(let context):
            "\(context) : la sortie n'est pas de l'UTF-8 valide."
        case .noRecognizableJSON(let context):
            "\(context) : aucune ligne ne ressemble à du JSON kopia."
        case .truncatedJSON(let context, let underlying):
            "\(context) : JSON tronqué ou invalide (\(underlying))."
        case .missingField(let path, let context):
            "\(context) : le champ « \(path) » est absent ou du mauvais type."
        case .unparsableTimestamp(let path, let value):
            "Date illisible pour « \(path) » : « \(value) »."
        case .implausibleCounter(let path, let value, let context):
            "\(context) : le champ « \(path) » annonce « \(value) », "
                + "qui ne désigne aucune quantité possible."
        }
    }

    /// Convertit en `BackupFailure` de genre `.unparseable` — la seule famille
    /// qui convienne : ce n'est ni un problème réseau, ni un mot de passe
    /// erroné, c'est kopia qui a rendu quelque chose qu'on n'a pas su lire, et
    /// que le contrat interdit d'interpréter au bénéfice du doute.
    public func asBackupFailure(rawOutput: String) -> BackupFailure {
        BackupFailure(
            kind: .unparseable,
            summary: description,
            suggestedAction: nil,
            rawOutput: rawOutput
        )
    }
}
