import Foundation

/// Un fait rapporté par un détecteur de fenêtres. Ne décide rien.
public struct MeetWindowSignal: Equatable, Sendable {
    /// Titre brut de la fenêtre, tel que rapporté par le système.
    public let windowTitle: String

    /// Code de réunion (`abc-defg-hij`) si extractible du titre.
    public let meetCode: String?

    /// Application propriétaire de la fenêtre, pour le diagnostic.
    public let owningApplication: String?

    public init(windowTitle: String, meetCode: String?, owningApplication: String? = nil) {
        self.windowTitle = windowTitle
        self.meetCode = meetCode
        self.owningApplication = owningApplication
    }
}
