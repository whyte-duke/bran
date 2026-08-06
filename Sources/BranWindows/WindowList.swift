import AppKit
import CoreGraphics
import Foundation

/// Une fenêtre telle que `CGWindowListCopyWindowInfo` la décrit.
///
/// Les quatre champs bruts sont copiés à l'énumération ; l'identifiant de paquet
/// ne l'est **pas**, parce qu'il coûte une résolution `NSRunningApplication` par
/// fenêtre et que la plupart des appelants ne le demandent jamais. Le laisser en
/// propriété calculée fait payer ce coût à ceux qui s'en servent, et à eux seuls.
public struct ListedWindow: Sendable {
    public let windowID: CGWindowID
    public let processID: pid_t
    /// Le nom de l'application propriétaire, tel que le serveur de fenêtres le
    /// donne. `nil` quand il ne le donne pas — plutôt qu'un « ? » inventé ici,
    /// que chaque appelant afficherait sans savoir d'où il vient.
    public let ownerName: String?
    /// Vide quand `kCGWindowName` n'est pas renseigné — ce qui est le cas de
    /// **toutes** les fenêtres sans l'autorisation Enregistrement de l'écran.
    public let title: String

    public var bundleIdentifier: String? {
        NSRunningApplication(processIdentifier: processID)?.bundleIdentifier
    }
}

/// **L'énumération des fenêtres du système, en un seul endroit.**
///
/// Le même bloc de dix lignes — les mêmes options, la même conversion en
/// `[[String: Any]]`, les mêmes quatre clés `kCGWindow*` — existait en cinq
/// exemplaires dans deux exécutables différents. Un `internal` n'y suffisait
/// pas : `BranApp` et `BranSpike` sont deux cibles distinctes. D'où cette
/// cible-ci.
///
/// **Elle n'est pas de la logique pure et ne prétend pas l'être** : elle touche
/// AppKit et CoreGraphics, et son résultat dépend d'une autorisation système.
/// Ce qu'elle offre n'est pas de la testabilité, c'est de n'avoir qu'un seul
/// endroit à corriger le jour où Apple change ces API — et un seul endroit où
/// lire ce que « fenêtre » veut dire dans bran.
///
/// **`kCGWindowName` n'est renseigné qu'avec l'autorisation Enregistrement de
/// l'écran.** Sans elle, l'énumération réussit et tous les titres sont vides :
/// c'est ce que `ScreenAccess` exploite comme sonde d'autorisation, et c'est
/// aussi pourquoi aucun appelant ne doit lire une liste vide comme « aucune
/// fenêtre ouverte ».
public enum WindowList {

    /// Les fenêtres à l'écran, hors éléments de bureau, dans l'ordre de
    /// superposition — la première est celle du dessus.
    ///
    /// - Parameter titled: écarte les fenêtres sans titre. C'est le cas courant,
    ///   parce qu'une fenêtre sans titre n'est ni nommable ni identifiable. Le
    ///   passer à `false` sert à qui cherche une fenêtre par son processus et
    ///   non par son nom : filtrer les titres décalerait alors la réponse d'une
    ///   fenêtre.
    public static func onScreen(titled: Bool = true) -> [ListedWindow] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let entries = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        return entries.compactMap { entry -> ListedWindow? in
            let title = entry[kCGWindowName as String] as? String ?? ""
            guard titled == false || title.isEmpty == false else { return nil }
            guard let pid = entry[kCGWindowOwnerPID as String] as? pid_t else { return nil }

            return ListedWindow(
                windowID: CGWindowID(entry[kCGWindowNumber as String] as? UInt32 ?? 0),
                processID: pid,
                ownerName: entry[kCGWindowOwnerName as String] as? String,
                title: title
            )
        }
    }

    /// La première fenêtre de l'application au premier plan.
    ///
    /// L'ordre de superposition suffit : la fenêtre du dessus appartenant au
    /// processus actif *est* celle que l'humain regarde. Aucune API
    /// d'accessibilité, donc aucune autorisation de plus.
    public static func frontmost(titled: Bool = true) -> ListedWindow? {
        guard let front = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            return nil
        }
        return onScreen(titled: titled).first { $0.processID == front }
    }
}
