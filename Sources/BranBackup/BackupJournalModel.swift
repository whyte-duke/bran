import Foundation

// Le format et les questions du journal des tentatives. Aucune écriture
// disque ici — l'écriture atomique en ajout est un autre fichier, écrit par
// quelqu'un d'autre. Celui-ci ne fait que deux choses : transformer une
// `BackupAttempt` en une ligne de texte et retour, et répondre aux questions
// que le reste du programme pose à un historique déjà en mémoire.
//
// **Pourquoi JSONL et pas un unique document JSON.** Le journal a deux
// écrivains concurrents — l'application et le job `launchd` — qui n'ouvrent
// jamais le fichier en même temps que pour y ajouter une ligne. Un document
// JSON unique demanderait de relire, fusionner et réécrire tout le fichier à
// chaque tentative : la fenêtre où un crash pourrait laisser un fichier à
// moitié réécrit y grandit avec l'historique. Une ligne par tentative, en
// ajout pur, n'a que la dernière ligne à risque — et cette machine-là relit
// ce risque comme le cas normal, pas comme une exception.

/// Une erreur de forme, distincte d'une ligne du journal illisible.
///
/// **Ne sert qu'à `encode` et à ce que `decode` ne trouve pas dans
/// `DecodingError`.** Une ligne corrompue *lue* depuis un fichier n'a pas
/// besoin de ce type — `parse` la classe directement dans `corrupted`, quelle
/// que soit l'erreur Swift qui l'a produite.
public enum BackupJournalError: Error, Sendable, Equatable {
    /// La ligne encodée ne serait pas de l'UTF-8 valide. N'est pas censé
    /// arriver — `String(data:encoding:)` échoue seulement sur des octets
    /// invalides, et `JSONEncoder` n'en produit pas — mais `encode` ne doit
    /// pas faire semblant de pouvoir toujours réussir.
    case invalidUTF8
    /// Le texte encodé contiendrait un retour à la ligne. Ne devrait jamais
    /// arriver non plus — `JSONEncoder` échappe `\n` dans les chaînes — mais
    /// tout le format JSONL repose sur « une ligne = une tentative » : une
    /// garde explicite vaut mieux qu'un fichier silencieusement corrompu par
    /// une future version de `Foundation` plus permissive.
    case embeddedNewline
}

/// Le format et les questions du journal des tentatives de sauvegarde.
///
/// Un espace de noms de fonctions pures, à l'image de `SpeedFormat` : aucun
/// état, seulement des transformations entre une `BackupAttempt` et sa forme
/// écrite, et des lectures sur un historique déjà chargé en mémoire.
public enum BackupJournalModel {

    /// La version du format d'une ligne de journal.
    ///
    /// **Portée par chaque ligne, pas par le fichier.** Un en-tête de fichier
    /// ne survivrait pas à ce journal : deux processus y ajoutent des lignes
    /// sans jamais se coordonner, donc rien ne garantit qu'un en-tête écrit
    /// une fois resterait la première ligne, ni que les deux écrivains
    /// tournent la même version de bran au même instant pendant une mise à
    /// jour. Une version par ligne rend chaque ligne autonome : une future
    /// version du format peut relire un vieux journal ligne par ligne sans
    /// avoir à deviner d'où vient chacune. Aujourd'hui il n'existe qu'une
    /// version ; le champ existe pour que la suivante ait un endroit où
    /// brancher sans casser celle-ci — voir `decode(line:)`.
    public static let currentFormatVersion = 1

    /// L'enveloppe réellement écrite sur une ligne. Interne : l'API publique
    /// parle en `BackupAttempt`, jamais en enveloppe — la version est un
    /// détail d'écriture, pas une donnée que le reste du programme a besoin
    /// de manipuler.
    private struct JournalLine: Codable {
        var formatVersion: Int
        var attempt: BackupAttempt
    }

    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    // MARK: - Encoder et décoder une ligne

    /// Une `BackupAttempt`, sur une seule ligne, prête à être ajoutée au
    /// fichier.
    public static func encode(_ attempt: BackupAttempt) throws -> String {
        let envelope = JournalLine(formatVersion: currentFormatVersion, attempt: attempt)
        let data = try encoder.encode(envelope)
        guard let text = String(data: data, encoding: .utf8) else {
            throw BackupJournalError.invalidUTF8
        }
        guard !text.contains("\n") else {
            throw BackupJournalError.embeddedNewline
        }
        return text
    }

