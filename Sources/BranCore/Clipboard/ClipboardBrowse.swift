import Foundation

/// Ce que **l'écran de bibliothèque** du presse-papiers décide sans rien
/// dessiner : ce qu'il retient, dans quel ordre, et ce qu'il annonce.
///
/// ## Pourquoi un second fichier à côté de `ClipboardFilter`
///
/// Ce ne sont pas deux versions de la même chose : ce sont deux écrans qui n'ont
/// pas la même question à résoudre, et les fondre en un seul type aurait produit
/// le composant à huit paramètres que `Design.swift` existe pour éviter.
///
/// `ClipboardFilter` sert **le panneau** — la fenêtre flottante de ⌘⇧C. Sa
/// question est « laquelle de ces quelques lignes vais-je coller dans les deux
/// secondes qui viennent ». Il filtre à la frappe sur ce qui est déjà en
/// mémoire, il place une sélection au clavier, il numérote ⌘1…⌘9. Il ne trie
/// rien, il ne compte rien, il ne sait pas ce qu'est une application source.
///
/// Ce fichier sert **la bibliothèque** — l'onglet de la fenêtre principale. Sa
/// question est « où est passée cette chose que j'ai copiée il y a trois
/// semaines ». Elle n'a pas de budget de 50 ms à tenir : personne n'ouvre un
/// onglet pour coller dans la seconde. Elle a en revanche le droit — et le
/// devoir — de chercher plus profond, de croiser des filtres, de trier
/// autrement que par l'heure, et de dire combien il y a de tout ça.
///
/// ## Ce qui est repris et non recopié
///
/// La règle de comparaison du panneau est appelée, jamais réécrite : voir
/// `matches(_:query:)`. **La recherche de la bibliothèque est un sur-ensemble
/// strict de celle du panneau, par construction et pas par intention.** Une
/// bibliothèque qui trouverait *moins* que la fenêtre flottante serait absurde,
/// et c'est le genre d'absurdité qu'on ne remarque qu'un jour où l'on cherche
/// vraiment.
///
/// L'ordre par défaut vient lui aussi d'ailleurs : `ClipboardStore.ordered(_:)`
/// est la seule définition de « la copie la plus récente en premier » du dépôt,
/// et `sorted(_:by:)` l'appelle plutôt que de la redémontrer.
///
/// ## Ce qui n'est pas ici
///
/// Le regroupement par jour. Il est partagé avec les autres écrans — voir
/// `DayGrouping` dans `BranApp` — et il y en avait déjà deux copies dans le
/// dépôt. En écrire une troisième ici, dans un autre module, aurait garanti la
/// divergence.
///
/// Rien ne connaît SwiftUI, et c'est la seule raison pour laquelle
/// `ClipboardBrowseTests` s'exécute en une milliseconde.
public enum ClipboardBrowse {

    // MARK: - Chercher

