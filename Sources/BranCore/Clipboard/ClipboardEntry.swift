import Foundation

/// Une entrée de l'historique du presse-papiers, telle qu'elle survit sur le
/// disque.
///
/// **Tout champ ajouté après la première écriture doit être optionnel.** Le
/// `Decodable` synthétisé par Swift ignore les valeurs par défaut : un champ non
/// optionnel ajouté ici rendrait illisible, d'un coup, chaque ligne déjà écrite,
/// et les lecteurs de ce dépôt avalent l'échec de décodage en silence par
/// tolérance aux fichiers coupés. Un mois d'historique disparaîtrait sans un
/// seul message. La leçon a déjà été payée sur `RecordingMetadata.segmentCount`
/// puis sur `TranscriptEntry` ; `ClipboardKind.swift` la répète en tête de
/// fichier. Quatre champs seulement sont exigés — `id`, `copiedAt`, `kind`,
/// `preview` — et `ClipboardEntryTests.compatibiliteAscendante` gèle ce contrat.
///
/// ```
/// ~/…/bran/Clipboard/
///   2026-08-10/
///     index.jsonl                  ← une ligne par entrée, gardée pour toujours
///     blobs/<sha256>.png           ← le contenu lourd, purgé après 30 jours
/// ```
///
/// **Un dossier par jour, et les blobs dedans.** Le contenu est adressé par son
/// empreinte, ce qui rend la déduplication gratuite — mais à l'intérieur d'une
/// journée seulement, puisque le dossier change à minuit. Ce serait une perte si
/// les recopies traversaient les jours ; mesuré sur l'historique réel du
/// propriétaire, **aucune** entrée n'a été recopiée à plus d'un jour d'écart.
/// La déduplication inter-jours qu'un dossier `blobs/` global aurait offerte ne
/// se serait donc jamais déclenchée, et elle aurait coûté la seule chose qui
/// rend la purge sûre : pouvoir décider quoi supprimer en lisant un nom de
/// dossier, sans ouvrir un seul fichier. Voir `ClipboardRetention`.
///
/// **Ce qui n'était pas ici.** Pas de champ « épinglé », pas d'étiquette, pas de
/// dossier de rangement. Ils s'ajouteront en `Optional` le jour où ils serviront
/// ; les inventer maintenant fige un format sur une intuition.
///
/// **L'épinglage est arrivé, exactement par la route que ce paragraphe
/// décrivait.** Le refuser en v1 était une décision *mesurée* — sur les 250
/// entrées de l'historique réel du propriétaire, zéro épingle et zéro recopie à
/// plus d'un jour d'écart : rien dans les données ne réclamait qu'une entrée
/// vive plus longtemps qu'une autre. Le propriétaire a tranché l'inverse : il
/// veut pouvoir garder certaines entrées indéfiniment. Une mesure dit ce qui a
/// été fait, jamais ce qui sera voulu, et c'est une raison suffisante de
/// renverser. La décision renversée reste écrite juste au-dessus — l'effacer
/// ferait croire que `pinnedAt` a toujours été une évidence, et le prochain
/// champ « évident » s'ajouterait sans mesure et sans arbitrage.
public struct ClipboardEntry: Codable, Identifiable, Equatable, Sendable {

    // MARK: - Le noyau exigé

    public var id: UUID

    /// L'instant de la **première** copie. C'est lui qui décide du dossier-jour,
    /// donc de la purge : une entrée ne change jamais de dossier.
    ///
    /// La règle n'est pas qu'une phrase ici : elle est `dayFolderName(calendar:)`,
    /// et c'est la seule dérivation d'un nom de dossier qui existe. Une règle de
    /// nommage qui ne vit qu'en commentaire est une règle que le premier
    /// appelant casse.
    public var copiedAt: Date

    /// Comment la ligne se dessine et quoi remettre au collage. Quatre valeurs,
    /// arbitrées une fois dans `ClipboardKind`.
    public var kind: ClipboardKind

    /// Le début du texte, déjà rogné à `previewLimit` caractères, tel qu'il est
    /// écrit dans l'index du jour.
    ///
    /// **Rogné et non tronqué avec une ellipse.** Aucune marque n'est stockée :
    /// une entrée dont le texte finit vraiment par « … » serait indiscernable
    /// d'une entrée coupée, et une recherche plein texte sur l'index se
    /// mettrait à trouver le caractère de l'outil plutôt que celui de
    /// l'utilisateur. La coupure se déduit — voir `isPreviewTruncated` — et
    /// l'ellipse est l'affaire de l'interface.
    ///
    /// Vide pour une image ou un fichier : il n'y a rien à en dire en texte, et
    /// écrire « (image) » ici mettrait une chaîne d'interface dans une donnée.
    public var preview: String

