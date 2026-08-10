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
    /// L'humain tenait-il cette voie à ce battement. Voir `WatchEvent.fg` :
    /// c'est ce champ qui décide de ce qui compte comme du travail.
    let foreground: Bool
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

    /// Les intervalles de **présence** du jour, dans le même fichier.
    ///
    /// Ils répondent à une question que les précédents ne peuvent pas poser :
    /// « étais-je là ». Sans eux, une journée sans voie observée est un trou, et
    /// un trou ne dit pas s'il s'agit d'une pause déjeuner ou d'un capteur mort.
    private(set) var presenceToday: [PresenceEvent] = []
    private(set) var journalBytes: Int64 = 0

    /// Le disque n'a pas voulu de la dernière ligne, ou ne rend plus le fichier
    /// du jour. Effacé dès qu'une écriture repasse.
    private var writeProblem: String?

    /// La rétention n'a pas été appliquée. **Vit à part de `writeProblem`**, et
    /// pas par élégance : `reload()` efface le problème d'écriture quand la
    /// lecture repasse, et la purge appelle justement `reload()` derrière elle.
    /// Un seul champ aurait donc effacé l'avertissement de rétention dans la
    /// milliseconde qui suit sa pose — un silence de plus, au même endroit que
    /// celui qu'on corrige.
    private var purgeProblem: String?

    /// Ce que le panneau affiche. Les deux pannes peuvent coexister — un volume
    /// débranché refuse l'écriture *et* la suppression — et il n'y a aucune
    /// raison d'en cacher une.
    ///
    /// La rétention passe devant : c'est la seule des deux dont la conséquence
    /// est irréversible. Une ligne non écrite est une ligne perdue ; un journal
    /// non supprimé est un journal qui reste lisible, et il reste lisible
    /// jusqu'à ce que quelqu'un l'apprenne.
    ///
    /// **Deux emplacements nommés plutôt qu'une file.** Chaque panne a le sien,
    /// donc chacune s'efface au retour de *sa* réussite : une écriture qui
    /// repasse ne fait pas disparaître un avertissement de rétention, et une
    /// purge réussie ne fait pas disparaître un disque qui refuse d'écrire. Une
    /// file d'accumulation garderait bien les deux messages, mais ne saurait
    /// plus lequel retirer.
    var problem: String? {
        let parts = [purgeProblem, writeProblem].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

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
    private var presenceLedger: PresenceLedger

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
        self.presenceLedger = PresenceLedger(tickInterval: tickInterval)
    }

    var folder: URL {
        root().appending(path: "Veille", directoryHint: .isDirectory)
    }

    func setRetention(_ policy: WatchRetention, tickInterval: TimeInterval) {
        retention = policy
        ledger.pulse = tickInterval * 2.5
        presenceLedger.pulse = tickInterval * 2.5
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
        } catch {
            writeProblem = "Dossier du journal inaccessible : \(error.localizedDescription)"
            return
        }

        do {
            let lines = try readDay(WatchDay.key(for: .now))
            today = lines.lanes
            presenceToday = lines.presence
            waitSecondsToday = today.filter { $0.state == .waiting }.reduce(0) { $0 + $1.d }
            writeProblem = nil
        } catch {
            // **On vide plutôt que de garder.** Ce qui était en mémoire venait
            // d'une lecture précédente ; le montrer sous un fichier devenu
            // illisible, c'est afficher une journée qu'on ne sait plus lire.
            // C'est le même défaut que l'insertion optimiste de `write`, une
            // couche plus haut.
            today = []
            presenceToday = []
            waitSecondsToday = 0
            writeProblem = """
                Journal du jour illisible : \(error.localizedDescription). \
                La journée affichée est donc vide, pas terminée.
                """
        }
    }

    /// Relit un fichier-jour. Une ligne illisible est **sautée, pas fatale** :
    /// le fichier est écrit en continu par un processus vivant, et la dernière
    /// ligne peut être coupée au milieu par une coupure de courant. C'est
    /// exactement la leçon de CR-6 sur les transcriptions, appliquée à nos
    /// propres fichiers.
    ///
    /// **Deux formes dans un seul fichier**, et c'est la même tolérance qui les
    /// sépare. Une ligne de présence porte `k` et n'a ni `lane` ni `state` ;
    /// une ligne de voie a l'inverse. Chacun des deux décodeurs échoue
    /// proprement sur les lignes de l'autre, exactement comme il échoue déjà sur
    /// une ligne coupée en deux. Aucun aiguillage à écrire, aucun format à
    /// migrer : les journaux d'avant la présence se relisent tels quels.
    ///
    /// **Un fichier absent n'est pas une erreur, un fichier illisible en est
    /// une.** Les deux rendaient la même journée vide, et c'était le troisième
    /// silence du même fichier : avant le premier battement du matin, il n'y a
    /// rien à lire — après, un `String(contentsOf:)` qui échoue veut dire qu'on
    /// affiche une journée blanche sur un journal qui, lui, n'est pas blanc.
    private func readDay(_ day: String) throws -> (lanes: [WatchEvent], presence: [PresenceEvent]) {
        let url = folder.appending(path: "\(day).jsonl")
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            return ([], [])
        }
        let text = try String(contentsOf: url, encoding: .utf8)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        var lanes: [WatchEvent] = []
        var presence: [PresenceEvent] = []

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8) else { continue }
            if let event = try? decoder.decode(PresenceEvent.self, from: data) {
                presence.append(event)
            } else if let event = try? decoder.decode(WatchEvent.self, from: data) {
                lanes.append(event)
            }
        }

        return (lanes, presence)
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
                source: record.source,
                foreground: record.foreground
            ) {
                write(closed)
            }
        }

        let seen = Set(records.map(\.lane.identity.key))
        for closed in ledger.closeMissing(keeping: seen) {
            write(closed)
        }
    }

    /// Absorbe la présence de l'humain. Même contrat que `record(_:at:elapsed:)`,
    /// sur un registre qui n'a qu'un intervalle ouvert puisqu'il n'y a qu'un
    /// humain.
    ///
    /// **Appelée même quand le veilleur se tait**, et c'est tout l'intérêt : les
    /// moments où il se tait — écran éteint, réunion en cours, économie
    /// d'énergie — sont précisément ceux où l'on veut savoir si quelqu'un était
    /// là. La présence ne coûte aucune capture d'écran et n'écrit aucun titre.
    func record(presence: Presence, at now: Date, elapsed: TimeInterval) {
        if let closed = presenceLedger.beat(presence, at: now, elapsed: elapsed) {
            write(closed)
        }
    }

    /// Ferme le seul intervalle de présence ouvert, sans toucher aux voies.
    /// Appelée quand le capteur d'inactivité devient muet : mieux vaut un trou
    /// qu'un intervalle prolongé sur une mesure absente.
    func flushPresence() {
        if let closed = presenceLedger.flush() { write(closed) }
    }

    /// Écrit l'absence correspondant à une veille machine, dont on n'apprend les
    /// bornes qu'au réveil. Sans elle, une nuit laisserait un trou là où il y a
    /// une absence parfaitement connue.
    func recordSleep(seconds: TimeInterval, endingAt now: Date) {
        for closed in presenceLedger.slept(for: seconds, endingAt: now) {
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
        if let closed = presenceLedger.flush() { write(closed) }
    }

    /// **Le disque d'abord, la mémoire ensuite.**
    ///
    /// L'ordre inverse — insérer puis écrire — donnait à l'interface un
    /// intervalle que le fichier n'avait jamais reçu : la liste du jour comptait
    /// une ligne de plus que le journal, et `waitSecondsToday` annonçait une
    /// dette d'attente qui n'existait que jusqu'au prochain `reload()`, où elle
    /// disparaissait sans explication.
    ///
    /// **Pourquoi cet ordre ne coûte rien, alors qu'un battement passe toutes
    /// les quelques secondes.** `append` était déjà synchrone et déjà appelé
    /// ici : le `FileHandle` est ouvert une fois pour la journée, l'écriture est
    /// un `write(2)` de deux cents octets à une position connue. Il n'y a pas de
    /// nouvelle attente disque — il y a la même, dans l'autre sens. La solution
    /// qui aurait coûté cher, c'est celle qu'on n'a pas prise : rendre `append`
    /// asynchrone pour confirmer après coup, ce qui aurait mis un point de
    /// suspension sur le chemin chaud et permis à deux battements de se croiser.
    ///
    /// **Pourquoi jeter et non pas garder.** Un intervalle refusé par le disque
    /// est perdu de toute façon : le prochain `reload()` reconstruit `today`
    /// depuis le fichier et l'aurait fait disparaître. Le garder n'ajoute donc
    /// pas de durabilité, seulement un écart temporaire entre ce qu'on montre et
    /// ce qu'on a. Le bandeau, lui, dit que le journal n'est plus écrit.
    private func write(_ event: WatchEvent) {
        guard append(event, from: event.from) else { return }
        today.insert(event, at: 0)
        if event.state == .waiting { waitSecondsToday += event.d }
    }

    private func write(_ event: PresenceEvent) {
        guard append(event, from: event.from) else { return }
        presenceToday.insert(event, at: 0)
    }

    /// Écrit une ligne. Le `FileHandle` est ouvert une fois et gardé.
    ///
    /// Générique sur le type d'intervalle : les deux formes partagent le même
    /// fichier, le même roulement à minuit et la même rétention. `start` est
    /// passé à part parce que `Encodable` ne promet aucune date.
    ///
    /// - Returns: `true` si la mémoire a le droit de tenir l'intervalle pour
    ///   acquis — soit qu'il est sur le disque, soit qu'il n'avait pas à y
    ///   aller. Une rétention à zéro jour ne conserve rien **par décision**, et
    ///   ce n'est pas une panne : l'écran doit continuer d'afficher la journée
    ///   même quand rien n'en survivra à minuit.
    private func append(_ event: some Encodable, from start: Date) -> Bool {
        guard retention.keepsNothing == false else { return true }

        // Le fichier est celui du **début** de l'intervalle : un intervalle ne
        // traverse jamais minuit, puisqu'on ferme tout au changement de jour.
        let day = WatchDay.key(for: start)
        do {
            let handle = try self.handle(for: day)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .secondsSince1970

            var data = try encoder.encode(event)
            data.append(0x0A)
            try handle.write(contentsOf: data)
            journalBytes += Int64(data.count)
            writeProblem = nil
            return true
        } catch {
            // Le handle est peut-être en cause — volume démonté sous lui, par
            // exemple. Le lâcher force `handle(for:)` à rouvrir au prochain
            // battement, ce qui est la seule réparation automatique possible.
            closeFile()
            writeProblem = """
                Journal non écrit : \(error.localizedDescription). \
                Les intervalles mesurés depuis ne sont pas conservés.
                """
            return false
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

    /// **Le seul `try?` volontairement muet de ce fichier.** `write(contentsOf:)`
    /// n'est pas tamponné : à ce point, chaque ligne est déjà partie au noyau, et
    /// un `close()` qui échoue ne dit rien de plus que ce que l'écriture aurait
    /// déjà signalé. Le descripteur est lâché dans tous les cas — le garder
    /// parce que sa fermeture a échoué empêcherait la réouverture, donc la
    /// reprise.
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
    /// noms sans toucher au disque. Ici il ne reste que le `removeItem` — et le
    /// devoir de dire quand il n'a pas eu lieu.
    ///
    /// **Le compte rendu est celui des fichiers partis.** Il l'était en
    /// apparence seulement : `try? removeItem` puis `removed += 1` annonçait
    /// quatre journaux effacés avec les quatre toujours sur le disque. Sur un
    /// fichier qui contient des titres de fenêtres — donc des noms de documents,
    /// de clients et des requêtes de recherche — une promesse de suppression non
    /// tenue est pire que pas de promesse : elle rassure. `WatchRetention` le
    /// dit dans ses propres termes : « on peut supprimer un dossier, on ne peut
    /// pas ne pas l'avoir écrit. »
    ///
    /// **Un échec reste affiché jusqu'à ce qu'une purge repasse.** La purge
    /// tourne une fois par jour et au changement de réglage ; effacer
    /// l'avertissement plus tôt reviendrait à cacher une rétention non tenue
    /// pendant vingt-quatre heures. C'est `purgeProblem`, qui survit
    /// délibérément au `reload()` de la ligne suivante.
    @discardableResult
    func purgeExpired(now: Date = .now) async -> Int {
        let manager = FileManager.default

        let files: [URL]
        do {
            files = try manager.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            )
        } catch {
            // Auparavant : `guard let … else { return 0 }`. Zéro supprimé et pas
            // un mot, exactement comme un dossier où il n'y avait rien à
            // supprimer. Les deux situations sont opposées.
            purgeProblem = WatchPurgeReport.blocked(by: error.localizedDescription).problem
            return 0
        }

        let names = files.map(\.lastPathComponent)
        let doomed = Set(retention.filesToPurge(from: names, today: WatchDay.key(for: now)))
        guard doomed.isEmpty == false else {
            purgeProblem = nil
            return 0
        }

        var report = WatchPurgeReport()
        for url in files where doomed.contains(url.lastPathComponent) {
            do {
                try manager.removeItem(at: url)
                report.succeeded(url.lastPathComponent)
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                // Parti entre l'énumération et ici. La rétention voulait son
                // absence, elle l'a : ce n'est pas un échec.
                report.succeeded(url.lastPathComponent)
            } catch {
                report.failed(url.lastPathComponent, reason: error.localizedDescription)
            }
        }

        purgeProblem = report.problem
        if report.removed > 0 { await reload() }
        return report.removed
    }
}
