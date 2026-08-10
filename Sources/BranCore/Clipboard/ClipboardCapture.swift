import Foundation

/// L'étage qui manquait entre la machine et le magasin.
///
/// `ClipboardMachine` rend un `ClipboardCapturePlan` — « lis ces types-là, range
/// ça en `richText` ». `ClipboardStore` sait écrire un `ClipboardEntry` et des
/// `ClipboardBlobPayload`. Entre les deux il restait une traduction que personne
/// ne faisait : des octets bruts vers une entrée et ses contenus lourds. Elle est
/// ici, et elle est **pure** — pas de disque, pas de `Date.now`, pas de
/// presse-papiers, pas d'AppKit.
///
/// **Pourquoi un fichier de plus plutôt qu'une méthode sur `ClipboardEntry`.**
/// L'entrée est une valeur que le magasin, la rétention et l'interface se
/// partagent ; lui greffer la connaissance des identifiants de type d'Apple la
/// rendrait dépendante d'une table qui bouge à chaque version de macOS, et lui
/// greffer la connaissance des `ClipboardBlobPayload` la rendrait dépendante du
/// magasin, qu'elle ne connaît pas. La traduction est le seul endroit qui a besoin
/// des deux ; elle vit donc seule.
///
/// **Pourquoi c'est pur.** Le presse-papiers ne se lit qu'avec AppKit, et AppKit
/// ne se teste ni sans écran ni sans autorisation. Toute la décision est donc
/// déplacée ici, où elle s'exécute en microsecondes : l'appelant dans `BranApp` se
/// réduit à « lis ces types, passe-moi le dictionnaire », ce qui est la seule
/// partie qu'on ne sait pas tester. Même partage que `ClipboardMachine` et ses
/// deux sœurs `SnapshotMachine` et `DictationMachine`.
///
/// **Un `enum` sans cas, et non un `struct`.** Il n'y a rien à instancier : ni
/// état, ni réglage. Un `struct` laisserait croire qu'un jour il y aura un
/// `ClipboardCapture()` quelque part, et le premier appelant qui en construirait
/// un en ferait une propriété. `ClipboardTypePolicy` est un `struct` parce qu'il
/// porte un réglage ; celui-ci n'en porte aucun.
public enum ClipboardCapture {

    // MARK: - La traduction

    /// Construit l'entrée et ses contenus lourds à partir de ce qui a été lu.
    ///
    /// - Parameters:
    ///   - plan: ce que la machine a décidé de lire, et sous quelle sorte le
    ///     ranger. C'est lui qui fait foi, jamais le contenu du dictionnaire : un
    ///     élément qui porte du PNG **et** du HTML a déjà été arbitré par
    ///     `ClipboardTypePolicy.plan(for:)`, et réarbitrer ici donnerait deux
    ///     réponses à une seule question.
    ///   - reading: les octets effectivement obtenus.
    ///   - source: l'application au premier plan, `nil` quand elle n'a pas pu être
    ///     lue. Traversé tel quel : inventer « Inconnu » mettrait une chaîne
    ///     d'interface dans une donnée.
    ///   - copiedAt: l'instant de la copie. **Passé, jamais lu à l'horloge** —
    ///     c'est lui qui décide du dossier-jour, donc de la purge, et une fonction
    ///     qui appellerait `.now` rendrait le rangement dépendant de l'heure à
    ///     laquelle le test s'exécute.
    ///   - id: l'identifiant de l'entrée. Paramétrable pour les tests et pour un
    ///     appelant qui aurait déjà réservé un identifiant ; le défaut est le bon.
    ///
    /// - Returns: `nil` **uniquement** quand absolument rien n'a pu être décodé —
    ///   pas un octet lisible sous le type principal, et pas d'aplatissement de
    ///   secours. Tous les autres cas rendent une entrée, quitte à ce qu'elle soit
    ///   diminuée : un aperçu vide reste une entrée qu'on peut recoller, alors
    ///   qu'un `nil` est une copie qui n'a jamais existé.
    ///
    /// **Ce que cette fonction ne décide pas, et ne doit jamais décider.**
    /// - Le **refus de taille**. `ClipboardStore.save` le tranche seul et
    ///   globalement : si un seul contenu dépasse `maximumBlobBytes`, aucun n'est
    ///   écrit et l'entrée naît avec `refusedBytes`. Filtrer les gros contenus ici
    ///   produirait une entrée à moitié vraie, dont l'interface ne saurait dire ni
    ///   qu'elle est complète ni qu'elle est refusée — et surtout, deux endroits
    ///   appliqueraient la même règle, donc deux endroits pourraient diverger.
    /// - L'**aperçu**. `ClipboardEntry.preview(for:)`, `normalized(_:)` et
    ///   `fitsInline(_:)` le dérivent, et ce sont les seules dérivations qui
    ///   existent. En recalculer une ici ferait que la ligne du panneau cesserait
    ///   de correspondre au fichier au premier correctif appliqué d'un seul côté.
    /// - La **fraîcheur**. `ClipboardReading.matches(_:)` existe pour que
    ///   l'appelant vérifie que le compteur n'a pas rebougé pendant qu'il lisait,
    ///   mais c'est à lui de le faire : rendre `nil` pour un contenu périmé
    ///   fondrait deux verdicts très différents — « illisible » et « trop tard » —
    ///   dans une seule valeur, que personne ne saurait plus interpréter.
    ///
    /// **`plan.measuresDimensions` n'a aujourd'hui aucune destination.** Le plan
    /// demande à l'appelant de relever les dimensions d'une image pendant qu'il la
    /// tient, mais `ClipboardEntry` n'a aucun champ où les poser. Rien n'est
    /// inventé ici : un champ ajouté sur une intuition fige un format pour
    /// toujours, et le contrat de `ClipboardKind.swift` veut qu'un champ ajouté
    /// après la première écriture soit `Optional` et argumenté. Le jour où
    /// l'interface en a besoin, ce sera un `pixelWidth: Int?` et un
    /// `pixelHeight: Int?` sur l'entrée, plus un paramètre de plus ici.
    public static func make(
        for plan: ClipboardCapturePlan,
        reading: ClipboardReading,
        source: ClipboardSource?,
        copiedAt: Date,
        id: UUID = UUID()
    ) -> ClipboardCaptureResult? {
        switch plan.kind {
        case .text:
            makeText(plan, reading, source, copiedAt, id)
        case .richText:
            makeRichText(plan, reading, source, copiedAt, id)
        case .image:
            makeImage(plan, reading, source, copiedAt, id)
        case .file:
            makeFile(plan, reading, source, copiedAt, id)
        }
    }

