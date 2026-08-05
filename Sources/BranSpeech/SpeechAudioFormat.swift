import Foundation

/// Le format d'entrée de Parakeet.
///
/// C'est la seule raison pour laquelle « 16 kHz mono » apparaît à deux endroits
/// du projet : la dictée capture en direct depuis `AVAudioEngine`, l'export CRM
/// relit un `.mp4` avec `AVAssetReader`. Même cible, deux mécanismes qui n'ont
/// rien à partager d'autre. Mutualiser les tuyaux produirait un protocole à deux
/// implémentations disjointes ; mutualiser la constante suffit.
public enum SpeechAudioFormat {
    public static let sampleRate: Double = 16_000
    public static let channelCount: UInt32 = 1

    /// Au-delà, on arrête proprement et on transcrit quand même.
    ///
    /// Sans plafond, un raccourci resté enfoncé — ou un basculement oublié —
    /// enregistre jusqu'à saturer le disque. Dix minutes, c'est déjà deux fois
    /// plus long que la plus longue dictée plausible.
    public static let maximumDuration: TimeInterval = 600

    /// En deçà, on considère qu'il n'y a rien eu à dire.
    ///
    /// Un appui accidenté ne doit pas coller le fruit de l'imagination du
    /// modèle dans le document de quelqu'un.
    public static let minimumDuration: TimeInterval = 0.35

    /// Octets par seconde en PCM 16 bits mono : 32 ko/s, soit ~1,9 Mo la minute.
    /// Une semaine de dictée intense tient largement sous le gigaoctet.
    public static let bytesPerSecond = 32_000
}
