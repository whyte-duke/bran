import AppKit
import CoreGraphics
import Dispatch
import Foundation

/// Le collage du texte là où était le curseur.
///
/// Huit détails font toute la différence entre « ça marche » et « ça marche
/// vraiment ». Les deux premiers se voient à la première dictée ; les six
/// autres ne se voient que chez quelqu'un d'autre, sur une autre machine, un
/// autre jour — et c'est exactement pour ça qu'ils ont vécu longtemps :
///
/// 1. **La cible peut changer.** Vous appuyez dans Slack, vous parlez, une
///    notification vous fait cliquer ailleurs, vous relâchez. Le texte partirait
///    dans la mauvaise fenêtre. On mémorise donc l'application au *début* de la
///    dictée et on la réactive avant de coller.
/// 2. **Le presse-papiers appartient à l'utilisateur.** Il y avait peut-être
///    quelque chose dedans — ou rien, et *rien est un contenu comme un autre* :
///    un presse-papiers trouvé vide se rend vide. D'où un instantané optionnel
///    plutôt qu'un tableau. Un tableau vide voulait dire deux choses à la fois,
///    « il n'y avait rien » et « je n'ai rien pu lire », et la restitution
///    renonçait dans les deux cas : le texte dicté restait en place là où il
///    fallait rendre un presse-papiers vide. `nil` veut dire « rien à rendre » ;
///    `[]` veut dire « rendre le vide », et les deux se distinguent.
/// 3. **Rendre peut détruire.** Entre le ⌘V et la restitution il s'écoule
///    600 ms, et 600 ms suffisent très largement à un ⌘C réflexe juste après
///    une dictée. Réécrire l'ancien contenu par-dessus ne « rend » alors plus
///    rien : ça efface la copie toute fraîche de l'utilisateur, sans un mot.
///    D'où le numéro de version (`changeCount`) vérifié avant toute
///    restitution : si le presse-papiers ne porte plus celui de notre propre
///    écriture, il ne nous appartient plus et on n'y touche pas.
///
///    La vérification est faite **sur la file du point 8**, dans le même
///    passage que l'écriture qu'elle autorise : la contrôler ailleurs laisserait
///    entre le test et l'écriture un intervalle que nos propres accès peuvent
///    traverser.
///
///    Et la restitution est **liée au collage qui l'a programmée**. Deux dictées
///    à moins de 680 ms d'intervalle partagaient un seul jeu de variables : le
///    minuteur de la première lisait la sauvegarde et le numéro de version de la
///    seconde, et rendait le contenu de l'une avec le laissez-passer de l'autre,
///    par-dessus un texte qui n'avait même pas fini d'être collé. Chaque collage
///    porte donc son numéro d'ordre, et un minuteur qui se réveille sur un
///    collage qui n'est plus le sien s'arrête.
/// 4. **La copie faite *pendant* la dictée, elle, est perdue — et il faut le
///    dire.** Le point 3 protège la fenêtre qui *suit* notre écriture ; celle
///    qui la précède ne se protège pas. Un ⌘C entre l'appui et le collage rend
///    l'instantané périmé : on ne le rend donc pas, c'est le point 3 — mais le
///    texte dicté s'écrit quand même par-dessus la copie toute fraîche. Il
///    n'existe aucune façon de coller sans posséder le presse-papiers :
///    l'écrasement n'est pas évitable. Ce qui l'était, c'est le silence.
///
///    Trois issues ont été pesées :
///
///    - **rendre l'instantané périmé quand même** : la pire. Elle détruit la
///      copie fraîche *et* ressuscite un contenu que l'utilisateur venait
///      lui-même de remplacer ;
///    - **relire le presse-papiers juste avant d'écrire**, pour sauver la copie
///      fraîche : c'est replacer une lecture de durée non bornée exactement là
///      où le point 6 s'échine à n'en avoir aucune, entre la transcription et le
///      ⌘V. Une dictée qui atterrit trois secondes trop tard dans la fenêtre
///      d'à côté est un dégât autrement plus grave qu'une entrée de
///      presse-papiers à recopier ;
///    - **remarquer la copie à l'instant où elle se fait**, en surveillant
///      `changeCount` : c'est mot pour mot ce que fait l'historique de
///      presse-papiers en cours de construction, pour tout le système et en
///      permanence. Un second surveillant ici, pour couvrir 600 ms d'un seul
///      cas, serait la même fonction écrite deux fois — et rien ne garantit que
///      ce soit la bonne des deux qui survive.
///
///    Donc : on écrase, on ne rend rien, et on le journalise, parce qu'un dégât
///    silencieux est un dégât qu'on ne saura jamais mesurer. **Le jour où
///    l'historique existe, tout ce ballet de sauvegarde et de restitution
///    disparaît** : la copie de l'utilisateur sera dans l'historique, à un
///    raccourci de distance, et le presse-papiers n'aura plus à être remis dans
///    l'état exact où on l'a trouvé. Ce fichier perdra alors ses points 2, 3 et
///    4 d'un coup.
/// 5. **Rien ne doit quitter le Mac.** `clearContents()` laisse tomber l'option
///    `NSPasteboardContentsCurrentHostOnly` : tout ce qu'on écrit ensuite est
///    diffusé sur l'iPhone et l'iPad du même compte iCloud par le
///    presse-papiers universel. Le README s'ouvre sur « rien n'est téléversé » ;
///    cette promesse tombait au premier mot dicté. D'où
///    `prepareForNewContents(with: .currentHostOnly)` partout, sans exception.
/// 6. **Lire le presse-papiers peut tuer le raccourci.** `data(forType:)` sur un
///    type *promis* — une pièce jointe de Mail, un rendu TIFF de Photoshop, un
///    élément que le presse-papiers universel est en train de tirer de
///    l'iPhone — est un XPC **synchrone** vers `pasteboardd`, qui interroge à
///    son tour le thread principal de l'application source. Si celle-ci est
///    occupée, l'appel dure des secondes. Fait depuis le main actor, il dépasse
///    le budget de temps du `CGEventTap` — la source du tap est sur
///    `CFRunLoopGetMain()`, voir l'en-tête de `HotkeyMonitor` —, macOS répond
///    `.tapDisabledByTimeout` et la dictée devient muette sans un message. La
///    lecture se fait donc à l'appui, hors du main actor : une dictée dure des
///    secondes, c'est tout le temps qu'il faut pour lire calmement.
///
///    Le numéro de génération suffisait à ne pas *adopter* une lecture périmée,
///    mais la lecture, elle, continuait : le XPC, le réveil de l'application
///    source et l'allocation des `Data` avaient lieu pour rien. La tâche est
///    donc gardée et annulée — à la lecture suivante, et avant toute écriture,
///    qui la rend caduque de toute façon. L'annulation est vérifiée entre deux
///    représentations, là où l'attente se répète. **Elle n'interrompt pas un XPC
///    déjà bloqué** : rien dans Swift ne le peut, un appel synchrone en cours va
///    jusqu'à son terme. Ce qu'elle garantit est plus modeste et bien réel :
///    aucune représentation *suivante* ne sera demandée.
/// 7. **L'ordre des représentations compte.** L'application qui colle prend « le
///    premier type qu'elle comprend » dans `pasteboard.types`. Un `Dictionary`
///    n'ayant pas d'ordre d'itération garanti, la même copie enrichie
///    ressortait tantôt en RTF, tantôt en texte brut. On conserve donc l'ordre
///    de `item.types` tel que la source l'a déclaré.
/// 8. **bran ne doit pas se courir après.** La lecture du point 6 tourne hors du
///    main actor pendant que le main actor, lui, écrit — et les deux touchent le
///    *même objet* : `NSPasteboard.general` est un singleton d'AppKit, et
///    `NSPasteboard(name: .general)` rend cette instance-là et pas une autre
///    (vérifié : `NSPasteboard.general === NSPasteboard(name: .general)`). Il
///    n'y a donc pas d'échappatoire par « une instance chacun ». Tous les accès
///    de bran — lectures comme écritures — passent par un seul acteur,
///    `PasteboardAccess`, dont l'exécuteur est une `DispatchSerialQueue` : la
///    sérialisation devient une propriété du type, vérifiée par le compilateur,
///    au lieu d'une convention que la prochaine ligne de code oubliera.
///
///    `DispatchSerialQueue` et non le pool coopératif : le XPC du point 6 bloque
///    le fil qui l'exécute. Sur le pool, un fil bloqué est un fil de moins pour
///    tout le programme, et il n'y en a que le nombre de cœurs.
///
///    Le prix à payer est réel et mérite d'être nommé. Une exclusion mutuelle
///    veut dire que quelqu'un attend, et le main actor n'a pas le droit
///    d'attendre (point 6). L'écriture est donc **postée** sur la file, jamais
///    attendue. Dans le cas courant elle est immédiate et le comportement est
///    celui d'avant, à quelques microsecondes près ; dans le cas pathologique —
///    une lecture bloquée depuis le début de la dictée — tout ce qui suit
///    arrive en retard, ce qui reste très préférable à un ⌘V qui colle
///    l'*ancien* contenu parce que le nôtre n'est pas encore arrivé.
///
///    Et « tout ce qui suit » veut dire **tout**. Poster l'écriture a laissé
///    derrière elle une hypothèse que chaque appelant continuait de faire : au
///    retour de `paste(_:)`, le texte est au presse-papiers. Il ne l'est pas.
///    Quatre choses en dépendaient, et chacune arrivait trop tôt :
///
///    - **l'activation de la cible.** Elle partait dans l'instant, le ⌘V
///      seulement à la fin de l'écriture. Séparées par une attente non bornée,
///      elles ne désignent plus la même fenêtre : le ⌘V atterrissait là où
///      l'utilisateur était revenu entre-temps, ce qui annule le point 1. Elles
///      sont désormais **adjacentes**, du même côté de l'attente — et les
///      0,08 s qui les séparent existent toujours pour la même raison, laisser
///      le changement d'application aboutir ;
///    - **la fin de la dictée.** La machine à états revenait au repos au retour
///      de `paste(_:)`, donc pendant qu'un ⌘V était encore armé : deux dictées
///      pouvaient se chevaucher dans un état que la machine déclare impossible ;
///    - **le son et la phase de la capture de texte**, joués et changés avant
///      que le texte soit là. On entend « c'est fait », on fait ⌘V, et on colle
///      le contenu précédent ;
///    - **la valeur de retour**, lue comme « c'est collé » alors qu'elle ne dit
///      que « je vais essayer ».
///
///    D'où deux réponses distinctes à deux questions distinctes, et il faut les
///    deux. La valeur de retour de `paste(_:)` répond tout de suite « est-ce que
///    je vais seulement essayer ? » — c'est ce qui permet de préparer un message
///    sans attendre une écriture qui peut traîner. `whenLanded` répond plus tard
///    « voilà ce qui s'est réellement passé, et c'est fini » — c'est le seul
///    signal qui autorise à affirmer que le texte est au presse-papiers, donc à
///    jouer un son, à changer de phase, ou à rendre la main. Aucun appelant ne
///    doit l'affirmer avant.
///
///    Ce que la file ne donne pas : l'exclusivité vis-à-vis du reste du monde.
///    Le presse-papiers est partagé par toutes les applications du système, et
///    n'importe laquelle peut écrire au milieu de notre lecture. Aucun verrou
///    de ce processus n'y peut quoi que ce soit — c'est précisément à ça que
///    sert `changeCount` (points 3 et 6).
///
/// ```
///        appui                  relâchement   écriture finie  +0,08 s   +0,68 s
///          │                         │              │            │         │
/// main ────┼──── parole (des sec.) ──┼──────────────┼────────────┼─────────┼──►
/// actor    │                         │              │            │         │
///          │ mémorise la cible ; annule la     active la     ⌘V, puis  restitution
///          │ demande la lecture  lecture ;     cible         whenLanded demandée,
///          │ (seulement si la    demande            ▲                   liée à CE
///          │  dictée est encore  l'écriture         │                   collage-là
///          ▼  possible)              ▼              │                       ▼
/// file ────●── lecture ──► instantané ●── écriture ─┘ ─────────────────────●─ restitution
/// série       (XPC vers pasteboardd :      du texte,                         si le n° de
///              des secondes possibles ;    rend le n°                        version est
///              jamais attendue ;           de version                        encore le
///              annulable, pas                                                nôtre
///              interruptible)
/// ```
///
/// L'activation de la cible est **du côté droit** de l'écriture, collée au ⌘V :
/// c'est ce qui fait qu'un collage tardif atterrit quand même dans la fenêtre
/// choisie au début de la dictée, et non dans celle où l'utilisateur est revenu
/// en attendant.
@MainActor
final class Paster {

