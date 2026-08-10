import Foundation

/// Le seul point de décision de la capture du presse-papiers.
///
/// Même parti pris que `SnapshotMachine` et `DictationMachine` : elle ne touche
/// ni à l'écran, ni au presse-papiers, ni au disque. Elle reçoit des événements
/// et rend des effets, ce qui la rend testable en une milliseconde, sans
/// autorisation — et c'est pour ça qu'elle vit dans une bibliothèque plutôt que
/// dans `BranApp`, qui n'a pas de cible de test.
///
/// Elle décide **deux choses, et rien d'autre** : quand le presse-papiers a fini
/// de bouger, et lesquels de ses types méritent d'être lus. Elle ne lit jamais
/// le contenu ; l'appelant le fait, une seule fois, sur son instruction. Elle ne
/// construit pas non plus l'entrée : `ClipboardEntry` est le travail de qui
/// exécute le plan.
///
/// ```
///                       ┌──────┐   indice de copie (⌘C, sondage)
///                  ┌───►│ idle │──────────────────────────┐
///                  │    └──────┘                          ▼
///                  │                            ┌────────────────────┐
///                  │  compteur immobile          │      settling      │
///                  ├─────────────────────────────┤ +40 +120 +300 +500 │
///                  │  → rien n'a été copié       └──┬──────┬──────┬───┘
///                  │                                │      │      │
///                  │  écriture de bran, marqueur    │      │      │ compteur
///                  │  privé, promesse de fichier    │      │      │ bougé mais
///                  ├────────────────────────────────┘      │      │ types vides
///                  │                                       │      ▼
///                  │                                       │  ┌──────────────────┐
///                  │  rien de lisible au bout de 2 s       │  │awaitingSlowWriter│
///                  ├───────────────────────────────────────┼──┤ +250 ms, 2 s max │
///                  │                                       │  └────────┬─────────┘
///                  │    deux mesures identiques après      │           │ types
///                  │    +300 ms, ou échéance atteinte      ▼           ▼
///                  │                            ┌────────────────────────┐
///                  └────────────────────────────┤       capturing        │
///                       contenu lu              └────────────────────────┘
/// ```
///
/// **Le problème de stabilisation, mesuré sur macOS 26.5.** `clearContents()`
/// incrémente le compteur de changement de **un**. Chaque `setData` qui suit
/// l'incrémente de **zéro**. Une application qui vide puis écrit cinq
/// représentations publie donc un presse-papiers **vide** au compte N et le
/// remplit dans les millisecondes qui suivent ; certaines écrivent de façon
/// asynchrone, 80 à 200 ms après la frappe qui a causé la copie. Le compteur ne
/// dit donc pas que la copie est terminée — il dit seulement qu'elle a commencé.
///
/// Lire la **liste des types** est gratuit : ça n'appelle aucun fournisseur
/// paresseux et ça ne déclenche pas l'alerte d'accès de macOS 15.4. Lire le
/// **contenu** ne l'est ni l'un ni l'autre. D'où l'anti-rebond : on échantillonne
/// la liste des types à +40, +120, +300 puis +500 ms, et on ne lit le contenu
/// qu'une fois.
///
/// **Un seul échantillon ne prouve rien.** Deux mesures identiques — même compte
/// *et* même jeu de types — sont exigées avant de capturer, parce que le danger
/// est précisément qu'un presse-papiers vide soit publié au compte final.
///
/// **Et deux mesures concordantes ne suffisent pas non plus avant +300 ms.**
/// Les écritures asynchrones mesurées s'étalent de 80 à 200 ms après la frappe :
/// une application qui pose son PNG à +30 ms et son HTML à +200 ms donne deux
/// relevés identiques à +40 et +120 sans avoir fini d'écrire, et l'entrée serait
/// rangée sous la mauvaise sorte. Le plancher couvre donc toute la fenêtre
/// mesurée, avec 100 ms de marge. On continue d'échantillonner à +40 et +120 —
/// ça détecte le mouvement et ça alimente le prédicat — mais la sortie vers la
/// capture reste verrouillée avant +300.
///
/// L'arbitrage est asymétrique, et c'est ce qui le rend facile : **personne ne
/// regarde son historique se remplir.** La seule latence perçue est celle de
/// ⌘⇧V → panneau ouvert, qui n'a aucun rapport. 180 ms de plus ne coûtent rien
/// de perceptible ; une entrée capturée à moitié écrite est fausse pour
/// toujours.
///
/// **Les deux sorties d'échéance, dont l'une était fausse dans la première
/// version.**
/// - Le compteur n'a pas bougé de tout le budget → la frappe n'était pas une
///   copie (⌘C dans un champ vide). On ne capture rien. C'est normal, pas un
///   échec.
/// - Le compteur a bougé mais le jeu de types est **encore vide** à l'échéance →
///   on n'abandonne **pas**. Un écrivain lent — Excel qui fabrique PDF + TIFF +
///   PNG + HTML + texte, une grande plage Numbers, un calque Photoshop — est
///   toujours en train de remplir. On repasse à une cadence lente plutôt que de
///   jeter la copie.
public struct ClipboardMachine: Sendable {

