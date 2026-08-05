import Foundation

/// Transforme une suite de progressions **par fichier** en une seule barre
/// monotone.
///
/// FluidAudio télécharge le modèle en plusieurs morceaux et rapporte la
/// progression de chacun, de 0 à 1. Affichée telle quelle, la barre recule à
/// chaque nouveau fichier : l'utilisateur voit « 50 %, 100 %, 50 %, 100 %… » et
/// en conclut que ça patine.
///
/// Le nombre de fichiers n'est pas annoncé à l'avance. On l'estime, et surtout
/// on garantit la seule propriété qui compte pour une barre de progression :
/// **elle n'a pas le droit de reculer.**
public struct DownloadTally: Sendable {

    /// Estimation du nombre de morceaux. Se corrige toute seule si la réalité
    /// dépasse l'estimation, plutôt que de bloquer la barre à 100 %.
    private var expectedFiles: Double
    private var completedFiles: Double = 0
    private var lastFraction: Double = 0
    private var published: Double = 0

    public init(expectedFiles: Int = 6) {
        self.expectedFiles = Double(max(1, expectedFiles))
    }

    /// Enregistre la progression du fichier en cours et rend la valeur à
    /// afficher.
    public mutating func advance(to fraction: Double) -> Double {
        let clamped = min(max(fraction, 0), 1)

        // Un recul signifie qu'un nouveau fichier a commencé.
        if clamped < lastFraction {
            completedFiles += 1
            if completedFiles >= expectedFiles {
                // Plus de fichiers que prévu : on étire l'échelle au lieu de
                // rester coincé à 100 % pendant que ça télécharge encore.
                expectedFiles = completedFiles + 1
            }
        }
        lastFraction = clamped

        let overall = (completedFiles + clamped) / expectedFiles
        published = max(published, min(overall, 0.99))
        return published
    }

    /// Le téléchargement est fini : la barre a le droit d'atteindre 100 %.
    public mutating func finish() -> Double {
        published = 1
        return published
    }
}
