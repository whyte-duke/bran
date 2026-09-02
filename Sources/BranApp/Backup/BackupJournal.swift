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
        let fd = open(cPath, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fd >= 0 else { throw Failure.cannotOpen(errno: errno) }
        defer { close(fd) }

        // Bloquant, volontairement : contrairement au verrou de
        // simultanéité de `BackupHeadlessRun` (qui doit échouer tout de
        // suite plutôt qu'attendre 30 heures), un ajout au journal est une
        // écriture de quelques centaines d'octets — attendre le tour de
        // l'autre écrivain coûte, au pire, le temps de CE `write()`-là.
        guard flock(fd, LOCK_EX) == 0 else { throw Failure.cannotLock(errno: errno) }
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
    }

    /// Lit tout le journal. Ne lève jamais pour un fichier absent : un Mac
    /// qui n'a encore jamais tenté de sauvegarde n'a pas de journal, ce
    /// n'est pas une erreur.
    public static func readAll() -> ReadResult {
        guard let data = FileManager.default.contents(atPath: path.path(percentEncoded: false)),
              data.isEmpty == false
        else {
            return ReadResult(attempts: [], unreadableLineCount: 0, lastLineWasTruncated: false)
        }

        // Une dernière ligne sans `\n` final n'a jamais fini d'être écrite :
        // ce n'est ni une tentative complète, ni une tentative à moitié
        // racontée qu'il vaudrait la peine d'essayer de décoder. On l'écarte
        // avant même de tenter le parseur — pas en rattrapant son échec.
        let endsWithNewline = data.last == UInt8(ascii: "\n")
        var lines = String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)

        var lastLineWasTruncated = false
        if !endsWithNewline, !lines.isEmpty {
            lines.removeLast()
            lastLineWasTruncated = true
        }

        var attempts: [BackupAttempt] = []
        attempts.reserveCapacity(lines.count)
        var unreadableLineCount = 0
        for line in lines {
            do {
                attempts.append(try BackupJournalModel.decode(line: line))
            } catch {
                // Une ligne interne (pas la dernière) qui refuse de se
                // décoder est un autre visage de la même panne : deux
                // écritures dont les `write()` respectifs se sont malgré
                // tout suivis sans séparateur — voir l'en-tête. On la
                // compte, on ne s'y arrête pas.
                unreadableLineCount += 1
            }
        }
        return ReadResult(
            attempts: attempts,
            unreadableLineCount: unreadableLineCount,
            lastLineWasTruncated: lastLineWasTruncated
        )
    }

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
