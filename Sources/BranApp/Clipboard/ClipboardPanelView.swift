import AppKit
import BranCore
import SwiftUI

/// Ce qu'une touche demande de faire d'une entrée.
///
/// **Au niveau du fichier et non imbriqué dans le modèle** : `ClipboardPanelModel`
/// est `@MainActor`, et un type imbriqué dans un type isolé hérite d'une
/// isolation dont une simple énumération de commandes n'a aucun besoin. Le même
/// raisonnement que les trois `nonisolated static let` en tête de
/// `ClipboardStore`, appliqué à un type plutôt qu'à une constante.
enum ClipboardActivation: Sendable {

    /// ↵ — coller dans l'application d'avant, avec sa mise en forme.
    case paste

    /// ⇧↵ — coller le texte nu. Le geste le plus demandé après « coller », et
    /// c'est pour lui que `ClipboardEntry.plainText` coexiste avec le blob RTF.
    case plainText

    /// ⌘↵ — mettre au presse-papiers sans coller. Pour quand la cible n'est pas
    /// l'application d'avant.
    case copyOnly
}

// MARK: - Le modèle

/// L'état d'affichage du panneau d'historique, et rien d'autre.
///
/// ## Ce qu'il ne fait pas, et pourquoi c'est la moitié de sa définition
///
/// Il ne colle rien, ne touche pas au presse-papiers, n'ouvre ni ne ferme la
/// fenêtre, ne supprime aucun fichier. Tout cela demande AppKit, une cible de
/// collage, un `NSPanel` et le disque — c'est-à-dire quatre choses qu'aucun test
/// ne peut fournir et qui rendraient ce type aussi invérifiable que le panneau
/// lui-même. Il **appelle des fermetures**, fournies par le présentateur, qui
/// est le seul à savoir dans quelle application on retourne et quelle fenêtre
/// se referme.
///
/// La conséquence pratique pour qui écrit le présentateur : **c'est `onPaste`
/// qui doit fermer le panneau**, pas le modèle. Le modèle ne se permet pas de
/// deviner qu'un collage vaut fermeture — c'est peut-être faux pour `onCopyOnly`,
/// et ça l'est certainement pour un futur « coller sans fermer ».
///
/// ## Ce qu'il lit
///
/// `ClipboardStore`, en lecture seule : `recent` pour la liste, `problem` pour
/// le bandeau de panne. Le magasin est `@Observable`, donc la vue se redessine
/// quand une copie arrive pendant que le panneau est ouvert — ce qui est le bon
/// comportement, l'entrée qu'on vient de copier étant souvent celle qu'on
/// cherche.
///
/// **Il n'appelle jamais `ClipboardStore.search(_:limit:)`.** Cette méthode
/// descend sur le disque et sa propre documentation dit qu'elle est faite pour
/// être appelée quand l'utilisateur *valide* une recherche, jamais à chaque
/// frappe. Or ici il n'y a pas de validation à offrir : ↵ colle. Le filtre porte
/// donc sur la fenêtre en mémoire, soit une dizaine de jours au rythme mesuré,
/// et chercher plus loin reste à inventer — probablement dans la fenêtre
/// principale, où une recherche a le droit de prendre son temps.
@MainActor
@Observable
final class ClipboardPanelModel {

    /// La clé de la présentation faite une seule fois.
    ///
    /// `nonisolated` pour que la vue puisse la passer à `@AppStorage`, dont
    /// l'initialiseur s'exécute hors du fil principal : une `String` constante
    /// est `Sendable`, il n'y a rien à protéger. Même motif que
    /// `ClipboardStore.folderName`.
    nonisolated static let introductionKey = "clipboard.panel.introduced"

    // MARK: - Ce que le présentateur fournit

    private let store: ClipboardStore

    /// Le raccourci d'ouverture, tel qu'il est réglé — « ⌘⇧C » par défaut.
    ///
    /// Passé et non déduit : le raccourci est modifiable dans les réglages, et
    /// un état vide qui nommerait « ⌘⇧C » à quelqu'un qui l'a changé pour ⌥V
    /// serait une instruction impossible à suivre. Le présentateur le tient de
    /// `StandaloneTriggerBinding.trigger.displayName`, comme les deux panes.
    let shortcutName: String

    /// La vignette d'une entrée, ou `nil` s'il n'y en a pas (encore).
    ///
    /// **Une fermeture et non un cache lu directement**, pour deux raisons. La
    /// première est un fait de calendrier : `ThumbnailCache` s'écrit en
    /// parallèle de ce fichier, et se brancher dessus aurait fait attendre l'un
    /// pour l'autre. La seconde est durable : la ligne n'a aucun besoin de
    /// savoir *d'où* vient l'image. Elle en veut une, tout de suite, ou rien —
    /// et « rien » est un état parfaitement affichable, le symbole du type. Une
    /// vignette qui arrive plus tard arrive par une invalidation du cache, donc
    /// par un redessin, sans que cette ligne ait à attendre quoi que ce soit.
    ///
    /// **Jamais l'image entière** : une capture d'écran Retina pèse plusieurs
    /// dizaines de mégaoctets décodée, et la liste en montre vingt à la fois.
    private let thumbnail: (ClipboardEntry) -> Image?

    let onPaste: (ClipboardEntry) -> Void
    let onPastePlain: (ClipboardEntry) -> Void
    let onCopyOnly: (ClipboardEntry) -> Void
    let onDelete: (ClipboardEntry) -> Void
    let onDismiss: () -> Void

    // MARK: - L'état d'affichage

    /// Ce qui est tapé dans le champ de filtre.
    var query = ""

