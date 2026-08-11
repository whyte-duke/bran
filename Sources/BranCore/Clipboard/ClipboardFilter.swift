import Foundation

/// Ce que le panneau du presse-papiers décide **sans écran** : quelles entrées
/// la liste montre, laquelle est sous le clavier, et ce que chaque ligne a le
/// droit d'afficher.
///
/// ## Pourquoi ce fichier existe
///
/// Le panneau est la première vue de l'application dont l'essentiel du
/// comportement n'est pas visuel. Filtrer, déplacer une sélection sur une liste
/// qui change sous les doigts, faire correspondre ⌘1…⌘9 à des lignes : ce sont
/// des règles, pas des pixels, et une règle enfermée dans un `body` SwiftUI n'a
/// aucun moyen d'être vérifiée. Les cas qui font mal — la sélection tombée hors
/// de la liste après une frappe dans le filtre, la ligne supprimée sous le
/// curseur, ⌘9 qui désignerait la neuvième entrée de l'historique plutôt que la
/// neuvième ligne visible — sont exactement ceux qu'on ne reproduit pas à la
/// main deux fois de suite.
///
/// Rien ici ne connaît SwiftUI, et c'est la seule raison pour laquelle
/// `ClipboardFilterTests` s'exécute en une milliseconde.
///
/// ## Ce qui n'est pas ici
///
/// L'ordre de la liste. Il est décidé une fois pour toutes par
/// `ClipboardStore.ordered(_:)` — la copie la plus récente en premier, l'identifiant
/// pour départager — et le filtre **ne retrie jamais**. Deux définitions d'un
/// ordre d'affichage divergeraient au premier correctif, et le symptôme (une
/// liste qui se réordonne quand on tape dans le filtre) ne se relie à rien.
public enum ClipboardFilter {

    // MARK: - Filtrer

