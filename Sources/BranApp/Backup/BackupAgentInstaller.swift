import Darwin
import Foundation
import os

/// Installe, met à jour et retire le `LaunchAgent` qui déclenche
/// `BackupHeadlessRun` — la seule façon pour la sauvegarde de tourner
/// pendant que l'interface ne tourne pas.
///
/// ## Pourquoi ça ne peut pas être un minuteur dans l'application
///
/// Un minuteur ne s'exécute que si bran tourne. « Toutes les deux jours » ne
/// veut rien dire sur une machine qu'on éteint le soir — le cas normal de ce
/// Mac, pas un cas limite. Il faut donc `launchd`, et le job doit lancer
/// **le même binaire** que l'interface, avec une sous-commande : deux copies
/// du code de sauvegarde — une pour l'écran, une pour le job — finiraient
/// par diverger, et le job daterait toujours d'une version qu'on a oublié de
/// mettre à jour.
///
/// **Le chiffre à garder en tête.** Au débit mesuré vers ce MinIO
/// (~5,5 Mo/s), la première sauvegarde d'environ 600 Go dure de l'ordre de
/// 30 heures. Ce fichier ne peut donc pas être conçu comme « une tâche
/// courte qui tourne toutes les 48 h » : voir ``pollIntervalSeconds`` et le
/// choix `ProcessType` plus bas, les deux endroits où ce chiffre pèse
/// vraiment sur la conception.
enum BackupAgentInstaller {

    private static let log = Logger(subsystem: "com.opahventures.bran", category: "backup-agent")

    // MARK: - Identité

