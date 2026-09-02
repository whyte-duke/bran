import Foundation

// Transforme la sortie brute d'un `Process` kopia en `BackupFailure`
// exploitable — ou en rien du tout, quand rien n'a échoué.
//
// **Pourquoi `classify` rend un optionnel et pas un `BackupFailure` sec.**
// Deux vérités locales entrent en tension : le code de sortie ment (mot de
// passe invalide → code observé 0 sur ce Mac), et la maintenance parle sur
// stderr au milieu d'un run réussi (`GC found …`). Un classifieur qui doit
// toujours rendre un `BackupFailure` serait forcé, sur une sortie de
// maintenance propre avec code 0, de choisir entre mentir (« pas d'échec »
// via un genre inventé) ou crier au loup (`.unparseable`, donc un rouge sur
// un run qui a réussi) — les deux sont le défaut que ce fichier existe pour
// fermer. `nil` est le seul verdict honnête : « rien à signaler ». C'est
// l'appelant qui décide alors d'écrire un succès, sur la foi du manifeste
// relu dans le dépôt — jamais de la seule absence d'échec ici.
public enum KopiaFailureClassifier {

    /// Classe une sortie d'échec de kopia, ou rend `nil` quand rien n'indique
    /// un échec réel.
    ///
    /// Le texte fait autorité. Le code de sortie ne sert que quand le texte
    /// ne dit rien du tout : stderr vide et code non nul veut dire « ça a
    /// échoué mais on ne sait pas pourquoi » (`.unparseable`), stderr vide et
    /// code nul veut dire « rien ne s'est passé » (`nil`). Un code 0
    /// accompagné d'un texte d'erreur reconnu donne toujours un échec — le
    /// texte gagne.
    public static func classify(
        stderr: String,
        exitCode: Int32,
        wasCancelled: Bool,
        signal: Int32?
    ) -> BackupFailure? {
        // L'interruption prime sur tout le reste : un run tué par un signal
        // ou annulé par l'utilisateur n'a rien à voir avec le contenu qu'il a
        // eu le temps d'écrire sur stderr avant de mourir.
        if wasCancelled || signal != nil {
            return interruptedFailure(signal: signal, rawOutput: stderr)
        }

        // **Sur `\r` autant que sur `\n`, et ce n'est pas un détail de
        // confort.** Kopia réécrit sa ligne de progression par retours
        // chariot : découper sur les seuls sauts de ligne rend une « ligne »
        // unique qui contient une dizaine d'états de progression collés. Elle
        // ne ressemble alors à rien de connu, et une sauvegarde parfaitement
        // réussie ressort classée `.unparseable` — c'est exactement ce qui
        // s'est produit au premier run réel, le 02/09/2026.
        let lines = stderr
            .components(separatedBy: "\n")
            .flatMap { $0.components(separatedBy: "\r") }

        // Kopia agrège ses échecs sous une ligne de résumé (`encountered 2
        // errors:`) qui ne nomme rien ; classer dessus donnerait un
        // `.unparseable` alors que la vraie cause est juste en dessous. On
        // parcourt donc les lignes dans l'ordre où kopia les a écrites et on
        // s'arrête à la première qui correspond à un motif connu — c'est la
        // première cause nommée, jamais le résumé.
        for line in lines {
            // **Le bruit connu est écarté AVANT d'être classé, et l'ordre est
            // tout.** Il ne l'était pas : `classifyLine` voyait passer les
            // lignes de progression, dont les compteurs défilent pendant des
            // heures. Une ligne parfaitement banale comme
            // `- 5 hashing, 1403 hashed (233 MB), …` contient la sous-chaîne
            // « 403 », et sortait donc classée « MinIO refuse les identifiants
            // S3 » — sur un run réussi. Pire : `.authentication` ne se
            // réessaie pas, donc un chiffre de progression malheureux
            // désarmait la reprise automatique.
            guard !isIgnorable(line) else { continue }
            if let match = classifyLine(line) {
                return BackupFailure(
                    kind: match.kind,
                    summary: match.summary,
                    suggestedAction: match.suggestedAction,
                    rawOutput: maskSecrets(in: stderr),
                    link: match.link
                )
            }
        }

        // Rien de reconnu. Reste à savoir si c'est parce qu'il n'y avait rien
        // à reconnaître (maintenance, sondes de vérification, lignes vides)
        // ou parce que kopia a parlé d'un problème qu'on ne sait pas encore
        // lire.
        let leftover = lines.filter { !isIgnorable($0) }
        if leftover.isEmpty {
            // Le texte est propre. On ne fait confiance au code de sortie que
            // dans ce cas précis, faute d'autre signal : un code non nul sans
            // une seule ligne exploitable est un échec réel qu'on ne peut pas
            // nommer, pas un succès qu'on invente par optimisme.
            return exitCode == 0 ? nil : unparseableFailure(rawOutput: stderr)
        }

        // Du texte est resté après avoir écarté le bruit connu, et aucun
        // motif ne l'a reconnu. C'est exactement le cas que la doctrine
        // interdit d'interpréter au bénéfice du doute — jamais un genre
        // plausible par défaut.
        return unparseableFailure(rawOutput: stderr)
    }

