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
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let entries = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }

        let mine = ProcessInfo.processInfo.processIdentifier
        return entries.contains { entry in
            guard let owner = entry[kCGWindowOwnerPID as String] as? Int32, owner != mine else {
                return false
            }
            guard let title = entry[kCGWindowName as String] as? String else { return false }
            return title.isEmpty == false
        }
    }

    /// Ce que le système déclare, qui peut être faux dans le sens permissif.
    static var isDeclaredGranted: Bool { CGPreflightScreenCaptureAccess() }

    /// Le verdict utilisé avant d'ouvrir le viseur.
    ///
    /// Les deux sondes doivent être d'accord. Le désaccord — déclaré accordé
    /// mais aucun titre lisible — est précisément le cas d'une autorisation
    /// accordée à une **ancienne signature** du binaire.
    static var isUsable: Bool { isDeclaredGranted && canSeeOtherWindows }

    /// Le diagnostic à afficher quand ce n'est pas utilisable.
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