    /// Ce qu'un collage a **réellement** fait, une fois le presse-papiers écrit.
    ///
    /// C'est la seconde des deux réponses du point 8, et la seule qui autorise à
    /// dire que le texte est là. Elle arrive quand tout est terminé : le
    /// presse-papiers porte le texte, et le ⌘V — s'il y en avait un à envoyer —
    /// est parti.
    enum Landing: Sendable, Equatable {
        /// Le texte est au presse-papiers et le ⌘V est parti vers la cible.
        case pasted
        /// Le texte est au presse-papiers, et rien d'autre n'a eu lieu. La cible
        /// avait disparu, la saisie sécurisée bloquait la synthèse d'événements,
        /// ou l'appelant n'avait rien demandé de plus (`copyOnly(_:)`).
        case clipboardOnly

        /// L'utilisateur a-t-il un ⌘V à faire lui-même ?
        ///
        /// La question que se posent les deux appelants, et la seule : elle évite
        /// à chacun de réécrire la comparaison — donc de se tromper de sens le
        /// jour où un troisième cas apparaîtra.
        var needsManualPaste: Bool { self == .clipboardOnly }
    }

    /// Ce qu'on dit à l'utilisateur quand le collage n'a pas eu lieu.
    ///
    /// La phrase vit ici, à côté de la garantie dont elle dépend : quoi qu'il
    /// arrive, le texte part au presse-papiers **avant** tout retour anticipé
    /// (en-tête, points 4 et 8). Sans cette garantie la phrase serait un
    /// mensonge ; en la laissant dans les deux interfaces, on pouvait corriger
    /// l'une et oublier l'autre.
    ///
    /// À n'afficher qu'une fois la `Landing` reçue : avant, le texte n'est pas
    /// encore là et la phrase est prématurée.
    static let fallbackNotice =
        "Le texte n'a pas pu être collé — il est dans le presse-papiers, faites ⌘V."

