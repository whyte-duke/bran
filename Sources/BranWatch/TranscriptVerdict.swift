import Foundation

/// Lit dans une transcription Claude Code **si la session attend**, sans jamais
/// charger une ligne de conversation.
///
/// **Le piège qu'on a évité, mesuré.** La première idée était de regarder la
/// date de modification du fichier : gratuite, un simple `stat()`. Comptage sur
/// une session réelle de 226 lignes :
///
/// ```
///   95 enregistrements type=assistant
///      ├── 93 × stop_reason = tool_use   ← « je travaille »
///      └──  2 × stop_reason = end_turn   ← « j'ai fini, à toi »
/// ```
///
/// Le fichier est réécrit surtout *pendant* le travail. Sa date de modification
/// est donc un capteur d'activité, pas un capteur d'attente — exactement
/// l'ambiguïté du mouvement de pixels, qu'il était censé lever.
///
/// **Le bon signal est ordinal, pas temporel** : le *dernier* enregistrement
/// `assistant` du fichier est-il un `end_turn` ? Si oui la session attend, si
/// c'est un `tool_use` elle travaille. Binaire, certain, insensible à l'horloge
/// — donc immunisé au correctif CR-2 (les durées fausses après une veille).
///
/// **CR-3 — aucun contenu n'est jamais lu.** L'analyse se fait par recherche de
/// sous-chaîne sur des marqueurs, jamais par décodage JSON : décoder chargerait
/// le corps des messages, et ces fichiers contiennent des conversations
/// entières, clés d'API comprises. `TranscriptVerdict` ne peut pas rendre du
/// contenu : son type ne contient aucun champ qui en accueille.
public enum TranscriptVerdict {

    public struct Reading: Equatable, Sendable {
        public let state: LaneState
        public let sessionID: String?
        public let workingDirectory: String?
        public let branch: String?
        /// Horodatage brut du dernier tour terminé, tel qu'écrit dans le fichier.
        public let endedAt: String?

        public init(
            state: LaneState,
            sessionID: String? = nil,
            workingDirectory: String? = nil,
            branch: String? = nil,
            endedAt: String? = nil
        ) {
            self.state = state
            self.sessionID = sessionID
            self.workingDirectory = workingDirectory
            self.branch = branch
            self.endedAt = endedAt
        }
    }

    static let assistantMarker = "\"type\":\"assistant\""
    static let endTurnMarker = "\"stop_reason\":\"end_turn\""

    /// Rend un verdict à partir de la **queue brute** d'une transcription.
    ///
    /// **Le découpage en lignes est ici, et pas chez l'appelant, parce qu'il a
    /// une règle et que cette règle mérite d'être vérifiée.** L'appelant lisait
    /// 256 Kio, les décodait d'un bloc en `String`, puis appelait `split` — qui
    /// avance par **graphèmes**. Deux défauts pour le prix d'un :
    ///
    /// - le coût, mesuré au profil : l'essentiel du temps du veilleur au repos
    ///   passait à chercher des frontières de caractère dont personne n'a besoin
    ///   pour trouver des `\n` ;
    /// - la correction, plus grave : `String(data:encoding:.utf8)` rend `nil`
    ///   dès que la coupure de la queue tombe au milieu d'un caractère
    ///   multi-octets. Le fichier entier disparaissait alors du veilleur, sans
    ///   un mot, et la voie avec lui — au hasard des accents présents à 256 Kio
    ///   de la fin.
    ///
    /// Couper les octets sur `0x0A` puis décoder chaque ligne rend exactement le
    /// même découpage : l'UTF-8 réserve le bit de poids fort aux octets de
    /// continuation, donc un `\n` ne peut jamais apparaître à l'intérieur d'un
    /// caractère. Et la seule ligne qui puisse être coupée est la première, que
    /// `tailIsTruncated` jette déjà.
    ///
    /// - Parameter utf8Tail: les derniers octets du fichier.
    /// - Parameter tailIsTruncated: vrai si la lecture a commencé en plein
    ///   milieu du fichier, auquel cas la première ligne est un fragment. **CR-6.**
    public static func read(utf8Tail: Data, tailIsTruncated: Bool) -> Reading {
        let lines: [String] = utf8Tail.withUnsafeBytes { raw in
            raw.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
                .map { String(decoding: $0, as: UTF8.self) }
        }
        return read(lines: lines, tailIsTruncated: tailIsTruncated)
    }

