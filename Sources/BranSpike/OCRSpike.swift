import AppKit
import BranVision
import CoreGraphics
import Foundation

/// Rejoue **exactement** le tuyau de lecture de l'application sur un fichier,
/// en imprimant chaque étape.
///
/// Écrit pour un bug précis : « Aucun texte trouvé » sur toutes les captures,
/// alors que le banc d'essai lisait les mêmes images sans problème. Un tuyau
/// qui rend une chaîne vide peut échouer à quatre endroits — le moteur, le
/// regroupement, l'assemblage, le nettoyage final — et seul un affichage
/// intermédiaire dit lequel.
///
/// ```
/// swift run BranSpike ocr <image.png> [--prose]
/// ```
enum OCRSpike {

    static func run(_ arguments: [String]) async {
        guard let path = arguments.first else {
            print("usage: swift run BranSpike ocr <image.png> [--prose]")
            return
        }
        let layout: LayoutMode = arguments.contains("--prose") ? .prose : .monospaced

        guard let image = NSImage(contentsOfFile: path)?
            .cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
            print("✗ image illisible : \(path)")
            return
        }

        print("image        \(image.width)×\(image.height) px")
        print("mise en page \(layout.label)")
        print("")

        let engine = VisionRecogniser()
        let handle = RecognisableImage(
            handle: image,
            pixelWidth: image.width,
            pixelHeight: image.height
        )

        let started = Date()
        let regions: [TextRegion]
        do {
            regions = switch layout {
            case .monospaced: try await engine.recogniseCode(handle)
            case .prose: try await engine.recognise(handle, language: .french)
            }
        } catch {
            print("✗ le moteur a levé : \(error)")
            return
        }
        let elapsed = Date().timeIntervalSince(started)

        print("① MOTEUR      \(regions.count) régions en \(Int(elapsed * 1000)) ms")
        guard regions.isEmpty == false else {
            print("   → le moteur ne rend rien. Le problème est en amont de l'assemblage.")
            return
        }
        for region in regions.prefix(4) {
            print(String(
                format: "   x=%.4f y=%.4f l=%.4f h=%.4f conf=%.2f  « %@ »",
                region.x, region.y, region.width, region.height, region.confidence,
                String(region.text.prefix(48))
            ))
        }
        if regions.count > 4 { print("   … \(regions.count - 4) autres") }

        let rows = TextAssembler.group(regions)
        print("")
        print("② GROUPEMENT  \(rows.count) lignes")
        print(String(format: "   hauteur médiane = %.5f  →  tolérance = %.5f",
                     TextAssembler.medianHeight(regions), TextAssembler.medianHeight(regions) / 2))
        print(String(format: "   largeur car. médiane = %.5f", TextAssembler.medianCharacterWidth(regions)))

        let assembled = TextAssembler.assemble(regions, layout: layout)
        print("")
        print("③ ASSEMBLAGE  \(assembled.count) caractères")
        guard assembled.isEmpty == false else {
            print("   → l'assemblage rend du vide alors que le moteur a rendu du texte.")
            return
        }

        let fixed = CharacterFixer.fix(assembled, layout: layout)
        let repairs = CharacterFixer.repairCount(assembled, layout: layout)
        print("④ CORRECTIONS \(repairs) caractère(s) remplacé(s)")

        let trimmed = fixed
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.replacing(/[ \t]+$/, with: "") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        print("⑤ NETTOYAGE   \(trimmed.count) caractères")
        if trimmed.isEmpty {
            print("   → le nettoyage a tout mangé. C'est là qu'est le bug.")
            return
        }

        print("")
        print("════ RÉSULTAT ════")
        for line in trimmed.split(separator: "\n", omittingEmptySubsequences: false) {
            print("│ \(line)")
        }
    }
}
