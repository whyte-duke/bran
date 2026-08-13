import AVFoundation
import Foundation

/// Extrait la piste audio d'un enregistrement au format que le CRM attend.
///
/// La vidéo reste sur le Mac : c'est l'archive. Seul l'audio part, parce que
/// c'est tout ce que la transcription utilise — et parce que le plafond est de
/// 50 Mo, contre plusieurs giga-octets pour la vidéo.
///
/// Cibles du §6 du contrat : **AAC mono 16 kHz**. Le mono n'est pas qu'une
/// économie : en mode asynchrone, Azure n'analyse que le canal 0, et un fichier
/// stéréo fait échouer tout le job avec un message qui ne parle jamais de
/// canaux.
///
/// Le débit, lui, n'est plus une constante. Il est **déduit de la durée** pour
/// que le fichier tienne sous le plafond quelle que soit la longueur de la
/// réunion : voir `bitrate(forDurationSeconds:)`. Un débit fixe à 48 kbit/s
/// marchait pour tout ce qui dure moins de deux heures et échouait purement et
/// simplement au-delà — bran refusait alors d'envoyer une réunion qu'il aurait
/// suffi d'encoder un cran plus bas.
enum AudioExporter {

    /// Le plafond du serveur : **50 Mo, c'est-à-dire 50 000 000 octets**.
    ///
    /// La valeur d'avant était `52_428_800`, soit 50 **Mio** — et le commentaire
    /// qui la portait disait pourtant « mesuré côté Supabase : 50 passent, 52
    /// sont refusés ». Confondre Mo et Mio plaçait donc la borne de bran à
    /// 52,4 Mo, en plein dans la zone de refus mesurée : un fichier entre 50 et
    /// 52,4 Mo passait la garde locale, montait en entier, et Foundry le
    /// rejetait à l'arrivée en annonçant une taille maximale de 50 Mo. Tout le
    /// temps de l'envoi était perdu, et le message ne disait pas à
    /// l'utilisateur ce qu'il aurait fallu faire.
    ///
    /// Le serveur compte en méga-octets décimaux ; on compte comme lui. Les
    /// 2,4 Mo d'écart ne valaient pas le risque de refaire ce trajet.
    static let maximumBytes = 50_000_000

    /// Ce que l'encodage a le droit de viser : 90 % du plafond, soit 45 Mo.
    ///
    /// La marge n'est pas de la prudence décorative, elle couvre deux
    /// dépassements mesurés :
    ///
    /// 1. **L'encodeur AAC d'Apple rend plus que ce qu'on lui demande.** À
    ///    16 kHz mono : 12 kbit/s demandés → 13,0 kbit/s réels, 16 → 17,6,
    ///    20 → 21,2, 24 → 24,5, 32 → 32,4, 40 → 40,4, 48 → 49,1. Le dépassement
    ///    va de 2 à 10 %.
    /// 2. **L'en-tête du conteneur MPEG-4 s'ajoute au flux.** Il est compris
    ///    dans les chiffres ci-dessus, qui ont été relevés sur 30 s de signal :
    ///    son poids relatif ne peut que décroître sur une réunion d'une heure.
    ///
    /// Viser le plafond exact aurait été de la fausse précision : le débit
    /// demandé n'est qu'une consigne, seule la taille écrite est un fait — d'où
    /// aussi le contrôle a posteriori en fin d'extraction.
    static let workingBudgetBytes = maximumBytes * 9 / 10