    /// Une horloge monotone, pas `Date`. Sur une fenêtre de 500 ms, un recalage
    /// NTP de quelques centaines de millisecondes suffirait à faire croire à la
    /// machine que son budget est épuisé — ou qu'il ne l'est jamais. Les
    /// instants viennent toujours de l'appelant : la machine n'appelle jamais
    /// `.now`, ce qui laisse les tests s'exécuter en microsecondes.
    public typealias Instant = ContinuousClock.Instant

    // MARK: - Cadence

    /// Les instants d'échantillonnage, comptés depuis l'indice. Le dernier
    /// **est** le budget : arrivé là, on tranche au lieu de reprogrammer.
    public static let sampleOffsets: [Duration] = [
        .milliseconds(40), .milliseconds(120), .milliseconds(300), .milliseconds(500),
    ]

    /// **Le plancher : aucune capture ne conclut avant 300 ms.** Deux relevés
    /// concordants plus tôt ne prouvent rien, parce que les écritures
    /// asynchrones mesurées s'étalent de 80 à 200 ms après la frappe : un
    /// écrivain qui pose son PNG à +30 et son HTML à +200 est parfaitement
    /// stable à +40 et à +120, et serait rangé en image. 300 ms couvre la
    /// fenêtre mesurée entière, plus 100 ms de marge. Ce n'est pas un chiffre
    /// inventé, et ce n'est pas une latence que quiconque perçoit : personne ne
    /// regarde son historique se remplir.
    ///
    /// Les relevés de +40 et +120 restent utiles — ils détectent le mouvement et
    /// alimentent le prédicat de stabilité —, c'est seulement la sortie vers la
    /// capture qui est verrouillée.
    public static let captureFloor: Duration = .milliseconds(300)

    /// Budget dur de la cadence rapide, depuis l'indice.
    public static let budget: Duration = .milliseconds(500)

    /// Cadence de repli quand le compteur a bougé mais que rien n'est encore
    /// lisible. 250 ms : assez lent pour ne pas sonder pour rien, assez rapide
    /// pour que l'entrée apparaisse pendant que l'utilisateur regarde encore.
    public static let slowWriterInterval: Duration = .milliseconds(250)

    /// Budget total, cadence lente comprise, depuis l'indice. Au-delà, ce n'est
    /// plus un écrivain lent, c'est un presse-papiers qu'on ne sait pas lire.
    public static let slowWriterBudget: Duration = .milliseconds(2_000)

    /// Combien de comptes causés par bran on retient. bran n'écrit que quand
    /// l'utilisateur recolle une entrée : une poignée, jamais une rafale.
    public static let ownWriteMemory = 8

    // MARK: - Vocabulaire

    public enum Phase: Equatable, Sendable {
        case idle
        /// Cadence rapide, dans les 500 premières millisecondes.
        case settling
        /// Le compteur a bougé, rien n'est encore lisible : on laisse le temps à
        /// un gros écrivain. Le seul état qui mérite d'être montré, et seulement
        /// s'il dure.
        case awaitingSlowWriter
        /// L'appelant lit le contenu. La machine n'y participe pas.
        case capturing

        public var isBusy: Bool { self != .idle }
    }

    public enum Event: Equatable, Sendable {
        /// Quelque chose laisse penser qu'une copie vient d'avoir lieu : un ⌘C
        /// observé, ou un sondage qui a vu le compteur bouger.
        ///
        /// `changeCount` est la valeur **d'avant** la copie. La lire est gratuit
        /// et l'appelant doit le faire au plus tôt — sur la frappe, avant que
        /// l'application ait pu réagir, ou depuis la dernière valeur connue de
        /// son sondeur. Une référence lue trop tard ferait conclure « rien n'a
        /// été copié » à une copie bien réelle.
        case hinted(changeCount: Int, at: Instant)

