import AVFoundation
import BranSpeech
import Foundation

@main
struct BranSpike {
    static func main() async {
        var arguments = CommandLine.arguments.dropFirst()
        let command = arguments.popFirst()

        do {
            switch command {
            case "titles":
                let interval = Double(value(of: "--interval", in: arguments) ?? "") ?? 5
                try await TitlesProbe(interval: .seconds(interval)).run()

            case "record":
                let duration = Double(value(of: "--duration", in: arguments) ?? "") ?? 30
                let output = value(of: "--output", in: arguments).map(URL.init(fileURLWithPath:))
                let scale = Double(value(of: "--scale", in: arguments) ?? "") ?? 1
                let codec: AVVideoCodecType = value(of: "--codec", in: arguments) == "hevc" ? .hevc : .h264
                try await CaptureSpike(
                    duration: .seconds(duration),
                    output: output,
                    scale: scale,
                    codec: codec
                ).run()

            case "inspect":
                guard let path = arguments.first else { throw SpikeUsageError.missingPath }
                try await FileReport.print(for: URL(fileURLWithPath: path))

            case "speech":
                let seconds = Double(value(of: "--seconds", in: arguments) ?? "") ?? 20
                let file = value(of: "--file", in: arguments).map(URL.init(fileURLWithPath:))
                let code = value(of: "--language", in: arguments) ?? "french"
                try await SpeechSpike(
                    seconds: seconds,
                    file: file,
                    language: SpeechLanguage(rawValue: code) ?? .french
                ).run()

            case "ocr":
                await OCRSpike.run(Array(arguments))

            default:
                printUsage()
                exit(command == nil ? 1 : 2)
            }
        } catch {
            FileHandle.standardError.write(Data("✗ \(error)\n".utf8))
            exit(1)
        }
    }

    private static func value(of flag: String, in arguments: ArraySlice<String>) -> String? {
        guard let index = arguments.firstIndex(of: flag) else { return nil }
        let next = arguments.index(after: index)
        return next < arguments.endIndex ? arguments[next] : nil
    }

    private static func printUsage() {
        print("""
        bran spike — outils de dérisquage Phase 1

          titles [--interval 5]
              Journalise en continu les titres de fenêtres et le verdict de
              MeetTitleMatcher. À lancer PENDANT une vraie réunion Meet, en
              changeant d'onglet, pour mesurer les vrais formats de titre.

          record [--duration 30] [--scale 1] [--codec h264|hevc] [--output <chemin.mp4>]
              Enregistre l'écran + l'audio système + le micro via SCRecordingOutput
              dans un seul .mp4, puis inspecte le fichier produit.
              --scale multiplie la résolution logique de l'écran :
                1,0 → ≈1 Go/h   1,5 → ≈2 Go/h   2,0 → Retina natif, ≈4 Go/h

          inspect <chemin.mp4>
              Rapport sur un fichier existant. Sert au test de résilience :
              après un `kill -9` en cours d'enregistrement, le .mp4 est-il
              encore lisible ?

          speech [--seconds 20] [--file <chemin.wav>] [--language french]
              Mesure Parakeet TDT 0.6B v3 sur CETTE machine : temps de
              chargement à froid, mémoire résidente, place occupée sur le
              disque, et rapport au temps réel. Les 110-190× annoncés le sont
              sur M4 Pro ; ici on obtient le vrai chiffre.

        Lancer depuis le Terminal : les autorisations TCC (Enregistrement de
        l'écran, Microphone) sont celles du Terminal, pas besoin du certificat
        bran-dev à ce stade.
        """)
    }
}

enum SpikeUsageError: Error, CustomStringConvertible {
    case missingPath

    var description: String { "Chemin de fichier manquant : bran-spike inspect <chemin.mp4>" }
}
