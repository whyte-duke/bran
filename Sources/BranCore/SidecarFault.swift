import Foundation

/// Pourquoi les métadonnées posées à côté d'un `.mp4` n'ont pas pu être lues.
///
/// Le sidecar vit à côté du fichier, et c'est un choix : déplacer le dossier, le
/// copier sur un autre Mac, le restaurer d'une sauvegarde — tout continue de
/// marcher parce que la bibliothèque se reconstruit en lisant le dossier. Le
/// revers est qu'un `.json` abîmé n'a aucun filet : il n'existe pas de seconde
/// copie en base. **Un décodage qui échoue mérite donc d'être dit, pas avalé.**
///
/// D'où la distinction que ce type porte, et qui est tout l'intérêt de
/// l'exercice : « pas de sidecar » est **normal** — un `.mp4` déposé à la main
/// dans le dossier doit apparaître dans la bibliothèque — alors qu'un sidecar
/// qui refuse de se décoder est un défaut, et une donnée peut-être encore
/// récupérable à la main si on prévient son propriétaire.
public enum SidecarFault: Error, Equatable, Sendable {

    /// Aucun fichier. Le cas normal, silencieux.
    case absent

    /// Le fichier est là, le système refuse de le lire — volume démonté,
    /// droits retirés, chemin devenu un dossier.
    case unreadable(String)

    /// Le fichier est là, se lit, et ne se décode pas.
    case corrupt(String)

    /// Classe une erreur survenue à la **lecture** des octets.
    ///
    /// Seule l'absence est banale ; tout le reste — un `EACCES`, un volume
    /// disparu — est un problème qui doit remonter. C'est la même distinction
    /// que le scan du dossier fait déjà entre « premier lancement » et
    /// « dossier illisible ».
    public static func reading(_ error: any Error) -> SidecarFault {
        let cocoa = error as NSError
        let missing = cocoa.domain == NSCocoaErrorDomain
            && (cocoa.code == NSFileReadNoSuchFileError || cocoa.code == NSFileNoSuchFileError)
        return missing ? .absent : .unreadable(cocoa.localizedDescription)
    }

    /// Classe une erreur survenue au **décodage** des octets déjà lus.
    public static func decoding(_ error: any Error) -> SidecarFault {
        .corrupt((error as NSError).localizedDescription)
    }

    /// Vrai quand il n'y a rien à signaler à qui que ce soit.
    public var isNormal: Bool { self == .absent }

    /// Ce qu'on affiche après avoir balayé le dossier, ou `nil` si le cas est
    /// normal. Un avertissement qui se déclencherait sur chaque fichier déposé
    /// à la main n'avertirait plus de rien.
    public func listingNote(for fileName: String) -> String? {
        switch self {
        case .absent:
            nil
        case .unreadable(let detail):
            "Fiche illisible (\(fileName)) : \(detail). "
                + "Le titre, les notes et le lien CRM de cet enregistrement resteront masqués tant que le fichier ne sera pas lisible."
        case .corrupt(let detail):
            "Fiche corrompue (\(fileName)) : \(detail). "
                + "La vidéo est intacte ; le titre, les notes et le lien CRM sont dans ce .json et peuvent encore être récupérés à la main — bran ne le réécrira pas."
        }
    }

    /// Ce qu'on dit quand l'utilisateur vient de modifier quelque chose.
    ///
    /// Ici l'absence n'est plus banale : elle veut dire que la saisie n'a nulle
    /// part où aller. Jamais `nil`, donc — une modification perdue en silence
    /// est la même faute qu'un enregistrement perdu en silence, en plus petit.
    public func editingNote(for fileName: String) -> String {
        switch self {
        case .absent:
            "Modification non enregistrée : cet enregistrement n'a pas de fiche (\(fileName))."
        case .unreadable(let detail):
            "Modification non enregistrée : \(fileName) illisible (\(detail))."
        case .corrupt(let detail):
            "Modification non enregistrée : \(fileName) ne se décode pas (\(detail)). "
                + "bran ne l'écrase pas — son contenu peut encore être récupéré à la main."
        }
    }
}
