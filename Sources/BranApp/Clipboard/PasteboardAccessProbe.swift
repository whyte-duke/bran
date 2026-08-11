import AppKit
import Foundation

/// La mesure qui décide si l'historique du presse-papiers peut exister.
///
/// **Pourquoi elle est dans l'application et pas dans `BranSpike`.** macOS 15.4
/// a introduit `NSPasteboardAccessBehavior` : une lecture *programmatique* du
/// presse-papiers général — c'est-à-dire toute lecture qui ne suit pas un ⌘V
/// fait dans bran — peut lever une alerte, et un refus pose `alwaysDeny
/// définitivement`. Le verdict est attaché à **l'identité de l'application** :
/// son identifiant de bundle et sa signature. Un exécutable en ligne de commande
/// hérite de l'identité du Terminal et ne prédit donc rien du tout du sort de
/// `bran.app` — c'est écrit noir sur blanc dans les notes de conception, et
/// c'est pour ça que cette sonde-ci vit dans la cible de l'application.
///
/// ## Deux temps, et l'ordre est une précaution
///
/// `--probe-pasteboard-access` seul ne lit **aucun contenu**. Il rapporte
/// `accessBehavior`, le compteur de version et la liste des types — trois choses
/// mesurées comme ne déclenchant rien du tout. Si le verdict est déjà tranché
/// dans un sens ou dans l'autre, on l'apprend sans avoir rien risqué.
///
/// `--probe-pasteboard-read` ajoute **une** lecture de contenu, la plus banale
/// qui soit, et c'est elle qui peut lever l'alerte. Elle est séparée parce
/// qu'elle est irréversible dans un sens : un clic sur « Refuser » pose
/// `alwaysDeny` pour toujours, et il n'y a pas de moyen programmatique de
/// revenir dessus. On ne la fait donc pas « pour voir ».
///
/// ## Ce que la lecture peut coûter
///
/// `string(forType:.string)` lit le **contenu**, pas la métadonnée. Si la
/// représentation texte est promise — copiée depuis une application occupée, ou
/// en train d'arriver d'un iPhone par le presse-papiers universel — la demander
/// est un XPC synchrone vers l'application source, qui peut durer des secondes.
/// Elle est donc chronométrée, et le résultat le dit.
///
/// Rien n'est jamais écrit sur le presse-papiers, et aucun octet du contenu
/// n'est imprimé : seulement sa longueur.
enum PasteboardAccessProbe {

    static let inspectFlag = "--probe-pasteboard-access"
    static let readFlag = "--probe-pasteboard-read"

    /// Exécute la sonde si l'un des deux drapeaux est présent.
    ///
    /// - Returns: `true` quand la sonde a tourné, auquel cas l'appelant doit
    ///   s'arrêter là plutôt que de démarrer l'interface.
    static func runIfRequested() -> Bool {
        let arguments = Set(CommandLine.arguments)
        let reads = arguments.contains(readFlag)
        guard reads || arguments.contains(inspectFlag) else { return false }

        var report = ""
        func say(_ line: String = "") {
            print(line)
            report += line + "\n"
        }

        say("── presse-papiers : ce que macOS nous laisse faire ──────────────")
        say("bundle           : \(Bundle.main.bundleIdentifier ?? "‹aucun›")")
        say("chemin           : \(Bundle.main.bundlePath)")
        say("signé            : \(signature())")
        say("")

        let pasteboard = NSPasteboard.general
        say("accessBehavior   : \(currentBehaviour())")
        say("changeCount      : \(pasteboard.changeCount)")

        // Mesuré comme ne déclenchant aucune alerte : `changeCount`, `types`,
        // `pasteboardItems`, `item.types`. C'est exactement ce dont le sondage
        // et l'échantillonnage de la machine se contentent.
        let items = pasteboard.pasteboardItems ?? []
        say("éléments         : \(items.count)")
        for (index, item) in items.enumerated() {
            say("  élément \(index + 1) : \(item.types.map(\.rawValue).joined(separator: ", "))")
        }

        if reads {
            say("")
            say("⚠︎  lecture de contenu — c'est CELLE-CI qui peut lever l'alerte.")
            say("   Un clic sur « Refuser » pose alwaysDeny DÉFINITIVEMENT.")
            say("")
            let start = ContinuousClock.now
            let text = pasteboard.string(forType: .string)
            let elapsed = start.duration(to: .now)
            say("→ string(forType:.string) rendu en \(elapsed)")
            switch text {
            case .some(let value):
                say("  résultat       : \(value.count) caractères lus (contenu non imprimé)")
            case .none:
                say("  résultat       : nil — refusé, ou aucune représentation texte")
            }
            say("accessBehavior après : \(currentBehaviour())")
        } else {
            say("")
            say("Aucune lecture de contenu. Pour la faire : \(readFlag)")
        }

        write(report)
        return true
    }

