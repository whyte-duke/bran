import BranWindows
import CoreGraphics
import Foundation

/// Savoir si bran voit réellement l'écran.
///
/// **`CGPreflightScreenCaptureAccess()` ne suffit pas, et c'est le piège qui a
/// coûté une soirée.** Il peut répondre « oui » alors que toute capture rend le
/// fond d'écran, fenêtres retirées. On obtient alors une image parfaitement
/// valide, de la bonne taille, sans un caractère dedans — et l'application
/// annonce « Aucun texte trouvé » pour ce qui est en réalité une case à cocher
/// dans les Réglages système.
///
/// La sonde fiable est ailleurs : **`kCGWindowName` n'est renseigné qu'avec
/// l'autorisation effectivement accordée à la signature courante**. C'est déjà
/// ce dont dépend `WindowTitleDetector` pour repérer les fenêtres Meet. Si bran
/// ne lit aucun titre de fenêtre, il ne capturera rien d'utile non plus.
///
/// Le cas qui déclenche ça en pratique : l'autorisation est liée à la signature
/// du binaire. Reconstruire l'application avec un certificat régénéré la fait
/// silencieusement perdre, alors que la case reste cochée dans les Réglages.
enum ScreenAccess {

    /// Vrai quand bran lit au moins un titre de fenêtre appartenant à une autre
    /// application.
    ///
    /// On exige une fenêtre **d'une autre application** : bran voit toujours ses
    /// propres titres, autorisation ou non, et s'en contenter rendrait la sonde
    /// systématiquement positive.
    static var canSeeOtherWindows: Bool {
        let mine = ProcessInfo.processInfo.processIdentifier
        // `WindowList.onScreen()` écarte déjà les fenêtres sans titre : il ne
        // reste qu'à vérifier qu'au moins une appartient à quelqu'un d'autre.
        return WindowList.onScreen().contains { $0.processID != mine }
    }

    /// Ce que le système déclare, qui peut être faux dans le sens permissif.
    static var isDeclaredGranted: Bool { CGPreflightScreenCaptureAccess() }

    /// **Trois états, parce qu'il y en a trois — et en confondre deux
    /// refusait la capture à des gens qui y avaient droit.**
    ///
    /// Le désaccord entre les deux sondes — déclaré accordé, mais aucun titre
    /// lisible — était traité comme un refus. C'est bien le symptôme d'une
    /// autorisation accordée à une ancienne signature. Ce n'est pas le seul :
    /// `WindowList.onScreen()` écarte les fenêtres **sans titre**, donc un
    /// bureau où toutes les autres applications sont réduites, ou une session
    /// où bran est seul au premier plan, ne fournit aucun témoin non plus.
    ///
    /// Dans ce cas, l'utilisateur recevait un refus catégorique assorti d'une
    /// procédure de suppression et de réajout de bran dans les Réglages
    /// système — pour une autorisation parfaitement valide. On ne peut pas
    /// distinguer les deux causes **avant** la capture ; on le peut très bien
    /// après, en regardant ce qu'elle a rendu.
    ///
    /// D'où : ne bloquer que ce qui est certain, et laisser le doute passer.
    enum Verdict: Equatable {
        /// Les deux sondes sont d'accord.
        case usable
        /// Le système lui-même refuse. Aucune capture ne servira à rien.
        case blocked
        /// Déclaré accordé, aucun témoin pour le confirmer. Peut être une
        /// autorisation périmée, peut être un bureau vide. **Tenter, puis
        /// classer le résultat** — voir `SnapshotController.beginSelection`.
        case unconfirmed
    }

    static var verdict: Verdict {
        if isDeclaredGranted == false { return .blocked }
        return canSeeOtherWindows ? .usable : .unconfirmed
    }

    /// « Rien ne prouve que c'est impossible. »
    ///
    /// Volontairement permissif : le doute ne doit pas fermer la porte. Les
    /// écrans de réglages s'en servent pour décider s'il faut afficher un
    /// avertissement, et un avertissement affiché à tort sur une autorisation
    /// saine coûte plus cher qu'un avertissement manqué — il envoie retirer et
    /// rajouter bran dans les Réglages système sans raison.
    static var isUsable: Bool { verdict != .blocked }

    /// Le diagnostic à afficher quand ce n'est pas utilisable, ou quand une
    /// capture faite dans le doute (`.unconfirmed`) n'a rien rendu.
    static var diagnosis: String {
        if isDeclaredGranted == false {
            return """
            bran n'a pas l'autorisation d'enregistrement de l'écran. Réglages \
            système › Confidentialité et sécurité › Enregistrement de l'écran, \
            puis cochez bran.
            """
        }
        return """
        L'autorisation d'enregistrement de l'écran est cochée, mais elle a été \
        accordée à une version antérieure de bran : macOS la lie à la signature \
        du binaire, et reconstruire l'application la périme sans décocher la \
        case. Dans Réglages système › Confidentialité et sécurité › \
        Enregistrement de l'écran, retirez bran avec le bouton « − », puis \
        rajoutez-le et relancez-le.
        """
    }
}
