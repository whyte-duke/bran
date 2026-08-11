import BranWatch
import Darwin
import Foundation
import Synchronization

/// **Le capteur certain**, côté disque et côté noyau.
///
/// Volontairement mince : toute la logique — l'ordre des enregistrements, la
/// ligne tronquée, l'extraction sans contenu, la porte de vivacité — vit dans
/// `BranWatch`, où elle est testée sans disque ni écran. Ici il ne reste que le
/// `FileHandle` et `libproc`.
///
/// **Ce capteur ne demande aucune autorisation.** Ni écran, ni Accessibilité :
/// des fichiers dans le dossier personnel et la liste des processus de
/// l'utilisateur. C'est ce qui permet au veilleur de servir à quelque chose
/// avant même que l'observation des pixels soit activée — et c'est la raison
/// pour laquelle `WatchSettings.watchesWindows` peut être faux par défaut.
///
/// Le code est proche de `BranSpike/WatchProbe.swift`, et c'est assumé : le
/// spike est un exécutable de dérisquage qui doit rester lançable seul, sans
/// dépendre de l'application. L'application, elle, ne peut pas dépendre du
/// spike — il a vocation à disparaître.
enum AgentTranscripts {

    /// Les 256 derniers Ko suffisent largement à contenir le dernier tour, et
    /// bornent le coût quel que soit le poids du fichier : le plus gros du
    /// dossier mesuré pèse 20 Mo.
    static let tailBytes = 256 * 1024

    /// Au-delà, la session est morte, pas en attente. Mesuré : 37 des 51
    /// fichiers du dossier ont plus de sept jours. Sans ce plafond, le veilleur
    /// ressusciterait trente-sept voies fantômes au premier lancement.
    static let liveness: TimeInterval = 6 * 3600

    /// Ce que le contrôleur consomme : une observation par session lisible.
    ///
    /// `nonisolated` et sans état : appelée depuis une tâche de fond, jamais
    /// depuis le `MainActor`. Ouvrir cinquante fichiers et en lire la queue,
    /// c'est quelques millisecondes, mais quelques millisecondes de disque n'ont
    /// rien à faire dans la boucle d'affichage.
    static func observations(now: Date = .now) -> [LaneObservation] {
        // **La vivacité n'est levée que si quelque chose l'attend.**
        // `TranscriptVerdict.gated` rend sa lecture inchangée pour tout ce qui
        // n'est pas `.waiting` : une session qui travaille n'a pas besoin qu'on
        // vérifie que son processus est vivant, elle vient de l'écrire. Or
        // l'énumérer coûte un `proc_pidpath` par processus de la machine —
        // plusieurs centaines — et la plupart des tics n'ont aucune session en
        // attente à départager. La liste est donc calculée à la première
        // question posée, et pas avant.
        var live: Set<String>?
        let root = URL.homeDirectory.appending(path: ".claude/projects")
        let manager = FileManager.default
        guard let projects = try? manager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ) else { return [] }

        let cutoff = now.addingTimeInterval(-liveness)
        var byLane: [String: LaneObservation] = [:]
        var visited: Set<String> = []

