import BranCore
import BranWindows

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
        WindowList.onScreen().compactMap { window -> MeetWindowSignal? in
            guard isBrowser(window) else { return nil }
            return MeetTitleMatcher.signal(
                from: window.title,
                owningApplication: window.ownerName
            )
        }
    }

    /// Restreindre aux navigateurs élimine d'un coup toute une classe de faux
    /// positifs — un canal Slack nommé « meeting », un document ouvert dont le
    /// titre contient le code d'une réunion.
    private func isBrowser(_ window: ListedWindow) -> Bool {
        guard let bundleID = window.bundleIdentifier else { return false }
        return Self.browsers.contains(bundleID)
    }
}
