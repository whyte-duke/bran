import CLame
import Foundation

/// L'encodeur MP3 de bran : une enveloppe mince autour de `libmp3lame`.
///
/// **Pourquoi du MP3 et pas de l'AAC**, alors que l'AAC est le format natif de
/// macOS et que tout le reste de l'app l'utilise : parce que le CRM le refuse.
/// Le relevé complet est dans `AudioExporter` ; le résumé tient en une ligne —
/// Azure ne sait pas décoder l'AAC au-delà d'une vingtaine de minutes, et
/// AudioToolbox ne sait pas écrire du MP3.
///
/// **Ce que cette classe garantit, et que l'appelant n'a donc pas à vérifier :**
///
/// - `libmp3lame` n'est jamais touché après `finish()` ni après un échec. Le
///   contexte est fermé une fois exactement, par `deinit` ou par `finish()`,
///   jamais deux fois — un double `lame_close` corromprait le tas.
/// - Les tampons de sortie sont dimensionnés selon la formule que LAME impose
///   (`1,25 × n + 7200`). Un tampon trop court n'est pas signalé par un code
///   d'erreur exploitable : LAME rend `-1` et l'audio est silencieusement perdu.
/// - Le flux rendu est du **CBR avec en-tête Info**, écrit à la fin par-dessus
///   la trame réservée au début. Sans cet en-tête le fichier reste lisible, mais
///   `AVURLAsset` doit alors deviner la durée d'après la taille — et c'est cette
///   durée que bran annonce au CRM, qui la compare à ce qu'il reçoit.
///
/// Non `Sendable` et volontairement : un contexte LAME porte l'état du flux
/// (réservoir de bits, fenêtre psychoacoustique). Il appartient à la tâche qui
/// l'a créé, du premier `encode` au `finish`.
final class MP3Encoder {

    enum Failure: LocalizedError {
        case initialisationFailed
        case parametersRefused(sampleRate: Int, bitrate: Int)
        case encodingFailed(code: Int32)

        var errorDescription: String? {
            switch self {
            case .initialisationFailed:
                "L'encodeur MP3 n'a pas démarré."
            case .parametersRefused(let sampleRate, let bitrate):
                "L'encodeur MP3 a refusé le réglage \(sampleRate) Hz à \(bitrate / 1000) kbit/s."
            case .encodingFailed(let code):
                "L'encodeur MP3 s'est arrêté (code \(code))."
            }
        }
    }

    private var flags: OpaquePointer?

    init(sampleRate: Int, bitrate: Int) throws {
        guard let gfp = lame_init() else { throw Failure.initialisationFailed }
        flags = gfp

        lame_set_in_samplerate(gfp, Int32(sampleRate))
        lame_set_out_samplerate(gfp, Int32(sampleRate))
        lame_set_num_channels(gfp, 1)
        lame_set_mode(gfp, MONO)
        lame_set_brate(gfp, Int32(bitrate / 1000))
        lame_set_VBR(gfp, vbr_off)

        // 2 sur une échelle où 0 est le plus lent : c'est le réglage que LAME
        // documente comme « proche du meilleur, nettement plus rapide », et
        // trente minutes d'audio s'encodent en quelques secondes. Descendre à 0
        // n'apporterait rien à une reconnaissance vocale qui travaille en
        // 16 kHz mono.
        lame_set_quality(gfp, 2)

        // La trame Info. `1` réserve la place au début du flux ; sans elle,
        // `lame_get_lametag_frame` n'aurait nulle part où écrire et il faudrait
        // décaler tout le fichier après coup.
        lame_set_bWriteVbrTag(gfp, 1)

        // **Pas d'ID3.** Le CRM n'en lit aucun, et sa présence casserait le
        // dimensionnement des tampons : `lame_encode_buffer` rend aussi les
        // octets d'ID3v2 lors du premier appel, jusqu'à 128 Kio de pochette,
        // là où la formule que LAME documente pour la taille du tampon ne
        // couvre que l'audio. Plutôt que de sur-allouer chaque bloc pour des
        // métadonnées qu'on n'écrit pas, on les coupe à la source.
        lame_set_write_id3tag_automatic(gfp, 0)

        guard lame_init_params(gfp) >= 0 else {
            close()
            throw Failure.parametersRefused(sampleRate: sampleRate, bitrate: bitrate)
        }

        // **On relit ce que LAME a retenu plutôt que de croire ce qu'on a
        // demandé.** Un débit hors table est remplacé en silence, et c'est
        // précisément le cas que le budget de taille ne survivrait pas : mieux
        // vaut le savoir ici que devant un fichier de 60 Mo.
        let accepted = Int(lame_get_brate(gfp)) * 1000
        guard accepted == bitrate else {
            close()
            throw Failure.parametersRefused(sampleRate: sampleRate, bitrate: bitrate)
        }
    }

