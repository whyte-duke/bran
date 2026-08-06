import Darwin
import Foundation

/// Quels agents tournent réellement, et dans quel dossier.
///
/// C'est la moitié système de la porte de vivacité : `TranscriptVerdict.gated`
/// porte la règle, ce fichier fournit les faits. Sans elle, une session terminée
/// il y a trois semaines a la même signature qu'une session qui attend depuis
/// quatre minutes — mesuré, et pris en défaut au premier essai.
///
/// On lit le dossier de travail des processus via `libproc`, pas en appelant
/// `lsof` : lancer un sous-processus toutes les deux secondes pour poser une
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

    /// Les dossiers de travail des agents vivants.
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
        return URL(fileURLWithPath: String(cString: path)).lastPathComponent
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
