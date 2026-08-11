import AppKit
import BranCore
import BranSpeech
import Foundation
import Observation
import os

private let clipboardLog = Logger(subsystem: "com.opahventures.bran", category: "clipboard")

/// L'orchestrateur de l'historique du presse-papiers.
///
/// Il ne décide rien : `ClipboardMachine` décide, lui exécute. Même découpage
/// que la dictée et la capture de texte, et pour la même raison — la machine se
/// teste en une milliseconde, l'orchestrateur ne se teste pas du tout parce
/// qu'il touche au presse-papiers, à l'horloge et au disque.
///
/// ```
///   ⌘C observé ─────────┐
///                       ├──► ClipboardMachine ──► sample ──► PasteboardAccess
///   sondage périodique ─┤            ▲               │         (types seuls)
///                       │            └───────────────┘
///   écriture de bran ───┘                    │ capture
///                                            ▼
///                     ClipboardCapture ──► ClipboardStore
/// ```
///
/// ## Les trois voies, et pourquoi il en faut trois
///
/// **La frappe** est la plus rapide et la seule qui donne une référence
/// antérieure à la copie. Elle ne suffit pas : copier par le menu Édition, par
/// le menu contextuel ou par un glisser ne produit aucune frappe.
///
/// **Le sondage** rattrape tout ce que la frappe ne voit pas, et c'est aussi lui
/// qui tient à jour la valeur publiée au guet — voir
/// `HotkeyMonitor.observeCopies(changeCount:)`. Il est lent exprès : lire
/// `changeCount` ne coûte qu'un entier, mais un sondage rapide transformerait une
/// fonction passive en consommation permanente, et rien ne presse — personne ne
/// regarde son historique se remplir.
///
/// **L'appel direct** est la seule des trois qui soit exacte. Quand bran écrit
/// lui-même sur le presse-papiers — la dictée, la capture de texte, un recollage
/// depuis le panneau — il connaît le compte que son écriture vient de produire,
/// et le dit. La déduplication se fait là-dessus et non sur un marqueur de type :
/// ajouter un type-témoin aux écritures de bran modifierait durablement ce que
/// l'utilisateur recolle ensuite, il collerait ce marqueur partout.
///
/// ## Ce qui n'est pas ici
///
/// La fenêtre elle-même, la cible du collage et la fermeture : tout cela vit
/// dans `ClipboardPanelPresenter`, que ce contrôleur possède sans le connaître
/// autrement que par `toggle()`. La séparation n'est pas de la symétrie : la
/// capture et l'affichage n'ont aucune dépendance l'un envers l'autre —
/// l'historique se remplit correctement bien avant qu'il y ait de quoi le
/// regarder, et c'est dans cet ordre qu'il a été vérifié.
@MainActor
@Observable
final class ClipboardController {

    let store: ClipboardStore

    /// Où en est la capture. Lu par l'interface le jour où elle voudra montrer
    /// l'attente d'un écrivain lent — le seul des états qui mérite d'être
    /// affiché, et seulement s'il dure.
    private(set) var phase: ClipboardMachine.Phase = .idle

    /// Ce que la dernière capture a refusé de garder, quand ça dit quelque chose
    /// sur bran plutôt que sur l'utilisateur. `nil` le reste du temps : un ⌘C
    /// dans un champ vide n'est pas un incident.
    private(set) var lastSkip: ClipboardSkip?

    // MARK: - Machinerie

    private var machine = ClipboardMachine()
    private weak var monitor: HotkeyMonitor?

    /// Les vignettes des images de l'historique.
    ///
    /// **Tenu ici parce que sans lui le critère des 50 ms est faux.** Décoder
    /// 250 images pleines pour dessiner une liste détruit le budget d'ouverture
    /// *et* la mémoire — mesuré sur un historique réel, 183 lignes de PNG
    /// pesaient 158 Mo. Le cache est construit avec le magasin parce qu'il en
    /// dérive le chemin des contenus lourds, et balayé au lancement à côté de la
    /// purge : c'est le seul moment où un travail de ménage ne fait attendre
    /// personne.
    let thumbnails: ThumbnailCache

