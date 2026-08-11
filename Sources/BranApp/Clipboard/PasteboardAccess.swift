import AppKit
import BranCore
import BranSpeech
import Foundation

// L'unique accès de bran à `NSPasteboard.general`.
//
// **Ce fichier était la fin de `Paster.swift`, et il en est sorti le jour où il
// a eu un second client.** La dictée et la capture de texte s'en servent pour
// emprunter le presse-papiers le temps d'un ⌘V ; l'historique s'en sert pour le
// relever et le lire. Rien n'a changé dans les gestes de la dictée — le
// déplacement est littéral, seule la visibilité s'ouvre —, mais laisser cette
// pièce enfermée dans le fichier du collage aurait mis le presse-papiers de
// l'historique devant un mauvais choix : appeler `NSPasteboard.general`
// directement, et faire de la promesse « un seul endroit y touche » une phrase
// fausse, ou recopier l'acteur, ce qui ne sérialise plus rien du tout.
//
// **Les renvois « point N » sont ceux de `Paster.swift`**, dont la liste en tête
// de fichier reste l'exposé complet de ce qu'un presse-papiers emprunté coûte.
// Ils n'ont pas été réécrits : ces neuf points ont été payés en défauts réels,
// et les paraphraser au moment de déménager le code serait le meilleur moyen
// d'en perdre un.

/// Une représentation du presse-papiers, réduite à des valeurs pures.
///
/// Pures, parce qu'un `NSPasteboardItem` est un mandataire vivant sur
/// `pasteboardd` : il n'est pas `Sendable`, et le faire traverser une frontière
/// d'isolation rejouerait le XPC du point 6 précisément là où on croyait s'en
/// être débarrassé.
struct SavedRepresentation: Sendable {
    let type: String
    let data: Data
}

/// Un élément du presse-papiers, **dans l'ordre** où l'application source a
/// déclaré ses représentations (point 7).
struct SavedItem: Sendable {
    let representations: [SavedRepresentation]
}

/// Ce qu'une lecture rapporte quand elle rapporte quelque chose.
///
/// `items` vide **est un résultat** : le presse-papiers était vide, et on saura
/// le rendre vide. Une lecture qui n'a rien de fiable à dire ne rend pas un
/// instantané vide, elle ne rend rien du tout (point 2).
struct ClipboardSnapshot: Sendable {
    let changeCount: Int
    let items: [SavedItem]
}

/// L'unique accès au presse-papiers, partagé par **toutes** les instances de
/// `Paster`.
///
/// Global et non stocké dans `Paster` : il en existe deux, une pour la dictée et
/// une pour la capture de texte, et un exécuteur par instance ne sérialiserait
/// rien du tout. C'est un `let` immuable d'un type `Sendable`, donc lisible
/// depuis n'importe quelle isolation sans annotation d'échappement.
let pasteboardAccess = PasteboardAccess()

