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
        guard claim.claim() else { return nil }

        let pasteboard = NSPasteboard.general
        let held = expected != nil && pasteboard.changeCount == expected

        let written = pasteboard.prepareForNewContents(with: .currentHostOnly)
        pasteboard.setString(text, forType: .string)

        announce(written)
        return WriteOutcome(changeCount: written, expectationHeld: held)
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

        pasteboard.writeObjects(items.map { item in
            let restored = NSPasteboardItem()
            for representation in item.representations {
                restored.setData(
                    representation.data,
                    forType: NSPasteboard.PasteboardType(representation.type)
                )
            }
            return restored
        })
        return true
    }
}
