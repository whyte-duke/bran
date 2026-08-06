import AVFoundation
import BranSpeech
import Foundation
import Synchronization

/// La capture du micro pour la dictée.
///
/// Trois contraintes qui dictent la forme du code :
///
/// 1. **Le callback du tap tourne sur un thread audio temps réel.** Pas
///    d'allocation, pas d'accès `@MainActor`, pas de `print`. Un dépassement de
///    délai fait craquer le son de tout le système. On y fait donc le strict
///    minimum : conversion, ajout au tampon, calcul du niveau.
/// 2. **Parakeet veut du 16 kHz mono `Float32`.** Le micro intégré donne du
///    48 kHz, les AirPods du 16 kHz mono déjà. `AVAudioConverter` gère les deux.
/// 3. **On ne touche jamais au disque ici.** Le `.wav` est écrit après l'arrêt,
///    depuis un contexte normal. Écrire dans le callback marcherait presque
///    toujours, et raterait exactement quand la machine est chargée.
final class MicCapture: @unchecked Sendable {

    /// Tampon partagé entre le thread audio et le reste du monde.
    ///
    /// `Mutex` plutôt qu'un acteur : un acteur imposerait un `await` dans le
    /// callback temps réel, ce qui est précisément interdit.
    private struct Shared {
        var samples: [Float] = []
        /// Historique récent des niveaux, pour la forme d'onde. Volontairement
        /// court : on dessine les deux dernières secondes, pas la séance.
        var levels: [Float] = Array(repeating: 0, count: MicCapture.levelSlots)
        var levelCursor = 0
        var peak: Float = 0
    }

    static let levelSlots = 56

    private let engine = AVAudioEngine()
    private let shared = Mutex(Shared())
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

    func start(deviceID: AudioDeviceID?) throws {
        guard isRunning == false else { return }

        // Choisir le micro AVANT de toucher au moteur : changer de périphérique
        // sur un moteur démarré le laisse dans un état incohérent.
        if let deviceID {
            try Self.setInputDevice(deviceID, on: engine)
        }

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)

        FeatureLog.record(String(
            format: "micro : format d'entrée %.0f Hz, %d canal/aux, périphérique imposé=%@",
            inputFormat.sampleRate, inputFormat.channelCount,
            deviceID == nil ? "non (système)" : "oui"
        ))

        guard inputFormat.sampleRate > 0 else {
            // Arrive quand le périphérique choisi vient d'être débranché.
            throw CaptureFailure.noInput
        }

        converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        guard converter != nil else { throw CaptureFailure.unsupportedFormat(inputFormat) }

        shared.withLock {
            $0.samples.removeAll(keepingCapacity: true)
            // Réserver d'un coup la place du plafond de durée : le thread temps
            // réel ne doit jamais déclencher une réallocation.
            $0.samples.reserveCapacity(
                Int(SpeechAudioFormat.sampleRate * SpeechAudioFormat.maximumDuration)
            )
            $0.levels = Array(repeating: 0, count: Self.levelSlots)
            $0.levelCursor = 0
            $0.peak = 0
        }

        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            self?.consume(buffer)
        }

        engine.prepare()
        try engine.start()
        isRunning = true
        FeatureLog.record("micro : moteur démarré, engine.isRunning=\(engine.isRunning)")
    }

    /// Reprend sur le périphérique système après un premier essai muet.
    ///
    /// **Pourquoi ce repli existe.** Imposer un périphérique précis à
    /// `AVAudioEngine` via `kAudioOutputUnitProperty_CurrentDevice` réussit sans
    /// erreur, démarre le moteur sans erreur, et peut malgré tout ne jamais
    /// appeler le tap : zéro échantillon, aucun signal. Constaté sur ce Mac avec
    /// le micro intégré explicitement choisi, alors que le même moteur laissé sur
    /// le périphérique système fonctionne.
    ///
    /// Plutôt que de deviner quel réglage CoreAudio en est responsable, on
    /// constate le silence et on repart sur le défaut système — qui est le
    /// chemin le mieux testé de macOS.
    func restartOnSystemDefault() throws {
        guard isRunning else { return }
        FeatureLog.record("micro : aucun son sur le périphérique imposé → reprise sur le système")
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        converter = nil
        try start(deviceID: nil)
    }

    /// Arrête le moteur et rend les échantillons capturés.
    @discardableResult
    func stop() -> [Float] {
        guard isRunning else { return [] }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        converter = nil
        return shared.withLock { $0.samples }
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

    // MARK: - Thread temps réel

    private func consume(_ buffer: AVAudioPCMBuffer) {
        guard let converter, let targetBuffer = makeTargetBuffer(for: buffer) else { return }

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

    // MARK: - Choix du périphérique

    /// Impose un périphérique d'entrée au moteur.
    ///
    /// `AVAudioEngine` n'expose pas ça directement sur macOS : il faut descendre
    /// jusqu'à l'unité audio sous-jacente.
    private static func setInputDevice(_ deviceID: AudioDeviceID, on engine: AVAudioEngine) throws {
        guard let unit = engine.inputNode.audioUnit else { throw CaptureFailure.noInput }
        var identifier = deviceID
        let status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &identifier,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else { throw CaptureFailure.deviceRefused(status) }
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

    enum CaptureFailure: LocalizedError {
        case noInput
        case unsupportedFormat(AVAudioFormat)
        case deviceRefused(OSStatus)

        var errorDescription: String? {
            switch self {
            case .noInput:
                "aucune entrée audio disponible"
            case .unsupportedFormat(let format):
                "format d'entrée non converti (\(Int(format.sampleRate)) Hz)"
            case .deviceRefused(let status):
                "le micro choisi a été refusé par le système (code \(status))"
            }
        }
    }
}
