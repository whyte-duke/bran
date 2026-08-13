import AVFoundation
import BranSpeech
import Foundation
import Synchronization

/// La capture du micro pour la dictée.
///
/// ## Pourquoi ce n'est plus `AVAudioEngine`
///
/// Ça l'a été jusqu'au 12 août 2026. Ce jour-là la dictée est tombée **en
/// marche** : elle rendait quarante-huit secondes de son réel à 16h48 — rms
/// −33 à −40 dB dans le journal de CoreAudio — et du silence numérique à 16h53
/// puis 16h56 : `rms −120 dB, crête −240 dB`, c'est-à-dire zéro échantillon.
/// Même processus, même binaire, aucune autre application n'avait touché
/// l'entrée audio de l'après-midi. Rien à mettre à jour, rien à réautoriser.
///
/// Ce que le journal montrait, lui, **à chaque séance** :
///
/// ```
/// IOWorkLoopInit: 332 70-F9-4A-A8-5F-E5:output : starting
/// HALS_Device::Activate: activating device 870: CADefaultDeviceAggregate-682-10
/// ```
///
/// bran démarrait la **sortie** d'un casque Bluetooth, et faisait fabriquer un
/// périphérique **agrégé** à CoreAudio. Pour un enregistrement qui ne joue
/// rien. Dix agrégés dans la journée, un par dictée.
///
/// La cause tient à `AVAudioEngine` : sur macOS il instancie toujours son nœud
/// de sortie, qui atterrit sur la sortie par défaut. Quand
/// `kAudioOutputUnitProperty_CurrentDevice` force l'entrée sur le micro
/// intégré pendant que la sortie est ailleurs, les deux horloges diffèrent —
/// CoreAudio n'a pas le choix, il agrège. Et un agrégé qui contient des AirPods
/// exige le lien Bluetooth en mode casque : 24 kHz, micro du casque dans la
/// boucle. Si ce lien ne transporte rien, l'agrégé entier rend du silence.
///
/// ## Ce que la mesure a donné, avant d'écrire une ligne de ceci
///
/// `swift run BranSpike micro` enregistre la même chose par les deux chemins et
/// compte ce que chacun ouvre. Seize séances, même machine, même micro :
///
/// ```
///                        AVAudioEngine   AVCaptureSession
///   agrégés créés / 8          8                0
///   sortie audio ouverte      oui            aucune
///   séances muettes / 12        1                0
/// ```
///
/// Deux résultats ont décidé de cette réécriture. Le premier : l'agrégé est
/// créé **même sans casque**, micro intégré et haut-parleurs intégrés. Les
/// AirPods ne créaient pas le problème, ils le rendaient permanent. Le second :
/// une séance sur douze rendait zéro échantillon avec un micro démarré sans
/// erreur (`Digital Mic PerformStartIO returned, result 0`) et l'autorisation
/// accordée. C'est ça, « ça marchait toute la journée » — le chemin n'était pas
/// cassé, il était intermittent, et il cassait au premier démarrage après un
/// changement de route audio.
///
/// `AVCaptureSession` n'a pas de nœud de sortie audio. Il n'y a rien à jouer,
/// donc pas de seconde horloge, donc pas d'agrégé, donc un casque ne peut pas
/// entrer dans la chaîne de capture. Ce n'est pas « ça marche mieux » : c'est le
/// mécanisme retiré par construction.
///
/// ## Ce qui a disparu avec le moteur
///
/// - **`restartOnSystemDefault()`**, le repli sur le périphérique système après
///   un premier essai muet. Il existait pour contourner le silence de l'agrégé,
///   et il envoyait la capture sur le casque — c'est-à-dire sur le seul
///   périphérique qui ne pouvait pas marcher. Le 7 août il avait aussi coûté
///   trois crashes en trois minutes.
/// - **La reprise du HAL** (`halTeardownBudget`, l'erreur 35, les quatre
///   `throwing -10877`). Elle absorbait une course entre le démontage
///   asynchrone d'un contexte d'entrée et la demande du suivant.
///   `AVCaptureSession.stopRunning()` ne rend la main qu'une fois le flux
///   arrêté ; il n'y a plus de course à absorber.
/// - **Le moteur neuf par séance**, qui était un correctif contre le
///   `removeTap` sur un moteur en marche. Il n'y a plus de tap.
///
/// ## Ce qui n'a pas changé
///
/// 1. **Le tampon est partagé avec un thread qui n'est pas le nôtre.** Les
///    images arrivent sur la file du délégué, pas sur le fil principal. Elle
///    n'a pas les contraintes temps réel d'un tap `AVAudioEngine`, mais on y
///    fait quand même le strict minimum : conversion, ajout, niveau.
/// 2. **Parakeet veut du 16 kHz mono `Float32`.** Le micro intégré donne du
///    48 kHz entier ; `AVAudioConverter` fait le reste.
/// 3. **On ne touche jamais au disque ici.** Le `.wav` est écrit après l'arrêt,
///    depuis un contexte normal.
final class MicCapture: NSObject, @unchecked Sendable {