        /// L'appelant a relevé le compteur et la liste des types, sans toucher
        /// au contenu.
        case sampled(ClipboardSample, at: Instant)

        /// bran vient d'écrire sur le presse-papiers, et voici le compte que son
        /// écriture a produit.
        ///
        /// **La déduplication se fait sur le compteur, pas sur un marqueur.**
        /// Ajouter un type-témoin aux écritures de bran modifierait durablement
        /// le contenu restauré par l'utilisateur — il collerait ensuite ce
        /// marqueur partout. `clearContents()` et `prepareForNewContents(with:)`
        /// rendent tous les deux le nouveau compte ; il suffit de s'en souvenir.
        case selfWrote(changeCount: Int)

        /// Le contenu a été lu (ou sa lecture a échoué) : la machine peut
        /// reprendre la main.
        case captureFinished

        case cancelRequested
    }

    /// Ce que l'appelant doit faire.
    public enum Effect: Equatable, Sendable {
        /// Attendre, puis relever compteur et liste des types. L'attente est à
        /// la charge de l'appelant : la machine ne dort pas.
        case sample(after: Duration)
        /// Lire le contenu, une seule fois, exactement comme le plan le dit.
        case capture(ClipboardCapturePlan)
        /// Ne rien conserver, et pourquoi.
        case ignore(ClipboardSkip)
    }

    // MARK: - État

    public private(set) var phase: Phase = .idle

    /// Modifiable à chaud : le propriétaire peut décider d'archiver malgré les
    /// marqueurs de confidentialité, et le changement doit prendre effet sans
    /// reconstruire la machine.
    public var policy: ClipboardTypePolicy

    private var origin: Instant?
    private var baseline = 0
    private var previous: ClipboardSample?
    private var ownCounts: [Int] = []
    private var lastCapturedCount: Int?

    public init(policy: ClipboardTypePolicy = ClipboardTypePolicy()) {
        self.policy = policy
    }

    // MARK: - Transitions

    /// Applique un événement et retourne les effets à exécuter.
    ///
    /// Comme ses deux sœurs : un événement qui n'a pas de sens dans l'état
    /// courant ne produit rien et ne change rien, plutôt que de lever une
    /// erreur. Un ⌘C répété deux fois en 50 ms ne doit rien casser.
    @discardableResult
    public mutating func handle(_ event: Event) -> [Effect] {
        switch event {

        case .selfWrote(let count):
            remember(own: count)
            return []

        case .hinted(let count, let at):
            // Un second indice pendant une fenêtre en cours relance la cadence
            // — le geste est nouveau, la preuve de stabilité accumulée ne vaut
            // plus rien — mais garde la référence d'origine : c'est toujours par
            // rapport à l'état d'avant la première copie qu'on juge si quelque
            // chose a bougé.
            if phase != .settling, phase != .awaitingSlowWriter { baseline = count }
            origin = at
            previous = nil
            phase = .settling
            return [.sample(after: Self.sampleOffsets[0])]

        case .sampled(let sample, let at):
            return handle(sample: sample, at: at)

        case .captureFinished:
            if phase == .capturing { phase = .idle }
            return []

        case .cancelRequested:
            reset()
            return []
        }
    }

