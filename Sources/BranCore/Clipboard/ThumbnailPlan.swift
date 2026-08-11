import Foundation

/// Tout ce qui se décide sur une vignette sans toucher à une image : où elle
/// vit, comment elle s'appelle, quelle taille demander, ce qui n'en a jamais, et
/// ce qui doit partir quand le dossier grossit.
///
/// ```
/// ~/…/bran/Clipboard/
///   2026-08-10/
///     <uuid>.json
///     index.jsonl
///     blobs/<sha256>.png          ← l'image copiée, jusqu'à 10000×10000
///   Thumbnails/
///     <sha256>-80.png             ← la vignette de ligne
///     <sha256>-256.png            ← la vignette de détail
/// ```
///
/// ## Pourquoi ce fichier existe
///
/// Le panneau doit s'ouvrir en moins de 50 ms avec 250 entrées. Sans cache, ce
/// critère est faux et il l'est de très loin : mesuré sur un historique réel,
/// 183 lignes de PNG pesaient 158 Mo, et une seule image copiée peut faire
/// 10000×10000 — soit 400 Mo de bitmap une fois décodée. Décoder ne serait-ce
/// que les dix premières lignes visibles détruirait le budget **et** la mémoire.
///
/// Ce qui est ici est la moitié pure du cache. Elle est dans `BranCore`, qui
/// n'importe que `Foundation`, parce que c'est ce qui la rend vérifiable sans
/// écran, sans autorisation et sans une seule image : le nommage, l'éligibilité
/// et l'éviction sont trois décisions dont une erreur se paie en fichiers
/// supprimés à tort ou en vignettes qui s'écrasent l'une l'autre, et aucune
/// d'elles n'a besoin d'un pixel pour être prise. Le décodage réel, lui, vit
/// dans `ThumbnailCache` du côté application, où ImageIO est autorisé.
///
/// ## Le nom porte toutes ses entrées, et c'est ce qui remplace un registre
///
/// Un blob est adressé par le SHA-256 de son contenu — voir `ClipboardBlobRef`.
/// La vignette hérite gratuitement de cette propriété : son nom est
/// `<empreinte>-<pixels>.png`, donc **deux entrées qui citent la même image
/// partagent leur vignette sans qu'aucun registre ne l'organise**. Copier deux
/// fois le même logo, le recopier la semaine suivante, l'avoir dans deux
/// dossiers-jours différents : un seul fichier, une seule fabrication.
///
/// L'alternative — nommer par l'identifiant de l'entrée — a été écartée pour
/// cette raison exacte : elle refabrique la même vignette autant de fois que
/// l'image a été copiée, et c'est le cas fréquent (43 entrées sur 250 ont été
/// copiées plus d'une fois).
///
/// **La taille demandée est dans le nom**, sinon la vignette de détail
/// écraserait celle de ligne à chaque ouverture du panneau et l'on payerait un
/// décodage pour chaque va-et-vient entre la liste et le détail.
///
/// ## Ce qui périme, et ce qui ne périme jamais
///
/// Une vignette adressée par le contenu ne peut pas être **fausse**. C'est tout
/// l'intérêt de hacher : si les pixels changent, l'empreinte change, donc le nom
/// change, donc l'ancien fichier n'est plus jamais demandé. Il n'y a pas
/// d'invalidation à écrire, pas de date à comparer, pas de numéro de version à
/// faire monter — changer la taille de `ThumbnailSize`, ou changer le format
/// d'encodage (donc l'extension), rend simplement les anciens fichiers
/// **inatteignables** plutôt que périmés.
///
/// Restent deux façons de devenir inutile : le blob source est purgé par la
/// rétention (30 jours), ou l'entrée est supprimée. Aucune des deux ne se
/// détecte ici, et c'est délibéré — voir `filesToEvict(from:)`, qui explique
/// pourquoi l'éviction par l'usage répond aux deux sans avoir à lire 365 index.
public struct ThumbnailPlan: Sendable, Equatable {

    // MARK: - Où le cache vit

