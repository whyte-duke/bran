import AVFoundation
import CoreAudio
import Foundation

/// Mesure ce que la capture du micro **ouvre d'autre** que le micro.
///
/// ## La panne que ce spike existe pour trancher
///
/// Le 12 août 2026, la dictée est tombée en marche : elle fonctionnait à 16h48
/// — quarante-huit secondes de son réel, rms −33 à −40 dB dans le journal de
/// CoreAudio — et rendait du silence numérique à 16h53, puis à 16h56 :
/// `rms −120 dB, crête −240 dB`, c'est-à-dire zéro échantillon. Rien n'avait
/// changé : même processus, même binaire, aucune autre application n'avait
/// touché l'entrée audio de tout l'après-midi.
///
/// Ce que le journal montrait en revanche, **à chaque dictée** :
///
/// ```
/// IOWorkLoopInit: 332 70-F9-4A-A8-5F-E5:output : starting
/// HALS_Device::Activate: activating device 870: CADefaultDeviceAggregate-682-10
/// ```
///
/// bran démarre la **sortie** des AirPods, et CoreAudio fabrique un
/// périphérique **agrégé**. Pour un enregistrement qui ne joue rien. Dix
/// agrégés dans la journée, un par séance.
///
/// L'explication tient à `AVAudioEngine` : sur macOS il instancie toujours son
/// nœud de sortie, qui atterrit sur la sortie par défaut. Quand
/// `kAudioOutputUnitProperty_CurrentDevice` force l'entrée sur le micro intégré
/// pendant que la sortie est sur un casque Bluetooth, les deux horloges ne sont
/// pas les mêmes : CoreAudio n'a pas le choix, il agrège. Et un agrégé qui
/// contient des AirPods exige le lien Bluetooth en mode casque — le HFP, à
/// 24 kHz, avec le micro du casque dans la boucle. Si ce lien ne transporte
/// rien, l'agrégé entier rend du silence.
///
/// ## Ce que le spike mesure, et pourquoi il ne se contente pas de raisonner
///
/// L'explication ci-dessus est plausible, et « plausible » ne suffit pas à
/// justifier de remplacer le chemin de capture. Le spike enregistre donc deux
/// fois la même chose, par deux chemins, et compte :
///
/// - **`engine`** — le chemin actuel : `AVAudioEngine`, périphérique d'entrée
///   imposé, tap sur le nœud d'entrée.
/// - **`capture`** — le chemin candidat : `AVCaptureSession` avec une entrée
///   audio et une sortie de données. Aucun nœud de sortie n'existe dans cette
///   API : il n'y a rien à jouer, donc rien à agréger.
///
/// Pour chacun : combien d'images sont arrivées, quel niveau crête, et surtout
/// — mesuré **hors du spike**, dans le journal unifié — combien d'agrégés ont
/// été activés et si la sortie du casque a démarré.
///
/// ```
/// swift run BranSpike micro --path engine  --seconds 3
/// swift run BranSpike micro --path capture --seconds 3
/// swift run BranSpike micro --devices
/// ```
///
/// Lancé depuis le Terminal, ce spike hérite de l'autorisation micro du
/// Terminal — comme `SpeechSpike`, et pour la même raison : la mesure ne vaut
/// que si elle est facile à relancer.
struct MicRouteSpike {

    enum Path: String {
        case engine
        case capture
    }

    let path: Path
    let seconds: Double
    /// UID du périphérique à imposer. `nil` suit le défaut système — c'est le
    /// repli dont on veut justement se débarrasser, donc il faut pouvoir le
    /// mesurer aussi.
    let deviceUID: String?
    /// Où écrire les échantillons convertis. Un compte d'échantillons dit que
    /// la conversion produit *quelque chose* ; seule l'écoute dit qu'elle
    /// produit de la parole.
    let wav: URL?