    private mutating func handle(sample: ClipboardSample, at now: Instant) -> [Effect] {
        guard phase == .settling || phase == .awaitingSlowWriter, let origin else { return [] }

        // — Les trois refus immédiats ————————————————————————————
        //
        // Inutile de continuer à sonder : aucun de ces trois cas ne peut se
        // transformer en quelque chose qu'on garderait.

        if ownCounts.contains(sample.changeCount) { return finish(.ownWrite) }

        // Un marqueur sur **un** élément rejette **toute** l'entrée : 1Password,
        // Bitwarden, KeePassXC et iTerm marquent ainsi leurs écritures, et macOS
        // lui-même les efface au bout d'environ 90 s. Apple n'offre aucune API
        // pour ça ; la convention est le seul signal qu'on ait.
        if policy.honoursPrivacyMarkers, sample.carriesPrivacyMarker { return finish(.markedPrivate) }

        if sample.changeCount == lastCapturedCount { return finish(.alreadyCaptured) }

        // — Stabilisation ————————————————————————————————————————
        let elapsed = origin.duration(to: now)
        let moved = sample.changeCount != baseline
        let plan = policy.plan(for: sample)
        let confirmed = previous.map(sample.matches) ?? false

        // Le plancher est la seule chose qui sépare « deux relevés d'affilée »
        // de « l'application a fini d'écrire ».
        if moved, confirmed, elapsed >= Self.captureFloor, let plan { return capture(plan) }

        previous = sample
        let deadline = phase == .settling ? Self.budget : Self.slowWriterBudget

        if elapsed < deadline, let delay = nextDelay(after: elapsed) {
            return [.sample(after: delay)]
        }

        // — Échéance : on tranche ————————————————————————————————

        // Le compteur n'a jamais bougé : ce n'était pas une copie.
        if !moved { return finish(.noCopy) }

        // Quelque chose de lisible, mais jamais confirmé — échantillon en
        // retard, écriture qui traîne. À l'échéance dure, capturer un
        // presse-papiers non confirmé vaut mieux que perdre la copie.
        if let plan { return capture(plan) }

        // Une promesse de fichier n'est pas un écrivain lent, c'est une réponse
        // définitive : elle rend un UTI, pas un contenu, et l'honorer voudrait
        // dire un aller-retour réseau. On la reconnaît pour pouvoir la refuser
        // en la nommant.
        if sample.carriesFilePromise { return finish(.filePromise) }

        if phase == .settling {
            phase = .awaitingSlowWriter
            if let delay = nextDelay(after: elapsed) { return [.sample(after: delay)] }
        }

        return finish(sample.isEmpty ? .neverSettled : .nothingUsable)
    }

    /// Le prochain rendez-vous, ou `nil` quand il n'y en a plus avant
    /// l'échéance. Les délais sont relatifs pour que l'appelant n'ait qu'à
    /// dormir : c'est ici que le budget est tenu **exactement**, jamais dépassé
    /// par accumulation de dérive.
    private func nextDelay(after elapsed: Duration) -> Duration? {
        if phase == .settling {
            guard let next = Self.sampleOffsets.first(where: { $0 > elapsed }) else { return nil }
            return next - elapsed
        }
        let remaining = Self.slowWriterBudget - elapsed
        guard remaining > .zero else { return nil }
        return min(Self.slowWriterInterval, remaining)
    }

    private mutating func capture(_ plan: ClipboardCapturePlan) -> [Effect] {
        reset()
        phase = .capturing
        lastCapturedCount = plan.changeCount
        return [.capture(plan)]
    }

    private mutating func finish(_ skip: ClipboardSkip) -> [Effect] {
        reset()
        return [.ignore(skip)]
    }

    private mutating func reset() {
        phase = .idle
        origin = nil
        previous = nil
    }

    private mutating func remember(own count: Int) {
        guard !ownCounts.contains(count) else { return }
        ownCounts.append(count)
        if ownCounts.count > Self.ownWriteMemory {
            ownCounts.removeFirst(ownCounts.count - Self.ownWriteMemory)
        }
    }
}

// MARK: - Ce qu'on relève

/// Un relevé du presse-papiers : son compteur, et les types annoncés par chacun
/// de ses éléments. **Aucun contenu.**
///
/// Les éléments sont gardés séparés parce que deux décisions en dépendent :
/// un marqueur de confidentialité posé sur un seul élément rejette l'entrée
/// entière, et une copie de trois fichiers depuis le Finder est trois éléments
/// portant chacun `public.file-url`.
public struct ClipboardSample: Equatable, Sendable {

    /// `NSPasteboard.changeCount` au moment du relevé.
    public let changeCount: Int

    /// Les identifiants de type annoncés, un tableau par élément.
    public let items: [[String]]

    public init(changeCount: Int, items: [[String]]) {
        self.changeCount = changeCount
        self.items = items
    }

    /// Un presse-papiers sans aucun type — l'état qu'une application publie
    /// entre son `clearContents()` et son premier `setData`.
    public var isEmpty: Bool { items.allSatisfy(\.isEmpty) }

    /// Forme canonique du relevé : l'ordre dans lequel une application déclare
    /// ses types n'est pas garanti stable d'un relevé à l'autre, et le prendre
    /// pour un changement ferait échantillonner jusqu'au budget à chaque copie.
    var signature: [[String]] { items.map { $0.sorted() } }

