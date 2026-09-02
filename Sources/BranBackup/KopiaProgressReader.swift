import Foundation

/// Découpe et interprète la ligne de progression que Kopia réécrit sur
/// **stderr**, par retours chariot.
///
/// Relevé réel (`create2.stderr`, kopia 0.23.1, 02/09/2026) : une annonce de
/// source terminée par `\n`, puis une seule ligne réécrite en boucle par
/// `\r`, précédée d'un caractère de rotation (`|`, `/`, `-`, `\`, ou `*` à la
/// toute fin), et dont la dernière occurrence se termine par `\n` :
///
/// ```
/// Snapshotting …/src2 ...
///  | 7 hashing, 0 hashed (131.1 KB), 0 cached (0 B), uploaded 0 B, estimating...
///  - 5 hashing, 7 hashed (233 MB), 0 cached (0 B), uploaded 215.2 MB, estimated 240 MB (97.1%) 0s left
/// ```
///
/// Le même flux porte aussi les lignes de maintenance (« Running full
/// maintenance... », « GC found 896989 unused contents (140.3 GB) ») et
/// l'annonce de la source (« Snapshotting … »), terminées par `\n` et sans
/// caractère de rotation. ``parse(line:)`` les reconnaît et rend `nil` — le
/// `(140.3 GB)` d'une ligne `GC found` a exactement la forme d'un volume de
/// progression et ne doit jamais en devenir un.
public struct KopiaProgressReader: Sendable {
    /// Ce qui n'a pas encore rencontré de `\r` ou `\n`. `Process` livre
    /// stderr par paquets qui ne respectent aucune frontière de ligne : un
    /// paquet peut s'arrêter au milieu d'un nombre (« uploaded 215.2 M »),
    /// au milieu du caractère de rotation, ou juste avant le séparateur qui
    /// clôt la ligne. Tant que ce séparateur n'est pas vu, rien n'est à lui,
    /// et rien ne doit être émis à partir de lui.
    private var buffer: String = ""

    public init() {}

    /// Consomme un morceau arbitraire du flux et rend les états de
    /// progression que ce morceau permet de fermer — zéro, un, ou plusieurs
    /// si le paquet contient plusieurs réécritures d'un coup.
    ///
    /// Une ligne non close reste dans le tampon jusqu'au prochain appel :
    /// c'est ce qui rend le découpage indépendant de la façon dont l'appelant
    /// tranche le flux, jusqu'à l'extrême d'un appel par caractère.
    public mutating func accept(_ chunk: String) -> [BackupProgress] {
        buffer += chunk

        var progresses: [BackupProgress] = []
        while let separator = buffer.firstIndex(where: { $0 == "\r" || $0 == "\n" }) {
            let line = String(buffer[buffer.startIndex..<separator])
            buffer = String(buffer[buffer.index(after: separator)...])
            if let progress = KopiaProgressReader.parse(line: line) {
                progresses.append(progress)
            }
        }
        return progresses
    }

    /// Analyse une ligne d'état déjà complète (déjà coupée sur `\r` ou `\n`).
    ///
    /// Rend `nil` sur tout ce qui n'est pas une ligne de progression — pas de
    /// préfixe de rotation, champ absent, unité inconnue, temps restant
    /// illisible — plutôt que de rendre un état partiel rempli de zéros. Un
    /// champ non analysé doit faire échouer la ligne entière : c'est la
    /// seule façon de ne jamais afficher un volume ou un temps restant
    /// inventé.
    public static func parse(line: String) -> BackupProgress? {
        var content = Substring(line)
        // Kopia efface la ligne précédente en réécrivant par-dessus puis en
        // complétant d'espaces ; une ligne plus courte que la précédente
        // laisse ces espaces de nettoyage à la fin (vu : « left  », « left   »).
        while content.hasSuffix(" ") { content.removeLast() }

        guard content.hasPrefix(" ") else { return nil }
        content.removeFirst()
        guard let marker = content.first, rotationMarkers.contains(marker) else { return nil }
        content.removeFirst()
        guard content.hasPrefix(" ") else { return nil }
        content.removeFirst()

        let fields = String(content).components(separatedBy: ", ")
        guard fields.count == 5 else { return nil }

        guard let hashingFiles = parseCount(fields[0], suffix: " hashing") else { return nil }
        guard let hashed = parseCountAndSize(fields[1], suffix: " hashed") else { return nil }
        guard let cached = parseCountAndSize(fields[2], suffix: " cached") else { return nil }
        guard let uploadedBytes = parseUploaded(fields[3]) else { return nil }
        guard let estimate = parseEstimate(fields[4]) else { return nil }

        return BackupProgress(
            hashingFiles: hashingFiles,
            hashedFiles: hashed.count,
            hashedBytes: hashed.bytes,
            cachedBytes: cached.bytes,
            uploadedBytes: uploadedBytes,
            estimatedBytes: estimate.bytes,
            secondsRemaining: estimate.seconds
        )
    }

    /// Vu réellement : `|`, `/`, `-`, `\`, et `*` à la toute dernière ligne,
    /// quand l'upload est terminé.
    private static let rotationMarkers: Set<Character> = ["|", "/", "-", "\\", "*"]

    /// « 7 hashing » → 7. Rien d'autre ne doit suivre le nombre.
    private static func parseCount(_ field: String, suffix: String) -> Int? {
        guard field.hasSuffix(suffix) else { return nil }
        return Int(field.dropLast(suffix.count))
    }