    /// Formule l'échec d'un snapshot partiel — manifeste rendu, mais
    /// `numFailed > 0`.
    ///
    /// C'est l'appelant qui détecte ce cas, en lisant `SnapshotProof` (kopia
    /// sort avec le code 0 et stderr propre quand ça arrive : rien dans le
    /// texte de commande ne le trahit). Cette fonction ne fait que porter la
    /// formulation ici, avec le reste des phrases françaises du classifieur,
    /// pour qu'elles ne divergent pas au fil du temps.
    public static func partialSnapshotFailure(errorCount: Int, rawOutput: String) -> BackupFailure {
        // L'accord ne se réduit pas à un « s » : le verbe change aussi au
        // pluriel (« n'a pas » → « n'ont pas »), sans quoi la phrase reste
        // fausse dès qu'il y a plus d'un fichier en cause.
        let phrase = errorCount > 1
            ? "\(errorCount) fichiers n'ont pas pu être lus"
            : "\(errorCount) fichier n'a pas pu être lu"
        return BackupFailure(
            kind: .partialSnapshot,
            summary: "Le snapshot a été enregistré, mais \(phrase).",
            suggestedAction: "Consulter le journal pour savoir lesquels — permission refusée, verrou, ou fichier déplacé pendant la sauvegarde.",
            rawOutput: maskSecrets(in: rawOutput),
            link: nil
        )
    }

    // MARK: - Le masquage des secrets

    /// Remplace, dans un texte destiné à être journalisé, toute valeur qui
    /// suit directement `secretAccessKey`, `password`, `KOPIA_PASSWORD` ou
    /// `Authorization`.
    ///
    /// Kopia masque déjà `secretAccessKey` de son côté dans
    /// `repository status --json` — mais rien ne garantit qu'une version
    /// future, un fournisseur S3 différent, ou une variable d'environnement
    /// recopiée par un shell autour de kopia fasse la même chose. `rawOutput`
    /// est montré tel quel dans l'interface (bouton « copier le
    /// diagnostic ») : c'est ici, une fois, qu'on ferme la fuite plutôt que
    /// de compter sur l'outil externe.
    ///
    /// Volontairement étroit : seul le jeton qui suit *immédiatement* le nom
    /// et un séparateur (`:` ou `=`) est masqué. Un mot comme « password »
    /// employé seul dans une phrase — `invalid repository password` — n'a pas
    /// de séparateur derrière lui et traverse intact, ce qui est le
    /// diagnostic qu'on veut garder lisible.
    public static func maskSecrets(in text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        var result = text
        // En ordre inverse : remplacer une occurrence plus loin dans le texte
        // ne décale pas les indices de celles qui restent à traiter avant
        // elle.
        for match in secretPattern.matches(in: text, range: range).reversed() {
            guard match.numberOfRanges > 3,
                  let valueRange = Range(match.range(at: 3), in: result)
            else { continue }
            result.replaceSubrange(valueRange, with: "********")
        }
        return result
    }

    // `NSRegularExpression` n'est pas `Sendable` dans l'overlay Foundation,
    // mais elle est immuable une fois compilée et son appariement ne mute
    // aucun état interne partagé — c'est le cas d'usage que
    // `nonisolated(unsafe)` couvre légitimement, plutôt que de reconstruire
    // le motif à chaque appel de `maskSecrets`.
    private nonisolated(unsafe) static let secretPattern: NSRegularExpression = {
        let names = "secretAccessKey|password|KOPIA_PASSWORD|Authorization"
        // Groupe 3 : la valeur, un seul jeton sans espace ni guillemet — ce
        // que le briefing décrit comme « une chaîne longue sans espace après
        // » le nom. On ne borne pas la longueur haute : mieux vaut sur-masquer
        // un jeton court que laisser passer une clé complète.
        let pattern = "(?i)(\(names))(\"?\\s*[:=]\\s*\"?)([^\\s\"]{3,})"
        // swiftlint:disable:next force_try
        return try! NSRegularExpression(pattern: pattern)
    }()