    /// La requête débarrassée de ses bords blancs, telle que le filtre la
    /// compare.
    ///
    /// Rognée et non nettoyée davantage : un espace **au milieu** d'une requête
    /// est une intention, c'est ce qui sépare « bonjour tout » de « bonjourtout ».
    /// Seuls les bords sont du bruit, et ils viennent d'un collage.
    public static func trimmed(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Cette entrée répond-elle à la requête ?
    ///
    /// **Ce n'est pas une deuxième implémentation : c'est un renvoi vers celle
    /// de `ClipboardStore`.** La règle — insensible à la casse *et* aux
    /// diacritiques, portant sur l'aperçu *et* sur le nom de la source — est
    /// écrite une seule fois dans tout le dépôt, dans `ClipboardStore.matches`,
    /// parce que le panneau et la recherche sur disque doivent trouver
    /// exactement les mêmes choses. Une recherche qui rend un résultat dans la
    /// fenêtre en mémoire et un autre après être descendue sur le disque serait
    /// pire qu'une recherche lente : elle serait fausse par intermittence.
    ///
    /// **Le prix de ce renvoi est l'isolation `@MainActor`**, et il est visible
    /// dans la signature plutôt que caché. `ClipboardStore` est une classe
    /// `@MainActor`, ce qui isole aussi ses membres statiques ; `matches` n'est
    /// pas marquée `nonisolated` comme le sont `ordered(_:)` ou `listing(of:)`,
    /// donc rien de non isolé ne peut l'appeler. Ce n'est pas grave ici — le
    /// panneau est une vue, il est déjà sur le fil principal, et les tests le
    /// sont aussi d'une annotation. Ce serait grave le jour où le filtrage
    /// devrait partir sur un fil de fond.
    ///
    /// **Le bon état final est l'inverse de celui-ci**, et il tient en deux
    /// lignes qu'un autre commit doit écrire : déplacer le corps de
    /// `ClipboardStore.matches` ici, en `nonisolated`, et laisser le magasin
    /// appeler `ClipboardFilter.matches`. Le magasin y gagnerait la même
    /// testabilité, ce fichier perdrait son `@MainActor`, et il n'y aurait
    /// toujours qu'une seule définition. Ce commit-ci n'a pas le droit de
    /// toucher aux fichiers existants ; il renvoie donc, plutôt que de copier.
    @MainActor
    public static func matches(_ entry: ClipboardEntry, query: String) -> Bool {
        let needle = trimmed(query)
        guard needle.isEmpty == false else { return true }
        return ClipboardStore.matches(entry, needle)
    }

    /// Les entrées que la liste montre pour cette requête, dans l'ordre reçu.
    ///
    /// Une requête vide rend **toute** la liste, et non une liste vide — c'est
    /// l'inverse de `ClipboardStore.search(_:limit:)`, qui rend `[]` parce qu'y
    /// répondre voudrait dire relire une année de dossiers pour rien. Ici, la
    /// requête vide est l'état d'ouverture du panneau : il n'y a rien de plus
    /// normal, et c'est le moment où l'on veut voir le plus de choses.
    @MainActor
    public static func visible(
        _ entries: [ClipboardEntry], matching query: String
    ) -> [ClipboardEntry] {
        let needle = trimmed(query)
        guard needle.isEmpty == false else { return entries }
        return entries.filter { ClipboardStore.matches($0, needle) }
    }

    // MARK: - Ce que la liste montre à un instant donné

    /// Les entrées visibles **et** la ligne courante, calculées ensemble.
    ///
    /// **Deux valeurs dans un seul type parce qu'elles se calculent d'un seul
    /// tenant.** La sélection ne peut pas être décidée sans connaître la liste
    /// filtrée : c'est elle qui dit si l'entrée désignée existe encore. Les
    /// exposer en deux propriétés calculées ferait refiltrer la liste à chaque
    /// lecture — et une vue qui demande « suis-je sélectionnée ? » une fois par
    /// ligne referait alors le filtrage 250 fois par image, c'est-à-dire
    /// exactement le coût que le stockage a été conçu pour ne pas payer (voir
    /// `ClipboardStore.recent` et son budget de 50 ms).
    public struct Shown: Sendable, Equatable {

        /// Les entrées à dessiner, de la plus récente à la plus ancienne.
        public let entries: [ClipboardEntry]

        /// L'entrée sous le clavier. `nil` **seulement** quand la liste est
        /// vide : voir `reconciled(_:in:)`.
        public let selection: ClipboardEntry.ID?

        public init(entries: [ClipboardEntry], selection: ClipboardEntry.ID?) {
            self.entries = entries
            self.selection = selection
        }

        /// L'entrée sélectionnée, quand il y en a une.
        public var selected: ClipboardEntry? {
            guard let selection else { return nil }
            return entries.first { $0.id == selection }
        }

        public var isEmpty: Bool { entries.isEmpty }
    }

    /// Tout ce que la liste a besoin de savoir, en un appel.
    ///
    /// C'est le seul point d'entrée que la vue utilise : lui donner la requête
    /// et la dernière intention du clavier, il rend ce qui s'affiche. La
    /// réconciliation de la sélection est faite **ici** et pas dans un
    /// `onChange` de la vue, parce qu'un `onChange` s'exécute *après* le rendu :
    /// il y aurait donc une image, au moins, où le panneau surligne une ligne
    /// qui n'existe plus, ou n'en surligne aucune alors qu'il y en a. Un état
    /// dérivé se dérive ; il ne se rattrape pas.
    @MainActor
    public static func shown(
        _ entries: [ClipboardEntry],
        query: String,
        selection: ClipboardEntry.ID?
    ) -> Shown {
        let visible = visible(entries, matching: query)
        return Shown(entries: visible, selection: reconciled(selection, in: visible))
    }

    // MARK: - Déplacer la sélection

    /// Les quatre déplacements que le clavier sait demander.
    ///
    /// **Quatre et pas six** : ni « page suivante » ni « page précédente ». Une
    /// page n'a de sens que si l'on sait combien de lignes tiennent à l'écran,
    /// c'est-à-dire une information de géométrie, que ce fichier n'a pas et ne
    /// doit pas avoir. `first` et `last` couvrent le besoin réel — atteindre un
    /// bout de la liste en une frappe — sans rien devoir mesurer.
    public enum Move: Sendable, Equatable, CaseIterable {
        case up
        case down
        case first
        case last
    }

    /// La sélection après un déplacement.
    ///
    /// **Une sélection est un identifiant, jamais un indice.** La liste change
    /// sous les doigts — chaque frappe dans le filtre la refait, une copie peut
    /// arriver pendant qu'on lit, ⌘⌫ en retire une ligne — et un indice désigne
    /// alors une *autre* entrée sans que rien ne le signale. Un identifiant
    /// désigne la même entrée ou plus rien du tout, et « plus rien » est un cas
    /// qu'on peut traiter.
    ///
    /// ## Le bord : ↓ sur la dernière ligne ne boucle pas
    ///
    /// C'est la décision discutable de ce fichier, et voici les trois raisons de
    /// la trancher ainsi.
    ///
    /// 1. **La répétition de touche.** Une flèche maintenue enfoncée sur une
    ///    liste bouclante ne s'arrête jamais : elle tourne, et le seul retour
    ///    qu'une liste au clavier puisse donner — « vous êtes arrivé au bout » —
    ///    disparaît. Buter est ce retour.
    /// 2. **La distance.** La fenêtre en mémoire porte jusqu'à
    ///    `ClipboardStore.windowSize` entrées, soit une dizaine de jours.
    ///    Boucler de la première à la dernière, c'est sauter dix jours en
    ///    arrière sur une frappe donnée par erreur, sans aucun moyen de sentir
    ///    ce qui s'est passé. Ce saut existe, il s'appelle `last`, et il se
    ///    demande exprès.
    /// 3. **La suppression.** ⌘⌫ retire des lignes ; la position d'après est
    ///    décidée par `selectionAfterRemoving(_:from:)`. Avec un bord qui
    ///    boucle, supprimer la dernière ligne ferait remonter la sélection tout
    ///    en haut, ce qui se lit comme un défilement spontané du panneau.
    ///
    /// ## Sans sélection
    ///
    /// Ne se produit qu'avec une liste vide (voir `reconciled(_:in:)`), mais le
    /// cas doit être défini : `down` et `first` prennent la première ligne, `up`
    /// et `last` la dernière. C'est le comportement d'un menu macOS, et c'est
    /// celui qu'on attend sans savoir qu'on l'attend.
    public static func moved(
        _ selection: ClipboardEntry.ID?,
        by move: Move,
        in entries: [ClipboardEntry]
    ) -> ClipboardEntry.ID? {
        guard entries.isEmpty == false else { return nil }

        switch move {
        case .first: return entries.first?.id
        case .last: return entries.last?.id
        case .up, .down: break
        }

        guard let selection, let index = entries.firstIndex(where: { $0.id == selection }) else {
            return move == .down ? entries.first?.id : entries.last?.id
        }

        let last = entries.count - 1
        let target = move == .down ? Swift.min(index + 1, last) : Swift.max(index - 1, 0)
        return entries[target].id
    }

    /// La sélection à retenir quand la liste vient de changer.
    ///
    /// **La règle est : une liste non vide a toujours une ligne sélectionnée.**
    /// C'est ce qui rend ↵ toujours signifiant. Un panneau qu'on ouvre au
    /// raccourci pour coller la dernière chose copiée et qui demanderait d'abord
    /// une flèche vers le bas ferait payer une frappe à chaque usage, pour un
    /// état — « rien n'est choisi » — dont personne n'a besoin.
    ///
    /// **La retombée est la première ligne, pas la ligne du même rang.** Après
    /// une frappe dans le filtre, la liste n'est pas la même liste plus courte :
    /// c'est une autre liste, triée par pertinence temporelle, dont le premier
    /// élément est le meilleur candidat. Garder le rang aurait désigné une ligne
    /// arbitraire ; garder l'identifiant, quand il survit, est en revanche exact
    /// et c'est ce qu'on essaie d'abord — filtrer plus finement autour de ce
    /// qu'on visait déjà ne doit pas faire perdre ce qu'on visait.
    public static func reconciled(
        _ selection: ClipboardEntry.ID?, in entries: [ClipboardEntry]
    ) -> ClipboardEntry.ID? {
        guard entries.isEmpty == false else { return nil }
        if let selection, entries.contains(where: { $0.id == selection }) { return selection }
        return entries.first?.id
    }

    /// La sélection à poser **avant** de retirer une entrée de la liste.
    ///
    /// Prend la liste telle qu'elle est encore, et rend la ligne qui doit
    /// hériter du clavier : la suivante, ou la précédente s'il n'y en avait pas
    /// de suivante, ou `nil` si c'était la seule.
    ///
    /// **Pourquoi ça ne peut pas être `reconciled` qui s'en charge.** Une fois la
    /// ligne partie, `reconciled` ne voit qu'une sélection introuvable et
    /// retombe en tête de liste — ce qui est juste après un filtrage et faux
    /// après une suppression : on supprime en descendant, et repartir du haut
    /// oblige à refaire tout le chemin. La différence entre les deux cas n'existe
    /// que dans l'instant qui précède la suppression, donc c'est là qu'elle se
    /// décide.
    ///
    /// **La suivante plutôt que la précédente**, parce que supprimer plusieurs
    /// entrées d'affilée est le geste réel : ⌘⌫ répété doit descendre la liste,
    /// pas la remonter. La précédente n'est le bon choix qu'en bas, où il n'y a
    /// plus de suivante.
    public static func selectionAfterRemoving(
        _ id: ClipboardEntry.ID, from entries: [ClipboardEntry]
    ) -> ClipboardEntry.ID? {
        guard let index = entries.firstIndex(where: { $0.id == id }) else {
            // La ligne n'était déjà plus là : rien à décider, la réconciliation
            // ordinaire fera le reste.
            return reconciled(nil, in: entries)
        }
        if index + 1 < entries.count { return entries[index + 1].id }
        if index > 0 { return entries[index - 1].id }
        return nil
    }

    // MARK: - Les raccourcis chiffrés

    /// Combien de lignes portent un raccourci chiffré — neuf.
    ///
    /// Neuf et pas dix : ⌘0 n'existe pas ici. Il faudrait décider s'il désigne
    /// la dixième ligne ou la « zéroième », et les deux réponses sont
    /// défendables, ce qui est la définition d'un raccourci qu'on n'utilisera
    /// jamais avec confiance. Au-delà de neuf, la flèche et le filtre sont plus
    /// rapides que de compter des lignes du regard.
    public static let shortcutCount = 9

    /// Le chiffre à afficher sur la ligne de rang `index`, ou `nil` au-delà du
    /// neuvième rang.
    ///
    /// **Le rang est celui de la liste visible.** C'est tout l'intérêt de faire
    /// passer la numérotation par ici : la vue reçoit une liste déjà filtrée et
    /// numérote ce qu'elle dessine, si bien que ⌘9 ne peut pas désigner la
    /// neuvième entrée de l'historique pendant que l'écran en montre trois.
    public static func shortcutNumber(forRowAt index: Int) -> Int? {
        guard index >= 0, index < shortcutCount else { return nil }
        return index + 1
    }

    /// L'entrée que ⌘`number` désigne dans **la liste visible**.
    ///
    /// Rend `nil` pour un chiffre hors de 1…9 et pour un chiffre qui dépasse la
    /// liste : ⌘7 sur trois lignes visibles ne doit rien faire du tout, surtout
    /// pas coller la septième entrée de l'historique. C'est le défaut que ce
    /// couple de fonctions existe pour rendre impossible — coller la mauvaise
    /// chose est le seul type d'erreur qu'un historique de presse-papiers ne
    /// peut pas rattraper, puisque le texte est déjà parti dans l'autre
    /// application.
    public static func entry(
        forShortcut number: Int, in entries: [ClipboardEntry]
    ) -> ClipboardEntry? {
        guard number >= 1, number <= shortcutCount else { return nil }
        let index = number - 1
        guard index < entries.count else { return nil }
        return entries[index]
    }

    // MARK: - Ce que la ligne a le droit d'afficher

    /// Le texte d'une ligne, **borné**, et le fait qu'il ait été rogné.
    ///
    /// Deux valeurs ensemble pour la même raison que `Shown` : elles sortent du
    /// même parcours de chaîne, et les séparer le ferait faire deux fois — sur
    /// un aperçu qui peut peser 2 Mio, ce n'est pas une élégance mais une
    /// milliseconde par ligne.
    public struct RowText: Sendable, Equatable {

        /// Une seule ligne, blancs intérieurs réduits, longueur bornée.
        public let text: String

        /// Le texte affiché s'arrête-t-il avant la fin de ce qui a été copié ?
        /// C'est ce qui autorise l'interface à poser une ellipse, et elle seule
        /// — `ClipboardEntry.preview` n'en stocke jamais.
        public let isClipped: Bool

        public init(text: String, isClipped: Bool) {
            self.text = text
            self.isClipped = isClipped
        }
    }

    /// Ce qu'une ligne du panneau affiche, borné **avant** qu'un `Text` ne le
    /// voie.
    ///
    /// ## Pourquoi la troncature est ici et pas dans la vue
    ///
    /// `lineLimit(1)` ne protège de rien : SwiftUI met le texte en page pour
    /// savoir où couper, donc un `Text` qui porte 2 Mio compose 2 Mio, une fois
    /// par image, et le panneau se fige. La seule troncature qui coûte quelque
    /// chose est celle qui a lieu avant la construction de la vue.
    ///
    /// Ce cas n'est pas théorique bien que `ClipboardEntry.preview(for:)` rogne
    /// déjà à `previewLimit` : l'initialiseur mémoire à mémoire de
    /// `ClipboardEntry` accepte n'importe quel `preview`, une entrée peut venir
    /// d'un `index.jsonl` écrit par une version antérieure ou modifié à la main
    /// — le dossier est délibérément lisible et modifiable —, et
    /// `ClipboardEntry.rowTitle` parcourt tout ce qu'on lui donne.
    ///
    /// ## Comment
    ///
    /// On borne d'abord, on transforme ensuite, et jamais l'inverse : `prefix`
    /// sur une `String` s'arrête au bout de N grappes de graphèmes sans lire la
    /// suite, alors que `split` ou `count` parcourent tout. `rowTitle` est
    /// ensuite appliqué à la copie bornée — c'est **lui** qui décide de ce
    /// qu'une ligne compacte montre (première ligne, indentation retirée), et
    /// le redécrire ici en ferait une deuxième version.
    ///
    /// Le seuil est `ClipboardEntry.previewLimit`, c'est-à-dire exactement ce
    /// que le magasin écrit sur le disque. Un seuil d'affichage plus petit
    /// aurait été un troisième chiffre à tenir d'accord avec les deux autres.
    public static func rowText(for entry: ClipboardEntry) -> RowText {
        let limit = ClipboardEntry.previewLimit

        // `dropFirst` rend une `Substring` en avançant de `limit` positions et
        // pas une de plus ; `isEmpty` est alors une comparaison d'indices. Le
        // total est en O(limit), jamais en O(taille de l'aperçu).
        let overLimit = entry.preview.dropFirst(limit).isEmpty == false
        let bounded = String(entry.preview.prefix(limit))

        // Une copie de valeur, uniquement pour réutiliser `rowTitle` sans le
        // réécrire. Les `String` sont à copie paresseuse : cela ne duplique rien.
        var clamped = entry
        clamped.preview = bounded

        return RowText(
            text: clamped.rowTitle,
            // Trois façons distinctes de perdre du texte, et il suffit d'une :
            // l'aperçu lui-même s'arrête avant la fin du contenu copié ; on
            // vient de le rogner à `previewLimit` ; ou il portait plusieurs
            // lignes et la ligne compacte n'en montre qu'une.
            isClipped: entry.isPreviewTruncated
                || overLimit
                || bounded.contains(where: \.isNewline)
        )
    }
}