    // MARK: - Texte brut

    /// Le cas de loin le plus fréquent, et le seul qui tienne souvent en ligne.
    ///
    /// **Tout est délégué à l'initialiseur `text:` de `ClipboardEntry`** : aperçu,
    /// longueur normalisée, et le choix entre le texte en ligne et le blob. C'est
    /// exactement ce que cet initialiseur existe pour garantir, et le refaire ici
    /// serait la faute qu'il a été écrit pour empêcher.
    ///
    /// **Le blob de débordement est produit ici, et il n'est pas facultatif.**
    /// L'initialiseur met `plainText` à `nil` dès que le texte dépasse
    /// `inlineTextLimit`, sans rien écrire de son côté : sans ce blob, l'entrée
    /// naîtrait avec son texte perdu, et l'utilisateur ne s'en apercevrait qu'au
    /// collage. 512 Kio de texte brut, c'est rare — mais c'est un journal ou un
    /// export CSV, précisément les choses qu'on cherche dans un historique parce
    /// qu'on ne les a gardées nulle part ailleurs.
    ///
    /// **Le blob porte l'UTF-8 du texte décodé, et non les octets d'origine.** Un
    /// `public.utf16-external-plain-text` de 600 Kio donnerait sinon un `.txt` en
    /// UTF-16 avec sa nomenclature, que la moitié des outils en ligne de commande
    /// lisent de travers — et le dossier est fait pour être ouvert à la main. Le
    /// seul écart mesurable est la nomenclature, qui n'était pas du contenu.
    private static func makeText(
        _ plan: ClipboardCapturePlan,
        _ reading: ClipboardReading,
        _ source: ClipboardSource?,
        _ copiedAt: Date,
        _ id: UUID
    ) -> ClipboardCaptureResult? {
        let decoded = reading.values(of: plan.primaryType).first
            .flatMap { decodeText($0, as: plan.primaryType) }

        // L'aplatissement de secours ne sert normalement pas ici — un élément qui
        // porte du texte brut n'a rien à aplatir — mais il coûte une ligne et il
        // rattrape le seul cas où la lecture a échoué là où l'appelant, lui, avait
        // obtenu une chaîne.
        guard let text = decoded ?? reading.flattenedText, text.isEmpty == false else { return nil }

        var payloads: [ClipboardBlobPayload] = []
        if ClipboardEntry.fitsInline(text) == false {
            payloads.append(
                ClipboardBlobPayload(
                    data: Data(text.utf8), ext: fileExtension(for: plan.primaryType)
                )
            )
        }

        let entry = ClipboardEntry(
            id: id,
            copiedAt: copiedAt,
            kind: .text,
            text: text,
            source: source,
            blobs: references(of: payloads)
            // Pas de `pasteboardItems` : on ne garde que l'élément qui a décidé,
            // donc l'entrée en porte un. Voir `storedItemCount` — supprimé — et
            // la règle qui l'a remplacé dans `makeFile`.
        )
        return ClipboardCaptureResult(entry: entry, payloads: payloads)
    }

