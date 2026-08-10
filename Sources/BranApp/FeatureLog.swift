import Foundation
import os

/// Le journal de la dictée et de la capture de texte.
///
/// ## La règle, avant tout le reste
///
/// **Rien de ce que l'utilisateur voit, dit ou copie n'entre dans ce journal.**
/// Pas le texte reconnu à l'écran, pas le presse-papiers, pas la transcription,
/// pas un titre de fenêtre, pas un chemin qui contient un nom de compte. On
/// journalise ce qui **diagnostique** — des états, des comptes, des durées, des
/// identifiants, des genres d'erreur, des formes — jamais ce qui **reproduit**.
///
/// Ce n'est pas de la prudence de principe. `SnapshotController` écrivait les
/// quarante premiers caractères de chaque région reconnue, en clair, avec
/// `privacy: .public`. Le journal unifié de macOS n'est pas « la machine » au
/// sens où bran l'entend : Console le lit, `log collect` l'emporte, un
/// sysdiagnose le joint à un rapport de bug, et la purge à sept jours de
/// `SnapshotRetention` n'y peut rien. Or le lecteur d'écran vise ce qui est
/// devant l'utilisateur — mesuré sur un vrai historique, Chrome et Terminal
/// 77 % du temps. Des mots de passe, des jetons, des noms de clients, des
/// `.env`.
///
/// ## Ce que le type impose, pour ne pas dépendre de la vigilance
///
/// `record(_:)` ne prend pas une `String` mais un ``Fact``, construit à partir
/// d'un littéral. Dans ce littéral :
///
/// - les **parties écrites en dur** sont publiques : elles sont déjà dans le
///   binaire, les cacher ne protégerait personne ;
/// - `\(nombre)`, `\(booléen)`, `\(énumération)`, `\(uuid)` sont publics : ce
///   sont des faits, ils ne peuvent pas porter de contenu ;
/// - **`\(chaîne)` est privé** dans le journal unifié. Le type ne peut pas
///   prouver d'où vient une `String`, alors il ne la montre pas : Console
///   affiche `‹privé 24 c.›`, et le texte complet ne va que dans le fichier.
///
/// Deux portes de sortie, et elles sont volontairement visibles à la relecture :
///
/// - `\(safe: chaîne)` publie la chaîne. À n'employer que si l'on peut dire à
///   voix haute d'où elle vient — un `rawValue`, un identifiant de moteur, une
///   constante du programme. Une ligne qui l'emploie mérite un commentaire qui
///   le justifie.
/// - `\(shapeOf: chaîne)` publie la **forme** de la chaîne et rien d'autre :
///   nombre de caractères, nombre de lignes, système d'écriture, répartition
///   entre lettres, chiffres, signes et espaces. C'est ce qu'il faut pour
///   diagnostiquer une mauvaise reconnaissance sans la reproduire.
///
/// Reste `record(_ message: String)`, marqué `@_disfavoredOverload` : il existe
/// pour les appels qui passent une `String` déjà fabriquée — un
/// `String(format:)`, une variable. Le compilateur ne le choisit **que** dans
/// ce cas, et tout ce qui passe par là est intégralement `<private>` dans le
/// journal unifié. Si une ligne disparaît de Console, c'est ça : la rendre à un
/// littéral la fait réapparaître, à l'exception de ses `\(chaîne)`.
///
/// ## Les deux sorties, parce qu'elles servent à deux moments
///
/// - **`os.Logger`** pour regarder en direct pendant qu'on appuie sur le
///   raccourci :
///   ```
///   log stream --predicate 'subsystem == "com.opahventures.bran"' --level debug
///   ```
///   C'est la sortie qui sort de la machine — celle qu'un utilisateur nous
///   enverra collée dans un courriel. C'est donc la sortie censurée.
/// - **un fichier**, `Captures/journal.txt`, pour lire après coup ce qui s'est
///   passé quand on n'était pas devant. Il ne quitte pas le dossier de bran,
///   il est plafonné à deux cents lignes, et c'est lui qui garde le texte
///   complet des `\(chaîne)`. Ce n'est pas une raison pour y mettre du
///   contenu : la règle du haut de page vaut pour les deux sorties.
///
/// ## Pourquoi le reste est resté public
///
/// `privacy: .public` sur les parties écrites en dur et sur les nombres est une
/// décision, pas un reste. Un journal où tout est `<private>` ne se lit pas, et
/// la raison d'être de ce fichier — une capture qui rend du vide peut échouer à
/// six endroits, et aucun d'eux ne se voit depuis l'interface — disparaît avec
/// lui. Deviner lequel a coûté une soirée ; une ligne par étape l'aurait donné
/// en trente secondes.
///
/// La description d'une erreur reste publique elle aussi : elles viennent de
/// `screencapture`, de Vision, d'`AVAudioEngine` ou de Foundation, ce sont des
/// phrases modèles et des codes, et c'est la ligne la plus utile quand
/// quelqu'un nous envoie sa sortie de Console. La seule fuite qu'on lui connaît
/// est le nom de fichier que Foundation glisse dans ses erreurs d'entrée-sortie
/// — ici des UUID d'images et `journal.txt`, rien qui nomme quelqu'un.
enum FeatureLog {

