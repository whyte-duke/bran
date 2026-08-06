import AppKit
import BranVision
import CoreGraphics
import Foundation

/// Choisir une zone de l'écran.
protocol RegionCapturer: Sendable {
    /// Rend `nil` quand l'utilisateur a annulé. L'annulation n'est pas une
    /// erreur : c'est le geste le plus fréquent après la capture elle-même.
    func selectRegion() async throws -> CGImage?

    /// Capture un rectangle imposé, sans viseur. Uniquement pour le diagnostic.
    func captureFixedRegion(_ rect: String) async throws -> CGImage?
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
        try await capture(interactive: true)
    }

    /// La même chaîne, mais sur un rectangle imposé et sans viseur.
    ///
    /// Sert au diagnostic : elle rejoue exactement ce que fait une vraie
    /// capture — même processus, mêmes drapeaux, même décodage — sans demander
    /// à l'utilisateur de tracer quoi que ce soit. C'est le seul moyen de
    /// comparer « ce que l'application fait » à « ce que la ligne de commande
    /// fait » sur un pied d'égalité.
    func captureFixedRegion(_ rect: String) async throws -> CGImage? {
        try await capture(interactive: false, rect: rect)
    }

    private func capture(interactive: Bool, rect: String = "0,0,10,10") async throws -> CGImage? {
        let destination = scratch
        defer { try? FileManager.default.removeItem(at: destination) }

        let arguments = interactive
            ? ["-i", "-x", "-o", "-r", "-t", "png", destination.path]
            : ["-x", "-r", "-R", rect, "-t", "png", destination.path]
        FeatureLog.record("viseur → screencapture \(arguments.joined(separator: " "))")
        let status = try await run(arguments: arguments)

        let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int) ?? nil
        FeatureLog.record("viseur ← code=\(status) fichier=\(size.map { "\($0) octets" } ?? "absent")")

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
            FeatureLog.record("✗ le PNG écrit par screencapture est indécodable")
            throw SnapshotFailure.selectionFailed("image illisible")
        }

        FeatureLog.record(
            "image \(image.width)×\(image.height) bpc=\(image.bitsPerComponent) "
            + "bpp=\(image.bitsPerPixel) alpha=\(image.alphaInfo.rawValue) "
            + "espace=\(image.colorSpace?.name.map(String.init(describing:)) ?? "inconnu")"
        )

        // Une sélection d'un pixel arrive quand on clique sans faire glisser.
        // La traiter comme une capture donnerait une entrée vide dans
        // l'historique et une encoche qui annonce « rien lu » — alors que
        // l'utilisateur a simplement raté son geste.
        guard image.width > 4, image.height > 4 else {
            FeatureLog.record("sélection ignorée : \(image.width)×\(image.height) px, trop petite")
            return nil
        }

        return Self.decoded(image) ?? image
    }

    /// Redessine l'image dans un bitmap que **nous** possédons.
    ///
    /// **C'est le correctif du bug le plus coûteux de cette fonctionnalité :**
    /// la reconnaissance rendait zéro région dans l'application alors que le
    /// même fichier, lu par un outil en ligne de commande, donnait 301
    /// caractères. Deux causes se cumulaient, et cette seule opération les
    /// supprime toutes les deux.
    ///
    /// **1. Le fichier disparaissait sous l'image.** `CGImageSourceCreateWithURL`
    /// rend un `CGImage` *paresseux* : les pixels ne sont lus qu'au moment où on
    /// les demande. Le `defer` effaçait le fichier temporaire au retour de la
    /// fonction, donc avant que le moteur ne les demande. Les dimensions, elles,
    /// venaient des métadonnées déjà lues — d'où une image « valide » de
    /// 1800×240 sans un pixel derrière.
    ///
    /// **2. L'espace colorimétrique.** `screencapture` écrit en Display P3.
    /// L'image fabriquée en mémoire par l'autotest, qui elle fonctionnait, était
    /// en sRGB. Redessiner ramène tout en sRGB.
    ///
    /// Le diagnostic tenait à une ligne de journal : au démarrage, l'autotest
    /// sur une image en mémoire donnait 1 région ; quarante millisecondes plus
    /// tard, la même reconnaissance sur une capture donnait 0. Même processus,
    /// même code, deux images.
    private static func decoded(_ image: CGImage) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        ) else {
            FeatureLog.record("✗ impossible de créer le contexte de décodage")
            return nil
        }

        // Le fond blanc évite qu'une capture avec transparence — une fenêtre aux
        // coins arrondis, un menu translucide — se retrouve sur du noir, où le
        // texte sombre devient illisible.
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))

        guard let decoded = context.makeImage() else {
            FeatureLog.record("✗ le décodage n'a rien rendu")
            return nil
        }
        FeatureLog.record("image décodée en sRGB, pixels détenus par bran")
        return decoded
    }

    private func run(arguments: [String]) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(filePath: "/usr/sbin/screencapture")
            process.arguments = arguments
            // `Pipe()` et non `FileHandle.nullDevice` : ce dernier est un objet
            // **partagé** par tout le processus, et `Process` peut refermer le
            // descripteur qu'on lui confie. Fermer un descripteur partagé libère
            // son numéro, que le prochain fichier ouvert récupère — et à partir
            // de là n'importe quelle lecture du processus peut atterrir au
            // mauvais endroit, sans la moindre erreur.
            process.standardOutput = Pipe()
            process.standardError = Pipe()

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