    // MARK: - Texte enrichi

    /// La sorte la plus riche, et la seule qui puisse porter trois contenus.
    ///
    /// **Le texte brut reste en ligne, et c'est tout l'intérêt.** « Coller sans
    /// mise en forme » est le geste le plus demandé après « coller » ; le servir
    /// depuis un blob coûterait un accès disque par collage, et ne coûterait plus
    /// rien du tout le jour où la rétention a emporté le blob — parce qu'il n'y
    /// aurait plus rien à coller. En ligne, il survit à la purge, l'index n'étant
    /// jamais purgé : un `richText` de l'an dernier reste collable en texte brut.
    /// C'est exactement ce que `ClipboardEntry.canPaste` teste **avant**
    /// `blobsArePurged`, et ce test n'est vrai que si quelqu'un pose le texte en
    /// ligne. Ce quelqu'un, c'est ici.
    ///
    /// **Trois contenus au plus, et ils ne sont pas de même nature :**
    /// - la forme enrichie (RTF, RTFD, HTML) : toujours un blob, c'est *le*
    ///   contenu ;
    /// - le rendu matriciel, quand la source en a posé un sur le même élément :
    ///   un second blob, pour qu'un futur « coller comme image » ne recapture
    ///   rien ;
    /// - le texte brut, en ligne — sauf s'il déborde `inlineTextLimit`, auquel
    ///   cas il devient un troisième blob plutôt que d'être perdu.
    ///
    /// **À défaut de compagnon texte et d'aplatissement, l'aperçu est vide, et on
    /// ne l'invente pas.** Aplatir du RTF exige AppKit — c'est-à-dire un écran et
    /// une autorisation — donc ça ne peut pas se faire ici ; et écrire « (texte
    /// enrichi) » dans `preview` mettrait une chaîne d'interface dans une donnée,
    /// qu'une recherche plein texte se mettrait ensuite à trouver. Une entrée sans
    /// aperçu reste parfaitement collable : elle porte son blob.
    private static func makeRichText(
        _ plan: ClipboardCapturePlan,
        _ reading: ClipboardReading,
        _ source: ClipboardSource?,
        _ copiedAt: Date,
        _ id: UUID
    ) -> ClipboardCaptureResult? {
        // Les compagnons se prennent sur **l'élément qui a décidé**, jamais sur le
        // presse-papiers entier : c'est la règle de
        // `ClipboardTypePolicy.companions(for:in:)`, et elle tient parce qu'un
        // compagnon est une autre vue du *même* objet. Aller chercher le texte
        // brut d'un élément voisin collerait le nom d'un fichier sous une citation
        // copiée du web, sans que rien ne le signale.
        let item = reading.item(carrying: plan.primaryType)
        let primary = bytes(plan.primaryType, in: item)

        let plainType = plan.companionTypes.first { ClipboardTypePolicy.textTypes.contains($0) }
        let renderingType = plan.companionTypes.first { ClipboardTypePolicy.imageTypes.contains($0) }
        let rendering = bytes(renderingType, in: item)

        let plain: String? = {
            if let plainType, let data = bytes(plainType, in: item),
               let decoded = decodeText(data, as: plainType), decoded.isEmpty == false {
                return decoded
            }
            // Le compagnon de l'application vaut mieux qu'une conversion, mais
            // une conversion vaut mieux que rien : c'est la seule raison d'être
            // de `flattenedText`.
            return reading.flattenedText.flatMap { $0.isEmpty ? nil : $0 }
        }()

        // L'ordre est celui de `plan.types`, contenu d'abord : c'est celui que
        // l'interface lira pour décider quoi proposer, et le premier blob d'un
        // `richText` doit être sa forme enrichie, jamais son rendu.
        var payloads: [ClipboardBlobPayload] = []
        if let primary {
            payloads.append(
                ClipboardBlobPayload(data: primary, ext: fileExtension(for: plan.primaryType))
            )
        }
        if let plain, ClipboardEntry.fitsInline(plain) == false {
            payloads.append(ClipboardBlobPayload(data: Data(plain.utf8), ext: plainTextExtension))
        }
        if let rendering, let renderingType {
            payloads.append(
                ClipboardBlobPayload(data: rendering, ext: fileExtension(for: renderingType))
            )
        }

        // Ni forme, ni texte : il n'y a pas d'entrée à écrire. Une ligne qui ne
        // porte rien n'est pas une trace, c'est du bruit dans une liste qu'on
        // parcourt à l'œil.
        guard payloads.isEmpty == false || plain != nil else { return nil }

        let blobs = references(of: payloads)
        // Un seul élément gardé, donc un seul annoncé : un `richText` porte ses
        // trois contenus — la forme enrichie, le texte brut, le rendu matriciel
        // — pour **un** objet, et ils sont pris sur le seul élément qui a
        // décidé. Reprendre le chiffre du plan ferait annoncer deux éléments
        // pour un seul contenu conservé.
        let items: Int? = nil

        guard let plain else {
            // **Surtout pas l'initialiseur `text:` avec une chaîne vide.** Il
            // poserait `plainText = ""` — vide mais non `nil` —, ce qui rendrait
            // `isTextInline` vrai pour une entrée sans une once de texte, et
            // ferait croire à `canPaste` qu'il y a de quoi coller sans mise en
            // forme. La différence entre « rien » et « la chaîne vide » est
            // exactement ce que ces deux propriétés lisent.
            return ClipboardCaptureResult(
                entry: ClipboardEntry(
                    id: id,
                    copiedAt: copiedAt,
                    kind: .richText,
                    preview: "",
                    source: source,
                    blobs: blobs,
                    pasteboardItems: items
                ),
                payloads: payloads
            )
        }

        return ClipboardCaptureResult(
            entry: ClipboardEntry(
                id: id,
                copiedAt: copiedAt,
                kind: .richText,
                text: plain,
                source: source,
                blobs: blobs,
                pasteboardItems: items
            ),
            payloads: payloads
        )
    }

