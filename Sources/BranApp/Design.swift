import SwiftUI

/// Le vocabulaire visuel de l'application, en un seul endroit.
///
/// **Pourquoi ce fichier existe.** L'application comptait dix-huit valeurs
/// d'espacement distinctes, douze durées d'animation, sept rayons et sept
/// opacités de fond — pour trois écrans. Aucune n'était fausse prise isolément ;
/// c'est leur nombre qui l'était. Deux cartes voisines respiraient différemment
/// sans qu'aucune décision ne l'ait voulu, et le survol d'une carte n'avait de
/// contour qu'en thème sombre parce qu'il était dessiné en blanc à 9 %.
///
/// La règle est simple : **une vue ne contient plus de nombre.** Si un échelon
/// manque, on l'ajoute ici, où il se compare aux autres.

// MARK: - Espacement

/// Une échelle de 4 points, et rien d'autre.
enum Space {
    /// 1 — entre un titre et son sous-titre, dans une étiquette de deux lignes.
    ///
    /// **L'échelon manquant, trouvé en mesurant.** Quatre vues écrivaient
    /// `spacing: 1` en clair pour la même figure — un libellé au-dessus de sa
    /// précision — parce qu'aucun échelon ne descendait sous 2. Deux points
    /// séparent déjà deux éléments distincts ; ces deux lignes-là n'en sont
    /// qu'un, et les écarter davantage les fait lire comme deux.
    static let line: CGFloat = 1
    /// 2 — entre deux icônes d'une même barre d'actions.
    static let hair: CGFloat = 2
    /// 4 — entre un libellé et sa valeur.
    static let tight: CGFloat = 4
    /// 8 — entre deux éléments d'une même ligne.
    static let small: CGFloat = 8
    /// 12 — l'intérieur d'un contrôle.
    static let inset: CGFloat = 12
    /// 16 — entre deux cartes.
    static let stack: CGFloat = 16
    /// 24 — la marge d'une section.
    static let gutter: CGFloat = 24
    /// 32 — au-dessus d'un grand titre.
    static let section: CGFloat = 32
    /// 14 — le rembourrage d'une carte de liste.
    static let card: CGFloat = 14
}

// MARK: - Rayons

enum Radius {
    /// 6 — un bouton d'icône, une pastille de raccourci.
    static let control: CGFloat = 6
    /// 8 — un champ, une tuile de fait.
    static let field: CGFloat = 8
    /// 12 — une carte de liste, un panneau.
    static let card: CGFloat = 12
    /// 14 — un panneau de tableau de bord.
    ///
    /// Deux points de plus qu'une carte de liste, et c'est délibéré : un
    /// panneau contient des cartes, et un conteneur au même rayon que son
    /// contenu donne cette impression d'emboîtement approximatif qu'on n'arrive
    /// pas à nommer en regardant.
    static let panel: CGFloat = 14
    /// 26 — la pilule de l'encoche, sur les écrans qui n'en ont pas.
    static let pill: CGFloat = 26
}

// MARK: - Tailles fixes