    /// Le sous-dossier du cache, sous la racine de la bibliothèque du
    /// presse-papiers et **à côté** des dossiers-jours, jamais dedans.
    ///
    /// **Pourquoi surtout pas dans un dossier-jour.** Trois raisons, et chacune
    /// suffirait :
    ///
    /// - le dossier-jour est promis lisible à l'utilisateur — c'est la moitié de
    ///   l'intérêt d'une bibliothèque qui est un simple dossier. Une vignette est
    ///   un artefact jetable de notre fabrication ; elle n'a rien à faire à côté
    ///   de ce qu'il a copié ;
    /// - la rétention purge `<jour>/blobs/` en entier, par nom de dossier et sans
    ///   ouvrir un fichier. Une vignette rangée là partirait avec, ce qui est
    ///   peut-être souhaitable mais surtout **hors de notre contrôle** ;
    /// - `ClipboardStore.collectOrphanedBlobs()` refuse de classer ce qu'il ne
    ///   sait pas nommer et laisse traîner pour toujours ce qui n'est pas
    ///   `<64 hexa>.<ext>`. Nos `<empreinte>-<pixels>.png` échouent à ce test par
    ///   construction : ils s'accumuleraient sans que rien ne les ramasse. C'est
    ///   exactement le défaut mesuré chez Maccy — 327,6 Mo de contenus orphelins
    ///   parce que la suppression du parent ne cascadait pas.
    ///
    /// Le nom est aussi choisi pour que `ClipboardRetention.day(from:)` le
    /// rejette : « Thumbnails » n'a pas la forme `AAAA-MM-JJ`, donc le balayage
    /// des jours ne le voit pas, ne le lit pas et ne le supprime pas. Un test le
    /// gèle.
    ///
    /// **Alternative écartée : `~/Library/Caches`.** C'est l'endroit canonique
    /// d'un cache sur macOS, et le système sait y faire le ménage tout seul. Mais
    /// la racine de la bibliothèque est un réglage : elle peut vivre sur un NAS
    /// ou un disque externe, et l'utilisateur peut la déplacer. Un cache resté
    /// derrière serait un tas d'octets que plus rien ne réclame et que notre
    /// propre éviction ne verrait plus — le défaut qu'on prétend corriger,
    /// reconstruit ailleurs. Un seul arbre : on le déplace, on le sauvegarde et
    /// on le supprime d'un seul geste.
    public static let folderName = "Thumbnails"

    /// Le format d'encodage des vignettes, extension comprise.
    ///
    /// **PNG et non JPEG.** Une vignette de 80 px pèse quelques kilo-octets dans
    /// les deux formats, donc le gain de place du JPEG est nul à cette échelle ;
    /// mais le JPEG n'a pas de couche alpha, et une capture de fenêtre macOS ou
    /// un logo copié en ont une. Ils se retrouveraient sur du noir dans la liste
    /// — un défaut visible, contre une économie invisible.
    ///
    /// L'extension fait partie du nom : changer ce constant rend l'intégralité du
    /// cache existant inatteignable plutôt qu'incohérente, et l'éviction le
    /// ramassera. C'est le comportement voulu, pas un accident.
    public static let fileExtension = "png"

    /// Le dossier du cache, sous la racine du presse-papiers.
    ///
    /// - Parameter clipboardFolder: `ClipboardStore.folder`, c'est-à-dire
    ///   `<racine>/Clipboard`. C'est le magasin qui sait où il range ; ce plan ne
    ///   redérive pas ce chemin, pour la même raison que `ClipboardEntry` ne
    ///   redérive pas le nom d'un dossier-jour.
    public static func folder(in clipboardFolder: URL) -> URL {
        clipboardFolder.appending(path: folderName, directoryHint: .isDirectory)
    }

    // MARK: - Comment une vignette s'appelle

    /// `<empreinte>-<pixels>.png`.
    ///
    /// L'empreinte seule, **sans l'extension du blob source** : ce qui est mis en
    /// cache, ce sont des pixels, et deux fichiers de même contenu ont les mêmes
    /// pixels quel que soit le nom qu'on leur a donné. Inclure l'extension source
    /// fabriquerait deux vignettes identiques pour un `png` et un `PNG`.
    ///
    /// Le séparateur est un tiret parce que `ClipboardBlobRef.fileName` utilise
    /// un point : un nom de vignette ne peut donc jamais être confondu avec un
    /// nom de blob, ni par `ClipboardStore.isSelfWritten` ni par un humain qui
    /// ouvre le dossier.
    public static func fileName(for blob: ClipboardBlobRef, size: ThumbnailSize) -> String {
        fileName(hash: blob.hash, maxPixelSize: size.maxPixelSize)
    }

    /// La même dérivation, à partir des deux seules valeurs qui la déterminent.
    /// Séparée pour que le test du nommage n'ait pas à fabriquer une référence
    /// complète, et pour qu'il n'existe **qu'une** façon d'assembler ce nom.
    public static func fileName(hash: String, maxPixelSize: Int) -> String {
        "\(hash)-\(maxPixelSize).\(fileExtension)"
    }

    /// L'emplacement complet d'une vignette.
    public static func url(
        for blob: ClipboardBlobRef, size: ThumbnailSize, in clipboardFolder: URL
    ) -> URL {
        folder(in: clipboardFolder).appending(path: fileName(for: blob, size: size))
    }

