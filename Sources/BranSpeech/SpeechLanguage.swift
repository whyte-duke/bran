import Foundation

/// La langue imposée au modèle.
///
/// Parakeet v3 détecte la langue tout seul parmi vingt-cinq. C'est pratique, et
/// c'est exactement la source du défaut constaté : sur une phrase courte, ou sur
/// une phrase française truffée d'anglais métier, la détection bascule et le
/// modèle rend un texte à moitié traduit.
///
/// FluidAudio expose un indice de langue (« script-aware token filtering »,
/// v3 uniquement) : les candidats dont le script ne correspond pas sont écartés
/// au décodage. Imposer le français règle le problème à la racine, sans
/// post-traitement.
///
/// `automatic` reste disponible pour ceux qui alternent vraiment de langue.
public enum SpeechLanguage: String, Codable, CaseIterable, Sendable, Identifiable {
    case automatic
    case french
    case english
    case spanish
    case german
    case italian
    case portuguese
    case dutch

    public var id: String { rawValue }

    /// Le code ISO attendu par FluidAudio, ou `nil` pour laisser détecter.
    public var code: String? {
        switch self {
        case .automatic: nil
        case .french: "fr"
        case .english: "en"
        case .spanish: "es"
        case .german: "de"
        case .italian: "it"
        case .portuguese: "pt"
        case .dutch: "nl"
        }
    }

    public var label: String {
        switch self {
        case .automatic: "Détection automatique"
        case .french: "Français"
        case .english: "Anglais"
        case .spanish: "Espagnol"
        case .german: "Allemand"
        case .italian: "Italien"
        case .portuguese: "Portugais"
        case .dutch: "Néerlandais"
        }
    }

    /// Pourquoi on conseille de choisir plutôt que de laisser détecter.
    public static let guidance = """
    Parakeet détecte la langue tout seul, mais sur une phrase courte ou truffée \
    d'anglais métier il se trompe et rend un texte à moitié traduit. Imposer la \
    langue supprime le problème.
    """
}