/// Les rares dimensions qu'une vue **ne peut pas** déduire de son contenu.
///
/// **Pourquoi une quatrième section de géométrie.** `Space` mesure ce qui sépare
/// deux choses, `Radius` ce qui arrondit un coin ; ni l'un ni l'autre ne dit ce
/// que fait 44 points de hauteur imposée à une ligne, et les ranger dans `Space`
/// aurait cassé la promesse de son commentaire — « une échelle de 4 points, et
/// rien d'autre » — qui n'est tenable que parce qu'aucun échelon n'y désigne
/// autre chose qu'un écart.
///
/// **Cette section doit rester très courte.** Une taille fixe est un aveu :
/// elle ne suit pas la préférence de taille de texte de macOS, exactement comme
/// les seize tailles en points que `Type` a supprimées. Chacune de celles qui
/// sont ici doit donc défendre pourquoi la mise en page ne peut pas être laissée
/// au contenu. Si un jour l'une d'elles ne peut plus le défendre, elle sort.
enum Size {
    /// **La hauteur d'une ligne de l'historique du presse-papiers.**
    ///
    /// Fixe, et c'est la décision structurante du panneau. Une hauteur variable
    /// oblige la liste à mesurer chaque ligne pour connaître sa propre géométrie
    /// de défilement ; sur les ~500 entrées que `ClipboardStore.windowSize`
    /// garde en mémoire, cela veut dire composer cinq cents lignes avant de
    /// pouvoir dessiner la première, et le panneau s'ouvre au raccourci, sous un
    /// budget de 50 ms que tout le stockage a été conçu pour tenir (voir
    /// `ClipboardStore` : fenêtre bornée, index par jour, blobs jamais ouverts).
    /// Perdre ces 50 ms dans la mise en page après les avoir gagnés sur le
    /// disque serait absurde. Hauteur constante : la position de la ligne *n*
    /// est une multiplication, le défilement de 250 lignes est régulier, et
    /// l'ascenseur ne saute pas en cours de route.
    ///
    /// **44, et pas un chiffre rond au hasard.** Deux lignes de texte au réglage
    /// par défaut — une prévisualisation en `Type.cardBody` (~16 pt d'interligne)
    /// au-dessus d'une méta en `Type.meta` (~14 pt), séparées de `Space.line` —
    /// occupent 31 points ; `Space.tight` en haut et en bas porte le total à 39.
    /// Les 5 points restants sont la marge d'un cran de préférence de taille de
    /// texte, au-delà duquel c'est la prévisualisation qui se rogne, pas la
    /// ligne qui grandit. C'est le prix assumé de la régularité du défilement,
    /// et 44 est sur la grille de 4 points de `Space` (11 × 4).
    /// **34, et c'est un renversement assumé du raisonnement ci-dessus.**
    ///
    /// Les 44 points venaient d'un empilement : un titre au-dessus d'une méta,
    /// séparés, plus les marges. La régularité était juste, la disposition ne
    /// l'était pas — deux lignes de texte pour une entrée dont **une seule**
    /// porte ce qu'on cherche. À l'usage, le panneau montrait neuf entrées là où
    /// l'écran en aurait porté douze, et retrouver un texte copié il y a quatre
    /// copies demandait de faire défiler.
    ///
    /// La méta est passée à droite du titre, sur la même ligne : elle est courte
    /// — une application, un instant relatif — et le titre se rogne déjà. 34
    /// points portent une ligne de `Type.cardBody` avec `Space.tight` de part et
    /// d'autre, restent sur la grille de 4 (8 × 4), et font tenir onze entrées
    /// dans la même fenêtre au lieu de neuf.
    static let clipboardRow: CGFloat = 34

    /// **La ligne d'une image ou d'un fichier**, plus haute que celle d'un texte.
    ///
    /// **Une liste à deux hauteurs, alors que le commentaire de `clipboardRow`
    /// défendait l'inverse.** L'argument — « une liste dont les lignes ne font
    /// pas toutes la même hauteur ne se parcourt pas en diagonale » — vaut pour
    /// des lignes qui portent la même chose. Ce n'est pas le cas ici : une ligne
    /// de texte se lit, une ligne d'image se **regarde**, et une vignette de 28
    /// points ne permettait pas de distinguer deux captures d'écran de la même
    /// application. Serrer le texte et desserrer l'image ne sont pas deux
    /// réglages contradictoires, ce sont deux réponses à deux besoins que la
    /// hauteur unique confondait.
    ///
    /// Le parcours en diagonale reste tenu par ce qui le tenait vraiment :
    /// l'alignement à gauche du titre, identique d'une sorte à l'autre.
    static let clipboardMediaRow: CGFloat = 52

    /// **La largeur du panneau d'historique.**
    ///
    /// 460 points portent une soixantaine de caractères de prévisualisation en
    /// `Type.cardBody` — la longueur au-delà de laquelle une ligne copiée cesse
    /// d'être reconnaissable par son début, et donc au-delà de laquelle chaque
    /// point supplémentaire n'achète plus rien. Plus étroit, deux entrées voisines
    /// se ressemblent ; beaucoup plus large, la fenêtre couvre le document dans
    /// lequel on s'apprête à coller, ce qui est exactement le contraire du geste.
    ///
    /// La comparaison a été faite : Maccy s'en tient à ~300 et coupe trop tôt,
    /// les lanceurs de commandes montent à ~750 parce qu'ils affichent des
    /// résultats hétérogènes et non une liste d'une seule sorte.
    static let clipboardPanelWidth: CGFloat = 460

