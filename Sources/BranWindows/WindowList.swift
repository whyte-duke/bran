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

    /// Le cadre de la fenêtre en coordonnées d'écran.
    public let frame: CGRect

    /// La couche de composition. 0 est celle des fenêtres ordinaires ; les
    /// palettes flottantes, les info-bulles et les panneaux d'alerte vivent
    /// au-dessus.
    public let layer: Int

    /// Faux pour une fenêtre minimisée, masquée, ou sur un autre bureau.
    ///
    /// Toujours vrai dans le résultat d'`onScreen`, qui ne rend que celles-là ;
    /// c'est `all()` qui donne à ce champ son intérêt.
    public let isOnScreen: Bool

    /// Cette fenêtre accepte-t-elle d'être capturée ?
    ///
    /// `kCGWindowSharingState` vaut `kCGWindowSharingNone` pour les fenêtres
    /// qu'une application déclare non partageable — gestionnaires de mots de
    /// passe, lecteurs de vidéo protégée. C'est le critère que
    /// `SCShareableContent` applique lui-même avant de rendre sa liste : qui
    /// remplace cette énumération par celle-ci doit le reprendre, sinon il
    /// hérite de fenêtres qu'aucune capture ne pourra jamais rendre.
    public let isShareable: Bool

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
        enumerate([.optionOnScreenOnly, .excludeDesktopElements], titled: titled)
    }

    /// **Toutes** les fenêtres, y compris celles qui ne sont pas à l'écran.
    ///
    /// Une fenêtre minimisée reste une fenêtre : elle porte un travail, et la
    /// faire disparaître d'une liste de voies reviendrait à dire que le travail
    /// n'existe plus. Elle ne se capture jamais pour autant — le compositeur
    /// n'en a plus les pixels — d'où `isOnScreen`, que l'appelant lit pour
    /// décider, plutôt qu'une seconde énumération.
    public static func all(titled: Bool = true) -> [ListedWindow] {
        enumerate([.optionAll, .excludeDesktopElements], titled: titled)
    }

    private static func enumerate(
        _ options: CGWindowListOption, titled: Bool
    ) -> [ListedWindow] {
        guard let entries = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        return entries.compactMap { entry -> ListedWindow? in
            let title = entry[kCGWindowName as String] as? String ?? ""
            guard titled == false || title.isEmpty == false else { return nil }
            guard let pid = entry[kCGWindowOwnerPID as String] as? pid_t else { return nil }

            // `kCGWindowBounds` est un dictionnaire sérialisé, pas un `CGRect` :
            // il se relit avec la fonction qu'Apple fournit pour ça, et jamais
            // en lisant ses clés à la main — leur nom n'est pas contractuel.
            //
            // Le passage par `NSDictionary` est un pont, pas une conversion
            // forcée : ce code s'exécute sur chaque fenêtre de la machine à
            // chaque tic du veilleur, et un `as!` y ferait tomber l'application
            // le jour où le serveur de fenêtres rendrait autre chose. Un cadre
            // absent donne `.zero`, que les filtres de taille écartent
            // d'eux-mêmes.
            var frame = CGRect.zero
            if let bounds = entry[kCGWindowBounds as String] as? NSDictionary {
                frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) ?? .zero
            }

            return ListedWindow(
                windowID: CGWindowID(entry[kCGWindowNumber as String] as? UInt32 ?? 0),
                processID: pid,
                ownerName: entry[kCGWindowOwnerName as String] as? String,
                title: title,
                frame: frame,
                layer: entry[kCGWindowLayer as String] as? Int ?? 0,
                isOnScreen: entry[kCGWindowIsOnscreen as String] as? Bool ?? false,
                // Absent, on suppose partageable : c'est le cas de l'immense
                // majorité des fenêtres, et supposer l'inverse ferait disparaître
                // des voies réelles sur une clé manquante.
                isShareable: (entry[kCGWindowSharingState as String] as? Int
                    ?? Int(CGWindowSharingType.readOnly.rawValue))
                    != Int(CGWindowSharingType.none.rawValue)
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
