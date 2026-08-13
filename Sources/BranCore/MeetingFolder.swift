import Foundation

/// Comment un rendez-vous s'écrit sur le disque : **un dossier par réunion**.
///
/// Avant, tout vivait à plat dans la racine de stockage, sous des noms d'UUID :
///
/// ```
/// Recordings/
///     5FDF7BDD-AA02-4A45-9833-58B7B3C7AA5B.mp4      2,5 Go
///     5FDF7BDD-AA02-4A45-9833-58B7B3C7AA5B.json
///     5FDF7BDD-AA02-4A45-9833-58B7B3C7AA5B-seg000.mp4
/// ```
///
/// Rien là-dedans ne se lit. On ne peut pas savoir de quelle réunion il s'agit,
/// ni ce qui va ensemble, ni ce qui est un reste. Et l'audio préparé pour le CRM
/// n'existait nulle part : il était fabriqué dans le dossier temporaire, envoyé,
/// puis effacé — donc impossible à écouter, à vérifier, ou à renvoyer à la main
/// le jour où le CRM le refuse.
///
/// Désormais :
///
/// ```
/// Recordings/
///     2026-08-11 09h57 — SA SERMATEC/
///         2026-08-11 09h57 — SA SERMATEC.mp4     la vidéo compressée
///         2026-08-11 09h57 — SA SERMATEC.m4a     l'audio prêt pour le CRM
///         Fiche.json                             les métadonnées de bran
/// ```
///
/// **Trois décisions, et leurs raisons.**
///
/// *Le contenu est trouvé par extension, pas par nom.* Le dossier peut donc être
/// renommé à la main dans le Finder sans rien casser : c'est le geste naturel
/// quand on classe des réunions, et une bibliothèque qui perdrait un
/// enregistrement parce qu'on l'a mieux nommé serait une bibliothèque qu'on
/// n'ose plus toucher.
///
/// *Le nom des fichiers reprend celui du dossier.* Sorti de son dossier — glissé
/// dans un mail, déposé dans un Drive — le fichier continue de dire quelle
/// réunion il est. C'est exactement ce qu'on fait d'un enregistrement, et
/// `reunion.mp4` aurait rendu chaque envoi anonyme.
///
/// *La fiche, elle, porte un nom fixe.* C'est le marqueur qui distingue un
/// dossier de réunion de tous les autres dossiers que bran pose dans la même
/// racine — `Dictées`, `Captures`, `Veille`, `Clipboard` —, dont certains
/// contiennent eux aussi des `.json`. Reconnaître un dossier de réunion à
/// « il contient un `.json` qui se décode » les aurait tous avalés.
public enum MeetingFolder {

    /// Le marqueur. Un dossier est un dossier de réunion si, et seulement si, il
    /// contient ce fichier.
    ///
    /// En français comme les dossiers voisins, qui sont eux aussi montrés à
    /// l'utilisateur dans le Finder — et qui s'appellent `Dictées` et `Veille`,
    /// pas `Dictations` et `Watch`.
    public static let sidecarName = "Fiche.json"

    public static let videoExtension = "mp4"
    public static let audioExtension = "m4a"

    /// Suffixe des morceaux intermédiaires — `<base>-seg000.mp4`.
    ///
    /// Ils ne sont jamais le fichier final : ce sont les pièces détachées d'une
    /// session, effacées après la fusion. Les reconnaître au nom évite de
    /// présenter trois morceaux comme trois réunions.
    public static let segmentMarker = "-seg"

    // MARK: - Noms