    // MARK: - Tout le reste, optionnel par contrat

    /// L'instant de la copie la plus récente, `nil` tant qu'il n'y en a pas eu
    /// de seconde.
    ///
    /// **`nil` plutôt qu'une copie de `copiedAt`.** Mesuré sur l'historique
    /// réel : 207 entrées sur 250 n'ont été copiées qu'une fois. Un encodeur
    /// JSON omet les `nil`, donc le cas de loin le plus fréquent n'écrit rien
    /// du tout — et la lecture reste exacte grâce à `lastCopiedAt`.
    public var recopiedAt: Date?

    /// Le nombre de recopies **après** la première, `nil` valant zéro.
    ///
    /// Compter les recopies plutôt que les copies pour la même raison que
    /// ci-dessus : la valeur du cas majoritaire est celle qui ne s'écrit pas.
    /// `copyCount` rend le total, qui est ce qu'on affiche.
    public var repeatCount: Int?

    /// L'application au premier plan au moment de la copie. C'est le meilleur
    /// critère de recherche trois semaines plus tard : on se souvient d'où
    /// venait un bout de texte bien avant de se souvenir de ce qu'il disait.
    /// Mesuré : Chrome et Terminal produisent 77 % de tout l'historique, donc
    /// filtrer par source coupe le bruit en deux d'un seul geste.
    public var source: ClipboardSource?

    /// Le texte brut complet, quand il tient en ligne dans l'index.
    ///
    /// `nil` dans trois cas qui ne se ressemblent pas : le contenu n'est pas du
    /// texte, le texte dépasse `inlineTextLimit` et vit dans un blob, ou
    /// l'entrée a été refusée. `isTextInline` et `blobsArePurged` distinguent.
    ///
    /// Pour `richText`, ce champ porte **l'aplatissement en texte brut** et le
    /// blob porte le RTF ou le HTML. Les deux coexistent volontairement :
    /// « coller sans mise en forme » est le geste le plus demandé après
    /// « coller », et le faire ne doit pas coûter une conversion à chaud.
    public var plainText: String?

    /// Le contenu lourd, hors de l'index. Plusieurs références pour une seule
    /// entrée : une sélection multiple du Finder, ou un `richText` qui porte à
    /// la fois son RTF et son HTML.
    public var blobs: [ClipboardBlobRef]?

    /// Les chemins des fichiers copiés, pour `kind == .file`.
    ///
    /// **Des chaînes et non des `URL`.** Le `Decodable` d'`URL` échoue sur une
    /// valeur qu'il ne sait pas analyser, et cet échec ferait tomber le décodage
    /// de **l'entrée entière** — un chemin bizarre effacerait une ligne
    /// d'historique. Une `String` ne peut pas échouer. La conversion en `URL`
    /// est l'affaire du site d'appel, qui peut la voir échouer sans rien perdre.
    ///
    /// **Séparés des blobs, et non fondus dedans.** `ClipboardBlobRef` est
    /// adressé par l'empreinte de son contenu ; un fichier copié n'est pas lu,
    /// donc il n'a pas d'empreinte. Les confondre obligerait à inventer un faux
    /// hachage. Le fichier peut être déplacé ou supprimé ensuite, et l'entrée
    /// devient alors morte — un état à afficher, comme un blob purgé.
    public var fileURLs: [String]?

    /// Le nombre d'éléments que macOS a déclarés sur le presse-papiers, `nil`
    /// valant un.
    ///
    /// **Une sélection multiple est une entrée, pas N.** Mesuré : un
    /// `writeObjects` de N éléments n'incrémente le compteur de changement
    /// qu'une seule fois. Le système considère ça comme une copie ; en faire
    /// N lignes inventerait des événements qui n'ont pas eu lieu et noierait
    /// l'historique au premier glisser de dossier.
    ///
    /// **Stocké et non déduit de `blobs.count`.** Un `richText` porte deux blobs
    /// pour un seul élément ; compter les blobs annoncerait « 2 éléments » pour
    /// un bout de texte copié depuis une page web. La machine, elle, connaît le
    /// vrai chiffre au moment de la lecture.
    public var pasteboardItems: Int?

