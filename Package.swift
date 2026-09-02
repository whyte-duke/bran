// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "bran",
    platforms: [.macOS("15.0")],
    dependencies: [
        // Parakeet TDT 0.6B v3 converti en CoreML, exécuté sur le Neural Engine.
        // Apache 2.0. On ne convertit rien nous-mêmes : porter une conversion
        // NeMo → CoreML serait une dette à vie, à chaque publication de NVIDIA.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.5"),
        // Les mises à jour automatiques. Voir `UpdateService` pour ce qu'elle porte
        // et `Scripts/release.sh` pour ce qui les publie.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.0"),
    ],
    targets: [
        // LAME 4.0, réduit à son encodeur. **La seule bibliothèque C du dépôt,
        // et elle est là par nécessité, pas par confort.**
        //
        // Azure refuse de décoder l'AAC au-delà d'environ vingt minutes — mesuré
        // le 31/08/2026 sur un vrai closing de 32 min, dans les trois profils
        // qu'on pouvait produire (16 kHz mono, 44,1 kHz mono, 44,1 kHz stéréo),
        // et sur les deux moteurs, `fast` comme `batch`. Le même audio en MP3
        // passe en 60 s. Voir `AudioExporter` pour le relevé complet.
        //
        // Or macOS **décode** le MP3 mais ne l'**encode** pas : AudioToolbox
        // annonce le format `.mp3` dans `afconvert -hf`, puis répond
        // `ExtAudioFileSetProperty ('cfmt') failed ('fmt?')` dès qu'on lui
        // demande d'écrire. Il n'existe aucun chemin système vers le seul format
        // que le CRM accepte, d'où ce vendoring.
        //
        // Le sous-arbre est celui de `libmp3lame`, sans le décodeur (mpg123),
        // sans l'exécutable `lame` et sans les analyseurs — 20 fichiers C. Le
        // `config.h` est celui qu'un `./configure --disable-frontend
        // --disable-decoder --disable-analyzer-hooks` produit sur macOS arm64 ;
        // bran ne vise que macOS, une génération par plateforme serait de la
        // cérémonie sans usage. LGPL 2.1, texte conservé dans le dossier.
        .target(
            name: "CLame",
            cSettings: [
                // `#include <config.h>` : les sources LAME le cherchent dans le
                // chemin d'inclusion, pas à côté d'elles.
                .headerSearchPath("."),
                .define("HAVE_CONFIG_H"),

                // **`-UDEBUG` n'est pas cosmétique.** SwiftPM compile les cibles
                // C avec `-DDEBUG=1` en configuration de débogage, et LAME s'en
                // sert pour activer des `printf` par trame : un closing de
                // 32 min a produit 6,2 Mo de « count1: real: … » sur la sortie
                // standard, et l'encodage est passé de quelques secondes à 30 s
                // rien qu'à les écrire. `config.h` laisse pourtant `DEBUG` non
                // défini — c'est bien l'outil de construction qui l'impose, pas
                // le réglage de la bibliothèque, donc c'est ici que ça se
                // reprend. Le drapeau arrive après celui de SwiftPM, qu'il
                // annule.
                //
                // `unsafeFlags` est accepté parce que bran est un paquet racine
                // dont personne ne dépend ; il n'y a pas d'autre moyen de
                // *retirer* une définition dans l'API de `cSettings`.
                .unsafeFlags(["-UDEBUG"]),
            ]
        ),

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

        // Le contrat, la logique et les preuves de la sauvegarde. Même règle que
        // les quatre cibles ci-dessus, appliquée là où elle compte le plus :
        // ici vivent les parseurs de la sortie de Kopia, l'évaluateur de la
        // chaîne réseau, la politique de planification et la machine à états —
        // c'est-à-dire tout ce qui décide si l'écran a le droit d'afficher
        // « sauvegardé ». Rien de tout ça ne touche au réseau, au disque ni à
        // un processus : le pilote Kopia et les sondes vivent dans `BranApp`.
        //
        // **La séparation est la fonctionnalité.** Une sauvegarde qui ment ne
        // se démasque pas en la regardant tourner — elle met des semaines. Le
        // seul endroit où cette classe de défaut s'attrape en une seconde,
        // c'est un test qui rejoue une sortie figée de Kopia.
        .target(name: "BranBackup"),

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
                "CLame",
                "BranBackup",
                "BranCore",
                "BranSpeech",
                "BranVision",
                "BranWatch",
                "BranWindows",
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "Sparkle", package: "Sparkle"),
            ]
        ),

        // Exécutable de dérisquage (Phase 1). Lancé depuis le Terminal, il hérite
        // des autorisations TCC du Terminal — pas besoin du certificat bran-dev
        // pour franchir la barrière.
        .executableTarget(
            name: "BranSpike",
            dependencies: [
                "BranBackup",
                "BranCore",
                "BranSpeech",
                "BranVision",
                "BranWatch",
                "BranWindows",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),

        .testTarget(name: "BranBackupTests", dependencies: ["BranBackup"]),
        .testTarget(name: "BranCoreTests", dependencies: ["BranCore"]),
        .testTarget(name: "BranSpeechTests", dependencies: ["BranSpeech"]),
        .testTarget(name: "BranVisionTests", dependencies: ["BranVision"]),
        .testTarget(name: "BranWatchTests", dependencies: ["BranWatch"]),
    ]
)