    /// Vrai quand deux relevés disent la même chose — la définition de
    /// « stabilisé ».
    func matches(_ other: ClipboardSample) -> Bool {
        changeCount == other.changeCount && signature == other.signature
    }

    public var carriesPrivacyMarker: Bool {
        items.contains { $0.contains(where: ClipboardTypePolicy.isPrivacyMarker) }
    }

    public var carriesFilePromise: Bool {
        items.contains { $0.contains(where: ClipboardTypePolicy.isFilePromise) }
    }
}

/// Ce que l'appelant doit lire, et sous quelle sorte le ranger. La machine
/// s'arrête ici : construire l'entrée est le travail de qui exécute le plan.
public struct ClipboardCapturePlan: Equatable, Sendable {

    public let kind: ClipboardKind

    /// Le compte auquel ce plan correspond. À revérifier juste avant de lire :
    /// s'il a encore bougé entre-temps, le contenu lu n'est plus celui-ci.
    public let changeCount: Int

    /// Le type qui porte le contenu de la sorte.
    public let primaryType: String

    /// Ce qu'on garde **en plus**, uniquement quand la sorte en a besoin : un
    /// `richText` garde sa forme en texte brut, parce que « coller sans mise en
    /// forme » est le geste le plus demandé après « coller », et son rendu
    /// matriciel quand la source en a posé un, parce que c'est ce qui permettra
    /// « coller comme image » sans rien recapturer. Rien d'autre n'est conservé
    /// — les 43 types distincts d'un historique réel ne sont pas de la fidélité,
    /// c'est du remplissage.
    public let companionTypes: [String]

    /// Combien d'éléments portent le type principal. Supérieur à 1 pour une
    /// copie de plusieurs fichiers, et à 1 partout ailleurs.
    public let itemCount: Int

    public init(
        kind: ClipboardKind,
        changeCount: Int,
        primaryType: String,
        companionTypes: [String],
        itemCount: Int
    ) {
        self.kind = kind
        self.changeCount = changeCount
        self.primaryType = primaryType
        self.companionTypes = companionTypes
        self.itemCount = itemCount
    }

    /// Tout ce qu'il y a à lire, le porteur du contenu d'abord.
    public var types: [String] { [primaryType] + companionTypes }

    /// Ce qu'une image « garde en plus » ne vient pas d'un autre type mais de
    /// ses octets : l'appelant relève ses dimensions pendant qu'il la tient.
    public var measuresDimensions: Bool { kind == .image }
}

/// Pourquoi rien n'a été conservé.
///
/// Cinq de ces sept cas sont parfaitement normaux et ne méritent pas une ligne
/// de journal — sans quoi un ⌘C dans un champ vide écrirait une alerte.
public enum ClipboardSkip: Equatable, Sendable {
    /// Le compteur n'a pas bougé : la frappe n'était pas une copie.
    case noCopy
    /// bran a causé ce compte lui-même, en recollant une entrée.
    case ownWrite
    /// Déjà rangé. Arrive quand le raccourci et le sondeur voient la même copie.
    case alreadyCaptured
    /// Un élément porte `org.nspasteboard.ConcealedType`, `TransientType` ou
    /// `AutoGeneratedType`.
    case markedPrivate
    /// Une promesse de fichier, reconnue et refusée.
    case filePromise
    /// Des types, mais aucun qu'on sache ranger.
    case nothingUsable
    /// Le compteur a bougé et le presse-papiers est resté vide jusqu'au bout.
    case neverSettled

    public var summary: String {
        switch self {
        case .noCopy: "Rien n'a été copié."
        case .ownWrite: "Écriture de bran, déjà connue."
        case .alreadyCaptured: "Cette copie est déjà dans l'historique."
        case .markedPrivate: "Copie marquée confidentielle par son application."
        case .filePromise: "Fichier promis, jamais téléchargé."
        case .nothingUsable: "Aucun format exploitable sur le presse-papiers."
        case .neverSettled: "Le presse-papiers est resté vide pendant 2 s."
        }
    }

    /// Vrai pour les deux seuls cas qui disent quelque chose sur bran plutôt que
    /// sur l'utilisateur.
    public var isNoteworthy: Bool {
        self == .nothingUsable || self == .neverSettled
    }
}

// MARK: - La matrice des types

/// Ce qu'on garde d'un presse-papiers, et ce qu'on jette.
///
/// Séparé de la machine pour être testable seul : c'est une table, et les tables
/// se relisent mieux qu'elles ne se déduisent.
public struct ClipboardTypePolicy: Sendable, Equatable {

