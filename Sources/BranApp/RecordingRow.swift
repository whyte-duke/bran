import SwiftUI

struct RecordingRow: View {
    let recording: Recording

    /// Fraction de 0 à 1 pendant la fusion et la compression, `nil` sinon.
    var progress: Double?

    /// État de l'envoi au CRM, `nil` si aucun envoi n'est en cours.
    var upload: UploadState?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.tight) {
            Text(recording.displayTitle)
                .font(Type.cardTitle)
                .lineLimit(1)

            if let progress {
                ProgressView(value: progress) {
                    Text("Fusion et compression…")
                } currentValueLabel: {
                    Text(progress, format: .percent.precision(.fractionLength(0)))
                }
                .progressViewStyle(.linear)
                .font(Type.meta)
                .tint(.accentColor)
            } else if let upload, upload.isFinished == false {
                uploadRow(upload)
            } else {
                facts
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    @ViewBuilder
    private func uploadRow(_ upload: UploadState) -> some View {
        if let fraction = upload.fraction {
            ProgressView(value: fraction) {
                Text(upload.description)
            }
            .progressViewStyle(.linear)
            .font(Type.meta)
        } else {
            HStack(spacing: Space.tight) {
                ProgressView().controlSize(.small)
                Text(upload.description)
            }
            .font(Type.meta)
            .foregroundStyle(.secondary)
        }
    }

    private var facts: some View {
        HStack(spacing: Space.small) {
            Text(recording.metadata.startedAt, format: .dateTime.hour().minute())
            Text("·")
            Text(recording.durationDescription)
            Text("·")
            Text(recording.sizeDescription)

            if let saving = recording.savingDescription {
                Text("·")
                Text(saving)
                    .foregroundStyle(Palette.done)
                    .help("Poids avant compression : \(recording.originalSizeDescription ?? "—")")
            }

            if let stage = recording.crmBadge {
                Text("·")
                Label(stage.text, systemImage: stage.symbol)
                    .foregroundStyle(stage.color)
                    .labelStyle(.titleAndIcon)
            }

            if recording.wasInterrupted {
                Text("·")
                // Le fichier est presque toujours lisible — replayd le finalise
                // même si bran meurt — mais le signaler évite de croire à tort
                // que tout s'est bien passé.
                Label("interrompue", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Palette.attention)
                    .labelStyle(.iconOnly)
                    .help("Session jamais close proprement.")
            }
        }
        .font(Type.meta)
        .foregroundStyle(.secondary)
    }

    private var accessibilityDescription: String {
        if let progress {
            let percent = (progress * 100).formatted(.number.precision(.fractionLength(0)))
            return "\(recording.displayTitle), compression en cours, \(percent) pour cent"
        }
        return "\(recording.displayTitle), \(recording.durationDescription), \(recording.sizeDescription)"
    }
}

#Preview {
    List {
        RecordingRow(recording: .preview)
        RecordingRow(recording: .preview, progress: 0.42)
        RecordingRow(recording: .preview, upload: .uploading(0.6))
    }
    .frame(width: 320)
}

extension Recording {
    static var preview: Recording {
        Recording(
            metadata: .init(
                id: UUID(),
                startedAt: .now.addingTimeInterval(-3600),
                endedAt: .now,
                title: "Point hebdo produit",
                meetCode: "abc-defg-hij",
                attendees: ["alice@example.com"]
            ),
            url: URL(fileURLWithPath: "/tmp/preview.mp4"),
            fileSize: 2_400_000_000,
            duration: 2_730,
            existsOnDisk: true,
            hasMetadataFile: true
        )
    }
}
