/// Le contrat de mise en page d'une transcription dans sa liste.
///
/// Une prévisualisation repliée doit rester bornée et ne pas installer le rendu
/// AppKit de sélection de texte, qui peut peindre hors de sa hauteur pendant une
/// animation SwiftUI. La carte ouverte, elle, montre et sélectionne tout.
public struct TranscriptCardPolicy: Sendable, Equatable {
    public let lineLimit: Int?
    public let allowsSelection: Bool
    public let fixesVerticalSize: Bool

    public init(isExpanded: Bool) {
        lineLimit = isExpanded ? nil : 3
        allowsSelection = isExpanded
        fixesVerticalSize = isExpanded
    }
}
