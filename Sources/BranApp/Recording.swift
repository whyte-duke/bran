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

    /// Les morceaux bruts encore présents, `<uuid>-segNNN.mp4`, dans l'ordre.
    ///
    /// Normalement vide : le post-traitement les efface après avoir écrit le
    /// fichier final. Ils survivent quand la session s'est mal terminée — et
    /// c'est alors la seule chose qui existe de la réunion.
    var segmentURLs: [URL] = []

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

    /// Ce que « Afficher dans le Finder » doit sélectionner.
    ///
    /// **Un bouton qui ne fait rien est pire que pas de bouton.** Il passait
    /// `url` sans condition, c'est-à-dire le `<uuid>.mp4` final ; quand la
    /// session s'était mal terminée, ce fichier n'existait pas et
    /// `activateFileViewerSelecting` ne faisait strictement rien — pas une
    /// fenêtre, pas un message. Le 11 août 2026, la réunion était sur le disque
    /// sous son nom de segment et l'utilisateur cherchait un fichier que bran
    /// refusait de lui montrer, en silence.
    ///
    /// Dans l'ordre : le fichier final, les morceaux bruts, le dossier. Le
    /// dossier est le dernier recours et il ouvre toujours quelque chose.
    var revealTargets: [URL] {
        if existsOnDisk { return [url] }
        if segmentURLs.isEmpty == false { return segmentURLs }
        return [url.deletingLastPathComponent()]
    }

    /// Un fichier lisible existe, sous une forme ou une autre.
    var hasPlayableFile: Bool { existsOnDisk || segmentURLs.isEmpty == false }

    /// Ce que le lecteur ouvre.
    ///
    /// Le fichier final, ou à défaut le premier morceau brut. Une session mal
    /// terminée montrait un lecteur vide alors que la réunion était sur le
    /// disque : c'est le morceau qu'il faut lire, quitte à n'en lire qu'un —
    /// `segmentNotice` dit alors qu'il y en a d'autres.
    var playbackURL: URL? {
        if existsOnDisk { return url }
        return segmentURLs.first
    }

    /// Ce qu'il faut dire quand le lecteur ne montre pas le fichier attendu.
    var segmentNotice: String? {
        guard existsOnDisk == false, segmentURLs.isEmpty == false else { return nil }

        return segmentURLs.count == 1
            ? "La fusion n'a pas eu lieu : c'est le morceau brut de la session qui est lu ici."
            : "La fusion n'a pas eu lieu : c'est le premier des \(segmentURLs.count) morceaux bruts "
            + "qui est lu ici. Les autres sont à côté, dans le dossier."
    }

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
