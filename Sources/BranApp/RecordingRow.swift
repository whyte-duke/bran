import BranCore
import SwiftUI

struct RecordingRow: View {
    let recording: Recording

    /// L'étape de la chaîne de fin qui tourne sur cet enregistrement, `nil` quand
    /// il n'y en a aucune.
    ///
    /// **Une étape, et plus une fraction.** La ligne recevait un `Double?` et
    /// écrivait « Fusion et compression… » au-dessus, quelle que soit l'étape
    /// réelle : l'extraction de l'audio pour le CRM s'annonçait comme une
    /// compression vidéo, et la finalisation ne s'annonçait pas du tout puisque
    /// `replayd` ne rapporte aucune fraction. Le nom de ce qui tourne vient
    /// désormais de `SessionProgress`, comme dans la barre et dans le menu.
    var step: SessionProgress?

    /// État de l'envoi au CRM, `nil` si aucun envoi n'est en cours.
    var upload: UploadState?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.tight) {
            Text(recording.displayTitle)
                .font(Type.cardTitle)
                .lineLimit(1)

            if let step {
                stageRow(step)
            } else if let upload, upload.isFinished == false {
                uploadRow(upload)
            } else {
                facts
            }
        }
        // 3 points ne sont sur aucune échelle : `Space.tight` en vaut 4, et le
        // point d'écart ne se voit pas sur une ligne posée dans une carte qui a
        // déjà son propre rembourrage.
        .padding(.vertical, Space.tight)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    /// La même figure que dans la barre de session, à la taille d'une ligne :
    /// une jauge quand l'étape se mesure, une roue quand elle ne se mesure pas.
    ///
    /// La finalisation est le cas qui impose la seconde forme. Elle dure le tiers
    /// de la réunion et n'offre rien à mesurer ; une jauge à 0 % pendant douze
    /// minutes se lit comme un blocage, alors qu'une roue qui tourne dit ce qui
    /// est vrai — ça travaille, on ne sait pas jusqu'où.
    @ViewBuilder
    private func stageRow(_ step: SessionProgress) -> some View {
        if let fraction = step.fraction {
            ProgressView(value: fraction) {
                Text(step.title)
            } currentValueLabel: {
                Text(fraction, format: .percent.precision(.fractionLength(0)))
            }
            .progressViewStyle(.linear)
            .font(Type.meta)
            .tint(.accentColor)
            .branAnimation(Motion.state, value: fraction)
        } else {
            HStack(spacing: Space.tight) {
                ProgressView().controlSize(.small)
                Text(step.title)
            }
            .font(Type.meta)
            .foregroundStyle(.secondary)
        }
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
                //
                // Le motif est écrit sur la ligne quand on l'a. Un triangle seul
                // renvoie à un bandeau qui a peut-être disparu depuis une heure ;
                // « finalisation impossible : délai dépassé » se lit sur place.
                // Sans motif — les enregistrements antérieurs au champ — la ligne
                // dit « interrompue » et rien de plus : c'est exactement ce
                // qu'elle sait.
                Label(
                    recording.interruptionDetail ?? "interrompue",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(Palette.attention)
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(recording.interruptionNote)
            }
        }
        .font(Type.meta)
        .foregroundStyle(.secondary)
    }

    /// **Les deux choses qui manquaient étaient exactement les deux qui
    /// comptent.**
    ///
    /// `children: .combine` rassemblait la ligne, puis cette description la
    /// remplaçait par titre, durée et poids — en perdant l'avertissement
    /// « interrompue » et l'état CRM. Or ce sont les seuls éléments qui
    /// appellent une action : un enregistrement interrompu mérite qu'on vérifie
    /// le fichier, et un envoi en échec mérite qu'on le relance. Le reste est du
    /// contexte.
    ///
    /// L'« interrompue » était par-dessus le marché posé en `.iconOnly` : une
    /// icône seule, sans étiquette, donc muette pour tout le monde. Elle porte
    /// désormais son texte, et son motif quand il y en a un — ici comme à
    /// l'écran, on ne dit du motif que ce qui a été écrit.
    private var accessibilityDescription: String {
        // `summary` est la phrase d'une seule ligne de `SessionProgress` — celle
        // du menu — et c'est exactement ce qu'il faut ici : l'étape nommée, son
        // pourcentage s'il existe, sans les points de suspension qui se lisent
        // mal à voix haute. Recomposer la phrase sur place la ferait diverger de
        // celle qui s'affiche, et personne ne le remarquerait.
        if let step {
            return "\(recording.displayTitle), \(step.summary)"
        }

        var parts = [
            recording.displayTitle,
            recording.durationDescription,
            recording.sizeDescription,
        ]
        if recording.wasInterrupted {
            if let detail = recording.interruptionDetail {
                parts.append("session interrompue, jamais close proprement, \(detail)")
            } else {
                parts.append("session interrompue, jamais close proprement")
            }
        }
        if let stage = recording.crmBadge {
            parts.append(stage.text)
        }
        return parts.joined(separator: ", ")
    }
}

#Preview {
    List {
        RecordingRow(recording: .preview)
        // Les deux formes d'une étape : mesurable, et pas mesurable.
        RecordingRow(
            recording: .preview,
            step: SessionProgress(stage: .merging, fraction: 0.42, elapsed: .seconds(120))
        )
        RecordingRow(
            recording: .preview,
            step: SessionProgress(stage: .finalizing, bytesWritten: 1_200_000_000, recorded: .seconds(2_191))
        )
        RecordingRow(recording: .preview, upload: .uploading(0.6))
        // Les deux façons d'être interrompue : avec le motif, et — pour tout ce
        // qui date d'avant le champ — sans.
        RecordingRow(recording: .previewInterrupted(reason: "finalisation impossible : délai dépassé"))
        RecordingRow(recording: .previewInterrupted(reason: nil))
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

    /// Une session que rien n'a close : pas de `endedAt`, avec ou sans motif.
    static func previewInterrupted(reason: String?) -> Recording {
        var metadata = RecordingMetadata(
            id: UUID(),
            startedAt: .now.addingTimeInterval(-1800),
            title: "Closing Dupont"
        )
        metadata.interruptionReason = reason

        return Recording(
            metadata: metadata,
            url: URL(fileURLWithPath: "/tmp/preview-interrupted.mp4"),
            fileSize: 800_000_000,
            duration: 1_500,
            existsOnDisk: true,
            hasMetadataFile: true
        )
    }
}