    /// L'horodatage d'une réunion, tel qu'il ouvre le nom du dossier :
    /// `2026-08-11 09h57`.
    ///
    /// **Ni `DateFormatter` ni `Date.FormatStyle`, et c'est délibéré.** Les deux
    /// sont sensibles à la langue et à la région : le même instant s'écrit
    /// `11/08/2026` ici et `8/11/2026` ailleurs, et un nom de fichier qui change
    /// de forme selon les réglages du Mac rend le tri alphabétique — le seul tri
    /// qu'offre le Finder sur une colonne de noms — inutilisable dès la première
    /// exportation. L'ordre année-mois-jour est choisi pour que ce tri-là soit
    /// l'ordre chronologique.
    ///
    /// `h` plutôt que `:` parce que le Finder affiche un `:` comme un `/`, et
    /// que `2026-08-11 09/57` ne veut plus rien dire.
    ///
    /// Le calendrier est celui de la machine : une réunion de 9 h 57 doit
    /// s'appeler 9 h 57 pour celui qui l'a tenue.
    public static func stamp(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(
            format: "%04d-%02d-%02d %02dh%02d",
            parts.year ?? 0, parts.month ?? 1, parts.day ?? 1,
            parts.hour ?? 0, parts.minute ?? 0
        )
    }

    /// Le nom du dossier d'une réunion : l'horodatage, puis le titre s'il y en a
    /// un.
    ///
    /// Le titre arrive souvent **après** le début — on nomme une réunion pendant
    /// qu'elle tourne, ou le CRM le fournit à l'arrivée. Le dossier naît donc
    /// sous son seul horodatage, et se renomme une fois, à la fin, quand le titre
    /// est connu. L'horodatage reste en tête dans les deux cas : c'est lui qui
    /// rend le dossier trouvable, et il ne change jamais.
    public static func name(startedAt: Date, title: String?) -> String {
        guard let title = title.flatMap(sanitized) else { return stamp(startedAt) }
        return "\(stamp(startedAt)) — \(title)"
    }

    /// Le nom d'un morceau brut, `<base>-seg000.mp4`.
    ///
    /// Zéro-rempli sur trois chiffres pour que l'ordre alphabétique soit l'ordre
    /// d'écriture : `seg9` et `seg10` se seraient croisés, et la fusion aurait
    /// recollé la réunion dans le désordre après dix pauses.
    public static func segmentName(base: String, index: Int) -> String {
        "\(base)\(segmentMarker)\(String(format: "%03d", index)).\(videoExtension)"
    }

    /// Ce nom désigne-t-il un morceau brut plutôt qu'un fichier final ?
    ///
    /// **La forme est exigée en entier, et ce n'est pas de la pédanterie.** Un
    /// simple `name.contains("-seg")` classait comme morceau tout fichier final
    /// dont le titre en contient la suite de lettres : « Point pré-segment »,
    /// « Bilan anti-ségrégation », « Réunion Bio-Segma ». Les morceaux étant ce
    /// que la bibliothèque exclut de sa liste et ce que le post-traitement
    /// efface, une réunion ainsi nommée aurait disparu de l'écran — et, dans le
    /// pire enchaînement, du disque.
    ///
    /// La vraie forme est `<base>-segNNN.mp4`, avec exactement trois chiffres,
    /// juste avant l'extension. C'est celle que `segmentName(base:index:)`
    /// produit, et rien d'autre ne doit passer.
    public static func isSegment(_ name: String) -> Bool {
        let suffix = ".\(videoExtension)"
        guard name.hasSuffix(suffix) else { return false }

        let stem = name.dropLast(suffix.count)
        guard stem.count >= segmentMarker.count + 3 else { return false }

        let digits = stem.suffix(3)
        guard digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber) else { return false }

