import Foundation
import Testing
@testable import BranBackup

/// **Ce que ce fichier protège** : que la ligne de progression de Kopia ne
/// puisse jamais produire un chiffre inventé.
///
/// Trois familles de mensonge sont visées. La première est l'unité : Kopia
/// compte en puissances de 1000, et une conversion en 1024 annoncerait un
/// volume et un temps restant faux de 7 % sans jamais planter. La seconde est
/// le découpage : `Process` livre stderr en paquets qui coupent au hasard —
/// au milieu d'un nombre, d'une unité, d'un caractère — et un lecteur naïf
/// émettrait un état à partir d'un fragment. La troisième est l'optimisme :
/// `estimating...` n'est pas 0 %, une estimation qui se corrige à la baisse
/// doit pouvoir reculer, et un champ illisible doit faire échouer la ligne
/// entière plutôt que de laisser passer des zéros de repli.
///
/// Les lignes réelles utilisées ici viennent de `create2.stderr`, capturé le
/// 02/09/2026 sur ce dépôt avec kopia 0.23.1 — copiées littéralement, `\r`
/// compris, pas reconstruites de mémoire.
@Suite("La lecture de la progression de Kopia")
struct KopiaProgressReaderTests {

    // MARK: - Les lignes réelles

    @Test("La ligne canonique — celle citée dans le contrat — se lit dans le détail")
    func canonicalLineFromTheRepository() {
        let progress = try! #require(KopiaProgressReader.parse(
            line: " - 5 hashing, 7 hashed (233 MB), 0 cached (0 B), uploaded 215.2 MB, estimated 240 MB (97.1%) 0s left"
        ))
        #expect(progress.hashingFiles == 5)
        #expect(progress.hashedFiles == 7)
        #expect(progress.hashedBytes == 233_000_000)
        #expect(progress.cachedBytes == 0)
        #expect(progress.uploadedBytes == 215_200_000)
        #expect(progress.estimatedBytes == 240_000_000)
        #expect(progress.secondsRemaining == 0)
        #expect(abs(progress.fraction! - 0.970_833) < 0.000_001)
    }

    @Test("Tant que kopia estime, aucun total n'est affirmé — jamais un zéro")
    func estimatingRegimeHasNoTotal() {
        let progress = try! #require(KopiaProgressReader.parse(
            line: " | 7 hashing, 0 hashed (131.1 KB), 0 cached (0 B), uploaded 0 B, estimating..."
        ))
        #expect(progress.hashingFiles == 7)
        #expect(progress.hashedBytes == 131_100)
        #expect(progress.uploadedBytes == 0)
        // Ni l'un ni l'autre ne vaut 0 : ce sont des absences, pas des mesures.
        #expect(progress.estimatedBytes == nil)
        #expect(progress.secondsRemaining == nil)
        #expect(progress.fraction == nil)
    }

    @Test("La toute dernière ligne, marquée `*`, se lit comme les autres")
    func finalStarMarkedLine() {
        let progress = try! #require(KopiaProgressReader.parse(
            line: " * 0 hashing, 12 hashed (240 MB), 0 cached (0 B), uploaded 240 MB, estimated 240 MB (100.0%) 0s left"
        ))
        #expect(progress.hashedFiles == 12)
        #expect(progress.estimatedBytes == 240_000_000)
        #expect(progress.fraction == 1)
    }

    // MARK: - Les unités : puissances de 1000, pas de 1024

    @Test("Les quatre unités vues se convertissent en puissances de 1000")
    func decimalUnits() {
        func line(uploaded: String) -> String {
            " - 1 hashing, 1 hashed (1 B), 0 cached (0 B), uploaded \(uploaded), estimating..."
        }
        #expect(KopiaProgressReader.parse(line: line(uploaded: "0 B"))?.uploadedBytes == 0)
        #expect(KopiaProgressReader.parse(line: line(uploaded: "131.1 KB"))?.uploadedBytes == 131_100)
        #expect(KopiaProgressReader.parse(line: line(uploaded: "1.5 GB"))?.uploadedBytes == 1_500_000_000)

        // Le cas mesuré qui a tranché : une source de 240 000 000 octets
        // s'affiche « 240 MB ». En base 1024 ce serait 228,9 Mio affichés
        // « 229 MB » — un chiffre différent, et faux du point de vue de kopia.
        #expect(KopiaProgressReader.parse(line: line(uploaded: "240 MB"))?.uploadedBytes == 240_000_000)
    }

    // MARK: - Le temps restant

    @Test("Les formes composées du temps restant se lisent, et son absence aussi")
    func remainingTimeForms() {
        func line(estimate: String) -> String {
            " - 1 hashing, 1 hashed (1 B), 0 cached (0 B), uploaded 1 B, \(estimate)"
        }
        #expect(KopiaProgressReader.parse(
            line: line(estimate: "estimated 240 MB (50.0%) 0s left"))?.secondsRemaining == 0)
        #expect(KopiaProgressReader.parse(
            line: line(estimate: "estimated 240 MB (50.0%) 1s left"))?.secondsRemaining == 1)
        #expect(KopiaProgressReader.parse(
            line: line(estimate: "estimated 240 MB (50.0%) 13m30s left"))?.secondsRemaining == 810)
        #expect(KopiaProgressReader.parse(
            line: line(estimate: "estimated 240 MB (50.0%) 2h5m left"))?.secondsRemaining == 7_500)

        // Vu sur un gros volume : kopia connaît le total mais ne dit parfois
        // rien du reste à faire. Ce n'est pas une ligne cassée.
        let noTime = KopiaProgressReader.parse(line: line(estimate: "estimated 240 MB (50.0%)"))
        #expect(noTime?.estimatedBytes == 240_000_000)
        #expect(noTime?.secondsRemaining == nil)
    }

    // MARK: - Ce qui n'est pas de la progression

    @Test("Les lignes de maintenance et l'annonce de la source ne sont ni progression ni erreur")
    func nonProgressLinesAreIgnored() {
        let lines = [
            "Running full maintenance...",
            // Le piège nommé : ce volume entre parenthèses a exactement la
            // forme d'un champ de progression et ne doit jamais en devenir un.
            "GC found 896989 unused contents (140.3 GB)",
            "GC found 0 unused contents that are too recent to delete (0 B)",
            "Compacting an eligible uncompacted epoch...",
            "Finished full maintenance.",
            "Snapshotting user@host:/tmp/fixtures/src ...",
        ]
        for line in lines {
            #expect(KopiaProgressReader.parse(line: line) == nil, "\(line) n'aurait pas dû se lire comme une progression")
        }
    }

    // MARK: - Zéro optimisme

    @Test("Un champ illisible fait échouer la ligne entière, pas seulement ce champ")
    func unreadableFieldFailsTheWholeLine() {
        // Unité inconnue : « XX » n'existe pas, la ligne ne doit rien affirmer.
        #expect(KopiaProgressReader.parse(
            line: " - 5 hashing, 7 hashed (233 MB), 0 cached (0 B), uploaded 215.2 XX, estimated 240 MB (97.1%) 0s left"
        ) == nil)

        // Champ « cached » absent : la forme attendue à cinq champs est rompue.
        #expect(KopiaProgressReader.parse(
            line: " - 5 hashing, 7 hashed (233 MB), uploaded 215.2 MB, estimated 240 MB (97.1%) 0s left"
        ) == nil)

        // Pas de préfixe de rotation : structurellement, ce n'est pas une
        // ligne de progression, même si le reste ressemble.
        #expect(KopiaProgressReader.parse(
            line: "5 hashing, 7 hashed (233 MB), 0 cached (0 B), uploaded 215.2 MB, estimated 240 MB (97.1%) 0s left"
        ) == nil)
    }

    @Test("L'estimation se corrige en cours de route, et la fraction a le droit de reculer")
    func fractionCanRecede() {
        // Kopia revoit son total à la hausse (120 → 400 MB) une fois qu'il a
        // vu plus de fichiers à hacher. La fraction affichée doit suivre
        // honnêtement, pas rester lissée vers le haut.
        let early = try! #require(KopiaProgressReader.parse(
            line: " - 1 hashing, 1 hashed (100 MB), 0 cached (0 B), uploaded 90 MB, estimated 120 MB (83.3%) 1s left"
        ))
        let revised = try! #require(KopiaProgressReader.parse(
            line: " - 1 hashing, 1 hashed (105 MB), 0 cached (0 B), uploaded 95 MB, estimated 400 MB (26.2%) 13m30s left"
        ))
        let earlyFraction = try! #require(early.fraction)
        let revisedFraction = try! #require(revised.fraction)
        #expect(revisedFraction < earlyFraction)
    }

    // MARK: - Le découpage incrémental

    @Test("Une coupure au milieu d'un nombre n'émet rien tant que le nombre n'est pas complet")
    func splitMidNumberEmitsNothingEarly() {
        var reader = KopiaProgressReader()
        // Le paquet s'arrête net au milieu de « 215.2 » — vu tel quel dans
        // les descriptions du flux réel : « uploaded 215.2 M » ne doit rien
        // laisser deviner.
        let firstChunk = reader.accept(
            " - 5 hashing, 7 hashed (233 MB), 0 cached (0 B), uploaded 21"
        )
        #expect(firstChunk.isEmpty)

        let secondChunk = reader.accept("5.2 MB, estimated 240 MB (97.1%) 0s left\r")
        let progress = try! #require(secondChunk.first)
        #expect(secondChunk.count == 1)
        #expect(progress.uploadedBytes == 215_200_000)
    }

    @Test("Une unité tronquée à la lettre près ne se lit pas comme la bonne unité")
    func truncatedUnitDoesNotParse() {
        // « uploaded 215.2 M » : lire 215.2 et supposer « MB » inventerait un
        // chiffre. « M » seul n'est pas une unité connue — les cinq champs
        // sont là, seule l'unité est coupée, pour isoler ce cas précis du
        // simple manque de champ testé ailleurs.
        #expect(KopiaProgressReader.parse(
            line: " - 5 hashing, 7 hashed (233 MB), 0 cached (0 B), uploaded 215.2 M, estimating..."
        ) == nil)
    }

    @Test("Un flux découpé caractère par caractère produit exactement la même suite d'états qu'un flux livré d'un bloc")
    func characterByCharacterMatchesWholeBlock() {
        // Reconstruction fidèle de `create2.stderr`, segment par segment tel
        // que le fichier réel le porte : l'annonce de source terminée par
        // `\n`, puis onze réécritures séparées par `\r`, puis la ligne finale
        // terminée par `\n`. Le chemin d'accès a été généralisé — il n'est
        // pas ce qui est sous test — mais chaque ligne de progression est
        // recopiée verbatim depuis la capture.
        let segments: [(text: String, terminator: Character)] = [
            ("Snapshotting user@host:/tmp/fixtures/src2 ...", "\n"),
            ("", "\r"),
            (" | 7 hashing, 0 hashed (131.1 KB), 0 cached (0 B), uploaded 0 B, estimating...", "\r"),
            (" / 12 hashing, 0 hashed (142.7 MB), 0 cached (0 B), uploaded 213 B, estimating...", "\r"),
            (" - 6 hashing, 6 hashed (208.7 MB), 0 cached (0 B), uploaded 171.2 MB, estimated 240 MB (87.0%) 1s left", "\r"),
            (" \\ 6 hashing, 6 hashed (208.8 MB), 0 cached (0 B), uploaded 171.2 MB, estimated 240 MB (87.0%) 1s left", "\r"),
            (" | 6 hashing, 6 hashed (214 MB), 0 cached (0 B), uploaded 194.2 MB, estimated 240 MB (89.2%) 1s left  ", "\r"),
            (" / 5 hashing, 7 hashed (223.3 MB), 0 cached (0 B), uploaded 194.2 MB, estimated 240 MB (93.0%) 0s left", "\r"),
            (" - 5 hashing, 7 hashed (233 MB), 0 cached (0 B), uploaded 215.2 MB, estimated 240 MB (97.1%) 0s left  ", "\r"),
            (" \\ 3 hashing, 9 hashed (239.1 MB), 0 cached (0 B), uploaded 215.2 MB, estimated 240 MB (99.6%) 0s left", "\r"),
            (" | 2 hashing, 10 hashed (239.1 MB), 0 cached (0 B), uploaded 215.2 MB, estimated 240 MB (99.6%) 0s left", "\r"),
            (" / 2 hashing, 10 hashed (239.1 MB), 0 cached (0 B), uploaded 215.2 MB, estimated 240 MB (99.6%) 0s left", "\r"),
            (" - 0 hashing, 12 hashed (240 MB), 0 cached (0 B), uploaded 240 MB, estimated 240 MB (100.0%) 0s left   ", "\r"),
            (" * 0 hashing, 12 hashed (240 MB), 0 cached (0 B), uploaded 240 MB, estimated 240 MB (100.0%) 0s left", "\n"),
        ]
        let fullStream = segments.map { $0.text + String($0.terminator) }.joined()

        var wholeBlockReader = KopiaProgressReader()
        let wholeBlockResult = wholeBlockReader.accept(fullStream)

        var characterReader = KopiaProgressReader()
        var characterResult: [BackupProgress] = []
        for character in fullStream {
            characterResult += characterReader.accept(String(character))
        }

        // Douze lignes de progression valides : les onze réécritures et la
        // finale — l'annonce de source et le segment vide entre `\n` et `\r`
        // sont rejetés par `parse(line:)`, dans les deux découpages.
        #expect(wholeBlockResult.count == 12)
        #expect(characterResult == wholeBlockResult)
    }
}

