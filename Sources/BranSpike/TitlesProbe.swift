import AppKit
import BranCore
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
            let windows = currentWindows()
            let signals = windows.compactMap {
                MeetTitleMatcher.signal(from: $0.title, owningApplication: $0.owner)
            }
            let isMeeting = signals.isEmpty == false

            // Toutes les fenêtres de navigateur sont journalisées, même non
            // matchées : c'est le corpus qui servira à corriger le matcher.
            for window in windows where Self.browserBundleIdentifiers.contains(window.bundleIdentifier ?? "") {
                let verdict = MeetTitleMatcher.isMeeting(window.title) ? "MEET" : "----"
                log.append("\(verdict)  [\(window.owner)] \(window.title)")
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

    private struct WindowInfo {
        let title: String
        let owner: String
        let bundleIdentifier: String?
    }

    private func currentWindows() -> [WindowInfo] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        return raw.compactMap { entry -> WindowInfo? in
            guard let title = entry[kCGWindowName as String] as? String, title.isEmpty == false else {
                return nil
            }
            let owner = entry[kCGWindowOwnerName as String] as? String ?? "?"
            let pid = entry[kCGWindowOwnerPID as String] as? pid_t
            let bundleIdentifier = pid.flatMap { pid in
                NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
            }
            return WindowInfo(title: title, owner: owner, bundleIdentifier: bundleIdentifier)
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