    /// Cette entrée répond-elle à la requête ?
    ///
    /// ## Quatre gisements, et le premier est celui du panneau
    ///
    /// 1. **L'aperçu et le nom de la source**, par renvoi vers
    ///    `ClipboardFilter.matches`, lui-même renvoyant vers
    ///    `ClipboardStore.matches`. Une seule définition dans tout le dépôt.
    /// 2. **Le texte complet**, quand il tient en ligne dans l'index
    ///    (`plainText`). C'est le vrai gain de cet écran : `preview` s'arrête à
    ///    `ClipboardEntry.previewLimit` caractères, donc chercher un mot qui se
    ///    trouve au troisième paragraphe d'un texte copié ne rendait rien du
    ///    tout dans le panneau — sans qu'aucun signe ne dise que la recherche
    ///    n'avait pas regardé jusque-là.
    /// 3. **Les chemins des fichiers copiés.** Se souvenir du dossier plutôt que
    ///    du nom est le cas courant d'une copie depuis le Finder, et le chemin
    ///    est la seule chose que l'entrée en garde.
    /// 4. Rien d'autre. En particulier **pas la sorte** : chercher « image » ne
    ///    doit pas ramener toutes les images, il y a un filtre pour ça, et une
    ///    recherche qui fait aussi office de filtre rend des résultats que
    ///    personne ne sait expliquer.
    ///
    /// ## Ce que la recherche ne regarde pas, et pourquoi elle ne ment pas
    ///
    /// Un texte de plus de `ClipboardEntry.inlineTextLimit` (512 Kio) vit dans
    /// un blob, et **ce blob n'est pas ouvert ici**. Le faire voudrait dire lire
    /// le disque une fois par entrée et par frappe, c'est-à-dire transformer un
    /// champ de recherche en balayage de bibliothèque. Ce qui est perdu est
    /// borné et connu : l'aperçu des 512 premiers caractères reste cherché, donc
    /// un texte géant reste trouvable par son début. La descente sur le disque
    /// existe déjà et porte un nom — `ClipboardStore.search(_:limit:)` —, elle
    /// se déclenche sur validation, et c'est le bon endroit pour elle.
    ///
    /// ## L'isolation `@MainActor`, visible plutôt que cachée
    ///
    /// Elle est héritée de `ClipboardFilter.matches`, qui l'hérite de
    /// `ClipboardStore.matches`, qui l'hérite de sa classe. `ClipboardFilter`
    /// documente déjà le bon état final — descendre le corps de la règle en
    /// `nonisolated` et laisser le magasin l'appeler — et le jour où il arrive,
    /// **cette fonction-ci perd son annotation sans changer d'une ligne**. Le
    /// coût aujourd'hui est nul : la bibliothèque est une vue, elle est déjà sur
    /// le fil principal, et les tests le sont d'une annotation.
    @MainActor
    public static func matches(_ entry: ClipboardEntry, query: String) -> Bool {
        let needle = ClipboardFilter.trimmed(query)
        guard needle.isEmpty == false else { return true }

        // Le gisement du panneau d'abord : c'est le moins cher — un aperçu est
        // borné à 512 caractères — et c'est aussi celui qui répond dans
        // l'écrasante majorité des cas.
        if ClipboardFilter.matches(entry, query: needle) { return true }

        if contains(entry.plainText, needle) { return true }

        for path in entry.fileURLs ?? [] where contains(searchable(path), needle) {
            return true
        }

        return false
    }