    /// La longueur du texte **normalisé** — celui dont `preview` est un préfixe.
    ///
    /// Retenue pour pouvoir dire « 512 des 4 312 caractères » sans ouvrir le
    /// blob, exactement comme `ClipboardBlobRef.bytes` retient la taille pour
    /// ne pas toucher au disque. C'est aussi ce qui rend `isPreviewTruncated`
    /// exact plutôt qu'approché.
    public var fullTextLength: Int?

    /// La taille de ce qui a été refusé parce qu'il dépassait `maximumBlobBytes`.
    ///
    /// L'entrée existe quand même, avec son type et sa taille, mais sans
    /// contenu : c'est plus honnête qu'un silence, et ça évite qu'un historique
    /// de presse-papiers puisse remplir un disque. `nil` dans le cas normal.
    ///
    /// **Un entier et non une énumération de motifs.** Il n'y a aujourd'hui
    /// qu'une seule raison de refuser. Le jour où il y en a une seconde, elle
    /// s'ajoute en `refusalReason: String?` à côté — jamais en champ non
    /// optionnel, jamais en changeant le type de celui-ci.
    public var refusedBytes: Int?

    /// L'instant où les blobs de cette entrée ont été supprimés par la
    /// rétention. `nil` tant qu'ils sont là.
    ///
    /// **Les références sont conservées, pas effacées.** `SnippetEntry` met son
    /// `imageFileName` à `nil` parce qu'il n'a rien d'autre à dire ; ici, les
    /// références portent le type et la taille de ce qui a disparu, et
    /// l'interface peut écrire « Image de 1,2 Mo, purgée le 10 août » au lieu de
    /// « rien ». Une référence morte est un état à afficher, pas un défaut à
    /// prévenir.
    public var blobsPurgedAt: Date?

    /// L'instant où l'entrée a été épinglée, `nil` quand elle ne l'est pas.
    ///
    /// Épingler veut dire une seule chose : **cette entrée-là ne perd pas ses
    /// contenus lourds au bout de `blobDays` jours, ni jamais.** Le texte, lui,
    /// était déjà conservé indéfiniment pour tout le monde ; l'épingle ne
    /// concerne donc que ce que la rétention efface.
    ///
    /// **Une date et non un `Bool`.** Trois questions du genre « est-ce que
    /// c'est arrivé ? » sont déjà répondues ici par une date — `recopiedAt`,
    /// `blobsPurgedAt`, et le `refusedBytes` qui porte sa taille plutôt qu'un
    /// drapeau — parce qu'un booléen répond « oui » et se tait sur tout le
    /// reste. La date, elle, coûte le même rien dans le cas majoritaire (un
    /// encodeur JSON omet les `nil`, et le cas majoritaire est *toutes* les
    /// entrées), se montre telle quelle dans le détail — « épinglée le
    /// 10 août » — et donne un ordre stable à une éventuelle section épinglée en
    /// tête de liste. Un `isPinned: Bool?` aurait écrit la même ligne pour en
    /// dire moins, et fait lire ce type comme deux types mélangés.
    ///
    /// **Épingler n'est pas qu'un drapeau, et c'est le point difficile.** La
    /// purge ne lit pas les entrées : elle supprime le sous-dossier `blobs/`
    /// d'un dossier-jour entier, en décidant **par le nom du dossier**, sans
    /// ouvrir un seul fichier — voir `ClipboardRetention.dayFoldersToPurge`.
    /// Exempter l'entrée ne peut donc pas suffire : son PNG serait emporté avec
    /// le dossier, et l'entrée survivrait en promettant un fichier effacé, c'est
    /// exactement la référence morte que ce type entier est écrit pour rendre
    /// impossible. La réponse est donc mécanique, pas déclarative : **épingler
    /// recopie les contenus lourds dans `Clipboard/Pinned/blobs/`**, à la racine
    /// de la bibliothèque, un dossier que la rétention ne peut pas voir puisque
    /// `ClipboardRetention.day(from: "Pinned")` rend `nil`. Le champ ci-dessus
    /// n'est que la trace de cette recopie ; c'est `ClipboardStore` qui la fait,
    /// et `ClipboardStore.pinnedFolderName` qui nomme l'endroit une seule fois,
    /// à côté de `blobsFolderName`, plutôt qu'en littéral des deux côtés.
    ///
    /// L'alternative écartée était de faire survivre le dossier-jour tant qu'il
    /// contient une entrée épinglée : une seule épingle sauvait alors les
    /// 158 Mo de PNG de sa journée, et surtout la purge redevenait une décision
    /// qui exige de lire chaque index — la fin du tour de force qui rend cette
    /// rétention sûre et instantanée.
    public var pinnedAt: Date?