    func run() async throws {
        print("■ chemin \(path.rawValue), \(format(seconds)) s")
        Self.printDevices()

        let device = deviceUID.flatMap { uid in InputDevice.all.first { $0.uid == uid } }
        if let deviceUID {
            if let device {
                print("■ périphérique imposé : « \(device.name) » (\(device.uid))")
            } else {
                print("■ périphérique « \(deviceUID) » introuvable — on suit le système")
            }
        } else {
            print("■ aucun périphérique imposé — on suit le système")
        }

        let started = Date()
        let result: Recording

        switch path {
        case .engine:
            result = try EngineRoute().record(seconds: seconds, deviceID: device?.id)
        case .capture:
            result = try await CaptureRoute().record(seconds: seconds, uid: device?.uid)
        }

        print("")
        print("■ résultat")
        print("  format d'entrée   \(Int(result.inputSampleRate)) Hz, \(result.inputChannels) canal/aux")
        print("  images reçues     \(result.frames)")
        print("  durée effective   \(format(result.duration)) s sur \(format(seconds)) s demandées")
        print("  niveau crête      \(level(result.peak))")
        print("  verdict           \(result.frames == 0 || result.peak == 0 ? "MUET" : "du son")")

        if result.converted.isEmpty == false {
            let seconds = Double(result.converted.count) / 16000
            let peak = result.converted.reduce(Float(0)) { max($0, abs($1)) }
            print("")
            print("■ après la conversion de production (16 kHz mono Float32)")
            print("  échantillons      \(result.converted.count) — \(format(seconds)) s")
            print("  niveau crête      \(level(peak))")
            if let wav {
                try Self.writeWAV(result.converted, to: wav)
                print("  écrit             \(wav.path)")
                print("                    ↑ à écouter : c'est exactement ce que Parakeet recevra")
            }
        }
        print("")
        print("■ fenêtre à inspecter dans le journal : \(Self.stamp(started)) → \(Self.stamp(Date()))")
        print("""
          /usr/bin/log show --start '\(Self.stamp(started))' --style compact --info \\
            --predicate 'process == "coreaudiod"' \\
            | grep -E 'CADefaultDeviceAggregate|:output.*starting|rms:'
        """)
    }

    // MARK: - Ce qu'une séance rapporte

    struct Recording {
        var frames: Int
        var peak: Float
        var duration: TimeInterval
        var inputSampleRate: Double
        var inputChannels: UInt32
        /// Les échantillons **après** la conversion que `MicCapture` applique
        /// en production — 16 kHz mono `Float32`, ce que Parakeet mange. Vide
        /// sur le chemin `engine`, qui ne sert plus qu'à la comparaison.
        var converted: [Float] = []
    }

    // MARK: - Chemin 1 : AVAudioEngine, tel qu'il est aujourd'hui

    /// Reproduit `MicCapture` au plus près : moteur neuf, périphérique imposé
    /// avant de toucher au moteur, tap sur le nœud d'entrée. Volontairement
    /// sans le repli sur le défaut système : ce qu'on mesure ici, c'est ce que
    /// le chemin nominal ouvre.
    private struct EngineRoute {
        func record(seconds: Double, deviceID: AudioDeviceID?) throws -> Recording {
            let engine = AVAudioEngine()

            if let deviceID {
                guard let unit = engine.inputNode.audioUnit else {
                    throw SpikeFailure.noInput
                }
                var identifier = deviceID
                let status = AudioUnitSetProperty(
                    unit,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global,
                    0,
                    &identifier,
                    UInt32(MemoryLayout<AudioDeviceID>.size)
                )
                guard status == noErr else { throw SpikeFailure.deviceRefused(status) }
            }

            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0 else { throw SpikeFailure.noInput }

            let tally = Tally()
            input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
                tally.add(buffer)
            }

            engine.prepare()
            let started = Date()
            try engine.start()
            Thread.sleep(forTimeInterval: seconds)
            engine.stop()
            input.removeTap(onBus: 0)