    private static let logger = Logger(subsystem: "com.opahventures.bran", category: "features")

    /// Là où le journal s'écrit. Fixé au démarrage par `SnapshotStore`, pour ne
    /// pas dépendre du dossier de destination à chaque ligne.
    nonisolated(unsafe) static var folder: URL?

    /// Nombre de lignes conservées. Un journal qui grossit sans fin devient un
    /// problème à son tour ; deux cents lignes couvrent largement la dernière
    /// séance de mise au point.
    private static let maximumLines = 200

    // MARK: - Écrire

    static func record(_ fact: Fact) {
        logger.debug("\(fact.redacted, privacy: .public)")
        append(fact.plain)
    }

    static func record(_ fact: Fact, error: any Error) {
        let reason = error.localizedDescription
        logger.error("\(fact.redacted, privacy: .public) — \(reason, privacy: .public)")
        append("✗ \(fact.plain) — \(reason)")
    }

    /// La porte de service, pour les appels qui passent une `String` déjà
    /// fabriquée. Voir l'en-tête : tout ce qui entre par là est `<private>`
    /// dans le journal unifié, parce que le type n'en sait rien.
    @_disfavoredOverload
    static func record(_ message: String) {
        logger.debug("\(message, privacy: .private)")
        append(message)
    }

    @_disfavoredOverload
    static func record(_ message: String, error: any Error) {
        let reason = error.localizedDescription
        logger.error("\(message, privacy: .private) — \(reason, privacy: .public)")
        append("✗ \(message) — \(reason)")
    }

    // MARK: - Une ligne faite de faits

    /// Ce qu'une ligne de journal a le droit de contenir.
    ///
    /// Deux rendus du même message : `plain` pour le fichier, `redacted` pour le
    /// journal unifié. La différence tient dans les `\(chaîne)`, remplacées par
    /// leur mesure. Voir l'en-tête du fichier pour la règle et ses deux portes
    /// de sortie.
    struct Fact: ExpressibleByStringInterpolation, Sendable {

        /// La ligne entière, pour `Captures/journal.txt`.
        let plain: String
        /// La même, sans les chaînes que le type n'a pas pu prouver.
        let redacted: String

        init(stringLiteral value: String) {
            plain = value
            redacted = value
        }

        init(stringInterpolation: StringInterpolation) {
            plain = stringInterpolation.plain
            redacted = stringInterpolation.redacted
        }

        private init(plain: String, redacted: String) {
            self.plain = plain
            self.redacted = redacted
        }

        /// Pour les messages écrits sur plusieurs littéraux collés par `+`.
        ///
        /// Sans lui, `"a\(x) " + "b"` produisait une `String`, tombait sur la
        /// porte de service et disparaissait entièrement de Console — ce qui
        /// aurait puni un pli de mise en forme au lieu d'une vraie fuite.
        static func + (lhs: Fact, rhs: Fact) -> Fact {
            Fact(plain: lhs.plain + rhs.plain, redacted: lhs.redacted + rhs.redacted)
        }

        struct StringInterpolation: StringInterpolationProtocol {

            fileprivate var plain = ""
            fileprivate var redacted = ""

            init(literalCapacity: Int, interpolationCount: Int) {
                plain.reserveCapacity(literalCapacity + interpolationCount * 12)
                redacted.reserveCapacity(literalCapacity + interpolationCount * 12)
            }

            mutating func appendLiteral(_ literal: String) {
                plain += literal
                redacted += literal
            }

            // — Des faits. Publics des deux côtés. —

            mutating func appendInterpolation(_ value: some BinaryInteger) { both("\(value)") }

            mutating func appendInterpolation(_ value: Bool) { both("\(value)") }

            mutating func appendInterpolation(_ value: some BinaryFloatingPoint) {
                both("\(Double(value))")
            }

            /// Un flottant arrondi, pour ne pas avoir à passer par
            /// `String(format:)` — qui, lui, fabrique une `String` et ferait
            /// tomber toute la ligne dans le privé.
            mutating func appendInterpolation(_ value: some BinaryFloatingPoint, decimals: Int) {
                both(String(format: "%.\(max(0, decimals))f", Double(value)))
            }

            /// Les énumérations de l'application. `CaseIterable` est là pour
            /// écarter les `RawRepresentable` qui enveloppent une chaîne
            /// d'exécution : un jeu de cas fermé a des `rawValue` écrits dans
            /// le code, donc déjà dans le binaire.
            mutating func appendInterpolation<T: RawRepresentable & CaseIterable>(
                _ value: T
            ) where T.RawValue == String {
                both(value.rawValue)
            }

            mutating func appendInterpolation(_ value: UUID) { both(value.uuidString) }

            /// Une constante de compilation ne peut pas porter de contenu.
            mutating func appendInterpolation(_ value: StaticString) { both("\(value)") }