    /// Ce nom aurait-il pu être écrit par ce cache ?
    ///
    /// 64 caractères hexadécimaux minuscules, un tiret, au moins un chiffre, puis
    /// `.png` — c'est-à-dire exactement ce qu'assemble `fileName(hash:maxPixelSize:)`,
    /// vérifié en le redécomposant.
    ///
    /// **Repris mot pour mot de `ClipboardStore.isSelfWritten`, et pour la même
    /// raison.** Le dossier est un dossier ordinaire, dans une bibliothèque qu'on
    /// invite l'utilisateur à ouvrir : supprimer le fichier d'un tiers parce
    /// qu'il traînait chez nous serait un défaut bien pire que celui qu'on
    /// corrige. Ce qu'on ne sait pas nommer reste, pour toujours, et n'est pas
    /// non plus compté dans le budget — sinon un film déposé là par erreur ferait
    /// évincer nos propres vignettes.
    ///
    /// **C'est aussi la garde contre la sortie du dossier**, et c'est le second
    /// service qu'elle rend : l'exécution du plan joint un *nom* au dossier de
    /// cache, et aucun nom qui passe ce test ne peut contenir un `/` ni un `..`.
    /// Une liste de noms ne peut donc pas désigner un fichier ailleurs, quelle
    /// que soit la façon dont elle a été obtenue.
    public static func isSelfWritten(_ name: String) -> Bool {
        let suffix = ".\(fileExtension)"
        guard name.hasSuffix(suffix) else { return false }

        let stem = name.dropLast(suffix.count)
        let parts = stem.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }

        let hash = parts[0]
        guard hash.count == 64 else { return false }
        guard hash.allSatisfy(\.isHexDigit), hash.allSatisfy({ $0.isUppercase == false }) else {
            return false
        }