    // MARK: - Image

    /// La plus lourde des quatre : toujours un blob, jamais en ligne.
    ///
    /// **`preview` vide et `plainText` nil, sans discussion.** C'est le contrat
    /// écrit noir sur blanc dans `ClipboardEntry.preview` : il n'y a rien à dire
    /// en texte d'une image, et y écrire « (image) » mettrait une chaîne
    /// d'interface dans une donnée. Le nom de fichier qu'une application pose
    /// souvent à côté d'une capture est du texte *voisin*, pas une description de
    /// l'image ; le reprendre en aperçu ferait afficher « Capture d'écran 3.png »
    /// comme si c'était le contenu — et la recherche plein texte se mettrait à
    /// trouver des images par un nom que l'utilisateur n'a jamais tapé.
    ///
    /// Les dimensions ne sont pas relevées ici : voir la note sur
    /// `plan.measuresDimensions` dans `make(for:reading:source:copiedAt:id:)`.
    private static func makeImage(
        _ plan: ClipboardCapturePlan,
        _ reading: ClipboardReading,
        _ source: ClipboardSource?,
        _ copiedAt: Date,
        _ id: UUID
    ) -> ClipboardCaptureResult? {
        // **Toutes les images, et non la première.** Un plan peut annoncer
        // plusieurs éléments portant le même type matriciel — un
        // `writeObjects` de deux images en est un —, et n'en garder qu'une
        // transformait une copie de deux images en une copie d'une image, tout
        // en écrivant « 2 éléments » dans l'entrée. Le contenu manquant ne se
        // voyait nulle part, et le chiffre affiché mentait par-dessus.
        //
        // Le contenu adressé par son empreinte rend le cas dégénéré gratuit :
        // deux fois la même image donnent deux fois la même empreinte, donc un
        // seul fichier sur le disque et une seule référence ici.
        let datas = reading.values(of: plan.primaryType)
        guard datas.isEmpty == false else { return nil }

        let extensionName = fileExtension(for: plan.primaryType)
        var payloads: [ClipboardBlobPayload] = []
        var references: [ClipboardBlobRef] = []
        for data in datas {
            let payload = ClipboardBlobPayload(data: data, ext: extensionName)
            guard references.contains(payload.ref) == false else { continue }
            payloads.append(payload)
            references.append(payload.ref)
        }

        let entry = ClipboardEntry(
            id: id,
            copiedAt: copiedAt,
            kind: .image,
            preview: "",
            source: source,
            blobs: references,
            // Le compte de ce qui est **gardé**, jamais celui du plan : voir la
            // même règle et la même raison dans `makeFile`.
            pasteboardItems: references.count > 1 ? references.count : nil
        )
        return ClipboardCaptureResult(entry: entry, payloads: payloads)
    }

    // MARK: - Fichiers