    /// Tampon partagé entre la file de capture et le reste du monde.
    private struct Shared {
        var samples: [Float] = []
        /// Historique récent des niveaux, pour la forme d'onde. Volontairement
        /// court : on dessine les deux dernières secondes, pas la séance.
        var levels: [Float] = Array(repeating: 0, count: MicCapture.levelSlots)
        var levelCursor = 0
        var peak: Float = 0
    }

    static let levelSlots = 56

    private let shared = Mutex(Shared())

    /// Une session neuve par séance. Pas pour la même raison que le moteur neuf
    /// d'avant — il n'y a plus de course à éviter — mais parce qu'une session
    /// porte son entrée, et qu'une entrée porte un périphérique qui a pu
    /// disparaître entre deux dictées. La reconstruire coûte ce que coûte
    /// `startRunning`, et c'est le seul prix de la séance.
    private var session: AVCaptureSession?

    /// La file du délégué. Sérielle : les images arrivent dans l'ordre, et
    /// `converter` n'est touché que là.
    private let queue = DispatchQueue(label: "com.opahventures.bran.micro")
    private var converter: AVAudioConverter?

    private var isRunning = false

    /// Format de sortie : celui que Parakeet attend, et rien d'autre.
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: SpeechAudioFormat.sampleRate,
        channels: SpeechAudioFormat.channelCount,
        interleaved: false
    )!

    // MARK: - Cycle de vie

    /// Démarre la capture sur le micro demandé.
    ///
    /// `uid` est celui de `AudioInputDevice` — le même identifiant sert à
    /// CoreAudio et à `AVCaptureDevice`, vérifié sur cette machine par le spike.
    /// `nil` laisse le système choisir.
    func start(deviceUID uid: String?) throws {
        guard isRunning == false else { return }

        let device = try Self.resolveDevice(uid: uid)
        FeatureLog.record("micro : périphérique retenu « \(device.localizedName) »")

        let session = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CaptureFailure.deviceRefused(device.localizedName) }
        session.addInput(input)

        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw CaptureFailure.noInput }
        session.addOutput(output)

        shared.withLock {
            $0.samples.removeAll(keepingCapacity: true)
            // Réserver d'un coup la place du plafond de durée : la file de
            // capture ne doit jamais déclencher une réallocation.
            $0.samples.reserveCapacity(
                Int(SpeechAudioFormat.sampleRate * SpeechAudioFormat.maximumDuration)
            )
            $0.levels = Array(repeating: 0, count: Self.levelSlots)
            $0.levelCursor = 0
            $0.peak = 0
        }
        queue.sync { converter = nil }

        // `startRunning` est bloquant. Mesuré sur cette machine, il rend la main
        // en quelques dizaines de millisecondes — sous le seuil de ce qui se
        // remarque au démarrage d'une dictée, et le fil principal a besoin du
        // verdict tout de suite pour ne pas afficher « écoute » sur une capture
        // qui n'a pas démarré.
        let started = Date()
        session.startRunning()
        guard session.isRunning else { throw CaptureFailure.sessionRefused }

        self.session = session
        isRunning = true
        FeatureLog.record(String(
            format: "micro : session démarrée en %.0f ms", Date().timeIntervalSince(started) * 1000
        ))
    }

    /// Arrête la capture et rend les échantillons.
    @discardableResult
    func stop() -> [Float] {
        guard isRunning else { return [] }
        stopSession()
        return shared.withLock { $0.samples }
    }

    /// `stopRunning()` ne rend la main qu'une fois le flux arrêté : après lui,
    /// plus aucune image n'arrive. Le `queue.sync` qui suit attend simplement
    /// que la dernière déjà partie ait fini d'être consommée, ce qui rend le
    /// nettoyage du convertisseur sûr sans verrou supplémentaire.
    private func stopSession() {
        session?.stopRunning()
        session = nil
        queue.sync { converter = nil }
        isRunning = false
    }

    func discard() {
        _ = stop()
        shared.withLock { $0.samples.removeAll(keepingCapacity: false) }
    }

    // MARK: - Lecture depuis le monde normal

    var duration: TimeInterval {
        Double(shared.withLock { $0.samples.count }) / SpeechAudioFormat.sampleRate
    }

    /// Les niveaux récents, remis dans l'ordre chronologique.
    var waveform: [Float] {
        shared.withLock { state in
            guard state.levels.isEmpty == false else { return [] }
            let cursor = state.levelCursor % state.levels.count
            return Array(state.levels[cursor...] + state.levels[..<cursor])
        }
    }

    /// Y a-t-il eu du son ? Sert à distinguer « rien dit » de « micro muet ».
    var peakLevel: Float { shared.withLock { $0.peak } }

    // MARK: - Choix du périphérique

    /// Résout le micro à employer, sans jamais choisir un casque tout seul.
    ///
    /// **La règle est un enseignement de la panne, pas une préférence.** Quand
    /// le périphérique réglé manque, l'ancien code repartait sur « le défaut
    /// système » — qui, casque sur les oreilles, est le casque. C'est ce repli
    /// qui a envoyé la capture sur le seul périphérique qui ne pouvait pas
    /// marcher. On préfère donc explicitement le micro intégré, qui est aussi
    /// ce que les réglages recommandent : activer le micro d'AirPods bascule le
    /// lien Bluetooth en mode casque et fait retomber la qualité d'écoute, y
    /// compris celle d'un appel en cours.
    private static func resolveDevice(uid: String?) throws -> AVCaptureDevice {
        if let uid, let device = AVCaptureDevice(uniqueID: uid) {
            return device
        }
        if let uid {
            FeatureLog.record("micro : « \(uid) » absent — repli sur le micro intégré")
        }
        if let builtIn = AudioInputDevice.builtIn?.uid,
           let device = AVCaptureDevice(uniqueID: builtIn) {
            return device
        }
        guard let fallback = AVCaptureDevice.default(for: .audio) else {
            throw CaptureFailure.noInput
        }
        FeatureLog.record("micro : aucun micro intégré — repli sur « \(fallback.localizedName) »")
        return fallback
    }

    // MARK: - Erreurs

    enum CaptureFailure: LocalizedError {
        case noInput
        case unsupportedFormat(AVAudioFormat)
        case deviceRefused(String)
        case sessionRefused

        var errorDescription: String? {
            switch self {
            case .noInput:
                "aucune entrée audio disponible"
            case .unsupportedFormat(let format):
                "format d'entrée non converti (\(Int(format.sampleRate)) Hz)"
            case .deviceRefused(let name):
                "le micro « \(name) » a été refusé par le système"
            case .sessionRefused:
                "la capture n'a pas démarré"
            }
        }
    }
}