    /// Le verdict, en clair, avec sa valeur brute — un entier nu dans un rapport
    /// de mesure ne se relit pas, et un libellé seul ne se compare pas à ce que
    /// `BranSpike` a imprimé.
    ///
    /// **`default` n'est pas « autorisé ».** Le SDK est explicite : tant qu'une
    /// application n'a jamais déclenché l'alerte, son presse-papiers général
    /// rapporte `default`, et elle n'apparaît pas dans les Réglages Système. La
    /// première lecture programmatique lève l'alerte et fait passer l'état à
    /// `ask`. Lire `default` ne dit donc rien du verdict à venir : ça dit que
    /// l'alerte est **devant** nous.
    ///
    /// Le tout derrière une garde de disponibilité : le plancher du paquet est
    /// macOS 15.0, et `accessBehavior` n'existe qu'à partir de 15.4.
    private static func currentBehaviour() -> String {
        guard #available(macOS 15.4, *) else {
            return "‹API absente avant macOS 15.4 — aucune restriction de ce type›"
        }
        let value = NSPasteboard.general.accessBehavior
        let label = switch value {
        case .default: "default — on n'a jamais encore demandé ; l'alerte est DEVANT"
        case .ask: "ask — le système demandera, sauf collage déclenché par l'utilisateur"
        case .alwaysAllow: "alwaysAllow — accès accordé sans notification"
        case .alwaysDeny: "alwaysDeny — accès refusé sans notification, DÉFINITIF"
        @unknown default: "valeur inconnue de ce binaire"
        }
        return "\(value.rawValue) · \(label)"
    }

    /// L'identité de signature du processus, parce que c'est elle et non le
    /// chemin qui décide de tout ici.
    private static func signature() -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        task.arguments = ["-dv", Bundle.main.bundlePath]
        let pipe = Pipe()
        task.standardError = pipe
        task.standardOutput = Pipe()
        guard (try? task.run()) != nil else { return "‹codesign indisponible›" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        let fields = text.split(separator: "\n").map(String.init)

        // **Pas seulement `Authority=`, et c'est une correction.** La première
        // version ne cherchait que cette ligne-là et concluait « non signé » en
        // son absence — ce qui était faux, et faux dans un rapport de mesure.
        // Le certificat de développement de bran est généré localement par
        // `Scripts/make-signing-identity.sh` : il n'a aucune chaîne de
        // confiance, donc `codesign -dv` n'imprime pas d'autorité, alors que le
        // bundle est bel et bien scellé — ce que la présence de `Signature` et
        // de l'identifiant démontre.
        let wanted = ["Identifier=", "TeamIdentifier=", "Authority=", "Signature"]
        let kept = fields.filter { field in wanted.contains { field.hasPrefix($0) } }
        return kept.isEmpty ? "‹aucune signature›" : kept.joined(separator: " · ")
    }

    /// Écrit le rapport à côté du bundle, **parce que lancer par `open` perd la
    /// sortie standard**. Et il faut pouvoir lancer par `open` : c'est le seul
    /// démarrage où launchd fait de bran son propre processus responsable, donc
    /// le seul qui mesure vraiment l'identité de bran plutôt que celle du
    /// terminal qui l'a exécuté.
    private static func write(_ report: String) {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "bran-pasteboard-access.txt")
        try? Data(report.utf8).write(to: url, options: .atomic)
        print("rapport écrit dans \(url.path(percentEncoded: false))")
    }
}
