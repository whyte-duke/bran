import Foundation

/// Répare les substitutions typographiques que la reconnaissance introduit
/// dans du code.
///
/// **Mesuré sur une vraie capture de `DictationMachine.swift` : 2,4 % d'erreur
/// avant, 0,7 % après.** Soixante-dix pour cent des erreurs restantes sur du
/// Swift tenaient à une seule confusion :
///
/// ```
/// case .idle, .failed: false      →  case •idle, •failed: false
/// case .capturing, .pasting: true →  case •capturing, •pasting: true
/// ```
///
/// Le moteur voit une puce là où il y a un point. C'est systématique, donc
/// réparable — contrairement aux confusions de glyphes voisins.
///
/// **Ce que cette table ne fait délibérément pas.** Les autres erreurs mesurées
/// sont `ls` → `1s`, `wc -l` → `wc -1`, `drwxr-xr-x` → `drwxr-xI-x`,
/// `50b0b89` → `50bøb89`. On pourrait être tenté de les corriger aussi. Il ne
/// faut pas :
///
/// - `1s` est un nom de fichier valide, et `wc -1` une option plausible ;
/// - une correction qui se trompe produit du texte **faux mais crédible**, que
///   vous colleriez sans le voir. Une erreur visible vaut mieux qu'une erreur
///   invisible, surtout dans du code qu'on exécute.
///
/// Chaque règle ci-dessous porte donc la même garantie : le caractère de gauche
/// **n'a aucune raison d'exister** dans du code ou une sortie de terminal.
///
/// En prose c'est l'inverse — « l'échéance » et « — » sont corrects — d'où le
/// verrouillage par `LayoutMode`.
public enum CharacterFixer {

    struct Rule: Sendable {
        let wrong: Character
        let right: String
        let why: String
    }

    /// Les règles, avec la raison de chacune. La colonne « pourquoi » n'est pas
    /// décorative : elle est le critère d'admission d'une future règle.
    static let rules: [Rule] = [
        Rule(wrong: "•", right: ".", why: "puce lue à la place d'un point — mesuré sur .idle et .failed"),
        Rule(wrong: "·", right: ".", why: "point médian, même cause"),
        Rule(wrong: "‧", right: ".", why: "point médian étroit"),
        Rule(wrong: "“", right: "\"", why: "guillemet ouvrant typographique — inexistant en code"),
        Rule(wrong: "”", right: "\"", why: "guillemet fermant typographique"),
        Rule(wrong: "„", right: "\"", why: "guillemet bas"),
        Rule(wrong: "‘", right: "'", why: "apostrophe typographique ouvrante"),
        Rule(wrong: "’", right: "'", why: "apostrophe typographique fermante"),
        Rule(wrong: "‹", right: "<", why: "chevron simple"),
        Rule(wrong: "›", right: ">", why: "chevron simple"),
        Rule(wrong: "—", right: "--", why: "tiret cadratin : un double tiret d'option lu comme un seul trait"),
        Rule(wrong: "–", right: "-", why: "tiret demi-cadratin"),
        Rule(wrong: "−", right: "-", why: "signe moins mathématique"),
        Rule(wrong: "…", right: "...", why: "points de suspension agglomérés"),
        Rule(wrong: "×", right: "*", why: "signe multiplier lu à la place d'une étoile"),
        Rule(wrong: "\u{00A0}", right: " ", why: "espace insécable : casse un découpage d'arguments"),
    ]

    private static let table: [Character: String] = Dictionary(
        uniqueKeysWithValues: rules.map { ($0.wrong, $0.right) }
    )

    /// Applique les règles, **uniquement** en mode chasse fixe.
    ///
    /// En `.prose`, le texte est rendu tel quel : corriger « l'échéance » en
    /// « l'échéance » avec une apostrophe droite abîmerait un texte correct.
    public static func fix(_ text: String, layout: LayoutMode) -> String {
        guard layout == .monospaced else { return text }
        guard text.contains(where: { table[$0] != nil }) else { return text }

        var out = ""
        out.reserveCapacity(text.count)
        for character in text {
            out += table[character] ?? String(character)
        }
        return out
    }

    /// Combien de caractères cette passe a remplacés. Affiché dans le détail
    /// d'une capture : savoir que huit corrections ont eu lieu invite à relire.
    public static func repairCount(_ text: String, layout: LayoutMode) -> Int {
        guard layout == .monospaced else { return 0 }
        return text.reduce(0) { $0 + (table[$1] != nil ? 1 : 0) }
    }
}
