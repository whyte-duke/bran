import BranCore
import BranWindows
import CoreGraphics
import Foundation

/// Sonde de détection. Ne décide rien, n'enregistre rien : elle mesure.
///
/// Objectif : remplacer les formats de titre *supposés* de `MeetTitleMatcher`
/// par des formats *observés*, et quantifier la faille connue — le titre d'une
/// fenêtre Chrome est celui de l'onglet actif, donc changer d'onglet fait
/// disparaître le signal Meet alors que la réunion continue.
struct TitlesProbe {
    let interval: Duration

    private static let browserBundleIdentifiers: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.apple.Safari",
        "com.microsoft.edgemac",
        "company.thebrowser.Browser",
        "org.mozilla.firefox",
        "com.brave.Browser",
    ]

    func run() async throws {
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            throw ProbeError.screenRecordingDenied
        }

        let logURL = try makeLogURL()
        let log = try LogFile(url: logURL)

        print("→ sonde démarrée, tic toutes les \(interval)")
        print("→ journal : \(logURL.path)")
        print("→ Ctrl-C pour arrêter. Pendant une réunion : changez d'onglet, ")
        print("  passez en plein écran, ouvrez une seconde fenêtre Meet.\n")

        var lastVerdict: Bool?

        while true {
            let windows = WindowList.onScreen()
            let signals = windows.compactMap {
                MeetTitleMatcher.signal(from: $0.title, owningApplication: $0.ownerName)
            }
            let isMeeting = signals.isEmpty == false

            // Toutes les fenêtres de navigateur sont journalisées, même non
            // matchées : c'est le corpus qui servira à corriger le matcher.
            for window in windows where Self.browserBundleIdentifiers.contains(window.bundleIdentifier ?? "") {
                let verdict = MeetTitleMatcher.isMeeting(window.title) ? "MEET" : "----"
                log.append("\(verdict)  [\(window.ownerName ?? "?")] \(window.title)")
            }

            if lastVerdict != isMeeting {
                let line = isMeeting
                    ? "▶︎ TRANSITION → réunion détectée (\(signals.count) fenêtre(s), code=\(signals.first?.meetCode ?? "aucun"))"
                    : "■ TRANSITION → plus aucun signal Meet"
                print(line)
                log.append(line)
                lastVerdict = isMeeting
            }

            try await Task.sleep(for: interval)
        }
    }

    private func makeLogURL() throws -> URL {
        try FileStamp.storageRoot().appending(path: "probe-\(FileStamp.now).log")
    }
}

enum ProbeError: Error, CustomStringConvertible {
    case screenRecordingDenied

    var description: String {
        switch self {
        case .screenRecordingDenied:
            """
            Autorisation « Enregistrement de l'écran » absente.
            Sans elle, kCGWindowName n'est jamais exposé et tous les titres sont vides.
            Réglages Système → Confidentialité et sécurité → Enregistrement de l'écran → activer Terminal,
            puis relancer le Terminal (l'autorisation n'est prise en compte qu'au redémarrage du processus).
            """
        }
    }
}

/// Écriture append-only, avec `Mutex` plutôt qu'un `FileHandle` partagé sans
/// protection — la sonde est mono-tâche aujourd'hui, mais le type est déjà sûr.
final class LogFile: Sendable {
    private let handle: FileHandle

    init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
    }

    func append(_ message: String) {
        let stamp = Date.now.formatted(date: .omitted, time: .standard)
        try? handle.write(contentsOf: Data("\(stamp)  \(message)\n".utf8))
    }
}
