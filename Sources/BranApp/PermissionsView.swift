import SwiftUI

struct PermissionsView: View {
    @Bindable var permissions: PermissionsService

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Autorisations")
                    .font(.title2.weight(.semibold))
                Text("bran a besoin de deux autorisations pour enregistrer, et d'une troisième pour nommer les réunions.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 12) {
                PermissionRow(
                    title: "Enregistrement de l'écran",
                    explanation: "Capture l'image, et donne accès aux titres de fenêtres qui servent à détecter les réunions.",
                    access: permissions.screenRecording,
                    isRequired: true
                ) {
                    permissions.requestScreenRecording()
                }

                PermissionRow(
                    title: "Microphone",
                    explanation: "Enregistre votre voix. Sans elle, on n'entend que les autres participants.",
                    access: permissions.microphone,
                    isRequired: true
                ) {
                    await permissions.requestMicrophone()
                }

                PermissionRow(
                    title: "Calendrier",
                    explanation: "Donne son titre et ses participants à l'enregistrement. Facultatif.",
                    access: permissions.calendar,
                    isRequired: false
                ) {
                    await permissions.requestCalendar()
                }
            }

            if permissions.screenRecording != .granted {
                Text("L'autorisation d'enregistrement d'écran n'est prise en compte qu'au prochain démarrage de bran. Quittez et relancez l'app après l'avoir accordée.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("Revérifier") { permissions.refresh() }
            }
        }
        .padding(24)
        .frame(minWidth: 420)
        .onAppear { permissions.refresh() }
    }
}

#Preview("Aucune autorisation") {
    PermissionsView(permissions: PermissionsService())
}
