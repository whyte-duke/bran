import BranCore
import SwiftUI

/// Le panneau déroulant du moniteur. **On ne dit que ce qui coûte.**
///
/// ```
///   Processeur      2 %   · 0,2 % des 12 cœurs
///   Mémoire       335 Mo  · 2 % des 16 Go
///   ───────────────────────────────────────
///   bran est au repos.
///   ───────────────────────────────────────
///   Ouvrir bran…
/// ```
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
struct ResourceMenu: View {
    let meter: ResourceMeter
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text("Processeur\(Self.gap)\(meter.cpuText)  ·  \(meter.cpuShareText) des \(meter.coresText)")
        Text("Mémoire\(Self.gap)\(meter.memoryText)  ·  \(meter.memoryShareText) de \(meter.installedMemoryText)")

        Divider()

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

        Divider()

        Button("Ouvrir bran…", systemImage: "macwindow") {
            WindowPresenter.bringToFront("library", using: openWindow)
        }

        Button("Masquer ce compteur") {
            meter.showsInMenuBar = false
        }
    }

    /// L'écart entre un libellé et sa valeur. Une espace cadratin : la plus
    /// large que la police système offre sans se transformer en tabulation
    /// approximative.
    private static let gap = "\u{2003}\u{2003}"
}
