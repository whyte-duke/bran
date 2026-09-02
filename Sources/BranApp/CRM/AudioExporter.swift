import AVFoundation
import BranCore
import Foundation

/// Extrait la piste audio d'un enregistrement au format que le CRM attend.
///
/// La vidéo reste sur le Mac : c'est l'archive. Seul l'audio part, parce que
/// c'est tout ce que la transcription utilise — et parce que le plafond est de
/// 50 Mo, contre plusieurs giga-octets pour la vidéo.
///
/// ## Pourquoi du MP3, et pas l'AAC natif de macOS
///
/// Parce qu'Azure ne sait pas décoder l'AAC que produit ce Mac. Ce n'est pas une
/// déduction : c'est le relevé du **31/08/2026**, fait en envoyant un vrai
/// closing de 32 min directement à l'API du CRM, dans quatre encodages du même
/// signal.
///
///     AAC 16 kHz mono   (ce que bran produisait)   → 422 InvalidAudioFormat
///     AAC 44,1 kHz mono                            → 422 InvalidAudioFormat
///     AAC 44,1 kHz stéréo                          → 422 InvalidAudioFormat
///     MP3 16 kHz mono 48 kbit/s                    → 200, transcrit en 60 s
///
/// Le même AAC déposé en `batch` — l'autre moteur, celui qui lit par URL — a
/// échoué pareil, avec `InvalidData`. **Il n'existe donc aucun contournement
/// côté serveur** : ni un profil AAC différent, ni un choix de moteur.
///
/// Ce que ça a coûté avant d'être vu : les trois seules réunions envoyées depuis
/// bran duraient 5,9 s, 8 min et 32,7 min. Les deux premières ont été
/// transcrites, la troisième a échoué — le seuil de refus d'Azure est autour de
/// vingt minutes, et bran n'avait jamais envoyé de closing d'une vraie durée.
/// La note interne du CRM le savait pourtant : « de l'AAC 16 kHz mono est refusé
/// au-delà d'environ 20 min là où le même audio en MP3 passe ».
///
/// Et macOS **décode** le MP3 sans l'**encoder** : `afconvert -hf` annonce le
/// format, puis répond `ExtAudioFileSetProperty ('cfmt') failed ('fmt?')` dès
/// qu'on lui demande d'écrire. D'où `libmp3lame` dans `Sources/CLame`, et
/// `MP3Encoder` pour l'habiller.
///
/// ## Le reste des cibles
///
/// **Mono 16 kHz**, comme avant : c'est ce que la reconnaissance vocale utilise,
/// et le CRM encode exactement pareil dans son repli navigateur. Le débit, lui,
/// est **déduit de la durée** pour que le fichier tienne sous le plafond quelle
/// que soit la longueur de la réunion — voir `SpeechAudioBudget`.
enum AudioExporter {

    /// Le plafond du serveur. Ré-exposé ici parce que l'interface le cite ;
    /// l'arithmétique, elle, vit dans `SpeechAudioBudget`, où elle se teste.
    static let maximumBytes = SpeechAudioBudget.maximumBytes

    /// La fréquence d'échantillonnage de la parole transcrite. Descendre à
    /// 8 kHz ferait gagner quelques kbit/s et perdrait des consonnes ; le calcul
    /// de débit tient jusqu'à douze heures d'affilée, ce recours n'a plus lieu
    /// d'être.
    static let sampleRate = 16_000

