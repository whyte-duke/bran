import AVFoundation
import Foundation
import Synchronization

/// Recolle les segments et compresse — **en une seule passe d'encodage**.
///
/// Fusionner puis compresser séparément encoderait deux fois : chaque passe
/// avec perte dégrade l'image, et sur du texte à l'écran ça se voit tout de
/// suite. `AVMutableComposition` assemble les morceaux sans les toucher, et
/// l'unique encodage se fait à la sortie.
///
/// C'est aussi la réponse au débit : `SCRecordingOutput` ne laisse régler aucun
/// débit à l'enregistrement, mais rien n'empêche d'en choisir un ici.
actor PostProcessor {

    struct Outcome: Sendable {
        let originalBytes: Int64
        let finalBytes: Int64

        var savedFraction: Double {
            originalBytes > 0 ? 1 - Double(finalBytes) / Double(originalBytes) : 0
        }
    }

    enum ProcessingError: LocalizedError {
        case noUsableSegment
        case noVideoTrack
        case writerFailed(String)

        var errorDescription: String? {
            switch self {
            case .noUsableSegment: "Aucun segment exploitable."
            case .noVideoTrack: "Le fichier ne contient aucune piste vidéo."
            case .writerFailed(let reason): "Écriture impossible : \(reason)"
            }
        }
    }

    /// Bits par pixel et par image, pour du contenu d'écran en HEVC.
    ///
    /// Une réunion est majoritairement statique : des slides, une interface,
    /// quelques vignettes qui bougent. 0,03 bit/pixel tient le texte net à cette
    /// densité de mouvement. Monter au-dessus ne fait grossir le fichier sans
    /// rien ajouter de visible.
    private static let bitsPerPixelPerFrame = 0.03

    /// - Parameter onProgress: fraction de 0 à 1, appelée depuis un contexte
    ///   arbitraire.
    func process(
        segments: [URL],
        into destination: URL,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> Outcome {
        let usable = segments.filter { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
        guard usable.isEmpty == false else { throw ProcessingError.noUsableSegment }

        let originalBytes = usable.reduce(Int64.zero) { $0 + Self.sizeOf($1) }

        let composition = try await Self.compose(usable)
        try await Self.transcode(composition, to: destination, onProgress: onProgress)

        // Les segments ne disparaissent qu'une fois le fichier final écrit et
        // vérifié. Un échec laisse la matière première intacte : on peut
        // relancer, ou récupérer les morceaux à la main.
        let finalBytes = Self.sizeOf(destination)
        guard finalBytes > 0 else { throw ProcessingError.writerFailed("fichier final vide") }

        for segment in usable {
            try? FileManager.default.removeItem(at: segment)
        }

        return Outcome(originalBytes: originalBytes, finalBytes: finalBytes)
    }

    // MARK: - Assemblage

    private static func compose(_ segments: [URL]) async throws -> AVComposition {
        let composition = AVMutableComposition()
        let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        let audio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)

        var cursor = CMTime.zero

        for url in segments {
            let asset = AVURLAsset(url: url)
            guard let duration = try? await asset.load(.duration), duration.isNumeric, duration > .zero else {
                continue
            }
            let range = CMTimeRange(start: .zero, duration: duration)

            if let sourceVideo = try await asset.loadTracks(withMediaType: .video).first {
                try video?.insertTimeRange(range, of: sourceVideo, at: cursor)
            }
            if let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first {
                try audio?.insertTimeRange(range, of: sourceAudio, at: cursor)
            }

            cursor = cursor + duration
        }

        guard cursor > .zero else { throw ProcessingError.noUsableSegment }
        return composition.copy() as! AVComposition
    }

    // MARK: - Encodage

    private static func transcode(
        _ asset: AVAsset,
        to destination: URL,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ProcessingError.noVideoTrack
        }

        let size = try await videoTrack.load(.naturalSize)
        let nominalRate = try await videoTrack.load(.nominalFrameRate)
        let frameRate = nominalRate > 1 ? Double(nominalRate) : 30
        let duration = try await asset.load(.duration).seconds

        let bitrate = Int(Double(size.width) * Double(size.height) * frameRate * bitsPerPixelPerFrame)

        try? FileManager.default.removeItem(at: destination)
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
        let reader = try AVAssetReader(asset: asset)

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoMaxKeyFrameIntervalKey: Int(frameRate * 2),
                AVVideoExpectedSourceFrameRateKey: Int(frameRate),
            ],
        ])
        videoInput.expectsMediaDataInRealTime = false
        videoInput.transform = try await videoTrack.load(.preferredTransform)
        writer.add(videoInput)

        let videoOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        reader.add(videoOutput)

        var audioInput: AVAssetWriterInput?
        var audioOutput: AVAssetReaderTrackOutput?

        if let audioTrack = try await asset.loadTracks(withMediaType: .audio).first {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000,
            ])
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audioInput = input

            let output = AVAssetReaderTrackOutput(
                track: audioTrack,
                outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM]
            )
            reader.add(output)
            audioOutput = output
        }

        guard reader.startReading() else {
            throw ProcessingError.writerFailed(reader.error?.localizedDescription ?? "lecture impossible")
        }
        guard writer.startWriting() else {
            throw ProcessingError.writerFailed(writer.error?.localizedDescription ?? "écriture impossible")
        }
        writer.startSession(atSourceTime: .zero)

        // Les deux pistes doivent être alimentées en parallèle : attendre la fin
        // de la vidéo avant de commencer l'audio ferait patienter l'encodeur sur
        // une piste qu'on ne lui donne pas.
        let videoPump = TrackPump(output: videoOutput, input: videoInput)
        let audioPump = audioOutput.flatMap { output in
            audioInput.map { TrackPump(output: output, input: $0) }
        }

        async let videoDone: Void = pump(
            videoPump,
            queue: "bran.transcode.video",
            duration: duration,
            onProgress: onProgress
        )
        async let audioDone: Void = pump(
            audioPump,
            queue: "bran.transcode.audio",
            duration: nil,
            onProgress: { _ in }
        )

        _ = await (videoDone, audioDone)

        guard reader.status != .failed else {
            writer.cancelWriting()
            throw ProcessingError.writerFailed(reader.error?.localizedDescription ?? "lecture interrompue")
        }

        await writer.finishWriting()

        guard writer.status == .completed else {
            throw ProcessingError.writerFailed(writer.error?.localizedDescription ?? "statut \(writer.status.rawValue)")
        }
    }

    /// Transfert d'une piste, échantillon par échantillon.
    ///
    /// `requestMediaDataWhenReady` est la seule façon correcte d'alimenter un
    /// `AVAssetWriterInput` : il rappelle quand le codec a de la place, ce qui
    /// évite de charger toute la vidéo en mémoire.
    /// Paire lecteur/écrivain d'une piste.
    ///
    /// `@unchecked Sendable` justifié : après construction, ces deux objets ne
    /// sont touchés que depuis la queue série qui leur est dédiée, celle que
    /// `requestMediaDataWhenReady` utilise pour rappeler.
    private struct TrackPump: @unchecked Sendable {
        let output: AVAssetReaderTrackOutput
        let input: AVAssetWriterInput
    }

    private static func pump(
        _ track: TrackPump?,
        queue label: String,
        duration: Double?,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async {
        guard let track else { return }
        let output = track.output
        let input = track.input

        await withCheckedContinuation { continuation in
            // `requestMediaDataWhenReady` peut rappeler après qu'on a déjà
            // terminé. Reprendre deux fois une continuation fait planter le
            // processus — le verrou garantit qu'on ne la reprend qu'une fois.
            let resumed = Mutex(false)
            let finish = { @Sendable in
                let alreadyDone = resumed.withLock { done -> Bool in
                    defer { done = true }
                    return done
                }
                if alreadyDone == false { continuation.resume() }
            }

            input.requestMediaDataWhenReady(on: DispatchQueue(label: label)) {
                while input.isReadyForMoreMediaData {
                    guard let sample = output.copyNextSampleBuffer() else {
                        input.markAsFinished()
                        finish()
                        return
                    }

                    if let duration, duration > 0 {
                        let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                        onProgress(min(max(time / duration, 0), 1))
                    }

                    if input.append(sample) == false {
                        input.markAsFinished()
                        finish()
                        return
                    }
                }
            }
        }
    }

    private static func sizeOf(_ url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        return attributes?[.size] as? Int64 ?? 0
    }
}
