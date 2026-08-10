import AppKit

/// La fenêtre que bran pose **au-dessus de tout le reste**, et le seul endroit
/// où ses réglages sont décidés.
///
/// Il y en a deux dans l'application : l'encoche de la dictée et de la capture,
/// et la pilule du veilleur. Les deux avaient recopié la même configuration à la
/// main, à une propriété près.
///
/// C'est le motif exact qui a justifié la création du target `BranWindows` :
/// `CGWindowListCopyWindowInfo` existait en cinq exemplaires, et un `internal`
/// ne pouvait pas les réunir parce que deux exécutables les portaient. Ici c'est
/// le même exécutable, donc il n'y avait même pas cette excuse. Neuf lignes
/// dupliquées, c'est neuf occasions qu'une des deux dérive sans que rien ne le
/// dise — et une fenêtre qui perd `.canJoinAllSpaces` ne se remarque que le jour
/// où quelqu'un travaille sur un second bureau.
///
/// **Chaque réglage est ici parce qu'il a été payé**, et le commentaire dit par
/// quoi. Ce n'est pas une liste de valeurs par défaut recopiées d'un exemple.
///
/// ## Deux familles de panneaux
///
/// `make` construit un **afficheur d'état** : il ne prend jamais le clavier, il
/// se pose au-dessus de la barre de menus, et il reste là pendant que bran n'a
/// aucun focus. C'est l'encoche et la pilule.
///
/// `makeFocusable` construit un **sélecteur** : il prend le clavier *sans* que
/// bran passe au premier plan, il se range sous la barre de menus, et il est
/// fait pour être ouvert puis refermé dans la seconde. C'est le presse-papiers.
///
/// Le fond commun — transparence, comportement multi-bureaux, absence d'ombre —
/// est le même pour les deux et n'est écrit qu'une fois, dans `configure`. Ce
/// qui diffère est un paramètre explicite, jamais une valeur par défaut.
enum OverlayPanel {

    // MARK: - L'afficheur d'état

