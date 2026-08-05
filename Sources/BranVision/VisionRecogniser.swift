import CoreGraphics
import Foundation
import os
import Vision

/// Le moteur de reconnaissance de macOS.
///
/// Zéro téléchargement, zéro mémoire résidente, disponible dès la première
/// seconde après l'installation. Mesuré sur de vraies captures de cet écran :
///
/// ```
///                        prose FR   code Swift   terminal
///   erreur caractère       0,7 %      0,7 %*      4,5 %*
///   latence               349 ms     188 ms      256 ms
///                                 * après CharacterFixer
/// ```
///
/// **Les deux réglages qui font la différence, et qu'il est facile de rater.**
///
/// 1. `usesLanguageCorrection` doit être **coupé** sur du code. Allumé — c'est
///    le défaut, et c'est ce que fait Live Text — le correcteur « répare » les
///    symboles selon les règles du français. C'est exactement pour ça que
///    l'aperçu de capture d'écran de macOS déçoit sur du terminal.
/// 2. La langue doit être **l'anglais** sur du code, jamais le français, pour
///    la même raison. Forcer `fr-FR` sur un `ls -la` dégrade le résultat.
///
/// Ce qui reste hors de portée : les confusions de glyphes voisins en chasse
/// fixe. `ls` lu `1s`, `drwxr-xr-x` lu `drwxr-xI-x`, `50b0b89` lu `50bøb89`.
/// Aucun agrandissement d'image ne les corrige — 24 combinaisons de facteur,
/// netteté et hauteur minimale ont été essayées, le taux reste dans la même
/// bande. C'est une limite du modèle, pas un réglage.
public struct VisionRecogniser: OCREngine {

    public init() {}

    /// Journal du moteur lui-même.
    ///
    /// Séparé de `SnapshotLog`, qui vit dans l'application : ce module ne doit
    /// dépendre de rien. Visible avec
    /// `log stream --predicate 'subsystem == "com.opahventures.bran"'`.
    private static let logger = Logger(subsystem: "com.opahventures.bran", category: "vision")

    public let identifier = "vision"
    public let displayName = "macOS (Vision)"

    /// Toujours prêt : le moteur est dans le système, il n'y a rien à charger.
    public var isReady: Bool { get async { true } }

    public func prepare(progress: @Sendable @escaping (Double) -> Void) async throws {
        progress(1)
    }

    public func release() async {}

    public func recognise(
        _ image: RecognisableImage,
        language: OCRLanguage
    ) async throws -> [TextRegion] {
        guard CFGetTypeID(image.handle) == CGImage.typeID else {
            throw SnapshotFailure.recognitionFailed("image inattendue")
        }
        // swiftlint:disable:next force_cast
        let cgImage = image.handle as! CGImage

        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate

        switch language {
        case .automatic:
            request.automaticallyDetectsLanguage = true
            request.usesLanguageCorrection = true
        default:
            request.automaticallyDetectsLanguage = false
            request.usesLanguageCorrection = true
            if let identifiers = language.localeIdentifiers {
                request.recognitionLanguages = identifiers.map { Locale.Language(identifier: $0) }
            }
        }

        let observations = try await request.perform(on: cgImage)
        return Self.convert(observations, label: "prose")
    }

    /// La variante réglée pour du code.
    ///
    /// Séparée de `recognise` parce que les deux réglages ne sont pas un goût
    /// mais une mesure : sur la même image, le correcteur allumé transforme
    /// `awk '{print` en `awk 'fprint`.
    public func recogniseCode(_ image: RecognisableImage) async throws -> [TextRegion] {
        guard CFGetTypeID(image.handle) == CGImage.typeID else {
            throw SnapshotFailure.recognitionFailed("image inattendue")
        }
        // swiftlint:disable:next force_cast
        let cgImage = image.handle as! CGImage

        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.automaticallyDetectsLanguage = false
        request.recognitionLanguages = [Locale.Language(identifier: "en-US")]

        let observations = try await request.perform(on: cgImage)
        return Self.convert(observations, label: "code")
    }

    /// Transforme les observations en régions, **en disant ce qu'on a perdu**.
    ///
    /// Le décompte brut et le décompte final sont journalisés séparément parce
    /// qu'ils ne veulent pas dire la même chose : zéro observation signifie que
    /// le moteur n'a rien vu, alors que des observations sans candidat signifie
    /// qu'il a vu du texte mais n'a pas su le lire. Les confondre en un seul
    /// « 0 régions » a coûté une soirée de diagnostic.
    private static func convert(
        _ observations: [RecognizedTextObservation],
        label: String
    ) -> [TextRegion] {
        let regions = observations.compactMap { observation -> TextRegion? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let box = observation.boundingBox
            return TextRegion(
                x: box.origin.x,
                y: box.origin.y,
                width: box.width,
                height: box.height,
                text: candidate.string,
                confidence: Double(candidate.confidence)
            )
        }
        logger.debug(
            "\(label, privacy: .public) : \(observations.count, privacy: .public) observations → \(regions.count, privacy: .public) régions"
        )
        return regions
    }

    /// Les langues que ce Mac sait lire. Sert à n'offrir dans les réglages que
    /// ce qui marchera vraiment.
    public static var supportedLanguages: [String] {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        return request.supportedRecognitionLanguages.map(\.maximalIdentifier)
    }
}
