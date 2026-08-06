import BranWatch
import Foundation
import Observation

/// Ce que le contrôleur donne au journal : une voie résolue, et d'où vient son
/// verdict. `Lane` ne porte pas la source — le résolveur n'a pas à la connaître,
/// mais le journal, si : sans elle, impossible de rejouer un taux de fausses
/// alertes par capteur, donc impossible d'améliorer les seuils.
struct LaneRecord: Sendable {
    let lane: Lane
    let source: WatchEvent.Source
}

/// **Le journal du veilleur : un fichier par jour, en ajout continu.**
///
/// ```
/// ~/…/bran/Veille/
///   2026-08-05.jsonl
///   2026-08-06.jsonl   ← ouvert, en ajout
/// ```
///
/// Le store **ne décide rien** : `WatchLedger` porte la règle de fusion — un
/// intervalle par voie, étendu tant que l'état ne change pas — et lui se
/// contente de sérialiser les intervalles qu'elle lui rend. C'est le même
/// découpage que partout ailleurs dans bran, et il a la même conséquence : la
/// règle se teste sans disque, le disque n'a aucune règle à connaître.
///
/// **Pourquoi un fichier par jour et pas un fichier continu.** La rétention
/// devient un `removeItem` après avoir lu la date dans le nom : zéro lecture,
/// zéro réécriture. Un fichier unique obligerait à relire, filtrer et réécrire
/// un fichier vivant ouvert en ajout — c'est-à-dire à choisir entre perdre des
/// lignes et bloquer le veilleur.
///
/// **Pourquoi pas le patron de `FeatureLog.append`.** Celui-ci relit tout le
/// fichier et le réécrit à chaque ligne. Correct pour un journal de mise au
/// point plafonné à 200 lignes, absurde à quelques centaines de lignes par jour
/// pendant un an : on écrirait des mégaoctets pour ajouter 200 octets. Ici, un
/// `FileHandle` ouvert une fois, `seekToEnd()` une fois, puis des
/// `write(contentsOf:)`.
@MainActor
@Observable
final class WatchStore {

    /// Les intervalles déjà fermés **du jour**. C'est tout ce que l'interface
    /// affiche : personne n'ouvre le veilleur pour lire avant-hier.
    private(set) var today: [WatchEvent] = []
    private(set) var problem: String?
    private(set) var journalBytes: Int64 = 0

    /// Secondes d'attente déjà consignées aujourd'hui. La dette *en cours* vit
    /// dans les intervalles encore ouverts — c'est `WatchVerdict.waitDebt`, que
    /// le résolveur calcule déjà, et il n'y a aucune raison de la compter deux
    /// fois.
    private(set) var waitSecondsToday: TimeInterval = 0

    /// Le dossier suit celui des enregistrements : changer la destination dans
    /// les réglages déplace tout d'un coup. Une fermeture plutôt qu'une `URL`
    /// figée, sinon le store garderait l'ancien dossier jusqu'au prochain
    /// lancement.
    private let root: @MainActor () -> URL
    private var retention: WatchRetention
    private var ledger: WatchLedger

    /// Le `FileHandle` du jour, gardé ouvert. Rouvert au changement de jour.
    private var handle: FileHandle?
    private var openDay: String?

    init(
        root: @escaping @MainActor () -> URL,
        retention: WatchRetention = .default,
        tickInterval: TimeInterval = 4
    ) {
        self.root = root
        self.retention = retention
        self.ledger = WatchLedger(tickInterval: tickInterval)
    }

    var folder: URL {
        root().appending(path: "Veille", directoryHint: .isDirectory)
    }

    func setRetention(_ policy: WatchRetention, tickInterval: TimeInterval) {
        retention = policy
        ledger.pulse = tickInterval * 2.5
        if policy.keepsNothing { closeFile() }
        Task { await purgeExpired() }
    }

    // MARK: - Lecture