        return stem.dropLast(3).hasSuffix(segmentMarker)
    }

    // MARK: - Assainissement

    /// Longueur maximale du titre dans le nom du dossier.
    ///
    /// Le plafond réel d'APFS est de 255 octets par composant, et on en est loin.
    /// Celui-ci est un plafond de lisibilité : au-delà, le Finder tronque au
    /// milieu, la colonne de la bibliothèque aussi, et un titre qu'on ne peut
    /// plus lire ne classe plus rien. Un nom de RDV du CRM tient très en dessous.
    private static let titleLimit = 60

    /// Ce qui n'a rien à faire à la fin d'un nom : espaces, tirets de toutes
    /// longueurs — celui qui sépare l'horodatage du titre est déjà là —, et
    /// points, que le Finder lit comme le début d'une extension.
    private static let trailingNoise = CharacterSet(charactersIn: " .-–—_")

    /// Le titre tel qu'il peut entrer dans un nom de fichier, ou `nil` s'il n'en
    /// reste rien.
    ///
    /// **Rendre `nil` plutôt qu'une chaîne vide est le point important** : un
    /// titre fait uniquement d'espaces, ou de caractères tous refusés, doit
    /// produire un dossier `2026-08-11 09h57` et non `2026-08-11 09h57 — `, qui
    /// se termine sur un tiret et un blanc que le Finder rognerait de toute
    /// façon.
    ///
    /// Ce qui est retiré, et pourquoi :
    /// - `/` est le séparateur de chemin : le laisser passer fabriquerait un
    ///   sous-dossier au lieu d'un nom ;
    /// - `:` est le séparateur historique de HFS, et le Finder l'affiche
    ///   **encore** comme un `/` ;
    /// - les caractères de contrôle et les sauts de ligne n'ont pas d'affichage,
    ///   donc un nom qui en contient est un nom qu'on ne peut pas retaper ;
    /// - un point en tête cacherait le dossier.
    ///
    /// Le reste — accents, apostrophes, esperluettes — est **gardé**. macOS les
    /// accepte, et « Closing L'Étoile & Fils » est le nom que l'utilisateur a
    /// écrit ; le déformer pour se conformer à des règles Windows qui ne
    /// s'appliquent pas ici lui ferait chercher une réunion sous un nom qui n'est
    /// pas le sien.
    public static func sanitized(_ title: String) -> String? {
        var cleaned = ""
        var lastWasSpace = false

        for character in title {
            let isForbidden = character == "/" || character == ":"
                || character.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }

            // Un caractère refusé devient une espace plutôt que rien :
            // « Castral/Orpheo » doit se lire « Castral Orpheo », pas
            // « CastralOrpheo ».
            let isSpace = isForbidden || character.isWhitespace
            if isSpace {
                if lastWasSpace == false, cleaned.isEmpty == false { cleaned.append(" ") }
                lastWasSpace = true
                continue
            }

            cleaned.append(character)
            lastWasSpace = false
        }

        // Les points de tête sont retirés un par un : `..` est aussi dangereux
        // que `.`, et il faut les deux passages pour arriver au bout de `...`.
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }

        var trimmed = cleaned.trimmingCharacters(in: .whitespaces)
        if trimmed.count > titleLimit {
            // **La coupe cherche d'abord une espace.** Tronquer au caractère près
            // fabrique des noms qui s'arrêtent au milieu d'un mot — « Closing
            // ORPHEO renouvellement contr » —, et un nom tronqué au milieu d'un
            // mot se lit comme un fichier abîmé. On ne recule que jusqu'aux trois
            // quarts du plafond : au-delà, il n'y avait pas d'espace, le titre est
            // un bloc, et le couper net vaut mieux que de le réduire à rien.
            let hard = String(trimmed.prefix(titleLimit))
            let floor = hard.index(hard.startIndex, offsetBy: titleLimit * 3 / 4)
            if let space = hard.lastIndex(of: " "), space >= floor {
                trimmed = String(hard[hard.startIndex..<space])
            } else {
                trimmed = hard
            }
        }

        // Les bornes de fin, après la troncature et pas avant : c'est elle qui
        // peut laisser un tiret orphelin. Un titre qui vaut « — » produirait
        // sinon « 2026-08-11 09h57 — — », et « RDV. » garderait un point final
        // que le Finder traite comme une extension vide.
        trimmed = trimmed.trimmingCharacters(in: trailingNoise)

        return trimmed.isEmpty ? nil : trimmed
    }
}