    // MARK: - Les seuils

    /// Au-delà, le texte part en blob plutôt qu'en ligne dans l'index — 512 Kio.
    ///
    /// **Jamais de troncature du contenu.** L'alternative rejetée était de
    /// couper à N caractères et de garder le début : elle transforme un outil
    /// où l'on retrouve ce qu'on a copié en un outil où l'on retrouve *parfois*
    /// ce qu'on a copié, ce qui est pire que rien puisqu'on ne s'en aperçoit
    /// qu'au collage. Ce que l'utilisateur a copié n'est jamais coupé ; c'est
    /// seulement rangé ailleurs.
    ///
    /// **Mesuré en octets UTF-8 et non en caractères.** Le seuil protège la
    /// taille d'une ligne de l'index, et l'index est de l'UTF-8. Compter les
    /// caractères laisserait passer 512 Kio d'idéogrammes en 1,5 Mio de fichier.
    public static let inlineTextLimit = 512 * 1024

    /// Au-delà, rien n'est conservé — 32 Mio.
    ///
    /// Mesuré sur une installation réelle : 183 lignes de PNG pesaient 158 Mo.
    /// Sans plafond, un seul export d'image copié par mégarde suffit à faire
    /// grossir la bibliothèque d'un ordre de grandeur. Un historique de
    /// presse-papiers ne doit pas pouvoir remplir un disque.
    public static let maximumBlobBytes = 32 * 1024 * 1024

    /// La longueur du texte gardé dans l'index du jour — 512 caractères.
    ///
    /// C'est l'affaire de l'index, pas de l'entrée ; mais l'entrée doit savoir
    /// en dériver un aperçu correct, sinon chaque site d'appel en invente une
    /// version légèrement différente et la ligne du panneau cesse de
    /// correspondre au fichier.
    public static let previewLimit = 512

    // MARK: - Construction

    public init(
        id: UUID = UUID(),
        copiedAt: Date,
        kind: ClipboardKind,
        preview: String,
        recopiedAt: Date? = nil,
        repeatCount: Int? = nil,
        source: ClipboardSource? = nil,
        plainText: String? = nil,
        blobs: [ClipboardBlobRef]? = nil,
        fileURLs: [String]? = nil,
        pasteboardItems: Int? = nil,
        fullTextLength: Int? = nil,
        refusedBytes: Int? = nil,
        blobsPurgedAt: Date? = nil,
        pinnedAt: Date? = nil
    ) {
        self.id = id
        self.copiedAt = copiedAt
        self.kind = kind
        self.preview = preview
        self.recopiedAt = recopiedAt
        self.repeatCount = repeatCount
        self.source = source
        self.plainText = plainText
        self.blobs = blobs
        self.fileURLs = fileURLs
        self.pasteboardItems = pasteboardItems
        self.fullTextLength = fullTextLength
        self.refusedBytes = refusedBytes
        self.blobsPurgedAt = blobsPurgedAt
        self.pinnedAt = pinnedAt
    }

    /// Construit une entrée à partir d'un texte, en tranchant seul l'aperçu, la
    /// longueur et l'inline-ou-blob.
    ///
    /// Existe pour que « l'aperçu est dérivable correctement » soit une garantie
    /// et non une convention : trois appelants qui rognent chacun de leur côté
    /// finissent par rogner différemment. L'appelant reste responsable d'avoir
    /// **écrit** le blob quand le texte dépasse `inlineTextLimit` ; s'il ne
    /// passe rien, l'entrée naît avec une référence morte, ce que l'interface
    /// sait déjà afficher.
    public init(
        id: UUID = UUID(),
        copiedAt: Date,
        kind: ClipboardKind,
        text: String,
        source: ClipboardSource? = nil,
        blobs: [ClipboardBlobRef]? = nil,
        pasteboardItems: Int? = nil
    ) {
        let normalized = Self.normalized(text)
        self.init(
            id: id,
            copiedAt: copiedAt,
            kind: kind,
            preview: Self.preview(for: text),
            source: source,
            plainText: Self.fitsInline(text) ? text : nil,
            blobs: blobs,
            pasteboardItems: pasteboardItems,
            fullTextLength: normalized.count
        )
    }

    // MARK: - Dériver l'aperçu