    /// Insensible à la casse **et aux diacritiques** : chercher « resume » doit
    /// trouver « résumé ». C'est la règle de `ClipboardStore.matches`, appliquée
    /// aux deux gisements que le panneau ne regarde pas.
    ///
    /// **Ce n'est pas une seconde définition de la règle, c'est la même options
    /// appliquée à d'autres champs.** La distinction compte : si l'un des deux
    /// endroits change d'avis sur la casse, ils divergeront — d'où le renvoi de
    /// `matches(_:query:)` vers le panneau pour les champs communs, qui est ce
    /// qui empêche cette divergence là où elle se verrait.
    static func contains(_ haystack: String?, _ needle: String) -> Bool {
        guard let haystack, haystack.isEmpty == false else { return false }
        return haystack.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    /// Un chemin de fichier tel qu'on le **cherche**, et non tel qu'il est
    /// stocké.
    ///
    /// `ClipboardEntry.fileURLs` porte ce que le presse-papiers a donné : tantôt
    /// un chemin nu (`/Users/x/Mon dossier/note.txt`), tantôt une URL
    /// (`file:///Users/x/Mon%20dossier/note.txt`). Sur la seconde forme,
    /// chercher « Mon dossier » ne trouve rien : l'espace y est écrit `%20`.
    /// C'est le genre d'échec qu'on n'attribue jamais à l'encodage — on conclut
    /// que « la recherche ne marche pas sur les fichiers » et on cesse de s'en
    /// servir.
    ///
    /// Le décodage échoue proprement sur une chaîne biscornue : on rend alors le
    /// texte tel quel plutôt que rien, parce qu'une recherche sur un chemin
    /// bizarre vaut mieux qu'aucune recherche.
    static func searchable(_ path: String) -> String {
        path.removingPercentEncoding ?? path
    }

    // MARK: - Filtrer

    /// Les entrées que l'écran retient, **dans l'ordre demandé**.
    ///
    /// L'ordre des tests n'est pas indifférent : les trois prédicats de filtre
    /// sont des comparaisons d'ensembles et de booléens, la recherche est un
    /// parcours de chaînes qui peut porter sur un texte de 512 Kio. On écarte
    /// donc avec ce qui est gratuit avant de payer ce qui ne l'est pas.
    @MainActor
    public static func filtered(
        _ entries: [ClipboardEntry], filter: ClipboardBrowseFilter
    ) -> [ClipboardEntry] {
        let kept = entries.filter { entry in
            if filter.pinnedOnly, entry.isPinned == false { return false }
            if filter.kinds.isEmpty == false, filter.kinds.contains(entry.kind) == false {
                return false
            }
            if filter.apps.isEmpty == false {
                // **Une entrée sans source ne passe aucun filtre d'application,
                // et ce n'est pas un oubli.** `ClipboardSource.isUnknown` dit
                // que l'interface doit se taire plutôt qu'écrire « Inconnu » ;
                // il n'y a donc aucune ligne « Origine inconnue » à cocher dans
                // le menu, et une entrée dont on ignore la provenance ne peut
                // pas être retenue par un filtre qui nomme des applications.
                guard let key = appKey(entry.source), filter.apps.contains(key) else {
                    return false
                }
            }
            return matches(entry, query: filter.query)
        }
        return sorted(kept, by: filter.sort)
    }

    /// Tout ce que l'écran a besoin de savoir, en un appel.
    ///
    /// **Trois valeurs dans un seul type parce qu'elles se calculent d'un seul
    /// tenant**, exactement comme `ClipboardFilter.Shown`. Une vue qui lirait
    /// séparément « les lignes », « combien il y en a » et « quelles
    /// applications » referait le filtrage trois fois par image — et une fois de
    /// plus par ligne dessinée si la ligne posait la moindre question au modèle.
    /// C'est très précisément le coût quadratique que tout le stockage du
    /// presse-papiers a été conçu pour ne pas payer.
    @MainActor
    public static func result(
        _ entries: [ClipboardEntry], filter: ClipboardBrowseFilter
    ) -> ClipboardBrowseResult {
        let kept = filtered(entries, filter: filter)
        return ClipboardBrowseResult(
            entries: kept,
            summary: summary(of: kept),
            // **Les applications viennent de la liste d'origine, pas de la liste
            // retenue.** Un menu construit sur le résultat se viderait au
            // premier clic : cocher « Terminal » ferait disparaître les quatorze
            // autres applications du menu, et il n'y aurait plus aucun moyen de
            // changer d'avis sans tout décocher à l'aveugle. Un filtre doit
            // pouvoir se défaire par là où il s'est fait.
            apps: apps(in: entries)
        )
    }

    // MARK: - Trier

    /// Les entrées dans l'ordre demandé.
    ///
    /// **Le défaut délègue.** `newestFirst` appelle `ClipboardStore.ordered(_:)`
    /// — la seule définition de l'ordre d'affichage du dépôt, départage des
    /// ex æquo comprise. La redémontrer ici aurait donné deux ordres qui se
    /// ressemblent, et le symptôme d'une divergence — une liste qui n'est pas
    /// tout à fait dans le même ordre selon l'écran — ne se relie à rien.
    ///
    /// **Les trois autres départagent par la date, puis par l'identifiant.**
    /// Sans cette cascade, deux entrées de même taille ou de même compteur
    /// changeraient d'ordre entre deux passes de dessin, ce qui se lit comme une
    /// liste qui bouge toute seule.
    public static func sorted(
        _ entries: [ClipboardEntry], by sort: ClipboardBrowseSort
    ) -> [ClipboardEntry] {
        switch sort {
        case .newestFirst:
            return ClipboardStore.ordered(entries)
        case .oldestFirst:
            return Array(ClipboardStore.ordered(entries).reversed())
        case .mostCopied:
            return rank(entries) { $0.copyCount > $1.copyCount }
        case .largest:
            return rank(entries) { weight(of: $0) > weight(of: $1) }
        }
    }

    /// Un classement, la chronologie en second critère.
    ///
    /// `ClipboardStore.ordered` est appliqué **avant** : `sorted(by:)` de la
    /// bibliothèque standard n'est pas stable, donc partir d'une liste déjà
    /// chronologique ne suffirait pas à garantir l'ordre des ex æquo. Le second
    /// critère est explicite pour cette raison.
    private static func rank(
        _ entries: [ClipboardEntry], by primary: (ClipboardEntry, ClipboardEntry) -> Bool
    ) -> [ClipboardEntry] {
        ClipboardStore.ordered(entries).sorted { left, right in
            if primary(left, right) { return true }
            if primary(right, left) { return false }
            if left.lastCopiedAt != right.lastCopiedAt {
                return left.lastCopiedAt > right.lastCopiedAt
            }
            return left.id.uuidString > right.id.uuidString
        }
    }

    /// Ce qu'une entrée pèse pour le tri par taille.
    ///
    /// Les octets des contenus lourds quand il y en a, le nombre de caractères
    /// sinon. **Ce n'est pas une addition des deux**, et c'est délibéré : mêler
    /// des octets de PNG et des caractères de texte dans un même nombre
    /// produirait un classement dont personne ne peut prédire le résultat. Le
    /// tri par taille sert à trouver ce qui occupe le disque ; ce qui occupe le
    /// disque, ce sont les blobs — 99 % du volume pour moins de 10 % des lignes,
    /// mesuré. Le texte se classe entre lui, tout en bas, ce qui est exact.
    private static func weight(of entry: ClipboardEntry) -> Int {
        let bytes = entry.totalBlobBytes
        if bytes > 0 { return bytes }
        if let refused = entry.refusedBytes { return refused }
        return entry.characterCount
    }

    // MARK: - Les applications présentes

    /// La clé qui identifie une application source, ou `nil` quand on n'en sait
    /// rien.
    ///
    /// **L'identifiant de paquet d'abord, le nom en repli.** C'est l'ordre que
    /// `ClipboardSource` argumente : le nom lisible ne survit pas à un
    /// changement de langue du système, l'identifiant reste vrai. Une entrée
    /// écrite avant que la source soit relevée, ou copiée depuis une
    /// application dont l'identifiant n'a pas pu être lu, se replie donc sur son
    /// nom plutôt que de disparaître du menu.
    public static func appKey(_ source: ClipboardSource?) -> String? {
        guard let source, source.isUnknown == false else { return nil }
        if let bundle = source.bundleIdentifier, bundle.isEmpty == false { return bundle }
        guard let name = source.name, name.isEmpty == false else { return nil }
        return name
    }

    /// Les applications présentes dans cette liste, avec ce qu'elles y pèsent.
    ///
    /// Existe pour que la vue n'ait pas à les deviner : un menu de filtre
    /// construit dans un `body` obligerait à parcourir les cinq cents entrées à
    /// chaque passe de dessin, y compris quand le menu est fermé.
    ///
    /// **Le nom affiché est celui de l'entrée la plus récente.** Une application
    /// renommée entre deux versions — ou traduite — laisse deux noms pour un
    /// même identifiant ; prendre le plus récent est la seule règle qui ne
    /// dépende pas de l'ordre de lecture des fichiers.
    ///
    /// **Le classement est par fréquence, et c'est un choix contestable
    /// assumé.** L'alphabet serait plus stable : le rang d'une application ne
    /// changerait jamais sous le curseur. Mais la mesure est nette — Chrome et
    /// Terminal produisent 77 % de tout l'historique réel — et un menu dont les
    /// deux premières lignes répondent aux trois quarts des intentions vaut le
    /// risque qu'un jour deux applications s'échangent leur rang. Le compte est
    /// rendu avec, pour que le classement s'explique de lui-même à l'écran.
    public static func apps(in entries: [ClipboardEntry]) -> [ClipboardApp] {
        var counts: [String: Int] = [:]
        var names: [String: String] = [:]
        var latest: [String: Date] = [:]

        for entry in entries {
            guard let key = appKey(entry.source) else { continue }
            counts[key, default: 0] += 1

            let seen = entry.lastCopiedAt
            if let known = latest[key], known >= seen { continue }
            latest[key] = seen
            names[key] = entry.source?.name ?? key
        }

        return counts.map { key, count in
            ClipboardApp(id: key, name: names[key] ?? key, count: count)
        }
        .sorted { left, right in
            if left.count != right.count { return left.count > right.count }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
    }

    // MARK: - Ce que le filtre a retenu

    /// Le résumé d'une liste : combien d'entrées, combien d'épingles, combien
    /// d'octets, et sur quelle étendue de temps.
    ///
    /// **C'est ce qu'un écran de bibliothèque montre et qu'un panneau ne montre
    /// pas.** Le panneau répond à « laquelle », il n'a rien à faire d'un total.
    /// La bibliothèque répond à « qu'est-ce que je garde », et cette question-là
    /// est un chiffre : ce sont les octets qui décident si le réglage de
    /// rétention est bien réglé, et c'est l'étendue de temps qui prouve la
    /// promesse — « rien n'est oublié » se vérifie en lisant la date la plus
    /// ancienne, pas en la croyant.
    public static func summary(of entries: [ClipboardEntry]) -> ClipboardBrowseSummary {
        var bytes = 0
        var characters = 0
        var pinned = 0
        var earliest: Date?
        var latest: Date?

        for entry in entries {
            bytes += entry.totalBlobBytes
            characters += entry.characterCount
            if entry.isPinned { pinned += 1 }

            let date = entry.lastCopiedAt
            if let known = earliest { earliest = Swift.min(known, date) } else { earliest = date }
            if let known = latest { latest = Swift.max(known, date) } else { latest = date }
        }

        return ClipboardBrowseSummary(
            count: entries.count,
            pinnedCount: pinned,
            bytes: bytes,
            characters: characters,
            earliest: earliest,
            latest: latest
        )
    }

    // MARK: - Les mots des filtres

    /// Le nom d'une **catégorie** de contenus, au pluriel.
    ///
    /// **Distinct de `ClipboardPanelVocabulary.kindName(_:)`, qui nomme *une*
    /// entrée.** Celui-là dit « 3 fichiers » ou « Fichier » selon ce que l'entrée
    /// porte ; celui-ci intitule une case à cocher qui vaut pour toutes les
    /// entrées d'une sorte. Les fondre aurait obligé à inventer une entrée
    /// fictive pour obtenir un libellé de menu.
    ///
    /// Ici plutôt que dans la vue parce que c'est le pendant de
    /// `ClipboardRetention.label` : un vocabulaire qu'un test peut lire, et non
    /// une chaîne semée dans un `body`.
    public static func name(for kind: ClipboardKind) -> String {
        switch kind {
        case .text: "Textes"
        case .richText: "Textes mis en forme"
        case .image: "Images"
        case .file: "Fichiers"
        }
    }
}

// MARK: - Le tri

/// Les ordres que la bibliothèque sait rendre.
///
/// **Quatre, et chacun répond à une question qu'on se pose vraiment devant un
/// historique.** L'exercice n'est pas d'offrir tous les tris possibles — il y en
/// a autant que de champs — mais de n'offrir que ceux dont la réponse change une
/// décision.
public enum ClipboardBrowseSort: String, Sendable, Equatable, Codable, CaseIterable, Identifiable {

    /// « Qu'est-ce que je viens de copier. » Le défaut, et le même ordre que le
    /// panneau : c'est `ClipboardStore.ordered(_:)`.
    case newestFirst

    /// « Qu'est-ce que je garde depuis le plus longtemps. »
    ///
    /// **C'est le tri qui rend visible la promesse de la fonction.** Tout
    /// l'argument de cet historique est que Maccy oublie au bout de 4,7 jours
    /// mesurés et que celui-ci n'oublie pas ; or le fond de la pile est
    /// précisément ce que le panneau ne montre jamais, puisqu'il ouvre sur la
    /// dernière copie et que la fenêtre en mémoire s'arrête à une dizaine de
    /// jours. Sans ce tri, « on garde tout » est une affirmation invérifiable.
    case oldestFirst

    /// « Qu'est-ce que je recolle tout le temps. »
    ///
    /// Mesuré : 43 entrées sur 250 ont été copiées plus d'une fois. C'est trop
    /// peu pour mériter une colonne dans la ligne — le panneau s'en tient à un
    /// petit signe — et bien assez pour mériter un tri : ces 43-là sont les
    /// candidates naturelles à l'épinglage, et ce tri est la façon de les
    /// trouver sans les avoir cherchées une par une.
    case mostCopied

    /// « Qu'est-ce qui occupe la place. »
    ///
    /// Le pendant du résumé en octets et du réglage de rétention : un réglage de
    /// durée se choisit bien mieux quand on voit ce que les dix plus grosses
    /// entrées pèsent. Mesuré : 183 lignes de PNG pesaient 158 Mo pour 250
    /// entrées.
    case largest

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .newestFirst: "Les plus récentes"
        case .oldestFirst: "Les plus anciennes"
        case .mostCopied: "Les plus recopiées"
        case .largest: "Les plus lourdes"
        }
    }