    deinit { close() }

    /// Encode un bloc d'échantillons mono 16 bits et rend les octets MP3 prêts.
    ///
    /// Le rendu peut être vide : LAME accumule jusqu'à avoir une trame complète.
    /// Ce n'est pas une erreur, et l'appelant ne doit rien en conclure.
    func encode(_ samples: UnsafeBufferPointer<Int16>) throws -> Data {
        guard let gfp = flags else { return Data() }
        guard let base = samples.baseAddress, samples.count > 0 else { return Data() }

        // La formule que LAME impose pour un tampon qui ne peut pas déborder.
        // Le terme constant couvre la vidange du réservoir de bits ; le facteur
        // 1,25 couvre le pire cas de trame.
        var out = [UInt8](repeating: 0, count: (samples.count * 5) / 4 + 7200)

        let written = out.withUnsafeMutableBufferPointer { buffer in
            lame_encode_buffer(gfp, base, nil, Int32(samples.count),
                               buffer.baseAddress, Int32(buffer.count))
        }
        guard written >= 0 else { throw Failure.encodingFailed(code: written) }

        return Data(out.prefix(Int(written)))
    }

    /// Vide le réservoir de bits et rend les derniers octets du flux.
    ///
    /// **Le contexte reste ouvert**, et c'est nécessaire : `infoTag()` a encore
    /// besoin de lui pour connaître le compte final des trames. La fermeture
    /// revient à `deinit`, ou à cet appel lui-même s'il échoue. Ne pas
    /// ré-encoder après.
    func finish() throws -> Data {
        guard let gfp = flags else { return Data() }

        var out = [UInt8](repeating: 0, count: 7200)
        let written = out.withUnsafeMutableBufferPointer { buffer in
            lame_encode_flush(gfp, buffer.baseAddress, Int32(buffer.count))
        }
        guard written >= 0 else {
            close()
            throw Failure.encodingFailed(code: written)
        }

        return Data(out.prefix(Int(written)))
    }

    /// La trame Info à écrire **par-dessus le début du fichier**, une fois tout
    /// l'audio encodé.
    ///
    /// À appeler après `finish()` et avant `deinit`. Rend `nil` si LAME n'a rien
    /// à écrire — le fichier reste alors valable, simplement sans en-tête.
    ///
    /// **La taille se demande ici, jamais à l'initialisation.** `lame_get_lametag_frame`
    /// commence par vérifier que la table de positions n'est pas vide et rend `0`
    /// tant qu'aucune trame n'a été encodée : une taille relevée après
    /// `lame_init_params` vaut donc zéro, et la version qui la gardait de là
    /// n'écrivait jamais l'en-tête. Le fichier sortait avec la trame réservée
    /// telle quelle — quarante octets d'en-tête MPEG suivis de zéros — ce qui se
    /// lit sans erreur nulle part, et ne se voit qu'en ouvrant le fichier octet
    /// par octet.
    ///
    /// Le premier appel avec un tampon nul rend la taille nécessaire ; le second
    /// écrit. C'est le protocole que LAME impose, et il n'y a pas de raccourci :
    /// la taille dépend du nombre de trames produites.
    func infoTag() -> Data? {
        guard let gfp = flags else { return nil }

        let needed = lame_get_lametag_frame(gfp, nil, 0)
        guard needed > 0 else { return nil }

        var out = [UInt8](repeating: 0, count: needed)
        let written = out.withUnsafeMutableBufferPointer { buffer in
            lame_get_lametag_frame(gfp, buffer.baseAddress, buffer.count)
        }
        guard written == needed else { return nil }

        return Data(out)
    }

    /// Fermeture unique. Le `nil` n'est pas de la coquetterie : `lame_close`
    /// appelé deux fois sur le même contexte corrompt le tas, et il y a trois
    /// chemins qui ferment (échec d'init, `finish`, `deinit`).
    private func close() {
        guard let gfp = flags else { return }
        flags = nil
        lame_close(gfp)
    }
}
