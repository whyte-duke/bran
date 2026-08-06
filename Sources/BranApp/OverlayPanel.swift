import AppKit

/// La fenêtre que bran pose **au-dessus de tout le reste**, et le seul endroit
/// où ses neuf réglages sont décidés.
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
enum OverlayPanel {

    /// Construit le panneau. `acceptsMouse` est la **seule** chose qui distingue
    /// les deux appelants aujourd'hui, et elle est un paramètre plutôt qu'une
    /// valeur par défaut pour que le prochain lecteur voie que c'est un choix.
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

        panel.contentView = content
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false

        // Au-dessus de la barre de menus. Sans ça, le panneau passe **dessous**
        // sur un écran à encoche, donc devient invisible exactement sur le
        // matériel pour lequel il a été dessiné.
        panel.level = .init(Int(CGShieldingWindowLevel()))

        panel.ignoresMouseEvents = acceptsMouse == false
        panel.acceptsMouseMovedEvents = acceptsMouse

        // `.canJoinAllSpaces` : les deux panneaux disent quelque chose sur l'état
        // de la machine, qui ne change pas quand on change de bureau virtuel.
        // `.stationary` les empêche de glisser pendant la transition Mission
        // Control, où un panneau qui suit le mouvement paraît décollé.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        // Un panneau qui disparaît quand bran perd le focus serait invisible en
        // permanence : bran n'a le focus presque jamais, et c'est le but.
        panel.hidesOnDeactivate = false

        panel.orderFrontRegardless()
        return panel
    }
}