/// Le seul endroit du programme qui touche `NSPasteboard.general` (point 8).
actor PasteboardAccess {

    /// L'exécuteur est une file série dédiée, pas le pool coopératif : la
    /// lecture peut rester bloquée des secondes dans un XPC synchrone, et un fil
    /// du pool bloqué est un fil de moins pour tout le programme.
    private let queue = DispatchSerialQueue(
        label: "com.opahventures.bran.pasteboard",
        qos: .userInitiated
    )

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    /// Lit le presse-papiers et n'en rapporte que des valeurs.
    ///
    /// Le numéro de version encadre la lecture : s'il a bougé pendant qu'on
    /// lisait, ce qu'on tient est un mélange de deux contenus et on préfère ne
    /// rien rapporter du tout plutôt que rendre un assemblage qui n'a jamais
    /// existé.
    ///
    /// - Returns: `nil` quand il n'y a rien de fiable à rapporter — lecture
    ///   annulée, contenu changé sous nos pieds, ou des éléments présents dont
    ///   pas un seul octet n'a pu être lu. Ce dernier cas mérite son `nil` : un
    ///   instantané vide serait rendu *comme* un presse-papiers vide, et on
    ///   effacerait au nom de la restitution un contenu qu'on a seulement échoué
    ///   à lire (point 2).
    func read() -> ClipboardSnapshot? {
        if Task.isCancelled { return nil }

        let pasteboard = NSPasteboard.general
        let before = pasteboard.changeCount
        let sources = pasteboard.pasteboardItems ?? []

        var items: [SavedItem] = []
        for source in sources {
            var representations: [SavedRepresentation] = []
            for type in source.types {
                // L'annulation se vérifie ici, entre deux représentations, et
                // pas seulement entre deux éléments : `data(forType:)` est le
                // seul appel long, et c'est la boucle intérieure qui le répète.
                if Task.isCancelled { return nil }
                guard let data = source.data(forType: type) else { continue }
                representations.append(
                    SavedRepresentation(type: type.rawValue, data: data)
                )
            }
            guard representations.isEmpty == false else { continue }
            items.append(SavedItem(representations: representations))
        }

        if Task.isCancelled { return nil }
        guard items.isEmpty == false || sources.isEmpty else { return nil }
        guard pasteboard.changeCount == before else { return nil }
        return ClipboardSnapshot(changeCount: before, items: items)
    }

    // MARK: - Ce que l'historique demande

    /// Le numéro de version, et rien d'autre.
    ///
    /// **La lecture la moins chère du presse-papiers, et la seule qui ne
    /// réveille personne.** Elle ne touche aucun élément, donc n'appelle aucun
    /// fournisseur paresseux et ne déclenche pas l'alerte d'accès de macOS 15.4.
    /// C'est ce qui rend le filet lent défendable : sonder toutes les deux
    /// secondes coûte un entier.
    func changeCount() -> Int {
        NSPasteboard.general.changeCount
    }

    /// Le numéro de version et la **liste des types** de chaque élément, sans un
    /// octet de contenu.
    ///
    /// C'est l'unité de mesure de `ClipboardMachine` : elle échantillonne à +40,
    /// +120, +300 puis +500 ms et compare deux relevés pour savoir si
    /// l'application source a fini d'écrire. Lire les types est gratuit ; lire
    /// le contenu ne l'est pas, et se fait une fois, sur son instruction.
    ///
    /// **Les éléments restent séparés.** Un marqueur de confidentialité posé sur
    /// un seul élément rejette l'entrée entière, et une copie de trois fichiers
    /// depuis le Finder est trois éléments portant chacun `public.file-url` :
    /// fondre les types en un seul ensemble perdrait les deux décisions.
    func sample() -> ClipboardSample {
        let pasteboard = NSPasteboard.general
        let count = pasteboard.changeCount
        let items = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.map(\.rawValue)
        }
        return ClipboardSample(changeCount: count, items: items)
    }

    /// Lit **exactement** ce que le plan demande, et rien de plus.
    ///
    /// Le numéro de version encadre la lecture, comme dans `read()` : s'il a
    /// bougé pendant qu'on lisait, ce qu'on tient est un mélange de deux
    /// contenus, et on préfère ne rien rapporter qu'un assemblage qui n'a jamais
    /// existé. L'appelant sait alors que c'est « trop tard » et non
    /// « illisible » — deux verdicts que `ClipboardCapture` refuse justement de
    /// confondre.
    ///
    /// **Seuls les types du plan sont demandés.** Un historique qui aspirerait
    /// tout garderait les 43 identifiants distincts mesurés sur 250 entrées
    /// réelles, dont le jeton interne de Chromium qui ne veut plus rien dire dès
    /// l'onglet fermé. Le plan est la liste courte, et c'est `ClipboardTypePolicy`
    /// qui l'a établie.
    ///
    /// Une représentation absente est sautée sans faute : le plan est bâti sur
    /// les types **annoncés**, et un fournisseur peut très bien annoncer un type
    /// puis ne rien rendre. `ClipboardCapture` sait construire une entrée
    /// diminuée ; il n'y a pas de raison de perdre la copie pour autant.
    func capture(_ plan: ClipboardCapturePlan) -> ClipboardReading? {
        if Task.isCancelled { return nil }

        let pasteboard = NSPasteboard.general
        let before = pasteboard.changeCount
        let wanted = Set(plan.types)

        var items: [[String: Data]] = []
        for source in pasteboard.pasteboardItems ?? [] {
            var representations: [String: Data] = [:]
            for type in source.types where wanted.contains(type.rawValue) {
                // L'annulation se vérifie entre deux représentations, comme dans
                // `read()` : `data(forType:)` est le seul appel long, et c'est
                // la boucle intérieure qui le répète.
                if Task.isCancelled { return nil }
                guard let data = source.data(forType: type) else { continue }
                representations[type.rawValue] = data
            }
            items.append(representations)
        }

        if Task.isCancelled { return nil }
        guard pasteboard.changeCount == before else { return nil }
        return ClipboardReading(changeCount: before, items: items)
    }

    // MARK: - Annoncer nos propres écritures

    /// Qui prévenir quand bran écrit sur le presse-papiers, et quel numéro de
    /// version son écriture vient de produire.
    private var onWrite: (@Sendable (Int) -> Void)?

    /// **Le raccord est ici, et nulle part ailleurs, pour la même raison que le
    /// reste de cet acteur.** L'historique doit reconnaître les écritures de bran
    /// pour ne pas les ranger comme des copies de l'utilisateur — sans quoi
    /// chaque dictée, chaque capture de texte et chaque recollage depuis le
    /// panneau apparaîtraient en double dans la liste. La question n'est donc pas
    /// « quel contrôleur pense à le dire », mais « d'où bran écrit-il ». La
    /// réponse est : d'ici, toujours. Poser le raccord sur `Paster` aurait
    /// demandé de le répéter sur chaque instance — il y en a deux — et un
    /// troisième écrivain futur l'aurait oublié en silence.
    ///
    /// **La déduplication se fait sur le compteur, jamais sur un marqueur.**
    /// Ajouter un type-témoin à nos écritures modifierait durablement ce que
    /// l'utilisateur recolle ensuite : il collerait ce marqueur partout.
    /// `prepareForNewContents` rend le nouveau numéro ; il suffit de le dire.
    ///
    /// Le gestionnaire est `@Sendable` et appelé depuis la file de l'acteur :
    /// c'est à lui de sauter vers l'isolation qu'il lui faut, sans jamais faire
    /// attendre cette file.
    func reportWrites(to handler: @escaping @Sendable (Int) -> Void) {
        onWrite = handler
    }

    private func announce(_ changeCount: Int) {
        onWrite?(changeCount)
    }

    /// Ce qu'une écriture apprend en passant.
    struct WriteOutcome: Sendable {
        /// Le numéro de version que notre écriture vient de rendre.
        let changeCount: Int
        /// Le presse-papiers portait-il encore, juste avant, le numéro de
        /// version attendu ? `false` veut dire qu'on vient d'écraser quelque
        /// chose de plus récent que ce qu'on avait sauvegardé (point 4).
        let expectationHeld: Bool
    }

    /// Le cœur commun à **toutes** les écritures de bran : la prise du jeton, la
    /// vérification du numéro de version, l'ouverture du presse-papiers et
    /// l'annonce. Seul ce qu'on y dépose change d'un appelant à l'autre.
    ///
    /// **Il est privé et il n'a qu'un paramètre variable, parce que ces quatre
    /// gestes-là n'ont pas le droit d'être écrits deux fois.** Le jour où
    /// l'historique a eu besoin d'écrire autre chose qu'une chaîne, la solution
    /// évidente était une seconde méthode complète à côté de la première ; elle
    /// aurait recopié, dans l'ordre, quatre décisions dont chacune a coûté un
    /// défaut réel — le jeton pris sur la file et non chez l'appelant (point 9),
    /// la comparaison du numéro de version dans le même passage que l'écriture
    /// qu'elle autorise (points 3 et 8), `prepareForNewContents(with:)` plutôt
    /// que `clearContents()` (point 5), et l'annonce à l'historique sans laquelle
    /// bran range ses propres écritures comme des copies de l'utilisateur. Une
    /// copie de cette séquence n'aurait pas eu à se tromper pour être dangereuse :
    /// il lui aurait suffi de ne pas suivre la correction suivante.
    ///
    /// `contents` est appelée **après** `prepareForNewContents` et sur la file de
    /// l'acteur, donc au seul endroit du programme d'où l'on a le droit de
    /// toucher `NSPasteboard.general` (point 8). Elle n'échappe pas : rien n'en
    /// garde une référence, et elle ne peut donc pas écrire plus tard, quand le
    /// presse-papiers appartiendra à quelqu'un d'autre.
    private func write(
        expecting expected: Int?,
        claiming claim: PasteDeadline,
        contents: (NSPasteboard) -> Void
    ) -> WriteOutcome? {
        guard claim.claim() else { return nil }

        let pasteboard = NSPasteboard.general
        let held = expected != nil && pasteboard.changeCount == expected

        let written = pasteboard.prepareForNewContents(with: .currentHostOnly)
        contents(pasteboard)

        announce(written)
        return WriteOutcome(changeCount: written, expectationHeld: held)
    }

    /// Écrit le texte, après avoir constaté sur place si le presse-papiers
    /// portait encore le numéro de version attendu.
    ///
    /// Les deux dans le même appel parce qu'ils doivent être indissociables :
    /// vérifier chez l'appelant puis écrire ici laisserait entre les deux un
    /// intervalle que nos propres accès peuvent traverser (points 3 et 8).
    ///
    /// `prepareForNewContents(with:)` et non `clearContents()` : celui-ci perd
    /// l'option et laisse le presse-papiers universel diffuser la dictée sur les
    /// autres appareils du compte iCloud (point 5). Sa valeur de retour est le
    /// nouveau numéro de version, dont dépend la restitution.
    ///
    /// Ces trois gestes — le jeton, la comparaison, l'ouverture — ont déménagé
    /// dans `write(expecting:claiming:contents:)` le jour où l'historique a eu
    /// besoin d'écrire des représentations plutôt qu'une chaîne. **Ils sont
    /// inchangés, et ils sont désormais les mêmes objets, pas les mêmes mots** :
    /// c'est tout l'intérêt du déménagement. Ce qui reste ici est la seule chose
    /// qui distinguait cette écriture-là : `setString`.
    ///
    /// - Parameter claim: le jeton du point 9. **La prise se fait ici, sur la
    ///   file, juste avant de toucher le presse-papiers** — exactement comme la
    ///   vérification de `expected`, et pour la même raison : décider et agir
    ///   doivent être un seul geste. La prendre chez l'appelant laisserait entre
    ///   le « j'ai le droit » et le « j'écris » un intervalle que le minuteur
    ///   peut traverser, et le presse-papiers gagnerait un texte dont on vient
    ///   d'annoncer qu'il n'arriverait pas.
    /// - Returns: `nil` quand le minuteur a renoncé le premier. **Rien n'a été
    ///   écrit et rien ne le sera** : c'est la décision du point 9, pas un
    ///   report. Le presse-papiers de l'utilisateur reste tel qu'il l'a laissé.
    @discardableResult
    func write(
        _ text: String,
        expecting expected: Int?,
        claiming claim: PasteDeadline
    ) -> WriteOutcome? {
        write(expecting: expected, claiming: claim) { pasteboard in
            pasteboard.setString(text, forType: .string)
        }
    }

    /// Écrit **plusieurs représentations** — une image, des fichiers, un texte
    /// enrichi avec sa mise en forme —, aux mêmes conditions exactement que
    /// l'écriture d'une chaîne.
    ///
    /// Le frère de `write(_:expecting:claiming:)`, et pas son cousin : les deux
    /// passent par le même cœur privé, donc par le même jeton, la même
    /// comparaison de numéro de version, le même `prepareForNewContents(with:)`
    /// et la même annonce à l'historique. Tout ce que celui-ci ajoute est
    /// `writeObjects`, c'est-à-dire très précisément ce que `restore` faisait
    /// déjà et qu'il fait maintenant avec le même constructeur d'éléments.
    ///
    /// **L'annonce n'est pas un détail de cette méthode, c'est sa condition
    /// d'existence.** Son appelant est le panneau d'historique : sans l'annonce,
    /// chaque recollage depuis le panneau serait vu par le guet comme une copie
    /// de l'utilisateur et rangé une seconde fois dans la liste dont il vient de
    /// sortir. Un doublon par recollage, produit par l'historique lui-même — le
    /// genre de défaut circulaire qu'on met une soirée à comprendre.
    ///
    /// **L'ordre des représentations est celui du tableau** (point 7) :
    /// l'application qui colle prend le premier type qu'elle comprend, donc
    /// l'appelant qui veut être collé en RTF plutôt qu'en texte brut doit
    /// déclarer le RTF en premier. Ce n'est pas à cette méthode d'en décider,
    /// mais c'est à elle de ne pas le perdre.
    ///
    /// - Parameter items: un élément par objet copié — trois fichiers glissés
    ///   depuis le Finder sont trois éléments, un texte enrichi est un seul
    ///   élément à deux représentations.
    ///
    ///   **Un tableau vide ne s'écrit pas.** Il vaut `[]` pour `restore`, où il
    ///   veut dire « rends le presse-papiers vide » et où c'est la bonne réponse
    ///   (point 2) ; ici il ne peut vouloir dire que « colle rien », ce qui
    ///   effacerait le presse-papiers de l'utilisateur juste avant de lui envoyer
    ///   un ⌘V sans objet. Le refus est donc **avant la prise du jeton** : ne pas
    ///   le prendre laisse le minuteur du point 9 répondre à l'appelant, qui
    ///   n'attend donc jamais pour rien. Le message qu'il rendra parlera d'un
    ///   presse-papiers qui n'a pas répondu, ce qui n'est pas la raison exacte —
    ///   la vraie est dans le journal ci-dessous. On a préféré ce petit mensonge
    ///   à une quatrième issue dans `Paster.Landing`, qui aurait fait porter à
    ///   tous les appelants, dictée comprise, un cas qu'aucun d'eux ne peut
    ///   produire.
    ///
    ///   **Le vide se décide en amont, et il s'y décide déjà.** Une entrée qui
    ///   n'a plus rien à donner — refusée à l'écriture, blobs purgés — se
    ///   reconnaît par `ClipboardEntry.canPaste`, et `ClipboardPastePlan.items`
    ///   rend `[]` pour elle. C'est là que le panneau doit s'arrêter, avec un
    ///   bouton grisé et sa raison, plutôt qu'ici avec un message approximatif.
    ///   Ce refus-ci est le filet, pas la règle.
    /// - Returns: `nil` quand le minuteur a renoncé le premier, ou quand il n'y
    ///   avait rien à écrire. Dans les deux cas le presse-papiers de
    ///   l'utilisateur reste tel qu'il l'a laissé.
    @discardableResult
    func write(
        _ items: [SavedItem],
        expecting expected: Int?,
        claiming claim: PasteDeadline
    ) -> WriteOutcome? {
        guard items.isEmpty == false else {
            FeatureLog.record(
                "presse-papiers : écriture sans aucune représentation refusée —"
                + " le presse-papiers n'est pas vidé, le minuteur répondra"
            )
            return nil
        }

        // **La valeur de retour de `writeObjects` n'est pas décorative.** AppKit
        // rend `false` quand il refuse l'écriture, et l'ignorer laissait passer
        // le pire enchaînement de tout ce chemin : `prepareForNewContents` a
        // déjà vidé le presse-papiers, l'appelant reçoit un `WriteOutcome` qu'il
        // croit bon, il envoie son ⌘V — et l'utilisateur colle **le vide**,
        // c'est-à-dire perd à la fois ce qu'il voulait coller et ce qu'il avait
        // avant. Avec `restoresClipboard = false`, rien ne le rattrape.
        //
        // On rend donc `nil`, exactement comme pour un tableau vide : le
        // minuteur du point 9 répondra, l'appelant saura que rien n'a abouti, et
        // aucun ⌘V ne partira.
        var accepted = true
        let outcome = write(expecting: expected, claiming: claim) { pasteboard in
            accepted = pasteboard.writeObjects(Self.objects(for: items))
        }
        guard accepted else {
            FeatureLog.record(
                "presse-papiers : macOS a refusé l'écriture des représentations —"
                + " rien ne sera collé, et le presse-papiers reste vide"
            )
            return nil
        }
        return outcome
    }

    /// Reconstruit des `NSPasteboardItem` à partir de valeurs pures.
    ///
    /// Un seul constructeur pour la restitution et pour l'écriture de
    /// l'historique, parce que les deux ont la même chose à ne pas perdre :
    /// **l'ordre des représentations** (point 7). Deux boucles écrites
    /// séparément auraient très bien pu diverger sur ce point sans que rien ne
    /// le signale — la même copie enrichie ressortant en RTF d'un côté et en
    /// texte brut de l'autre est exactement le défaut qui a produit le point 7.
    ///
    /// `NSPasteboardItem` n'est pas `Sendable` (voir `SavedRepresentation`) :
    /// les objets naissent ici, sur la file de l'acteur, et sont consommés dans
    /// le même passage. Aucun ne traverse de frontière d'isolation.
    private static func objects(for items: [SavedItem]) -> [NSPasteboardItem] {
        items.map { item in
            let object = NSPasteboardItem()
            for representation in item.representations {
                object.setData(
                    representation.data,
                    forType: NSPasteboard.PasteboardType(representation.type)
                )
            }
            return object
        }
    }

    /// Rend le contenu sauvegardé, si le presse-papiers porte toujours le numéro
    /// de version de notre propre écriture (point 3).
    ///
    /// - Parameter items: `[]` demande de rendre un presse-papiers **vide**, ce
    ///   qui est la bonne réponse quand on l'avait trouvé vide (point 2).
    /// - Returns: `false` quand le presse-papiers ne nous appartenait plus et
    ///   qu'on n'y a donc pas touché.
    @discardableResult
    func restore(_ items: [SavedItem], ifChangeCountIs expected: Int) -> Bool {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount == expected else { return false }

        // La restitution compte elle aussi : elle republie le contenu que
        // l'utilisateur avait avant la dictée, donc elle produit un nouveau
        // numéro de version. Sans l'annoncer, l'historique verrait un
        // presse-papiers changer et rangerait une seconde fois ce qu'il avait
        // déjà — un doublon par dictée, avec la date de la restitution.
        announce(pasteboard.prepareForNewContents(with: .currentHostOnly))
        guard items.isEmpty == false else { return true }

        // Le même constructeur d'éléments que l'écriture de représentations, et
        // pas une seconde boucle qui lui ressemble : voir `objects(for:)` pour
        // ce que deux boucles jumelles auraient fini par perdre.
        pasteboard.writeObjects(Self.objects(for: items))
        return true
    }
}
