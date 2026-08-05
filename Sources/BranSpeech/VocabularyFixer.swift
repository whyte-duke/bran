import Foundation

/// Le rattrapage du vocabulaire métier.
///
/// Parakeet n'a jamais entendu le nom de votre entreprise, ni celui de vos
/// clients. Il écrira « castral » en minuscule, « SDR » en « s d r », et le nom
/// d'un prospect en trois mots. Une table de remplacement appliquée après coup
/// coûte quelques lignes et c'est, de loin, le plus gros gain de qualité perçue
/// de toute la fonctionnalité : on redicte chaque jour les vingt mêmes mots.
///
/// Trois précautions qui font la différence entre utile et pénible :
/// - **frontières de mots** — « SDR » ne doit pas transformer « sdrastvouïtié » ;
/// - **règles longues d'abord** — « google meet » doit gagner contre « meet » ;
/// - **aucune `Regex`** — elle n'est pas `Sendable`, et ce type traverse les
///   acteurs. Recherche manuelle, donc, et c'est aussi plus rapide.
public struct VocabularyFixer: Codable, Equatable, Sendable {

    public struct Rule: Codable, Equatable, Sendable, Identifiable {
        public var id: UUID
        /// Ce que le modèle écrit.
        public var heard: String
        /// Ce qu'il faut écrire à la place.
        public var written: String

        public init(id: UUID = UUID(), heard: String, written: String) {
            self.id = id
            self.heard = heard
            self.written = written
        }

        var isUsable: Bool {
            heard.trimmingCharacters(in: .whitespaces).isEmpty == false
                && written.trimmingCharacters(in: .whitespaces).isEmpty == false
        }
    }

    public var rules: [Rule]

    public init(rules: [Rule] = []) {
        self.rules = rules
    }

    /// Quelques termes que Parakeet écorche en français quel que soit le métier.
    /// Le vrai gain viendra des termes que vous ajouterez vous-même.
    ///
    /// « google, mais est » n'est pas inventé : c'est la faute exacte relevée
    /// sur la première mesure réelle, où « on se voit sur Google Meet à quatorze
    /// heures » est ressorti en « on se voit sur Google, mais est à 14h ». Le
    /// modèle entend un mot anglais court au milieu d'une phrase française et
    /// le rabat sur des mots français plausibles.
    public static let starter = VocabularyFixer(rules: [
        Rule(heard: "google, mais est", written: "Google Meet"),
        Rule(heard: "google mais est", written: "Google Meet"),
        Rule(heard: "google meet", written: "Google Meet"),
        Rule(heard: "gogole meet", written: "Google Meet"),
        Rule(heard: "c r m", written: "CRM"),
        Rule(heard: "crm", written: "CRM"),
        Rule(heard: "s d r", written: "SDR"),
        Rule(heard: "k p i", written: "KPI"),
        Rule(heard: "r d v", written: "RDV"),
        Rule(heard: "clauda code", written: "Claude Code"),
        Rule(heard: "claude code", written: "Claude Code"),
    ])

    /// Applique toutes les règles utilisables, les plus longues d'abord.
    public func apply(to text: String) -> String {
        var output = text
        let ordered = rules
            .filter(\.isUsable)
            .sorted { $0.heard.count > $1.heard.count }

        for rule in ordered {
            output = Self.replace(rule.heard, with: rule.written, in: output)
        }
        return output
    }

    /// Remplace toutes les occurrences de `needle` délimitées par des frontières
    /// de mot, sans tenir compte de la casse ni des accents.
    ///
    /// La comparaison ignore les diacritiques : Parakeet hésite entre « resume »
    /// et « résumé », et on veut attraper les deux.
    static func replace(_ needle: String, with replacement: String, in haystack: String) -> String {
        guard needle.isEmpty == false else { return haystack }

        var result = ""
        var index = haystack.startIndex

        while index < haystack.endIndex,
              let found = haystack.range(
                  of: needle,
                  options: [.caseInsensitive, .diacriticInsensitive],
                  range: index..<haystack.endIndex
              ) {

            let startsWord = found.lowerBound == haystack.startIndex
                || isWordCharacter(haystack[haystack.index(before: found.lowerBound)]) == false
            let endsWord = found.upperBound == haystack.endIndex
                || isWordCharacter(haystack[found.upperBound]) == false

            result += haystack[index..<found.lowerBound]
            result += (startsWord && endsWord) ? replacement : String(haystack[found])

            index = found.upperBound
            // Une aiguille qui ne consomme rien ferait une boucle infinie.
            if found.isEmpty { break }
        }

        result += haystack[index...]
        return result
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }
}