    /// **Dérivé du `bundleIdentifier` réel, jamais écrit en dur.**
    /// `com.opahventures.bran` apparaît en toutes lettres ailleurs dans ce
    /// dépôt (journalisation, Trousseau), mais le `LaunchAgent` est
    /// justement l'endroit où deux copies désynchronisées se voient : un
    /// bundle signé sous une autre identité (`BRAN_BUNDLE_ID` personnalisé
    /// côté `Scripts/build-app.sh`, ou un fork) installerait sinon un job
    /// que cette identité-là ne retrouve jamais, ou pire, écraserait le job
    /// d'une autre identité de bran déjà installée sur la même machine.
    static var label: String {
        (Bundle.main.bundleIdentifier ?? "com.opahventures.bran") + ".backup"
    }

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library", directoryHint: .isDirectory)
            .appending(path: "LaunchAgents", directoryHint: .isDirectory)
            .appending(path: "\(label).plist", directoryHint: .notDirectory)
    }

    // MARK: - Les échecs

    enum Failure: Error, CustomStringConvertible {
        case noExecutableURL
        case cannotCreateDirectory(String)
        case cannotSerialize(String)
        case cannotWrite(String)
        case launchctlLaunchFailed(arguments: [String], underlying: String)
        case launchctlFailed(arguments: [String], status: Int32, output: String)

        var description: String {
            switch self {
            case .noExecutableURL:
                "Bundle.main.executableURL est vide ; impossible de savoir quel binaire le job doit lancer."
            case let .cannotCreateDirectory(reason):
                "~/Library/LaunchAgents est inaccessible : \(reason)"
            case let .cannotSerialize(reason):
                "le plist du job n'est pas sérialisable : \(reason)"
            case let .cannotWrite(reason):
                "écriture du plist impossible : \(reason)"
            case let .launchctlLaunchFailed(arguments, underlying):
                "impossible de lancer « launchctl \(arguments.joined(separator: " ")) » : \(underlying)"
            case let .launchctlFailed(arguments, status, output):
                "« launchctl \(arguments.joined(separator: " ")) » a rendu \(status) : \(output)"
            }
        }
    }

    // MARK: - Installer / mettre à jour

    /// **Le rythme d'interrogation est volontairement découplé de la
    /// cadence de sauvegarde choisie par l'utilisateur.**
    ///
    /// `configuration.intervalHours` peut valoir n'importe quoi — deux
    /// jours, une semaine — et le recopier tel quel dans `StartInterval`
    /// serait la même erreur que le minuteur qu'on remplace : si le Mac
    /// s'allume juste après une échéance manquée, le prochain réveil de
    /// `launchd` n'arriverait qu'un intervalle entier plus tard, alors que
    /// `SchedulePolicy` aurait dit « rattrape tout de suite » depuis la
    /// première seconde. Le recul exponentiel d'un échec réseau (voir
    /// `SchedulePolicy.retryDelay`, plafonné à 6 h) a lui aussi besoin
    /// d'être revérifié bien plus souvent qu'une fois par cycle de
    /// sauvegarde, sans quoi une ligne revenue en une heure attendrait des
    /// jours qu'on s'en aperçoive.
    ///
    /// Un poll fixe, court, indépendant de la cadence choisie, donne au
    /// contraire à `SchedulePolicy` une chance par heure de comparer
    /// l'horloge réelle à `lastSuccess` et de décider. C'est cette décision,
    /// pas la fidélité de `launchd`, qui gouverne réellement le rythme —
    /// voir `SchedulePolicy` pour le pourquoi de ce report de confiance.
    private static let pollIntervalSeconds = 3600

    static func install() throws {
        guard let executable = Bundle.main.executableURL else {
            throw Failure.noExecutableURL
        }

        // Le journal des tentatives vit dans `BackupJournal` et suffit à
        // répondre « est-ce que ça a marché ». Il ne répond pas à « pourquoi le
        // job ne démarre même pas » — un binaire absent, un droit manquant, un
        // plantage avant la première ligne écrite. Dans ces cas-là, `launchd`
        // est le seul témoin, et sans ces deux clés il parle dans le vide.
        //
        // C'est la panne la plus coûteuse à diagnostiquer sur un agent : elle
        // est silencieuse par construction, personne n'est devant l'écran, et
        // le seul symptôme est une sauvegarde qui n'arrive pas. Deux chemins
        // de fichier valent mieux qu'une soirée à deviner.
        // Le même dossier que le journal des tentatives : tout ce qui
        // documente une sauvegarde se lit au même endroit, et `launchd` refuse
        // de démarrer un job dont le dossier de sortie n'existe pas.
        let logDirectory = BackupJournal.directory
        try FileManager.default.createDirectory(
            at: logDirectory, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "Label": label,
            // Le binaire réel de **cette** installation — jamais un chemin
            // littéral : bran s'installe aussi bien dans `/Applications`
            // que dans `~/Applications`, et le job doit suivre celui qui
            // tourne, pas une hypothèse sur l'un ou l'autre.
            "ProgramArguments": [executable.path(percentEncoded: false), BackupHeadlessRun.flag],
            "StartInterval": pollIntervalSeconds,
            // Rattrape dès l'ouverture de session — le moment où un Mac
            // éteint la veille redevient capable de sauvegarder, souvent
            // bien avant le premier `StartInterval`.
            "RunAtLoad": true,
            // **`Background`, et ce que ça coûte.** macOS étrangle les
            // entrées-sorties (et abaisse la priorité CPU) des jobs marqués
            // ainsi dès qu'il y a contention avec le premier plan. Sur un
            // transfert de 30 heures, ce n'est pas une case qu'on coche sans
            // y penser : les jours où le Mac sert activement à autre chose,
            // ça peut allonger sensiblement la durée du transfert.
            //
            // Le choix reste `Background`, pour la raison inverse : un job
            // sans surveillance, qui peut tourner des heures, ne doit
            // **jamais** ralentir ce que l'utilisateur fait activement —
            // c'est l'inverse, un job « interactif » par défaut, qui
            // apprendrait à désactiver la sauvegarde le jour où elle
            // gênerait un export vidéo ou une visioconférence. Sur un Mac
            // inactif la nuit — le cas le plus fréquent pour un transfert de
            // cette durée — l'étranglement ne coûte rien : il n'existe qu'en
            // cas de contention réelle.
            "ProcessType": "Background",
            "StandardOutPath": logDirectory.appending(path: "launchd.out.log").path(percentEncoded: false),
            "StandardErrorPath": logDirectory.appending(path: "launchd.err.log").path(percentEncoded: false),
        ]

        try write(plist)
        try reload()
    }

    /// Décharge le job et retire son plist. Idempotent : appelable sur un
    /// job jamais installé sans que ce soit une erreur.
    static func uninstall() throws {
        // Avant de retirer le fichier : sans ce déchargement, `launchd`
        // garde le job en mémoire pour le reste de la session, y compris
        // après la suppression du plist qui l'a créé.
        try bootOut()

        let existing = plistURL.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: existing) else { return }
        do {
            try FileManager.default.removeItem(at: plistURL)
        } catch {
            throw Failure.cannotWrite("suppression du plist impossible : \(error)")
        }
    }

    // MARK: - Vérifier

    /// Ce qu'une relecture de l'état réel a appris — jamais une supposition
    /// que l'écriture du plist a suffi. `launchctl bootstrap` peut réussir
    /// tout en laissant un job qui ne se lancera jamais (chemin
    /// d'exécutable invalide, argument malformé) ; seule une relecture par
    /// `launchctl print` le débusque.
    struct VerificationResult: Sendable {
        let isLoaded: Bool
        let rawOutput: String
    }

    static func verifyInstalled() -> VerificationResult {
        let domain = "gui/\(getuid())/\(label)"
        guard let result = try? runLaunchctl(["print", domain]) else {
            return VerificationResult(
                isLoaded: false,
                rawOutput: "launchctl n'a pas pu être lancé pour vérifier l'installation"
            )
        }
        return VerificationResult(isLoaded: result.status == 0, rawOutput: result.output)
    }

    // MARK: - Le plist

    private static func write(_ plist: [String: Any]) throws {
        let directory = plistURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw Failure.cannotCreateDirectory(String(describing: error))
        }

        let data: Data
        do {
            data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        } catch {
            throw Failure.cannotSerialize(String(describing: error))
        }

        do {
            // `.atomic` : `launchd` ou un humain qui lirait le plist au
            // mauvais instant ne doit jamais voir un fichier à moitié écrit.
            try data.write(to: plistURL, options: .atomic)
        } catch {
            throw Failure.cannotWrite(String(describing: error))
        }
    }

    // MARK: - Le rechargement

    private static func reload() throws {
        try bootOut()
        let domain = "gui/\(getuid())"
        let target = plistURL.path(percentEncoded: false)
        let result = try runLaunchctl(["bootstrap", domain, target])
        guard result.status == 0 else {
            throw Failure.launchctlFailed(arguments: ["bootstrap", domain, target], status: result.status, output: result.output)
        }
        log.notice("LaunchAgent de sauvegarde (re)chargé : \(label, privacy: .public)")
    }

    /// Décharge le job s'il est chargé. **Un job non chargé n'est pas un
    /// échec de déchargement.** Sur Darwin, `ESRCH` (« aucun processus »)
    /// vaut 3, et c'est le code que `launchctl bootout` rend quand le
    /// domaine demandé n'a rien à décharger — Darwin ne distingue pas ici
    /// « jamais chargé » de « déjà déchargé ». On le reconnaît explicitement
    /// plutôt que de le traiter comme n'importe quel autre échec : sans ça,
    /// la toute première installation sur un Mac neuf échouerait à l'étape
    /// même qui est censée être un no-op.
    private static func bootOut() throws {
        let domain = "gui/\(getuid())/\(label)"
        let result = try runLaunchctl(["bootout", domain])
        guard result.status == 0 || result.status == 3 else {
            throw Failure.launchctlFailed(arguments: ["bootout", domain], status: result.status, output: result.output)
        }
    }

    private static func runLaunchctl(_ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            throw Failure.launchctlLaunchFailed(arguments: arguments, underlying: String(describing: error))
        }
        // **Lire d'abord, attendre ensuite. L'ordre inverse est un
        // interblocage, et le dépôt le sait déjà.**
        //
        // Un tube a une capacité finie — 64 Kio sur Darwin. Quand un enfant
        // écrit plus que ça et que personne ne lit, son `write` bloque ; il
        // ne se termine donc jamais, et le `waitUntilExit()` qui devait
        // précéder la lecture attend un événement que la lecture seule
        // pourrait provoquer. Le processus appelant est figé pour toujours.
        //
        // Ce n'est pas une hypothèse ici : `launchctl print` est appelé plus
        // haut, et c'est la commande la plus bavarde de la famille — elle
        // déballe le domaine entier. Les deux flux sont en plus dirigés vers
        // le **même** tube, donc vers le même plafond.
        //
        // Le piège a déjà coûté cher sur ce projet : `ChainProbes.runProcess`
        // le documente et l'évite par `readabilityHandler`, parce que les
        // 13 436 octets de `tailscale status --json` arrivaient tronqués. Le
        // même défaut avait survécu ici, dans un chemin synchrone.
        //
        // `readDataToEndOfFile()` rend la main sur la fermeture du côté
        // écriture, c'est-à-dire à la mort de l'enfant : le tube ne peut plus
        // se remplir, et `waitUntilExit()` n'a plus qu'à moissonner.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
