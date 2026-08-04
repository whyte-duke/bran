import Foundation

/// `String → MeetWindowSignal?`. Pure, synchrone, sans dépendance système.
///
/// Deux règles d'acceptation, volontairement conservatrices — un faux positif
/// enregistre une réunion qui n'existe pas, un faux négatif rate une réunion.
/// Le second est plus grave, mais le premier est plus insidieux : il fait
/// croire que le système marche.
public enum MeetTitleMatcher {
    /// `abc-defg-hij` — trois lettres, quatre, trois. Format stable de Google Meet.
    /// Propriété calculée et non `static let` : `Regex` n'est pas `Sendable`.
    /// Le littéral est compilé à la compilation, la construction est négligeable
    /// face à un tic de 5 s.
    private static var meetCodePattern: Regex<(Substring, Substring)> {
        /\b([a-z]{3}-[a-z]{4}-[a-z]{3})\b/
    }

    /// Titres qui contiennent « Meet » sans qu'une réunion soit en cours.
    /// La page d'accueil de Meet en est l'exemple canonique.
    private static let lobbyTitles: Set<String> = [
        "google meet",
        "meet",
        "meet - google meet",
        "google meet - accueil",
    ]

    /// Les tirets que Chrome, Safari et Meet utilisent indifféremment.
    private static let dashes: Set<Character> = ["-", "\u{2013}", "\u{2014}"]

    public static func signal(from rawTitle: String, owningApplication: String? = nil) -> MeetWindowSignal? {
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)

        // Titre vide : autorisation Enregistrement de l'écran absente, pas une réunion.
        guard title.isEmpty == false else { return nil }

        let normalized = title.lowercased()
        guard lobbyTitles.contains(normalized) == false else { return nil }

        let code = meetCode(in: normalized)

        // Règle 1 — un code de réunion présent est une preuve suffisante.
        // Règle 2 — le titre commence par « Meet <tiret> … » (réunion nommée,
        // sans code visible dans le titre de l'onglet).
        // Règle 3 — le titre se TERMINE par « <tiret> Google Meet ». Le suffixe
        // est ce qui distingue « Réunion équipe - Google Meet » (réunion) de
        // « Démarrer avec Google Meet - Documentation » (article de blog).
        //
        // Les règles 2 et 3 sont provisoires : elles reposent sur des formats de
        // titre supposés. `BranSpike titles` existe pour les remplacer par des
        // formats mesurés sur une vraie réunion.
        guard code != nil || startsWithMeetPrefix(normalized) || endsWithGoogleMeetSuffix(normalized) else {
            return nil
        }

        return MeetWindowSignal(
            windowTitle: title,
            meetCode: code,
            owningApplication: owningApplication
        )
    }

    /// Raccourci booléen, pour les tests table-driven.
    public static func isMeeting(_ rawTitle: String) -> Bool {
        signal(from: rawTitle) != nil
    }

    public static func meetCode(in text: String) -> String? {
        text.lowercased().firstMatch(of: meetCodePattern).map { String($0.output.1) }
    }

    private static func startsWithMeetPrefix(_ normalized: String) -> Bool {
        guard normalized.hasPrefix("meet") else { return false }

        let rest = normalized.dropFirst("meet".count).drop(while: \.isWhitespace)
        guard let separator = rest.first, dashes.contains(separator) else { return false }

        let remainder = rest.dropFirst().trimmingCharacters(in: .whitespaces)
        return remainder.isEmpty == false
    }

    private static func endsWithGoogleMeetSuffix(_ normalized: String) -> Bool {
        guard normalized.hasSuffix("google meet") else { return false }

        let head = normalized.dropLast("google meet".count).trimmingCharacters(in: .whitespaces)
        guard let separator = head.last, dashes.contains(separator) else { return false }

        return head.dropLast().trimmingCharacters(in: .whitespaces).isEmpty == false
    }
}
