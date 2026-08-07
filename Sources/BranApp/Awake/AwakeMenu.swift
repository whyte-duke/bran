import BranCore
import SwiftUI

/// L'éveil dans le menu de bran : **un interrupteur, une phrase, un sous-menu**.
///
/// ```
///   ☑ Garder le Mac éveillé                      ⌘E
///     Éveillé — encore 1 h 12.
///     Éveil pendant…                              ▸
/// ```
///
/// L'interrupteur d'abord, parce que c'est le geste : quatre-vingt-dix-neuf
/// fois sur cent on vient allumer ou éteindre, pas choisir une durée. Le
/// sous-menu est là pour la centième, et il ne prend qu'une ligne tant qu'on ne
/// l'ouvre pas.
///
/// **La phrase d'état est affichée aussi quand l'éveil est éteint.** Un menu qui
/// ne dit rien dans l'état de repos oblige à interpréter une case à cocher : la
/// case dit ce qui est demandé, la phrase dit ce qui se passe. Sur une fonction
/// dont tout l'objet est un état invisible, ça vaut la ligne.
struct AwakeMenu: View {
    let awake: AwakeController

    var body: some View {
        Toggle(isOn: Binding(
            get: { awake.isOn },
            // Le `set` est ignoré : `toggle()` sait déjà ce que veut dire
            // « l'inverse », et il applique la durée par défaut au passage.
            set: { _ in awake.toggle() }
        )) {
            Text("Garder le Mac éveillé")
        }
        .keyboardShortcut("e")

        Text(awake.summary)

        Menu("Éveil pendant…") {
            ForEach(AwakeDuration.allCases) { duration in
                Button(duration.label) { awake.begin(duration) }
            }
        }
    }
}