    /// **La hauteur du panneau d'historique.**
    ///
    /// Dérivée de `clipboardRow` et du clavier, pas choisie : neuf lignes de 44
    /// font 396, et neuf est le nombre exact que ⌘1…⌘9 sait atteindre. Un
    /// panneau qui en montrerait dix laisserait la dixième sans raccourci, à
    /// portée de l'œil et hors de portée de la main — le genre d'écart qu'on ne
    /// remarque pas en le dessinant et qui agace tous les jours. Le champ de
    /// filtre et son séparateur ajoutent une quarantaine de points, les marges le
    /// reste.
    ///
    /// Au-delà, la liste défile : c'est le rôle de la recherche, pas celui de la
    /// hauteur, de retrouver une entrée d'il y a trois semaines.
    ///
    /// **Le chiffre est resté, sa dérivation a changé.** Il valait
    /// `9 × clipboardRow + 84` quand une ligne faisait 44 points ; elle en fait
    /// 34, et recalculer aurait **rétréci** la fenêtre au moment précis où on
    /// cherchait à en voir plus. La hauteur est donc figée à ce qu'elle était, et
    /// ce sont les entrées qui gagnent : onze au lieu de neuf.
    ///
    /// Ce que ça concède : ⌘1…⌘9 n'atteint plus que les neuf premières, et deux
    /// lignes visibles n'ont pas de raccourci chiffré. C'était l'objection qui
    /// avait fixé le neuf, et elle pèse moins que ce qu'elle coûtait — les
    /// flèches et le clic atteignent tout, une liste qui défile montre de toute
    /// façon des lignes sans numéro, et les deux entrées gagnées sont vues sans
    /// aucun geste.
    static let clipboardPanelHeight: CGFloat = 480

    /// **Le carré de vignette d'une ligne de l'historique** : l'aperçu d'une
    /// image, l'icône d'un fichier.
    ///
    /// 28 découle de `clipboardRow` plutôt que de le contraindre : 44 moins
    /// `Space.tight` en haut et en bas laisse 36 au maximum, et s'en approcher
    /// donnerait une vignette qui touche presque les bords et fait paraître la
    /// ligne trop pleine. À 28, les 8 points qui restent de chaque côté alignent
    /// optiquement le carré sur le bloc de deux lignes de texte qu'il accompagne
    /// — c'est-à-dire sur le contenu, et non sur la boîte.
    ///
    /// Assez grand pour servir : à 28 points, soit 56 pixels sur un écran
    /// Retina, deux captures d'écran de la même application restent
    /// distinguables l'une de l'autre, ce qui est la seule chose qu'on demande à
    /// une vignette d'historique — reconnaître, pas lire. Assez petit pour que
    /// le coût de décodage reste celui des lignes visibles.
    ///
    /// Carré, et pas au rapport de l'image : des vignettes de largeurs
    /// différentes désalignent les colonnes de texte d'une ligne à l'autre, et
    /// c'est précisément ce qui rend une liste illisible en diagonale. Le
    /// cadrage est l'affaire de la vue. Son rayon est `Radius.control` : une
    /// vignette est de la taille d'un bouton d'icône, pas d'une carte.
    /// **40, contre 28.** Le raisonnement du dessus tenait la vignette sous la
    /// hauteur d'une ligne de texte ; elle vit maintenant dans une ligne de
    /// média, qui fait 52 points et lui en laisse 40 avec `Space.tight` de part
    /// et d'autre.
    ///
    /// Ce que les 12 points achètent : à 28 points — 56 pixels — deux captures
    /// d'écran de la même application se distinguaient à peine ; à 40, soit 80
    /// pixels, on reconnaît la fenêtre qu'on a copiée. C'est la seule chose
    /// qu'on demande à une vignette d'historique, et elle ne la rendait
    /// qu'à moitié.
    static let clipboardThumbnail: CGFloat = 40

    /// **Ce que la méta d'une ligne a le droit de prendre**, à droite du titre.
    ///
    /// 200 points sur les 460 de la fenêtre, soit un peu moins de la moitié :
    /// assez pour « Google Chrome · il y a 32 minutes · 606 octets », qui est le
    /// cas complet, et jamais assez pour que le titre — l'information qu'on
    /// cherche — soit réduit à une ellipse par une application au nom long.
    /// Au-delà, c'est la méta qui se rogne : elle se relit dans le détail, le
    /// titre non.
    static let clipboardMeta: CGFloat = 200

    /// Combien de lignes de texte une entrée ouverte montre.
    ///
    /// **Cinq, et surtout pas tout.** Une entrée peut porter deux mille
    /// caractères ; les afficher ferait une ligne haute comme la fenêtre, qui
    /// chasserait toutes les autres et transformerait une liste en document.
    /// Cinq lignes suffisent à reconnaître un paragraphe, un bloc de code ou une
    /// adresse complète — c'est-à-dire à répondre à la seule question qu'on se
    /// pose en s'arrêtant sur une ligne : « est-ce bien celui-là ? ». Lire en
    /// entier est l'affaire de l'onglet Presse-papiers, qui a la place.
    static let clipboardExpandedLines = 5
}

