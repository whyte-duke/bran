import Foundation

/// Le seul levier de poids de fichier dont on dispose.
///
/// `SCRecordingOutputConfiguration` n'expose que `outputURL`, `videoCodecType`
/// et `outputFileType` — aucun réglage de débit. Le nombre de pixels est donc
/// la seule variable, et l'encodeur alloue les bits en conséquence.
///
/// Mesuré sur une vraie réunion Meet (image animée, vignettes des participants) :
/// Retina natif en HEVC coûte ~6 Go/h. Sur un écran figé, le même réglage
/// tombe à 0,2 Go/h — ScreenCaptureKit ne livre une image que lorsque l'écran
/// change, donc le coût réel dépend entièrement du contenu.
public enum QualityPreset: String, CaseIterable, Identifiable, Sendable {
    case retina
    case elevee
    case standard

    public var id: String { rawValue }

    public var scale: Double {
        switch self {
        case .retina: 2
        case .elevee: 1.5
        case .standard: 1
        }
    }

    public var label: String {
        switch self {
        case .retina: "Retina — texte parfaitement net"
        case .elevee: "Élevée — bon compromis"
        case .standard: "Standard — fichiers légers"
        }
    }

    /// Ordre de grandeur observé sur une réunion animée, pas une garantie.
    public var estimatedRate: String {
        switch self {
        case .retina: "~6 Go/h"
        case .elevee: "~3 Go/h"
        case .standard: "~1,5 Go/h"
        }
    }
}