// MARK: - La file de capture

extension MicCapture: AVCaptureAudioDataOutputSampleBufferDelegate {

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: description)

        // **Le convertisseur est construit à la première image, pas au
        // démarrage.** `AVCaptureSession` ne publie pas le format d'entrée avant
        // de livrer : le demander plus tôt donnerait une supposition, et une
        // supposition fausse ici rend du bruit blanc plutôt qu'une erreur.
        if converter == nil || converter?.inputFormat != format {
            converter = AVAudioConverter(from: format, to: targetFormat)
            FeatureLog.record(String(
                format: "micro : format d'entrée %.0f Hz, %d canal/aux",
                format.sampleRate, format.channelCount
            ))
        }
        guard let converter else { return }

        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let source = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            return
        }
        source.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frames),
            into: source.mutableAudioBufferList
        ) == noErr else { return }

        consume(source, through: converter)
    }

    private func consume(_ buffer: AVAudioPCMBuffer, through converter: AVAudioConverter) {
        guard let targetBuffer = makeTargetBuffer(for: buffer) else { return }

        // `AVAudioConverter` réclame ses données par rappel, et n'accepte le
        // tampon qu'une fois. Une boîte plutôt qu'un `var` capturé : Swift 6
        // considère ce rappel comme concurrent, même s'il est exécuté sur place.
        let consumed = Latch()
        var error: NSError?
        converter.convert(to: targetBuffer, error: &error) { _, status in
            guard consumed.close() else {
                status.pointee = .noDataNow
                return nil
            }
            status.pointee = .haveData
            return buffer
        }

        guard error == nil, let channel = targetBuffer.floatChannelData?[0] else { return }
        let count = Int(targetBuffer.frameLength)
        guard count > 0 else { return }

        // Racine du carré moyen : ce que l'oreille perçoit comme « fort »,
        // contrairement au maximum qui saute au moindre claquement de doigt.
        var sum: Float = 0
        for index in 0..<count {
            let value = channel[index]
            sum += value * value
        }
        let rms = (sum / Float(count)).squareRoot()

        shared.withLock { state in
            state.samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: count))
            state.levels[state.levelCursor % state.levels.count] = rms
            state.levelCursor += 1
            state.peak = max(state.peak, rms)
        }
    }

    private func makeTargetBuffer(for source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let ratio = targetFormat.sampleRate / source.format.sampleRate
        let capacity = AVAudioFrameCount(Double(source.frameLength) * ratio) + 64
        return AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity)
    }

    /// Verrou à usage unique : le premier appel rend `true`, les suivants
    /// `false`.
    private final class Latch: @unchecked Sendable {
        private var isOpen = true
        func close() -> Bool {
            defer { isOpen = false }
            return isOpen
        }
    }
}