    // MARK: - Le classement d'une ligne

    private struct LineMatch {
        var kind: FailureKind
        var link: ChainLink?
        var summary: String
        var suggestedAction: String?
    }

    /// Essaie chaque motif connu sur une ligne, dans l'ordre où un désaccord
    /// entre deux motifs sur la même ligne doit se trancher — les motifs les
    /// plus spécifiques d'abord, pour qu'un message S3 qui contiendrait
    /// accidentellement le mot « source » ne bascule pas dans la mauvaise
    /// famille.
    private static func classifyLine(_ line: String) -> LineMatch? {
        if line.contains("invalid repository password") {
            return LineMatch(
                kind: .authentication,
                link: .repositoryOpens,
                summary: "Le mot de passe du dépôt de sauvegarde n'est plus valide : kopia refuse d'ouvrir le dépôt.",
                suggestedAction: "Ressaisir le mot de passe du dépôt dans les réglages — celui enregistré au trousseau ne correspond plus à celui du dépôt."
            )
        }

        if line.contains("repository is not connected") {
            return LineMatch(
                kind: .notConfigured,
                link: nil,
                summary: "Le dépôt de sauvegarde n'est pas encore relié à cette machine.",
                suggestedAction: "Terminer la configuration de la sauvegarde — identifiants S3 et mot de passe du dépôt."
            )
        }

        // Un compartiment absent (`NoSuchBucket`/404) est distingué d'un
        // dépôt qui s'ouvre mal et refuse pour une raison de format ou
        // d'index (`.repository`, « grave »). Un compartiment qu'on n'atteint
        // pas du tout ressemble bien plus à une configuration qui pointe au
        // mauvais endroit — nom de seau mal recopié, ou seau jamais créé —
        // qu'à un dépôt existant mais corrompu : il n'y a même pas de dépôt à
        // corrompre puisqu'on n'a jamais pu l'ouvrir. D'où `.notConfigured`
        // plutôt que `.repository`.
        if line.contains("NoSuchBucket") || mentionsHTTPStatus(404, in: line) {
            return LineMatch(
                kind: .notConfigured,
                link: .bucketReachable,
                summary: "Le compartiment S3 configuré est introuvable — il n'existe pas, ou plus, sous ce nom.",
                suggestedAction: "Vérifier le nom du compartiment dans les réglages, ou le recréer s'il a été supprimé côté MinIO."
            )
        }

        if line.contains("AccessDenied") || line.contains("InvalidAccessKeyId")
            || line.contains("SignatureDoesNotMatch") || mentionsHTTPStatus(403, in: line) {
            return LineMatch(
                kind: .authentication,
                link: .bucketReachable,
                summary: "MinIO refuse les identifiants S3 enregistrés pour ce compartiment.",
                suggestedAction: "Vérifier la clé d'accès et la clé secrète S3 dans les réglages — elles ont pu être régénérées côté MinIO."
            )
        }

        if line.contains("no such file or directory") || line.contains("unsupported source") {
            let path = extractSourcePath(from: line)
            let summary = path.map { "Le dossier à sauvegarder n'existe plus : \($0)." }
                ?? "Un des dossiers à sauvegarder n'existe plus à l'endroit configuré."
            return LineMatch(
                kind: .storage,
                link: nil,
                summary: summary,
                suggestedAction: "Vérifier que ce dossier existe encore sur ce Mac, ou le retirer de la liste des sources."
            )
        }

        if let transport = transportMatch(line) {
            return transport
        }

        if line.contains("no space left on device") {
            return LineMatch(
                kind: .storage,
                link: nil,
                summary: "Le disque de ce Mac n'a plus de place — kopia ne peut plus écrire son cache local.",
                suggestedAction: "Libérer de l'espace disque, puis relancer la sauvegarde."
            )
        }

        if line.contains("disk quota exceeded") {
            return LineMatch(
                kind: .storage,
                link: nil,
                summary: "Le quota disque de ce compte est atteint — kopia ne peut plus écrire son cache local.",
                suggestedAction: "Libérer de l'espace dans le quota du compte, puis relancer la sauvegarde."
            )
        }

        return nil
    }