    /// La dernière ligne que le **clavier** a désignée.
    ///
    /// Privée, et c'est le point : personne d'autre que ce modèle n'a le droit
    /// de la lire, parce qu'elle peut désigner une entrée qui n'est plus dans la
    /// liste. Ce qui s'affiche est `shown`, où elle est réconciliée avant d'être
    /// rendue visible.
    private var keyboardSelection: ClipboardEntry.ID?

    /// Ce que le dernier collage n'a pas pu faire, ou `nil` quand il a abouti.
    ///
    /// **Le panneau ne se ferme jamais en silence sur un échec**, et c'est le
    /// quatrième des cinq points de la cible de collage. `Paster.paste` rend
    /// `false` quand la cible a disparu ou que la saisie sécurisée est active :
    /// le contenu est alors au presse-papiers et il reste un ⌘V à faire à la
    /// main. Ne rien dire ferait croire à un geste qui a eu lieu, ce qui est
    /// très exactement le défaut que la dictée a déjà connu et corrigé avec
    /// `pasteFallbackNotice`.
    ///
    /// Posé par le présentateur, effacé à l'ouverture suivante : un échec est un
    /// événement, pas un état.
    var lastFailure: String?

    /// Incrémenté à chaque ouverture. La vue le regarde pour **reprendre** le
    /// clavier.
    ///
    /// **Sans lui, les flèches ne marchaient qu'à la première ouverture.** Le
    /// panneau est construit une fois et réutilisé ensuite — `orderOut` le
    /// retire de l'écran, il ne le détruit pas — donc sa `NSHostingView` et son
    /// arbre SwiftUI survivent. `onAppear`, qui posait `isFilterFocused = true`,
    /// ne se déclenche donc **qu'une seule fois dans la vie du processus**. À la
    /// deuxième ouverture, le champ n'avait plus le focus, et comme tous les
    /// raccourcis du panneau sont posés sur le champ — voir `filterField`, c'est
    /// la seule façon d'arriver avant l'interprétation par défaut du champ — ↑,
    /// ↓, ⌘1…9 et ⌫ ne répondaient plus. Seul Échap continuait de fonctionner,
    /// via la fermeture au clic dehors, ce qui rendait la panne d'autant plus
    /// difficile à lire.
    ///
    /// Un compteur plutôt qu'un booléen : « demander le focus » est un
    /// événement, et un booléen déjà à `true` ne redéclencherait rien.
    private(set) var focusRequests = 0

    /// Appelée par le présentateur **après** que le panneau est devenu clé :
    /// poser un `@FocusState` sur une fenêtre qui n'a pas encore le clavier ne
    /// tient pas.
    func requestFocus() { focusRequests += 1 }

    /// Change à chaque vignette fraîchement fabriquée.
    ///
    /// **Un compteur et non les images.** Le modèle ne porte aucune image — une
    /// capture Retina pèse des dizaines de mégaoctets décodée, et la liste en
    /// montre vingt. Il porte de quoi savoir qu'il faut en **redemander** une :
    /// la vue lit ce compteur, donc l'observation l'inscrit dans ses
    /// dépendances, donc l'incrémenter redessine. Sans lui, une vignette
    /// fabriquée après coup n'apparaîtrait qu'au prochain redessin fortuit.
    var thumbnailGeneration = 0

    /// La vignette d'une entrée, en déclarant la dépendance qui la fera
    /// réapparaître.
    ///
    /// La lecture de `thumbnailGeneration` **est** le mécanisme : une fermeture
    /// n'est pas observable, donc l'appeler seule ne rattacherait la vue à rien.
    func thumbnail(for entry: ClipboardEntry) -> Image? {
        _ = thumbnailGeneration
        return thumbnail(entry)
    }

    init(
        store: ClipboardStore,
        shortcutName: String,
        thumbnail: @escaping (ClipboardEntry) -> Image? = { _ in nil },
        onPaste: @escaping (ClipboardEntry) -> Void,
        onPastePlain: @escaping (ClipboardEntry) -> Void,
        onCopyOnly: @escaping (ClipboardEntry) -> Void,
        onDelete: @escaping (ClipboardEntry) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.store = store
        self.shortcutName = shortcutName
        self.thumbnail = thumbnail
        self.onPaste = onPaste
        self.onPastePlain = onPastePlain
        self.onCopyOnly = onCopyOnly
        self.onDelete = onDelete
        self.onDismiss = onDismiss
    }

    // MARK: - Ce que la vue lit

    /// Les lignes visibles et la ligne courante, calculées d'un seul tenant.
    ///
    /// **À lire une fois par passe de `body`, jamais une fois par ligne.** Le
    /// calcul filtre jusqu'à `ClipboardStore.windowSize` entrées ; le refaire
    /// pour chacune des lignes affichées le rendrait quadratique, ce qui est
    /// exactement le budget que tout le stockage a été conçu pour préserver.
    var shown: ClipboardFilter.Shown {
        ClipboardFilter.shown(store.recent, query: query, selection: keyboardSelection)
    }

    /// L'historique est-il vide **avant** tout filtrage ?
    ///
    /// Distinct de « le filtre ne rend rien », et les deux états ont des
    /// branches séparées dans la vue. Les confondre donnerait la phrase
    /// « copiez quelque chose » à quelqu'un qui a trois cents entrées et une
    /// faute de frappe dans son filtre.
    var isHistoryEmpty: Bool { store.recent.isEmpty }

    /// Ce qui empêche de lire ou d'écrire, quand quelque chose l'empêche.
    var problem: String? { store.problem }

