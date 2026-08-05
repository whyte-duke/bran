import Foundation

/// Une dictée, telle qu'elle survit sur le disque.
///
/// **Tout champ ajouté après coup doit être optionnel.** Le `Decodable`
/// synthétisé par Swift ignore les valeurs par défaut : un champ non optionnel
/// ajouté à cette structure rendrait illisibles, d'un seul coup, toutes les
/// transcriptions déjà écrites. Cette leçon a déjà coûté un aller-retour sur
/// `RecordingMetadata.segmentCount` — on ne la réapprend pas.
public struct TranscriptEntry: Codable, Identifiable, Equatable, Sendable {

    public var id: UUID
    public var createdAt: Date
    public var duration: TimeInterval

    /// Le texte tel qu'il a été collé, dictionnaire de corrections appliqué.
    public var text: String

    /// Le texte brut du modèle, avant corrections. Conservé pour pouvoir
    /// réappliquer un dictionnaire enrichi sans relancer une transcription.
    public var rawText: String?

    public var language: String?
    public var confidence: Double?
    public var processingTime: TimeInterval?
    public var modelVersion: String?

    /// Nom du fichier audio dans le même dossier. `nil` une fois l'audio purgé
    /// par la politique de rétention — l'entrée, elle, reste pour toujours.
    public var audioFileName: String?

    /// Renseigné quand la transcription a échoué. L'entrée existe quand même,
    /// pour que l'audio reste réessayable.
    public var failure: String?

    public init(
        id: UUID = UUID(),
        createdAt: Date,
        duration: TimeInterval,
        text: String,
        rawText: String? = nil,
        language: String? = nil,
        confidence: Double? = nil,
        processingTime: TimeInterval? = nil,
        modelVersion: String? = nil,
        audioFileName: String? = nil,
        failure: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.duration = duration
        self.text = text
        self.rawText = rawText
        self.language = language
        self.confidence = confidence
        self.processingTime = processingTime
        self.modelVersion = modelVersion
        self.audioFileName = audioFileName
        self.failure = failure
    }

    /// L'audio a-t-il survécu à la purge ? C'est la seule condition pour
    /// pouvoir réessayer — d'où un bouton désactivé avec sa raison plutôt
    /// qu'un bouton qui échoue.
    public var canRetry: Bool { audioFileName != nil }

    public var isFailed: Bool { failure != nil }

    /// Ce qu'on affiche dans la liste quand le texte est vide ou en échec.
    public var previewText: String {
        if let failure, text.isEmpty { return failure }
        return text
    }

    public var durationDescription: String {
        let seconds = Int(duration.rounded())
        if seconds < 60 { return "\(seconds) s" }
        return "\(seconds / 60) min \(seconds % 60) s"
    }

    public var wordCount: Int {
        text.split(whereSeparator: \.isWhitespace).count
    }
}