    /// Rend un verdict à partir des dernières lignes d'une transcription.
    ///
    /// - Parameter lines: les lignes lues, dans l'ordre du fichier.
    /// - Parameter tailIsTruncated: vrai si la lecture a commencé en plein
    ///   milieu du fichier, auquel cas la première ligne est un fragment. **CR-6.**
    public static func read(lines: [String], tailIsTruncated: Bool) -> Reading {
        var usable = lines
        if tailIsTruncated, usable.isEmpty == false { usable.removeFirst() }

        // CR-6 : le fichier est écrit en continu par une session vivante, donc
        // la toute dernière ligne peut être coupée au milieu. Une ligne qui ne
        // ferme pas son objet est ignorée — on remonte d'un cran, on ne plante
        // pas et on ne fait pas disparaître la voie.
        if let last = usable.last, last.hasSuffix("}") == false { usable.removeLast() }

        guard let latest = usable.last(where: { topLevel("type", equals: "assistant", in: $0) })
        else {
            return Reading(state: .unknown)
        }

        let identity = self.identity(in: usable)
        let waiting = nested("message", "stop_reason", in: latest) == "end_turn"

        return Reading(
            state: waiting ? .waiting : .working,
            sessionID: identity.sessionID,
            workingDirectory: identity.workingDirectory,
            branch: identity.branch,
            endedAt: waiting ? field("timestamp", in: latest) : nil
        )
    }

    /// L'identité est cherchée sur *n'importe quelle* ligne, pas seulement la
    /// dernière : `cwd` et `gitBranch` sont présents partout, et la dernière
    /// ligne utile peut être un enregistrement qui ne les porte pas.
    private static func identity(
        in lines: [String]
    ) -> (sessionID: String?, workingDirectory: String?, branch: String?) {
        for line in lines.reversed() {
            guard let directory = field("cwd", in: line) else { continue }
            return (field("sessionId", in: line), directory, field("gitBranch", in: line))
        }
        return (nil, nil, nil)
    }

    /// **La vivacité, et pourquoi elle n'est pas optionnelle.**
    ///
    /// Une transcription dont le dernier tour est terminé ressemble exactement à
    /// une session qui attend. Sauf si le processus est mort : alors elle
    /// n'attend rien, elle est finie.
    ///
    /// Mesuré au premier essai sur une vraie session : dernier enregistrement
    /// `end_turn`, fichier touché quatorze minutes plus tôt, **et aucun
    /// processus `claude` en vie**. Un filtre fondé sur la date du fichier la
    /// laissait passer et bran aurait annoncé une attente inventée. Sur les 51
    /// transcriptions du dossier, 37 datent de plus d'une semaine : sans cette
    /// porte, la première alerte du produit aurait été un fantôme.
    ///
    /// Une session non vivante devient `stale` — sans nouvelles — et pas
    /// `waiting`. Elle reste visible, elle ne dérange personne.
    public static func gated(
        _ reading: Reading,
        liveWorkingDirectories: Set<String>
    ) -> Reading {
        guard reading.state == .waiting else { return reading }
        guard let directory = reading.workingDirectory,
              liveWorkingDirectories.contains(directory)
        else {
            return Reading(
                state: .stale,
                sessionID: reading.sessionID,
                workingDirectory: reading.workingDirectory,
                branch: reading.branch,
                endedAt: reading.endedAt
            )
        }
        return reading
    }

