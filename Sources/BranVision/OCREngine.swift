import Foundation

/// Ce qu'un moteur de reconnaissance doit savoir faire.
///
/// L'interface tient en trois membres, et c'est délibéré : tant qu'un moteur
/// rend des `TextRegion`, tout le reste de bran — assemblage, substitutions,
/// historique, encoche — fonctionne sans le connaître.
///
/// **Pourquoi une interface alors qu'il n'y a qu'un moteur.** Parce que la
/// mesure a montré deux régimes nets sur les mêmes captures :
///
/// ```
///                        prose FR    code Swift    terminal
///   Vision (macOS)         0,7 %       0,7 %*       4,5 %*
///   téléchargement          0 Mo        0 Mo         0 Mo
///   mémoire                 0 Mo        0 Mo         0 Mo
///   latence               349 ms      188 ms       256 ms
///                                   * après table de substitutions
/// ```
///
/// Vision est excellent sur la prose et le code, et cale sur les sorties
/// tabulaires en chasse fixe — `drwxr-xr-x` lu `drwxr-xI-x`, `ls` lu `1s`. Le
/// jour où un modèle local fait mieux sur ce cas précis, il se branche ici sans
/// toucher au reste.
public protocol OCREngine: Sendable {

    /// Identifiant stable, écrit dans l'historique. Sans lui, comparer deux
    /// captures ne voudrait rien dire.
    var identifier: String { get }

    /// Nom affiché dans les réglages.
    var displayName: String { get }

    /// Le moteur peut-il travailler tout de suite ?
    ///
    /// C'est ce booléen qui décide si l'encoche montre une étape de chargement.
    /// Vision répond toujours `true` ; un modèle local répond `false` tant que
    /// ses poids ne sont pas en mémoire.
    var isReady: Bool { get async }

    /// Charge ce qu'il faut. Sans effet si c'est déjà fait.
    ///
    /// `progress` reçoit des valeurs entre 0 et 1 quand elles sont connues.
    func prepare(progress: @Sendable @escaping (Double) -> Void) async throws

    /// Lit le texte d'une image.
    ///
    /// Rend des régions brutes et non une chaîne : c'est `TextAssembler` qui
    /// décide comment les recoller, et il ne peut pas le faire sans la
    /// géométrie. Un moteur qui ne rendrait qu'une chaîne perdrait
    /// l'indentation et l'alignement des colonnes.
    func recognise(_ image: RecognisableImage, language: OCRLanguage) async throws -> [TextRegion]

    /// Libère ce qui peut l'être après un temps d'inactivité. Sans effet pour
    /// un moteur système.
    func release() async
}

/// Une image à lire, réduite à ce dont un moteur a besoin.
///
/// Enveloppe volontairement opaque : `BranVision` ne dépend ni de CoreGraphics
/// ni de Vision, ce qui garde l'assemblage et les substitutions testables sans
/// framework système. L'application y range un `CGImage`.
public struct RecognisableImage: @unchecked Sendable {

    public let handle: AnyObject
    public let pixelWidth: Int
    public let pixelHeight: Int

    public init(handle: AnyObject, pixelWidth: Int, pixelHeight: Int) {
        self.handle = handle
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

/// La langue de reconnaissance.
///
/// Les mêmes que pour la dictée, plus un cas `.automatic`. Attention au piège
/// mesuré : forcer le français sur du code **dégrade** le résultat, parce que
/// le correcteur linguistique « répare » les symboles. D'où `isCode`, qui
/// impose l'anglais et coupe la correction quel que soit le réglage.
public enum OCRLanguage: String, Codable, CaseIterable, Sendable, Equatable {
    case automatic
    case french
    case english
    case german
    case spanish
    case italian
    case portuguese

    public var label: String {
        switch self {
        case .automatic: "Détection automatique"
        case .french: "Français"
        case .english: "Anglais"
        case .german: "Allemand"
        case .spanish: "Espagnol"
        case .italian: "Italien"
        case .portuguese: "Portugais"
        }
    }

    /// Identifiants BCP-47 attendus par Vision. `nil` en détection automatique.
    public var localeIdentifiers: [String]? {
        switch self {
        case .automatic: nil
        case .french: ["fr-FR"]
        case .english: ["en-US"]
        case .german: ["de-DE"]
        case .spanish: ["es-ES"]
        case .italian: ["it-IT"]
        case .portuguese: ["pt-BR"]
        }
    }
}
