import AppKit
import BranCore
import CoreGraphics

/// Énumère les fenêtres à l'écran et filtre celles qui ressemblent à une
/// réunion Meet. **Rapporte, ne décide jamais.**
///
/// `kCGWindowName` n'est renseigné qu'avec l'autorisation Enregistrement de
/// l'écran — déjà obligatoire pour capturer. C'est ce qui permet d'éviter la
/// permission Automation et un code spécifique par navigateur.
struct WindowTitleDetector: Sendable {
    private static let browsers: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.apple.Safari",
        "com.microsoft.edgemac",
        "company.thebrowser.Browser",
        "org.mozilla.firefox",
        "com.brave.Browser",
    ]

    func currentSignals() -> [MeetWindowSignal] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let entries = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        return entries.compactMap { entry -> MeetWindowSignal? in
            guard let title = entry[kCGWindowName as String] as? String, title.isEmpty == false else {
                return nil
            }
            guard isBrowser(entry) else { return nil }

            let owner = entry[kCGWindowOwnerName as String] as? String
            return MeetTitleMatcher.signal(from: title, owningApplication: owner)
        }
    }

    /// Restreindre aux navigateurs élimine d'un coup toute une classe de faux
    /// positifs — un canal Slack nommé « meeting », un document ouvert dont le
    /// titre contient le code d'une réunion.
    private func isBrowser(_ entry: [String: Any]) -> Bool {
        guard let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
              let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        else { return false }

        return Self.browsers.contains(bundleID)
    }
}
