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

            case "watch":
                let mode = WatchProbe.Mode(rawValue: value(of: "--mode", in: arguments) ?? "") ?? .watch
                let interval = Double(value(of: "--interval", in: arguments) ?? "") ?? 2
                let delta = Double(value(of: "--delta", in: arguments) ?? "") ?? 0.02
                let busy = Double(value(of: "--busy", in: arguments) ?? "") ?? 0.01
                let minutes = Double(value(of: "--alert-after", in: arguments) ?? "") ?? 3
                let ticks = Int(value(of: "--ticks", in: arguments) ?? "") ?? 0
                try await WatchProbe(
                    mode: mode,
                    interval: .seconds(interval),
                    delta: delta,
                    busyRatio: busy,
                    alertMinutes: minutes,
                    ticks: ticks
                ).run()

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

          watch [--mode occlusion|cursor|watch] [--interval 2] [--delta 0.02]
                [--busy 0.01] [--alert-after 3]
              Mesure si le mouvement de pixels distingue une machine qui
              travaille d'une machine qui attend. Trois modes, dans cet ordre :

                occlusion  Une capture par fenêtre, puis un verdict : la capture
                           par fenêtre traverse-t-elle l'occultation ? Si oui,
                           une voie cachée derrière une autre reste observable.
                cursor     Le test qui peut tuer le projet. Un terminal qui
                           ATTEND montre un curseur qui clignote ; un terminal
                           qui TRAVAILLE peut rester figé entre deux outils. Si
                           les ratios ne se séparent pas, le signal est mort.
                watch      La vraie mesure, sur une journée. Alertes annotables,
                           plus lecture de ~/.claude/projects (trois champs,
                           jamais de contenu).

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