    /// L'entrée sous le clavier, quand il y en a une.
    var selectedEntry: ClipboardEntry? { shown.selected }

    /// L'entrée que ⌘`number` désigne dans la liste **visible**.
    func entry(forShortcut number: Int) -> ClipboardEntry? {
        ClipboardFilter.entry(forShortcut: number, in: shown.entries)
    }

    // MARK: - Ce que le clavier demande

    func move(_ move: ClipboardFilter.Move) {
        let now = shown
        keyboardSelection = ClipboardFilter.moved(now.selection, by: move, in: now.entries)
    }

    /// Le clic : la ligne prend le clavier, sans rien coller.
    ///
    /// Un simple clic sélectionne, un double clic colle. C'est la convention de
    /// toutes les listes de macOS, et l'écart avec ↵ est voulu : une liste où le
    /// premier clic colle est une liste où l'on ne peut pas se tromper de
    /// millimètre.
    func select(_ id: ClipboardEntry.ID) {
        keyboardSelection = id
    }

    /// Agit sur la ligne courante. Ne fait rien s'il n'y en a pas.
    func activateSelection(_ activation: ClipboardActivation) {
        guard let entry = selectedEntry else { return }
        activate(activation, on: entry)
    }

    /// Agit sur une entrée nommée — ⌘N, ou un double clic.
    ///
    /// **Le refus est annoncé, il n'est pas silencieux.** Une entrée dont les
    /// contenus lourds ont été purgés, ou dont le contenu a été refusé à
    /// l'écriture pour cause de taille, n'a plus rien à donner : `canPaste` le
    /// dit sans toucher au disque. Un ↵ qui ne ferait rien du tout laisserait
    /// croire à une touche morte ; on dit donc pourquoi, et le panneau reste
    /// ouvert pour qu'on puisse choisir autre chose.
    func activate(_ activation: ClipboardActivation, on entry: ClipboardEntry) {
        guard entry.canPaste else {
            announce("Rien à coller : \(unavailableReason(for: entry)).")
            return
        }

        let subject = spoken(entry)
        switch activation {
        case .paste:
            onPaste(entry)
            // **L'annonce est indispensable ici et nulle part ailleurs.** Le
            // présentateur referme le panneau dans la foulée : l'élément
            // d'accessibilité qui portait la ligne disparaît, et plus rien ne
            // dira que le collage a eu lieu. Une annonce système survit à la
            // fenêtre qui l'a déclenchée, c'est sa seule propriété qui compte.
            announce("Collé : \(subject).")
        case .plainText:
            onPastePlain(entry)
            announce("Collé sans mise en forme : \(subject).")
        case .copyOnly:
            onCopyOnly(entry)
            announce("Copié dans le presse-papiers, sans coller : \(subject).")
        }
    }

    /// Supprime une entrée, en donnant d'abord le clavier à sa voisine.
    ///
    /// **L'ordre compte, et il ne peut pas être inversé.** La ligne qui hérite
    /// de la sélection se décide sur la liste telle qu'elle est *encore* : une
    /// fois l'entrée retirée, il ne reste qu'une sélection introuvable, dont la
    /// réconciliation ordinaire retombe en tête de liste. On remonterait donc
    /// tout en haut à chaque suppression, alors qu'on supprime en descendant.
    /// Voir `ClipboardFilter.selectionAfterRemoving(_:from:)`.
    func delete(_ entry: ClipboardEntry) {
        keyboardSelection = ClipboardFilter.selectionAfterRemoving(entry.id, from: shown.entries)
        onDelete(entry)
        announce("Supprimé : \(spoken(entry)).")
    }

    func dismiss() {
        onDismiss()
    }

    // MARK: - VoiceOver

    /// La phrase à dire en ouvrant le panneau.
    ///
    /// **Une annonce en plus des éléments, pas à leur place.** Le panneau prend
    /// le clavier — c'est ce que `OverlayPanel.makeFocusable` lui donne de plus
    /// qu'aux deux autres — donc le curseur VoiceOver peut réellement parcourir
    /// ses lignes, ce qui n'était pas le cas de la pilule d'attention (voir
    /// `AttentionOverlay`, qui a dû se contenter d'une annonce parce qu'elle ne
    /// prend jamais le focus). Mais le focus arrive dans le **champ de filtre**,
    /// pas dans la liste : sans cette phrase, on entendrait « champ de texte » et
    /// rien sur ce que le panneau contient. C'est aussi elle qui lit l'état vide,
    /// qui n'est traversé par aucun curseur puisqu'il ne contient rien de
    /// focalisable.
    func announceOpening() {
        guard isHistoryEmpty == false else {
            announce(emptyDescription)
            return
        }
        let count = shown.entries.count
        announce(
            "Historique du presse-papiers, \(count) \(count == 1 ? "entrée" : "entrées"). "
                + "Flèches haut et bas pour parcourir, Entrée pour coller, Échap pour fermer."
        )
    }

    /// La phrase de l'historique vide, lue **et** affichée. Une seule
    /// formulation pour les deux : deux textes différents pour le même état
    /// finiraient par se contredire, et c'est le lecteur d'écran qui perdrait.
    var emptyDescription: String {
        "L'historique est vide. Copiez quelque chose, puis rouvrez cette liste "
            + "avec \(shortcutName) : tout ce que vous copierez s'y trouvera."
    }

