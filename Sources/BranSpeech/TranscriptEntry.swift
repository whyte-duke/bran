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

    /// **Le plafond d'une durée de dictée : 24 heures.**
    ///
    /// Ce n'est pas une borne de vraisemblance — la plus longue dictée mesurée
    /// tient en quelques minutes —, c'est une borne de sûreté, et elle est
    /// volontairement mille fois trop haute pour ne jamais refuser une dictée
    /// réelle. Ce qu'elle refuse, c'est ce qu'aucun enregistrement ne produit :
    /// un nombre fabriqué.
    public static let durationCeiling: TimeInterval = 24 * 60 * 60

    /// Cette durée peut-elle avoir été mesurée ?
    ///
    /// Un `Double` de JSON accepte `1e308`, `-1`, `nan` et `inf` ; aucun ne
    /// sort d'un enregistrement.
    static func isPlausible(_ duration: TimeInterval) -> Bool {
        duration.isFinite && duration >= 0 && duration <= durationCeiling
    }

    /// **Refuse au décodage ce qui ferait tomber l'affichage.**
    ///
    /// `duration` est un `Double` que rien ne validait, et `durationDescription`
    /// le convertissait avec `Int(duration.rounded())`. Mesuré : le sidecar
    /// `{"id":…,"createdAt":0,"duration":1e308,"text":"x"}` se décode sans un
    /// mot, puis la conversion tue le processus — « Double value cannot be
    /// converted to Int because the result would be greater than Int.max ». La
    /// ligne étant dessinée à chaque affichage de la liste, la panne n'était pas
    /// une entrée abîmée : c'était le panneau de dictée devenu impossible à
    /// ouvrir, à chaque lancement, jusqu'à ce que le fichier soit trouvé à la
    /// main.
    ///
    /// **Refuser plutôt que corriger.** Ramener la durée à zéro garderait le
    /// texte, mais écrirait dans la bibliothèque un chiffre que personne n'a
    /// mesuré. Un sidecar qui annonce 1e308 secondes n'est pas une transcription
    /// abîmée par un disque — un octet retourné casse le JSON bien avant — c'est
    /// un fichier que bran n'a pas écrit. Le refus le range où va déjà tout
    /// sidecar illisible : compté, dit, et son audio épargné, donc réessayable.
    ///
    /// Le reste du décodage est celui que Swift synthétisait, à la lettre :
    /// `decodeIfPresent` pour chaque champ optionnel, sans quoi une
    /// transcription écrite avant l'ajout d'un champ cesserait de se lire — la
    /// panne que la documentation de ce type ouvre.
    public init(from decoder: any Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        let duration = try box.decode(TimeInterval.self, forKey: .duration)
        guard Self.isPlausible(duration) else {
            throw DecodingError.dataCorruptedError(
                forKey: .duration, in: box,
                debugDescription: "durée impossible (\(duration))"
            )
        }

        self.id = try box.decode(UUID.self, forKey: .id)
        self.createdAt = try box.decode(Date.self, forKey: .createdAt)
        self.duration = duration
        self.text = try box.decode(String.self, forKey: .text)
        self.rawText = try box.decodeIfPresent(String.self, forKey: .rawText)
        self.language = try box.decodeIfPresent(String.self, forKey: .language)
        self.confidence = try box.decodeIfPresent(Double.self, forKey: .confidence)
        self.processingTime = try box.decodeIfPresent(TimeInterval.self, forKey: .processingTime)
        self.modelVersion = try box.decodeIfPresent(String.self, forKey: .modelVersion)
        self.audioFileName = try box.decodeIfPresent(String.self, forKey: .audioFileName)
        self.failure = try box.decodeIfPresent(String.self, forKey: .failure)
    }

    /// **La conversion est gardée ici aussi, et ce n'est pas une ceinture de
    /// plus.** Le décodage protège ce qui vient du disque ; `duration` reste un
    /// `var` qu'un calcul en mémoire peut remplir — une division par une durée
    /// nulle rend `inf` sans prévenir. Un affichage ne doit jamais être ce qui
    /// arrête bran.
    public var durationDescription: String {
        guard Self.isPlausible(duration) else { return "durée inconnue" }
        let seconds = Int(duration.rounded())
        if seconds < 60 { return "\(seconds) s" }
        return "\(seconds / 60) min \(seconds % 60) s"
    }

    public var wordCount: Int {
        text.split(whereSeparator: \.isWhitespace).count
    }
}
