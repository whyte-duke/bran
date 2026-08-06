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
    /// 26 — la pilule de l'encoche, sur les écrans qui n'en ont pas.
    static let pill: CGFloat = 26
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

    /// Un panneau encastré : tuile de fait, éditeur de notes, bandeau.
    static let well = AnyShapeStyle(.quinary)

    /// La sélection dans la colonne. `.selection` porte déjà la vibrance, le
    /// contraste, et l'état « fenêtre non active » que le blanc codé en dur
    /// ignorait.
    static let selection = AnyShapeStyle(.selection)

    /// Les états. **Les seules couleurs littérales autorisées**, et elles sont
    /// ici pour qu'on puisse les compter.
    static let live = Color.red
    static let held = Color.orange
    static let done = Color.green
    static let attention = Color.orange
    static let broken = Color.red
    static let asleep = Color.secondary
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

    /// Le temps que met l'encoche à se refermer — **et donc le temps qu'il faut
    /// attendre avant de retirer la fenêtre.**
    ///
    /// `NotchOverlay.hide()` posait 380 ms écrits en dur pendant que le ressort
    /// qui les justifie vivait ici. Deux fichiers pour un seul mouvement : régler
    /// le ressort sans toucher l'attente fait disparaître le panneau au milieu de
    /// sa propre fermeture, et aucun test ne peut le voir.
    static let notchCollapse: Duration = .milliseconds(380)

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
