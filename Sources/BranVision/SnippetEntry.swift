import Foundation

/// Une capture de texte, telle qu'elle survit sur le disque.
///
/// **Tout champ ajouté après coup doit être optionnel.** Le `Decodable`
/// synthétisé ignore les valeurs par défaut : un champ non optionnel ajouté ici
/// rendrait illisibles, d'un coup, toutes les captures déjà écrites. La leçon a
/// été payée deux fois — `RecordingMetadata.segmentCount`, puis
/// `TranscriptEntry`. On ne la réapprend pas une troisième.
///
/// ```
/// ~/…/bran/Captures/
///   2026-08-05T20-47-11-<uuid>.json   ← le texte, gardé pour toujours
///   2026-08-05T20-47-11-<uuid>.png    ← l'image, purgée après 7 jours
/// ```
public struct SnippetEntry: Codable, Identifiable, Equatable, Sendable {

    public var id: UUID
    public var createdAt: Date

    /// Le texte livré au presse-papiers, corrections appliquées.
    public var text: String

    /// Le texte brut du moteur, avant la table de substitutions. Conservé pour
    /// pouvoir rejouer une table enrichie sans relancer la reconnaissance, et
    /// pour pouvoir comparer deux moteurs sur la même image.
    public var rawText: String?

    /// Prose ou chasse fixe. Détermine si les substitutions ont été appliquées,
    /// et permet de relire la même image dans l'autre mode.
    public var layout: LayoutMode?

    /// Identifiant du moteur — « vision », plus tard le nom d'un modèle local.
    /// Sans lui, comparer deux captures ne voudrait rien dire.
    public var engine: String?

    public var confidence: Double?
    public var processingTime: TimeInterval?

    /// Nombre de caractères réparés par `CharacterFixer`. Affiché dans le
    /// détail : savoir que huit corrections ont eu lieu invite à relire avant
    /// de coller dans un terminal.
    public var repairCount: Int?

    /// L'application au premier plan au moment de la capture. C'est le meilleur
    /// critère de recherche trois semaines plus tard : on se souvient d'où
    /// venait un bout de texte bien avant de se souvenir de ce qu'il disait.
    public var sourceApp: String?

    /// Nom du fichier image dans le même dossier. `nil` une fois l'image purgée
    /// — l'entrée, elle, reste.
    public var imageFileName: String?

    public var pixelWidth: Int?
    public var pixelHeight: Int?

    /// Renseigné quand la reconnaissance a échoué. L'entrée existe quand même,
    /// pour que l'image reste réessayable.
    public var failure: String?

    public init(
        id: UUID = UUID(),
        createdAt: Date,
        text: String,
        rawText: String? = nil,
        layout: LayoutMode? = nil,
        engine: String? = nil,
        confidence: Double? = nil,
        processingTime: TimeInterval? = nil,
        repairCount: Int? = nil,
        sourceApp: String? = nil,
        imageFileName: String? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        failure: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.text = text
        self.rawText = rawText
        self.layout = layout
        self.engine = engine
        self.confidence = confidence
        self.processingTime = processingTime
        self.repairCount = repairCount
        self.sourceApp = sourceApp
        self.imageFileName = imageFileName
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.failure = failure
    }

    /// L'image a-t-elle survécu à la purge ? C'est la seule condition pour
    /// relancer une lecture — d'où un bouton désactivé avec sa raison plutôt
    /// qu'un bouton qui échoue.
    public var canRetry: Bool { imageFileName != nil }

    public var isFailed: Bool { failure != nil }

    public var previewText: String {
        if let failure, text.isEmpty { return failure }
        return text
    }

    public var wordCount: Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    public var lineCount: Int {
        guard text.isEmpty == false else { return 0 }
        return text.split(whereSeparator: \.isNewline).count
    }

    public var characterCount: Int { text.count }

    /// Résumé compact pour la liste : « 12 lignes · 340 caractères ».
    public var sizeDescription: String {
        guard lineCount > 1 else { return "\(characterCount) caractères" }
        return "\(lineCount) lignes · \(characterCount) caractères"
    }
}
