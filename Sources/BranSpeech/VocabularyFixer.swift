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
    ///
    /// **Un seul passage sur le texte, et non un passage par règle.** Ce n'est
    /// pas une optimisation : c'est ce qui rend vraie la promesse écrite en tête
    /// de ce fichier.
    ///
    /// La version précédente réappliquait chaque règle au texte **déjà
    /// corrigé**, si bien qu'une règle courte remangeait ce qu'une règle longue
    /// venait d'écrire. L'exemple de la documentation tombait sur lui-même :
    /// avec « google meet » → « Google Meet » et « meet » → « réunion », la
    /// longue passait bien la première, puis la courte relisait sa sortie et
    /// rendait « Google réunion ». Le test qui prétendait geler la propriété ne
    /// pouvait pas la voir — il corrigeait « meet » en « Meet », donc la seconde
    /// substitution rendait le même texte, et la panne se cachait derrière une
    /// coïncidence.
    ///
    /// Ici, ce qu'une règle écrit est un **résultat** : le curseur saute
    /// par-dessus, et plus aucune règle ne le regarde. À chaque position, c'est
    /// la première règle qui correspond qui gagne, et l'ordre est celui des
    /// règles longues d'abord — la priorité est donc décidée à un seul endroit,
    /// pour de bon.
    ///
    /// **À longueur égale, la règle déclarée en premier gagne.** `sorted(by:)`
    /// n'est pas stable en Swift : deux règles de même longueur pour la même
    /// aiguille rendaient un résultat qui dépendait de l'implémentation du tri.
    /// L'index de déclaration départage.
    public func apply(to text: String) -> String {
        let usable = rules.filter(\.isUsable)
        guard usable.isEmpty == false else { return text }

        let ordered = usable.enumerated()
            .sorted { left, right in
                left.element.heard.count == right.element.heard.count
                    ? left.offset < right.offset
                    : left.element.heard.count > right.element.heard.count
            }
            .map(\.element)

        var result = ""
        var index = text.startIndex

        while index < text.endIndex {
            if let hit = Self.match(ordered, in: text, at: index) {
                result += hit.replacement
                index = hit.end
                continue
            }
            result.append(text[index])
            index = text.index(after: index)
        }
        return result
    }

    /// La première règle qui correspond **exactement à cette position**, avec
    /// ses deux frontières de mot. `nil` si aucune.
    ///
    /// `.anchored` est ce qui change tout par rapport à une recherche libre :
    /// on ne demande pas « où cette aiguille apparaît-elle ensuite ? » mais
    /// « commence-t-elle ici ? ». C'est la question qu'il faut poser quand on
    /// balaie le texte une seule fois pour toutes les règles à la fois.
    private static func match(
        _ rules: [Rule], in haystack: String, at index: String.Index
    ) -> (replacement: String, end: String.Index)? {
        // Une frontière gauche manquante interdit toutes les règles d'un coup :
        // c'est le filtre qui rend le balayage bon marché, puisqu'il élimine
        // toutes les positions à l'intérieur d'un mot sans essayer une seule
        // aiguille.
        let startsWord = index == haystack.startIndex
            || isWordCharacter(haystack[haystack.index(before: index)]) == false
        guard startsWord else { return nil }

        for rule in rules {
            guard let found = haystack.range(
                of: rule.heard,
                options: [.caseInsensitive, .diacriticInsensitive, .anchored],
                range: index..<haystack.endIndex
            ), found.isEmpty == false else { continue }

            let endsWord = found.upperBound == haystack.endIndex
                || isWordCharacter(haystack[found.upperBound]) == false
            guard endsWord else { continue }

            return (rule.written, found.upperBound)
        }
        return nil
    }

    /// Remplace toutes les occurrences de `needle` délimitées par des frontières
    /// de mot, sans tenir compte de la casse ni des accents.
    ///
    /// La comparaison ignore les diacritiques : Parakeet hésite entre « resume »
    /// et « résumé », et on veut attraper les deux.
    ///
    /// Le cas d'une seule règle, exprimé avec le balayage ci-dessus : deux
    /// moteurs de substitution pour un même produit auraient fini par corriger
    /// deux textes différemment.
    static func replace(_ needle: String, with replacement: String, in haystack: String) -> String {
        VocabularyFixer(rules: [Rule(heard: needle, written: replacement)]).apply(to: haystack)
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }
}
