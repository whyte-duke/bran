import BranSpeech
import BranVision
import BranWatch
import Foundation
import Observation

/// Ce qui relit le journal du veilleur **sur plusieurs jours** et le donne à
/// `WeekSummary`.
///
/// `WatchStore` ne garde que le jour courant en mémoire — c'est délibéré, la
/// section Veille montre ce qui se passe, pas ce qui s'est passé. Le journal de
/// bord, lui, a besoin d'une semaine entière ; il relit donc les fichiers
/// lui-même, en lecture seule, sans rien changer au store qui les écrit.
///
/// La lecture est **hors du fil principal** : sept fichiers de quelques
/// centaines de lignes, c'est court, mais trente en portée « mois » ne le sont
/// plus, et une section qui bloque en s'ouvrant se remarque immédiatement.
@MainActor
@Observable
final class WeekLoader {

    /// L'état du chargement. **`loading` existe séparément de « vide »** : au
    /// premier affichage les deux se ressemblent, et l'un des deux est faux.
    /// C'est le défaut d'interface n° 1 de cette application, et il n'a pas à
    /// être reproduit dans une section neuve.
    enum Phase: Equatable {
        case loading
        case ready
        case failed(String)
    }

    private(set) var phase: Phase = .loading
    private(set) var summary: WeekSummary = .empty

    /// La portée demandée. La vue la change, `load` la relit.
    var span: WeekSpan = .week

    private let folder: @MainActor () -> URL

    /// Le dossier suit celui du veilleur par une fermeture, comme partout
    /// ailleurs : changer la destination dans les réglages doit déplacer la
    /// lecture aussi, pas seulement l'écriture.
    init(folder: @escaping @MainActor () -> URL) {
        self.folder = folder
    }

    // MARK: - Chargement

    func load(markers: [WeekMarker], now: Date = .now, calendar: Calendar = .current) async {
        // On n'annonce « en cours » que si l'écran est encore vide. Repasser en
        // squelette à chaque rafraîchissement ferait clignoter une vue qui a
        // déjà tout ce qu'il faut à montrer.
        if summary.isEmpty { phase = .loading }

        let keys = dayKeys(now: now, calendar: calendar)
        let directory = folder()

        let harvest = await Task.detached(priority: .userInitiated) {
            Self.harvest(from: directory, days: keys)
        }.value

        summary = WeekSummary.make(
            events: harvest.events,
            markers: markers,
            now: now,
            span: span,
            calendar: calendar
        )
        phase = harvest.problem.map(Phase.failed) ?? .ready
    }

    private func dayKeys(now: Date, calendar: Calendar) -> [String] {
        let today = calendar.startOfDay(for: now)
        return (0..<span.days).reversed().compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: today)
                .map { WatchDay.key(for: $0, calendar: calendar) }
        }
    }

    // MARK: - Lecture des fichiers

    private struct Harvest: Sendable {
        let events: [WatchEvent]
        let problem: String?
    }

    /// Relit les fichiers-jour demandés.
    ///
    /// Un fichier absent est **normal** : c'est un jour sans veille, pas une
    /// panne. Une ligne illisible est sautée, jamais fatale — le fichier est
    /// écrit en continu par un processus vivant, et sa dernière ligne peut être
    /// coupée au milieu par une coupure de courant. Seul un fichier présent et
    /// refusé par le système remonte comme un problème.
    private nonisolated static func harvest(from folder: URL, days: [String]) -> Harvest {
        let manager = FileManager.default
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        var events: [WatchEvent] = []
        var problem: String?

        for day in days {
            let url = folder.appending(path: "\(day).jsonl")
            guard manager.fileExists(atPath: url.path(percentEncoded: false)) else { continue }

            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                    guard let data = line.data(using: .utf8),
                          let event = try? decoder.decode(WatchEvent.self, from: data)
                    else { continue }
                    events.append(event)
                }
            } catch {
                problem = "Journal du \(day) illisible : \(error.localizedDescription)"
            }
        }

        return Harvest(events: events, problem: problem)
    }
}

// MARK: - Les trois autres sources, ramenées à une forme commune

extension WeekLoader {

    /// Fusionne réunions, dictées et captures en une seule liste de repères.
    ///
    /// C'est ici que le journal de bord tient sa promesse : les quatre sources
    /// sur une seule horloge. Chacune garde son store, son format et sa
    /// rétention — la vue n'en voit qu'un fil.
    static func markers(
        recordings: [Recording],
        dictations: [TranscriptEntry],
        snippets: [SnippetEntry]
    ) -> [WeekMarker] {
        var markers: [WeekMarker] = []
        markers.reserveCapacity(recordings.count + dictations.count + snippets.count)

        for recording in recordings {
            markers.append(WeekMarker(
                id: "meeting:\(recording.id.uuidString)",
                kind: .meeting,
                title: recording.displayTitle,
                at: recording.metadata.startedAt,
                duration: recording.duration
            ))
        }

        for entry in dictations {
            markers.append(WeekMarker(
                id: "dictation:\(entry.id.uuidString)",
                kind: .dictation,
                title: excerpt(of: entry.text),
                at: entry.createdAt,
                duration: entry.duration
            ))
        }

        for entry in snippets {
            markers.append(WeekMarker(
                id: "snapshot:\(entry.id.uuidString)",
                kind: .snapshot,
                title: excerpt(of: entry.text),
                at: entry.createdAt
            ))
        }

        return markers
    }

    /// Une ligne, pas un paragraphe. Le fil des jalons répond à « qu'est-ce que
    /// j'ai fait », pas à « qu'est-ce que j'ai dit » — le détail vit dans les
    /// sections Dictées et Captures, qui savent déjà le montrer.
    private static func excerpt(of text: String) -> String {
        let flat = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flat.isEmpty == false else { return "(vide)" }
        guard flat.count > 80 else { return flat }
        return String(flat.prefix(80)) + "…"
    }
}