    /// Plancher et plafond de la fenêtre utilisable de l'encodeur AAC d'Apple
    /// **à 16 kHz mono**.
    ///
    /// Mesuré avec `AVAssetWriterInput` et `AVEncoderBitRateKey`, sur 30 s de
    /// signal synthétique :
    ///
    ///      8 kbit/s → ÉCHEC « Cannot Encode Media »
    ///     12 kbit/s → ok, 13,0 kbit/s réels
    ///     16 kbit/s → ok, 17,6 kbit/s réels
    ///     20 kbit/s → ok, 21,2 kbit/s réels
    ///     24 kbit/s → ok, 24,5 kbit/s réels
    ///     32 kbit/s → ok, 32,4 kbit/s réels
    ///     40 kbit/s → ok, 40,4 kbit/s réels
    ///     48 kbit/s → ok, 49,1 kbit/s réels
    ///     56 kbit/s → ÉCHEC « Cannot Encode Media »
    ///     64 kbit/s → ÉCHEC « Cannot Encode Media »
    ///
    /// Hors de cette fenêtre l'encodeur ne signale pas un réglage inadapté : il
    /// refuse le média entier, avec un message qui ne parle jamais de débit.
    /// C'est pour ça que ces bornes sont dures et non « souhaitables ».
    /// (ffmpeg accepte 64 kbit/s au même réglage — c'est un autre encodeur, et
    /// il n'est pas dans l'app.)
    ///
    /// **Descendre à 8 kHz est écarté.** La fenêtre s'y déplace vers le bas —
    /// 8 à 24 kbit/s passent, 32 et au-delà échouent — donc on y gagnerait
    /// quelques kbit/s de plancher, mais la parole y perd et la transcription
    /// avec elle. Le calcul de débit ci-dessous tient jusqu'à plus de huit
    /// heures d'affilée : ce recours n'a plus de raison d'être.
    static let minimumBitrate = 12_000
    static let maximumBitrate = 48_000

    struct Result: Sendable {
        let url: URL
        let sizeBytes: Int
        let durationMilliseconds: Int
        /// Le débit effectivement retenu, en bit/s. Exposé pour que l'interface
        /// puisse dire « encodé à 24 kbit/s pour tenir sous 50 Mo » au lieu de
        /// laisser croire que la qualité est toujours la même.
        let bitrate: Int
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
                \(Self.durationText(seconds)) d'enregistrement, alors que le CRM \
                plafonne à 50 Mo.
                """
            }
        }

        var recoverySuggestion: String? {
            switch self {
            case .tooLarge:
                """
                Au-delà d'environ 8 h 20 d'affilée, même 12 kbit/s dépassent le plafond : \
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

    /// Le débit à demander pour qu'une réunion de `seconds` secondes tienne dans
    /// le budget de travail.
    ///
    /// `budget × 8 / secondes`, arrondi **vers le bas** au millier — arrondir au
    /// plus proche aurait pu remonter au-dessus du budget, et c'est exactement
    /// le genre d'octets qu'on n'a pas — puis borné à la fenêtre de l'encodeur.
    ///
    /// Ce que ça donne concrètement, avec 45 Mo de budget :
    ///
    /// - **jusqu'à ≈ 2 h 05**, le calcul dépasse 48 kbit/s : on reste au
    ///   maximum de l'encodeur, donc exactement la qualité d'aujourd'hui. Rien
    ///   ne change pour la quasi-totalité des closings.
    /// - **au-delà**, bran descend le débit au lieu de refuser l'envoi. Une
    ///   réunion de 4 h part à 24 kbit/s : moins beau, mais transcrit — et
    ///   Azure travaille sur de la parole à 16 kHz, pas sur de la musique.
    /// - **le plancher de 12 kbit/s n'est atteint qu'à ≈ 8 h 20**. Au-delà,
    ///   plus aucun réglage ne sauve l'envoi : c'est `ExportError.tooLarge`,
    ///   levée avant d'encoder.
    ///
    /// Durée inconnue (`duration` non numérique sur un fichier abîmé) : on
    /// demande le maximum et on laisse la mesure de fin trancher. Deviner bas
    /// « au cas où » aurait dégradé tous les fichiers dont on ne sait rien.
    static func bitrate(forDurationSeconds seconds: Double) -> Int {
        guard seconds > 0 else { return maximumBitrate }
        let ideal = Double(workingBudgetBytes) * 8 / seconds
        let flooredToThousand = Int(ideal / 1000) * 1000
        return min(max(flooredToThousand, minimumBitrate), maximumBitrate)
    }

