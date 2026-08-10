import BranCore
import Foundation
import SwiftUI

/// Un enregistrement tel que la bibliothèque l'affiche : les métadonnées
/// persistées, plus les faits lus sur le disque au moment du scan.
struct Recording: Identifiable, Equatable, Sendable {
    var metadata: RecordingMetadata
    var url: URL
    var fileSize: Int64
    var duration: TimeInterval?
    var existsOnDisk: Bool

    /// `false` quand le `.json` est absent — fichier antérieur à la
    /// bibliothèque, ou sidecar supprimé à la main.
    var hasMetadataFile: Bool

    var id: UUID { metadata.id }

    /// Session ouverte sans jamais être close proprement.
    ///
    /// La distinction avec « pas de sidecar du tout » est importante : sans
    /// elle, tous les anciens fichiers seraient signalés comme interrompus,
    /// et un avertissement qui se déclenche toujours n'avertit plus de rien.
    var wasInterrupted: Bool {
        hasMetadataFile && metadata.endedAt == nil
    }

    /// Le motif de l'interruption, **seulement s'il a été écrit**.
    ///
    /// `nil` pour tout ce qui a été enregistré avant que le champ existe, et
    /// c'est le cas le plus courant de la bibliothèque : la ligne doit alors
    /// dire ce qu'elle sait — la session ne s'est pas close — sans inventer un
    /// « motif inconnu ».
    var interruptionDetail: String? {
        wasInterrupted ? metadata.interruptionDetail : nil
    }

    /// L'infobulle du triangle. Porte le motif quand il existe.
    var interruptionNote: String { metadata.interruptionNote }

    /// Le titre du calendrier s'il existe, sinon la date formatée **maintenant**
    /// — dans la langue et le fuseau de celui qui regarde, pas de celui qui a
    /// enregistré.
    var displayTitle: String {
        if let title = metadata.title, title.isEmpty == false { return title }
        return metadata.startedAt.formatted(date: .abbreviated, time: .shortened)
    }

    var durationDescription: String {
        guard let duration else { return "—" }
        let total = Int(duration.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60

        return hours > 0
            ? "\(hours) h \(String(format: "%02d", minutes))"
            : "\(minutes) min \(String(format: "%02d", seconds)) s"
    }

    var sizeDescription: String {
        fileSize.formatted(.byteCount(style: .file))
    }

    var originalSizeDescription: String? {
        metadata.originalBytes?.formatted(.byteCount(style: .file))
    }

    /// « −58 % » quand la compression a fait gagner quelque chose de visible.
    /// Rien en dessous de 5 % : afficher « −2 % » donnerait l'impression que la
    /// passe n'a servi à rien, alors qu'elle a surtout recollé les morceaux.
    var savingDescription: String? {
        guard let original = metadata.originalBytes, original > 0, fileSize > 0 else { return nil }
        let saved = 1 - Double(fileSize) / Double(original)
        guard saved >= 0.05 else { return nil }
        return "−\((saved * 100).formatted(.number.precision(.fractionLength(0)))) %"
    }

    var segmentCount: Int { metadata.segmentCount ?? 1 }

    /// Pastille d'état CRM dans la liste. Elle ne dit qu'une chose : où en est
    /// ce closing côté Castral.
    var crmBadge: (text: String, symbol: String, color: Color)? {
        guard metadata.transcriptionID != nil else { return nil }

        return switch metadata.crmStage {
        case "ready":
            metadata.crmWarning == nil
                ? ("compte-rendu prêt", "checkmark.seal.fill", .green)
                : ("transcrit, sans compte-rendu", "exclamationmark.triangle.fill", .orange)
        case "failed":
            ("échec CRM", "xmark.seal.fill", .red)
        case nil:
            nil
        default:
            ("traitement en cours", "arrow.triangle.2.circlepath", .secondary)
        }
    }

    /// Ordre de grandeur du coût horaire, utile pour juger un réglage de qualité.
    var rateDescription: String? {
        guard let duration, duration > 60 else { return nil }
        let gigabytesPerHour = Double(fileSize) / duration * 3600 / 1_073_741_824
        return "\(gigabytesPerHour.formatted(.number.precision(.fractionLength(1)))) Go/h"
    }
}