        for project in projects {
            guard let files = try? manager.contentsOfDirectory(
                at: project, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
            ) else { continue }

            for file in files where file.pathExtension == "jsonl" {
                // Les deux champs sont demandés d'un coup : ils viennent du même
                // `stat`, et la taille sert à dater le mémo aussi finement que
                // la date de modification — voir `Version`.
                let values = try? file.resourceValues(forKeys: [
                    .contentModificationDateKey, .fileSizeKey,
                ])
                let modified = values?.contentModificationDate ?? .distantPast
                guard modified > cutoff else { continue }

                // Pas de taille, pas de mémo : la date seule ne suffit pas à
                // dater une transcription écrite en rafale, et une lecture de
                // trop vaut mieux qu'un verdict figé sur un fichier qui a
                // changé.
                let version = values?.fileSize.map { Version(modified: modified, size: $0) }
                visited.insert(file.path)
                guard let reading = read(file, version: version) else { continue }

                let gated: TranscriptVerdict.Reading
                if reading.state == .waiting {
                    let running = live ?? RunningAgents.workingDirectories()
                    live = running
                    gated = TranscriptVerdict.gated(reading, liveWorkingDirectories: running)
                } else {
                    gated = reading
                }
                guard let directory = gated.workingDirectory else { continue }

                let identity = LaneIdentity.claudeCode(
                    sessionID: gated.sessionID ?? "",
                    workingDirectory: directory,
                    branch: gated.branch ?? ""
                )

                // Plusieurs transcriptions par dossier, c'est la norme : chaque
                // `--resume` en ouvre une, et deux fenêtres peuvent travailler
                // sur le même dépôt. La clé de voie étant le dossier, il faut
                // en élire une.
                //
                // **Ce n'était pas une élection, c'était un écrasement.** Le
                // commentaire d'origine affirmait garder « la plus avancée »
                // parce que les fichiers sont parcourus « dans l'ordre du
                // système de fichiers » — mais `contentsOfDirectory` ne promet
                // aucun ordre, et surtout pas celui des dates de modification.
                // La gagnante était donc tirée au sort à chaque tic : une
                // session qui travaille et une session qui attend dans le même
                // dossier faisaient basculer l'état de la voie d'un tic à
                // l'autre, avec l'alerte et le panneau qui vont avec.
                //
                // La règle est maintenant écrite, et elle répond à la question
                // que l'utilisateur se pose vraiment — « ce dossier a-t-il
                // besoin de moi » : si **quelque chose y tourne**, la voie
                // travaille ; sinon c'est l'attente la plus récente qui parle.
                let candidate = observation(for: gated, identity: identity, now: now)
                byLane[identity.key] = elect(candidate, over: byLane[identity.key])
            }
        }

        // Le mémo ne garde que les fichiers encore vivants. Ceux qui sont
        // tombés sous le seuil de vivacité n'ont pas été visités : les laisser
        // ferait grandir la table à chaque session ouverte depuis le lancement,
        // sans que rien ne la vide jamais.
        memos.withLock { table in
            table = table.filter { visited.contains($0.key) }
        }