    /// Cet ordre se regroupe-t-il par jour ?
    ///
    /// **Seule la chronologie descendante le fait, et c'est une règle et non une
    /// omission.** Un regroupement par jour impose son propre ordre — les jours
    /// du plus récent au plus ancien, les entrées de même — donc l'appliquer à
    /// un classement par poids ou par nombre de copies effacerait purement et
    /// simplement le tri demandé : on obtiendrait une liste chronologique avec
    /// un intitulé qui promet autre chose, ce qui est pire que de ne pas offrir
    /// le tri.
    ///
    /// Les trois autres rendent donc une liste plate. C'est aussi ce qu'on veut
    /// en les demandant : « les dix plus lourdes » est un palmarès, et un
    /// palmarès coupé en tranches de journées n'est plus un palmarès.
    public var groupsByDay: Bool { self == .newestFirst }
}

// MARK: - Une application source

/// Une application présente dans l'historique, telle qu'un menu de filtre la
/// montre.
///
/// **Le compte fait partie du type et non d'un dictionnaire à côté**, parce que
/// c'est lui qui justifie le classement par fréquence : un menu qui met Chrome
/// en tête sans dire « 94 » a l'air arbitraire, le même menu avec le chiffre
/// s'explique tout seul.
public struct ClipboardApp: Sendable, Equatable, Hashable, Identifiable {

