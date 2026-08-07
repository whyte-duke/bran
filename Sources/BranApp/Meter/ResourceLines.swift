import BranCore
import SwiftUI

/// Les lignes du moniteur, **dans le menu de bran**. On ne dit que ce qui coûte.
///
/// ```
///   Processeur      2 %   · 0,2 % des 12 cœurs
///   Mémoire       335 Mo  · 2 % des 16 Go
///   ───────────────────────────────────────
///   bran est au repos.
/// ```
///
/// **Elles vivaient dans un second élément de barre de menus, elles n'y vivent
/// plus.** L'argument d'origine était solide et il tenait en une phrase : le
/// libellé de bran porte le chrono pendant un enregistrement et « à l'écoute »
/// pendant une dictée, donc les deux moments où la consommation monte étaient
/// exactement les deux moments où le chiffre aurait disparu. Ce qu'il ne pesait
/// pas, c'est le prix permanent de la solution : deux icônes bran côte à côte
/// dans une barre de menus qui en compte déjà quinze, pour une information qu'on
/// consulte une fois par semaine. La demande de l'utilisateur a tranché — un
/// seul endroit — et le compromis est explicite : le chiffre reste dans le
/// libellé **au repos**, il cède la place aux événements, et le panneau
/// déroulant, lui, l'affiche toujours.
///
/// **Pourquoi les lignes d'état apparaissent et disparaissent.** Au repos,
/// quatre lignes qui disent toutes « rien ne se passe » sont du bruit permanent :
/// on cesse de les lire en une semaine, et le jour où l'une d'elles a quelque
/// chose à dire, elle est déjà invisible. Une ligne qui n'apparaît que
/// lorsqu'elle a une nouvelle est une ligne qu'on lit.
///
/// **Pourquoi les deux colonnes ne s'alignent pas au pixel.** Un `MenuBarExtra`
/// de style menu est un `NSMenu` : ses éléments sont des chaînes dans la police
/// système, sans colonnes ni chasse fixe. Le remplissage ci-dessous rapproche
/// les valeurs sans prétendre à un tableau — prétendre le contraire demanderait
/// une vue personnalisée dans un menu, ce qui casse le survol, le clavier et
/// VoiceOver pour un gain d'un demi-cadratin.
struct ResourceLines: View {
    let meter: ResourceMeter

    var body: some View {
        Text("Processeur\(Self.gap)\(meter.cpuText)  ·  \(meter.cpuShareText) des \(meter.coresText)")
        Text("Mémoire\(Self.gap)\(meter.memoryText)  ·  \(meter.memoryShareText) de \(meter.installedMemoryText)")

        let activities = meter.activities()
        if activities.isEmpty {
            // La phrase entière, pas « — » : c'est une bonne nouvelle, et une
            // bonne nouvelle se dit.
            Text("bran est au repos.")
        } else {
            ForEach(activities) { activity in
                Text("\(activity.title)\(Self.gap)\(activity.detail)")
            }
        }

        Button("Masquer la consommation") {
            meter.showsInMenuBar = false
        }
    }

    /// L'écart entre un libellé et sa valeur. Une espace cadratin : la plus
    /// large que la police système offre sans se transformer en tabulation
    /// approximative.
    private static let gap = "\u{2003}\u{2003}"
}