        let pixels = parts[1]
        return pixels.isEmpty == false && pixels.allSatisfy(\.isNumber)
    }

    // MARK: - Ce qui n'a pas de vignette du tout

    /// Le contenu à partir duquel fabriquer la vignette, ou `nil` quand il n'y en
    /// a aucun.
    ///
    /// **La question se répond sans un seul accès disque**, et c'est ce qui
    /// permet à une ligne de liste de se dessiner sans I/O : 250 lignes qui
    /// demandent chacune « ai-je une image ? » ne doivent pas produire 250
    /// `stat`. Tout ce qui est nécessaire est déjà dans l'entrée.
    ///
    /// Quatre refus :
    ///
    /// - une sorte autre qu'`image`. Un texte, un fichier du Finder ou du
    ///   `richText` se dessinent avec un symbole, jamais avec une image — et pour
    ///   `richText`, le blob est du RTF ou du HTML, qu'ImageIO ne lira pas ;
    /// - une entrée refusée à l'écriture (`refusedBytes`) : le contenu n'a jamais
    ///   touché le disque. Le test est explicite bien que le magasin mette déjà
    ///   `blobs` à `nil` dans ce cas — dépendre d'un invariant d'un autre fichier
    ///   pour une décision de sécurité est un pari qu'on perd au premier
    ///   correctif ;
    /// - une entrée dont les blobs ont été purgés. Elle sait déjà dire pourquoi
    ///   — « Image de 1,2 Mo, purgée le 10 août » — et c'est cette phrase que la
    ///   ligne doit montrer, pas une vignette survivante qui prétendrait le
    ///   contraire ;
    /// - une entrée sans aucun blob.
    ///
    /// **Le premier blob, sans trier par extension.** `kind == .image` a déjà
    /// tranché la nature du contenu, et ImageIO lit tout ce que le presse-papiers
    /// pose (PNG, TIFF, JPEG, HEIC). Pour une copie multiple de plusieurs images,
    /// c'est la première qui représente l'entrée — la ligne est une ligne, pas
    /// une planche-contact.
    public static func source(for entry: ClipboardEntry) -> ClipboardBlobRef? {
        guard entry.kind == .image else { return nil }
        guard entry.isRefused == false else { return nil }
        guard entry.blobsArePurged == false else { return nil }
        return entry.blobs?.first
    }

    /// Cette entrée peut-elle montrer une vignette ? Sans accès disque, donc
    /// appelable depuis le corps d'une ligne.
    ///
    /// Répondre `true` ne promet pas que le fichier existe : il peut avoir été
    /// supprimé sous nous. C'est `ThumbnailCache` qui rend alors `nil` sans
    /// bruit, et la ligne retombe sur son symbole — une image absente n'est jamais
    /// une panne.
    public static func hasThumbnail(_ entry: ClipboardEntry) -> Bool {
        source(for: entry) != nil
    }

    // MARK: - L'éviction

    /// Le plafond en octets du dossier de cache.
    ///
    /// **48 Mio, et le chiffre vient d'une mesure.** L'historique réel du
    /// propriétaire porte 183 lignes d'image pour 250 entrées. Une vignette de
    /// détail (256 px) d'une capture d'écran pèse ~100 Ko en PNG, une vignette de
    /// ligne (80 px) ~8 Ko : le jeu complet des deux tailles pour cet historique
    /// tient dans ~20 Mo. Le plafond laisse donc plus du double de marge sur le
    /// cas mesuré — assez pour que l'éviction ne morde pas dans l'usage normal,
    /// et assez bas pour rester dérisoire devant les 158 Mo de blobs qu'il sert à
    /// ne pas décoder.
    public static let defaultBudgetBytes = 48 * 1024 * 1024

    /// Le plafond effectif. Réglable **pour les tests**, comme la fenêtre de
    /// `ClipboardStore` : vérifier qu'une éviction mord ne doit pas coûter
    /// d'écrire 48 Mio de fixtures. Aucun appelant de production ne passe autre
    /// chose que le défaut — ce n'est pas un réglage utilisateur, et ça ne doit
    /// pas en devenir un : personne ne sait répondre à « combien de mégaoctets de
    /// vignettes voulez-vous ? ».
    public var budgetBytes: Int

    public init(budgetBytes: Int = ThumbnailPlan.defaultBudgetBytes) {
        self.budgetBytes = Swift.max(0, budgetBytes)
    }

    public static let `default` = ThumbnailPlan()

    public static func budget(bytes: Int) -> ThumbnailPlan {
        ThumbnailPlan(budgetBytes: bytes)
    }

    /// Les vignettes à supprimer pour que le dossier repasse sous le plafond, les
    /// moins récemment utilisées d'abord.
    ///
    /// **Rend des noms et ne supprime rien**, exactement comme
    /// `ClipboardRetention.dayFoldersToPurge(from:today:)` : la décision est pure
    /// et se teste en une milliseconde, l'exécution est ailleurs et n'a plus rien
    /// à décider. Des noms et non des `URL` : l'exécutant les joint au dossier de
    /// cache qu'il a choisi, donc il ne peut structurellement pas supprimer
    /// ailleurs.
    ///
    /// ## Pourquoi un plafond d'octets, et pas les deux autres politiques
    ///
    /// Ce qu'on défend est une place sur le disque. Le plafond est donc exprimé
    /// dans l'unité du dommage, ce qui est la seule façon d'en garantir la borne.
    ///
    /// - **Un âge** (« les vignettes de plus de 30 jours ») ne borne rien : 400
    ///   images copiées dans la même journée posent 400 vignettes dont aucune
    ///   n'est assez vieille pour partir. Et il jette ce qu'on regarde tous les
    ///   jours pour la seule raison que c'est ancien — c'est-à-dire le défaut que
    ///   toute cette fonctionnalité existe pour corriger : un outil qui oublie ne
    ///   remplace pas la mémoire, il la simule.
    /// - **Un nombre d'entrées** (« 500 vignettes ») borne la mauvaise grandeur.
    ///   Une vignette n'a pas de taille fixe : un panorama et une icône carrée
    ///   réduits au même côté maximal diffèrent d'un ordre de grandeur en octets.
    ///   Le même compte peut donc valoir 3 Mo ou 60 Mo, et le plafond ne veut
    ///   plus rien dire.
    ///
    /// **L'ordre est celui du dernier usage, pas celui de la fabrication.** Ce
    /// qu'on veut garder est ce que le panneau montre, et le panneau montre ce
    /// que l'on rouvre — pas ce qui vient d'être fabriqué. Le coût de ce choix
    /// est que l'exécutant doit tenir cette date à jour ; il le fait en touchant
    /// la date de modification lors d'une lecture depuis le disque, ce qui est
    /// rare parce que le cache mémoire absorbe les relectures.
    ///
    /// **Et c'est ce qui remplace un ramassage d'orphelins.** Une vignette dont
    /// le blob a été purgé, ou dont l'entrée a été supprimée, ne sera plus jamais
    /// demandée : elle descend d'elle-même au bas du classement et part au
    /// premier dépassement. Le ramassage exact — recouper les empreintes citées
    /// par toutes les entrées vivantes — a été écarté parce qu'il faut avoir tout
    /// lu pour conclure par une absence : 365 index à ouvrir pour supprimer des
    /// fichiers que l'usage désigne déjà, et le risque, s'il conclut sur une
    /// lecture incomplète, de supprimer ce qui servait. C'est précisément le
    /// piège documenté dans `ClipboardStore.collectOrphanedBlobs()`.
    ///
    /// **Un fichier trop gros n'emporte pas ceux d'après.** Le parcours continue
    /// après un refus au lieu de s'arrêter au premier dépassement : l'invariant
    /// « la somme de ce qui reste tient sous le plafond » est vrai dans les deux
    /// cas, mais s'arrêter ferait évincer cent vignettes utiles derrière une
    /// seule anormalement lourde.
    public func filesToEvict(from files: [CachedThumbnail]) -> [String] {
        // Ce qui n'est pas de nous n'est ni compté ni supprimé. Voir
        // `isSelfWritten(_:)` : un fichier de trop coûte des octets, un fichier
        // de tiers supprimé coûte la confiance dans un dossier qu'on invite à
        // ouvrir.
        let ours = files.filter { Self.isSelfWritten($0.name) }

        // Le plus récemment utilisé d'abord. À égalité de date, le nom départage
        // — deux vignettes écrites dans la même seconde ne doivent pas changer de
        // sort d'un balayage à l'autre.
        let ranked = ours.sorted {
            $0.lastUsed == $1.lastUsed ? $0.name < $1.name : $0.lastUsed > $1.lastUsed
        }

        var kept = 0
        var doomed: [String] = []
        for file in ranked {
            let size = Swift.max(0, file.bytes)
            if kept + size <= budgetBytes {
                kept += size
            } else {
                doomed.append(file.name)
            }
        }
        return doomed
    }
}

