import AVFoundation
import BranSpeech
import FluidAudio
import Foundation

/// Mesure Parakeet sur *cette* machine.
///
/// Les chiffres publiés annoncent 110× à 190× le temps réel sur M4 Pro. Sur un
/// M2 Pro ce sera moins, et « moins » n'est pas une donnée. Lancé depuis le
/// Terminal, ce spike hérite de l'autorisation micro du Terminal : pas besoin
/// du certificat bran-dev pour obtenir la mesure.
///
/// ```
/// swift run BranSpike speech --seconds 20
/// swift run BranSpike speech --file ~/un-fichier.wav
/// ```
struct SpeechSpike {

    let seconds: Double
    let file: URL?
    let language: SpeechLanguage

    func run() async throws {
        let directory = URL.applicationSupportDirectory
            .appending(path: "FluidAudio", directoryHint: .isDirectory)
            .appending(path: "Models", directoryHint: .isDirectory)

        let alreadyThere = AsrModels.modelsExist(at: directory)
        print("■ modèle \(alreadyThere ? "présent sur le disque" : "absent — téléchargement à venir")")

        // 1 — Chargement
        let loadStart = Date()
        let models = try await AsrModels.downloadAndLoad(
            to: directory,
            version: .v3,
            progressHandler: { progress in
                let percent = Int(progress.fractionCompleted * 100)
                if percent % 10 == 0 { print("  téléchargement \(percent) %") }
            }
        )
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        let loadDuration = Date().timeIntervalSince(loadStart)

        print("■ chargement \(format(loadDuration)) s (\(alreadyThere ? "à froid, depuis le disque" : "téléchargement inclus"))")
        print("■ occupation disque \(bytes(size(of: directory)))")
        print("■ mémoire résidente \(bytes(Int64(residentBytes())))")

        // 2 — Échantillons
        let samples: [Float]
        let sourceDuration: Double

        if let file {
            samples = try readSamples(from: file)
            sourceDuration = Double(samples.count) / SpeechAudioFormat.sampleRate
            print("■ fichier \(file.lastPathComponent) — \(format(sourceDuration)) s")
        } else {
            print("■ parlez pendant \(Int(seconds)) secondes…")
            samples = try await record(seconds: seconds)
            sourceDuration = Double(samples.count) / SpeechAudioFormat.sampleRate
        }

        guard samples.isEmpty == false else {
            print("✗ aucun échantillon capturé")
            return
        }

        // 3 — Transcription
        var state = try TdtDecoderState()
        let hint = language.code.flatMap { Language(rawValue: $0) }

        let transcribeStart = Date()
        let result = try await manager.transcribe(samples, decoderState: &state, language: hint)
        let transcribeDuration = Date().timeIntervalSince(transcribeStart)

        print("")
        print("■ transcription \(format(transcribeDuration)) s pour \(format(sourceDuration)) s d'audio")
        print("■ rapport \(format(sourceDuration / transcribeDuration))× le temps réel")
        print("■ confiance \(format(Double(result.confidence)))")
        print("■ mémoire après \(bytes(Int64(residentBytes())))")
        print("")
        print("« \(result.text) »")
        print("")

        // 4 — Extrapolation, puisque c'est la question posée
        let ratio = sourceDuration / transcribeDuration
        print("■ à ce rythme : 2 min → \(format(120 / ratio)) s · 4 min → \(format(240 / ratio)) s")

        await manager.cleanup()
    }

    // MARK: - Capture

    private func record(seconds: Double) async throws -> [Float] {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)

        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: SpeechAudioFormat.sampleRate,
            channels: SpeechAudioFormat.channelCount,
            interleaved: false
        ), let converter = AVAudioConverter(from: inputFormat, to: target) else {
            throw SpikeFailure.noConverter
        }

        let collector = SampleCollector()

        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { buffer, _ in
            let ratio = target.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }

            // Boîte plutôt qu'un `var` capturé : Swift 6 refuse la mutation
            // d'une variable locale depuis une fermeture qu'il considère
            // concurrente, même si elle est appelée sur place.
            let consumed = Box(false)
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if consumed.value { status.pointee = .noDataNow; return nil }
                consumed.value = true
                status.pointee = .haveData
                return buffer
            }

            guard error == nil, let channel = out.floatChannelData?[0] else { return }
            collector.append(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
        }

        engine.prepare()
        try engine.start()
        try await Task.sleep(for: .seconds(seconds))
        input.removeTap(onBus: 0)
        engine.stop()

        return collector.drain()
    }

    private func readSamples(from url: URL) throws -> [Float] {
        let audioFile = try AVAudioFile(forReading: url)
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: SpeechAudioFormat.sampleRate,
            channels: SpeechAudioFormat.channelCount,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(audioFile.length)
        ) else { throw SpikeFailure.noConverter }

        try audioFile.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    // MARK: - Mesures

    private func size(of directory: URL) -> Int64 {
        guard let walker = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }

    private func residentBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    private func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private func bytes(_ count: Int64) -> String {
        ByteCountFormatStyle(style: .file).format(count)
    }

    enum SpikeFailure: Error { case noConverter }
}

private final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

/// Accumulateur partagé entre le thread audio et l'appelant.
private final class SampleCollector: @unchecked Sendable {
    private var storage: [Float] = []
    private let lock = NSLock()

    func append(_ buffer: UnsafeBufferPointer<Float>) {
        lock.lock()
        storage.append(contentsOf: buffer)
        lock.unlock()
    }

    func drain() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