    /// Le texte débarrassé de ses bords blancs. C'est de **lui** que `preview`
    /// est un préfixe, et c'est **sa** longueur que porte `fullTextLength`.
    ///
    /// Rogner les bords et rien d'autre : une copie depuis un terminal se
    /// termine presque toujours par un saut de ligne, et une ligne de panneau
    /// qui commence par du vide a l'air cassée. L'intérieur, lui, est laissé
    /// intact — l'indentation d'un bout de code est de l'information.
    public static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// L'aperçu à écrire dans l'index : le texte normalisé, rogné à
    /// `previewLimit` **caractères**.
    ///
    /// Des `Character` et non des octets ni des scalaires : `prefix` sur une
    /// `String` compte des grappes de graphèmes, donc un emoji composé ou une
    /// lettre accentuée décomposée ne peut pas être coupé en deux. Couper en
    /// octets produirait de l'UTF-8 invalide dans un fichier JSON.
    public static func preview(for text: String) -> String {
        let trimmed = normalized(text)
        guard trimmed.count > previewLimit else { return trimmed }
        return String(trimmed.prefix(previewLimit))
    }

    /// Le texte tient-il en ligne dans l'index ?
    public static func fitsInline(_ text: String) -> Bool {
        text.utf8.count <= inlineTextLimit
    }

    /// Ce contenu doit-il être refusé ?
    ///
    /// Comparaison stricte : un blob qui pèse exactement le plafond est accepté.
    /// Un plafond qu'on n'a pas le droit d'atteindre est un plafond dont le
    /// chiffre annoncé est faux.
    public static func isTooLarge(bytes: Int) -> Bool {
        bytes > maximumBlobBytes
    }

    // MARK: - Où l'entrée est rangée

    /// Le nom du dossier-jour qui contient cette entrée et ses blobs, au format
    /// `AAAA-MM-JJ`.
    ///
    /// **La seule dérivation d'un nom de dossier du dépôt, et elle part de
    /// `copiedAt`.** Elle existe pour que le couplage entre la date de première
    /// copie et l'emplacement sur le disque soit du code appelable plutôt qu'une
    /// promesse en prose : `ClipboardRetention` s'en sert pour savoir quand les
    /// blobs d'une entrée s'en vont, et un futur écrivain doit s'en servir pour
    /// savoir où les poser. Les deux ne peuvent alors plus diverger.
    ///
    /// Surtout pas `lastCopiedAt` : recopier ne déplace pas une ligne déjà
    /// écrite, donc recopier ne doit pas changer la réponse.
    public func dayFolderName(calendar: Calendar = .current) -> String {
        ClipboardRetention.dayKey(for: copiedAt, calendar: calendar)
    }

    // MARK: - Ce que la liste affiche

    /// L'instant de la copie la plus récente — la première quand il n'y en a
    /// pas eu d'autre. C'est cette date que la liste **trie**.
    ///
    /// **Ce n'est pas celle que la rétention compte.** La durée de vie d'un blob
    /// est celle de son dossier, et le dossier est nommé par `copiedAt` — voir
    /// `ClipboardRetention.expiryDate(for:)`, qui explique pourquoi c'est
    /// l'horloge du rangement qui gagne sur celle de l'usage.
    public var lastCopiedAt: Date { recopiedAt ?? copiedAt }

    /// Le nombre total de copies, recopies comprises. Vaut toujours au moins un.
    public var copyCount: Int { 1 + max(0, repeatCount ?? 0) }

    /// Mesuré : 43 entrées sur 250 ont été copiées plus d'une fois. C'est assez
    /// pour mériter un signe dans la ligne, et trop peu pour mériter une colonne.
    public var wasRecopied: Bool { copyCount > 1 }

    /// Le nombre d'éléments du presse-papiers réunis dans cette entrée.
    public var itemCount: Int {
        if let pasteboardItems, pasteboardItems > 0 { return pasteboardItems }
        if let fileURLs, fileURLs.isEmpty == false { return fileURLs.count }
        return 1
    }

    public var isMultipleItems: Bool { itemCount > 1 }

    /// La longueur du texte normalisé. Retombe sur l'aperçu quand elle n'a pas
    /// été écrite — vrai des entrées d'avant ce champ, et exact pour elles
    /// puisqu'un aperçu non rogné *est* le texte.
    public var characterCount: Int { fullTextLength ?? preview.count }

    /// L'aperçu s'arrête-t-il avant la fin du texte ? C'est ce qui autorise
    /// l'interface à poser une ellipse, et elle seule.
    public var isPreviewTruncated: Bool { characterCount > preview.count }

    /// Le texte complet est-il lisible sans toucher au disque ?
    public var isTextInline: Bool { plainText != nil }