// MARK: - Les tailles demandées

/// Les deux tailles de vignette que l'interface sait demander.
///
/// **Deux, pas un continuum.** Une taille libre ferait un fichier par taille
/// demandée, donc un cache qui grossit à chaque changement de largeur de fenêtre
/// et qui ne touche jamais deux fois le même fichier — un cache qui ne cache
/// rien. Deux valeurs fixes, et l'interface met à l'échelle le peu qui manque :
/// une vignette légèrement réduite à l'affichage est indiscernable, une vignette
/// agrandie ne l'est pas, d'où des tailles choisies au-dessus du besoin.
public enum ThumbnailSize: Sendable, Equatable, CaseIterable {

    /// La ligne de la liste du panneau.
    case row

    /// Le détail d'une entrée sélectionnée.
    case detail

    /// Le côté le plus long, en **points**.
    public var points: Int {
        switch self {
        case .row: 40
        case .detail: 128
        }
    }

    /// Le facteur d'échelle, **figé et jamais lu sur l'écran branché**.
    ///
    /// C'est le point important de ce type. Demander `backingScaleFactor` au
    /// moment de la fabrication ferait entrer l'écran courant dans le nom du
    /// fichier : brancher ou débrancher un écran externe refabriquerait tout le
    /// cache, et un portable qu'on pose sur son bureau le ferait deux fois par
    /// jour. Tous les Mac vendus depuis dix ans sont en 2× ; les rares écrans en
    /// 1× affichent une vignette deux fois trop détaillée, ce qui ne se voit pas.
    public static let scale = 2

    /// Le côté le plus long en pixels — ce qui est passé à
    /// `kCGImageSourceThumbnailMaxPixelSize`, et ce qui entre dans le nom du
    /// fichier.
    public var maxPixelSize: Int { points * Self.scale }
}

// MARK: - Ce que l'exécutant a trouvé dans le dossier

/// Une vignette telle que le dossier la décrit : un nom, un poids, une date de
/// dernier usage.
///
/// **Volontairement pauvre.** Ce type est la frontière entre le disque et la
/// décision : tout ce que l'éviction a le droit de savoir est ici, et rien de ce
/// qui est ici n'oblige à ouvrir un fichier — les trois valeurs viennent du
/// listage de dossier que l'exécutant fait de toute façon. Y ajouter une `URL`
/// serait le premier pas vers une décision qui désigne un chemin absolu, donc
/// vers une suppression hors du dossier de cache.
public struct CachedThumbnail: Sendable, Equatable {

    /// Le nom du fichier, sans chemin.
    public let name: String

    /// Sa taille sur le disque.
    public let bytes: Int

    /// La date du dernier usage — en pratique la date de modification, que
    /// l'exécutant touche quand il relit la vignette depuis le disque.
    public let lastUsed: Date

    public init(name: String, bytes: Int, lastUsed: Date) {
        self.name = name
        self.bytes = bytes
        self.lastUsed = lastUsed
    }
}