    /// Des chemins, et **aucun blob** : le contenu du fichier n'est jamais repris.
    ///
    /// Ce que le presse-papiers porte est une URL, et le fichier peut être déplacé
    /// ou supprimé ensuite ; l'entrée devient alors morte, et le dit — même parti
    /// pris que la dictée dont l'audio a été purgé. Recopier le contenu ferait
    /// d'un glisser de dossier de 4 Go une entrée d'historique, ce qu'aucune
    /// rétention ne rattraperait.
    ///
    /// **Des `String` et non des `URL`.** La raison est écrite dans
    /// `ClipboardEntry.fileURLs` et elle est sérieuse : le `Decodable` d'`URL`
    /// échoue sur une valeur qu'il ne sait pas analyser, et cet échec ferait
    /// tomber le décodage de l'entrée **entière** — un chemin bizarre effacerait
    /// une ligne d'historique. La conversion est l'affaire du site d'appel, qui
    /// peut la voir échouer sans rien perdre.
    ///
    /// `preview` vide, pour la même raison que l'image : le chemin est déjà dans
    /// `fileURLs`, et le recopier en aperçu ferait deux vérités pour une donnée.
    private static func makeFile(
        _ plan: ClipboardCapturePlan,
        _ reading: ClipboardReading,
        _ source: ClipboardSource?,
        _ copiedAt: Date,
        _ id: UUID
    ) -> ClipboardCaptureResult? {
        // Tous les éléments, et pas seulement celui qui a décidé : une sélection
        // multiple du Finder est N éléments portant chacun sa `public.file-url`,
        // et n'en garder qu'une transformerait une copie de douze fichiers en une
        // copie d'un fichier — silencieusement, ce qui est le pire.
        let paths = reading.values(of: plan.primaryType)
            .flatMap { decodeFilePaths($0, as: plan.primaryType) }
        guard paths.isEmpty == false else { return nil }

        // **Le compte n'est pas repris du plan, il est celui des chemins gardés.**
        // Le plan annonce ce que le presse-papiers déclarait ; ce qui a
        // effectivement été décodé peut être moindre — une `public.file-url`
        // illisible sur trois. Recopier le chiffre du plan ferait dire à l'entrée
        // « trois fichiers » en n'en portant que deux, et rien dans l'interface
        // ne pourrait le rattraper. `ClipboardEntry.itemCount` retombe sur
        // `fileURLs.count`, qui est le seul chiffre dont on réponde.
        //
        // Ça règle du même coup `NSFilenamesPboardType`, qui porte N chemins dans
        // **un** élément : le plan y compte 1 là où la copie en compte N.
        let entry = ClipboardEntry(
            id: id,
            copiedAt: copiedAt,
            kind: .file,
            preview: "",
            source: source,
            fileURLs: paths
        )
        return ClipboardCaptureResult(entry: entry, payloads: [])
    }

    // MARK: - Décoder

    /// L'UTF-16 « externe » du presse-papiers, avec sa nomenclature.
    ///
    /// Nommé ici parce que c'est le **seul** type de la table dont l'encodage
    /// n'est pas de l'UTF-8, et que le décider sur une comparaison de chaîne au
    /// milieu d'une fonction rendrait la règle invisible.
    /// `ClipboardTypePolicy.textTypes` le liste sans le distinguer — il n'a pas à
    /// le faire, il ne décode rien.
    public static let externalUTF16Type = "public.utf16-external-plain-text"

    /// L'identifiant hérité qui porte un plist de chemins plutôt qu'une URL.
    public static let legacyFilenamesType = "NSFilenamesPboardType"

    /// L'extension d'un blob de texte brut.
    public static let plainTextExtension = "txt"

    /// Décode des octets de presse-papiers en chaîne, selon ce que leur type
    /// promet.
    ///
    /// **Strict, et `nil` franc quand ça échoue.** Trois replis ont été envisagés
    /// et écartés, tous pour la même raison :
    ///
    /// - *Réparer en UTF-8 permissif* (`String(decoding:as:)`, qui remplace les
    ///   séquences invalides par U+FFFD) : l'entrée survivrait, mais son texte ne
    ///   serait plus celui qui a été copié, et le recoller réinjecterait des
    ///   losanges dans le document de l'utilisateur. Un historique dont on ne peut
    ///   pas croire le contenu ne remplace pas la mémoire, il la simule.
    /// - *Réessayer en UTF-16 quand l'UTF-8 échoue* : sur un nombre pair d'octets,
    ///   un décodage UTF-16 réussit presque toujours — en produisant des
    ///   idéogrammes au hasard. C'est la pire des issues, parce qu'elle a l'air
    ///   d'un succès.
    /// - *Retomber sur `isoLatin1`*, qui ne peut jamais échouer : même défaut, du
    ///   mojibake présenté comme du texte.
    ///
    /// Le repli retenu est ailleurs, et il est légitime : l'appelant a peut-être
    /// obtenu la chaîne autrement, et `ClipboardReading.flattenedText` la porte. À
    /// défaut, la copie est rendue `nil` — **pas en silence** : le site d'appel
    /// reçoit `nil` de `make` et doit le journaliser, exactement comme il
    /// journalise un `ClipboardSkip.nothingUsable`. Une lecture d'octets qui
    /// échoue sur un type que macOS a déclaré est une anomalie qui mérite d'être
    /// vue, pas une entrée à fabriquer coûte que coûte.
    ///
    /// L'UTF-16 « externe » se décode avec `.utf16`, qui honore la nomenclature
    /// quand elle est là et suppose le gros-boutisme quand elle ne l'est pas — ce
    /// qui est exactement la définition de la représentation externe.
    static func decodeText(_ data: Data, as type: String) -> String? {
        String(data: data, encoding: type == externalUTF16Type ? .utf16 : .utf8)
    }