    /// Ce qu'un collage a mis de côté, **et le collage auquel ça appartient**.
    ///
    /// Le tout dans une seule valeur, parce que les trois champs n'ont de sens
    /// qu'ensemble : c'est en les laissant vivre séparément que le minuteur
    /// d'un collage a fini par rendre la sauvegarde d'un autre (point 3).
    private struct PendingRestore {
        let generation: Int
        /// `[]` est une valeur, pas une absence : rendre un presse-papiers vide,
        /// c'est le rendre tel qu'on l'a trouvé (point 2). L'absence, elle,
        /// s'écrit `nil` sur `pending`.
        let items: [SavedItem]
        /// Numéro de version rendu par notre propre écriture. Tant que le
        /// presse-papiers le porte, bran en est le dernier auteur et peut
        /// reprendre sa place ; dès qu'il en porte un autre, quelqu'un a copié
        /// et le presse-papiers a changé de propriétaire.
        let writtenChangeCount: Int
    }

    /// Application visée, mémorisée au moment où la dictée démarre.
    private var target: NSRunningApplication?

    /// Ce que la lecture a rapporté, avec le numéro de version que le
    /// presse-papiers portait pendant qu'on le lisait. `nil` tant que la lecture
    /// n'a pas abouti — c'est un état normal et non une panne, voir `paste(_:)`.
    private var snapshot: ClipboardSnapshot?