        return Array(byLane.values)
    }

    /// Départage deux transcriptions du même dossier. **Déterministe**, et
    /// c'est tout ce qu'on lui demande.
    ///
    /// L'ordre de préférence : ce qui travaille l'emporte sur ce qui attend, ce
    /// qui attend l'emporte sur ce qui ne dit rien, et à égalité c'est
    /// l'horodatage le plus récent qui tranche. Aucun de ces trois critères ne
    /// dépend de l'ordre dans lequel le disque a rendu ses fichiers.
    private static func elect(
        _ candidate: LaneObservation,
        over incumbent: LaneObservation?
    ) -> LaneObservation {
        guard let incumbent else { return candidate }

        let rank: (LaneObservation) -> Int = { observation in
            switch observation.certain {
            case .working: 2
            case .waiting: 1
            case nil: 0
            }
        }

        let (new, old) = (rank(candidate), rank(incumbent))
        if new != old { return new > old ? candidate : incumbent }

        // Même rang : la plus récente. `certainSince` porte l'horodatage écrit
        // par l'outil lui-même, `stillFor` une durée d'immobilité — donc plus
        // elle est **petite**, plus la transcription est fraîche.
        switch (candidate.certainSince, incumbent.certainSince) {
        case let (new?, old?): return new >= old ? candidate : incumbent
        case (_?, nil): return candidate
        case (nil, _?): return incumbent
        case (nil, nil):
            let new = candidate.stillFor ?? .greatestFiniteMagnitude
            let old = incumbent.stillFor ?? .greatestFiniteMagnitude
            return new <= old ? candidate : incumbent
        }
    }

    /// Traduit une lecture en observation.
    ///
    /// **Un capteur certain n'a que deux réponses** — elle attend, elle
    /// travaille. Le troisième cas que rend `gated` — une session dont le
    /// dernier tour est terminé mais dont plus aucun processus ne vit — n'est
    /// pas une certitude : c'est l'absence de nouvelles. On le rapporte donc
    /// comme ce qu'il est, une voie immobile depuis longtemps, et c'est le
    /// résolveur qui en fait un `stale`. Lui mettre `certain: .waiting`
    /// afficherait « le dernier tour est terminé » pour une session morte
    /// depuis trois semaines.
    private static func observation(
        for reading: TranscriptVerdict.Reading,
        identity: LaneIdentity,
        now: Date
    ) -> LaneObservation {
        let endedAt = reading.endedAt.flatMap { ISO8601DateFormatter.watch.date(from: $0) }

        switch reading.state {
        case .waiting:
            return LaneObservation(
                identity: identity,
                certain: .waiting,
                // L'horodatage écrit par l'outil lui-même, et pas une
                // soustraction faite ici : il est juste même si bran vient de
                // démarrer. Une session qui attendait déjà depuis vingt minutes
                // au lancement doit le dire, pas repartir de zéro.
                certainSince: endedAt
            )

        case .working:
            return LaneObservation(identity: identity, certain: .working)

        default:
            return LaneObservation(
                identity: identity,
                motionRatio: 0,
                stillFor: endedAt.map { max(0, now.timeIntervalSince($0)) }
            )
        }
    }

    /// De quelle version d'un fichier un verdict a été tiré.
    ///
    /// La date de modification seule ne suffirait pas : deux écritures dans la
    /// même seconde sont indiscernables sur un système de fichiers à
    /// granularité grossière, et une transcription est écrite en rafale. La
    /// taille les sépare — un enregistrement ajouté allonge toujours le
    /// fichier. Les deux champs viennent du même `stat`, déjà fait pour la
    /// porte de vivacité : le mémo ne coûte aucun accès disque de plus.
    struct Version: Equatable, Sendable {
        let modified: Date
        let size: Int
    }

    private struct Memo: Sendable {
        let version: Version
        /// `nil` compris : un fichier illisible ou sans verdict doit rester
        /// illisible sans être rouvert quinze fois par minute.
        let reading: TranscriptVerdict.Reading?
    }

    /// Ce qui a déjà été lu, et de quelle version.
    ///
    /// **Sans ce mémo, chaque tic relisait cinquante fichiers pour n'en trouver
    /// que deux ou trois de changés.** Le veilleur tourne toutes les quatre
    /// secondes ; une session d'agent qui attend n'écrit rien pendant des
    /// minutes, et une session morte depuis cinq heures reste sous le seuil de
    /// vivacité jusqu'à la sixième. Au profil, relire ces fichiers pour
    /// retrouver exactement le verdict précédent était le premier poste de
    /// dépense de l'application au repos.
    ///
    /// `Mutex` plutôt qu'un acteur : la table est touchée depuis la tâche
    /// détachée du veilleur, une seule à la fois, et deux `withLock` de
    /// quelques microsecondes par tic n'ont pas besoin d'un point de suspension
    /// — qui obligerait en retour `observations` à devenir `async` et à
    /// remonter jusqu'au contrôleur.
    private static let memos = Mutex<[String: Memo]>([:])

    /// - Parameter version: l'état du fichier tel que l'appelant vient de le
    ///   constater. Sans elle, la lecture est refaite systématiquement : c'est
    ///   ce qu'on veut d'un appel isolé, qui n'a aucune raison de faire
    ///   confiance à un mémo qu'il ne peut pas dater.
    static func read(_ file: URL, version: Version? = nil) -> TranscriptVerdict.Reading? {
        if let version, let memo = memos.withLock({ $0[file.path] }), memo.version == version {
            return memo.reading
        }

        let reading = readFromDisk(file)
        if let version {
            memos.withLock { $0[file.path] = Memo(version: version, reading: reading) }
        }
        return reading
    }

    private static func readFromDisk(_ file: URL) -> TranscriptVerdict.Reading? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: start)

        guard let data = try? handle.readToEnd() else { return nil }

        // Le découpage en lignes vit dans `BranWatch`, avec ses tests : il porte
        // la règle du fragment initial, et il a une correction à défendre — voir
        // `TranscriptVerdict.read(utf8Tail:tailIsTruncated:)`.
        let reading = TranscriptVerdict.read(utf8Tail: data, tailIsTruncated: start > 0)
        return reading.state == .unknown ? nil : reading
    }
}

extension ISO8601DateFormatter {
    /// Les horodatages des transcriptions portent des millisecondes.
    ///
    /// `nonisolated(unsafe)` : `ISO8601DateFormatter` n'est pas `Sendable`, mais
    /// Apple documente ses formateurs comme sûrs en lecture depuis plusieurs
    /// fils une fois configurés. On n'écrit jamais dedans après cette closure.
    /// L'alternative — en construire un par fichier de transcription, cinquante
    /// fois par tic — coûterait plus cher que ce qu'elle protège.
    nonisolated(unsafe) static let watch: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

/// Quels agents tournent réellement, et dans quel dossier.
///
/// C'est la moitié système de la porte de vivacité : `TranscriptVerdict.gated`
/// porte la règle, ceci fournit les faits. Sans elle, une session terminée il y
/// a trois semaines a la même signature qu'une session qui attend depuis quatre
/// minutes — mesuré, et pris en défaut au premier essai.
///
/// On lit le dossier de travail des processus via `libproc`, pas en appelant
/// `lsof` : lancer un sous-processus toutes les quatre secondes pour poser une
/// question que le noyau répond directement serait absurde sur batterie.
enum RunningAgents {

