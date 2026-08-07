import BranWatch
import Darwin
import Foundation

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
        let live = RunningAgents.workingDirectories()
        let root = URL.homeDirectory.appending(path: ".claude/projects")
        let manager = FileManager.default
        guard let projects = try? manager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ) else { return [] }

        let cutoff = now.addingTimeInterval(-liveness)
        var byLane: [String: LaneObservation] = [:]

        for project in projects {
            guard let files = try? manager.contentsOfDirectory(
                at: project, includingPropertiesForKeys: [.contentModificationDateKey]
            ) else { continue }

            for file in files where file.pathExtension == "jsonl" {
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                guard modified > cutoff else { continue }
                guard let reading = read(file) else { continue }

                let gated = TranscriptVerdict.gated(reading, liveWorkingDirectories: live)
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

    static func read(_ file: URL) -> TranscriptVerdict.Reading? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: start)

        guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) else {
            return nil
        }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let reading = TranscriptVerdict.read(lines: lines, tailIsTruncated: start > 0)
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

    static func workingDirectories() -> Set<String> {
        var directories: Set<String> = []

        let capacity = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard capacity > 0 else { return [] }

        var pids = [pid_t](repeating: 0, count: Int(capacity) / MemoryLayout<pid_t>.size)
        let written = pids.withUnsafeMutableBufferPointer { buffer in
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, buffer.baseAddress, capacity)
        }
        guard written > 0 else { return [] }

        for pid in pids where pid > 0 {
            guard let name = executableName(of: pid), names.contains(name) else { continue }
            if let directory = workingDirectory(of: pid) { directories.insert(directory) }
        }
        return directories
    }

    private static func executableName(of pid: pid_t) -> String? {
        var path = [CChar](repeating: 0, count: pathMax)
        let length = proc_pidpath(pid, &path, UInt32(pathMax))
        guard length > 0 else { return nil }

        // `proc_pidpath` rend la longueur utile, sans le zéro terminal : on
        // décode exactement ces octets plutôt que de chercher un `\0` dans un
        // tampon de 4 Ko.
        let bytes = path.prefix(Int(length)).map { UInt8(bitPattern: $0) }
        return URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self)).lastPathComponent
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