// MARK: - Typographie

/// **Aucune taille en points.** Les seize tailles fixes semées dans les vues
/// (11 · 11,5 · 12 · 13 · 15 · 17 · 19 · 26) ne suivaient pas la préférence de
/// taille de texte de macOS : un utilisateur qui l'augmente ne voyait rien
/// changer. Tout dérive désormais d'un style système.
///
/// Deux exceptions assumées, et elles sont commentées sur place : l'encoche et
/// la chasse fixe, où la géométrie est contrainte par le matériel ou par le
/// contenu.
enum Type {
    /// La marque, en tête de la colonne. Un rôle à elle seule : ni un titre de
    /// section, ni un titre de carte. Elle n'apparaît qu'une fois dans toute
    /// l'application, et c'est la première chose qu'on lit en l'ouvrant.
    static let appMark = Font.system(.title3, design: .default, weight: .semibold)

    static let paneTitle = Font.system(.largeTitle, design: .default, weight: .semibold)

    /// Le titre d'une feuille modale.
    ///
    /// **Échelon manquant, trouvé en migrant.** Entre `paneTitle` (largeTitle)
    /// et `cardTitle` (body) il n'y avait rien, et deux feuilles avaient tranché
    /// chacune de leur côté : `BookingPickerSheet` en `.title2.weight(.semibold)`,
    /// `VocabularySheet` en `.title3`. Deux en-têtes, deux tailles, aucune règle.
    /// Une feuille n'est pas une section — elle est plus petite qu'une fenêtre et
    /// plus grande qu'une carte.
    static let sheetTitle = Font.title2.weight(.semibold)

    static let paneLead = Font.callout
    static let cardTitle = Font.body.weight(.medium)
    static let cardBody = Font.callout

    /// Un corps de carte qui doit se détacher : l'avertissement au-dessus de son
    /// explication. `cardBody` seul les met sur le même plan, et on perd
    /// exactement la hiérarchie que le paragraphe gris en dessous suppose.
    static let cardBodyStrong = Font.callout.weight(.medium)

    /// Un champ qu'on **écrit**, par opposition à un texte qu'on lit.
    ///
    /// Une taille au-dessus de `cardBody` et c'est délibéré : rétrécir la zone
    /// de saisie pour l'aligner sur les libellés voisins rend la frappe moins
    /// confortable au bénéfice d'une régularité que personne ne remarque.
    static let input = Font.body

    static let meta = Font.caption
    static let metaFaint = Font.caption2
    static let groupHead = Font.subheadline.weight(.medium)

    // MARK: Le tableau de bord

    /// **Le chiffre principal d'un écran.** Un seul par colonne, jamais deux.
    ///
    /// L'écran Aujourd'hui annonçait « 4 h 08 de travail · 68 % d'une journée de
    /// 6 h » dans une phrase en `paneLead`. C'est une phrase juste, et c'est
    /// exactement le problème : on la lit, au lieu de la voir. Un tableau de
    /// bord se scanne — le chiffre qu'on est venu chercher doit se prendre en
    /// une fixation, pas en une lecture.
    ///
    /// Arrondi comme `timer`, et pour la même raison : ces chiffres changent
    /// sous les yeux, et une chasse fixe empêche la ligne de gigoter à chaque
    /// minute qui passe.
    static let metric = Font.system(.largeTitle, design: .rounded, weight: .semibold)

    /// Le chiffre d'une tuile secondaire. Assez grand pour se détacher de son
    /// libellé, assez petit pour ne pas concurrencer `metric`.
    static let metricSmall = Font.system(.title2, design: .rounded, weight: .semibold)

    /// Le libellé **au-dessus** d'un chiffre. Au-dessus et pas en dessous : on
    /// lit ce qu'on mesure avant de lire la mesure, sinon le nombre arrive sans
    /// unité et il faut y revenir.
    static let metricLabel = Font.caption

    /// L'en-tête d'un panneau. Petites capitales, comme toutes les barres de
    /// titre de tableau de bord depuis toujours : elle doit se voir sans se
    /// lire, puisqu'on la relit rarement après la première fois.
    static let panelHead = Font.caption.weight(.semibold)