    /// L'inverse de `encode(_:)`, sur une ligne déjà isolée du reste du
    /// fichier.
    ///
    /// Ne rejette jamais une ligne au seul motif que `formatVersion` lui est
    /// inconnu. Un format qui n'aurait fait qu'ajouter des champs — la seule
    /// évolution prévue tant que `BackupAttempt` reste défini dans le contrat
    /// commun — se relit déjà sans y toucher : `JSONDecoder` ignore les clés
    /// qu'il ne connaît pas, à n'importe quel niveau. Le jour où un format
    /// change de forme plutôt que d'ajouter des champs, c'est ici qu'il
    /// faudra faire brancher la lecture sur `envelope.formatVersion` — la
    /// raison pour laquelle ce champ est lu et pas seulement écrit.
    public static func decode(line: String) throws -> BackupAttempt {
        guard let data = line.data(using: .utf8) else {
            throw BackupJournalError.invalidUTF8
        }
        let envelope = try decoder.decode(JournalLine.self, from: data)
        return envelope.attempt
    }

    // MARK: - Relire un fichier entier

    /// Relit le contenu d'un journal, ligne par ligne.
    ///
    /// **Une ligne illisible ne fait jamais échouer les autres.** C'est le
    /// cas normal de ce format, pas son cas limite : la dernière ligne d'un
    /// journal est tronquée à chaque fois que la machine s'éteint pendant
    /// qu'on y écrit, et c'est justement l'instant où l'historique qui
    /// précède compte le plus. Les lignes illisibles sont rendues à part —
    /// jamais avalées, pour qu'un appelant puisse un jour les signaler —
    /// mais elles n'empêchent jamais de lire ce qui reste.
    public static func parse(_ contents: String) -> (attempts: [BackupAttempt], corrupted: [String]) {
        var attempts: [BackupAttempt] = []
        var corrupted: [String] = []

        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: true) {
            var line = String(rawLine)
            // Tolère du CRLF sans le traiter comme une ligne à part : un
            // journal recopié depuis un outil qui écrit du CRLF ne doit pas
            // se retrouver avec une ligne corrompue sur deux.
            if line.hasSuffix("\r") { line.removeLast() }

            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }

            do {
                attempts.append(try decode(line: line))
            } catch {
                corrupted.append(line)
            }
        }

        return (attempts, corrupted)
    }

    // MARK: - Les questions posées à l'historique

    /// La date qui ordonne une tentative : celle de son issue quand elle en a
    /// une, celle de son départ sinon.
    ///
    /// **L'ordre n'est pas celui du fichier.** Deux processus écrivent dans
    /// le même journal ; leurs lignes s'entrelacent selon l'ordre d'écriture
    /// sur disque, pas selon un ordre chronologique global. Toutes les
    /// questions ci-dessous trient explicitement sur cette date plutôt que de
    /// faire confiance à la position dans le tableau.
    private static func orderingDate(_ attempt: BackupAttempt) -> Date {
        attempt.finishedAt ?? attempt.startedAt
    }

    /// Une tentative par identifiant, la plus récente retenue.
    ///
    /// La doc du contrat parle d'une écriture « à chaque transition durable »
    /// — au pluriel — ce qui laisse ouverte la possibilité qu'un même `id`
    /// soit écrit plus d'une fois (par exemple une ligne au départ, une autre
    /// à l'issue). Cette fonction ne suppose ni l'un ni l'autre : si chaque
    /// tentative n'apparaît qu'une fois, elle ne change rien ; si elle
    /// apparaît plusieurs fois, elle ne garde que la version la plus
    /// avancée. C'est une défense, pas une certitude sur ce que l'écrivain
    /// fera réellement — voir le rapport de mission pour ce doute.
    private static func latestPerAttempt(_ attempts: [BackupAttempt]) -> [BackupAttempt] {
        var latest: [UUID: BackupAttempt] = [:]
        for attempt in attempts {
            if let existing = latest[attempt.id], orderingDate(existing) >= orderingDate(attempt) {
                continue
            }
            latest[attempt.id] = attempt
        }
        return Array(latest.values)
    }

    /// La dernière tentative *réussie*, ou `nil` si aucune ne l'a été.
    ///
    /// **Il n'existe pas de deuxième définition du succès ici.** Le filtre
    /// est `attempt.succeeded`, qui vient du contrat et vaut
    /// `proof?.isTrustworthy == true` — ni plus, ni moins. Une tentative dont
    /// la seule preuve est `.reportedByCreate`, ou dont `isComplete` est faux
    /// malgré une confirmation, a `succeeded == false` avant même d'arriver
    /// ici : cette fonction n'a rien à revérifier, seulement à trier.
    /// Combien d'échecs se sont enchaînés depuis la dernière réussite.
    ///
    /// **C'est le compteur qui empêche une boucle.** `SchedulePolicy` s'en sert
    /// pour espacer les tentatives : sans lui, un mot de passe de dépôt devenu
    /// faux ferait relancer un run toutes les minutes, remplirait le journal de
    /// milliers de lignes identiques, et noierait l'échec qu'il fallait lire.
    ///
    /// Il vit ici, avec les autres questions qu'on pose au journal, plutôt que
    /// dans la politique : la politique est une fonction pure d'entrées, et
    /// compter des échecs demande d'avoir l'historique sous les yeux.
    ///
    /// **Seuls les échecs réessayables comptent**, et c'est la moitié du sens.
    /// Le recul exponentiel sert à ne pas marteler un serveur qui redémarre ;
    /// un mauvais mot de passe de dépôt, lui, ne se répare pas en attendant
    /// plus longtemps. Les mélanger ferait grandir le recul pour une raison
    /// qui n'a rien à voir avec la patience.
    ///
    /// On compte à rebours depuis la tentative la plus récente et on s'arrête à
    /// la première qui n'est pas un échec réessayable. Une tentative encore en
    /// cours — ni preuve ni échec — rompt donc la série plutôt que de la
    /// prolonger : elle n'a rien démontré.
    public static func consecutiveFailures(in attempts: [BackupAttempt]) -> Int {
        var count = 0
        for attempt in history(in: attempts, limit: attempts.count) {
            guard attempt.succeeded == false,
                  let failure = attempt.failure,
                  failure.kind.deservesRetry
            else { break }
            count += 1
        }
        return count
    }

    public static func lastSuccess(in attempts: [BackupAttempt]) -> BackupAttempt? {
        latestPerAttempt(attempts)
            .filter(\.succeeded)
            .max { orderingDate($0) < orderingDate($1) }
    }

    /// La dernière tentative, réussie ou non.
    public static func lastAttempt(in attempts: [BackupAttempt]) -> BackupAttempt? {
        latestPerAttempt(attempts)
            .max { orderingDate($0) < orderingDate($1) }
    }

    /// Les `limit` tentatives les plus récentes, la plus récente en premier.
    public static func history(in attempts: [BackupAttempt], limit: Int) -> [BackupAttempt] {
        guard limit > 0 else { return [] }
        return Array(
            latestPerAttempt(attempts)
                .sorted { orderingDate($0) > orderingDate($1) }
                .prefix(limit)
        )
    }

    /// Les échecs survenus depuis `since`.
    ///
    /// **Exclut les tentatives seulement interrompues.** Le contrat est
    /// explicite sur ce point (`FailureKind.interrupted` : « Pas un échec de
    /// la sauvegarde : une interruption, dont on reprendra ») — un Mac qui
    /// s'est mis en veille pendant un transfert n'est pas une panne, et le
    /// compter comme telle apprendrait à ignorer une liste d'échecs qui
    /// grossit pour de mauvaises raisons.
    public static func failures(in attempts: [BackupAttempt], since: Date) -> [BackupAttempt] {
        latestPerAttempt(attempts).filter { attempt in
            guard let failure = attempt.failure, failure.kind != .interrupted else { return false }
            return orderingDate(attempt) >= since
        }
    }

    /// Le delta d'octets réellement montés entre une tentative et celle qui
    /// la précède.
    ///
    /// `nil` quand l'un des deux volumes manque — **jamais 0**, qui
    /// prétendrait qu'aucun octet n'a bougé alors qu'on ne sait tout
    /// simplement pas. Peut être négatif : ce n'est pas borné artificiellement
    /// à une progression, et un delta négatif est le signe le plus honnête
    /// qu'on puisse afficher si `previous` n'est en fait pas la tentative
    /// d'avant.
    public static func newBytes(between attempt: BackupAttempt, and previous: BackupAttempt?) -> Int64? {
        guard let previous, let current = attempt.uploadedBytes, let earlier = previous.uploadedBytes else {
            return nil
        }
        return current - earlier
    }

    /// Le même delta, mais calculé directement sur un historique dans le
    /// désordre : trouve la dernière tentative et celle qui la précède
    /// chronologiquement, sans que l'appelant ait à les chercher lui-même.
    ///
    /// C'est ce chiffre qui rend une reprise visible : au deuxième passage
    /// sur une même source, la dédup fait que le volume réellement monté
    /// s'effondre, et c'est ce delta-là qui le montre — pas `proof.totalSize`,
    /// qui décrit l'arborescence entière et ne bouge presque pas.
    public static func newBytesSinceLastAttempt(in attempts: [BackupAttempt]) -> Int64? {
        let ordered = latestPerAttempt(attempts).sorted { orderingDate($0) < orderingDate($1) }
        guard let last = ordered.last else { return nil }
        return newBytes(between: last, and: ordered.dropLast().last)
    }
}