    /// Rejeter les entrées marquées par la convention `org.nspasteboard.*`.
    ///
    /// **Paramètre, avec le rejet par défaut.** Apple n'offre aucune API pour
    /// savoir qu'une copie est un mot de passe ; la convention est le seul
    /// signal. Mais c'est une convention, pas une garantie, et le propriétaire
    /// de la machine peut vouloir la désactiver — auquel cas les marqueurs
    /// restent exclus du plan, seule la mise au rebut de l'entrée disparaît.
    public var honoursPrivacyMarkers: Bool

    public init(honoursPrivacyMarkers: Bool = true) {
        self.honoursPrivacyMarkers = honoursPrivacyMarkers
    }

    // MARK: Marqueurs

    /// La convention `org.nspasteboard.*`, respectée par 1Password, Bitwarden,
    /// KeePassXC et iTerm.
    public static let privacyMarkers: Set<String> = [
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.TransientType",
        "org.nspasteboard.AutoGeneratedType",
    ]

    public static func isPrivacyMarker(_ identifier: String) -> Bool {
        privacyMarkers.contains(identifier)
    }

    /// Les promesses de fichier. **Jamais honorées sur ce chemin** : elles
    /// rendent une chaîne d'UTI, pas un contenu, et les honorer signifierait un
    /// aller-retour réseau déclenché par un ⌘C.
    public static let filePromiseTypes: Set<String> = [
        "com.apple.pasteboard.promised-file-content-type",
        "com.apple.pasteboard.promised-file-url",
        "com.apple.pasteboard.promised-suggested-file-name",
        "com.apple.NSFilePromiseItemMetaData",
    ]

    public static func isFilePromise(_ identifier: String) -> Bool {
        filePromiseTypes.contains(identifier)
    }

    // MARK: Rebut

    /// Les identifiants privés ou éphémères, listés un par un.
    public static let discardedIdentifiers: Set<String> = [
        // L'application source, posée par la même convention que les marqueurs :
        // utile à qui écrit, sans valeur une fois rangée.
        "org.nspasteboard.source",
        // Blob interne de WebKit, illisible hors du processus qui l'a écrit.
        "com.apple.WebKit.custom-pasteboard-data",
        "com.apple.webarchive",
        // Office : de quoi retrouver l'objet OLE d'origine, rien de plus.
        "com.microsoft.DataObjectDescriptor",
        "com.microsoft.appbundleid",
        "com.microsoft.Art--GVML-ClipFormat",
        // Le nœud Finder pointe une position dans une fenêtre, pas un fichier.
        "com.apple.finder.node",
    ]

    /// Les familles entières mises au rebut.
    ///
    /// `org.chromium.` est la plus rentable : `org.chromium.internal.source-rfh-token`
    /// pesait 5 515 lignes dans un historique réel de 250 entrées, et n'a plus
    /// aucun sens dès que l'onglet source est fermé. `org.chromium.source-url`
    /// et ses voisins ne valent pas mieux.
    ///
    /// `dyn.` est la famille des UTI dynamiques : un type qu'une application
    /// s'est inventé et que personne d'autre ne sait relire.
    public static let discardedPrefixes: [String] = [
        "org.chromium.",
        "com.apple.pasteboard.",
        "com.apple.NSFilePromise",
        "com.microsoft.ole.",
        "dyn.",
    ]

    /// Vrai pour un identifiant qu'on ne conserve jamais, promesses exclues :
    /// celles-ci restent visibles pour pouvoir être refusées en les nommant.
    public static func isDiscarded(_ identifier: String) -> Bool {
        if isFilePromise(identifier) { return false }
        if isPrivacyMarker(identifier) { return true }
        if discardedIdentifiers.contains(identifier) { return true }
        return discardedPrefixes.contains { identifier.hasPrefix($0) }
    }

    // MARK: Les quatre tiers

    /// Le contenu n'est pas repris : le presse-papiers porte une URL.
    public static let fileTypes = ["public.file-url", "NSFilenamesPboardType"]

