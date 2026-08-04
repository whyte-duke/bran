import AVFoundation
import Foundation

/// Extrait la piste audio d'un enregistrement au format que le CRM attend.
///
/// La vidéo reste sur le Mac : c'est l'archive. Seul l'audio part, parce que
/// c'est tout ce que la transcription utilise — et parce que le plafond est de
/// 50 Mio, contre plusieurs giga-octets pour la vidéo.
///
/// Cibles du §6 du contrat : **AAC mono 16 kHz 64 kbit/s**, ≈ 29 Mo pour une
/// heure. Le mono n'est pas qu'une économie : en mode asynchrone, Azure
/// n'analyse que le canal 0, et un fichier stéréo fait échouer tout le job avec
/// un message qui ne parle jamais de canaux.
enum AudioExporter {

    /// 50 Mio. Mesuré côté Supabase : 50 passent, 52 sont refusés. C'est le
    /// plafond du projet, pas celui du bucket.
    static let maximumBytes = 52_428_800

    struct Result: Sendable {
        let url: URL
        let sizeBytes: Int
        let durationMilliseconds: Int
        let mimeType = "audio/mp4"
    }

    enum ExportError: LocalizedError {
        case noAudioTrack
        case exportFailed(String)
        case tooLarge(bytes: Int, durationSeconds: Double)

        var errorDescription: String? {
            switch self {
            case .noAudioTrack:
                "L'enregistrement ne contient aucune piste audio."
            case .exportFailed(let reason):
                "Extraction audio impossible : \(reason)"
            case .tooLarge(let bytes, let seconds):
                """
                Audio trop lourd : \(bytes.formatted(.byteCount(style: .file))) pour \
                \(Int(seconds / 60)) min, alors que le CRM plafonne à 50 Mo.
                """
            }
        }

        var recoverySuggestion: String? {
            switch self {
            case .tooLarge:
                "Au-delà d'environ 1 h 45, l'audio doit être découpé avant l'envoi."
            case .noAudioTrack, .exportFailed:
                nil
            }
        }
    }

    static func extractSpeechAudio(from source: URL, to destination: URL) async throws -> Result {
        let asset = AVURLAsset(url: source)

        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw ExportError.noAudioTrack
        }

        let duration = try await asset.load(.duration)
        let seconds = duration.isNumeric ? duration.seconds : 0

        try? FileManager.default.removeItem(at: destination)

        let writer = try AVAssetWriter(outputURL: destination, fileType: .m4a)
        let reader = try AVAssetReader(asset: asset)

        // `AVAssetWriter` n'est PAS un convertisseur : il encode ce qu'on lui
        // donne, tel quel. Lui livrer du PCM 48 kHz stéréo en lui demandant de
        // l'AAC mono 16 kHz échoue avec « Cannot Encode Media ».
        //
        // La conversion se fait donc à la LECTURE. `AVAssetReaderAudioMixOutput`
        // est fait pour ça : c'est le seul chemin qui sache à la fois
        // rééchantillonner et replier deux canaux sur un.
        let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)

        var monoLayout = AudioChannelLayout()
        monoLayout.mChannelLayoutTag = kAudioChannelLayoutTag_Mono

        // 48 kbit/s et pas 64 : le débit maximal de l'encodeur AAC d'Apple
        // dépend de la fréquence d'échantillonnage, et à 16 kHz mono il
        // plafonne là. Mesuré : 48 passe, 56 échoue sur « Cannot Encode Media ».
        // ffmpeg accepte 64 kbit/s au même réglage — c'est un autre encodeur.
        //
        // Aucune perte pour l'usage : le §6 du contrat CRM liste lui-même
        // 48 kbit/s mono comme la marge confortable, à ≈ 22 Mo l'heure.
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 1,      // mono : Azure n'analyse que le canal 0
            AVSampleRateKey: 16_000,       // la parole est transcrite à 16 kHz
            AVEncoderBitRateKey: 48_000,
            AVChannelLayoutKey: Data(bytes: &monoLayout, count: MemoryLayout<AudioChannelLayout>.size),
        ])
        input.expectsMediaDataInRealTime = false
        writer.add(input)

        guard reader.startReading() else {
            throw ExportError.exportFailed(reader.error?.localizedDescription ?? "lecture impossible")
        }
        guard writer.startWriting() else {
            throw ExportError.exportFailed(writer.error?.localizedDescription ?? "écriture impossible")
        }
        writer.startSession(atSourceTime: .zero)

        await withCheckedContinuation { continuation in
            let pump = AudioPump(output: output, input: input)
            let resumed = ResumeGuard(continuation)

            input.requestMediaDataWhenReady(on: DispatchQueue(label: "bran.audio.export")) {
                while pump.input.isReadyForMoreMediaData {
                    guard let sample = pump.output.copyNextSampleBuffer() else {
                        pump.input.markAsFinished()
                        resumed.fire()
                        return
                    }
                    if pump.input.append(sample) == false {
                        pump.input.markAsFinished()
                        resumed.fire()
                        return
                    }
                }
            }
        }

        await writer.finishWriting()

        guard writer.status == .completed else {
            let detail = writer.error?.localizedDescription
                ?? reader.error?.localizedDescription
                ?? "statut \(writer.status.rawValue)"
            throw ExportError.exportFailed(detail)
        }

        let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path(percentEncoded: false))
        let size = (attributes?[.size] as? Int) ?? 0

        // Refus immédiat plutôt qu'un envoi de 40 Mo qui échoue à la fin.
        guard size > 0, size <= maximumBytes else {
            try? FileManager.default.removeItem(at: destination)
            throw ExportError.tooLarge(bytes: size, durationSeconds: seconds)
        }

        return Result(
            url: destination,
            sizeBytes: size,
            durationMilliseconds: Int(seconds * 1000)
        )
    }
}

private struct AudioPump: @unchecked Sendable {
    let output: AVAssetReaderOutput
    let input: AVAssetWriterInput
}

/// `requestMediaDataWhenReady` peut rappeler après la fin. Reprendre deux fois
/// une continuation fait planter le processus.
private final class ResumeGuard: @unchecked Sendable {
    private let continuation: CheckedContinuation<Void, Never>
    private let lock = NSLock()
    private var fired = false

    init(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    func fire() {
        lock.lock()
        let alreadyFired = fired
        fired = true
        lock.unlock()

        if alreadyFired == false { continuation.resume() }
    }
}