    /// Extrait une valeur de chaîne **au premier niveau** de l'enregistrement.
    ///
    /// **Pourquoi un balayage et pas un `range(of:)`.** La version naïve
    /// cherchait `"cwd":"` n'importe où dans la ligne, y compris dans le corps
    /// d'un message. Or les transcriptions de bran contiennent littéralement ces
    /// chaînes — celle de cette session en est pleine. Une conversation qui cite
    /// `"stop_reason":"end_turn"` aurait transformé un message utilisateur en
    /// fausse attente.
    ///
    /// Découper au préfixe avant `"message"` ne suffit pas : les clés sortent en
    /// ordre alphabétique, donc `sessionId`, `timestamp` et `type` arrivent
    /// **après** le corps du message. Il faut donc compter la profondeur.
    ///
    /// Toujours pas de décodage JSON, toujours pour CR-3 : on saute le contenu
    /// des chaînes sans jamais le retenir.
    static func field(_ name: String, in line: String) -> String? {
        scan(line) { key, value in key == name ? value : nil }
    }

    /// Vrai si la ligne porte, au premier niveau, la clé `name` avec la valeur
    /// `value`.
    static func topLevel(_ name: String, equals value: String, in line: String) -> Bool {
        scan(line) { key, found in key == name && found == value ? true : nil } ?? false
    }

    /// La valeur d'une clé située **dans un objet nommé du premier niveau** —
    /// typiquement `message.stop_reason`.
    ///
    /// Nécessaire pour la même raison que `field` : un message d'assistant dont
    /// le texte cite `"stop_reason":"end_turn"` — ce qui arrive dans ce dépôt
    /// précisément, puisqu'on y écrit sur le sujet — serait lu comme un tour
    /// terminé alors que la session appelle un outil.
    static func nested(_ outer: String, _ inner: String, in line: String) -> String? {
        var depth = 0
        var inString = false
        var escaped = false
        var token = ""
        var pendingKey: String?
        var expectingValue = false
        var insideOuter = false
        var outerDepth = 0

        for character in line {
            if escaped { escaped = false; if inString { token.append(character) }; continue }

            if inString {
                switch character {
                case "\\": escaped = true
                case "\"":
                    inString = false
                    let level = insideOuter ? 2 : 1
                    if depth == level {
                        if expectingValue, let key = pendingKey {
                            if insideOuter, key == inner { return token }
                            pendingKey = nil
                            expectingValue = false
                        } else {
                            pendingKey = token
                        }
                    }
                default: token.append(character)
                }
                continue
            }

            switch character {
            case "\"": inString = true; token = ""
            case "{", "[":
                if depth == 1, insideOuter == false, pendingKey == outer, expectingValue {
                    insideOuter = true
                    outerDepth = depth
                }
                depth += 1
                pendingKey = nil
                expectingValue = false
            case "}", "]":
                depth -= 1
                if insideOuter, depth <= outerDepth { insideOuter = false }
                pendingKey = nil
                expectingValue = false
            case ":": expectingValue = true
            case ",": pendingKey = nil; expectingValue = false
            default: break
            }
        }
        return nil
    }

    /// Balaye les paires clé/valeur de chaînes situées à la profondeur 1.
    ///
    /// S'arrête au premier résultat non nul rendu par `pick`. Rien n'est
    /// accumulé : les valeurs imbriquées ne sont jamais matérialisées, elles
    /// sont sautées caractère par caractère.
    static func scan<T>(_ line: String, _ pick: (String, String) -> T?) -> T? {
        var depth = 0
        var inString = false
        var escaped = false
        var token = ""
        var pendingKey: String?
        var expectingValue = false

        for character in line {
            if escaped { escaped = false; if inString { token.append(character) }; continue }

            if inString {
                switch character {
                case "\\": escaped = true
                case "\"":
                    inString = false
                    if depth == 1 {
                        if expectingValue, let key = pendingKey {
                            if let result = pick(key, token) { return result }
                            pendingKey = nil
                            expectingValue = false
                        } else {
                            pendingKey = token
                        }
                    }
                default: if depth == 1 { token.append(character) }
                }
                continue
            }

            switch character {
            case "\"": inString = true; token = ""
            case "{", "[": depth += 1; pendingKey = nil; expectingValue = false
            case "}", "]": depth -= 1; pendingKey = nil; expectingValue = false
            case ":": if depth == 1 { expectingValue = true }
            case ",": if depth == 1 { pendingKey = nil; expectingValue = false }
            default: break
            }
        }
        return nil
    }
}
