import Foundation
import os

/// Le journal de la capture de texte.
///
/// Écrit parce qu'une capture qui rend du vide peut échouer à six endroits — le
/// viseur, l'écriture du fichier temporaire, le décodage, le moteur, le
/// regroupement, le nettoyage — et qu'aucun d'eux ne se voit depuis l'interface.
/// Deviner lequel a coûté une soirée ; une ligne par étape l'aurait donné en
/// trente secondes.
///
/// Deux sorties, parce qu'elles servent à deux moments :
///
/// - **`os.Logger`** pour regarder en direct pendant qu'on appuie sur le
///   raccourci :
///   ```
///   log stream --predicate 'subsystem == "com.opahventures.bran"' --level debug
///   ```
/// - **un fichier**, `Captures/journal.txt`, pour lire après coup ce qui s'est
///   passé quand on n'était pas devant.
enum SnapshotLog {

    private static let logger = Logger(subsystem: "com.opahventures.bran", category: "snapshot")

    /// Là où le journal s'écrit. Fixé au démarrage par `SnapshotStore`, pour ne
    /// pas dépendre du dossier de destination à chaque ligne.
    nonisolated(unsafe) static var folder: URL?

    /// Nombre de lignes conservées. Un journal qui grossit sans fin devient un
    /// problème à son tour ; deux cents lignes couvrent largement la dernière
    /// séance de mise au point.
    private static let maximumLines = 200

    static func record(_ message: String) {
        logger.debug("\(message, privacy: .public)")
        append(message)
    }

    static func record(_ message: String, error: any Error) {
        let full = "\(message) — \(error.localizedDescription)"
        logger.error("\(full, privacy: .public)")
        append("✗ \(full)")
    }

    private static func append(_ message: String) {
        guard let folder else { return }
        let line = "\(Self.stamp()) \(message)\n"
        let url = folder.appending(path: "journal.txt")

        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

            var existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            existing += line

            // Rognage par la fin : ce qui vient de se passer compte plus que ce
            // qui s'est passé avant-hier.
            let lines = existing.split(separator: "\n", omittingEmptySubsequences: false)
            if lines.count > maximumLines {
                existing = lines.suffix(maximumLines).joined(separator: "\n")
            }

            try existing.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            // Un journal qui n'arrive pas à s'écrire ne doit surtout pas casser
            // ce qu'il observe.
            logger.error("journal inaccessible : \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: .now)
    }
}