    /// Ce qu'on rendra après le collage, si on le juge encore légitime.
    private var pending: PendingRestore?

    /// La lecture en cours, gardée pour pouvoir l'annuler (point 6).
    private var readTask: Task<Void, Never>?

    /// Génération de la lecture en cours. Deux dictées qui s'enchaînent lancent
    /// deux lectures et rien ne garantit qu'elles finissent dans l'ordre où
    /// elles ont commencé : sans ce compteur, la plus lente écraserait la plus
    /// récente.
    private var readGeneration = 0

    /// Numéro d'ordre du collage. Sert à ce qu'un minuteur ne parle jamais au
    /// nom d'un collage qui n'est plus le sien (point 3).
    private var pasteGeneration = 0

    /// Faut-il rendre le presse-papiers à l'utilisateur après collage ?
    /// Certains préfèrent garder la dernière dictée sous la main.
    var restoresClipboard = true

    /// Mémorise la cible **et**, si `readingClipboard` le permet, lance la
    /// lecture du presse-papiers. À appeler à l'appui sur le raccourci, pas au
    /// relâchement.
    ///
    /// C'est tout l'intérêt du moment choisi : la lecture a devant elle la durée
    /// de la dictée pour aboutir, au lieu de devoir s'insérer entre la fin de la
    /// transcription et le ⌘V, là où elle bloquerait le main actor et couperait
    /// le tap clavier (point 6).
    ///
    /// - Parameter readingClipboard: `false` quand l'appelant sait déjà que la
    ///   dictée ne se fera pas — saisie sécurisée, micro refusé, appui qui
    ///   *arrête* une dictée en cours. La lecture n'est pas gratuite : elle
    ///   réveille l'application source pour chaque type promis et, depuis
    ///   macOS 15.4, peut déclencher l'alerte système d'accès au presse-papiers.
    ///   La cible, elle, est mémorisée dans tous les cas : c'est la seule chose
    ///   qu'on ne pourra plus savoir plus tard (point 1).
    func rememberTarget(readingClipboard: Bool = true) {
        target = NSWorkspace.shared.frontmostApplication

        // Rien d'autre n'est réinitialisé quand on ne relit pas. Un instantané
        // plus ancien n'est pas dangereux : il porte son propre numéro de
        // version, et sera refusé au collage si le presse-papiers a bougé
        // depuis (point 3). Le jeter était un vrai bug en mode bascule, où le
        // second appui — celui qui arrête la dictée — effaçait la lecture que
        // le premier avait eu tout le temps de mener à bien.
        guard restoresClipboard, readingClipboard else { return }

        readTask?.cancel()

        readGeneration &+= 1
        let generation = readGeneration
        snapshot = nil

        // La tâche vit sur le main actor ; seul l'appel à l'acteur en sort. Ce
        // n'est pas une nuance de style : c'est ce qui rend `adopt` sûr sans un
        // saut d'isolation de plus, et c'est l'exécuteur de `PasteboardAccess`,
        // pas ce `Task`, qui décide où le XPC bloquant s'exécute (point 8).
        readTask = Task { [weak self] in
            let read = await pasteboardAccess.read()
            guard let self else { return }
            adopt(read, generation: generation)
        }
    }

