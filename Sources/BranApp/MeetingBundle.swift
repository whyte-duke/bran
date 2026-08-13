import BranCore
import Foundation

/// Ce qu'un dossier de rendez-vous contient **réellement**, lu sur le disque.
///
/// `MeetingFolder` dit comment un dossier de réunion doit s'appeler ; ce type-ci
/// dit ce qu'on y a trouvé. La distinction compte : le nom est ce que bran écrit,
/// le contenu est ce qui reste après que l'utilisateur est passé dans le Finder.
///
/// **Les fichiers sont trouvés par extension, jamais par nom, et c'est toute la
/// raison d'être de ce type.** Chercher `<nom du dossier>.mp4` aurait été plus
/// court d'une dizaine de lignes, et aurait rendu la bibliothèque aveugle dès le
/// premier renommage à la main — or renommer un dossier de réunion est
/// exactement le geste qu'on fait quand on classe. Une bibliothèque qui perd un
/// enregistrement parce qu'on l'a mieux nommé est une bibliothèque qu'on n'ose
/// plus toucher, et on finit par ne plus rien y ranger.
///
/// L'autre règle est celle du marqueur : un sous-dossier n'est un dossier de
/// réunion **que** s'il contient `Fiche.json`. bran pose déjà `Dictées`,
/// `Captures`, `Veille`, `Clipboard` et `Journal` dans la même racine, et
/// plusieurs de ces dossiers contiennent eux aussi des `.json`. Une règle du
/// genre « un sous-dossier avec un `.json` qui se décode » les aurait tous
/// avalés et transformés en réunions fantômes.
struct MeetingBundle: Sendable {

    /// Le dossier du rendez-vous. Pour un enregistrement resté à plat, c'est la
    /// racine de stockage — il n'a pas de dossier à lui, et prétendre le
    /// contraire ferait écrire à côté.
    let folder: URL

    let sidecar: URL

    /// La vidéo finale, hors morceaux bruts. `nil` pendant l'enregistrement et
    /// tant que la fusion n'a pas écrit son fichier.
    let video: URL?

    /// L'audio préparé pour le CRM. `nil` tant qu'il n'a pas été extrait — ou
    /// pour toujours, si la réunion n'a jamais été envoyée.
    let audio: URL?

    /// Les morceaux bruts encore présents, dans l'ordre où ils ont été écrits.
    ///
    /// Triés par nom, ce qui suffit : `seg000`, `seg001`… sont zéro-remplis
    /// précisément pour que l'ordre alphabétique soit l'ordre chronologique.
    let segments: [URL]

    /// Ancienne disposition : tout à plat dans la racine, sous des noms d'UUID.
    let isFlat: Bool

    // MARK: - Destinations

    /// Où la vidéo finale d'un dossier doit s'écrire.
    ///
    /// La base est `folder.lastPathComponent`, donc le nom du dossier tel qu'il
    /// est **maintenant**, renommages à la main compris. C'est ce qui fait qu'un
    /// `.mp4` sorti de son dossier — glissé dans un mail, déposé sur un Drive —
    /// continue de dire de quelle réunion il vient. `reunion.mp4` aurait rendu
    /// chaque envoi anonyme, et c'est le fichier qu'on envoie le plus.
    static func videoDestination(in folder: URL) -> URL {
        folder.appending(path: "\(folder.lastPathComponent).\(MeetingFolder.videoExtension)")
    }

    /// Où l'audio du CRM doit s'écrire. Même base que la vidéo, pour la même
    /// raison : les deux fichiers voyagent séparément.
    static func audioDestination(in folder: URL) -> URL {
        folder.appending(path: "\(folder.lastPathComponent).\(MeetingFolder.audioExtension)")
    }

    /// Où les morceaux bruts d'une session s'écrivent.
    ///
    /// **Leur base est l'horodatage seul, sans le titre**, et pas celle du
    /// dossier. Deux raisons, et la seconde est la vraie : ils sont écrits
    /// pendant l'enregistrement, avant que le titre soit connu — le CRM le
    /// fournit à l'arrivée, ou l'utilisateur le tape en cours de route ; et le
    /// dossier se renomme à la fin, alors qu'eux sont déjà sur le disque. Les
    /// faire dépendre du nom du dossier obligerait à renommer des morceaux de
    /// plusieurs gigaoctets à chaque changement de titre, pour rien : ils sont
    /// effacés dès la fusion faite.
    static func segmentDestination(in folder: URL, startedAt: Date, index: Int) -> URL {
        folder.appending(
            path: MeetingFolder.segmentName(base: MeetingFolder.stamp(startedAt), index: index)
        )
    }

    // MARK: - Lecture