    /// La liaison du raccourci d'ouverture, tenue ici parce que rien ne
    /// l'inscrit tout seul.
    ///
    /// **`apply` réarme, il n'enregistre pas.** `HotkeyMonitor.bindings` n'est
    /// alimenté par aucun mécanisme automatique : chaque fonction y pose la
    /// sienne depuis son propre contrôleur, à la main. Une fonction qui l'oublie
    /// a un raccourci parfaitement réglable dans les réglages et parfaitement
    /// inerte au clavier, sans un mot d'erreur.
    /// Les réglages de la fonction. Tenus ici — et pas seulement la liaison —
    /// parce que trois d'entre eux doivent être poussés à chaud : la rétention
    /// au magasin, la matrice des types à la machine, et l'interrupteur de
    /// capture aux deux voies d'observation. Voir `applySettings()`.
    private let settings: ClipboardSettings

    /// La tâche d'échantillonnage en cours. Une seule : un second indice pendant
    /// une fenêtre ouverte relance la cadence, il ne la double pas.
    private var sampling: Task<Void, Never>?

    /// Le sondeur périodique, ou `nil` tant qu'il n'a pas démarré.
    private var polling: Task<Void, Never>?

    /// Vrai une fois la bibliothèque chargée. Empêche `applySettings()` de
    /// lancer le sondeur avant `start(monitor:)` : la fenêtre en mémoire doit
    /// être remplie avant que quoi que ce soit puisse écrire.
    private var hasLoaded = false

    /// L'application de devant au moment de l'indice.
    ///
    /// **Relevée à l'indice et non à la capture.** Entre les deux il s'écoule au
    /// moins 300 ms, et c'est exactement le temps qu'il faut pour changer de
    /// fenêtre après un ⌘C — auquel cas l'entrée serait attribuée à
    /// l'application d'arrivée. Or la source est le meilleur critère de
    /// recherche trois semaines plus tard : mesuré, Chrome et Terminal font 77 %
    /// de tout l'historique.
    private var pendingSource: ClipboardSource?

    /// L'instant de l'indice, sur l'horloge monotone de la machine.
    private var pendingOrigin: ClipboardMachine.Instant?

    /// Le dernier compte publié au guet, pour ne republier que ce qui change.
    private var publishedChangeCount: Int?

    /// Le numéro d'ordre de la capture en cours.
    ///
    /// **Ce qu'il empêche : une lecture en retard qui remet à zéro la suivante.**
    /// La machine accepte un nouvel indice pendant qu'elle est en `.capturing` —
    /// c'est voulu, un second ⌘C est un geste neuf. Une lecture partie avant
    /// peut donc revenir après qu'un nouveau cycle a commencé, et son
    /// `.captureFinished` remettait alors la machine à `.idle` pour le compte de
    /// quelqu'un d'autre : la phase publiée devenait fausse, et la capture
    /// récente perdait la seule transition qui la termine proprement.
    ///
    /// Même remède que `Paster.pasteGeneration`, et pour la même raison : après
    /// un `await`, « je suis toujours celui qui a commencé » est une question
    /// qu'il faut poser, jamais supposer.
    private var captureGeneration = 0

    /// Le panneau d'historique. Construit à la première ouverture, jamais
    /// reconstruit : c'est ce qui rend tenable le budget de 50 ms.
    @ObservationIgnored private lazy var panel = ClipboardPanelPresenter(
        store: store, settings: settings, thumbnails: thumbnails
    )