    /// Range le résultat de la lecture. On y revient sur le main actor, mais au
    /// milieu de la dictée : personne n'attend, et le coût est celui d'une
    /// affectation.
    private func adopt(_ read: ClipboardSnapshot?, generation: Int) {
        guard generation == readGeneration else { return }
        readTask = nil
        guard let read else { return }
        snapshot = read
    }

    /// Place le texte dans le presse-papiers et le colle dans la cible.
    ///
    /// **Deux questions, deux réponses, et il faut les deux** (point 8) :
    ///
    /// - la **valeur de retour** répond « vais-je seulement essayer de coller ? »
    ///   et elle répond tout de suite, sur le main actor. `false` veut dire que
    ///   la cible a disparu ou que la saisie sécurisée bloque la synthèse
    ///   d'événements : aucun ⌘V ne sera tenté. Elle ne dit **rien** de l'état du
    ///   presse-papiers, qui à cet instant ne porte pas encore le texte ;
    /// - `whenLanded` répond « qu'est-ce qui s'est passé, et est-ce fini ? », et
    ///   elle répond plus tard, rappelée sur le main actor. C'est le seul signal
    ///   qui autorise à affirmer que le texte est au presse-papiers, donc à
    ///   jouer un son, à faire avancer une machine à états ou à conclure quoi que
    ///   ce soit.
    ///
    /// Les deux peuvent diverger, et c'est voulu : entre la décision et
    /// l'écriture il peut s'écouler des secondes, pendant lesquelles la cible
    /// peut se fermer ou un champ de mot de passe prendre le focus. `true` suivi
    /// d'un `.clipboardOnly` est donc un cas normal, pas une incohérence — la
    /// seconde réponse a le dernier mot.
    ///
    /// Dans tous les cas le texte part au presse-papiers. Perdre le texte serait
    /// la pire issue possible, et `Paster.fallbackNotice` dit exactement ce qu'il
    /// reste à faire.
    ///
    /// - Parameter whenLanded: appelé **une fois**, sur le main actor, quand tout
    ///   est terminé. Facultatif : un appelant qui n'a rien à enchaîner ne doit
    ///   pas avoir à écrire une fermeture vide.
    @discardableResult
    func paste(_ text: String, whenLanded: ((Landing) -> Void)? = nil) -> Bool {
        // La lecture en cours n'a plus d'objet : on s'apprête à écrire par-
        // dessus ce qu'elle est en train de lire. L'annuler ne l'interrompra pas
        // si elle est déjà bloquée dans son XPC, mais lui épargnera tout ce
        // qu'il lui restait à demander (point 6).
        readTask?.cancel()
        readTask = nil

        pasteGeneration &+= 1
        let generation = pasteGeneration

        let saved = snapshot
        snapshot = nil

        // La restitution d'un collage précédent, s'il y en a une en attente, est
        // caduque : on écrit par-dessus dans l'instant, et l'instantané de ce
        // collage-ci a capturé ce qu'il y avait juste avant lui — c'est-à-dire,
        // le plus souvent, le texte de ce collage précédent (point 4).
        pending = nil

        let target = self.target
        // Deux raisons de ne pas simuler le collage, connues dès maintenant
        // parce qu'aucune des deux ne touche au presse-papiers :
        //
        // - la cible a disparu pendant qu'on transcrivait ;
        // - la saisie sécurisée bloque aussi la synthèse d'événements.
        //
        // Dans les deux cas le texte part quand même au presse-papiers : c'est
        // récupérable, contrairement à un collage envoyé dans le vide.
        let willTry = target != nil
            && target?.isTerminated == false
            && HotkeyMonitor.isSecureInputActive == false

        Task { [weak self] in
            // `expecting:` fait comparer le numéro de version *sur la file*,
            // juste avant d'écrire — le seul endroit où « le presse-papiers
            // n'a pas bougé depuis la lecture » et « je l'écris » ne peuvent
            // pas être séparés par un de nos propres accès (points 3 et 8).
            let outcome = await pasteboardAccess.write(text, expecting: saved?.changeCount)
            guard let self else { return }

            // Un collage plus récent est passé devant pendant l'attente : tout
            // ce qui suit lui appartient, on ne touche plus ni au
            // presse-papiers ni au clavier. L'appelant, lui, doit être libéré
            // quand même — le laisser sans réponse figerait sa machine à états
            // dans une phase de collage qui ne finirait jamais, ce qui est très
            // exactement le défaut qu'on est en train de corriger, à l'envers.
            guard pasteGeneration == generation else {
                whenLanded?(.clipboardOnly)
                return
            }

            if restoresClipboard, let saved {
                if outcome.expectationHeld {
                    pending = PendingRestore(
                        generation: generation,
                        items: saved.items,
                        writtenChangeCount: outcome.changeCount
                    )
                } else {
                    // Point 4 : quelqu'un a copié entre l'appui et maintenant,
                    // et le texte dicté vient de passer par-dessus. On ne rend
                    // pas l'instantané — il est plus vieux que ce qu'on détruit.
                    FeatureLog.record(
                        "presse-papiers : une copie faite pendant la dictée a été"
                        + " remplacée par le texte dicté, rien ne sera rendu"
                    )
                }
            }

            // Reposées ici, et pas seulement au départ : l'écriture a pu
            // attendre des secondes derrière une lecture bloquée, et la cible
            // comme la saisie sécurisée ont eu tout ce temps pour changer d'avis.
            // C'est pour ça que la valeur de retour et cette réponse-ci peuvent
            // diverger.
            guard willTry,
                  let target,
                  target.isTerminated == false,
                  HotkeyMonitor.isSecureInputActive == false
            else {
                whenLanded?(.clipboardOnly)
                return
            }

            // **Adjacente au ⌘V, pas au début du collage** (point 8). Les
            // 0,08 s qui suivent existent pour laisser le changement
            // d'application aboutir : sans eux le ⌘V part avant que la cible ait
            // le focus clavier et se perd. Les mettre du même côté que
            // l'écriture, c'est ce qui garantit qu'un collage tardif atterrit
            // dans la fenêtre du point 1 et pas dans la fenêtre du moment.
            target.activate()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                Self.sendCommandV()
                // Après le ⌘V, jamais avant : tant qu'il n'est pas parti, une
                // dictée suivante peut démarrer et son écriture doubler celui-ci.
                whenLanded?(.pasted)

                guard let self, restoresClipboard else { return }
                // Assez tard pour que la cible ait lu le presse-papiers, assez
                // tôt pour que l'utilisateur ne s'en aperçoive pas.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    self?.restoreClipboard(generation: generation)
                }
            }
        }

        return willTry
    }

    /// Place le texte dans le presse-papiers, sans coller.
    ///
    /// - Parameter whenLanded: appelé **une fois**, sur le main actor, quand le
    ///   texte est réellement au presse-papiers. Même règle qu'au collage : rien
    ///   ne doit annoncer « c'est copié » avant ce rappel, sinon l'utilisateur
    ///   entend le son de fin, fait ⌘V, et récupère le contenu précédent.
    ///   Facultatif — une copie depuis l'historique n'a rien à enchaîner.
    func copyOnly(_ text: String, whenLanded: (() -> Void)? = nil) {
        // Un geste explicite de l'utilisateur : ce qu'il vient de copier prime
        // sur tout ce que bran avait prévu de faire du presse-papiers. La
        // lecture en cours n'a plus d'objet, et une restitution en attente lui
        // passerait par-dessus dans les 600 ms.
        readTask?.cancel()
        readTask = nil
        pending = nil

        // Même passage par la file qu'au collage (point 8) et même
        // `prepareForNewContents(with:)` : `clearContents()` autoriserait la
        // diffusion du texte vers les autres appareils du compte iCloud
        // (point 5).
        //
        // La tâche hérite de l'isolation du main actor : le rappel revient donc
        // là où l'appelant l'attend, sans saut d'isolation à écrire.
        Task {
            _ = await pasteboardAccess.write(text, expecting: nil)
            whenLanded?()
        }
    }

    // MARK: - Presse-papiers

    /// Rend le presse-papiers à l'utilisateur — ou y renonce.
    ///
    /// Deux raisons d'y renoncer, et la première est celle qu'on oublie : ce
    /// minuteur n'appartient peut-être plus au collage en cours. Une seconde
    /// dictée a pu démarrer et écrire depuis, auquel cas le laissez-passer qu'on
    /// s'apprêtait à utiliser est le sien, pas le nôtre (point 3).
    ///
    /// La seconde raison — quelqu'un a copié entre le ⌘V et maintenant — est
    /// vérifiée par l'acteur, dans le même passage que l'écriture qu'elle
    /// autorise.
    ///
    /// Dans tous les cas la sauvegarde est relâchée, pour qu'aucune dictée
    /// suivante n'aille repêcher un contenu périmé.
    private func restoreClipboard(generation: Int) {
        guard let pending, pending.generation == generation else { return }
        self.pending = nil

        Task {
            await pasteboardAccess.restore(
                pending.items,
                ifChangeCountIs: pending.writtenChangeCount
            )
        }
    }

    // MARK: - Synthèse du ⌘V

    private static func sendCommandV() {
        // `cghidEventTap` et non `cgSessionEventTap` : injecté au niveau du
        // pilote, c'est le seul endroit où toutes les applications le voient,
        // y compris celles qui filtrent les événements de session.
        let source = CGEventSource(stateID: .hidSystemState)
        let keyCodeV: CGKeyCode = 9

        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCodeV, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCodeV, keyDown: false)
        else { return }

        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}