    /// Pourquoi cette entrée ne peut plus rien donner.
    ///
    /// Deux causes seulement, et elles ne se ressemblent pas : le contenu a été
    /// refusé à l'écriture parce qu'il dépassait `maximumBlobBytes`, ou il a été
    /// purgé par la rétention. Nommer la date dans le second cas n'est pas de la
    /// coquetterie — c'est ce qui permet de comprendre qu'un réglage de
    /// rétention est en cause, et donc de le changer.
    func unavailableReason(for entry: ClipboardEntry) -> String {
        if entry.isRefused {
            return "ce contenu était trop lourd pour être conservé (\(entry.sizeDescription))"
        }
        if let purged = entry.blobsPurgedAt {
            return "le contenu a été purgé le \(purged.formatted(date: .long, time: .omitted))"
        }
        return "il n'y a plus de contenu attaché à cette entrée"
    }

    /// Comment on nomme une entrée à voix haute.
    private func spoken(_ entry: ClipboardEntry) -> String {
        let row = ClipboardFilter.rowText(for: entry)
        guard row.text.isEmpty else { return "« \(row.text) »" }
        return ClipboardPanelVocabulary.kindName(entry)
    }

    /// **Sans mémoire de la dernière phrase, contrairement à
    /// `AttentionOverlay.announce()`.** Là-bas, l'annonce est poussée par une
    /// horloge et redire la même chose à chaque tic serait du bruit pur. Ici,
    /// chaque annonce suit une frappe : coller deux fois la même entrée est un
    /// geste délibéré fait deux fois, et il doit être confirmé deux fois. Une
    /// déduplication rendrait le second collage silencieux, c'est-à-dire
    /// indiscernable d'un ↵ qui n'aurait rien fait.
    private func announce(_ text: String) {
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: text,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }
}

// MARK: - Le vocabulaire des lignes

/// Les mots que la ligne emploie pour décrire une entrée.
///
/// Rassemblés parce qu'ils servent **deux fois chacun** — une fois à l'écran,
/// une fois dans le libellé d'accessibilité — et que deux formulations pour la
/// même chose finissent par diverger. C'est celle du libellé qui perdrait,
/// puisque personne ne la relit.
enum ClipboardPanelVocabulary {

    /// « Image », « 3 fichiers », « Texte mis en forme ».
    static func kindName(_ entry: ClipboardEntry) -> String {
        switch entry.kind {
        case .image:
            return "Image"
        case .file:
            return entry.itemCount > 1 ? "\(entry.itemCount) fichiers" : "Fichier"
        case .richText:
            return "Texte mis en forme"
        case .text:
            return "Texte"
        }
    }

    /// Le symbole de repli, quand il n'y a pas de vignette.
    ///
    /// **C'est aussi le repli d'une application désinstallée.** Le nom de la
    /// source, lui, ne se replie pas : `ClipboardSource` stocke le nom lisible
    /// *au moment de la copie*, précisément pour qu'il reste juste quand
    /// l'application n'existe plus — mesuré, deux applications sur quinze sur un
    /// historique réel. C'est l'icône qui devient introuvable, jamais le nom, et
    /// remplacer une icône manquante par un symbole générique n'efface aucune
    /// information ; réinventer un nom en effacerait une.
    static func symbolName(_ entry: ClipboardEntry) -> String {
        switch entry.kind {
        case .image: "photo"
        case .file: "doc"
        case .richText: "textformat"
        case .text: "text.alignleft"
        }
    }
}

// MARK: - La vue

/// Le contenu du panneau d'historique : un filtre, des bandeaux, une liste.
///
/// ## La ligne n'est pas une carte, et n'essaie pas de l'être
///
/// `branCard` n'est pas employé ici, et le refus est argumenté plutôt que
/// paresseux. Six désaccords, dont aucun ne se règle par un paramètre : pas de
/// chevron (une ligne ne se déplie pas, elle se colle) ; pas d'actions révélées
/// au survol, puisque ici toute action est une touche ; une hauteur **fixe**
/// obligatoire, que `branCard` ne peut pas donner puisqu'il se dimensionne sur
/// son contenu (voir `Size.clipboardRow` pour ce que cette hauteur achète) ; une
/// vignette et une pastille ⌘N qui n'ont d'équivalent nulle part ailleurs ; un
/// état sélectionné-au-clavier qu'aucune carte n'a — c'est `Palette.row(hover:selected:)`
/// et non `Palette.card(hover:)` ; et `.textSelection(.enabled)`, qui deviendrait
/// nuisible puisque la frappe filtre au lieu de sélectionner. Les y faire entrer
/// aurait produit le composant à huit paramètres que `Design.swift` existe pour
/// éviter.
///
/// ## Les animations
///
/// Une seule dans tout le fichier, sur les bandeaux, et elle passe par
/// `branAnimation` comme les deux panes. **La liste n'est jamais animée** : un
/// diff animé au filtrage ferait glisser jusqu'à `ClipboardStore.windowSize`
/// lignes à chaque frappe, là où les panes existantes en animent cinquante sur
/// un changement de compte. La seule mutation clavier qui change ce qui est à
/// l'écran est la suppression, et elle passe par `honouring(_:)` — c'est-à-dire
/// par `Motion.honouring`, le seul chemin qui atteigne une animation posée
/// dans un gestionnaire de touche. ↵ n'anime rien parce qu'il ne reste rien à
/// animer : le présentateur referme le panneau.
struct ClipboardPanelView: View {

    @Bindable var model: ClipboardPanelModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Le champ de filtre, focalisé à l'ouverture et jamais quitté.
    @FocusState private var isFilterFocused: Bool

    /// Voir `watchesSecureInput(_:)` : la valeur ne peut pas être lue
    /// directement dans le `body`, rien ne la publie.
    @State private var isSecureInputActive = false