    /// Le chrono : arrondi, chiffres de largeur fixe, pour ne pas gigoter.
    static let timer = Font.system(.title3, design: .rounded, weight: .semibold)

    /// L'encoche. Taille fixe assumée : la hauteur disponible est celle du
    /// matériel, elle ne suit aucune préférence.
    static let notch = Font.system(size: 11.5, weight: .medium, design: .rounded)

    /// Une capture lue en chasse fixe le reste.
    static let code = Font.system(.callout, design: .monospaced)
}

// MARK: - Couleurs

/// **Sémantique, jamais littérale.**
///
/// Deux erreurs mesurées que ce type ferme : `.white.opacity(0.09)` pour un
/// contour de survol, invisible en thème clair ; et du texte blanc sur `.tint`
/// dans la colonne, qui tombe à ~1,4:1 de contraste dès que l'accent système est
/// jaune ou vert.
enum Palette {
    /// Le fond d'une carte. Une seule valeur, deux états.
    static func card(hover: Bool) -> AnyShapeStyle {
        hover ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.quinary)
    }

    /// Le fond d'une **ligne sélectionnable** : trois états, aucun accent.
    ///
    /// **Pourquoi ce n'est pas `card(hover:)` avec un paramètre de plus.**
    /// Une carte et une ligne ne se ressemblent qu'à l'arrêt sur image. Une
    /// carte est une surface : elle est visible au repos (`.quinary`), elle se
    /// survole, elle se déplie. Une ligne est un fragment de liste : au repos
    /// elle **n'a pas de fond du tout** — deux cent cinquante rectangles gris
    /// empilés font une texture, pas une liste — et ce qui la distingue de ses
    /// voisines n'est pas la souris mais le **clavier**, qui y pose un point
    /// d'insertion persistant que la souris ne connaît pas. Les deux fonctions
    /// ne partagent donc ni leur état de repos, ni le nombre de leurs états, ni
    /// ce qui les fait changer. Ajouter `selected:` à `card(hover:)` aurait
    /// obligé chaque appelant de carte à passer `selected: false` pour rien, et
    /// produit exactement le composant à huit paramètres que ce fichier existe
    /// pour éviter : un seul point d'entrée qui, à force d'accepter tous les
    /// cas, ne décrit plus aucune intention.
    ///
    /// **Jamais l'accent en fond.** La règle est démontrée, chiffres compris,
    /// dans `SidebarItem.background` : un fond `.tint` avec du texte blanc tombe
    /// à ~1,4:1 dès que l'accent système est jaune ou vert, et un fond
    /// `.selection` avec du texte `.primary` donne du noir sur du bleu foncé
    /// dans la configuration macOS **par défaut**. Aucune couleur de texte fixe
    /// ne peut être correcte sur un fond que l'utilisateur choisit. Le fond
    /// reste donc un matériau neutre, dont le contraste avec `.primary` est
    /// garanti dans les deux thèmes, et la sélection se lit **hors couleur** :
    /// c'est ce qui la rend aussi lisible en vision daltonienne. L'appelant
    /// complète avec la graisse du libellé — `.medium` sélectionné, `.regular`
    /// sinon — et, s'il en a un, avec l'accent sur son **symbole**, où il n'a
    /// personne à porter. Ne pas employer `Palette.selection` ici : son propre
    /// commentaire dit pourquoi.
    ///
    /// **Sélectionné l'emporte sur survolé, et il n'y a pas de quatrième état.**
    /// On aurait pu franchir un cran de plus (`.tertiary`) quand la souris passe
    /// sur la ligne déjà sélectionnée. C'est refusé : le curseur qui traverse la
    /// liste sans rien faire ferait alors s'éclaircir la ligne du clavier, et ce
    /// mouvement se lit comme un déplacement de la sélection. Une sélection au
    /// clavier doit rester immobile tant que le clavier ne l'a pas déplacée.
    ///
    /// **Trois états, deux niveaux de matériau seulement**, et l'écart entre les
    /// deux est volontairement petit : `.quaternary` sur `.quinary`, c'est le
    /// même écart qu'entre le repos et le survol d'une carte. Le survol est une
    /// réponse à un geste en cours, pas une information ; il doit être vu du
    /// coin de l'œil et oublié.
    ///
    /// Ce jeton **existe parce qu'il était déjà écrit en dur** :
    /// `SidebarItem.background` tranche ces trois mêmes valeurs à la main, hors
    /// de `Palette`, et le panneau du presse-papiers allait en faire une
    /// deuxième copie. Deux copies d'une décision de contraste, c'est une copie
    /// qui dérivera. Voir le rapport de migration : `SidebarItem` doit appeler
    /// cette fonction.
    static func row(hover: Bool, selected: Bool) -> AnyShapeStyle {
        if selected { return AnyShapeStyle(.quaternary) }
        if hover { return AnyShapeStyle(.quinary) }
        return AnyShapeStyle(.clear)
    }

    /// Un panneau encastré : tuile de fait, éditeur de notes, bandeau.
    static let well = AnyShapeStyle(.quinary)

    /// Le fond d'un **panneau de tableau de bord**, et la barre de titre qui le
    /// coiffe.
    ///
    /// Deux valeurs et pas une : c'est la barre plus claire qui fait qu'un
    /// panneau se lit comme une surface et non comme un paragraphe. Sans elle,
    /// un titre de section n'est qu'un texte gris de plus dans une colonne, et
    /// c'est précisément ce qui rendait le journal de bord documentaire plutôt
    /// que consultable.
    ///
    /// Des matériaux et non des couleurs : les deux thèmes et les cinq niveaux
    /// de transparence de macOS sont alors gérés par le système, ce qu'aucune
    /// opacité écrite à la main ne fait correctement — la leçon du `.white`
    /// à 9 % qui ouvre ce fichier.
    static let panel = AnyShapeStyle(.quinary)
    static let panelHead = AnyShapeStyle(.quaternary)

    /// Le creux d'une barre de proportion. Toujours visible, y compris à zéro :
    /// une barre vide doit se voir vide, pas absente — sinon « 0 % » et « pas
    /// mesuré » se ressemblent.
    static let trough = AnyShapeStyle(.quaternary)

    /// **N'est plus utilisée pour la colonne, et le commentaire d'origine était
    /// faux.** Il promettait que `.selection` « porte déjà le contraste ». Elle
    /// rend l'accent système saturé : avec `.primary` par-dessus, c'est du noir
    /// sur du bleu foncé en thème clair — la configuration macOS par défaut.
    /// Voir `SidebarItem.background`, qui n'emploie aucune couleur d'accent en
    /// fond et met l'accent sur le symbole.
    ///
    /// Conservée parce qu'elle reste juste dans un conteneur sélectionnable, où
    /// AppKit règle lui-même la couleur du texte. Ne pas l'employer ailleurs.
    static let selection = AnyShapeStyle(.selection)

    /// Les états. **Les seules couleurs littérales autorisées**, et elles sont
    /// ici pour qu'on puisse les compter.
    static let live = Color.red
    static let held = Color.orange
    static let done = Color.green
    static let attention = Color.orange
    static let broken = Color.red
    static let asleep = Color.secondary

    /// Ce qui a avancé **sans l'utilisateur** : une machine qui tourne pendant
    /// qu'il fait autre chose.
    ///
    /// Ni `done` ni `asleep`, et c'est tout le sujet. Le vert dirait « c'est
    /// votre travail », le gris dirait « il ne s'est rien passé » ; ici il s'est
    /// passé quelque chose de réel, qui n'est simplement pas à mettre à votre
    /// crédit. Le bleu est la seule couleur d'état qui ne portait encore aucun
    /// sens dans l'application, donc la seule qui n'en contredise pas un autre.
    static let machine = Color.blue
}