    /// Le seul caractère qu'on rogne au bord d'un chemin : le NUL.
    ///
    /// Il n'est pas décoratif : certains écrivains posent une chaîne C terminée,
    /// et un `\0` final rend le chemin introuvable sans que rien ne le dise —
    /// `FileManager` ne le trouve pas, et l'affichage, lui, a l'air normal.
    ///
    /// **Et lui seul, alors que la première version rognait aussi les blancs.**
    /// C'était une erreur, et une erreur silencieuse : sur un système de fichiers
    /// POSIX, l'espace et le saut de ligne sont des caractères de nom de fichier
    /// parfaitement légaux, et `NSFilenamesPboardType` porte des chemins **nus**,
    /// pas des URL encodées. Un fichier réellement nommé « brouillon  » se
    /// serait retrouvé rangé sous « brouillon », c'est-à-dire sous un chemin qui
    /// ne désigne rien — une entrée morte à la naissance, sans un mot.
    ///
    /// Le NUL, lui, ne peut apparaître dans aucun chemin : c'est le terminateur
    /// de chaîne du noyau. Le rogner ne peut donc jamais retirer du nom.
    private static let pathNoise = CharacterSet(charactersIn: "\0")

    /// Les chemins portés par une représentation, sous forme de chaînes.
    ///
    /// **Deux formats, parce que macOS en a deux.** `public.file-url` porte une
    /// URL en UTF-8, une par élément. `NSFilenamesPboardType`, que les
    /// applications antérieures à 10.6 posent encore, porte un plist contenant un
    /// **tableau** de chemins dans un seul élément. Ne traiter que le premier
    /// donnerait, pour le second, une `fileURLs` contenant du XML : une entrée
    /// visiblement absurde, mais écrite sans un mot. `PropertyListSerialization`
    /// vient de Foundation ; le reconnaître ne coûte donc pas une dépendance.
    ///
    /// Ce que le plist rend n'est pas une URL mais un chemin nu (`/Users/…`), et
    /// c'est très bien : `fileURLs` est documenté comme portant des chaînes que le
    /// site d'appel convertit, et il sait convertir les deux formes.
    static func decodeFilePaths(_ data: Data, as type: String) -> [String] {
        if type == legacyFilenamesType,
           let plist = try? PropertyListSerialization.propertyList(
               from: data, options: [], format: nil
           ),
           let paths = plist as? [String] {
            return paths.compactMap { cleanedPath($0) }
        }
        guard let text = String(data: data, encoding: .utf8),
              let path = cleanedPath(text)
        else { return [] }
        return [path]
    }

    private static func cleanedPath(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: pathNoise)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Nommer les blobs

    /// L'extension d'un blob, déduite de l'identifiant de type qui l'a porté.
    ///
    /// **Elle n'est pas décorative** : c'est elle qui permet à Quick Look d'ouvrir
    /// le fichier depuis le Finder, ce qui est la moitié de l'intérêt d'une
    /// bibliothèque qui est un simple dossier — `ClipboardBlobRef.ext` le dit
    /// déjà. Une table explicite plutôt qu'un appel à `UTType`, pour deux raisons :
    /// `UniformTypeIdentifiers` traîne CoreServices, que `BranCore` refuse pour
    /// rester testable sans écran ; et `UTType.preferredFilenameExtension` rend
    /// `nil` sur un identifiant hérité comme `NSStringPboardType`, ce qui
    /// obligerait de toute façon à écrire cette table à côté.
    ///
    /// Les clés sont exactement celles des quatre tiers de `ClipboardTypePolicy`.
    /// Le défaut ne devrait donc jamais servir : un plan ne peut nommer qu'un
    /// identifiant de ces tables. Il existe pour qu'un type ajouté à la politique
    /// sans ligne correspondante ici produise un fichier maladroitement nommé
    /// plutôt qu'un plantage — et `dat` se voit assez pour être corrigé.
    public static let blobExtensions: [String: String] = [
        // Matriciel.
        "public.png": "png",
        "public.tiff": "tiff",
        "public.jpeg": "jpeg",
        "public.heic": "heic",
        "public.heif": "heif",
        "com.compuserve.gif": "gif",
        "com.microsoft.bmp": "bmp",
        // Enrichi. Les deux RTFD partagent leur extension : `com.apple.flat-rtfd`
        // est la version « à plat » du paquet `public.rtfd`, et c'est la seule que
        // le presse-papiers transporte — un blob est un fichier, pas un dossier.
        "public.rtf": "rtf",
        "com.apple.flat-rtfd": "rtfd",
        "public.rtfd": "rtfd",
        "public.html": "html",
        // Texte brut, toutes déclinaisons confondues : ce qu'on écrit est de
        // l'UTF-8, quel que soit l'encodage d'origine.
        "public.utf8-plain-text": plainTextExtension,
        "public.utf16-external-plain-text": plainTextExtension,
        "public.plain-text": plainTextExtension,
        "NSStringPboardType": plainTextExtension,
    ]

