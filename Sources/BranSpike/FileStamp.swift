import Foundation

/// Horodatage pour noms de fichiers : triable, lisible, et dans le fuseau de
/// l'utilisateur. `.iso8601` seul produit de l'UTC, ce qui donne un nom décalé
/// de plusieurs heures par rapport à l'heure de la réunion.
enum FileStamp {
    static var now: String {
        Date.now.formatted(
            Date.ISO8601FormatStyle(timeZone: .current)
                .year().month().day()
                .dateTimeSeparator(.standard)
                .time(includingFractionalSeconds: false)
        )
        .replacing(":", with: "-")
    }

    /// `~/Movies/bran`, créé si nécessaire.
    static func storageRoot() throws -> URL {
        let root = URL.moviesDirectory.appending(path: "bran", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