    /// Les six formes de panne de transport listées dans le briefing.
    /// Regroupées : elles partagent le même genre, le même maillon, et la
    /// même politique de réessai — seule la phrase change, pour nommer *où*
    /// ça a cassé plutôt que de dire « erreur réseau », qui ne se lit sur
    /// rien.
    private static func transportMatch(_ line: String) -> LineMatch? {
        let markers = [
            "connection refused", "no route to host", "i/o timeout",
            "context deadline exceeded", "EOF", "dial tcp",
        ]
        guard markers.contains(where: { line.contains($0) }) else { return nil }

        let port = extractPort(from: line)
        let summary = port.map {
            "MinIO n'a pas répondu sur le port \($0) — le conteneur est peut-être arrêté côté Proxmox, ou Tailscale a coupé la route."
        } ?? "MinIO n'a pas répondu à temps sur le réseau Tailscale — le conteneur est peut-être arrêté, ou la route a été coupée."

        return LineMatch(
            kind: .network,
            link: .s3Reachable,
            summary: summary,
            // Rien à suggérer : c'est transitoire par nature, la sauvegarde
            // réessaiera d'elle-même. Un bouton « réessayer » enseignerait
            // que le réessai automatique ne suffit pas.
            suggestedAction: nil
        )
    }

    // MARK: - L'interruption

    private static func interruptedFailure(signal: Int32?, rawOutput: String) -> BackupFailure {
        let summary: String
        if let signal {
            summary = "La sauvegarde a été interrompue (\(signalName(signal))) — elle reprendra, et la déduplication rendra la reprise bon marché."
        } else {
            summary = "La sauvegarde a été interrompue — elle reprendra, et la déduplication rendra la reprise bon marché."
        }
        return BackupFailure(
            kind: .interrupted,
            summary: summary,
            suggestedAction: nil,
            rawOutput: maskSecrets(in: rawOutput),
            link: nil
        )
    }

    /// Les trois signaux nommés dans le briefing ; au-delà, le numéro brut
    /// reste plus honnête qu'un nom deviné.
    private static func signalName(_ signal: Int32) -> String {
        switch signal {
        case 2: "SIGINT"
        case 9: "SIGKILL"
        case 15: "SIGTERM"
        default: "signal \(signal)"
        }
    }

    // MARK: - L'échec non lu

    private static func unparseableFailure(rawOutput: String) -> BackupFailure {
        BackupFailure(
            kind: .unparseable,
            summary: "Kopia a rendu un message que bran ne sait pas encore interpréter.",
            suggestedAction: "Copier le journal brut ci-dessous : ce message n'est pas reconnu par bran.",
            rawOutput: maskSecrets(in: rawOutput),
            link: nil
        )
    }

    /// Vrai quand la ligne parle vraiment d'un code HTTP, et non d'un nombre
    /// qui en contient les chiffres.
    ///
    /// **Chercher « 403 » en sous-chaîne est un piège à retardement.** Les
    /// compteurs de Kopia traversent des millions de valeurs pendant un
    /// transfert de plusieurs heures ; que l'une d'elles contienne 403 ou 404
    /// n'est pas une éventualité, c'est une certitude. Le filtre du bruit
    /// écarte déjà les lignes de progression, mais s'appuyer sur lui seul
    /// laisserait le piège armé pour la première forme de sortie qu'il ne
    /// connaîtrait pas encore.
    ///
    /// On exige donc que le nombre soit **isolé** — pas entouré d'autres
    /// chiffres — et accompagné d'un mot qui en fait un code de statut. Les
    /// formes retenues sont celles que les clients S3 et Go écrivent
    /// réellement : `status code: 403`, `StatusCode: 404`, `HTTP 403`,
    /// `response status 404`.
    private static func mentionsHTTPStatus(_ code: Int, in line: String) -> Bool {
        let lowered = line.lowercased()
        let markers = ["status code: ", "statuscode: ", "status code ", "http ", "http/1.1 ", "status "]
        for marker in markers {
            var search = lowered[...]
            while let range = search.range(of: marker + String(code)) {
                let after = search.index(range.upperBound, offsetBy: 0)
                let followedByDigit = after < search.endIndex && search[after].isNumber
                if !followedByDigit { return true }
                search = search[range.upperBound...]
            }
        }
        return false
    }

    // MARK: - Le bruit qu'on ignore sans le classer en erreur