    public static func fileExtension(for type: String) -> String {
        blobExtensions[type] ?? "dat"
    }

    // MARK: - Petits arbitrages partagés

    /// Les octets d'un type dans un élément, `nil` dès qu'il n'y a rien à écrire.
    ///
    /// « Absent » et « déclaré avec zéro octet » se traitent d'une seule façon, et
    /// à un seul endroit : un blob de zéro octet serait une entrée qui promet un
    /// contenu et n'en a pas, c'est-à-dire exactement la référence morte que tout
    /// le magasin est construit pour rendre impossible.
    private static func bytes(_ type: String?, in item: [String: Data]?) -> Data? {
        guard let type, let data = item?[type], data.isEmpty == false else { return nil }
        return data
    }

    /// **Le compte d'éléments n'est jamais repris du plan, et c'est la règle.**
    ///
    /// Il y en avait une, `storedItemCount(_:)`, qui rendait `plan.itemCount`
    /// quand il dépassait un. Elle était fausse d'une façon que rien ne pouvait
    /// rattraper en aval : le plan dit ce que le presse-papiers **déclarait**,
    /// pas ce qui a effectivement été gardé. Trois `public.file-url` dont une
    /// illisible donnaient une entrée annonçant trois fichiers et n'en portant
    /// que deux ; deux images donnaient « 2 éléments » pour un seul blob écrit.
    /// L'écart ne se voyait nulle part, et le chiffre affiché mentait par-dessus
    /// la perte.
    ///
    /// Chaque sorte écrit donc son propre compte, à partir de ce qu'elle range :
    /// `makeFile` laisse `ClipboardEntry.itemCount` retomber sur `fileURLs.count`,
    /// `makeImage` compte ses références, et le texte comme le texte enrichi
    /// n'annoncent rien parce qu'ils ne gardent qu'un élément. Le cas majoritaire
    /// reste celui qui ne s'écrit pas — un encodeur JSON omet les `nil`, et
    /// `ClipboardEntry` documente le champ comme « `nil` valant un ».

    /// Les références des contenus lourds, `nil` plutôt qu'un tableau vide.
    ///
    /// Un `[]` encodé serait un champ de plus sur chaque entrée de texte — le cas
    /// le plus fréquent, et celui qui n'a pas de blob.
    ///
    /// **Ces références sont calculées deux fois : ici, puis par le magasin.**
    /// C'est assumé. `ClipboardStore.save` rend « ce qui est sur le disque » et
    /// doit donc rehacher lui-même ; mais une entrée qui ne citerait ses blobs
    /// qu'après avoir touché le disque serait fausse en mémoire, donc intestable
    /// et inaffichable sans écrire. Le coût réel est un SHA-256 de plus par
    /// contenu, hors du fil de l'interface.
    private static func references(of payloads: [ClipboardBlobPayload]) -> [ClipboardBlobRef]? {
        payloads.isEmpty ? nil : payloads.map(\.ref)
    }
}

// MARK: - Ce que la capture rend

/// Une entrée et les contenus lourds qui vont avec, prêts pour
/// `ClipboardStore.save(_:payloads:)`.
///
/// **Les deux ensemble, et non l'entrée seule.** L'entrée cite déjà ses blobs par
/// leur empreinte — c'est `ClipboardBlobRef` — mais elle ne porte pas leurs
/// octets, et une ligne qui cite un fichier que personne n'a écrit est exactement
/// le désordre que l'ordre d'écriture du magasin existe pour rendre impossible.
/// Les rendre séparément laisserait un appelant écrire l'une sans les autres ;
/// les rendre liés fait que l'oubli ne compile pas.
public struct ClipboardCaptureResult: Sendable, Equatable {

    /// L'entrée telle qu'elle sera écrite, `blobs` déjà renseigné.
    public let entry: ClipboardEntry

    /// Les contenus lourds, dans l'ordre où l'entrée les cite.
    public let payloads: [ClipboardBlobPayload]

    public init(entry: ClipboardEntry, payloads: [ClipboardBlobPayload]) {
        self.entry = entry
        self.payloads = payloads
    }
}

// MARK: - Ce que l'appelant a lu