// MARK: - Mouvement

/// Quatre courbes, une par intention.
///
/// Les douze durées précédentes ne correspondaient à aucune différence de sens :
/// 0,14 et 0,15 s cohabitaient pour deux survols identiques.
enum Motion {
    /// Survol, pression, apparition d'une icône. Doit être imperceptible.
    static let hover = Animation.easeOut(duration: 0.12)

    /// Changement d'état d'un contenu : dépliage, texte substitué, progression.
    static let state = Animation.smooth(duration: 0.28)

    /// Entrée ou sortie : bandeau, barre de session, carte.
    static let enter = Animation.spring(response: 0.34, dampingFraction: 0.86)

    /// Changement de section. Le seul mouvement qu'on a le droit de voir.
    static let pane = Animation.spring(response: 0.42, dampingFraction: 0.9)

    /// L'ouverture de l'encoche. Franche, peu rebondissante : elle est vue vingt
    /// fois par heure. Valeur d'origine de `NotchView`, conservée telle quelle.
    static let notch = Animation.spring(response: 0.42, dampingFraction: 0.74)

    /// Le contenu de l'encoche, qui entre **après** son contenant.
    ///
    /// Le délai n'est pas cosmétique : sans lui on voit le texte déborder du
    /// cadre pendant deux images, le temps que le tracé finisse de s'ouvrir.
    static let notchContent = Animation.smooth(duration: 0.3)
    static let notchContentDelay: TimeInterval = 0.09