    /// La cadence du filet lent.
    ///
    /// Deux secondes, et le chiffre se défend par ce qu'il ne coûte pas : la
    /// lecture est un entier, sans réveil de fournisseur paresseux et sans
    /// alerte d'accès de macOS 15.4. Ce qu'on paie est un réveil du processus,
    /// et c'est ça qu'on espace. Une copie faite à la souris apparaît donc dans
    /// l'historique jusqu'à deux secondes plus tard ; celle faite au clavier est
    /// immédiate, et c'est l'écrasante majorité.
    static let pollInterval: Duration = .seconds(2)

    init(store: ClipboardStore, settings: ClipboardSettings) {
        self.store = store
        self.settings = settings
        self.thumbnails = ThumbnailCache(store: store)
    }

    // MARK: - Démarrage

    /// Charge la bibliothèque, fait le ménage différé, inscrit le raccourci et
    /// arme les deux voies d'observation.
    ///
    /// **L'ordre n'est pas indifférent.** La fenêtre en mémoire est remplie
    /// avant que quoi que ce soit puisse écrire : un `save` qui arriverait
    /// pendant le chargement insérerait son entrée dans une liste vide, que le
    /// chargement écraserait ensuite. La file d'attente de `ClipboardStore` rend
    /// ça impossible depuis peu, mais compter dessus reviendrait à faire
    /// dépendre l'ordre d'affichage d'un détail d'implémentation d'un autre
    /// fichier.
    func start(monitor: HotkeyMonitor) {
        self.monitor = monitor
        applySettings()

        // **Le guet doit être posé, pas seulement renseigné.** `bind` inscrit la
        // touche dans la table ; c'est `install()` qui pose le `CGEventTap`. Les
        // deux autres fonctions l'appellent depuis leur propre interrupteur —
        // `DictationController.setEnabled`, `AppModel.enableSnapshot` — de sorte
        // que le tap existait « par accident » dès que l'une d'elles était
        // active. Le presse-papiers, lui, n'a pas d'interrupteur : sans cet
        // appel, quelqu'un qui a désactivé la dictée et la capture de texte
        // aurait un ⌘⇧C et un indice ⌘C parfaitement inertes, un sondage qui
        // tourne quand même, et donc un historique à moitié vivant sans qu'un
        // seul message ne le dise.
        //
        // L'échec n'est pas signalé ici : il ne peut vouloir dire qu'une chose,
        // l'Accessibilité manque, et c'est l'écran des autorisations qui la
        // réclame. Le sondage, lui, continue de tenir l'historique à jour sans
        // aucune autorisation — c'est même sa deuxième raison d'exister.
        _ = monitor.install()

        Task {
            // **Le raccord des écritures internes, posé avant tout le reste.**
            // Sans lui, chaque dictée, chaque capture de texte et chaque
            // restitution de presse-papiers apparaîtraient dans l'historique
            // comme des copies de l'utilisateur. Posé au seul endroit d'où bran
            // écrit, plutôt que sur chacun des deux `Paster` : un troisième
            // écrivain futur ne peut pas l'oublier.
            await pasteboardAccess.reportWrites { [weak self] count in
                Task { @MainActor in self?.noteOwnWrite(changeCount: count) }
            }

            // **La référence est publiée avant le chargement, et c'est une
            // correction.** Elle l'était après, ce qui ouvrait une fenêtre de la
            // durée d'un `load` plus une purge plus un ramassage — des dizaines
            // de millisecondes, parfois davantage sur une grande bibliothèque —
            // pendant laquelle une copie était perdue des deux côtés à la fois :
            // l'indice clavier n'avait pas de référence, donc ne partait pas, et
            // le premier tour du sondeur traitait sa mesure comme la référence
            // et non comme un événement. Publier d'abord arme les deux voies
            // avant que quoi que ce soit de lent ne commence.
            if settings.capturesCopies {
                publish(changeCount: await pasteboardAccess.changeCount())
            }

            await store.load()
            // Le ménage après le chargement, jamais avant : la purge et le
            // ramassage relisent des dossiers entiers, et faire attendre la
            // première ouverture du panneau derrière eux serait payer au pire
            // moment un travail qui n'intéresse personne.
            await store.purgeExpired()
            await store.collectOrphanedBlobs()
            await thumbnails.sweep()
            hasLoaded = true
            if settings.capturesCopies { startPolling() }
        }
    }

