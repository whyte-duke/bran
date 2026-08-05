import AppKit
import BranVision
import CoreGraphics
import Foundation

/// Choisir une zone de l'écran.
protocol RegionCapturer: Sendable {
    /// Rend `nil` quand l'utilisateur a annulé. L'annulation n'est pas une
    /// erreur : c'est le geste le plus fréquent après la capture elle-même.
    func selectRegion() async throws -> CGImage?
}

/// Le viseur de macOS, appelé tel quel.
///
/// **Pourquoi lancer un processus plutôt que dessiner notre propre viseur.**
/// Parce que le viseur système, c'est vingt ans de réflexes acquis :
///
/// ```
///   ✓ loupe au pixel + cotes en direct
///   ✓ barre d'espace pour déplacer la sélection en cours
///   ✓ barre d'espace pour basculer en mode fenêtre, avec surbrillance
///   ✓ Échap pour annuler
///   ✓ multi-écran, échelles mixtes, sélection à cheval
/// ```
///
/// Réécrire tout ça prendrait une semaine et le moindre détail manquant se
/// remarquerait immédiatement — une loupe absente, un Échap qui réagit
/// autrement. L'objectif était « comme si macOS avait livré la fonction » ;
/// le chemin le plus court est de laisser macOS la livrer.
///
/// Les drapeaux comptent :
/// - `-i` sélection interactive ;
/// - `-x` pas de bruit d'obturateur — on capture pour lire, pas pour archiver ;
/// - `-o` pas d'ombre portée quand on choisit une fenêtre, sinon la marge grise
///   entre dans l'image et fausse la marge gauche calculée par `TextAssembler` ;
/// - `-r` pas de métadonnées de résolution, inutiles ici.
struct SystemRegionCapturer: RegionCapturer {

    /// Là où l'image atterrit avant d'être lue. Effacée aussitôt après.
    private var scratch: URL {
        FileManager.default.temporaryDirectory
            .appending(path: "bran-capture-\(UUID().uuidString).png")
    }

    func selectRegion() async throws -> CGImage? {
        let destination = scratch
        defer { try? FileManager.default.removeItem(at: destination) }

        let status = try await run(arguments: ["-i", "-x", "-o", "-r", "-t", "png", destination.path])

        // Deux façons d'annuler, et il faut accepter les deux : selon la
        // version de macOS, `screencapture` sort avec 0 ou 1 quand on presse
        // Échap. Le seul signal fiable est l'absence de fichier.
        guard FileManager.default.fileExists(atPath: destination.path) else {
            guard status == 0 || status == 1 else {
                throw SnapshotFailure.selectionFailed("screencapture a terminé avec le code \(status)")
            }
            return nil
        }

        guard let source = CGImageSourceCreateWithURL(destination as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw SnapshotFailure.selectionFailed("image illisible")
        }

        // Une sélection d'un pixel arrive quand on clique sans faire glisser.
        // La traiter comme une capture donnerait une entrée vide dans
        // l'historique et une encoche qui annonce « rien lu » — alors que
        // l'utilisateur a simplement raté son geste.
        guard image.width > 4, image.height > 4 else { return nil }

        return image
    }

    private func run(arguments: [String]) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(filePath: "/usr/sbin/screencapture")
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice

            // `terminationHandler` plutôt que `waitUntilExit` : celui-ci
            // bloquerait le fil appelant pendant tout le temps où l'utilisateur
            // trace son rectangle, ce qui peut durer.
            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus)
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: SnapshotFailure.selectionFailed(error.localizedDescription))
            }
        }
    }
}