    /// Vrai pour une ligne qu'on sait être inoffensive : maintenance en
    /// tâche de fond, progression de `snapshot verify`, bannière de début de
    /// snapshot, résumé d'agrégation d'erreurs, ou ligne vide. Aucune de ces
    /// lignes ne doit, à elle seule, faire basculer une sortie propre en
    /// `.unparseable`.
    private static func isIgnorable(_ rawLine: String) -> Bool {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.isEmpty { return true }

        // La liste complète relevée sur les vraies exécutions — cycle rapide
        // **et** cycle complet. Elle n'en portait que la moitié, et il a suffi
        // d'un `Running quick maintenance...` pour qu'un run réussi soit
        // déclaré incompréhensible.
        let maintenanceMarkers = [
            "Running full maintenance", "Running quick maintenance",
            "Finished full maintenance", "Finished quick maintenance",
            "GC found", "GC undeleted", "Compacting", "Attempting to compact",
            "Advancing epoch markers", "Cleaning up", "Cleaned up",
        ]
        if maintenanceMarkers.contains(where: { line.contains($0) }) { return true }

        // **La ligne de progression, et c'est elle qui manquait.**
        //
        // `KopiaProgressReader` la lit déjà, dans la cible pure, à l'autre
        // bout du même flux : elle est donc tout sauf inconnue du programme.
        // Le classifieur, lui, ne la connaissait pas — et comme elle arrive
        // par centaines pendant un run, le moindre snapshot réussi ressortait
        // en échec de type « message non interprété ».
        //
        // On la reconnaît à sa forme, préfixe de rotation compris (`|`, `/`,
        // `-`, `\`, `*`), et non par une simple recherche de « hashing » :
        // une vraie erreur qui contiendrait ce mot ne doit pas s'échapper par
        // cette porte.
        if let first = line.first, "|/-\\*".contains(first),
           line.contains(" hashing, "), line.contains(" cached (") {
            return true
        }

        // `snapshot verify` — texte, sans JSON — écrit sa progression sous
        // cette forme sur stderr pendant une vérification réussie.
        if line.hasPrefix("Processed ") || line.hasPrefix("Finished processing ") { return true }

        // La bannière que `snapshot create` écrit avant de commencer :
        // aucune information d'échec, seulement le rappel de la source.
        if line.hasPrefix("Snapshotting ") { return true }

        // Le résumé d'agrégation lui-même — la vraie cause est sur une des
        // lignes suivantes, déjà traitées par `classifyLine` avant qu'on
        // n'atteigne ce filtre.
        if line.hasPrefix("encountered ") && line.hasSuffix("errors:") { return true }
        if line == "encountered 1 error:" { return true }

        return false
    }

    // MARK: - L'extraction, jamais la supposition

    /// Le chemin d'une source absente, tiré de `lstat <chemin>: no such file
    /// or directory` ou de `unsupported source: <hôte>:<chemin>`. Rend `nil`
    /// plutôt qu'une valeur plausible si le format ne correspond pas
    /// exactement — la doctrine du projet interdit de deviner.
    private static func extractSourcePath(from line: String) -> String? {
        if let lstatRange = line.range(of: "lstat "),
           let terminator = line.range(of: ": no such file or directory", range: lstatRange.upperBound..<line.endIndex) {
            return String(line[lstatRange.upperBound..<terminator.lowerBound])
        }
        if let sourceRange = line.range(of: "unsupported source: ") {
            return String(line[sourceRange.upperBound...])
        }
        return nil
    }

    /// Le port d'un `dial tcp <hôte>:<port>`, quand la ligne le porte.
    ///
    /// **Le dernier `:` de la ligne n'est pas le bon.** Le Go de kopia écrit
    /// `dial tcp 100.x.x.x:9000: connect: connection refused` — un deuxième
    /// `:` sépare le message d'erreur qui suit l'adresse. Chercher le
    /// *dernier* deux-points de toute la ligne attrape celui-là et rend une
    /// chaîne vide plutôt que le port. On isole donc d'abord le jeton
    /// « hôte:port » — tout ce qui suit `dial tcp ` jusqu'au premier blanc —
    /// avant d'y chercher le `:` qui compte.
    private static func extractPort(from line: String) -> String? {
        guard let dialRange = line.range(of: "dial tcp ") else { return nil }
        let rest = line[dialRange.upperBound...]
        let addressToken = rest.prefix { !$0.isWhitespace }
        guard let colon = addressToken.firstIndex(of: ":") else { return nil }
        let afterColon = addressToken[addressToken.index(after: colon)...]
        let digits = afterColon.prefix { $0.isNumber }
        return digits.isEmpty ? nil : String(digits)
    }
}