            return tally.recording(
                since: started,
                sampleRate: format.sampleRate,
                channels: format.channelCount
            )
        }
    }

    // MARK: - Chemin 2 : AVCaptureSession, qui n'a pas de sortie audio

    /// La même mesure, par une API qui ne connaît que l'entrée.
    ///
    /// `AVCaptureSession` n'a pas de nœud de sortie audio : on lui donne un
    /// périphérique et une destination de données, et il ne joue rien. Il n'y a
    /// donc aucune seconde horloge à marier, et rien qui puisse entraîner un
    /// casque Bluetooth dans la chaîne. C'est l'hypothèse — ce spike la vérifie
    /// au lieu de la supposer.
    private struct CaptureRoute {
        func record(seconds: Double, uid: String?) async throws -> Recording {
            let device: AVCaptureDevice
            if let uid {
                guard let found = AVCaptureDevice(uniqueID: uid) else {
                    throw SpikeFailure.deviceMissing(uid)
                }
                device = found
            } else {
                guard let fallback = AVCaptureDevice.default(for: .audio) else {
                    throw SpikeFailure.noInput
                }
                device = fallback
            }

            let session = AVCaptureSession()
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { throw SpikeFailure.noInput }
            session.addInput(input)

            let output = AVCaptureAudioDataOutput()
            let tally = Tally()
            let collector = Collector(tally: tally)
            output.setSampleBufferDelegate(collector, queue: DispatchQueue(label: "bran.spike.micro"))
            guard session.canAddOutput(output) else { throw SpikeFailure.noInput }
            session.addOutput(output)

            let started = Date()
            session.startRunning()
            try await Task.sleep(for: .seconds(seconds))
            session.stopRunning()

            let format = collector.format
            var recording = tally.recording(
                since: started,
                sampleRate: format?.mSampleRate ?? 0,
                channels: format?.mChannelsPerFrame ?? 0
            )
            recording.converted = collector.converted
            return recording
        }

        /// Le délégué doit être une classe.
        ///
        /// Il fait deux choses, et la seconde est le vrai objet du test :
        /// compter les images brutes, **et** rejouer la conversion exacte que
        /// `MicCapture` applique en production — `CMSampleBuffer` →
        /// `AVAudioPCMBuffer` → `AVAudioConverter` vers 16 kHz mono `Float32`.
        /// C'est la seule partie du nouveau chemin qui n'existait nulle part
        /// avant ; la mesurer sur du son réel, et pouvoir l'écouter, vaut mieux
        /// que la relire.
        private final class Collector: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
            private let tally: Tally
            private(set) var format: AudioStreamBasicDescription?
            private(set) var converted: [Float] = []
            private var converter: AVAudioConverter?

            private let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16000,
                channels: 1,
                interleaved: false
            )!

            init(tally: Tally) { self.tally = tally }

            func captureOutput(
                _ output: AVCaptureOutput,
                didOutput sampleBuffer: CMSampleBuffer,
                from connection: AVCaptureConnection
            ) {
                guard let description = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
                if format == nil,
                   let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description) {
                    format = basic.pointee
                }
                tally.add(sampleBuffer)

                let inputFormat = AVAudioFormat(cmAudioFormatDescription: description)
                if converter == nil || converter?.inputFormat != inputFormat {
                    converter = AVAudioConverter(from: inputFormat, to: targetFormat)
                }
                guard let converter else { return }

                let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
                guard frames > 0,
                      let source = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frames)
                else { return }
                source.frameLength = frames
                guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
                    sampleBuffer, at: 0, frameCount: Int32(frames), into: source.mutableAudioBufferList
                ) == noErr else { return }

                let ratio = targetFormat.sampleRate / inputFormat.sampleRate
                let capacity = AVAudioFrameCount(Double(frames) * ratio) + 64
                guard let target = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity)
                else { return }

                var consumed = false
                var error: NSError?
                converter.convert(to: target, error: &error) { _, status in
                    if consumed {
                        status.pointee = .noDataNow
                        return nil
                    }
                    consumed = true
                    status.pointee = .haveData
                    return source
                }
                guard error == nil, let channel = target.floatChannelData?[0] else { return }
                converted.append(
                    contentsOf: UnsafeBufferPointer(start: channel, count: Int(target.frameLength))
                )
            }
        }
    }

    // MARK: - Le comptage, partagé par les deux chemins

    /// Compte les images et retient la crête. Le verrou est grossier et c'est
    /// voulu : un spike n'a pas les contraintes temps réel de `MicCapture`, et
    /// une mesure fausse coûterait plus cher qu'une microseconde.
    private final class Tally: @unchecked Sendable {
        private let lock = NSLock()
        private var frames = 0
        private var peak: Float = 0

        func add(_ buffer: AVAudioPCMBuffer) {
            guard let channel = buffer.floatChannelData?[0] else {
                bump(count: Int(buffer.frameLength), peak: 0)
                return
            }
            let count = Int(buffer.frameLength)
            var maximum: Float = 0
            for index in 0..<count { maximum = max(maximum, abs(channel[index])) }
            bump(count: count, peak: maximum)
        }

        func add(_ sampleBuffer: CMSampleBuffer) {
            let count = CMSampleBufferGetNumSamples(sampleBuffer)
            var maximum: Float = 0

            // Le tampon arrive en `Int16` entrelacé sur le chemin capture ; on
            // ne convertit pas, on cherche seulement s'il y a du signal.
            if let block = CMSampleBufferGetDataBuffer(sampleBuffer) {
                var length = 0
                var pointer: UnsafeMutablePointer<CChar>?
                if CMBlockBufferGetDataPointer(
                    block,
                    atOffset: 0,
                    lengthAtOffsetOut: nil,
                    totalLengthOut: &length,
                    dataPointerOut: &pointer
                ) == noErr, let pointer {
                    pointer.withMemoryRebound(to: Int16.self, capacity: length / 2) { samples in
                        for index in 0..<(length / 2) {
                            maximum = max(maximum, abs(Float(samples[index]) / 32768))
                        }
                    }
                }
            }
            bump(count: count, peak: maximum)
        }

        private func bump(count: Int, peak value: Float) {
            lock.lock()
            frames += count
            peak = max(peak, value)
            lock.unlock()
        }

        func recording(
            since started: Date,
            sampleRate: Double,
            channels: UInt32
        ) -> Recording {
            lock.lock()
            defer { lock.unlock() }
            return Recording(
                frames: frames,
                peak: peak,
                duration: sampleRate > 0 ? Double(frames) / sampleRate : 0,
                inputSampleRate: sampleRate,
                inputChannels: channels
            )
        }
    }

    // MARK: - Énumération des entrées

    /// Recopié de `AudioInputDevice` dans `BranApp` : les deux exécutables sont
    /// distincts et un `internal` ne les réunit pas. Le spike n'a besoin que de
    /// trois champs, il ne prétend pas remplacer l'original.
    struct InputDevice {
        let id: AudioDeviceID
        let uid: String
        let name: String
        let transport: String

        static var all: [InputDevice] {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var size: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
            ) == noErr else { return [] }

            let count = Int(size) / MemoryLayout<AudioDeviceID>.size
            var ids = [AudioDeviceID](repeating: 0, count: count)
            guard AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
            ) == noErr else { return [] }

            return ids.compactMap(describe)
        }

        private static func describe(_ id: AudioDeviceID) -> InputDevice? {
            guard hasInput(id), let uid = string(id, kAudioDevicePropertyDeviceUID) else {
                return nil
            }
            return InputDevice(
                id: id,
                uid: uid,
                name: string(id, kAudioObjectPropertyName) ?? uid,
                transport: transport(id)
            )
        }

        private static func hasInput(_ id: AudioDeviceID) -> Bool {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var size: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr,
                  size > 0 else { return false }

            let buffer = UnsafeMutableRawPointer.allocate(
                byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment
            )
            defer { buffer.deallocate() }
            guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, buffer) == noErr else {
                return false
            }
            let list = UnsafeMutableAudioBufferListPointer(
                buffer.assumingMemoryBound(to: AudioBufferList.self)
            )
            return list.contains { $0.mNumberChannels > 0 }
        }

        private static func string(
            _ id: AudioDeviceID,
            _ selector: AudioObjectPropertySelector
        ) -> String? {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var size = UInt32(MemoryLayout<CFString?>.size)
            var value: CFString?
            guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
                  let value else { return nil }
            return value as String
        }

        private static func transport(_ id: AudioDeviceID) -> String {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyTransportType,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var size = UInt32(MemoryLayout<UInt32>.size)
            var value: UInt32 = 0
            guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else {
                return "?"
            }
            switch value {
            case kAudioDeviceTransportTypeBuiltIn: return "intégré"
            case kAudioDeviceTransportTypeBluetooth: return "Bluetooth"
            case kAudioDeviceTransportTypeBluetoothLE: return "Bluetooth LE"
            case kAudioDeviceTransportTypeUSB: return "USB"
            case kAudioDeviceTransportTypeVirtual: return "virtuel"
            case kAudioDeviceTransportTypeAggregate: return "agrégé"
            case kAudioDeviceTransportTypeContinuityCaptureWired,
                 kAudioDeviceTransportTypeContinuityCaptureWireless: return "Continuité"
            default: return "autre"
            }
        }
    }

    static func printDevices() {
        print("■ entrées disponibles")
        let defaultInput = defaultInputUID()
        for device in InputDevice.all {
            let marker = device.uid == defaultInput ? " ← défaut système" : ""
            print("  \(device.uid.padding(toLength: 34, withPad: " ", startingAt: 0)) "
                + "\(device.transport.padding(toLength: 12, withPad: " ", startingAt: 0)) "
                + "\(device.name)\(marker)")
        }
    }

    private static func defaultInputUID() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var id: AudioDeviceID = 0
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id
        ) == noErr else { return nil }
        return InputDevice.all.first { $0.id == id }?.uid
    }

    // MARK: - Mise en forme

    private func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private func level(_ peak: Float) -> String {
        guard peak > 0 else { return "0 (silence numérique)" }
        return String(format: "%.4f (%.1f dBFS)", peak, 20 * log10(peak))
    }

    /// Écrit un `.wav` 16 kHz mono. `AVAudioFile` plutôt qu'un en-tête à la
    /// main : c'est déjà ce que la dictée emploie pour conserver l'audio.
    private static func writeWAV(_ samples: [Float], to url: URL) throws {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false
        )!
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false
            ]
        )
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)
        ), let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        try file.write(from: buffer)
    }

    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    enum SpikeFailure: LocalizedError {
        case noInput
        case deviceRefused(OSStatus)
        case deviceMissing(String)

        var errorDescription: String? {
            switch self {
            case .noInput: "aucune entrée audio disponible"
            case .deviceRefused(let status): "périphérique refusé (code \(status))"
            case .deviceMissing(let uid): "périphérique « \(uid) » introuvable"
            }
        }
    }
}
