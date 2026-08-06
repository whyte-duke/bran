import SwiftUI

/// Ce qui touche l'enregistrement d'une réunion.
///
/// Une seule décision aujourd'hui — la qualité — mais elle mérite son propre
/// onglet : c'est le seul réglage qu'on ne peut plus changer une fois la
/// réunion commencée, et le noyer entre le démarrage et la dictée le rendait
/// introuvable au moment où on le cherche.
struct MeetingSettingsSection: View {
    @Bindable var model: AppModel

    var body: some View {
        Section("Qualité d'enregistrement") {
            Picker("Qualité", selection: $model.quality) {
                ForEach(QualityPreset.allCases) { preset in
                    VStack(alignment: .leading) {
                        Text(preset.label)
                        Text(preset.estimatedRate).foregroundStyle(.secondary)
                    }
                    .tag(preset)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .disabled(model.isRecording)

            Text("Le débit dépend du contenu : un écran figé coûte presque rien, une visio animée coûte le maximum. Ces valeurs sont des ordres de grandeur mesurés sur une vraie réunion.")
                .font(Type.meta)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if model.isRecording {
                Text("Modification impossible pendant un enregistrement : changer la configuration d'un flux actif l'interrompt.")
                    .font(Type.meta)
                    .foregroundStyle(Palette.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
