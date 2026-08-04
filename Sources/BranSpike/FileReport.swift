import AVFoundation
import Foundation

/// Verdict objectif sur le fichier produit.
///
/// Le critère de réussite du plan (« on entend les participants, on s'entend
/// soi-même ») est un jugement à l'oreille. Le nombre de pistes audio, lui, est
/// mesurable : si le `.mp4` contient DEUX pistes audio, QuickTime ne jouera que
/// la première et l'utilisateur ne s'entendra pas — le critère échoue même si
/// les deux flux ont bien été capturés.
enum FileReport {
    static func print(for url: URL) async throws {
        let path = url.path(percentEncoded: false)

        guard FileManager.default.fileExists(atPath: path) else {
            Swift.print("✗ aucun fichier à \(path)")

            // replayd peut écrire ailleurs, ou laisser un résidu temporaire.
            // Montrer le dossier évite un aller-retour de diagnostic.
            let directory = url.deletingLastPathComponent()
            let siblings = (try? FileManager.default.contentsOfDirectory(atPath: directory.path())) ?? []
            Swift.print("  contenu de \(directory.path(percentEncoded: false)) :")
            if siblings.isEmpty {
                Swift.print("    (vide)")
            } else {
                for name in siblings.sorted() { Swift.print("    \(name)") }
            }
            return
        }

        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let size = attributes?[.size] as? Int64 ?? 0
        let asset = AVURLAsset(url: url)

        let isPlayable = try await asset.load(.isPlayable)
        let duration = try await asset.load(.duration)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)

        let seconds = duration.isNumeric ? duration.seconds : 0
        let gigabytesPerHour: Double = seconds > 0
            ? Double(size) / seconds * 3600 / 1_073_741_824
            : 0

        Swift.print("── rapport ────────────────────────────────")
        Swift.print("  lisible          \(isPlayable ? "oui" : "NON")")
        Swift.print("  durée            \(seconds.formatted(.number.precision(.fractionLength(1)))) s")
        Swift.print("  taille           \(size.formatted(.byteCount(style: .file)))")
        Swift.print("  débit extrapolé  \(gigabytesPerHour.formatted(.number.precision(.fractionLength(2)))) Go/h  (cible du plan : ~1)")
        Swift.print("  pistes vidéo     \(videoTracks.count)")
        Swift.print("  pistes audio     \(audioTracks.count)")

        for (index, track) in videoTracks.enumerated() {
            let size = try await track.load(.naturalSize)
            let rate = try await track.load(.nominalFrameRate)
            Swift.print("    vidéo \(index)        \(Int(size.width))×\(Int(size.height)) @ \(rate.formatted(.number.precision(.fractionLength(1)))) fps")
        }

        for (index, track) in audioTracks.enumerated() {
            let descriptions = try await track.load(.formatDescriptions)
            let channels = descriptions.first?.audioStreamBasicDescription?.mChannelsPerFrame ?? 0
            let sampleRate = descriptions.first?.audioStreamBasicDescription?.mSampleRate ?? 0
            Swift.print("    audio \(index)        \(channels) canaux @ \(Int(sampleRate)) Hz")
        }

        Swift.print("───────────────────────────────────────────")

        switch audioTracks.count {
        case 0:
            Swift.print("✗ VERDICT : aucune piste audio. Ni participants, ni micro. Échec de la barrière.")
        case 1:
            Swift.print("✓ VERDICT : une piste audio unique — SCRecordingOutput a mixé système + micro.")
            Swift.print("  Reste à valider à l'oreille que les DEUX sources y sont audibles.")
        default:
            Swift.print("⚠︎ VERDICT : \(audioTracks.count) pistes audio séparées.")
            Swift.print("  QuickTime ne jouera que la première : l'utilisateur ne s'entendra pas.")
            Swift.print("  → il faudra un mixage, donc la voie AVAssetWriter, donc replanifier la Phase 1.")
        }
    }
}
