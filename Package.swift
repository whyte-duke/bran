// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "bran",
    platforms: [.macOS("15.0")],
    dependencies: [
        // Parakeet TDT 0.6B v3 converti en CoreML, exécuté sur le Neural Engine.
        // Apache 2.0. On ne convertit rien nous-mêmes : porter une conversion
        // NeMo → CoreML serait une dette à vie, à chaque publication de NVIDIA.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.5")
    ],
    targets: [
        // Logique pure. Aucune permission, aucun écran, aucun framework système.
        // C'est ce target qui porte l'objectif « 65 % testable en swift test ».
        .target(name: "BranCore"),

        // Même contrat que BranCore, mais pour la dictée : machine à états,
        // politique de rétention, raccourcis, dictionnaire de corrections.
        // Tout ce qui se teste sans micro et sans autorisation.
        .target(name: "BranSpeech"),

        // Même contrat encore, pour la capture de texte à l'écran. Ne dépend
        // pas de Vision : l'assemblage des lignes et la table de substitutions
        // — là où se jouent presque toutes les erreurs — se testent sur des
        // rectangles nus, sans image et sans autorisation.
        .target(name: "BranVision"),

        // Le contrat une quatrième fois, pour le veilleur de sessions
        // parallèles : identité des voies, machine à états, résolveur, lecture
        // des transcriptions. Rien de tout ça n'a besoin d'un écran ni d'une
        // autorisation — c'est là que se joue la justesse des alertes, donc
        // c'est là que doivent être les tests.
        .target(name: "BranWatch"),

        // **L'exception assumée, et la seule.** AppKit et CoreGraphics sont
        // autorisés ici : cette cible n'est pas de la logique pure et ne
        // prétend pas l'être — elle énumère les fenêtres du système et réduit
        // une image en niveaux de gris. Il n'y a rien à y tester, puisque tout
        // son résultat dépend d'une autorisation et d'un serveur de fenêtres.
        //
        // Elle existe parce que `BranApp` et `BranSpike` sont deux exécutables
        // distincts : le même appel à `CGWindowListCopyWindowInfo` y existait
        // en cinq exemplaires, et un `internal` ne pouvait pas les réunir. Ce
        // qu'elle offre n'est pas de la testabilité, c'est un seul endroit à
        // corriger le jour où Apple change ces API.
        .target(name: "BranWindows"),

        // L'application. Assemblée en .app signé par Scripts/build-app.sh :
        // SwiftPM produit le binaire, le script produit le bundle. Ça évite un
        // .xcodeproj tout en gardant les #Preview (ouvrir Package.swift dans
        // Xcode suffit) et `swift test` à ~1 ms.
        .executableTarget(
            name: "BranApp",
            dependencies: [
                "BranCore",
                "BranSpeech",
                "BranVision",
                "BranWatch",
                "BranWindows",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),

        // Exécutable de dérisquage (Phase 1). Lancé depuis le Terminal, il hérite
        // des autorisations TCC du Terminal — pas besoin du certificat bran-dev
        // pour franchir la barrière.
        .executableTarget(
            name: "BranSpike",
            dependencies: [
                "BranCore",
                "BranSpeech",
                "BranVision",
                "BranWatch",
                "BranWindows",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),

        .testTarget(name: "BranCoreTests", dependencies: ["BranCore"]),
        .testTarget(name: "BranSpeechTests", dependencies: ["BranSpeech"]),
        .testTarget(name: "BranVisionTests", dependencies: ["BranVision"]),
        .testTarget(name: "BranWatchTests", dependencies: ["BranWatch"]),
    ]
)
