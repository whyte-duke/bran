import AppKit
import BranSpeech
import CoreGraphics
import Dispatch
import Foundation

/// Le collage du texte là où était le curseur.
///
/// Neuf détails font toute la différence entre « ça marche » et « ça marche
/// vraiment ». Les deux premiers se voient à la première dictée ; les sept
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
/// 9. **Une réponse finit toujours par arriver.** Les points 6 et 8 sont chacun
///    justes, et leur composition ne l'était pas. Le point 6 dit qu'une lecture
///    peut rester bloquée indéfiniment dans un XPC et que rien ne peut
///    l'interrompre — l'annulation lui épargne les représentations *suivantes*,
///    pas celle qui est en cours. Le point 8 dit que toute écriture passe
///    derrière elle sur la même file. Mis bout à bout : une application source
///    coincée retenait l'écriture, l'écriture retenait `whenLanded`, et
///    `whenLanded` retenait la machine à états de l'appelant. La dictée restait
///    en `.pasting` et la capture en `.copying` aussi longtemps que Mail ou
///    Photoshop ne répondait pas. C'est le blocage que la propagation de la
///    `Landing` avait été écrite pour supprimer, revenu par la sérialisation
///    ajoutée pour en supprimer un autre.
///
///    **On ne peut pas débloquer ce XPC. On peut arrêter de l'attendre.** Au
///    moment où l'écriture est postée, un minuteur de `PasteDeadline.grace`
///    part sur le main actor — sans rien attendre, c'est tout l'intérêt : une
///    attente sur le main actor échangerait un gel contre un autre. Le premier
///    des deux à se réveiller prend le jeton `PasteDeadline` et répond ; l'autre
///    se tait. Un seul `whenLanded`, jamais zéro.
///
///    **Et l'écriture perdante n'écrit pas.** Elle se réveillera, plus tard,
///    quand l'application source se débloquera. Écrire à ce moment-là poserait
///    dans le presse-papiers une dictée d'il y a deux minutes, par-dessus ce que
///    l'utilisateur a copié entre-temps, alors qu'on venait de lui dire qu'elle
///    n'était pas partie. C'est donc `.stalled`, le texte ne part pas, et il
///    n'est pas perdu pour autant : les deux appelants enregistrent leur entrée
///    dans l'historique *avant* de la livrer, et l'historique a un bouton
///    « copier ». `Paster.stalledNotice` dit exactement cela.
///
///    Le délai vit dans `BranSpeech` et non ici, avec les tests qui prouvent
///    qu'un seul des deux coureurs parle : `BranApp` n'a pas de cible de test,
///    et une politique de renoncement non prouvée est précisément le genre de
///    chose qui se remet à ne jamais expirer sans que rien ne le signale.
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
/// Le minuteur du point 9 part du même instant que l'écriture, sur le main
/// actor, et court en parallèle de tout ce que ce schéma montre à droite. Si
/// l'écriture n'a pas atteint la file au bout de `PasteDeadline.grace`, c'est
/// lui qui répond `.stalled` — et la file, quand elle se libère enfin, trouve le
/// jeton pris et n'écrit pas. Toute la branche de droite est alors abandonnée :
/// pas d'activation, pas de ⌘V, pas de restitution, parce qu'il n'y a rien à
/// restituer.
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
        /// **Le texte n'est nulle part.** Le presse-papiers n'a pas répondu dans
        /// le délai (point 9), l'écriture a été abandonnée, et elle n'aura pas
        /// lieu plus tard non plus.
        ///
        /// Un troisième cas et non une variante du second, parce que ce que le
        /// second raconte serait ici un mensonge : `.clipboardOnly` veut dire
        /// « c'est dans le presse-papiers, faites ⌘V », et faire ⌘V collerait
        /// ce qui s'y trouvait avant. La différence n'est pas de formulation,
        /// c'est celle entre un geste qui marche et un geste qui trompe.
        case stalled

        /// L'utilisateur a-t-il un ⌘V à faire lui-même ?
        ///
        /// La question que se posent les deux appelants, et la seule : elle évite
        /// à chacun de réécrire la comparaison — donc de se tromper de sens le
        /// jour où un troisième cas apparaîtra. Ce jour est arrivé avec
        /// `.stalled`, et la réponse est `false` : il n'y a rien à coller. Tout
        /// appelant qui posait déjà cette question-ci s'est trouvé juste sans
        /// rien changer, ce qui est exactement ce pour quoi elle existe.
        var needsManualPaste: Bool { self == .clipboardOnly }

        /// Le texte est-il au presse-papiers ?
        ///
        /// La question de tout ce qui *annonce* la fin : un son de réussite, une
        /// coche verte. `.stalled` est le seul cas où la réponse est non.
        var reachedClipboard: Bool { self != .stalled }

        /// Ce qu'il reste à dire à l'utilisateur, ou `nil` quand il n'y a rien à
        /// ajouter parce que tout s'est passé comme prévu.
        ///
        /// Ici et pas chez les appelants : c'est la même phrase pour la dictée
        /// et pour la capture, et le ternaire qu'ils écrivaient chacun de leur
        /// côté est très exactement ce qui aurait laissé l'un des deux dire
        /// « faites ⌘V » sur un collage qui n'a jamais atteint le presse-papiers.
        var notice: String? {
            switch self {
            case .pasted: nil
            case .clipboardOnly: Paster.fallbackNotice
            case .stalled: Paster.stalledNotice
            }
        }
    }

    /// Ce qu'un collage dépose dans le presse-papiers.
    ///
    /// **Deux formes, parce qu'il y a deux sortes d'appelants et qu'aucune des
    /// deux ne doit payer pour l'autre.** La dictée et la capture de texte
    /// produisent du texte, et rien d'autre : leur donner à construire des
    /// représentations les obligerait à savoir ce qu'est `public.utf8-plain-text`
    /// pour dire « voici une phrase ». Le panneau d'historique, lui, doit
    /// pouvoir recoller ce qui a été copié — une image, des fichiers, un texte
    /// enrichi avec sa mise en forme —, et un `String` ne peut pas porter ça.
    ///
    /// Une énumération plutôt qu'un protocole ou une fermeture d'écriture : les
    /// deux formes sont connues, closes, et c'est le presse-papiers qui décide
    /// de ce qu'il accepte, pas nous. Un protocole aurait ouvert une porte que
    /// personne ne demande et aurait laissé un appelant écrire lui-même sur
    /// `NSPasteboard.general`, ce que le point 8 interdit.
    ///
    /// `Sendable` parce que la valeur traverse la frontière du main actor vers
    /// la file série de `PasteboardAccess` — et elle ne le peut que parce que
    /// `SavedItem` est fait de valeurs pures. Un `NSPasteboardItem` dans ce
    /// tableau rejouerait le XPC du point 6 dans le mauvais domaine d'isolation.
    enum Payload: Sendable {
        /// Du texte brut, la charge utile de la dictée et de la capture.
        case text(String)

        /// Des représentations, **dans l'ordre de préférence** : l'application
        /// qui colle prend le premier type qu'elle comprend (point 7). Un
        /// élément par objet copié ; un texte enrichi est un seul élément à
        /// plusieurs représentations, trois fichiers sont trois éléments.
        ///
        /// Un tableau vide n'est pas écrit — voir
        /// `PasteboardAccess.write(_:expecting:claiming:)`, qui explique
        /// pourquoi vider le presse-papiers ne peut pas être la réponse à
        /// « colle ça ».
        case representations([SavedItem])

        /// L'écriture correspondante, sur la file de l'acteur.
        ///
        /// **Le seul endroit du programme où la forme de la charge utile est
        /// examinée.** Le collage et la copie sans collage passent tous les deux
        /// par ici, et c'est ce qui garantit qu'ils ne peuvent pas diverger sur
        /// ce qu'ils écrivent. Les deux gestes qui entourent l'écriture, eux, ne
        /// sont pas ici et ne doivent pas y être : la prise du jeton (point 9)
        /// et la comparaison du numéro de version (points 3 et 8) se font sur la
        /// file, dans le même passage que l'écriture qu'elles autorisent.
        ///
        /// Non isolée au main actor : une énumération imbriquée n'hérite pas de
        /// l'isolation de son parent en Swift 6, ce qui tombe bien — cette
        /// méthode n'a rien à faire sur le fil principal, elle ne fait que
        /// sauter vers la file série.
        fileprivate func write(
            expecting expected: Int?,
            claiming claim: PasteDeadline
        ) async -> PasteboardAccess.WriteOutcome? {
            switch self {
            case .text(let text):
                await pasteboardAccess.write(
                    text,
                    expecting: expected,
                    claiming: claim
                )
            case .representations(let items):
                await pasteboardAccess.write(
                    items,
                    expecting: expected,
                    claiming: claim
                )
            }
        }
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
    /// `nonisolated` : `Landing` est un type imbriqué, et en Swift 6 un type
    /// imbriqué n'hérite pas de l'isolation d'acteur de son parent. Sans ça,
    /// `Landing.notice` ne peut pas lire cette constante — qui n'est qu'une
    /// chaîne, et n'a aucune raison d'appartenir au fil principal.
    nonisolated static let fallbackNotice =
        "Le texte n'a pas pu être collé — il est dans le presse-papiers, faites ⌘V."

    /// Ce qu'on dit quand le presse-papiers lui-même n'a pas répondu (point 9).
    ///
    /// Trois choses à dire et pas une de moins. **Que ça a échoué** — sinon
    /// l'utilisateur fait ⌘V et colle autre chose. **Pourquoi** — sinon il
    /// recommence sa dictée, ce qui repartira dans la même file coincée.
    /// **Où est le texte** — parce qu'il y est : les deux appelants enregistrent
    /// leur entrée avant de la livrer, et c'est ce qui autorise à renoncer à
    /// l'écriture plutôt que de la laisser atterrir en retard.
    ///
    /// Pas de nom d'application coupable, même si on le connaît souvent : la
    /// lecture est faite à l'appui et le blocage se constate une dictée plus
    /// tard, sur une application qui n'est peut-être plus au premier plan.
    /// Accuser la mauvaise est pire que de ne pas accuser.
    /// `nonisolated` : `Landing` est un type imbriqué, et en Swift 6 un type
    /// imbriqué n'hérite pas de l'isolation d'acteur de son parent. Sans ça,
    /// `Landing.notice` ne peut pas lire cette constante — qui n'est qu'une
    /// chaîne, et n'a aucune raison d'appartenir au fil principal.
    nonisolated static let stalledNotice =
        "Le presse-papiers n'a pas répondu — le texte n'a pas été collé,"
        + " retrouvez-le dans l'historique."

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

    /// Place la charge utile dans le presse-papiers et la colle dans la cible.
    ///
    /// **La forme générale, et le seul chemin de collage du programme.** Elle
    /// s'appelait `paste(_ text: String, ...)` tant que ses deux seuls appelants
    /// produisaient du texte ; le panneau d'historique, lui, doit recoller des
    /// images et des fichiers. Ce qui a changé tient en une ligne : ce qu'on
    /// écrit. Tout ce qui suit l'écriture — la cible encore vivante, la saisie
    /// sécurisée, `activate()`, les 0,08 s, le ⌘V, `whenLanded`, la restitution
    /// conditionnelle — est resté **ici, en un seul exemplaire**. C'est là que
    /// sont les neuf points de l'en-tête, et une seconde copie de cette séquence
    /// aurait reproduit les neuf défauts qui les ont écrits, dans un fichier où
    /// personne n'aurait pensé à les chercher. `paste(_ text:whenLanded:)` est
    /// donc devenu un appel d'une ligne vers ici, et le chemin de la dictée est
    /// littéralement le code d'avant.
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
    /// - Parameter whenLanded: appelé **exactement une fois**, sur le main actor,
    ///   quand tout est terminé. Ni zéro ni deux : au pire il arrive
    ///   `PasteDeadline.grace` après l'appel, avec `.stalled`, parce que le
    ///   presse-papiers n'a pas répondu (point 9). Aucun appelant n'a donc à se
    ///   protéger d'une réponse qui ne viendrait pas, et aucun n'a de minuteur à
    ///   poser de son côté. Facultatif : un appelant qui n'a rien à enchaîner ne
    ///   doit pas avoir à écrire une fermeture vide.
    @discardableResult
    func paste(_ payload: Payload, whenLanded: ((Landing) -> Void)? = nil) -> Bool {
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

        // Le jeton du point 9. Deux coureurs le regardent : l'écriture, sur la
        // file série, et le minuteur juste en dessous, sur le main actor. Le
        // premier à le prendre répond à l'appelant ; l'autre se retire.
        let deadline = PasteDeadline()

        // **Posé avant l'écriture, et non attendu.** `asyncAfter` et non
        // `Task.sleep` : le sommeil vivrait dans une tâche héritant du main
        // actor, ce qui reste correct, mais `asyncAfter` dit sans ambiguïté que
        // personne n'attend — c'est la garantie de l'en-tête, le main actor ne
        // bloque jamais.
        DispatchQueue.main.asyncAfter(deadline: .now() + PasteDeadline.graceInSeconds) {
            guard deadline.claim() else { return }
            // Rien à défaire : `pending` n'est installé qu'au retour de
            // l'écriture, qui n'a pas eu lieu, et l'instantané a déjà été
            // consommé ci-dessus. Le presse-papiers, lui, n'a pas été touché —
            // c'est même tout ce que `.stalled` veut dire.
            FeatureLog.record(
                "presse-papiers : aucune réponse en \(PasteDeadline.graceInSeconds) s"
                + " (application source bloquée) — l'écriture est abandonnée,"
                + " le texte reste dans l'historique"
            )
            whenLanded?(.stalled)
        }

        Task { [weak self] in
            // `expecting:` fait comparer le numéro de version *sur la file*,
            // juste avant d'écrire — le seul endroit où « le presse-papiers
            // n'a pas bougé depuis la lecture » et « je l'écris » ne peuvent
            // pas être séparés par un de nos propres accès (points 3 et 8).
            //
            // `claiming:` est pris au même endroit et pour la même raison : la
            // décision d'écrire et l'écriture doivent être indissociables. Prise
            // ici, la course avec le minuteur se jouerait entre les deux.
            //
            // La forme de la charge utile est tranchée dans `Payload.write` et
            // pas ici : c'est la seule ligne que le texte et les représentations
            // n'avaient pas en commun, et tout ce qui suit leur appartient aux
            // deux.
            let outcome = await payload.write(
                expecting: saved?.changeCount,
                claiming: deadline
            )
            // Le minuteur a parlé le premier et a déjà répondu `.stalled` :
            // l'écriture n'a pas eu lieu, il n'y a rien à restituer, rien à
            // coller, et surtout pas un second `whenLanded` à envoyer.
            guard let outcome else { return }

            // Le texte *est* au presse-papiers. Si `Paster` a disparu entre
            // temps, l'appelant doit quand même l'apprendre : sans cette
            // réponse-ci, un `Paster` libéré pendant l'écriture laisserait sa
            // machine à états figée — le défaut du point 9, par une autre porte.
            guard let self else {
                whenLanded?(.clipboardOnly)
                return
            }

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
                // **Relâcher n'est pas rendre.** Le minuteur de restitution
                // n'est posé que sur le chemin du ⌘V ; ici il n'y en aura pas,
                // et la sauvegarde installée juste au-dessus n'a plus personne
                // pour la consommer. Elle restait donc en place jusqu'au collage
                // suivant, qui la trouvait et la rendait — au nom d'un collage
                // qui n'avait jamais eu lieu, par-dessus un presse-papiers dont
                // l'utilisateur s'était peut-être servi entre-temps.
                //
                // Ne *pas* restituer est le bon comportement et reste le
                // comportement : le texte est au presse-papiers et l'utilisateur
                // a encore son ⌘V à faire, le lui reprendre serait un sabotage.
                // Ce qu'on jette n'est pas le service rendu, c'est une intention
                // devenue sans objet.
                releasePendingRestore(generation: generation)
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

                guard let self else { return }
                // La même porte que ci-dessus, en plus étroite : le réglage a pu
                // basculer pendant les 0,08 s. La sauvegarde a été installée
                // sous l'ancien réglage et n'aura plus de minuteur ; la laisser
                // en place, c'est la promettre au collage suivant.
                guard restoresClipboard else {
                    releasePendingRestore(generation: generation)
                    return
                }
                // Assez tard pour que la cible ait lu le presse-papiers, assez
                // tôt pour que l'utilisateur ne s'en aperçoive pas.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    self?.restoreClipboard(generation: generation)
                }
            }
        }

        return willTry
    }

    /// Place le **texte** dans le presse-papiers et le colle dans la cible.
    ///
    /// Le chemin de la dictée et de la capture de texte, mot pour mot celui
    /// d'avant : une seule ligne, qui emballe la chaîne et appelle la forme
    /// générale. Il n'y a rien à lire ici, tout est dans
    /// `paste(_:whenLanded:)` — y compris les deux réponses du point 8, dont la
    /// valeur de retour que cette surcharge se contente de faire suivre.
    ///
    /// **Elle existe pour que les appelants n'aient pas à changer.** Leur faire
    /// écrire `paste(.text(texte))` aurait été une modification mécanique de
    /// deux fichiers, sans le moindre gain : ils n'ont qu'une forme de charge
    /// utile à offrir, et la leur faire nommer à chaque appel n'aurait fait
    /// qu'ajouter du bruit à des sites d'appel déjà denses. Elle a aussi une
    /// valeur de preuve : tant qu'elle est là, la dictée ne peut pas dériver de
    /// la forme générale sans qu'on le voie ici.
    @discardableResult
    func paste(_ text: String, whenLanded: ((Landing) -> Void)? = nil) -> Bool {
        paste(.text(text), whenLanded: whenLanded)
    }

    /// Place la charge utile dans le presse-papiers, sans coller.
    ///
    /// La même généralisation qu'au collage et pour le même appelant : le
    /// panneau d'historique a besoin de « copier sans coller » sur une image
    /// comme sur un texte, et ce bouton-là serait le seul du panneau à ne
    /// marcher que sur la moitié des entrées. La forme s'y applique
    /// naturellement — il n'y a ici ni cible, ni ⌘V, ni restitution, donc rien
    /// que la charge utile puisse compliquer : le seul geste est l'écriture, et
    /// c'est précisément celui que `Payload` sait faire des deux façons.
    ///
    /// - Parameter whenLanded: appelé **exactement une fois**, sur le main actor.
    ///   Même règle qu'au collage : rien ne doit annoncer « c'est copié » avant
    ///   ce rappel, sinon l'utilisateur entend le son de fin, fait ⌘V, et
    ///   récupère le contenu précédent. Le paramètre est `false` quand le
    ///   presse-papiers n'a pas répondu dans le délai et que l'écriture a été
    ///   abandonnée (point 9) — c'est le `.stalled` du collage, réduit au seul
    ///   bit qui ait un sens ici puisqu'il n'y a jamais eu de ⌘V à envoyer.
    ///   Ce chemin-là avait le même trou que l'autre : sans réponse, la capture
    ///   restait en `.copying` indéfiniment. Facultatif — une copie depuis
    ///   l'historique n'a rien à enchaîner.
    func copyOnly(_ payload: Payload, whenLanded: ((Bool) -> Void)? = nil) {
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

        // Le même jeton et le même minuteur qu'au collage (point 9), pour la
        // même raison : la file peut être occupée par une lecture bloquée, et
        // une copie qui ne répond jamais fige l'appelant tout autant qu'un
        // collage qui ne répond jamais. `copyOnly` n'a pas de ⌘V à envoyer, donc
        // pas de troisième issue à distinguer : écrit, ou pas écrit.
        let deadline = PasteDeadline()

        DispatchQueue.main.asyncAfter(deadline: .now() + PasteDeadline.graceInSeconds) {
            guard deadline.claim() else { return }
            FeatureLog.record(
                "presse-papiers : aucune réponse en \(PasteDeadline.graceInSeconds) s"
                + " sur une copie — l'écriture est abandonnée"
            )
            whenLanded?(false)
        }

        Task {
            // `expecting: nil` : une copie explicite ne restitue rien, donc il
            // n'y a aucun numéro de version à faire tenir. Et la forme de la
            // charge utile est tranchée dans `Payload.write`, au même endroit
            // que pour le collage — c'est ce qui interdit aux deux chemins
            // d'écrire différemment ce que l'appelant leur a donné.
            let written = await payload.write(expecting: nil, claiming: deadline)
            // Le minuteur a renoncé le premier : il a déjà répondu `false`, et
            // rien n'a été écrit.
            guard written != nil else { return }
            whenLanded?(true)
        }
    }

    /// Place le **texte** dans le presse-papiers, sans coller.
    ///
    /// Le chemin de la capture de texte et des deux boutons « copier » de
    /// l'historique, inchangé : une ligne qui emballe la chaîne. Même raison
    /// d'exister que la surcharge jumelle du collage — les appelants qui n'ont
    /// que du texte à offrir n'ont pas à le nommer.
    func copyOnly(_ text: String, whenLanded: ((Bool) -> Void)? = nil) {
        copyOnly(.text(text), whenLanded: whenLanded)
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
    /// Jette la sauvegarde de **ce** collage-ci, sans rien rendre.
    ///
    /// La vérification du numéro d'ordre n'est pas une précaution de style :
    /// entre l'écriture et ce point, un collage plus récent a pu s'installer, et
    /// sa sauvegarde à lui a un minuteur qui l'attend. La jeter le priverait de
    /// sa restitution, ce qui est le défaut d'à côté, à l'envers.
    private func releasePendingRestore(generation: Int) {
        guard pending?.generation == generation else { return }
        pending = nil
    }

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

    /// Synthétise le ⌘V — **signé**, pour que le guet de bran le reconnaisse et
    /// n'y réponde pas.
    ///
    /// Injecté au niveau du pilote (`cghidEventTap` et non `cgSessionEventTap`)
    /// parce que c'est le seul endroit où toutes les applications le voient, y
    /// compris celles qui filtrent les événements de session. Le revers, mesuré :
    /// **le tap de session de bran le voit aussi**. Sans marque, il suffirait
    /// qu'un utilisateur règle un raccourci sur ⌘V pour que chaque collage de
    /// dictée déclenche la fonction correspondante — bran se répondant à
    /// lui-même, une fois par dictée, indéfiniment.
    ///
    /// La marque est posée sur **chacun des deux** événements et non sur la
    /// source : `HotkeyMonitor.receive` lit un événement à la fois, et un
    /// relâchement non marqué serait aussi mal interprété qu'un appui. Voir
    /// `SyntheticEventTag` pour la mesure du champ et pour ce qui a été écarté.
    private static func sendCommandV() {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyCodeV: CGKeyCode = 9

        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCodeV, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCodeV, keyDown: false)
        else { return }

        down.flags = .maskCommand
        up.flags = .maskCommand
        down.setIntegerValueField(.eventSourceUserData, value: SyntheticEventTag.value)
        up.setIntegerValueField(.eventSourceUserData, value: SyntheticEventTag.value)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