    /// « 7 hashed (131.1 KB) » → (7, 131 100). Le compte et le volume entre
    /// parenthèses doivent tous les deux se lire : l'un manquant rend toute
    /// la ligne illisible, jamais un des deux avec un zéro de repli pour
    /// l'autre.
    private static func parseCountAndSize(
        _ field: String, suffix: String
    ) -> (count: Int, bytes: Int64)? {
        guard field.hasSuffix(")"), let openParen = field.firstIndex(of: "(") else { return nil }
        let countPart = String(field[field.startIndex..<openParen])
        guard countPart.hasSuffix(suffix + " ") else { return nil }
        guard let count = Int(countPart.dropLast(suffix.count + 1)) else { return nil }

        let sizePart = String(field[field.index(after: openParen)..<field.index(before: field.endIndex)])
        guard let bytes = parseSize(sizePart) else { return nil }
        return (count, bytes)
    }

    /// « uploaded 0 B » → 0. « uploaded 215.2 MB » → 215 200 000.
    private static func parseUploaded(_ field: String) -> Int64? {
        let prefix = "uploaded "
        guard field.hasPrefix(prefix) else { return nil }
        return parseSize(String(field.dropFirst(prefix.count)))
    }

    /// « estimating... » → (nil, nil). Le total est inconnu, et `nil` est
    /// l'état à afficher — pas 0, qui se lirait comme une source vide.
    ///
    /// « estimated 240 MB (97.1%) 0s left » → (240 000 000, 0). Le
    /// pourcentage entre parenthèses est validé — un signe qu'il faut lire
    /// jusqu'au bout pour ne pas confondre une ligne bien formée avec une
    /// ligne tronquée juste après le volume — mais pas conservé : la
    /// fraction affichée se recalcule depuis `hashedBytes` et `cachedBytes`,
    /// voir ``BackupProgress/fraction``.
    ///
    /// Le temps restant peut manquer entièrement (observé sur les gros
    /// volumes) : `remainder` vide après la parenthèse fermante rend un
    /// `estimatedBytes` connu et un `secondsRemaining` nil, pas une ligne
    /// refusée.
    private static func parseEstimate(
        _ field: String
    ) -> (bytes: Int64?, seconds: TimeInterval?)? {
        if field == "estimating..." { return (nil, nil) }

        let prefix = "estimated "
        guard field.hasPrefix(prefix) else { return nil }
        let rest = field.dropFirst(prefix.count)

        guard let openParen = rest.firstIndex(of: "(") else { return nil }
        let sizePart = rest[rest.startIndex..<openParen]
        guard sizePart.hasSuffix(" "), let estimatedBytes = parseSize(String(sizePart.dropLast()))
        else { return nil }

        let afterOpen = rest[rest.index(after: openParen)...]
        guard let closeParen = afterOpen.firstIndex(of: ")") else { return nil }
        let percentPart = afterOpen[afterOpen.startIndex..<closeParen]
        guard percentPart.hasSuffix("%"), Double(percentPart.dropLast()) != nil else { return nil }

        let remainder = afterOpen[afterOpen.index(after: closeParen)...]
        if remainder.isEmpty { return (estimatedBytes, nil) }
        guard remainder.hasPrefix(" ") else { return nil }
        guard let seconds = parseDuration(String(remainder.dropFirst())) else { return nil }
        return (estimatedBytes, seconds)
    }

    /// « 131.1 KB » → 131 100. Les unités sont des puissances de 1000, comme
    /// l'affichage de Kopia — mesuré : une source de 240 000 000 octets
    /// s'affiche « 240 MB », pas « 228,9 MB ». Une unité inconnue (donc une
    /// ligne qu'on ne connaît pas) rend `nil`, jamais une supposition.
    private static func parseSize(_ text: String) -> Int64? {
        // `Character(" ")` explicite : un séparateur littéral serait sinon
        // ambigu entre le `split(separator:)` historique et celui qui prend
        // un `RegexComponent`, les deux acceptant un littéral de chaîne.
        let parts = text.split(separator: Character(" "))
        guard parts.count == 2, let value = Double(parts[0]) else { return nil }
        let multiplier: Double
        switch parts[1] {
        case "B": multiplier = 1
        case "KB": multiplier = 1_000
        case "MB": multiplier = 1_000_000
        case "GB": multiplier = 1_000_000_000
        default: return nil
        }
        return Int64((value * multiplier).rounded())
    }

    /// « 0s left », « 13m30s left », « 2h5m left » → des secondes. Les trois
    /// composantes sont optionnelles et doivent apparaître dans cet ordre ;
    /// au moins une doit être présente, et rien ne doit rester après la
    /// dernière lue — sinon la ligne est mal formée et ne doit rien affirmer.
    private static func parseDuration(_ text: String) -> TimeInterval? {
        guard text.hasSuffix(" left") else { return nil }
        var remainder = text.dropLast(" left".count)
        guard !remainder.isEmpty else { return nil }

        var seconds: Double = 0
        var consumedAny = false

        if let hIndex = remainder.firstIndex(of: "h") {
            guard let hours = Double(remainder[remainder.startIndex..<hIndex]) else { return nil }
            seconds += hours * 3_600
            remainder = remainder[remainder.index(after: hIndex)...]
            consumedAny = true
        }
        if let mIndex = remainder.firstIndex(of: "m") {
            guard let minutes = Double(remainder[remainder.startIndex..<mIndex]) else { return nil }
            seconds += minutes * 60
            remainder = remainder[remainder.index(after: mIndex)...]
            consumedAny = true
        }
        if let sIndex = remainder.firstIndex(of: "s") {
            guard let secs = Double(remainder[remainder.startIndex..<sIndex]) else { return nil }
            seconds += secs
            remainder = remainder[remainder.index(after: sIndex)...]
            consumedAny = true
        }

        guard consumedAny, remainder.isEmpty else { return nil }
        return seconds
    }
}
