// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "bran",
    platforms: [.macOS("15.0")],
    targets: [
        // Logique pure. Aucune permission, aucun écran, aucun framework système.
        // C'est ce target qui porte l'objectif « 65 % testable en swift test ».
        .target(name: "BranCore"),

        // L'application. Assemblée en .app signé par Scripts/build-app.sh :
        // SwiftPM produit le binaire, le script produit le bundle. Ça évite un
        // .xcodeproj tout en gardant les #Preview (ouvrir Package.swift dans
        // Xcode suffit) et `swift test` à ~1 ms.
        .executableTarget(name: "BranApp", dependencies: ["BranCore"]),

        // Exécutable de dérisquage (Phase 1). Lancé depuis le Terminal, il hérite
        // des autorisations TCC du Terminal — pas besoin du certificat bran-dev
        // pour franchir la barrière.
        .executableTarget(name: "BranSpike", dependencies: ["BranCore"]),

        .testTarget(name: "BranCoreTests", dependencies: ["BranCore"]),
    ]
)
