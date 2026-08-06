import Foundation

/// **La clé de jour du journal**, `AAAA-MM-JJ`.
///
/// Elle décide de trois choses d'un coup : dans quel fichier une ligne est
/// écrite, quand les intervalles ouverts sont fermés, et — via
/// `WatchRetention.filesToPurge` — quel fichier est supprimé. Une erreur ici ne
/// se voit pas le jour même : elle se voit un mois plus tard, sur un journal
/// dont il manque des morceaux.
public enum WatchDay {

    /// La clé de jour, **dans le calendrier de l'utilisateur**.
    ///
    /// Fuseau local et non UTC : la journée de travail de quelqu'un se termine à
    /// minuit *chez lui*. Un journal coupé à 2 h du matin parce que le code
    /// pense en UTC serait incompréhensible à la relecture.
    ///
    /// Composé à la main plutôt qu'avec un `DateFormatter` : celui-ci suit les
    /// réglages régionaux, et rendrait `2026-08-06` en calendrier grégorien mais
    /// autre chose en calendrier bouddhiste ou japonais — des noms de fichiers
    /// qui ne se trient plus et une rétention qui ne reconnaît plus rien.
    public static func key(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0
        )
    }

    /// Le jour a-t-il changé depuis le fichier actuellement ouvert ?
    ///
    /// `nil` — aucun fichier ouvert — rend `false` : sans écriture en cours il
    /// n'y a rien à fermer, et répondre `true` ferait vider le registre à chaque
    /// tic avant la première ligne du jour.
    public static func changed(
        from openDay: String?,
        at date: Date,
        calendar: Calendar = .current
    ) -> Bool {
        guard let openDay else { return false }
        return openDay != key(for: date, calendar: calendar)
    }
}