    /// Lecture d'un dossier candidat. `nil` si ce n'est pas un dossier de
    /// réunion.
    ///
    /// Le seul critère est la présence de `Fiche.json` — sa **présence**, pas sa
    /// lisibilité. Une fiche corrompue ne doit pas faire disparaître la réunion
    /// de la bibliothèque : la vidéo est intacte à côté, et c'est justement le
    /// moment où on a besoin de la voir pour la récupérer. L'appelant décodera
    /// et dira ce qui cloche ; ici on se contente de constater que ce dossier
    /// est bien une réunion.
    static func read(folder: URL) -> MeetingBundle? {
        let manager = FileManager.default
        let sidecar = folder.appending(path: MeetingFolder.sidecarName)

        guard manager.fileExists(atPath: sidecar.path(percentEncoded: false)) else { return nil }

        // Un dossier de réunion illisible reste un dossier de réunion : on rend
        // un paquet sans média plutôt que `nil`. Rendre `nil` ferait disparaître
        // la ligne de la bibliothèque alors que le `Fiche.json` est là, et
        // l'utilisateur conclurait à une perte de données là où il n'y a qu'un
        // droit d'accès retiré.
        let names = (try? manager.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []

        var videos: [URL] = []
        var audios: [URL] = []
        var segments: [URL] = []

        for name in names.sorted() {
            // Comparaison en minuscules : macOS n'impose pas la casse des
            // extensions, et un `.MP4` copié depuis un autre outil est une
            // vidéo comme les autres. La refuser rendrait le dossier vide aux
            // yeux de bran alors que le Finder y montre un film.
            let url = folder.appending(path: name)
            switch (name as NSString).pathExtension.lowercased() {
            case MeetingFolder.videoExtension:
                if isSegment(name) {
                    segments.append(url)
                } else {
                    videos.append(url)
                }
            case MeetingFolder.audioExtension:
                audios.append(url)
            default:
                continue
            }
        }

        return MeetingBundle(
            folder: folder,
            sidecar: sidecar,
            video: preferred(videos, base: folder.lastPathComponent),
            audio: preferred(audios, base: folder.lastPathComponent),
            segments: segments,
            isFlat: false
        )
    }

    /// Ce qu'un enregistrement resté à plat occupe dans la racine.
    ///
    /// Utilisé par le rangement, qui a besoin de l'état **du disque au moment où
    /// il déplace**, pas de celui qu'un balayage a relevé il y a peut-être une
    /// heure. Déplacer d'après une liste périmée, c'est déplacer un fichier qui
    /// n'est plus là et en oublier un qui est arrivé depuis.
    static func flat(root: URL, identifier: UUID) -> MeetingBundle {
        let manager = FileManager.default
        let names = (try? manager.contentsOfDirectory(atPath: root.path(percentEncoded: false))) ?? []

        let video = root.appending(path: "\(identifier.uuidString).\(MeetingFolder.videoExtension)")
        let hasVideo = manager.fileExists(atPath: video.path(percentEncoded: false))

        let prefix = "\(identifier.uuidString)\(MeetingFolder.segmentMarker)"
        let segments = names
            .filter { $0.hasPrefix(prefix) && isSegment($0) }
            .sorted()
            .map { root.appending(path: $0) }

        return MeetingBundle(
            folder: root,
            sidecar: root.appending(path: "\(identifier.uuidString).json"),
            video: hasVideo ? video : nil,
            // L'ancienne disposition n'a jamais produit d'audio : il était
            // fabriqué dans le dossier temporaire, envoyé au CRM, puis effacé.
            // C'est précisément ce que la nouvelle disposition répare.
            audio: nil,
            segments: segments,
            isFlat: true
        )
    }

    /// Ce nom est-il celui d'un morceau brut plutôt que d'une vidéo finale ?
    ///
    /// **Une seule implémentation, dans `MeetingFolder`, et pas une copie
    /// locale.** Ce fichier en a porté une, écrite parce que la version de
    /// `MeetingFolder` cherchait alors `-seg` n'importe où dans le nom : ce qui
    /// suffisait tant que les fichiers s'appelaient d'après un UUID — un UUID ne
    /// contient pas de lettres au-delà de `f` — et devenait faux dès que le
    /// fichier a porté le titre du rendez-vous. « Point-segmentation
    /// clientèle.mp4 » aurait été pris pour un morceau brut, la réunion se serait
    /// affichée sans vidéo, et une heure d'enregistrement aurait disparu de
    /// l'écran pour une syllabe.
    ///
    /// `MeetingFolder.isSegment` exige désormais la forme entière — `-seg`, trois
    /// chiffres, l'extension, dans cet ordre et en fin de nom — c'est-à-dire
    /// exactement ce que `segmentName(base:index:)` produit. Garder ici une
    /// seconde version de la même règle, fût-elle correcte aujourd'hui, ne ferait
    /// qu'offrir une occasion de les faire diverger ; et le jour où elles
    /// divergent, l'une des deux fait disparaître des réunions.
    private static func isSegment(_ name: String) -> Bool {
        MeetingFolder.isSegment(name)
    }

    /// Le fichier qui porte le nom du dossier, à défaut le premier par ordre
    /// alphabétique.
    ///
    /// Un dossier ne devrait contenir qu'une vidéo finale. S'il en contient
    /// deux — un montage déposé à côté, une copie « (1) » faite à la main —
    /// prendre celle qui porte le nom du dossier rend le choix prévisible, et le
    /// tri rend le repli stable d'un balayage à l'autre : une bibliothèque qui
    /// change d'avis à chaque rafraîchissement fait douter de tout le reste.
    private static func preferred(_ candidates: [URL], base: String) -> URL? {
        candidates.first { $0.deletingPathExtension().lastPathComponent == base }
            ?? candidates.first
    }
}