    /// Le temps qu'il faut rester sur une ligne d'historique avant qu'elle
    /// s'ouvre sur son contenu.
    ///
    /// **Un délai, et pas un survol immédiat.** Sans lui, traverser la liste à
    /// la souris ou à la flèche ferait grandir et rétrécir chaque ligne au
    /// passage : la liste bougerait sous le curseur, et la ligne qu'on visait ne
    /// serait plus là où on l'a vue. Une demi-seconde est le seuil au-delà
    /// duquel s'arrêter sur une ligne veut dire quelque chose — c'est aussi
    /// celui d'une infobulle de macOS, et l'accord n'est pas fortuit : c'est le
    /// même geste, « je m'arrête pour regarder ».
    static let dwell: TimeInterval = 0.5

    /// L'ouverture d'une ligne : plus lente que le survol, parce qu'elle
    /// déplace ce qui est en dessous.
    static let expand = Animation.smooth(duration: 0.22)

    /// Le temps que met l'encoche à se refermer — **et donc le temps qu'il faut
    /// attendre avant de retirer la fenêtre.**
    ///
    /// `NotchOverlay.hide()` posait 380 ms écrits en dur pendant que le ressort
    /// qui les justifie vivait ici. Deux fichiers pour un seul mouvement : régler
    /// le ressort sans toucher l'attente fait disparaître le panneau au milieu de
    /// sa propre fermeture, et aucun test ne peut le voir.
    static let notchCollapse: Duration = .milliseconds(380)

    /// Le repli de la pilule d'attention, et le retrait de sa fenêtre.
    /// Même raisonnement que `notchCollapse`, sur une animation plus courte
    /// (`Motion.enter`) : retirer la fenêtre trop tôt supprime la sortie.
    static let pillCollapse: Duration = .milliseconds(300)

    // MARK: Les boucles

    /// Les animations qui ne s'arrêtent jamais : la pastille qui respire pendant
    /// la dictée, la navette de la barre de chargement.
    ///
    /// **Elles sont supprimées par « Réduire les animations », pas ralenties.**
    /// C'est la seule catégorie de cette énumération qui se coupe entièrement, et
    /// c'est le sens même du réglage : ce qu'il vise en premier, ce sont les
    /// mouvements perpétuels. Les trois de bran vivaient dans l'encoche, c'est-à-dire
    /// dans la seule surface qu'on regarde vraiment, vingt fois par heure.
    static let pulse = Animation.easeOut(duration: 1.25).repeatForever(autoreverses: false)
    static let shuttle = Animation.easeInOut(duration: 0.9).repeatForever(autoreverses: true)

    /// La respiration de la pastille rouge, pendant un enregistrement.
    ///
    /// Distincte de `pulse`, qui ne fait qu'aller : celle-ci revient, parce
    /// qu'une pastille qui s'éteint et se rallume dit « en direct » là où une
    /// pastille qui pulse dit « en cours de calcul ». Distincte de `shuttle`
    /// aussi, plus lente : une navette de chargement doit paraître pressée, un
    /// témoin d'enregistrement dure une heure et ne doit fatiguer personne.
    ///
    /// Elle vivait en clair dans `RecordingBar`, seule durée de boucle de
    /// l'application à ne pas être ici — donc la seule qu'on ne pouvait pas
    /// comparer aux deux autres.
    static let breathe = Animation.easeInOut(duration: 1).repeatForever(autoreverses: true)

    /// La même courbe, pour `withAnimation` **au point de mutation**.
    ///
    /// `branAnimation` est un modificateur : il ne peut pas atteindre un
    /// `withAnimation { … }` posé dans le gestionnaire d'un bouton. C'est le
    /// dernier endroit par lequel une animation échappait au réglage — le
    /// changement de section de la colonne, précisément le mouvement le plus
    /// ample de l'application.
    ///
    /// L'appelant fournit `reduceMotion` parce qu'il est une vue et qu'il peut
    /// le lire ; cette énumération, elle, n'a pas d'environnement.
    static func honouring(_ animation: Animation, reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.1) : animation
    }
}

