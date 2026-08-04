import SwiftUI

struct PermissionRow: View {
    let title: String
    let explanation: String
    let access: PermissionsService.Access
    let isRequired: Bool
    let request: () async -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbolName)
                .foregroundStyle(symbolColor)
                .font(.title3)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(.headline)
                    if isRequired == false {
                        Text("facultative")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if access != .granted {
                Button("Accorder") {
                    Task { await request() }
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10))
        // Une ligne = une information pour VoiceOver, pas quatre fragments.
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(accessibilityStatus)")
        .accessibilityHint(explanation)
    }

    private var symbolName: String {
        switch access {
        case .granted: "checkmark.circle.fill"
        case .denied: "xmark.circle.fill"
        case .notDetermined: "circle.dashed"
        }
    }

    private var symbolColor: Color {
        switch access {
        case .granted: .green
        case .denied: .red
        case .notDetermined: .secondary
        }
    }

    private var accessibilityStatus: String {
        switch access {
        case .granted: "accordée"
        case .denied: "refusée"
        case .notDetermined: "non accordée"
        }
    }
}

#Preview {
    VStack(spacing: 12) {
        PermissionRow(
            title: "Enregistrement de l'écran",
            explanation: "Capture l'image, et donne accès aux titres de fenêtres.",
            access: .granted,
            isRequired: true
        ) {}

        PermissionRow(
            title: "Microphone",
            explanation: "Enregistre votre voix.",
            access: .notDetermined,
            isRequired: true
        ) {}

        PermissionRow(
            title: "Calendrier",
            explanation: "Donne son titre à l'enregistrement.",
            access: .denied,
            isRequired: false
        ) {}
    }
    .padding()
    .frame(width: 440)
}