// MARK: - Le seul accès au presse-papiers

/// Une représentation du presse-papiers, réduite à des valeurs pures.
///
/// Pures, parce qu'un `NSPasteboardItem` est un mandataire vivant sur
/// `pasteboardd` : il n'est pas `Sendable`, et le faire traverser une frontière
/// d'isolation rejouerait le XPC du point 6 précisément là où on croyait s'en
/// être débarrassé.
private struct SavedRepresentation: Sendable {
    let type: String
    let data: Data
}

/// Un élément du presse-papiers, **dans l'ordre** où l'application source a
/// déclaré ses représentations (point 7).
private struct SavedItem: Sendable {
    let representations: [SavedRepresentation]
}

/// Ce qu'une lecture rapporte quand elle rapporte quelque chose.
///
/// `items` vide **est un résultat** : le presse-papiers était vide, et on saura
/// le rendre vide. Une lecture qui n'a rien de fiable à dire ne rend pas un
/// instantané vide, elle ne rend rien du tout (point 2).
private struct ClipboardSnapshot: Sendable {
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
private let pasteboardAccess = PasteboardAccess()

/// Le seul endroit du programme qui touche `NSPasteboard.general` (point 8).
private actor PasteboardAccess {

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
    @discardableResult
    func write(_ text: String, expecting expected: Int?) -> WriteOutcome {
        let pasteboard = NSPasteboard.general
        let held = expected != nil && pasteboard.changeCount == expected

        let written = pasteboard.prepareForNewContents(with: .currentHostOnly)
        pasteboard.setString(text, forType: .string)

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

        _ = pasteboard.prepareForNewContents(with: .currentHostOnly)
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