    /// Construit un panneau qui montre un état et ne prend jamais le clavier.
    ///
    /// `acceptsMouse` est ce qui distingue **les deux appelants d'aujourd'hui**
    /// — l'encoche et la pilule d'attention — et c'est un paramètre plutôt
    /// qu'une valeur par défaut pour que le prochain lecteur voie que c'est un
    /// choix. Ce n'est plus la seule ligne de partage du fichier pour autant :
    /// depuis `makeFocusable`, la vraie frontière passe entre les panneaux qui
    /// affichent et celui qui reçoit des touches, et elle emporte avec elle le
    /// niveau de fenêtre, la capacité à devenir clé, et qui décide de la
    /// fermeture.
    ///
    /// - L'encoche refuse la souris : elle n'a aucun contrôle, elle affiche un
    ///   état, et intercepter un clic destiné à la fenêtre du dessous serait un
    ///   défaut pur.
    /// - La pilule d'attention l'accepte, parce que le clic **est** le produit :
    ///   c'est le geste de retour. Le tri de ce qui est cliquable se fait dans le
    ///   `hitTest` de sa vue, pas ici — le panneau est bien plus grand que la
    ///   capsule qu'il porte.
    static func make(frame: NSRect, content: NSView, acceptsMouse: Bool) -> NSPanel {
        let panel = NSPanel(
            contentRect: frame,
            // `.nonactivatingPanel` : ni afficher l'état de la dictée, ni
            // signaler qu'une machine attend ne doit voler le focus à
            // l'application où l'on est en train d'écrire.
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        configure(panel, content: content, acceptsMouse: acceptsMouse)

        // Au-dessus de la barre de menus. Sans ça, le panneau passe **dessous**
        // sur un écran à encoche, donc devient invisible exactement sur le
        // matériel pour lequel il a été dessiné.
        panel.level = .init(Int(CGShieldingWindowLevel()))

        // Un panneau qui disparaît quand bran perd le focus serait invisible en
        // permanence : bran n'a le focus presque jamais, et c'est le but.
        panel.hidesOnDeactivate = false

        panel.orderFrontRegardless()
        return panel
    }

    // MARK: - Le sélecteur

    /// Construit un panneau qui **reçoit les touches sans que bran passe devant**.
    ///
    /// ## Ce qui a été mesuré, et pas supposé
    ///
    /// Une sonde jetable (hors dépôt) a ouvert ce panneau exact au-dessus de
    /// TextEdit, vérifié que TextEdit était bien l'application de premier plan,
    /// puis posté de vraies touches par `CGEvent(…).post(tap: .cghidEventTap)` —
    /// donc par le chemin d'un clavier physique, pas par un envoi direct à la
    /// fenêtre. Résultats :
    ///
    /// - `NSPanel[.borderless, .nonactivatingPanel]` non sous-classé :
    ///   `canBecomeKey == false`. C'est bien la bordure absente qui bloque, et
    ///   il n'y a pas d'autre remède que la sous-classe.
    /// - Sous-classé : `isKeyWindow == true`, la vue de texte devient premier
    ///   répondant, et les caractères tapés **arrivent dans le champ**.
    /// - Pendant tout ce temps `NSWorkspace.shared.frontmostApplication` a
    ///   continué de désigner TextEdit. **La cible de collage survit.** C'est le
    ///   fait sur lequel repose tout le panneau du presse-papiers.
    /// - `NSApp.isActive` passe à `true`, lui. C'est une activation au sens
    ///   d'AppKit seulement, sans changement de premier plan au sens du système.
    ///   Elle est utile : voir la fermeture, plus bas.
    /// - Quand une autre application s'active vraiment, le panneau **rend la clé
    ///   tout seul** et les touches suivantes repartent chez elle. Il n'y a pas
    ///   de fenêtre clé fantôme qui continuerait d'avaler la frappe.
    /// - `hidesOnDeactivate` n'empêche pas de devenir clé : les deux valeurs ont
    ///   été essayées côte à côte, `isKeyWindow == true` dans les deux cas.
    ///
    /// **Un piège observé.** Dans un essai où un *autre* panneau sans bordure
    /// était ordonné devant au même niveau juste avant, la demande de clé a
    /// échoué **en silence** : `isKeyWindow == false`, aucune erreur. La cause
    /// exacte n'a pas été isolée. L'appelant a donc intérêt à ne pas réordonner
    /// une autre surface dans le même tour de boucle, et à vérifier
    /// `panel.isKeyWindow` s'il tient à savoir.
    ///
    /// - Parameter initialResponder: la vue qui doit recevoir la frappe. Elle
    ///   est posée **ici**, parce que l'ordre compte : `makeFirstResponder`
    ///   avant que la fenêtre soit clé ne sert à rien, et c'est précisément le
    ///   genre de séquence que ce fichier existe pour ne pas laisser recopier.
    ///   `makeKeyAndOrderFront` est aussi la seule forme éprouvée — `makeKey`
    ///   seul a été mesuré insuffisant depuis une application inactive.
    static func makeFocusable(
        frame: NSRect,
        content: NSView,
        initialResponder: NSView? = nil
    ) -> NSPanel {
        let panel = FocusableOverlayPanel(
            contentRect: frame,
            // Même masque que l'afficheur d'état, et pour une raison plus forte
            // encore : ouvrir le sélecteur ne doit pas changer l'application de
            // premier plan, sinon la cible du collage — la seule chose que le
            // presse-papiers ait à viser — disparaît au moment où on l'ouvre.
            // C'est la sous-classe, pas le masque, qui rend la clé possible.
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // Un sélecteur se pilote au clavier **et** à la souris : on y clique une
        // entrée. Pas de paramètre, donc, contrairement à `make` — il n'y a pas
        // de sélecteur qui se voudrait transparent aux clics.
        configure(panel, content: content, acceptsMouse: true)

        // **`.floating`, pas `CGShieldingWindowLevel()`.**
        //
        // Le niveau de bouclier existe pour l'encoche : sur un écran à encoche
        // elle doit passer *au-dessus* de la barre de menus, sans quoi elle est
        // invisible sur le matériel pour lequel elle est dessinée. Un sélecteur
        // n'a pas ce besoin, et hériter du même niveau lui ferait recouvrir la
        // barre de menus et l'horloge pendant tout le temps où il est ouvert —
        // pour une fenêtre qui vit au milieu de l'écran, c'est du dégât pur.
        //
        // `.floating` (3) flotte au-dessus des fenêtres ordinaires de *toutes*
        // les applications — les niveaux sont globaux — donc au-dessus de celle
        // dans laquelle on va coller, tout en restant sous la barre de menus
        // (24). C'est exactement la place d'un sélecteur.
        panel.level = .floating

        // **`false`, comme l'afficheur d'état, mais pour une autre raison.**
        //
        // Pour l'encoche, `false` est ce qui la rend visible du tout. Pour un
        // sélecteur, on pourrait croire que `true` est le bon réglage : il doit
        // effectivement disparaître dès que l'utilisateur va ailleurs. C'est le
        // bon effet obtenu par le mauvais moyen.
        //
        // `hidesOnDeactivate` **cache la fenêtre sans rien dire à personne**. Le
        // contrôleur continuerait de croire son sélecteur ouvert : la frappe de
        // raccourci suivante basculerait contre un état périmé, et le travail de
        // fermeture — rendre la main, oublier la sélection, relâcher ce qui a
        // été retenu — ne serait jamais fait. Le panneau serait parti de l'écran
        // et toujours là dans le modèle.
        //
        // La sonde donne au contrôleur mieux que ça : ouvrir le sélecteur rend
        // `NSApp.isActive` vrai, donc partir ailleurs déclenche un vrai
        // `didResignActive`. Il y a un événement à écouter ; il faut l'écouter,
        // pas laisser AppKit escamoter la fenêtre en douce.
        panel.hidesOnDeactivate = false

        // L'ordre mesuré : devant et clé d'abord, premier répondant ensuite.
        panel.makeKeyAndOrderFront(nil)
        if let initialResponder {
            panel.makeFirstResponder(initialResponder)
        }
        return panel
    }

    // MARK: - Le fond commun

    /// Ce que les deux familles partagent. Écrit une seule fois : c'est la
    /// raison d'être du fichier.
    private static func configure(_ panel: NSPanel, content: NSView, acceptsMouse: Bool) {
        panel.contentView = content
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false

        panel.ignoresMouseEvents = acceptsMouse == false
        panel.acceptsMouseMovedEvents = acceptsMouse

        // `.canJoinAllSpaces` : les panneaux d'état disent quelque chose sur la
        // machine, qui ne change pas quand on change de bureau virtuel ; et le
        // sélecteur doit s'ouvrir sur le bureau où l'on est, pas sur celui où il
        // a été construit. `.stationary` les empêche de glisser pendant la
        // transition Mission Control, où un panneau qui suit le mouvement paraît
        // décollé.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    }
}

// MARK: - La sous-classe

/// **La première sous-classe de fenêtre du dépôt, et elle n'existe que pour deux
/// lignes.**
///
/// Une `NSWindow` sans bordure répond `false` à `canBecomeKey`, et c'est une
/// propriété calculée en lecture seule : il n'y a aucun réglage, aucun masque et
/// aucun appel qui la retourne depuis l'extérieur. `OverlayPanel.make` rendait un
/// `NSPanel` nu, donc il n'y avait littéralement pas d'endroit où l'écrire. D'où
/// ce type, gardé aussi petit que possible — tout le reste de la configuration
/// est resté dans `OverlayPanel`, là où on va le chercher.
private final class FocusableOverlayPanel: NSPanel {

    /// Mesuré : sans cette ligne, `false`, et le champ de texte ne reçoit rien.
    /// Avec, la fenêtre devient clé pendant que
    /// `NSWorkspace.shared.frontmostApplication` continue de désigner
    /// l'application où l'on écrit.
    override var canBecomeKey: Bool { true }

    /// **Volontairement `false`.**
    ///
    /// La fenêtre principale est celle dont l'application possède la barre de
    /// menus et le titre. Un sélecteur qui la deviendrait ferait remplacer la
    /// barre de menus de l'application où l'on travaille par celle de bran :
    /// exactement le vol d'attention que `.nonactivatingPanel` sert à éviter,
    /// repris par une autre porte.
    ///
    /// Ce n'est pas un renoncement : la sonde confirme que principale et clé
    /// sont indépendantes. Avec `canBecomeMain == false`, `NSApp.mainWindow`
    /// reste `nil`, et la frappe arrive quand même.
    override var canBecomeMain: Bool { false }
}

// MARK: - La fermeture au clic dehors
//
// **Elle n'est pas ici, et c'est une décision.** Pas de type non plus : il n'y
// aurait rien à mettre dedans, et une coquille vide se remplirait un jour du
// mauvais côté de la frontière.
//
// Aucun des panneaux ne se ferme aujourd'hui sur un clic à l'extérieur. Pour
// l'encoche et la pilule c'est correct : elles affichent un état, et un état ne
// se congédie pas — il cesse quand ce qu'il décrit cesse. Pour un sélecteur
// c'est indispensable : une liste de presse-papiers qui reste posée au milieu de
// l'écran après qu'on est parti ailleurs est un défaut.
//
// Le réflexe serait de mettre ce comportement dans `FocusableOverlayPanel`,
// puisque c'est « une propriété du sélecteur ». Il appartient au **contrôleur**,
// pour trois raisons :
//
// 1. **Le panneau ne sait pas ce que « fermer » veut dire.** Le sélecteur du
//    presse-papiers a un état à défaire : la cible de collage retenue, la
//    sélection courante, le raccourci qui l'a ouvert et qui doit redevenir un
//    ouvrant. `orderOut` n'est que le dernier geste de cette séquence ; une
//    fenêtre qui se retirerait elle-même laisserait son propriétaire persuadé
//    d'être encore ouvert — la faute même que `hidesOnDeactivate = true` aurait
//    commise plus haut.
//
// 2. **Le signal est global, donc il a un cycle de vie.**
//    `NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, …])` rend un
//    jeton qu'il faut retirer, et il se déclenche pour *tous* les clics de la
//    session, y compris ceux qui atterrissent sur les autres surfaces de bran.
//    Seul le contrôleur sait lesquels sont légitimes. Une ressource à durée de
//    vie et à politique n'a pas sa place dans une fonction de construction qui,
//    par ailleurs, rend un objet et l'oublie.
//
// 3. **La moitié du travail est déjà faite par le système, et gratuitement.**
//    Mesuré : quand une autre application s'active, le panneau rend la clé de
//    lui-même et bran reçoit `NSApplication.didResignActiveNotification` — le
//    sélecteur devenant clé rend bran actif au sens d'AppKit, donc s'en aller
//    est un vrai événement. Ce cas-là ne demande qu'un observateur.
//
//    Le moniteur global ne sert qu'à ce que la notification ne couvre pas : le
//    clic qui reste **dans** l'application déjà au premier plan, laquelle ne
//    s'« active » pas puisqu'elle y est. Le moniteur a été vérifié fonctionnel
//    depuis une application accessoire inactive — mais il exige la confiance
//    Accessibilité, que bran a déjà pour tout le reste, et qu'il faut compter
//    comme une dépendance et non comme un acquis.