    /// L'identifiant de paquet quand on l'a, le nom sinon. C'est cette clé que
    /// `ClipboardBrowseFilter.apps` retient — jamais le nom affiché, qui peut
    /// changer avec la langue du système.
    public let id: String

    /// Le nom lisible, tel qu'il a été relevé au moment de la copie.
    public let name: String

    /// Combien d'entrées de la liste viennent de là.
    public let count: Int

    public init(id: String, name: String, count: Int) {
        self.id = id
        self.name = name
        self.count = count
    }
}

// MARK: - Le filtre

/// Ce que l'écran de bibliothèque demande à voir.
///
/// **Un type de valeur et non cinq propriétés éparpillées dans la vue**, pour
/// deux raisons qui n'ont rien de cosmétique. La première est qu'un filtre est
/// une chose qu'on compare — « est-ce que quelque chose est coché ? », « remets
/// tout à zéro » — et qu'un ensemble de `@State` ne se compare pas. La seconde
/// est que c'est ainsi qu'il se teste : `ClipboardBrowseTests` construit des
/// filtres et vérifie ce qu'ils retiennent, ce qu'aucun test ne saurait faire
/// avec des états de vue.
///
/// **Les ensembles vides veulent dire « tout », jamais « rien ».** C'est le
/// piège de ce genre de modèle, et il se paie cher : un écran qui ouvrirait sur
/// un historique vide parce qu'aucune sorte n'est cochée serait tenu pour cassé
/// avant qu'on ait eu l'idée de cocher quoi que ce soit. Décocher la dernière
/// case rend donc l'écran complet, ce qui est aussi ce que fait le Finder.
public struct ClipboardBrowseFilter: Sendable, Equatable {