    /// A-t-on déjà expliqué qu'un historique démarre ? Une seule fois dans la
    /// vie de l'installation, d'où le passage par les préférences plutôt que par
    /// un `@State` que la première fermeture du panneau effacerait.
    @AppStorage(ClipboardPanelModel.introductionKey) private var wasIntroduced = false

    /// Les chiffres que ⌘1…⌘9 peuvent porter.
    private static let shortcutDigits = CharacterSet(charactersIn: "123456789")

    var body: some View {
        // Une seule lecture de `shown` par passe : voir sa documentation.
        let shown = model.shown

        return VStack(spacing: 0) {
            filterField
            Divider()
            notices
            content(shown)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Un matériau et non une couleur, pour la raison que `Palette` donne en
        // tête : les deux thèmes et les cinq niveaux de transparence de macOS
        // sont alors l'affaire du système. Voir le rapport : il manque un jeton
        // `Palette.floating` pour le fond d'une fenêtre posée par-dessus une
        // *autre* application, que `Palette.panel` (`.quinary`) ne peut pas
        // jouer — presque transparent sur un fond de bureau, c'est illisible.
        .background(.regularMaterial)
        .clipShape(.rect(cornerRadius: Radius.panel))
        .watchesSecureInput($isSecureInputActive)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Historique du presse-papiers")
        .onAppear {
            isFilterFocused = true
            model.announceOpening()
        }
        // La vue survit à la fermeture du panneau : `onAppear` ne reviendra
        // jamais. C'est ce compteur, et lui seul, qui rend le clavier au champ
        // aux ouvertures suivantes. Voir `ClipboardPanelModel.focusRequests`.
        .onChange(of: model.focusRequests) { isFilterFocused = true }
    }

    // MARK: - Le filtre

    /// Le champ, et **tous** les raccourcis du panneau.
    ///
    /// **Les touches sont posées sur le champ et pas sur le conteneur, et ce
    /// n'est pas un détail de placement.** `onKeyPress` est consulté avant le
    /// traitement par défaut de la vue *focalisée* ; posé sur un ancêtre, il ne
    /// voit que ce que le champ a laissé passer. Or un champ de texte a une
    /// opinion sur presque toutes ces touches : ↑ et ↓ déplacent le point
    /// d'insertion, ⌘⌫ efface jusqu'au début de la ligne, Échap annule la
    /// complétion. Les mettre ici est la seule façon d'arriver avant.
    ///
    /// Et le champ garde le focus en permanence — aucune ligne n'est focalisable
    /// — ce qui est exactement l'exigence : ↑ et ↓ déplacent la sélection **sans
    /// sortir du champ**, donc on peut continuer à taper après avoir regardé.
    private var filterField: some View {
        HStack(spacing: Space.small) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(Type.meta)
                .accessibilityHidden(true)

            TextField("Filtrer l'historique", text: $model.query)
                .textFieldStyle(.plain)
                .font(Type.input)
                .focused($isFilterFocused)
                .accessibilityLabel("Filtrer l'historique")
                .accessibilityHint(
                    "Les flèches haut et bas déplacent la sélection sans quitter le champ. "
                        + "Entrée colle, Maj Entrée colle sans mise en forme, "
                        + "Commande Entrée copie sans coller, Commande Suppression supprime."
                )
                .onKeyPress(.upArrow) { model.move(.up); return .handled }
                .onKeyPress(.downArrow) { model.move(.down); return .handled }
                .onKeyPress(.home) { model.move(.first); return .handled }
                .onKeyPress(.end) { model.move(.last); return .handled }
                // **Échap ferme, et ne vide pas d'abord le champ.** C'est un
                // écart assumé avec `SearchField`, dont Échap efface la
                // recherche avant de rendre le clavier. Là-bas, le panneau reste
                // ouvert derrière et la recherche est un état durable qu'on ne
                // veut pas perdre par mégarde. Ici la fenêtre entière est
                // éphémère : elle s'ouvre au raccourci et se referme dans la
                // seconde, et son filtre ne survit pas à sa fermeture de toute
                // façon. Demander deux frappes pour partir ferait payer un
                // acquittement à un état que personne ne cherchait à garder.
                .onKeyPress(.escape) { model.dismiss(); return .handled }
                // `phases:` est écrit alors qu'il n'a qu'une valeur utile ici :
                // c'est lui qui choisit la surcharge d'`onKeyPress` qui donne
                // accès à la frappe, donc à ses modificateurs. Sans lui, la
                // surcharge sans argument l'emporte et ⇧↵ est indiscernable de ↵.
                .onKeyPress(.return, phases: .down) { press in
                    // ⌘ est testé avant ⇧ : les deux ensemble sont une frappe
                    // qu'aucun libellé n'annonce, et il vaut mieux qu'elle fasse
                    // le geste le moins engageant des deux — copier sans coller
                    // ne touche pas l'application d'en face.
                    if press.modifiers.contains(.command) {
                        model.activateSelection(.copyOnly)
                    } else if press.modifiers.contains(.shift) {
                        model.activateSelection(.plainText)
                    } else {
                        model.activateSelection(.paste)
                    }
                    return .handled
                }
                .onKeyPress(.delete, phases: .down) { press in
                    // **Sans Commande, la touche appartient au champ.** Retour
                    // arrière doit effacer une lettre du filtre ; l'intercepter
                    // rendrait le champ impossible à corriger, et le symptôme —
                    // « je ne peux plus effacer ce que je tape » — serait
                    // immédiat et incompréhensible.
                    guard press.modifiers.contains(.command) else { return .ignored }
                    deleteSelection()
                    return .handled
                }
                .onKeyPress(characters: Self.shortcutDigits, phases: .down) { press in
                    guard press.modifiers.contains(.command),
                          let digit = press.characters.first,
                          let number = Int(String(digit)),
                          let entry = model.entry(forShortcut: number)
                    else { return .ignored }
                    model.activate(.paste, on: entry)
                    return .handled
                }

            if model.query.isEmpty == false {
                Button("Effacer", systemImage: "xmark.circle.fill") { model.query = "" }
                    .buttonStyle(.plain)
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
                    .help("Effacer le filtre")
            }
        }
        .padding(.horizontal, Space.inset)
        .padding(.vertical, Space.small)
    }