    /// Le total en octets des contenus référencés, purgés ou non.
    public var totalBlobBytes: Int { (blobs ?? []).reduce(0) { $0 + $1.bytes } }

    /// Les chemins des fichiers copiés, **en POSIX**, décodés.
    ///
    /// **`fileURLs` contient des URL, pas des chemins, et le nom du champ le
    /// disait.** Ce qui est écrit sur le disque ressemble à
    /// `file:///Users/x/photo%20de%20vacances.png` : c'est ce que le
    /// presse-papiers porte, et le stocker tel quel est le bon choix — voir la
    /// déclaration du champ, qui explique pourquoi ce sont des `String`.
    ///
    /// Ce qui n'allait pas, c'est ce qu'on en faisait ensuite. Trois endroits
    /// les traitaient comme des chemins : `URL(fileURLWithPath:)` fabriquait
    /// alors un chemin *relatif* nommé « file: », donc un fichier inexistant, et
    /// aucun aperçu ne pouvait être produit — mesuré, c'est la raison pour
    /// laquelle une image copiée depuis le Finder ne montrait jamais qu'une
    /// icône de document. Le nom affiché s'en ressentait aussi : le dernier
    /// composant d'une URL à paramètres donnait `id=6571367.66920817`.
    ///
    /// La conversion est faite **une fois, ici**, plutôt qu'à chacun des trois
    /// sites d'appel — c'est exactement le genre de règle que trois copies font
    /// diverger. Ce qui n'est pas une URL de fichier est laissé tel quel : le
    /// presse-papiers peut porter n'importe quoi, et inventer un chemin serait
    /// pire que de rendre la chaîne d'origine.
    public var filePaths: [String] {
        (fileURLs ?? []).map { raw in
            guard raw.hasPrefix("file://"), let url = URL(string: raw), url.isFileURL else {
                return raw
            }
            let path = url.path(percentEncoded: false)
            // **La chaîne d'origine plutôt qu'un chemin vide.** `URL(string:)`
            // coupe à un `#` non encodé et rend alors un chemin tronqué ou nul.
            // Le presse-papiers de macOS encode correctement, mais cette entrée
            // peut avoir été écrite par une version antérieure ou par n'importe
            // quelle application : rendre la chaîne telle qu'elle est écrite
            // laisse au moins l'appelant afficher quelque chose de juste.
            return path.isEmpty ? raw : path
        }
    }

    /// Le nom des fichiers copiés, tel qu'une ligne doit l'écrire, ou `nil` quand
    /// l'entrée n'est pas un fichier.
    ///
    /// **Une entrée `.file` n'avait aucun titre, et c'est un défaut qu'on ne voit
    /// qu'à l'usage.** `preview` reste vide exprès pour un fichier — le contenu
    /// n'est pas lu, et y écrire quoi que ce soit mettrait une chaîne
    /// d'interface dans une donnée. La ligne retombait donc sur le nom du
    /// **type**, et l'historique affichait « Fichier », « Fichier », « Fichier »,
    /// une ligne par copie, sans qu'aucune ne se distingue d'une autre. Or le
    /// nom est là, dans `fileURLs`, depuis le premier jour.
    ///
    /// Dérivé et non stocké, pour la raison qui interdisait déjà de le mettre
    /// dans `preview` : c'est une **présentation** du chemin, et la présentation
    /// change sans que la donnée bouge.
    ///
    /// Au-delà d'un fichier, le premier nom et le compte — « photo.jpg + 4 » —
    /// plutôt que la liste : une ligne fait une ligne de haut, et le premier nom
    /// est celui qui permet de reconnaître la sélection.
    public var fileTitle: String? {
        guard kind == .file else { return nil }
        let paths = filePaths
        guard let first = paths.first else { return nil }
        let name = (first as NSString).lastPathComponent
        guard name.isEmpty == false else { return nil }
        return paths.count > 1 ? "\(name) + \(paths.count - 1)" : name
    }