/// Ce que l'appelant a effectivement obtenu en exécutant un `ClipboardCapturePlan`.
///
/// **Le pendant exact de `ClipboardSample`, un cran plus loin.** L'échantillon
/// porte les types annoncés et **aucun contenu**, parce que lire la liste des
/// types est gratuit alors que lire le contenu ne l'est ni en temps ni en alerte
/// d'accès. La lecture, elle, porte les octets — et elle n'a lieu qu'une fois par
/// copie, sur instruction de la machine.
///
/// **Un dictionnaire par élément, et non un dictionnaire à plat.** Les éléments
/// restent séparés pour la même raison que dans `ClipboardSample` : une copie de
/// trois fichiers depuis le Finder est trois éléments, et un compagnon n'est un
/// compagnon que s'il vient du **même** élément que la forme qu'il accompagne.
/// Aplatir donnerait le texte brut d'un objet à un autre objet, sans que rien ne
/// le signale.
///
/// **Aucun AppKit ici, et c'est la raison d'être du type.** `NSPasteboard` rend
/// des `Data` par type ; tout ce que l'appelant a à faire est de les recopier dans
/// cette forme, et toute la décision se teste ensuite sans écran ni autorisation.
public struct ClipboardReading: Sendable, Equatable {

    /// Le compteur de changement au moment de la lecture.
    ///
    /// Il est là pour être **comparé** à celui du plan — voir `matches(_:)` — et
    /// pour rien d'autre. Un presse-papiers qui a rebougé pendant la lecture rend
    /// des octets qui appartiennent à la copie suivante : c'est le seul cas où des
    /// octets parfaitement lisibles sont quand même faux, et ce chiffre est le
    /// seul moyen de le voir.
    public let changeCount: Int

    /// Un dictionnaire type → octets par élément retenu du presse-papiers.
    ///
    /// Seuls les types que le plan demandait ont à s'y trouver. Un type absent, ou
    /// présent avec zéro octet, est traité comme non lu : un type déclaré mais
    /// vide n'est pas une bizarrerie théorique, c'est ce qu'une application publie
    /// entre son `clearContents()` et son `setData`, et c'est justement ce que le
    /// plancher de stabilisation de `ClipboardMachine` existe pour éviter.
    public let items: [[String: Data]]

    /// L'aplatissement en texte brut, quand l'appelant a su le faire.
    ///
    /// **Optionnel, et ce n'est pas de la paresse : aplatir du RTF ou du HTML
    /// exige AppKit**, donc ça ne peut pas se faire dans `BranCore`, qui doit
    /// rester testable sans écran ni autorisation. L'appelant, lui, a déjà AppKit
    /// sous la main : s'il sait produire la chaîne, elle devient l'aperçu et le
    /// « coller sans mise en forme » d'un texte enrichi qui n'a pas posé de
    /// compagnon en texte brut. Sinon l'aperçu reste vide, ce qui est honnête.
    ///
    /// Normalement `nil` quand l'élément porte déjà sa propre forme en texte brut :
    /// celle de l'application est meilleure qu'une conversion.
    public let flattenedText: String?

    public init(changeCount: Int, items: [[String: Data]], flattenedText: String? = nil) {
        self.changeCount = changeCount
        self.items = items
        self.flattenedText = flattenedText
    }

    /// Ces octets appartiennent-ils bien à la copie que le plan désignait ?
    ///
    /// À appeler **par l'appelant**, juste après la lecture. `ClipboardCapture` ne
    /// le fait pas à sa place, et volontairement : « illisible » et « trop tard »
    /// sont deux verdicts qui appellent deux réactions différentes — l'un se
    /// journalise, l'autre se rejoue —, et les fondre dans un même `nil` les
    /// rendrait indistinguables.
    public func matches(_ plan: ClipboardCapturePlan) -> Bool {
        changeCount == plan.changeCount
    }

    /// L'élément qui porte ce type, contenu d'abord.
    ///
    /// Un élément qui déclare le type avec zéro octet est un moins bon candidat
    /// qu'un élément qui le porte vraiment — mais il vaut mieux que rien : ses
    /// compagnons, eux, sont peut-être remplis, et un `richText` dont le RTF est
    /// vide mais dont le texte brut est là reste une entrée qu'on peut coller.
    func item(carrying type: String) -> [String: Data]? {
        items.first { $0[type]?.isEmpty == false } ?? items.first { $0[type] != nil }
    }

    /// Les octets déclarés sous ce type, un par élément qui en porte vraiment.
    ///
    /// Les représentations vides sont écartées ici, une fois pour toutes.
    ///
    /// `public` parce que l'appelant s'en sert aussi : c'est ainsi qu'il sait si
    /// le presse-papiers portait déjà un texte brut avant d'aller aplatir une
    /// forme enrichie — voir `ClipboardController.flattening(_:for:)`. Le lui
    /// faire refaire à la main sur `items` reviendrait à recopier la règle des
    /// représentations vides, qui n'a de sens qu'écrite une fois.
    public func values(of type: String) -> [Data] {
        items.compactMap { $0[type] }.filter { $0.isEmpty == false }
    }
}
