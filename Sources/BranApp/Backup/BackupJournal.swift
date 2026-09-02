import BranBackup
import Darwin
import Foundation

/// Le disque du journal de sauvegarde : l'ajout atomique, la lecture
/// tolérante à la corruption, la rotation. Le **format** — encodage JSONL,
/// décodage, requêtes sur l'historique (dernier succès, échecs enchaînés) —
/// vit dans `BackupJournalModel`, côté `BranBackup`, écrit par un autre
/// agent. Ce fichier ne connaît que des octets et un chemin ; il ne
/// réimplémente jamais la forme d'une ligne.
///
/// ## Pourquoi l'ajout doit être un seul `write()`, verrouillé
///
/// Deux processus écrivent ici : l'interface, pour un run manuel, et le job
/// launchd (`BackupHeadlessRun`), pour tout le reste — c'est-à-dire la
/// quasi-totalité des écritures, puisque la première sauvegarde de ce Mac
/// dure environ 30 heures et que personne ne laisse bran ouvert tout ce
/// temps. Un `append` naïf — écrire le corps JSON, puis écrire `"\n"` — peut
/// entrelacer deux tentatives et corrompre les deux lignes à la fois.
///
/// Ce que POSIX garantit vraiment tient en une phrase : sur un fichier ouvert
/// `O_APPEND`, **un seul appel `write()`** ne peut pas être coupé en deux par
/// le `write()` d'un autre processus — le noyau sérialise des appels
/// entiers, jamais leurs octets. Cette garantie ne dit en revanche **rien**
/// sur deux appels `write()` successifs du même processus : un `write()`
/// d'un tiers peut s'intercaler entre le corps JSON et son `\n`, et le
/// fichier porte alors deux lignes JSON collées sans séparateur, chacune
/// ensuite privée de sa propre fin de ligne — exactement la corruption que
/// ce fichier existe pour empêcher. La seule mention chiffrée que POSIX fait
/// de ce genre d'atomicité est `PIPE_BUF`, et elle ne vaut que pour les
/// tubes : pour un fichier ordinaire, rien n'oblige un système à traiter un
/// gros `write()` comme indivisible.
///
/// D'où deux règles, cumulées, aucune ne suffisant seule :
/// 1. le buffer complet — JSON **et** `\n` — est construit une fois, remis
///    au noyau en un seul appel `write()` ;
/// 2. `flock` tient l'exclusion pendant toute l'opération d'écriture, pour
///    ne pas reposer uniquement sur un comportement d'atomicité que la
///    norme ne promet pas explicitement en dehors des tubes.
public enum BackupJournal {

    // MARK: - L'emplacement

    /// `~/Library/Application Support/bran/backup/journal.jsonl`, résolu à
    /// l'exécution — jamais un chemin littéral : le frère du propriétaire
    /// fait tourner la même application, sous un compte différent.
    public static var path: URL {
        directory.appending(path: "journal.jsonl", directoryHint: .notDirectory)
    }

    /// Le dossier qui porte le journal, et à côté duquel
    /// `BackupHeadlessRun` pose son verrou de simultanéité — un fichier
    /// dédié, distinct du journal lui-même, pour que prendre le verrou
    /// n'implique jamais d'ouvrir le journal en écriture.
    public static var directory: URL {
        URL.applicationSupportDirectory
            .appending(path: "bran", directoryHint: .isDirectory)
            .appending(path: "backup", directoryHint: .isDirectory)
    }

    // MARK: - Les échecs nommés

    public enum Failure: Error, CustomStringConvertible {
        case cannotCreateDirectory(String)
        case cannotEncode(String)
        case cannotOpen(errno: Int32)
        case cannotLock(errno: Int32)
        /// Le `write()` a rendu moins d'octets que le buffer n'en portait —
        /// le cas le plus probable est un disque plein en cours d'écriture.
        /// Le compter comme un succès partiel serait le même mensonge que
        /// celui documenté dans `BackupContract` : mieux vaut une ligne
        /// perdue et nommée qu'une ligne à moitié écrite qu'on croirait
        /// complète.
        case shortWrite(wrote: Int, expected: Int)
        case cannotRotate(String)