    /// Que des formats matriciels. **`com.adobe.pdf` n'est pas ici** : c'est une
    /// représentation qu'Excel, Numbers et Aperçu posent *en plus* du reste, et
    /// la retenir comme déclencheur ferait d'une plage de tableur une image
    /// avant même de regarder son HTML. Les mêmes applications posent aussi un
    /// TIFF, donc le cas « PDF seul » ne se rencontre pas en pratique.
    ///
    /// Le TIFF, lui, est bien un déclencheur — mais pas quand le même élément
    /// porte aussi sa propre source éditable ; voir `plan(for:)`.
    public static let imageTypes = [
        "public.png", "public.tiff", "public.jpeg", "public.heic", "public.heif",
        "com.compuserve.gif", "com.microsoft.bmp",
    ]

    /// RTF avant HTML : recoller du HTML dans un champ riche donne un résultat
    /// différent dans chaque application, là où le RTF se comporte partout de la
    /// même façon.
    public static let richTextTypes = [
        "public.rtf", "com.apple.flat-rtfd", "public.rtfd", "public.html",
    ]

    public static let textTypes = [
        "public.utf8-plain-text", "public.utf16-external-plain-text",
        "public.plain-text", "NSStringPboardType",
    ]

    /// Les identifiants d'une sorte, par ordre de préférence.
    public static func identifiers(for kind: ClipboardKind) -> [String] {
        switch kind {
        case .file: fileTypes
        case .image: imageTypes
        case .richText: richTextTypes
        case .text: textTypes
        }
    }

    // MARK: La décision

    /// Ce qu'il y a à lire sur ce relevé, ou `nil` s'il n'y a rien qu'on sache
    /// ranger.
    ///
    /// **L'ordre des cas de `ClipboardKind` est l'ordre de priorité** — fichier,
    /// image, texte enrichi, texte — et les formes coexistent presque toujours :
    /// copier un fichier depuis le Finder pose aussi son nom en texte, copier du
    /// web pose du HTML *et* du texte brut. La première sorte dont une forme est
    /// présente décide ; les autres ne sont gardées que si elles ajoutent
    /// quelque chose dont cette sorte a besoin.
    ///
    /// **Avec une exception, et une seule : la forme éditable l'emporte sur son
    /// propre rendu.** Quand un même élément porte à la fois une forme matricielle
    /// et du RTF ou du HTML, le bitmap n'est pas le contenu, c'est une image de
    /// ce texte : une plage Excel collée dans Notes doit donner un tableau, pas
    /// une capture de tableau. Le bitmap est alors conservé en forme compagne,
    /// pour qu'un futur « coller comme image » n'ait rien à recapturer.
    ///
    /// La règle se juge **au sein d'un même élément**, jamais entre éléments : un
    /// élément est un objet, et deux objets sur le même presse-papiers ne sont
    /// pas deux vues de la même chose. Une capture d'Aperçu, une diapo Keynote en
    /// PDF + TIFF, une image de Figma ne portent aucune forme enrichie et restent
    /// donc des images.
    public func plan(for sample: ClipboardSample) -> ClipboardCapturePlan? {
        let kept = sample.items.map { item in
            item.filter { !Self.isDiscarded($0) && !Self.isFilePromise($0) }
        }
        let rendersRichText = kept.map { item in
            Self.richTextTypes.contains { item.contains($0) }
        }

        for kind in ClipboardKind.allCases {
            // Un élément qui porte sa propre source éditable ne compte pas comme
            // une image ; il compte encore pour toutes les autres sortes.
            let eligible = kind == .image
                ? kept.indices.filter { !rendersRichText[$0] }
                : Array(kept.indices)

            let table = Self.identifiers(for: kind)
            guard let primary = table.first(where: { id in eligible.contains { kept[$0].contains(id) } }),
                  let deciding = eligible.first(where: { kept[$0].contains(primary) })
            else { continue }

            return ClipboardCapturePlan(
                kind: kind,
                changeCount: sample.changeCount,
                primaryType: primary,
                companionTypes: Self.companions(for: kind, in: kept[deciding]),
                itemCount: eligible.filter { kept[$0].contains(primary) }.count
            )
        }
        return nil
    }

    /// Les compagnons se prennent sur l'élément qui a décidé, pas sur le
    /// presse-papiers entier : un compagnon est une autre vue du **même** objet.
    private static func companions(for kind: ClipboardKind, in item: [String]) -> [String] {
        guard kind == .richText else { return [] }
        var companions: [String] = []
        if let plain = textTypes.first(where: { item.contains($0) }) { companions.append(plain) }
        if let rendering = imageTypes.first(where: { item.contains($0) }) {
            companions.append(rendering)
        }
        return companions
    }
}