    /// Le type des fichiers copiés, en majuscules — « JPG », « MP3 » — ou `nil`
    /// quand il n'y en a pas.
    ///
    /// Ce que la ligne met à la place du poids, qu'un fichier copié n'a pas :
    /// rien n'est lu, donc rien n'est pesé, et aller le chercher coûterait un
    /// accès disque par ligne dessinée. L'extension, elle, est dans le chemin.
    /// **Tout ce qui suit un point n'est pas une extension**, et l'historique
    /// réel l'a montré au premier essai : des entrées dont le chemin finissait
    /// par `id=6571367.66920817` annonçaient fièrement le type « 66920817 ». Une
    /// extension de fichier est courte et alphabétique — `jpg`, `png`, `mp3`,
    /// `heic`. Ce qui ne l'est pas ne se laisse pas nommer, et il vaut mieux ne
    /// rien dire que d'inventer un type.
    public var fileTypeName: String? {
        guard kind == .file, let first = filePaths.first else { return nil }
        let ext = (first as NSString).pathExtension
        guard (1...5).contains(ext.count) else { return nil }
        guard ext.allSatisfy(\.isLetter) else { return nil }
        return ext.uppercased()
    }

    /// Les blobs ont-ils été supprimés par la rétention ? L'entrée, elle, reste.
    public var blobsArePurged: Bool { blobsPurgedAt != nil }

    /// L'entrée est-elle épinglée, donc gardée indéfiniment ?
    ///
    /// La question est posée à deux endroits qui n'ont rien à voir — la
    /// rétention avant d'inscrire une entrée sur sa liste de purge, la liste
    /// avant de dessiner l'épingle — et elle doit avoir une seule réponse, pour
    /// la même raison que `blobsArePurged` juste au-dessus : trois sites
    /// d'appel qui écrivent `pinnedAt != nil` chacun de leur côté finissent par
    /// écrire des conditions légèrement différentes, et c'est la purge qui perd.
    public var isPinned: Bool { pinnedAt != nil }

    /// Le contenu a-t-il été refusé à l'écriture pour cause de taille ?
    public var isRefused: Bool { refusedBytes != nil }

    /// Y a-t-il encore quelque chose à recoller ?
    ///
    /// Un bouton désactivé avec sa raison, jamais un bouton qui échoue — même
    /// parti pris que `SnippetEntry.canRetry`.
    ///
    /// **Le texte en ligne est testé avant la purge, et l'ordre est le fond de
    /// l'affaire.** `plainText` vit dans l'index, que la rétention ne touche
    /// jamais ; un `richText` dont le RTF est parti garde donc de quoi coller.
    /// Répondre `false` par symétrie avec les autres cas ferait griser un bouton
    /// qui marcherait très bien. Ce qui est perdu, c'est la mise en forme, et
    /// c'est `isComplete` qui le dit.
    public var canPaste: Bool {
        if isRefused { return false }
        if plainText != nil { return true }
        if blobsArePurged { return false }
        if let blobs, blobs.isEmpty == false { return true }
        if let fileURLs, fileURLs.isEmpty == false { return true }
        return false
    }

    /// Le contenu est-il encore celui qui a été copié, entier ?
    ///
    /// `false` quand il a été refusé à l'écriture ou purgé depuis. C'est la
    /// phrase que l'interface doit poser à côté d'une entrée diminuée — « mise
    /// en forme perdue », « image purgée le 10 août » — plutôt que de faire
    /// semblant que rien n'a changé.
    public var isComplete: Bool { isRefused == false && blobsArePurged == false }