    /// Arrête les deux tâches de fond.
    ///
    /// **C'est l'interrupteur de capture qui l'appelle**, et il est arrivé peu
    /// après qu'elle a été écrite « au cas où ». Une boucle infinie sans moyen
    /// déclaré de s'arrêter est une fuite qui attend son premier appelant ;
    /// celui-ci est `applySettings()`, quand `capturesCopies` passe à faux.
    func stop() {
        polling?.cancel()
        polling = nil
        sampling?.cancel()
        sampling = nil
        monitor?.observeCopies(changeCount: nil)
        publishedChangeCount = nil
    }

    /// Pousse les réglages là où ils agissent, et **à chaud**. À appeler après
    /// tout changement, comme ses deux sœurs.
    ///
    /// Trois destinataires, et aucun ne se réveille tout seul : le magasin pour
    /// la rétention, la machine pour la matrice des types, les deux voies
    /// d'observation pour l'interrupteur de capture.
    func applySettings() {
        // Le raccourci est inscrit dans tous les cas, capture éteinte comprise :
        // ⌘⇧C ouvre l'historique déjà rangé, et cesser d'écrire ne doit pas
        // empêcher de lire.
        monitor?.bind(.clipboard, to: settings.trigger)
        store.setRetention(settings.retention)
        machine.policy = settings.typePolicy

        guard settings.capturesCopies else {
            // `stop()` désarme les deux voies d'un coup : il annule le sondeur
            // et rend `nil` au guet, ce qui suffit à éteindre l'indice clavier —
            // sans référence publiée, le tap ne relaie plus rien, voir
            // `HotkeyMonitor.observeCopies`. C'est la définition exacte de « ne
            // rien écrire du tout », et rien n'est supprimé au passage.
            stop()
            return
        }

        guard hasLoaded, polling == nil else { return }
        // Rallumage après extinction : la référence d'abord — un indice sans
        // référence ne veut rien dire —, le sondeur ensuite.
        Task { [weak self] in
            let count = await pasteboardAccess.changeCount()
            // **Le réglage est relu après l'attente, et pas seulement avant.**
            // L'acteur du presse-papiers peut rester bloqué des secondes dans un
            // XPC ; éteindre l'interrupteur pendant ce temps laisserait cette
            // tâche-ci rallumer le sondeur en arrivant, et les copies
            // recommenceraient à être capturées alors que le réglage dit non.
            // C'est la règle générale de ce fichier : après un `await`, « rien
            // n'a changé » est une question, jamais une supposition.
            guard let self, self.settings.capturesCopies, self.polling == nil else { return }
            self.publish(changeCount: count)
            self.startPolling()
        }
    }

    // MARK: - La voie du clavier

    /// Un ⌘C ou un ⌘X vient d'être observé, et voici le compte d'avant.
    ///
    /// Branché sur `ShortcutRouter.onCopyHint`, qui le relaie **sans
    /// arbitrage** : une copie faite pendant une dictée est précisément celle
    /// qu'on voudra coller à la fin.
    func copyHinted(changeCount: Int) {
        hint(changeCount: changeCount)
    }

    /// Le raccourci d'ouverture du panneau.
    func openRequested() {
        panel.toggle()
    }

    /// Le panneau est-il ouvert ?
    ///
    /// **Lu par `ShortcutRouter`, et il a fallu l'y brancher.** La première
    /// version portait ce commentaire en annonçant un arbitrage qui n'existait
    /// pas : on pouvait démarrer une dictée ou une capture pendant que le
    /// panneau était ouvert **et fenêtre clé**, c'est-à-dire poser l'encoche ou
    /// le viseur de macOS par-dessus une liste qui attend une touche. C'est
    /// exactement la réentrance que la doctrine de l'aiguilleur interdit — une
    /// fonction occupée fait taire les autres — appliquée à la fonction qui
    /// venait d'arriver.
    var isBusy: Bool { panel.isOpen }