        public var description: String {
            switch self {
            case let .cannotCreateDirectory(reason): "dossier du journal introuvable : \(reason)"
            case let .cannotEncode(reason): "tentative non encodable en JSON : \(reason)"
            case let .cannotOpen(code): "ouverture du journal impossible (errno \(code))"
            case let .cannotLock(code): "verrou du journal impossible (errno \(code))"
            case let .shortWrite(wrote, expected):
                "écriture tronquée (\(wrote)/\(expected) octets) — disque plein pendant l'écriture ?"
            case let .cannotRotate(reason): "rotation du journal impossible : \(reason)"
            }
        }
    }

    // MARK: - Ajouter

    /// Ajoute une tentative au journal, en un seul `write()` verrouillé.
    /// Voir l'en-tête du fichier pour ce que garantit — et ne garantit pas —
    /// `O_APPEND` seul.
    public static func append(_ attempt: BackupAttempt) throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw Failure.cannotCreateDirectory(String(describing: error))
        }

        var line: Data
        do {
            // `encode` rend le JSON en texte ; c'est ici, et seulement ici,
            // qu'il devient des octets — parce que c'est ici qu'on maîtrise ce
            // qui part dans l'unique `write()`.
            line = Data(try BackupJournalModel.encode(attempt).utf8)
        } catch {
            throw Failure.cannotEncode(String(describing: error))
        }
        // Le `\n` DANS le même buffer que le JSON : c'est ce qui garantit
        // qu'un seul `write()` porte la ligne entière, séparateur compris —
        // voir l'en-tête pour pourquoi un deuxième `write()` séparé pour le
        // seul `\n` romprait la garantie.
        line.append(0x0A)

        let cPath = path.path(percentEncoded: false)

        // **Ouvrir, verrouiller, puis vérifier qu'on tient bien le fichier
        // qu'on croit — et recommencer sinon.**
        //
        // `flock` verrouille un **inœud**, pas un chemin. Le scénario qui
        // perdait des lignes tenait en trois temps, avec les deux écrivains que
        // ce module a par construction (l'interface et le job launchd) :
        //
        // 1. B ouvre `journal.jsonl` (inœud 42) et se met en attente du verrou,
        //    que A tient déjà.
        // 2. A finit d'écrire, constate que le fichier dépasse le seuil, le
        //    renomme en `journal-<horodatage>.jsonl` — l'inœud 42 s'appelle
        //    maintenant autrement — puis relâche le verrou.
        // 3. B obtient le verrou sur l'inœud 42 et écrit sa ligne… dans
        //    l'archive. Le prochain `readAll()` ne relisait que `journal.jsonl`,
        //    tout neuf : la tentative de B avait disparu, sans erreur, sans
        //    trace.
        //
        // `fstat` sur le descripteur tenu, comparé à `stat` sur le chemin, dit
        // exactement si le renommage a eu lieu entre l'ouverture et la prise du
        // verrou. Deux essais suffisent en pratique — la rotation n'arrive
        // qu'une fois par 5 Mio — mais la boucle est bornée pour ne jamais
        // devenir une attente sans fin.
        var fd: Int32 = -1
        var attemptsLeft = 3
        while true {
            fd = open(cPath, O_WRONLY | O_CREAT | O_APPEND, 0o644)
            guard fd >= 0 else { throw Failure.cannotOpen(errno: errno) }

            // Bloquant, volontairement : contrairement au verrou de
            // simultanéité de `BackupHeadlessRun` (qui doit échouer tout de
            // suite plutôt qu'attendre 30 heures), un ajout au journal est une
            // écriture de quelques centaines d'octets — attendre le tour de
            // l'autre écrivain coûte, au pire, le temps de CE `write()`-là.
            guard flock(fd, LOCK_EX) == 0 else {
                let code = errno
                close(fd)
                throw Failure.cannotLock(errno: code)
            }

            var held = stat()
            var onDisk = stat()
            let sameFile = fstat(fd, &held) == 0
                && stat(cPath, &onDisk) == 0
                && held.st_dev == onDisk.st_dev
                && held.st_ino == onDisk.st_ino
            if sameFile { break }

            flock(fd, LOCK_UN)
            close(fd)
            attemptsLeft -= 1
            guard attemptsLeft > 0 else {
                throw Failure.cannotRotate(
                    "le journal a été renommé sous le verrou trois fois de suite ; la tentative n'a pas été écrite")
            }
        }
        defer { close(fd) }
        defer { flock(fd, LOCK_UN) }

        let written = line.withUnsafeBytes { buffer -> Int in
            write(fd, buffer.baseAddress, buffer.count)
        }
        guard written == line.count else {
            throw Failure.shortWrite(wrote: max(0, written), expected: line.count)
        }

        // Sous le même verrou que l'écriture qui vient de se faire : sans
        // ça, un autre `append` pourrait s'intercaler entre le constat
        // « trop gros » et le renommage, et sa ligne atterrirait dans
        // l'ancien fichier juste après qu'il a été archivé — invisible pour
        // tout `readAll()` suivant, qui ne relit que `path`.
        try rotateIfNeeded(fd: fd)
    }

    // MARK: - Lire

    /// Ce qu'une lecture rend : ce qui s'est laissé décoder, et ce qui ne
    /// s'est pas laissé décoder — jamais un échec en bloc pour une seule
    /// ligne abîmée.
    public struct ReadResult: Sendable {
        public let attempts: [BackupAttempt]
        /// Des lignes présentes dans le fichier mais que
        /// `BackupJournalModel.parse` a refusées — JSON invalide, champ
        /// manquant. Un compte, jamais le contenu : une ligne abîmée n'a
        /// rien à montrer.
        public let unreadableLineCount: Int
        /// Vrai quand le fichier ne se termine pas par `\n`. **C'est le cas
        /// normal**, pas un cas limite : une extinction pendant l'écriture
        /// laisse exactement cette trace. La ligne tronquée qui en résulte
        /// n'est écartée que si elle est la dernière — voir `readAll()`.
        public let lastLineWasTruncated: Bool
        /// Pourquoi le journal n'a pas pu être **lu**, quand c'est le cas.
        ///
        /// **Un journal illisible n'est pas un journal absent.**
        /// `FileManager.contents(atPath:)` rend `nil` dans les deux cas, et
        /// l'ancienne lecture les confondait : un fichier présent mais dont les
        /// droits ont été retirés, ou porté par un disque en panne, produisait
        /// exactement le même résultat qu'un Mac qui n'a jamais tenté de
        /// sauvegarde — zéro tentative, aucune erreur, aucune alerte. Tout
        /// l'historique disparaissait de l'écran en silence, et
        /// `BackupAlerts.decide` retombait sur « aucune tentative n'a encore
        /// été consignée ; rien à mesurer », donc se taisait pour toujours.
        public let readFailure: String?
    }

    /// Lit tout le journal. Ne lève jamais pour un fichier absent : un Mac
    /// qui n'a encore jamais tenté de sauvegarde n'a pas de journal, ce
    /// n'est pas une erreur.
    public static func readAll() -> ReadResult {
        var attempts: [BackupAttempt] = []
        var unreadableLineCount = 0
        var lastLineWasTruncated = false
        var readFailure: String?

        // **Les archives d'abord, le journal courant ensuite.**
        //
        // `rotateIfNeeded` renomme le journal en `journal-<horodatage>.jsonl`
        // dès qu'il dépasse 5 Mio, et `readAll()` ne relisait que `path`. Le
        // jour de la rotation, tout l'historique de ce Mac disparaissait donc
        // de l'écran d'un coup : plus de dernier succès, donc « aucune
        // sauvegarde réussie » ; plus de couverture, donc « vos fichiers ne
        // sont pas protégés » ; et une alerte qui repart de zéro. Le fichier
        // n'était pas perdu — personne ne le rouvrait.
        //
        // Les archives sont lues de la plus ancienne à la plus récente : le
        // nom porte un horodatage Unix, l'ordre lexicographique n'est donc
        // fiable que sur un même nombre de chiffres, ce qui vaut pour les
        // quelque trois siècles à venir. `BackupJournalModel` dédoublonne et
        // retrie de toute façon.
        for archive in archives() {
            switch read(fileAt: archive) {
            case .absent:
                continue
            case .unreadable(let reason):
                // Une archive illisible n'empêche pas de lire le journal
                // courant — mais elle se dit, comme tout le reste.
                readFailure = (readFailure.map { $0 + " ; " } ?? "") + reason
            case .parsed(let parsedAttempts, let parsedUnreadable, _):
                attempts.append(contentsOf: parsedAttempts)
                unreadableLineCount += parsedUnreadable
            }
        }

        switch read(fileAt: path) {
        case .absent:
            break
        case .unreadable(let reason):
            readFailure = (readFailure.map { $0 + " ; " } ?? "") + reason
        case .parsed(let parsedAttempts, let parsedUnreadable, let truncatedTail):
            attempts.append(contentsOf: parsedAttempts)
            unreadableLineCount += parsedUnreadable
            lastLineWasTruncated = truncatedTail
        }

        return ReadResult(
            attempts: attempts,
            unreadableLineCount: unreadableLineCount,
            lastLineWasTruncated: lastLineWasTruncated,
            readFailure: readFailure
        )
    }

    private enum FileReadOutcome {
        case absent
        case unreadable(String)
        case parsed(attempts: [BackupAttempt], unreadable: Int, truncatedTail: Bool)
    }

    private static func read(fileAt url: URL) -> FileReadOutcome {
        let filePath = url.path(percentEncoded: false)
        // `fileExists` **avant** la lecture : c'est ce qui distingue « il n'y a
        // rien à lire » de « il y a quelque chose et je n'ai pas su le lire ».
        guard FileManager.default.fileExists(atPath: filePath) else { return .absent }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return .unreadable("« \(url.lastPathComponent) » existe mais n'a pas pu être lu : \(error)")
        }
        guard !data.isEmpty else { return .parsed(attempts: [], unreadable: 0, truncatedTail: false) }

        // Une dernière ligne sans `\n` final n'a jamais fini d'être écrite :
        // ce n'est ni une tentative complète, ni une tentative à moitié
        // racontée qu'il vaudrait la peine d'essayer de décoder. On l'écarte
        // avant même de tenter le parseur — pas en rattrapant son échec.
        let endsWithNewline = data.last == UInt8(ascii: "\n")
        var lines = String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)

        var truncatedTail = false
        if !endsWithNewline, !lines.isEmpty {
            lines.removeLast()
            truncatedTail = true
        }

        var attempts: [BackupAttempt] = []
        attempts.reserveCapacity(lines.count)
        var unreadable = 0
        for line in lines {
            do {
                attempts.append(try BackupJournalModel.decode(line: line))
            } catch {
                // Une ligne interne (pas la dernière) qui refuse de se
                // décoder est un autre visage de la même panne : deux
                // écritures dont les `write()` respectifs se sont malgré
                // tout suivis sans séparateur — voir l'en-tête. On la
                // compte, on ne s'y arrête pas… mais on essaie d'abord de
                // sauver ce qu'elle contient encore d'entier.
                unreadable += 1
                if let salvaged = salvage(line) { attempts.append(salvaged) }
            }
        }
        return .parsed(attempts: attempts, unreadable: unreadable, truncatedTail: truncatedTail)
    }

    /// Récupère la tentative **complète** collée derrière une tentative
    /// tronquée, sur une même ligne.
    ///
    /// ## La panne, au mot près
    ///
    /// Une extinction pendant un `write()` laisse un JSON amputé, sans son
    /// `\n`. Le prochain `append` — qui rouvre en `O_APPEND` — écrit sa propre
    /// ligne **juste derrière**, sur la même ligne physique :
    ///
    /// ```
    ///   {"id":"AAA","startedAt":123,"trig{"id":"BBB",…,"proof":{…}}\n
    ///   ^ moitié perdue à l'extinction  ^ tentative entière, victime collatérale
    /// ```
    ///
    /// `split(separator: "\n")` en fait **une** ligne, que le décodeur refuse.
    /// Deux tentatives disparaissent alors pour une seule écriture ratée — et
    /// la seconde était complète, souvent le succès qui suit le redémarrage.
    ///
    /// ## Pourquoi essayer chaque `{`, plutôt qu'un découpage plus malin
    ///
    /// L'objet perdu est amputé à un endroit qu'on ne connaît pas ; on ne peut
    /// donc pas calculer où commence le suivant, seulement le chercher. Chaque
    /// `{` de la ligne est un début possible : ceux qui tombent à l'intérieur
    /// de l'objet tronqué donnent un fragment que le décodeur refuse, celui
    /// qui ouvre l'objet entier donne un objet valide. On s'arrête au premier
    /// qui décode, et on n'essaie que les 64 premiers pour qu'une ligne
    /// pathologique — une longue suite de `{` — ne coûte pas un temps
    /// quadratique.
    ///
    /// Ce n'est jamais une invention : ce qui est rendu a été décodé
    /// entièrement, avec le même décodeur que les lignes saines. La moitié
    /// perdue, elle, reste perdue et reste comptée dans
    /// ``ReadResult/unreadableLineCount``.
    ///
    /// **Mesuré** sur une tentative de forme réaliste (objet imbriqué, plus un
    /// `rawOutput` contenant lui-même des accolades), coupée successivement à
    /// **chacune** de ses 147 positions possibles avec une tentative entière
    /// collée derrière : la tentative entière est récupérée dans 147 cas sur
    /// 147. Une ligne sans aucun JSON valide rend `nil`, et une ligne saine ne
    /// passe jamais ici — elle décode du premier coup.
    private static func salvage(_ line: String) -> BackupAttempt? {
        var attempted = 0
        var index = line.index(after: line.startIndex)
        while index < line.endIndex, attempted < salvageAttemptLimit {
            guard let next = line[index...].firstIndex(of: "{") else { return nil }
            attempted += 1
            if let decoded = try? BackupJournalModel.decode(line: String(line[next...])) {
                return decoded
            }
            index = line.index(after: next)
        }
        return nil
    }

    private static let salvageAttemptLimit = 64

    /// Les journaux archivés par la rotation, du plus ancien au plus récent, et
    /// bornés aux ``archiveReadLimit`` derniers.
    ///
    /// **Bornés, parce que lire n'est pas gratuit.** Chaque archive pèse au
    /// plus le seuil de rotation (5 Mio) ; les relire toutes à chaque
    /// `readAll()` — et `readAll()` est appelée après chaque tentative —
    /// grossirait sans fin avec l'âge de l'installation. Deux archives, plus
    /// le journal courant, couvrent largement l'historique dont l'écran et
    /// l'alerte ont besoin : la question posée est toujours « quand a eu lieu
    /// le dernier succès », jamais « qu'a fait ce Mac il y a trois ans ».
    private static func archives() -> [URL] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
        else { return [] }
        let matching = entries
            .filter { $0.lastPathComponent.hasPrefix("journal-") && $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return Array(matching.suffix(archiveReadLimit))
    }

    private static let archiveReadLimit = 2

    // MARK: - Rotation

    /// Au-delà de cette taille, le journal tourne. Des milliers de
    /// tentatives — largement plus qu'une vie de sauvegardes à la cadence
    /// par défaut de deux jours — tiennent bien en-deçà : ce n'est pas une
    /// taille qu'on espère atteindre en usage normal, c'est un filet contre
    /// un journal qui grossirait pour une raison qu'on n'a pas prévue.
    private static let rotationThreshold: Int64 = 5 * 1024 * 1024

    /// Fait tourner le journal s'il dépasse le seuil, **en renommant** —
    /// jamais en tronquant. Appelée avec le verrou d'écriture déjà tenu par
    /// `append(_:)`.
    ///
    /// Après le renommage, `fd` continue de désigner l'ancien fichier (les
    /// descripteurs suivent l'inœud, pas le chemin) : le prochain `append`
    /// rouvrira `path`, qui n'existe plus, et `O_CREAT` en créera un nouveau,
    /// vide. C'est exactement le roulement voulu, sans fenêtre où un
    /// écrivain concurrent verrait un fichier absent.
    private static func rotateIfNeeded(fd: Int32) throws {
        var status = stat()
        guard fstat(fd, &status) == 0 else {
            throw Failure.cannotRotate("fstat a échoué (errno \(errno))")
        }
        guard status.st_size > rotationThreshold else { return }

        let archived = directory.appending(
            path: "journal-\(Int(Date().timeIntervalSince1970)).jsonl",
            directoryHint: .notDirectory
        )
        do {
            try FileManager.default.moveItem(at: path, to: archived)
        } catch {
            // Ne jamais perdre l'historique par précipitation : si le
            // renommage échoue, le journal continue simplement de grossir
            // plutôt que d'être tronqué. La rotation retentera au prochain
            // ajout.
            throw Failure.cannotRotate(String(describing: error))
        }
    }
}
