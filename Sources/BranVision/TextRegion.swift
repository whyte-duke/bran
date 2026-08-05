import Foundation

/// Un morceau de texte reconnu, avec sa place sur l'image.
///
/// Volontairement détaché de Vision : ce type ne connaît ni `CGImage` ni
/// `RecognizedTextObservation`. C'est ce qui permet de tester l'assemblage —
/// la partie où se jouent presque toutes les erreurs — sans écran, sans image
/// et sans autorisation, en quelques microsecondes.
///
/// Coordonnées **normalisées**, origine en bas à gauche, comme Vision les rend.
public struct TextRegion: Equatable, Sendable {

    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var text: String
    /// 0 à 1. Sert à écarter les régions douteuses et à afficher un indice de
    /// fiabilité dans l'historique.
    public var confidence: Double

    public init(
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        text: String,
        confidence: Double = 1
    ) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.text = text
        self.confidence = confidence
    }

    /// Le centre vertical. C'est lui qui décide si deux morceaux sont sur la
    /// même ligne — pas `y`, qui est le bas de la boîte et qui bouge dès qu'un
    /// morceau contient une lettre à jambage (« p », « g »).
    var midY: Double { y + height / 2 }

    var maxX: Double { x + width }
}

/// Comment recoller les morceaux.
///
/// La distinction n'est pas cosmétique, elle change l'algorithme :
///
/// ```
/// PROSE                              CHASSE FIXE
/// ┌──────────┐ ┌─────────┐           ┌────────┐  ┌────┐   ┌──────────┐
/// │ Bonjour, │ │ ça va ? │           │ -rw-r… │  │ 12 │   │ fichier  │
/// └──────────┘ └─────────┘           └────────┘  └────┘   └──────────┘
///        ↓                                       ↓
/// « Bonjour, ça va ? »               « -rw-r…    12    fichier »
///   un espace suffit                   les écarts portent du sens
/// ```
///
/// En prose, l'écart horizontal ne veut rien dire : c'est de la justification.
/// En chasse fixe, l'écart **est** l'information — c'est l'alignement des
/// colonnes de `ls -la` et l'indentation du code.
public enum LayoutMode: String, Codable, CaseIterable, Sendable, Equatable {
    case prose
    case monospaced

    public var label: String {
        switch self {
        case .prose: "Texte"
        case .monospaced: "Code et terminal"
        }
    }
}