    /// Ce qui est tapé dans le champ de recherche.
    public var query: String

    /// Les sortes retenues. Vide : toutes.
    public var kinds: Set<ClipboardKind>

    /// Les clés d'applications retenues — voir `ClipboardBrowse.appKey(_:)`.
    /// Vide : toutes.
    public var apps: Set<String>

    /// Ne montrer que ce qui est épinglé.
    public var pinnedOnly: Bool

    /// L'ordre demandé.
    public var sort: ClipboardBrowseSort

    public init(
        query: String = "",
        kinds: Set<ClipboardKind> = [],
        apps: Set<String> = [],
        pinnedOnly: Bool = false,
        sort: ClipboardBrowseSort = .newestFirst
    ) {
        self.query = query
        self.kinds = kinds
        self.apps = apps
        self.pinnedOnly = pinnedOnly
        self.sort = sort
    }

    /// L'écran à l'ouverture : tout, du plus récent au plus ancien.
    public static let everything = ClipboardBrowseFilter()

    /// Y a-t-il un filtre coché, **en plus** de la recherche ?
    ///
    /// La distinction avec la recherche est ce qui permet à l'écran de proposer
    /// « Tout afficher » au bon moment. Un état vide qui ne dit pas *pourquoi*
    /// il est vide est un cul-de-sac ; et entre « votre recherche ne rend rien »
    /// et « vos trois filtres ne laissent rien passer », ce n'est pas le même
    /// geste qui répare.
    public var narrowsBeyondQuery: Bool {
        pinnedOnly || kinds.isEmpty == false || apps.isEmpty == false
    }

    /// Combien de filtres sont posés. Sert à l'écran à annoncer « 2 filtres »
    /// sans recompter à la main ce que ce type sait déjà.
    public var narrowingCount: Int {
        (pinnedOnly ? 1 : 0) + (kinds.isEmpty ? 0 : 1) + (apps.isEmpty ? 0 : 1)
    }