    /// Referme le panneau pour laisser la place à une autre fonction.
    func closePanel() { panel.close() }

    // MARK: - La voie de l'écriture interne

    /// bran vient d'écrire sur le presse-papiers, et voici le compte que son
    /// écriture a rendu.
    ///
    /// **À appeler par tout ce qui écrit**, sans exception : sans ça, chaque
    /// dictée et chaque capture de texte se retrouveraient dans l'historique du
    /// presse-papiers comme si l'utilisateur les avait copiées, ce qui doublerait
    /// silencieusement toutes les deux.
    func noteOwnWrite(changeCount: Int) {
        machine.handle(.selfWrote(changeCount: changeCount))
        publish(changeCount: changeCount)
    }

    // MARK: - Le filet lent

    /// Sonde `changeCount` à cadence fixe, et déclenche un indice quand il a
    /// bougé sans que personne ne l'ait annoncé.
    ///
    /// **C'est aussi lui qui tient à jour la valeur publiée au guet.** Le
    /// callback du tap ne lit pas le presse-papiers — il ne peut pas, il n'a le
    /// droit de rien bloquer — il relit ce que ce sondeur a publié. Arrêter le
    /// sondeur désarme donc l'indice clavier, ce qui est cohérent : sans
    /// référence, un indice ne veut rien dire.
    ///
    /// **La référence forte ne survit pas au sommeil, et ce détail est le
    /// cycle.** Un `guard let self` en tête de boucle lie une référence forte
    /// qui vit jusqu'à la fin de l'itération, sommeil compris : la tâche
    /// retiendrait alors le contrôleur pour toujours, à travers une boucle qui
    /// ne se termine jamais, et le `[weak self]` ne servirait plus à rien. Prise
    /// dans un `if let`, la référence meurt avec sa portée, avant le `sleep`.
    private func startPolling() {
        polling?.cancel()
        polling = Task { [weak self] in
            while Task.isCancelled == false {
                let count = await pasteboardAccess.changeCount()
                if let controller = self {
                    controller.pollTick(count)
                } else {
                    return
                }
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    private func pollTick(_ count: Int) {
        let previous = publishedChangeCount
        publish(changeCount: count)

        // La première mesure n'est pas un événement : elle établit la référence.
        // Sans ce garde-fou, tout ce qui était sur le presse-papiers au
        // lancement de bran serait capturé comme une copie qui vient d'avoir
        // lieu — avec la date du lancement, ce qui est faux, et à chaque
        // lancement, ce qui est un doublon par jour.
        guard let previous, count != previous else { return }
        hint(changeCount: previous)
    }

    /// Publie le compte au guet, et ne le fait que quand il change.
    private func publish(changeCount: Int) {
        guard publishedChangeCount != changeCount else { return }
        publishedChangeCount = changeCount
        monitor?.observeCopies(changeCount: changeCount)
    }

    // MARK: - Le cycle de la machine

    /// L'entrée commune aux deux voies qui découvrent une copie.
    private func hint(changeCount: Int) {
        pendingSource = Self.frontmostSource()
        pendingOrigin = .now
        run(machine.handle(.hinted(changeCount: changeCount, at: pendingOrigin!)))
    }

    private func run(_ effects: [ClipboardMachine.Effect]) {
        phase = machine.phase
        for effect in effects {
            switch effect {
            case .sample(let delay):
                scheduleSample(after: delay)
            case .capture(let plan):
                capture(plan)
            case .ignore(let skip):
                finish(skip)
            }
        }
    }

    /// Programme le prochain relevé. **Une seule tâche à la fois** : la machine
    /// ne demande jamais deux échantillons en parallèle, et un indice qui
    /// relance la cadence remplace celle en cours plutôt que de s'y ajouter.
    private func scheduleSample(after delay: Duration) {
        sampling?.cancel()
        sampling = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard Task.isCancelled == false else { return }
            let sample = await pasteboardAccess.sample()
            guard let self, Task.isCancelled == false else { return }
            self.publish(changeCount: sample.changeCount)
            self.run(self.machine.handle(.sampled(sample, at: .now)))
        }
    }

    /// Lit le contenu, une seule fois, exactement comme le plan le dit.
    private func capture(_ plan: ClipboardCapturePlan) {
        phase = machine.phase
        let source = pendingSource
        captureGeneration += 1
        let generation = captureGeneration
        Task { [weak self] in
            let reading = await pasteboardAccess.capture(plan)
            guard let self else { return }
            await self.store(reading, for: plan, from: source, generation: generation)
        }
    }

    private func store(
        _ reading: ClipboardReading?,
        for plan: ClipboardCapturePlan,
        from source: ClipboardSource?,
        generation: Int
    ) async {
        // La lecture est arrivée après qu'un nouveau cycle a commencé : tout ce
        // qui suit lui appartient. On ne termine pas sa capture à sa place, et
        // on n'écrit rien — le contenu lu est celui d'avant.
        guard generation == captureGeneration else {
            clipboardLog.notice("Lecture en retard, une copie plus récente a pris la main")
            return
        }

        defer {
            // Le même garde-fou une seconde fois : `store` a lui aussi des
            // `await`, et un nouvel indice a pu passer pendant l'écriture.
            if generation == captureGeneration { run(machine.handle(.captureFinished)) }
        }

        // « Trop tard » et « illisible » sont deux verdicts distincts, et les
        // confondre effacerait la différence entre une copie qu'on a ratée et
        // une copie qui n'a jamais rien porté. Le premier n'est pas une panne :
        // le compteur a rebougé, donc une autre copie est en route et c'est elle
        // qui sera gardée.
        guard let reading, reading.matches(plan) else {
            clipboardLog.notice("Contenu changé pendant la lecture, capture abandonnée")
            return
        }

        guard let result = ClipboardCapture.make(
            for: plan, reading: Self.flattening(reading, for: plan), source: source, copiedAt: .now
        ) else {
            clipboardLog.error(
                "Rien de décodable sous \(plan.primaryType, privacy: .public), copie perdue"
            )
            return
        }

        await store.save(result.entry, payloads: result.payloads)
        lastSkip = nil
    }

    private func finish(_ skip: ClipboardSkip) {
        phase = machine.phase
        pendingSource = nil
        pendingOrigin = nil

        // **Effacé d'abord, reposé ensuite.** La version précédente sortait
        // avant d'effacer quand le motif n'était pas notable, si bien qu'un
        // incident réel — « aucun format exploitable » — restait affiché après
        // dix copies normales. Un canal qui garde le dernier *incident* plutôt
        // que le dernier *état* finit toujours par décrire un passé que
        // personne ne reconnaît.
        lastSkip = nil

        // Cinq des sept cas sont parfaitement normaux et ne méritent pas une
        // ligne : sans ce filtre, un ⌘C dans un champ vide écrirait au journal.
        guard skip.isNoteworthy else { return }
        lastSkip = skip
        clipboardLog.notice("Copie non conservée : \(skip.summary, privacy: .public)")
    }

    // MARK: - Aplatir un texte enrichi

    /// Ajoute à la lecture l'aplatissement en texte brut de sa forme enrichie,
    /// **et seulement quand le presse-papiers n'en portait pas déjà un**.
    ///
    /// **Sans ça, `ClipboardReading.flattenedText` n'était jamais renseigné, et
    /// un repli que personne n'alimente est un repli qui n'existe pas.** Une
    /// revue l'a relevé sur les tests : ils vérifiaient que `ClipboardCapture`
    /// *sait* se servir d'un aplatissement, jamais que l'intégration lui en
    /// fournit un. Le cas concret est un RTF ou un HTML posé sans
    /// `public.utf8-plain-text` à côté — cela arrive, notamment depuis des
    /// éditeurs qui n'écrivent que leur format. L'entrée naissait alors avec un
    /// aperçu vide : une ligne muette dans la liste, introuvable à la recherche,
    /// pour un contenu parfaitement présent.
    ///
    /// **Ici et non dans `PasteboardAccess`, à cause de HTML.** L'importateur
    /// HTML de `NSAttributedString` s'appuie sur WebKit et exige le fil
    /// principal ; l'acteur d'accès, lui, tourne sur une file série dédiée
    /// précisément pour ne jamais bloquer le fil principal. Aplatir là-bas
    /// aurait donc été soit faux pour HTML, soit une entorse à la raison d'être
    /// de cette file. Le contrôleur est `@MainActor` : c'est le bon endroit, et
    /// le coût n'est payé que dans le cas de repli.
    ///
    /// **Ce n'est pas du texte inventé.** L'aplatissement est ce que le même
    /// contenu donne quand on le colle dans un champ sans mise en forme —
    /// exactement ce que l'entrée promet sous `plainText`.
    private static func flattening(
        _ reading: ClipboardReading, for plan: ClipboardCapturePlan
    ) -> ClipboardReading {
        guard plan.kind == .richText else { return reading }

        // Un compagnon en texte brut présent rend l'aplatissement inutile : il
        // est plus fidèle, il est gratuit, et c'est la source de l'application
        // elle-même.
        let carriesPlainText = ClipboardTypePolicy.textTypes.contains { type in
            reading.values(of: type).isEmpty == false
        }
        guard carriesPlainText == false else { return reading }

        guard let data = reading.values(of: plan.primaryType).first,
              let flattened = Self.plainText(from: data, type: plan.primaryType),
              flattened.isEmpty == false
        else { return reading }

        return ClipboardReading(
            changeCount: reading.changeCount,
            items: reading.items,
            flattenedText: flattened
        )
    }

    /// Le texte nu d'une forme enrichie, ou `nil` si elle refuse de s'ouvrir.
    ///
    /// `nil` plutôt qu'une chaîne vide, et sans repli : un aplatissement qui
    /// échoue laisse l'aperçu vide, ce qui est déjà le comportement documenté.
    /// Inventer quelque chose ici — les octets lus en latin-1, par exemple —
    /// mettrait du mojibake là où l'interface affiche du texte.
    private static func plainText(from data: Data, type: String) -> String? {
        let documentType: NSAttributedString.DocumentType? = switch type {
        case "public.rtf": .rtf
        case "com.apple.flat-rtfd", "public.rtfd": .rtfd
        case "public.html": .html
        default: nil
        }
        guard let documentType else { return nil }

        let attributed = try? NSAttributedString(
            data: data,
            options: [.documentType: documentType],
            documentAttributes: nil
        )
        return attributed?.string
    }

    // MARK: - Qui a copié

    /// L'application au premier plan, ou `nil` si elle n'a pas pu être lue.
    ///
    /// `nil` plutôt qu'une valeur inventée : `ClipboardSource.isUnknown` existe
    /// pour que l'interface se taise dans ce cas, et « Inconnu » occuperait la
    /// même place en ne disant rien.
    ///
    /// **Ce n'est pas bran, même quand bran est devant.** Le panneau est un
    /// `NSPanel` non activant : l'ouvrir laisse `frontmostApplication` désigner
    /// l'application où l'on travaille — c'est mesuré, et c'est ce sur quoi
    /// repose la cible du collage.
    private static func frontmostSource() -> ClipboardSource? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return ClipboardSource(
            bundleIdentifier: app.bundleIdentifier, name: app.localizedName
        )
    }
}