    // MARK: - Les bandeaux

    /// Les trois choses qu'il faut dire avant la liste.
    ///
    /// Même forme, même symbole et mêmes mots que les deux panes : un bandeau
    /// qui dirait la même panne autrement obligerait à la reconnaître deux fois.
    @ViewBuilder
    private var notices: some View {
        VStack(spacing: 0) {
            // **Une fois, et jamais plus.** Un historique du presse-papiers
            // enregistre ce qu'on copie sans qu'on l'ait demandé à chaque fois :
            // le dire une fois est le minimum, le redire à chaque ouverture
            // serait une bannière qu'on apprend à ne plus lire — c'est-à-dire
            // exactement le canal qu'on veut garder disponible pour les pannes
            // juste en dessous.
            if wasIntroduced == false {
                NoticeRow(
                    text: "bran garde désormais ce que vous copiez. \(model.shortcutName) "
                        + "rouvre cette liste, ↵ colle la ligne choisie. Le texte est conservé ; "
                        + "les images et les fichiers lourds sont effacés au bout de la durée "
                        + "réglée dans les réglages.",
                    symbol: "clipboard",
                    // L'historique se remplit **sans l'utilisateur**, pendant
                    // qu'il fait autre chose : c'est très exactement ce que
                    // `Palette.machine` nomme.
                    tint: Palette.machine
                ) {
                    Button("Compris") { wasIntroduced = true }
                        .controlSize(.small)
                }
            }

            // ↵ échouera : macOS bloque la synthèse de frappe tant qu'un champ
            // sécurisé a le focus, et c'est documenté dans `Paster.swift`. Le
            // dire avant plutôt que laisser constater après.
            if isSecureInputActive {
                NoticeRow(
                    text: "Saisie sécurisée active : macOS bloque le collage automatique tant "
                        + "qu'un champ de mot de passe a le focus. ⌘↵ met quand même l'entrée "
                        + "au presse-papiers, à coller à la main.",
                    symbol: "lock.fill",
                    tint: Palette.attention
                )
            }

            if let failure = model.lastFailure {
                NoticeRow(
                    text: failure,
                    symbol: "arrow.uturn.backward",
                    tint: Palette.attention
                )
            }

            if let problem = model.problem {
                NoticeRow(
                    text: problem,
                    symbol: "externaldrive.badge.xmark",
                    tint: Palette.attention
                )
            }
        }
        // `.clipped()` avant l'animation : un bandeau qui entre par le haut
        // passerait sinon par-dessus le champ de filtre pendant la transition.
        .clipped()
        // Une seule animation qui couvre les trois bandeaux. Sans elle, les
        // `.transition` déclarées par `NoticeRow` ne se déclencheraient jamais —
        // un `.transition` sans animation sur un ancêtre est du code mort.
        .branAnimation(Motion.enter, value: noticeSignature)
    }

    /// Ce qui doit relancer l'animation des bandeaux. Même motif que
    /// `DictationPane` : une chaîne unique, parce que SwiftUI n'anime une
    /// insertion que si la valeur surveillée change **au même instant**.
    private var noticeSignature: String {
        var parts: [String] = []
        if wasIntroduced == false { parts.append("présentation") }
        if isSecureInputActive { parts.append("saisie sécurisée") }
        if let failure = model.lastFailure { parts.append(failure) }
        if let problem = model.problem { parts.append(problem) }
        return parts.joined(separator: "|")
    }

    // MARK: - La liste et ses deux absences

    @ViewBuilder
    private func content(_ shown: ClipboardFilter.Shown) -> some View {
        if model.isHistoryEmpty {
            // Premier lancement, ou historique entièrement vidé. La phrase nomme
            // le raccourci — un état vide qui ne dit pas comment revenir est un
            // cul-de-sac.
            ContentUnavailableView {
                Label("Presse-papiers vide", systemImage: "clipboard")
            } description: {
                Text(model.emptyDescription)
            }
            .accessibilityElement(children: .combine)
        } else if shown.isEmpty {
            // **Une branche distincte de la précédente.** Elles se ressemblent à
            // l'écran et ne veulent pas dire la même chose : ici il y a un
            // historique, c'est le filtre qui ne trouve rien, et la seule chose
            // utile à montrer est le mot cherché.
            ContentUnavailableView.search(text: model.query)
        } else {
            list(shown)
        }
    }