    /// Une seule ligne, blancs intérieurs réduits, pour la ligne compacte.
    ///
    /// L'indentation disparaît ici et nulle part ailleurs : sur une ligne de
    /// hauteur fixe, huit espaces de tête ne montrent rien et volent la moitié
    /// de la largeur. `preview` garde le texte tel quel pour le détail et pour
    /// la recherche.
    public var rowTitle: String {
        let first = preview.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return first.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Résumé compact de la taille, pour le pied de la ligne.
    ///
    /// Le refus passe avant le reste : c'est la seule des trois branches qui
    /// annonce une absence, et l'annoncer est tout l'intérêt de la garder.
    public var sizeDescription: String {
        if let refusedBytes {
            return "\(Self.formatted(bytes: refusedBytes)) — non conservé"
        }
        if totalBlobBytes > 0 {
            return Self.formatted(bytes: totalBlobBytes)
        }
        return "\(characterCount) caractères"
    }

    /// `Int64` et non `Int` : `ByteCountFormatStyle` n'accepte que celui-là, et
    /// `ClipboardBlobRef.bytes` est un `Int`.
    public static func formatted(bytes: Int) -> String {
        Int64(bytes).formatted(.byteCount(style: .file))
    }

    // MARK: - Faire évoluer une entrée

    /// La même entrée, recopiée à cet instant.
    ///
    /// Une valeur rendue plutôt qu'une mutation en place : l'entrée est une
    /// valeur, et c'est le magasin qui décide de réécrire la ligne. Le compteur
    /// monte, la date la plus récente avance, le reste ne bouge pas — surtout
    /// pas `copiedAt`, qui désigne le dossier-jour où la ligne est écrite.
    ///
    /// **La date de départ du blob ne bouge pas non plus.** Le blob est déjà
    /// posé dans le dossier de la première copie ; recopier n'y touche pas, donc
    /// recopier ne peut pas prolonger sa vie sans mentir. `ClipboardRetention`
    /// compte depuis `copiedAt` pour cette raison exactement.
    ///
    /// Mesuré : **aucune** recopie à plus d'un jour d'écart sur 250 entrées.
    /// C'est ce qui rend légitime de ne chercher l'entrée à faire monter que
    /// dans le dossier du jour, et donc de ne jamais rouvrir hier.
    public func recopied(at date: Date) -> ClipboardEntry {
        var copy = self
        copy.repeatCount = (repeatCount ?? 0) + 1
        copy.recopiedAt = Swift.max(date, lastCopiedAt)
        return copy
    }

    /// La même entrée, ses blobs déclarés partis.
    ///
    /// Les références restent : c'est ce qui permet de dire *quoi* a disparu.
    public func purgingBlobs(at date: Date) -> ClipboardEntry {
        var copy = self
        copy.blobsPurgedAt = date
        return copy
    }

    /// La même entrée, épinglée à cet instant — donc soustraite à la rétention.
    ///
    /// Une valeur rendue plutôt qu'une mutation en place, comme les deux
    /// méthodes ci-dessus : l'entrée est une valeur, et c'est le magasin qui
    /// décide de réécrire la ligne.
    ///
    /// **Épingler une entrée déjà épinglée ne change rien, pas même la date.**
    /// Ce second geste n'arrive qu'en double — un double-clic, un état
    /// réappliqué au chargement, une commande rejouée après un échec d'écriture
    /// — et aucun des trois n'est une nouvelle décision de l'utilisateur.
    /// Laisser la date se réécrire ferait avancer toute seule la ligne
    /// « épinglée le 10 août » que le détail affiche, ce qui est mot pour mot le
    /// défaut que `ClipboardRetention` évite en refusant de repurger une entrée
    /// déjà purgée. Le prix de ce choix est qu'on ne peut pas *déplacer* la date
    /// d'un coup : il faut désépingler puis réépingler, c'est-à-dire décrire le
    /// geste qu'on a réellement fait.
    ///
    /// **Ce que cette méthode ne fait pas, et ne peut pas faire :** recopier les
    /// contenus lourds dans `Clipboard/Pinned/blobs/`. Sans cette recopie,
    /// l'épingle est une promesse que le prochain balayage contredit, puisque
    /// la purge emporte le sous-dossier `blobs/` du jour sans jamais lire une
    /// entrée. Un type de valeur ne touche pas au disque ; c'est `ClipboardStore`
    /// qui écrit d'abord et n'appelle ceci qu'ensuite, dans cet ordre-là, pour
    /// la même raison qui lui fait marquer avant de supprimer.
    public func pinned(at date: Date) -> ClipboardEntry {
        guard isPinned == false else { return self }
        var copy = self
        copy.pinnedAt = date
        return copy
    }

    /// La même entrée, désépinglée : elle redevient soumise à la rétention.
    ///
    /// **Le champ est remis à `nil`, il n'est pas doublé d'un `unpinnedAt`.**
    /// Savoir *quand* quelqu'un a cessé de vouloir garder quelque chose ne sert
    /// à personne : ça ne s'affiche pas, ça ne se trie pas, et ça ne change
    /// aucune décision de purge. Un champ de plus dans chaque ligne écrite pour
    /// une information que rien ne lit est exactement ce que le paragraphe en
    /// tête de ce fichier interdit.
    ///
    /// **Désépingler ne ressuscite pas la rétention rétroactivement, et n'a pas
    /// à le faire.** Si le dossier-jour de l'entrée a perdu ses blobs pendant
    /// qu'elle était épinglée, le balayage suivant la retrouve — son dossier est
    /// toujours candidat — et la marque enfin purgée, avec la date de ce
    /// balayage-là. C'est honnête : le fichier disparaît quand le magasin
    /// supprime la copie de `Pinned/blobs/`, c'est-à-dire maintenant, et pas au
    /// jour où le dossier d'origine a été vidé.
    public func unpinned() -> ClipboardEntry {
        var copy = self
        copy.pinnedAt = nil
        return copy
    }
}