    /// Le même filtre, ses cases décochées — **la recherche et l'ordre
    /// survivent**.
    ///
    /// Décocher n'est pas recommencer : quelqu'un qui a tapé trois mots et coché
    /// deux cases, puis qui décoche, veut voir ses trois mots sur tout
    /// l'historique. Effacer aussi la recherche lui reprendrait le travail qu'il
    /// n'a pas demandé à défaire.
    public var withoutNarrowing: ClipboardBrowseFilter {
        ClipboardBrowseFilter(query: query, kinds: [], apps: [], pinnedOnly: false, sort: sort)
    }

    /// Coche ou décoche une sorte.
    public mutating func toggle(_ kind: ClipboardKind) {
        if kinds.contains(kind) { kinds.remove(kind) } else { kinds.insert(kind) }
    }

    /// Coche ou décoche une application.
    public mutating func toggle(app id: String) {
        if apps.contains(id) { apps.remove(id) } else { apps.insert(id) }
    }
}

// MARK: - Le résumé

/// Ce que le filtre a retenu, en chiffres.
public struct ClipboardBrowseSummary: Sendable, Equatable {

    public let count: Int
    public let pinnedCount: Int

    /// Les octets des contenus lourds, purgés compris — leurs références portent
    /// exprès la taille de ce qui a disparu.
    public let bytes: Int

    /// Les caractères de texte, tous cumulés.
    public let characters: Int

    /// La plus ancienne et la plus récente des dates de copie de la liste,
    /// `nil` quand elle est vide.
    public let earliest: Date?
    public let latest: Date?

    public init(
        count: Int,
        pinnedCount: Int,
        bytes: Int,
        characters: Int,
        earliest: Date?,
        latest: Date?
    ) {
        self.count = count
        self.pinnedCount = pinnedCount
        self.bytes = bytes
        self.characters = characters
        self.earliest = earliest
        self.latest = latest
    }

    public var isEmpty: Bool { count == 0 }

    /// « 128 entrées · 12 épinglées · 4,2 Mo ».
    ///
    /// **Les octets ne s'affichent que s'il y en a**, et c'est la seule
    /// condition de tout ce texte. Écrire « 0 octet » sur un historique de texte
    /// pur — le cas de loin le plus fréquent — occuperait la ligne pour dire que
    /// la fonctionnalité ne consomme rien, ce que personne n'est venu vérifier.
    /// Les caractères ne s'affichent jamais ici : un total de caractères ne veut
    /// rien dire à l'échelle d'une bibliothèque, il est gardé pour la ligne, où
    /// il en veut un.
    public var description: String {
        var parts = [count == 1 ? "1 entrée" : "\(count) entrées"]
        if pinnedCount > 0 {
            parts.append(pinnedCount == 1 ? "1 épinglée" : "\(pinnedCount) épinglées")
        }
        if bytes > 0 { parts.append(Self.formatted(bytes: bytes)) }
        return parts.joined(separator: " · ")
    }

    /// `Int64` et non `Int` : `ByteCountFormatStyle` n'accepte que celui-là.
    /// Même raison et même style que `ClipboardEntry.sizeDescription`, pour que
    /// le total et les lignes qu'il additionne s'écrivent pareil.
    static func formatted(bytes: Int) -> String {
        Int64(bytes).formatted(.byteCount(style: .file))
    }
}

// MARK: - Le résultat

/// Les lignes, leur résumé et les applications présentes, calculés d'un seul
/// tenant.
public struct ClipboardBrowseResult: Sendable, Equatable {

    /// Les entrées à dessiner, dans l'ordre demandé.
    public let entries: [ClipboardEntry]

    /// Ce que ces entrées pèsent.
    public let summary: ClipboardBrowseSummary

    /// Les applications de l'historique **entier**, pour peupler le menu de
    /// filtre. Voir `ClipboardBrowse.result(_:filter:)` : les tirer du résultat
    /// filtré viderait le menu au premier clic.
    public let apps: [ClipboardApp]

    public init(
        entries: [ClipboardEntry], summary: ClipboardBrowseSummary, apps: [ClipboardApp]
    ) {
        self.entries = entries
        self.summary = summary
        self.apps = apps
    }

    public var isEmpty: Bool { entries.isEmpty }
}