// MARK: - L'encre de l'encoche

/// Le vocabulaire propre à l'encoche : du blanc sur du noir, à des dosages qui
/// n'ont pas d'équivalent dans `Palette`.
///
/// `Palette` est sémantique et s'adapte au thème ; l'encoche, elle, est noire
/// dans les deux thèmes parce qu'elle imite un trou dans le matériel. Lui
/// imposer les couleurs de l'application n'aurait pas de sens — mais laisser
/// neuf opacités littérales semées dans la vue n'en avait pas non plus.
enum NotchInk {
    /// Le texte principal.
    static let text = Color.white.opacity(0.93)
    /// Une valeur secondaire : le chrono, le pourcentage.
    static let value = Color.white.opacity(0.6)
    /// Un symbole actif.
    static let symbol = Color.white.opacity(0.9)
    /// Un symbole en retrait : le chargement du moteur.
    static let symbolFaint = Color.white.opacity(0.75)
    /// Un symbole d'échec doux : rien entendu, annulé.
    static let symbolMuted = Color.white.opacity(0.5)
    /// Le liseré du contour, une fois ouvert.
    static let edge = Color.white.opacity(0.10)
    /// Le creux d'une barre de progression.
    static let trough = Color.white.opacity(0.18)
    /// Le plein d'une barre de progression.
    static let fill = Color.white.opacity(0.9)
}

// MARK: - Application

extension View {

    /// Anime en respectant « Réduire les animations », **en un seul endroit**
    /// plutôt que dans les quarante vues qui animent quelque chose. Le réglage
    /// n'était honoré qu'à un seul endroit de l'application.
    ///
    /// Sans mouvement, un fondu court subsiste : supprimer *toute* transition
    /// rend les changements d'état illisibles, ce que le réglage ne demande pas.
    func branAnimation<V: Equatable>(_ animation: Animation, value: V) -> some View {
        modifier(ReducedMotion(animation: animation, value: value))
    }

    /// Une animation **perpétuelle**, et le seul modificateur qui la supprime
    /// vraiment sous « Réduire les animations » au lieu de la raccourcir.
    ///
    /// La distinction avec `branAnimation` est le fond du sujet. Une transition
    /// qu'on raccourcit reste lisible : l'état change, on le voit, c'est juste
    /// plus bref. Une boucle qu'on raccourcit devient **pire** — elle bat plus
    /// vite. La seule réponse correcte est de ne pas la jouer, et de laisser la
    /// vue dans son état de repos.
    ///
    /// **Et ce n'est pas un annulateur.** `nil` supprime l'animation des
    /// changements *à venir* de `value` ; il ne coupe pas une boucle déjà
    /// lancée. Une vue dont le réglage peut basculer en cours de vie doit donc
    /// **aussi faire changer la valeur observée** — voir `PulsingDot`, qui
    /// repose `isPulsing` sur un `onChange(of:initial:)`, et non sur un
    /// `onAppear` qui ne se déclenche qu'une fois.
    func branLoop<V: Equatable>(_ animation: Animation, value: V) -> some View {
        modifier(LoopingMotion(animation: animation, value: value))
    }

    /// Le fond d'une carte de liste, avec son contour de survol visible dans les
    /// deux thèmes et un curseur qui annonce qu'on peut cliquer.
    func branCard(isHovering: Bool) -> some View {
        padding(Space.card)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.card(hover: isHovering), in: .rect(cornerRadius: Radius.card))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(.separator, lineWidth: isHovering ? 1 : 0)
            }
            .contentShape(.rect)
            .branAnimation(Motion.hover, value: isHovering)
    }

    /// Un panneau encastré : tuile de fait, éditeur, bloc CRM.
    func branWell() -> some View {
        padding(Space.inset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.well, in: .rect(cornerRadius: Radius.field))
    }
}

private struct ReducedMotion<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation
    let value: V

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? .easeOut(duration: 0.1) : animation, value: value)
    }
}

/// Une boucle : jouée, ou pas jouée du tout. Jamais raccourcie.
private struct LoopingMotion<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation
    let value: V

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

// **Couper l'animation ne suffit pas toujours.** Une horloge qui pousse une
// phase à 40 Hz continue de faire travailler la machine même si plus rien ne
// bouge à l'écran. Les vues concernées lisent donc `accessibilityReduceMotion`
// directement pour **ne pas démarrer** leur boucle, en plus de ne pas l'animer.
// `AnimatedStripe` dans `NotchView.swift` est le cas type.