    /// Les exécutables considérés comme des agents. Le nom du binaire suffit :
    /// on ne cherche pas à savoir *ce que* fait le processus, seulement s'il est
    /// là et où il travaille.
    static let names: Set<String> = ["claude", "codex", "cursor-agent"]

    /// `PROC_PIDPATHINFO_MAXSIZE` de `<sys/proc_info.h>` n'est pas exposé à
    /// Swift : c'est une macro, `4 * MAXPATHLEN`. Écrite en clair plutôt que
    /// devinée au hasard.
    private static let pathMax = 4 * 1024

    /// Les noms d'agents en octets, pour les comparer sans construire de
    /// `String`.
    ///
    /// La question « ce processus est-il un agent » se pose une fois par
    /// processus de la machine — plusieurs centaines par tic — et la réponse est
    /// non dans la quasi-totalité des cas. Fabriquer une `String` pour chacun,
    /// juste pour la jeter à la ligne suivante, était au profil le poste
    /// dominant de cette énumération, devant l'appel système qui la justifie.
    private static let nameBytes: [[UInt8]] = names.map { Array($0.utf8) }

    static func workingDirectories() -> Set<String> {
        var directories: Set<String> = []

        let capacity = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard capacity > 0 else { return [] }

        var pids = [pid_t](repeating: 0, count: Int(capacity) / MemoryLayout<pid_t>.size)
        let written = pids.withUnsafeMutableBufferPointer { buffer in
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, buffer.baseAddress, capacity)
        }
        guard written > 0 else { return [] }

        // Le tampon de chemin est alloué **une fois** pour toute l'énumération.
        // Un tampon de 4 Ko par processus, mis à zéro à chaque fois, coûtait
        // plus que le `proc_pidpath` qu'il sert à recevoir.
        var path = [CChar](repeating: 0, count: pathMax)

        for pid in pids where pid > 0 {
            guard isAgent(pid, path: &path) else { continue }
            if let directory = workingDirectory(of: pid) { directories.insert(directory) }
        }
        return directories
    }

    /// Le dernier composant du chemin de l'exécutable est-il un nom d'agent ?
    ///
    /// **Le dernier composant est cherché dans les octets, pas par `URL`.**
    /// `URL(fileURLWithPath:)` fait un `lstat` sur le chemin pour décider s'il
    /// désigne un dossier — un appel système par processus de la machine, et
    /// c'était au profil le second poste de dépense du veilleur. Chercher le
    /// dernier `/` répond à la même question sans toucher au disque, et sans
    /// dépendre de l'existence du fichier : un binaire supprimé pendant que son
    /// processus tourne est un cas réel, et son nom compte toujours.
    private static func isAgent(_ pid: pid_t, path: inout [CChar]) -> Bool {
        // `proc_pidpath` rend la longueur utile, sans le zéro terminal : on lit
        // exactement ces octets plutôt que de chercher un `\0` dans 4 Ko.
        let length = proc_pidpath(pid, &path, UInt32(pathMax))
        guard length > 0 else { return false }

        return path.withUnsafeBytes { raw in
            let full = UnsafeRawBufferPointer(rebasing: raw[..<Int(length)])
            let start = full.lastIndex(of: UInt8(ascii: "/")).map { $0 + 1 } ?? 0
            let name = UnsafeRawBufferPointer(rebasing: full[start...])
            return nameBytes.contains { $0.elementsEqual(name) }
        }
    }


    /// `PROC_PIDVNODEPATHINFO` rend le vnode du répertoire courant. Réservé aux
    /// processus du même utilisateur — ce qui est exactement le périmètre voulu :
    /// bran n'a aucune raison de regarder les processus de quelqu'un d'autre.
    private static func workingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let read = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, pointer, size)
        }
        guard read == size else { return nil }

        return withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw in
            guard let base = raw.baseAddress else { return nil }
            let path = String(cString: base.assumingMemoryBound(to: CChar.self))
            return path.isEmpty ? nil : path
        }
    }
}