    private func list(_ shown: ClipboardFilter.Shown) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: Space.hair) {
                    ForEach(Array(shown.entries.enumerated()), id: \.element.id) { index, entry in
                        ClipboardRow(
                            entry: entry,
                            shortcut: ClipboardFilter.shortcutNumber(forRowAt: index),
                            isSelected: entry.id == shown.selection,
                            thumbnail: model.thumbnail(for: entry),
                            unavailableReason: entry.canPaste ? nil : model.unavailableReason(for: entry),
                            onSelect: { model.select(entry.id) },
                            onActivate: { model.activate($0, on: entry) },
                            onDelete: { honouring { model.delete(entry) } }
                        )
                        .id(entry.id)
                    }
                }
                .padding(.horizontal, Space.small)
                .padding(.vertical, Space.small)
            }
            // Sans animation : `scrollTo` posé hors de toute animation saute
            // d'un coup, ce qui est le bon comportement sous une flèche tenue.
            // Un défilement animé à chaque cran prendrait du retard sur la
            // répétition de touche et la sélection sortirait de l'écran.
            .onChange(of: shown.selection) { _, selection in
                guard let selection else { return }
                proxy.scrollTo(selection, anchor: .center)
            }
        }
    }

    // MARK: - Muter depuis une touche

    private func deleteSelection() {
        guard let entry = model.selectedEntry else { return }
        honouring { model.delete(entry) }
    }

    /// **La seule animation impérative du fichier, et le seul chemin qui
    /// atteigne une mutation déclenchée par une touche.**
    ///
    /// `branAnimation` est un modificateur : il ne peut pas atteindre ce qui se
    /// passe dans un gestionnaire de `onKeyPress`. `Motion.honouring` existe
    /// pour ce trou exactement, et il prend `reduceMotion` en paramètre parce
    /// qu'une énumération n'a pas d'environnement à lire — la vue, si.
    ///
    /// N'est employé que pour la suppression : c'est la seule frappe qui retire
    /// une ligne sous les yeux. Sans elle, les lignes du dessous sautent d'un
    /// cran sans transition et l'on ne sait plus laquelle vient de partir.
    private func honouring(_ change: () -> Void) {
        withAnimation(Motion.honouring(Motion.enter, reduceMotion: reduceMotion), change)
    }
}

// MARK: - La ligne

/// Une entrée de l'historique, en hauteur fixe.
///
/// Ne connaît ni le magasin, ni le modèle : elle reçoit ce qu'elle affiche et
/// rend ce qu'on lui demande. C'est ce qui permet à la liste de n'être qu'un
/// `ForEach` et à chaque ligne de ne rien recalculer.
private struct ClipboardRow: View {

    let entry: ClipboardEntry
    let shortcut: Int?
    let isSelected: Bool
    let thumbnail: Image?

    /// Pourquoi ↵ ne marchera pas sur cette ligne, ou `nil` si tout va bien.
    /// Calculé par le modèle pour que la phrase affichée dans l'infobulle et
    /// celle annoncée au refus soient la même.
    let unavailableReason: String?

    let onSelect: () -> Void
    let onActivate: (ClipboardActivation) -> Void
    let onDelete: () -> Void

    @State private var isHovering = false

    private var row: ClipboardFilter.RowText { ClipboardFilter.rowText(for: entry) }