            // — Le reste. Privé, sauf demande explicite. —

            /// Le cas par défaut d'une chaîne : le fichier la garde, Console
            /// n'en voit que la longueur.
            mutating func appendInterpolation(_ value: String) {
                plain += value
                redacted += "‹privé \(value.count) c.›"
            }

            /// Tout le reste — un optionnel, un tableau, un type à soi.
            ///
            /// Il existe pour que la règle ne se paie pas en erreurs de
            /// compilation chez les voisins : une interpolation qu'aucune
            /// surcharge ne reconnaît compile, et **ne sort pas**. Si vous
            /// tenez à la voir dans Console, dites pourquoi et passez par
            /// `\(safe:)`.
            mutating func appendInterpolation(_ value: some Any) {
                plain += String(describing: value)
                redacted += "‹privé›"
            }

            /// À n'employer que pour une chaîne dont on peut dire d'où elle
            /// vient, et en le disant en commentaire au-dessus.
            mutating func appendInterpolation(safe value: String) { both(value) }

            /// La forme d'une chaîne, jamais son contenu. C'est la façon de
            /// parler d'un texte reconnu, dicté ou collé.
            mutating func appendInterpolation(shapeOf value: String) {
                both(FeatureLog.shape(of: value))
            }

            private mutating func both(_ text: String) {
                plain += text
                redacted += text
            }
        }
    }

    // MARK: - Décrire un texte sans le reproduire

    /// Ce qu'on a le droit de dire d'un texte : sa taille, sa disposition, son
    /// système d'écriture, et la part de lettres, de chiffres, de signes et
    /// d'espaces.
    ///
    /// Assez pour trancher les pannes qu'on rencontre vraiment — une région
    /// large qui rend trois caractères, un `ls -la` lu comme de la prose et qui
    /// perd ses signes, un moteur qui rend des régions vides, une image en
    /// japonais reconnue en latin — sans qu'aucun mot n'en sorte. Le pire qu'on
    /// puisse en déduire sur un fragment très court, c'est « c'était sans doute
    /// un nombre » ; on ne saura jamais lequel.
    ///
    /// Format : `forme=24 c. sur 2 lignes, latin, 15L 2N 3S 4E`, où `L`, `N`,
    /// `S` et `E` comptent lettres, nombres, signes et espaces.
    static func shape(of text: String) -> String {
        guard text.isEmpty == false else { return "forme=vide" }

        var letters = 0
        var digits = 0
        var spaces = 0
        var symbols = 0
        var systems: Set<String> = []

        for scalar in text.unicodeScalars {
            if CharacterSet.decimalDigits.contains(scalar) {
                digits += 1
            } else if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                spaces += 1
            } else if CharacterSet.letters.contains(scalar) {
                letters += 1
                systems.insert(writingSystem(of: scalar))
            } else {
                symbols += 1
            }
        }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).count
        let system = systems.isEmpty ? "sans lettre" : systems.sorted().joined(separator: "+")

        return "forme=\(text.count) c."
            + (lines > 1 ? " sur \(lines) lignes" : "")
            + ", \(system), \(letters)L \(digits)N \(symbols)S \(spaces)E"
    }

    /// Le système d'écriture d'un caractère, par plage Unicode.
    ///
    /// Volontairement grossier : il répond à « le moteur a-t-il reconnu la
    /// bonne écriture ? », qui est la question utile, et il ne distingue pas
    /// deux textes du même alphabet — ce qui est exactement le point.
    private static func writingSystem(of scalar: Unicode.Scalar) -> String {
        switch scalar.value {
        case 0x0041...0x024F, 0x1E00...0x1EFF: "latin"
        case 0x0370...0x03FF, 0x1F00...0x1FFF: "grec"
        case 0x0400...0x052F: "cyrillique"
        case 0x0590...0x05FF: "hébreu"
        case 0x0600...0x06FF, 0x0750...0x077F: "arabe"
        case 0x0900...0x097F: "devanagari"
        case 0x0E00...0x0E7F: "thaï"
        case 0x3040...0x309F: "hiragana"
        case 0x30A0...0x30FF: "katakana"
        case 0x3400...0x4DBF, 0x4E00...0x9FFF: "han"
        case 0xAC00...0xD7AF: "hangul"
        default: "autre"
        }
    }

    // MARK: - Le fichier

    private static func append(_ message: String) {
        guard let folder else { return }
        let line = "\(Self.stamp()) \(message)\n"
        let url = folder.appending(path: "journal.txt")

        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

            var existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            existing += line

            // Rognage par la fin : ce qui vient de se passer compte plus que ce
            // qui s'est passé avant-hier.
            let lines = existing.split(separator: "\n", omittingEmptySubsequences: false)
            if lines.count > maximumLines {
                existing = lines.suffix(maximumLines).joined(separator: "\n")
            }

            try existing.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            // Un journal qui n'arrive pas à s'écrire ne doit surtout pas casser
            // ce qu'il observe.
            logger.error("journal inaccessible : \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: .now)
    }
}