    /// Relit un `.m4a` déjà préparé pour savoir s'il est réutilisable tel quel.
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
        // L'encodage d'une réunion longue prend plusieurs minutes de calcul ; les
        // dépenser pour lever `tooLarge` à la fin, alors que l'arithmétique le
        // savait dès la première ligne, serait de la cruauté gratuite. Le seuil
        // est celui du plancher : si même 12 kbit/s ne rentre pas, aucun réglage
        // ne rentrera.
        //
        // **Le refus se mesure au plafond réel, pas au budget de travail.** Il
        // regardait les 45 Mo du budget, ce qui refusait d'encoder entre 8 h 20
        // et 9 h 15 d'enregistrement — des durées où le fichier à 12 kbit/s
        // serait pourtant passé sous les 50 Mo. Le budget est une marge qu'on
        // s'accorde pour VISER ; il n'a rien à faire dans la décision de renoncer,
        // qui doit se prendre sur ce que le serveur refuse vraiment. La marge
        // continue de jouer son rôle juste après, dans le choix du débit, et le
        // contrôle a posteriori sur la taille écrite reste le seul juge.
        let idealBitrate = seconds > 0 ? Double(maximumBytes) * 8 / seconds : .infinity
        if idealBitrate < Double(minimumBitrate) {
            throw ExportError.tooLarge(
                bytes: Int(seconds * Double(minimumBitrate) / 8),
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
        // rendez-vous, ce `removeItem` détruisait un fichier existant avant même
        // d'avoir commencé à produire son remplaçant : une ré-extraction qui
        // échoue — piste illisible, encodeur qui refuse, fichier trop lourd —
        // laissait le dossier sans audio du tout, alors qu'il en avait un
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
        // couvre donc les six chemins de sortie sans qu'il faille les énumérer,
        // et sans qu'un chemin ajouté plus tard puisse l'oublier.
        defer { try? FileManager.default.removeItem(at: scratch) }

        let writer = try AVAssetWriter(outputURL: scratch, fileType: .m4a)
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

        // Le débit vient du calcul, plus d'une constante : voir
        // `bitrate(forDurationSeconds:)` pour la fenêtre de l'encodeur et les
        // seuils. Sous deux heures, `bitrate` vaut 48 000 — soit très
        // exactement le réglage d'avant, celui que le §6 du contrat CRM appelle
        // « la marge confortable » à ≈ 22 Mo l'heure.
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 1,      // mono : Azure n'analyse que le canal 0
            AVSampleRateKey: 16_000,       // la parole est transcrite à 16 kHz
            AVEncoderBitRateKey: bitrate,
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

        let attributes = try? FileManager.default.attributesOfItem(atPath: scratch.path(percentEncoded: false))
        let size = (attributes?[.size] as? Int) ?? 0

        // Le calcul de débit est une estimation, ceci est une mesure — et c'est
        // la mesure qui décide. Le contrôle reste donc en place malgré le
        // budget à 90 % : l'encodeur peut déborder plus que ce qu'on a relevé,
        // la durée peut être inconnue, un fichier abîmé peut produire n'importe
        // quoi. Mieux vaut refuser ici, une fois, que faire refuser par Foundry
        // après un envoi complet.
        guard size > 0, size <= maximumBytes else {
            try? FileManager.default.removeItem(at: scratch)
            throw ExportError.tooLarge(bytes: size, durationSeconds: seconds)
        }

        // La mise en place. C'est le seul moment où l'ancien audio disparaît, et
        // il ne disparaît que remplacé : `replaceItemAt` échange les deux d'un
        // bloc, et si l'échange échoue on ne perd ni l'un ni l'autre.
        //
        // Le repli sur `moveItem` couvre le cas où il n'y avait rien à remplacer
        // — première extraction — que `replaceItemAt` refuse.
        do {
            if FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: scratch)
            } else {
                try FileManager.default.moveItem(at: scratch, to: destination)
            }
        } catch {
            try? FileManager.default.removeItem(at: scratch)
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