    struct Result: Sendable {
        let url: URL
        let sizeBytes: Int
        let durationMilliseconds: Int
        /// Le débit effectivement retenu, en bit/s. Exposé pour que l'interface
        /// puisse dire « encodé à 24 kbit/s pour tenir sous 50 Mo » au lieu de
        /// laisser croire que la qualité est toujours la même.
        let bitrate: Int
        let mimeType = "audio/mpeg"
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
                \(Self.durationText(seconds)) d'enregistrement, alors que le CRM \
                plafonne à 50 Mo.
                """
            }
        }

        var recoverySuggestion: String? {
            switch self {
            case .tooLarge:
                """
                Au-delà d'environ 12 h 30 d'affilée, même 8 kbit/s dépassent le plafond : \
                l'enregistrement doit être découpé en deux, et chaque moitié envoyée sur \
                son propre rendez-vous.
                """
            case .noAudioTrack, .exportFailed:
                nil
            }
        }

        /// « 8 h 20 » plutôt que « 500 min ». Le message doit se lire comme on
        /// parle d'une réunion, pas comme un relevé de compteur.
        private static func durationText(_ seconds: Double) -> String {
            let total = Int(seconds.rounded())
            let hours = total / 3600
            let minutes = (total % 3600) / 60
            return hours > 0 ? "\(hours) h \(String(format: "%02d", minutes))" : "\(minutes) min"
        }
    }

    /// Le débit à demander pour cette durée. Passe-plat vers `SpeechAudioBudget`,
    /// gardé pour que les appelants n'aient pas à connaître les deux types.
    static func bitrate(forDurationSeconds seconds: Double) -> Int {
        SpeechAudioBudget.bitrate(forDurationSeconds: seconds)
    }

    /// Relit un audio déjà préparé pour savoir s'il est réutilisable tel quel.
    ///
    /// Sert au chemin « l'audio est déjà à côté de la vidéo » : ré-encoder
    /// trente-six minutes d'audio qu'on possède déjà, c'est du temps pris à
    /// l'utilisateur pour rien. Mais un fichier trouvé sur le disque n'est pas
    /// un fichier connu : sa taille et sa durée sont **relues**
    /// (`AVURLAsset`), jamais supposées d'après les métadonnées de
    /// l'enregistrement — celles-ci décrivent la vidéo, et le CRM compare ce
    /// qu'on lui annonce à ce qu'il reçoit.
    ///
    /// `nil` dès que le fichier ne peut pas servir : absent, vide, au-dessus du
    /// plafond, ou sans durée lisible. L'appelant repasse alors par une
    /// extraction complète, ce qui est toujours sûr.
    ///
    /// **L'extension n'est pas vérifiée ici**, et c'est volontaire : l'appelant
    /// ne propose à cette fonction que le chemin de destination courant, qui
    /// porte l'extension courante. Un `.m4a` laissé par une version antérieure
    /// de bran n'est donc jamais candidat — il n'est pas à ce chemin.
    static func inspectPreparedAudio(at url: URL) async -> Result? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        guard let size = attributes?[.size] as? Int, size > 0, size <= maximumBytes else { return nil }

        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration), duration.isNumeric else { return nil }
        let seconds = duration.seconds
        guard seconds > 0 else { return nil }

        // Le débit annoncé est ici une mesure, pas la consigne d'encodage : on
        // ne sait pas à quel réglage ce fichier a été produit, et la seule
        // chose vraie est le rapport octets/durée.
        return Result(
            url: url,
            sizeBytes: size,
            durationMilliseconds: Int(seconds * 1000),
            bitrate: Int(Double(size) * 8 / seconds)
        )
    }

    /// Le nom du brouillon, **borné**.
    ///
    /// Un composant de chemin est plafonné à 255 octets sur APFS. Le nom du
    /// fichier audio reprend celui de son dossier, que l'utilisateur peut
    /// renommer à la main aussi long qu'il veut : décorer d'un point et de
    /// « .en-cours » un nom déjà proche de la limite ferait échouer la création
    /// du brouillon, donc l'extraction entière — sur la seule réunion dont
    /// quelqu'un aura pris la peine d'écrire le nom en entier.
    ///
    /// Le budget est fixé bas, à 200 octets : le nom d'un brouillon ne sert à
    /// personne d'autre qu'à lui-même, il vit quelques secondes, et la coupe ne
    /// crée aucune ambiguïté puisqu'il n'y a qu'un audio par dossier. On rogne
    /// caractère par caractère et non octet par octet, pour ne jamais couper un
    /// accent en deux.
    private static func draftName(for name: String) -> String {
        let head = "."
        let tail = ".en-cours"
        let budget = 200 - head.utf8.count - tail.utf8.count

        var trimmed = name
        while trimmed.utf8.count > budget, trimmed.isEmpty == false { trimmed.removeLast() }
        return head + trimmed + tail
    }

    static func extractSpeechAudio(from source: URL, to destination: URL) async throws -> Result {
        let asset = AVURLAsset(url: source)

        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw ExportError.noAudioTrack
        }

        let duration = try await asset.load(.duration)
        let seconds = duration.isNumeric ? duration.seconds : 0

        // Refus AVANT d'encoder, pas après.
        //
        // L'encodage d'une réunion longue prend plusieurs secondes de calcul ;
        // les dépenser pour lever `tooLarge` à la fin, alors que l'arithmétique
        // le savait dès la première ligne, serait de la cruauté gratuite. Le
        // seuil est celui du plancher : si même 8 kbit/s ne rentre pas, aucun
        // réglage ne rentrera.
        guard SpeechAudioBudget.fits(durationSeconds: seconds) else {
            throw ExportError.tooLarge(
                bytes: SpeechAudioBudget.floorSizeBytes(durationSeconds: seconds),
                durationSeconds: seconds
            )
        }

        // `Self.` est nécessaire : la constante locale porte le même nom que la
        // fonction, et sans qualification le compilateur croirait qu'on
        // s'appelle soi-même dans sa propre initialisation.
        let bitrate = Self.bitrate(forDurationSeconds: seconds)

        // **On écrit à côté, puis on met en place ; on n'efface jamais avant.**
        //
        // Tant que la destination était un fichier temporaire, effacer d'abord ne
        // coûtait rien. Depuis que l'audio du CRM est CONSERVÉ dans le dossier du
        // rendez-vous, effacer d'abord détruirait un fichier existant avant même
        // d'avoir commencé à produire son remplaçant : une ré-extraction qui
        // échoue — piste illisible, encodeur qui refuse, fichier trop lourd —
        // laisserait le dossier sans audio du tout, alors qu'il en avait un
        // parfaitement valable une seconde plus tôt.
        //
        // Le brouillon vit **dans le même dossier** que la destination, et pas
        // dans le dossier temporaire : la mise en place finale est alors un
        // renommage sur le même volume, donc instantané et atomique. Passer par
        // `/tmp` en aurait fait une copie de plusieurs dizaines de mégaoctets,
        // interruptible en son milieu — soit précisément le défaut qu'on corrige.
        let scratch = destination
            .deletingLastPathComponent()
            .appending(path: draftName(for: destination.lastPathComponent))
        try? FileManager.default.removeItem(at: scratch)

        // Aucun brouillon ne survit à cette fonction, quelle qu'en soit la
        // sortie. Après une mise en place réussie il n'existe plus, et
        // `removeItem` sur un fichier absent ne fait rien : un seul `defer`
        // couvre donc les chemins de sortie sans qu'il faille les énumérer, et
        // sans qu'un chemin ajouté plus tard puisse l'oublier.
        defer { try? FileManager.default.removeItem(at: scratch) }

        let reader = try AVAssetReader(asset: asset)

        // La conversion se fait à la LECTURE. `AVAssetReaderAudioMixOutput` est
        // le seul chemin qui sache à la fois rééchantillonner et replier deux
        // canaux sur un ; `libmp3lame`, lui, ne fait qu'encoder ce qu'on lui
        // donne et attend du PCM 16 bits à la fréquence de sortie.
        let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)

        guard FileManager.default.createFile(atPath: scratch.path(percentEncoded: false), contents: nil) else {
            throw ExportError.exportFailed("brouillon impossible à créer")
        }

        guard reader.startReading() else {
            throw ExportError.exportFailed(reader.error?.localizedDescription ?? "lecture impossible")
        }

        // **Hors du pool coopératif.** Lire et encoder trente minutes d'audio est
        // un travail bloquant de plusieurs secondes ; le laisser sur un fil de
        // `async` gèlerait autant de tâches Swift Concurrency, dont l'interface.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue(label: "bran.audio.export").async {
                do {
                    try encode(reader: reader, output: output, to: scratch, bitrate: bitrate)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }

        let attributes = try? FileManager.default.attributesOfItem(atPath: scratch.path(percentEncoded: false))
        let size = (attributes?[.size] as? Int) ?? 0

        // Le calcul de débit est une estimation, ceci est une mesure — et c'est
        // la mesure qui décide. Le contrôle reste donc en place malgré le
        // budget à 90 % : la durée peut être inconnue, un fichier abîmé peut
        // produire n'importe quoi. Mieux vaut refuser ici, une fois, que faire
        // refuser par le CRM après un envoi complet.
        guard size > 0, size <= maximumBytes else {
            throw ExportError.tooLarge(bytes: size, durationSeconds: seconds)
        }

        // La mise en place. C'est le seul moment où l'ancien audio disparaît, et
        // il ne disparaît que remplacé : `replaceItemAt` échange les deux d'un
        // bloc, et si l'échange échoue on ne perd ni l'un ni l'autre.
        //
        // **Le repli sur `moveItem` reste, sa justification était fausse.**
        // Ce commentaire affirmait que `replaceItemAt` refuse une destination
        // absente — première extraction. Mesuré le 02/09/2026 sur macOS 26.5
        // (build 25F71) : elle réussit, que le fichier temporaire soit dans le
        // même dossier que la cible ou ailleurs. Le repli est donc inutile
        // plutôt que nécessaire ; il est conservé parce qu'il est exact et
        // qu'un `moveItem` sur une destination libre est un rename, c'est-à-dire
        // moins de travail que le va-et-vient de `replaceItemAt`.
        //
        // La phrase corrigée ici plutôt que supprimée : cinq rapports d'audit
        // sur douze l'ont recopiée telle quelle pour classer, ailleurs dans le
        // dépôt, un défaut critique qui n'existe pas. Un commentaire faux dans
        // ce dépôt-ci ne reste pas dans son fichier.
        do {
            if FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: scratch)
            } else {
                try FileManager.default.moveItem(at: scratch, to: destination)
            }
        } catch {
            throw ExportError.exportFailed(
                "l'audio a bien été encodé mais n'a pas pu être mis en place — \(error.localizedDescription)"
            )
        }

        return Result(
            url: destination,
            sizeBytes: size,
            durationMilliseconds: Int(seconds * 1000),
            bitrate: bitrate
        )
    }

    /// La boucle lecture → encodage → disque. Bloquante, appelée sur sa propre
    /// file.
    ///
    /// **Le fichier est écrit au fil de l'eau et non accumulé en mémoire.** Un
    /// closing de quatre heures fait 460 Mo de PCM décompressé ; le garder en
    /// RAM pour l'écrire d'un bloc à la fin ferait payer un pic de mémoire pour
    /// rien, sur la machine de quelqu'un qui est peut-être encore en réunion.
    private static func encode(
        reader: AVAssetReader,
        output: AVAssetReaderOutput,
        to url: URL,
        bitrate: Int
    ) throws {
        let encoder = try MP3Encoder(sampleRate: sampleRate, bitrate: bitrate)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        while true {
            guard let sample = output.copyNextSampleBuffer() else { break }
            defer { CMSampleBufferInvalidate(sample) }

            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            guard length > 0 else { continue }

            var bytes = [UInt8](repeating: 0, count: length)
            let status = bytes.withUnsafeMutableBytes { raw in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
            }
            guard status == noErr else {
                throw ExportError.exportFailed("bloc audio illisible (\(status))")
            }

            let encoded = try bytes.withUnsafeBytes { raw -> Data in
                try encoder.encode(raw.bindMemory(to: Int16.self))
            }
            if encoded.isEmpty == false { try handle.write(contentsOf: encoded) }
        }

        // L'état du lecteur se consulte APRÈS la boucle : `copyNextSampleBuffer`
        // rend `nil` aussi bien à la fin normale du flux que sur une piste qui
        // se corrompt en cours de route, et les deux ne doivent pas produire le
        // même fichier. Sans ce contrôle, une lecture interrompue à mi-parcours
        // donnerait un MP3 parfaitement valable — et parfaitement tronqué.
        guard reader.status == .completed else {
            throw ExportError.exportFailed(
                reader.error?.localizedDescription ?? "lecture interrompue (statut \(reader.status.rawValue))"
            )
        }

        try handle.write(contentsOf: encoder.finish())

        // La trame Info, écrite par-dessus celle que LAME avait réservée au
        // début du flux. Elle porte le compte exact des trames, que l'encodeur
        // ne connaît qu'ici — c'est elle qui permet à `AVURLAsset` de rendre une
        // durée juste, celle-là même que bran annonce au CRM.
        if let tag = encoder.infoTag() {
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: tag)
        }
    }
}
