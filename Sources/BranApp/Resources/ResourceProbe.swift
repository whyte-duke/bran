import BranCore
import Darwin
import Foundation

/// **Les deux seuls appels système du moniteur.** Rien à tester ici : tout le
/// résultat vient du noyau. Le calcul, lui, vit dans
/// `Sources/BranCore/ResourceReading.swift`, où il se teste sur des entiers.
///
/// ```
///   task_info(TASK_VM_INFO).phys_footprint ──▶ octets
///   proc_pid_rusage(ri_user_time + ri_system_time) ──▶ nanosecondes cumulées
/// ```
///
/// **Pourquoi `phys_footprint` et pas `resident_size`.** Ce sont deux colonnes
/// différentes du Moniteur d'activité : `phys_footprint` est « Mémoire »,
/// `resident_size` est « Mémoire réelle ». Elles ne donnent pas le même chiffre,
/// et c'est la première que l'utilisateur lit quand il ouvre le vrai Moniteur
/// d'activité pour recouper — c'est-à-dire l'usage exact de ce panneau. Le même
/// appel existait déjà dans `Sources/BranSpike/SpeechSpike.swift` pour mesurer
/// le coût de Parakeet ; il est repris tel quel, pas réinventé.
///
/// **Pourquoi `proc_pid_rusage` et pas `task_info(TASK_BASIC_INFO)`.**
/// `TASK_BASIC_INFO` ne compte pas les fils déjà terminés : une transcription
/// qui a occupé un cœur pendant deux secondes puis a rendu son fil disparaîtrait
/// du compte. `ri_user_time + ri_system_time` sont cumulés sur tout le
/// processus, fils morts compris. `libproc` est déjà utilisé dans
/// `Sources/BranSpike/RunningAgents.swift` — même en-tête, même import `Darwin`.
///
/// **Et rien ne quitte le Mac** : ces deux appels interrogent le processus
/// courant, pas les autres, et n'ouvrent aucune socket (contrainte C2).
enum ResourceProbe {

    /// Un relevé brut. Des nombres, pas des pourcentages : la dérivée est faite
    /// ailleurs, par `ResourceTracker`.
    struct Sample: Sendable {
        /// `ri_user_time + ri_system_time`, cumulés depuis le lancement.
        var cpuNanoseconds: UInt64
        /// `phys_footprint`, instantané.
        var footprintBytes: UInt64
    }

    /// Le relevé complet. `nil` si l'un des deux appels échoue : une moitié de
    /// mesure afficherait un « — » d'un côté et un chiffre de l'autre, ce qui
    /// ressemble à une panne de bran plutôt qu'à une panne du relevé.
    ///
    /// **Appelé hors du `MainActor`.** Les deux appels sont des micro-secondes,
    /// mais ils sont faits toutes les deux secondes pour toute la vie du
    /// processus : les tenir hors de la boucle d'interface est gratuit et
    /// définitif.
    static func sample() -> Sample? {
        guard let cpu = cpuNanoseconds(), let footprint = footprintBytes() else { return nil }
        return Sample(cpuNanoseconds: cpu, footprintBytes: footprint)
    }

    /// Le temps processeur cumulé du processus courant, en nanosecondes.
    ///
    /// `rusage_info_current` est l'alias que le SDK fait pointer vers la
    /// dernière version de la structure ; l'utiliser avec `RUSAGE_INFO_CURRENT`
    /// évite de figer un `rusage_info_v4` qui deviendrait faux au prochain SDK.
    /// Le double `withMemoryRebound` est la seule façon d'atteindre la signature
    /// C, qui attend un `rusage_info_t` — un pointeur opaque.
    private static func cpuNanoseconds() -> UInt64? {
        var info = rusage_info_current()
        let result = withUnsafeMutablePointer(to: &info) { pointer -> Int32 in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(getpid(), RUSAGE_INFO_CURRENT, rebound)
            }
        }
        guard result == 0 else { return nil }
        // `&+` : deux compteurs monotones qui ne déborderont pas avant six cents
        // ans de temps processeur, mais un `+` qui déborde fait tomber le
        // processus, et un moniteur n'a pas le droit de tuer ce qu'il observe.
        let ticks = info.ri_user_time &+ info.ri_system_time

        // **Ces champs ne sont pas des nanosecondes, malgré leur nom.** Ils
        // comptent des unités de `mach_absolute_time`, qui valent 41,67 ns sur
        // Apple Silicon. Voir `ResourceMath.nanoseconds(machTicks:numer:denom:)`
        // pour la mesure qui l'établit et pour ce que le défaut coûtait.
        return ResourceMath.nanoseconds(
            machTicks: ticks,
            numer: timebase.numer,
            denom: timebase.denom
        )
    }

    /// La base de temps du noyau, lue **une seule fois**. Elle ne change pas
    /// pendant la vie du processus, et `mach_timebase_info` est un appel système.
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        guard mach_timebase_info(&info) == KERN_SUCCESS, info.denom > 0 else {
            // Le repli est l'identité, c'est-à-dire le comportement d'Intel.
            // Faux sur Apple Silicon, mais moins faux que zéro.
            return mach_timebase_info_data_t(numer: 1, denom: 1)
        }
        return info
    }()

    /// L'empreinte mémoire, en octets. Copié de `SpeechSpike.residentBytes()`,
    /// dont le nom mentait déjà : il rendait bien `phys_footprint`.
    private static func footprintBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : nil
    }

    // MARK: - Les dénominateurs

    /// Le nombre de cœurs **actifs**, et non le nombre de cœurs installés :
    /// c'est celui-là que le Moniteur d'activité utilise pour son échelle.
    static var cores: Int { ProcessInfo.processInfo.activeProcessorCount }

    static var physicalMemory: UInt64 { ProcessInfo.processInfo.physicalMemory }
}