/// **Ce que ce fichier protège** : qu'un Mac assez gros pour avoir quelque
/// chose à perdre soit encore sauvegardé.
///
/// Le défaut qu'il fige était silencieux et complet. `parseSize` connaissait
/// `B`, `KB`, `MB` et `GB`, pas `TB`. Au-delà d'un téraoctet haché, kopia
/// écrit son unité comme il se doit, la ligne devenait illisible, et
/// `accept()` rendait un tableau vide. Or `KopiaDriver` ne rafraîchit son
/// horloge de blocage que sur une progression **décodée** : dix minutes plus
/// tard, son chien de garde concluait « plus rien n'avance » et tuait un run
/// parfaitement sain — à chaque tentative, indéfiniment, pendant que la
/// chaîne réseau restait verte.
///
/// C'est la panne fondatrice du projet, reconstruite un cran plus loin : rien
/// de restaurable, et rien qui le dise.
@Suite("Les grandes unités, et les nombres qui n'en sont pas")
struct KopiaProgressReaderLargeUnitTests {

    /// La ligne canonique, avec la seule unité changée : c'est exactement ce
    /// que voit un Mac de plus d'un téraoctet.
    @Test("Un téraoctet haché se lit, au lieu de rendre la ligne muette")
    func terabytesAreUnderstood() {
        let progress = try! #require(KopiaProgressReader.parse(
            line: " - 5 hashing, 7 hashed (1.5 TB), 0 cached (0 B), uploaded 215.2 MB, estimated 2 TB (75.0%) 0s left"
        ))
        #expect(progress.hashedBytes == 1_500_000_000_000)
        #expect(progress.estimatedBytes == 2_000_000_000_000)
    }

    @Test("Le pétaoctet aussi, pour que le jour venu ne coûte pas une seconde enquête")
    func petabytesAreUnderstood() {
        let progress = try! #require(KopiaProgressReader.parse(
            line: " - 5 hashing, 7 hashed (1 PB), 0 cached (0 B), uploaded 215.2 MB, estimated 2 PB (50.0%) 0s left"
        ))
        #expect(progress.hashedBytes == 1_000_000_000_000_000)
    }

    /// La conséquence, dite dans les termes du pilote : ce qui compte n'est
    /// pas que la ligne se lise, c'est que `accept()` rende quelque chose —
    /// c'est ce retour, et lui seul, qui repousse l'échéance du chien de garde.
    @Test("Une progression en téraoctets nourrit le chien de garde, au lieu de l'affamer")
    func terabyteProgressFeedsTheWatchdog() {
        var reader = KopiaProgressReader()
        let progresses = reader.accept(
            " - 5 hashing, 7 hashed (1.5 TB), 0 cached (0 B), uploaded 215.2 MB, estimated 2 TB (75.0%) 0s left\r"
        )
        #expect(progresses.isEmpty == false)
    }

    /// `Double("1e400")` rend `+∞` sans se plaindre, et `Int64(+∞)` est une
    /// erreur fatale — pas un `nil`. Kopia n'écrit pas cette notation ; un
    /// parseur qui arrête le processus sur une entrée qu'il ne reconnaît pas
    /// n'a pas à exister quand le refuser coûte trois lignes.
    @Test("Une taille non finie est refusée, jamais convertie")
    func nonFiniteSizeIsRefusedRatherThanFatal() {
        #expect(KopiaProgressReader.parse(
            line: " - 5 hashing, 7 hashed (1e400 GB), 0 cached (0 B), uploaded 215.2 MB, estimated 240 MB (97.1%) 0s left"
        ) == nil)
        #expect(KopiaProgressReader.parse(
            line: " - 5 hashing, 7 hashed (nan GB), 0 cached (0 B), uploaded 215.2 MB, estimated 240 MB (97.1%) 0s left"
        ) == nil)
    }

    @Test("Une taille qui déborde Int64 est refusée, jamais tronquée")
    func overflowingSizeIsRefused() {
        #expect(KopiaProgressReader.parse(
            line: " - 5 hashing, 7 hashed (99999999999 TB), 0 cached (0 B), uploaded 215.2 MB, estimated 240 MB (97.1%) 0s left"
        ) == nil)
    }
}