    func reload() async {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let files = try FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]
            )

            journalBytes = files
                .filter { $0.pathExtension == "jsonl" }
                .reduce(into: Int64(0)) { total, url in
                    total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                }

            today = readDay(WatchDay.key(for: .now))
            waitSecondsToday = today.filter { $0.state == .waiting }.reduce(0) { $0 + $1.d }
            problem = nil
        } catch {
            problem = "Dossier du journal inaccessible : \(error.localizedDescription)"
        }
    }

    /// Relit un fichier-jour. Une ligne illisible est **sautée, pas fatale** :
    /// le fichier est écrit en continu par un processus vivant, et la dernière
    /// ligne peut être coupée au milieu par une coupure de courant. C'est
    /// exactement la leçon de CR-6 sur les transcriptions, appliquée à nos
    /// propres fichiers.
    private func readDay(_ day: String) -> [WatchEvent] {
        let url = folder.appending(path: "\(day).jsonl")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        return text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line in
                guard let data = line.data(using: .utf8) else { return nil }
                return try? decoder.decode(WatchEvent.self, from: data)
            }
    }

    // MARK: - Écriture

    /// Absorbe un verdict. **N'écrit que ce qui vient de changer.**
    ///
    /// - Parameter elapsed: le temps écoulé depuis le battement précédent, sur
    ///   `SuspendingClock`. C'est lui qui alimente `d`, et c'est pour ça qu'une
    ///   nuit de veille n'ajoute pas huit heures à un intervalle ouvert.
    func record(_ records: [LaneRecord], at now: Date, elapsed: TimeInterval) {
        for record in records {
            if let closed = ledger.beat(
                lane: record.lane,
                at: now,
                elapsed: elapsed,
                source: record.source
            ) {
                write(closed)
            }
        }

        let seen = Set(records.map(\.lane.identity.key))
        for closed in ledger.closeMissing(keeping: seen) {
            write(closed)
        }
    }

    /// Ferme tous les intervalles ouverts.
    ///
    /// Appelée à la mise en veille, à la fermeture de bran et au changement de
    /// jour. Un intervalle qu'on n'écrit pas est un intervalle perdu — et c'est
    /// justement celui qui durait le plus longtemps.
    func flush() {
        for closed in ledger.flush() { write(closed) }
    }

    private func write(_ event: WatchEvent) {
        today.insert(event, at: 0)
        if event.state == .waiting { waitSecondsToday += event.d }
        append(event)
    }

    /// Écrit une ligne. Le `FileHandle` est ouvert une fois et gardé.
    private func append(_ event: WatchEvent) {
        guard retention.keepsNothing == false else { return }

        // Le fichier est celui du **début** de l'intervalle : un intervalle ne
        // traverse jamais minuit, puisqu'on ferme tout au changement de jour.
        let day = WatchDay.key(for: event.from)
        do {
            let handle = try self.handle(for: day)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .secondsSince1970

            var data = try encoder.encode(event)
            data.append(0x0A)
            try handle.write(contentsOf: data)
            journalBytes += Int64(data.count)
            problem = nil
        } catch {
            problem = "Journal non écrit : \(error.localizedDescription)"
        }
    }

    private func handle(for day: String) throws -> FileHandle {
        if let handle, openDay == day { return handle }

        closeFile()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let url = folder.appending(path: "\(day).jsonl")
        if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) == false {
            FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: nil)
        }

        let opened = try FileHandle(forWritingTo: url)
        // Une seule fois : les écritures suivantes repartent d'où celle-ci
        // s'arrête. Chercher la fin à chaque ligne serait un appel système de
        // plus pour une position qu'on connaît déjà.
        try opened.seekToEnd()

        handle = opened
        openDay = day
        return opened
    }

    private func closeFile() {
        try? handle?.close()
        handle = nil
        openDay = nil
    }

    /// Le jour a-t-il changé depuis la dernière écriture ?
    ///
    /// Le contrôleur s'en sert pour fermer les intervalles ouverts à minuit : un
    /// intervalle qui commence à 23 h 50 et se ferme à 8 h du matin
    /// appartiendrait à deux fichiers-jour à la fois, ce qui n'existe pas.
    func dayChanged(at now: Date = .now) -> Bool {
        WatchDay.changed(from: openDay, at: now)
    }

    // MARK: - Purge

    /// Supprime les fichiers-jour arrivés à échéance.
    ///
    /// La décision appartient à `WatchRetention`, qui prend des noms et rend des
    /// noms sans toucher au disque. Ici il ne reste que le `removeItem`.
    @discardableResult
    func purgeExpired(now: Date = .now) async -> Int {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return 0 }

        let names = files.map(\.lastPathComponent)
        let doomed = Set(retention.filesToPurge(from: names, today: WatchDay.key(for: now)))
        guard doomed.isEmpty == false else { return 0 }

        var removed = 0
        for url in files where doomed.contains(url.lastPathComponent) {
            try? manager.removeItem(at: url)
            removed += 1
        }

        if removed > 0 { await reload() }
        return removed
    }
}
