import BranCore
import SwiftUI

/// Les réglages de l'éveil, dans « Général ».
///
/// **Pas un huitième onglet**, et la raison est la même que pour la
/// consommation, qui vit déjà ici : quatre contrôles ne font pas un écran. Un
/// onglet par fonction se défend quand la fonction a un modèle à télécharger, un
/// raccourci à capturer et une rétention à régler — la dictée, la capture, le
/// veilleur. L'éveil a un interrupteur et une durée.
struct AwakeSettingsSection: View {
    @Bindable var model: AppModel

    private var awake: AwakeController { model.awake }

    var body: some View {
        Section("Éveil") {
            Toggle("Garder le Mac éveillé", isOn: Binding(
                get: { awake.isOn },
                set: { _ in awake.toggle() }
            ))

            // L'état réel, sous l'interrupteur qui dit l'intention. Sur une
            // fonction dont tout l'objet est invisible, la phrase vaut la ligne
            // — et pendant une session minutée, c'est elle qui décompte.
            Text(awake.summary)
                .font(Type.meta)
                .foregroundStyle(.secondary)

            Picker("Durée par défaut", selection: Binding(
                get: { model.awakeSettings.defaultDuration },
                set: { model.awakeSettings.defaultDuration = $0 }
            )) {
                ForEach(AwakeDuration.allCases) { duration in
                    Text(duration.label).tag(duration)
                }
            }

            Text("Ce qu'un clic sur « Garder le Mac éveillé » déclenche. « Sans limite » par défaut : un clic allume, un second éteint. Choisir une durée ici ne change pas le geste, seulement ce qu'il applique — et le sous-menu « Éveil pendant… » reste disponible pour une durée ponctuelle.")
                .font(Type.meta)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Activer l'éveil au lancement de bran", isOn: Binding(
                get: { model.awakeSettings.startsAtLaunch },
                set: { model.awakeSettings.startsAtLaunch = $0 }
            ))

            Toggle("Arrêter quand le Mac est mis en veille", isOn: Binding(
                get: { model.awakeSettings.stopsOnManualSleep },
                set: { model.awakeSettings.stopsOnManualSleep = $0 }
            ))

            // **Ce que la fonction ne fait pas, dit avant qu'on le découvre.**
            // Une assertion d'énergie n'empêche que la veille par inactivité :
            // fermer le capot endort la machine quoi qu'on demande, et aucune
            // API publique ne le contredit. Le taire ferait passer un
            // comportement du matériel pour un bogue de bran.
            Text("bran demande au gestionnaire d'énergie de ne pas éteindre l'écran par inactivité — ce qui empêche aussi la veille automatique et l'économiseur d'écran. Refermer le capot endort le Mac malgré tout. L'assertion est visible de l'extérieur : `pmset -g assertions` la liste au nom de bran.")
                .font(Type.meta)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