    var body: some View {
        HStack(spacing: Space.small) {
            leading

            VStack(alignment: .leading, spacing: Space.line) {
                title
                meta
            }

            Spacer(minLength: Space.small)

            trailing
        }
        .padding(.horizontal, Space.inset)
        // La hauteur fixe est la décision structurante du panneau, et son
        // chiffre se défend dans `Design.swift`. Elle vaut aussi pour les lignes
        // vides de texte : une liste dont les lignes ne font pas toutes la même
        // hauteur ne se parcourt pas en diagonale.
        .frame(height: Size.clipboardRow)
        .background(
            Palette.row(hover: isHovering, selected: isSelected),
            in: .rect(cornerRadius: Radius.field)
        )
        .contentShape(.rect)
        .onHover { isHovering = $0 }
        .branAnimation(Motion.hover, value: isHovering)
        .branAnimation(Motion.hover, value: isSelected)
        // Le double clic avant le simple : déclaré dans l'autre ordre, le simple
        // avale le premier des deux clics.
        .onTapGesture(count: 2) { onActivate(.paste) }
        .onTapGesture { onSelect() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        // Le trait, et non une mention « sélectionné » dans le libellé :
        // VoiceOver l'annonce dans la langue et la formulation du système.
        .accessibilityAddTraits(isSelected ? AccessibilityTraits.isSelected : [])
        .accessibilityAction(named: "Coller") { onActivate(.paste) }
        .accessibilityAction(named: "Coller en texte brut") { onActivate(.plainText) }
        .accessibilityAction(named: "Copier sans coller") { onActivate(.copyOnly) }
        .accessibilityAction(named: "Supprimer") { onDelete() }
    }

    // MARK: La vignette

    @ViewBuilder
    private var leading: some View {
        if let thumbnail {
            thumbnail
                .resizable()
                // Rempli puis rogné, jamais déformé : un carré au rapport de
                // l'image désalignerait les colonnes de texte d'une ligne à
                // l'autre, ce qui est précisément ce qui rend une liste
                // illisible en diagonale.
                .scaledToFill()
                .frame(width: Size.clipboardThumbnail, height: Size.clipboardThumbnail)
                .clipShape(.rect(cornerRadius: Radius.control))
                .accessibilityHidden(true)
        } else {
            Image(systemName: ClipboardPanelVocabulary.symbolName(entry))
                .font(Type.cardBody)
                .foregroundStyle(.secondary)
                .frame(width: Size.clipboardThumbnail, height: Size.clipboardThumbnail)
                .accessibilityHidden(true)
        }
    }

    // MARK: Le texte

    private var title: some View {
        // `row.text` est déjà borné à `ClipboardEntry.previewLimit` par
        // `ClipboardFilter.rowText` : un `Text` qui porterait les 2 Mio d'un
        // aperçu géant les mettrait en page à chaque image, `lineLimit` ou pas.
        // L'ellipse vient du modèle, jamais du stockage — `preview` n'en écrit
        // aucune, exprès, pour qu'un texte finissant vraiment par « … » reste
        // discernable d'un texte coupé.
        Text(displayedTitle)
            .font(Type.cardBody)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var displayedTitle: String {
        guard row.text.isEmpty else { return row.isClipped ? row.text + "…" : row.text }
        // Rien à écrire : une image, ou un fichier sans nom lisible. On nomme le
        // type plutôt que de laisser une ligne muette — `ClipboardEntry.preview`
        // reste vide exprès dans ce cas, pour qu'aucune chaîne d'interface ne
        // se retrouve stockée dans une donnée.
        return ClipboardPanelVocabulary.kindName(entry)
    }

    private var meta: some View {
        HStack(spacing: Space.tight) {
            // Le nom **stocké** fait foi : il a été lu au moment de la copie,
            // quand l'application existait encore. Silence quand on ne sait
            // rien, plutôt qu'« Inconnu », qui occupe la même place sans rien
            // dire — c'est ce que `ClipboardSource.isUnknown` demande.
            if let name = entry.source?.name {
                Text(name)
                Text("·")
            }

            Text(entry.lastCopiedAt, format: .relative(presentation: .named))

            // Le poids, systématiquement pour un contenu lourd, et seulement
            // quand la ligne ne montre pas tout pour du texte : « 512 des 4 312
            // caractères » n'apprend rien quand les 17 caractères sont là.
            if entry.isRefused || entry.totalBlobBytes > 0 || row.isClipped {
                Text("·")
                Text(entry.sizeDescription)
            }

            if entry.isMultipleItems {
                Text("·")
                Text("\(entry.itemCount) éléments")
            }
        }
        .font(Type.meta)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    // MARK: Les marques de droite

    @ViewBuilder
    private var trailing: some View {
        HStack(spacing: Space.tight) {
            // **La ligne reste, le texte reste, seul le collage part.** Un blob
            // purgé n'est pas une entrée à cacher : `ClipboardEntry` conserve
            // exprès ses références mortes pour qu'on puisse dire *quoi* a
            // disparu et *quand*. L'infobulle nomme la date parce que c'est elle
            // qui relie ce qu'on voit au réglage de rétention qui l'a causé.
            if let unavailableReason {
                Image(systemName: entry.isRefused ? "exclamationmark.triangle" : "clock.badge.xmark")
                    .font(Type.meta)
                    .foregroundStyle(.secondary)
                    // La même phrase que celle annoncée quand ↵ est refusé :
                    // ce qu'on lit dans l'infobulle et ce qu'on entend au refus
                    // ne doivent pas être deux descriptions du même état.
                    .help("Rien à coller : \(unavailableReason).")
            }

            // Mesuré : 43 entrées sur 250 ont été copiées plus d'une fois. Assez
            // pour mériter un signe, trop peu pour mériter une colonne.
            if entry.wasRecopied {
                Label("\(entry.copyCount)", systemImage: "arrow.triangle.2.circlepath")
                    .labelStyle(.titleAndIcon)
                    .font(Type.metaFaint)
                    .foregroundStyle(.secondary)
                    .help("Copié \(entry.copyCount) fois.")
            }

            if let shortcut {
                Text("⌘\(shortcut)")
                    .font(Type.metaFaint)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Space.tight)
                    .padding(.vertical, Space.hair)
                    .background(Palette.well, in: .rect(cornerRadius: Radius.control))
            }
        }
    }

    // MARK: Ce que VoiceOver lit

    /// Le libellé de la ligne, dans l'ordre où on le lirait à voix haute.
    ///
    /// Le contenu d'abord, parce que c'est ce qu'on cherche ; la provenance et
    /// l'ancienneté ensuite, parce que ce sont les deux critères dont on se
    /// souvient trois semaines plus tard ; le raccourci en dernier, parce que
    /// c'est le geste et non la description.
    ///
    /// **Le numéro ⌘N est dans le libellé et pas seulement dans la pastille.**
    /// Une pastille est un repère purement visuel : sans lui dans le libellé, la
    /// liste garde neuf raccourcis parfaitement fonctionnels dont rien n'annonce
    /// l'existence à qui ne voit pas l'écran, c'est-à-dire précisément la
    /// personne pour qui compter des lignes à la flèche coûte le plus cher.
    private var accessibilityLabel: String {
        var parts: [String] = []

        switch entry.kind {
        case .text, .richText:
            parts.append(row.text.isEmpty ? ClipboardPanelVocabulary.kindName(entry) : "« \(row.text) »")
        case .image, .file:
            // Le type d'abord — « Image », « 3 fichiers » — puis le nom quand il
            // y en a un : entendre « Image » avant le nom du fichier évite de
            // devoir déduire la nature de l'entrée de son intitulé.
            parts.append(ClipboardPanelVocabulary.kindName(entry))
            if row.text.isEmpty == false { parts.append("« \(row.text) »") }
        }

        // Le poids, aux mêmes conditions qu'à l'écran, pour que ce qui est lu et
        // ce qui est vu ne divergent pas.
        if entry.isRefused || entry.totalBlobBytes > 0 || row.isClipped {
            parts.append(entry.sizeDescription)
        }

        if let name = entry.source?.name { parts.append(name) }

        parts.append(entry.lastCopiedAt.formatted(.relative(presentation: .named)))

        if entry.wasRecopied { parts.append("copié \(entry.copyCount) fois") }
        if let unavailableReason { parts.append(unavailableReason) }
        if let shortcut { parts.append("commande \(shortcut)") }

        return parts.joined(separator: ", ")
    }
}
