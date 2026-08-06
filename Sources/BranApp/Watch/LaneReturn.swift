import AppKit
import ApplicationServices
import BranWatch
import BranWindows
import Foundation

/// **Le geste de retour** — la moitié du produit qui n'existait pas.
///
/// bran savait dire qu'une machine attend. Il ne savait pas y ramener : le
/// panneau d'attention posait `ignoresMouseEvents = true`, et il n'y avait
/// aucune occurrence de `NSRunningApplication` dans toute l'application. Le
/// critère de succès écrit du produit — « revenir sur une voie qui attend coûte
/// une seule action » — n'avait aucune implémentation.
///
/// **Aucune autorisation nouvelle.** bran possède déjà l'Accessibilité : la
/// dictée ne fonctionne pas sans, `HotkeyMonitor.isTrusted` la lit,
/// `SystemSettings.reRequestAccessibility()` sait la redemander et les Réglages
/// l'affichent. Remonter une fenêtre précise par `AXUIElement` ne coûte donc
/// rien de plus en TCC, et ce fichier ne crée surtout **pas** un second chemin
/// de demande : il lit l'état existant et se contente de dire ce qu'il manque.
///
/// **Deux natures de voie, deux stratégies.** Une voie de fenêtre connaît son
/// application et son titre : il n'y a qu'à retrouver la fenêtre. Une voie
/// Claude Code vient d'une transcription — elle n'a jamais eu de fenêtre du
/// point de vue de bran — et il faut la *chercher* par le nom de son dossier de
/// travail. Le choix parmi les candidates est de la logique pure, il vit dans
/// `WindowChoice` et il se teste ; ce fichier-ci n'est que la plomberie.
///
/// **Il ne fait jamais rien en silence.** Chaque sortie est un `Outcome` qui
/// porte sa raison, parce qu'un geste de retour qui échoue sans le dire est
/// exactement ce qui apprend à ne plus cliquer.
@MainActor
enum LaneReturn {

    /// Ce qui s'est réellement passé. Le point d'appel doit pouvoir le dire à
    /// l'utilisateur, mot pour mot.
    enum Outcome: Equatable {
        /// La fenêtre exacte est devant.
        case raised(window: String)
        /// L'application est devant, mais pas forcément la bonne fenêtre.
        case appOnly(reason: String)
        /// Rien n'a bougé, et voici pourquoi.
        case notFound(reason: String)
    }

    @discardableResult
    static func go(to identity: LaneIdentity) -> Outcome {
        guard let target = LaneTarget(key: identity.key) else {
            return .notFound(reason: "La clé de cette voie n'est pas lisible : bran ne sait pas à quoi elle correspond.")
        }

        let apps = searchSpace(for: target)
        guard apps.isEmpty == false else {
            return .notFound(reason: missingApplication(for: target, name: identity.displayName))
        }

        guard HotkeyMonitor.isTrusted else {
            return withoutAccessibility(apps: apps, identity: identity)
        }

        // Une seule énumération sert aux deux besoins : lire les titres pour
        // choisir, et garder l'élément qu'il faudra remonter. Passer par les
        // fenêtres du serveur graphique donnerait les mêmes titres, mais au prix
        // de l'autorisation Enregistrement de l'écran — et sans l'élément.
        var candidates: [(candidate: WindowCandidate, app: NSRunningApplication, window: AXUIElement)] = []
        for app in apps {
            let owner = app.bundleIdentifier ?? app.localizedName ?? ""
            for window in accessibleWindows(of: app) {
                candidates.append((WindowCandidate(owner: owner, title: window.title), app, window.element))
            }
        }

        guard let winner = WindowChoice.best(among: candidates.map(\.candidate), for: identity),
              let match = candidates.first(where: { $0.candidate == winner })
        else {
            return giveUp(target: target, apps: apps, identity: identity)
        }

        match.app.activate()
        raise(match.window, in: match.app)
        return .raised(window: winner.title)
    }

    // MARK: - Où chercher

    /// Les applications qui peuvent porter cette voie.
    ///
    /// **Le processus courant est toujours exclu.** La section « Veille »
    /// affiche le nom de chaque voie ; la fenêtre de bran contient donc
    /// littéralement « crm · feat/ocr » pendant qu'on cherche « crm ». Sans
    /// cette exclusion, le geste de retour ramènerait bran sur bran — le seul
    /// endroit d'où l'on vient de partir.
    private static func searchSpace(for target: LaneTarget) -> [NSRunningApplication] {
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.processIdentifier != NSRunningApplication.current.processIdentifier }

        switch target {
        case .window(let owner, _):
            let byBundle = running.filter { $0.bundleIdentifier == owner }
            guard byBundle.isEmpty else { return byBundle }
            // La clé retient le nom quand le système n'a pas donné
            // d'identifiant de paquet : on doit savoir relire les deux.
            return running.filter {
                $0.localizedName?.compare(owner, options: .caseInsensitive) == .orderedSame
            }

        case .workspace:
            // Une session d'agent peut tourner dans n'importe quel terminal, et
            // sa fenêtre peut aussi être un onglet d'éditeur. On ne présume
            // d'aucune application : `WindowChoice` tranche sur les titres.
            return running.filter { $0.activationPolicy == .regular }
        }
    }

    private static func missingApplication(for target: LaneTarget, name: String) -> String {
        switch target {
        case .window(let owner, _):
            "« \(name) » vivait dans \(owner), qui n'est plus lancée."
        case .workspace:
            "Aucune application visible ne porte « \(name) » : la fenêtre a dû être fermée."
        }
    }

    private static func nameOf(_ app: NSRunningApplication) -> String {
        app.localizedName ?? app.bundleIdentifier ?? "L'application"
    }

    // MARK: - Sans l'Accessibilité

    /// **`activate()` seul ne demande aucune autorisation.** Le geste dégradé
    /// reste donc utile : on amène la bonne application au premier plan, ce qui
    /// est déjà l'essentiel du chemin, et on dit ce qui manque pour aller
    /// jusqu'à la bonne fenêtre.
    ///
    /// Pour une voie Claude Code, on n'a même pas d'application : le seul
    /// candidat est alors la liste des fenêtres du serveur graphique. Elle
    /// dépend de l'autorisation Enregistrement de l'écran, que le veilleur
    /// utilise déjà quand il observe les fenêtres — et quand elle manque aussi,
    /// tous les titres sont vides et on ne trouve simplement rien, sans mentir.
    private static func withoutAccessibility(
        apps: [NSRunningApplication],
        identity: LaneIdentity
    ) -> Outcome {
        let reason = "L'autorisation Accessibilité manque : bran peut amener l'application au premier plan, mais pas remonter une fenêtre précise."

        let listed = WindowList.onScreen().compactMap { window -> (WindowCandidate, NSRunningApplication)? in
            guard let app = NSRunningApplication(processIdentifier: window.processID),
                  app.processIdentifier != NSRunningApplication.current.processIdentifier
            else { return nil }
            let owner = app.bundleIdentifier ?? window.ownerName ?? ""
            return (WindowCandidate(owner: owner, title: window.title), app)
        }

        // **Pour une voie de fenêtre, le propriétaire est une condition, pas un
        // bonus.** `WindowChoice` note le propriétaire favorablement mais accepte
        // un titre qui correspond chez n'importe qui. Le cas concret : la voie
        // est `win:com.apple.TextEdit:Notes`, TextEdit tourne mais sa fenêtre a
        // été fermée, et Safari a un onglet intitulé « Notes ». Le score de
        // Safari passe, et le geste de retour vous emmène dans le navigateur.
        //
        // Une voie Claude Code n'a pas ce problème : elle n'a pas de
        // propriétaire par construction — elle vient d'une transcription, pas
        // d'une fenêtre — donc la recherche reste ouverte à toutes les
        // applications, ce qui est exactement son but.
        let searchable: [(WindowCandidate, NSRunningApplication)] = {
            guard case .window = LaneTarget(key: identity.key) else { return listed }
            let owned = Set(apps.map(\.processIdentifier))
            return listed.filter { owned.contains($0.1.processIdentifier) }
        }()

        if let winner = WindowChoice.best(among: searchable.map(\.0), for: identity),
           let match = searchable.first(where: { $0.0 == winner }) {
            match.1.activate()
            return .appOnly(reason: reason)
        }

        return giveUp(target: LaneTarget(key: identity.key), apps: apps, identity: identity, prefix: reason)
    }

    /// **Ce qu'on fait quand on n'a pas trouvé la fenêtre — et surtout ce qu'on
    /// ne fait pas.**
    ///
    /// La version précédente activait `apps.first` dans tous les cas. Pour une
    /// voie de fenêtre c'est correct : `apps` a été filtré sur le propriétaire,
    /// donc la première entrée est la bonne application, seulement pas la bonne
    /// fenêtre. Pour une voie Claude Code, `apps` est **toutes** les applications
    /// de premier plan de la machine, dans l'ordre non spécifié que rend
    /// `NSWorkspace.shared.runningApplications`.
    ///
    /// Le cas concret, et c'est le plus fréquent : une voie `cc:…/castral/crm`
    /// dont le terminal affiche `user@kvm4: ~`, sans jamais nommer le dossier.
    /// Aucun titre ne correspond, et l'utilisateur qui clique « revenir sur
    /// crm » atterrissait dans Mail. `WindowChoice` le dit dans son propre
    /// en-tête : déplacer quelqu'un là où il n'a rien demandé lui fait perdre sa
    /// place **et** sa confiance, ce qui est pire que de ne rien faire.
    ///
    /// Donc : on n'active que si `apps` a été restreint à un propriétaire connu.
    private static func giveUp(
        target: LaneTarget?,
        apps: [NSRunningApplication],
        identity: LaneIdentity,
        prefix: String? = nil
    ) -> Outcome {
        let lost = "bran n'a pas retrouvé la fenêtre de « \(identity.displayName) » : son titre a dû changer depuis la dernière observation."

        guard case .window = target, let app = apps.first else {
            // Aucun propriétaire connu : on ne bouge personne. Le message dit
            // quoi faire plutôt que de laisser l'utilisateur chercher.
            let advice = "Aucune fenêtre ouverte ne nomme « \(identity.displayName) ». Le titre du terminal peut ne nommer que la machine — voir « Naming the work behind an SSH session » dans le README."
            return .notFound(reason: [prefix, advice].compactMap { $0 }.joined(separator: " "))
        }

        app.activate()
        return .appOnly(reason: [prefix, "\(nameOf(app)) est au premier plan, mais \(lost)"].compactMap { $0 }.joined(separator: " "))
    }

    // MARK: - Accessibilité

    /// Les fenêtres titrées d'une application, vues par l'API d'accessibilité.
    ///
    /// Les fenêtres sans titre sont écartées : elles ne sont ni nommables ni
    /// identifiables, et `WindowChoice` ne saurait rien en faire — c'est le même
    /// parti pris que `WindowList.onScreen(titled:)`.
    private static func accessibleWindows(
        of app: NSRunningApplication
    ) -> [(title: String, element: AXUIElement)] {
        let application = AXUIElementCreateApplication(app.processIdentifier)

        // **Sans ce délai, un clic sur la pilule peut geler bran.**
        // `AXUIElementCopyAttributeValue` est synchrone et attend la réponse de
        // l'application visée. Une application bloquée reste dans
        // `runningApplications` et répond à `activate()` : elle a l'air vivante.
        // L'appel d'accessibilité, lui, attend le délai par défaut — six
        // secondes — sur le fil principal, et pendant ce temps l'interface de
        // bran ne répond plus. Un geste censé faire gagner du temps se
        // transformerait en roue qui tourne.
        //
        // 250 ms est très au-dessus de ce que met une application saine
        // (quelques millisecondes) et très en dessous de ce qui se remarque. Au
        // pire on retombe sur le geste dégradé, qui amène quand même la bonne
        // application au premier plan.
        AXUIElementSetMessagingTimeout(application, 0.25)

        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &raw) == .success,
              let windows = raw as? [AXUIElement]
        else { return [] }

        return windows.compactMap { window in
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &value) == .success,
                  let title = value as? String, title.isEmpty == false
            else { return nil }
            return (title, window)
        }
    }

    /// **Trois gestes, et pas un seul.** `AXRaise` met la fenêtre au-dessus des
    /// autres fenêtres de son application, mais ne la désigne pas comme
    /// principale : après un `activate()`, macOS redonne le focus à celle que
    /// l'application considère comme sienne, et l'utilisateur voit passer la
    /// bonne fenêtre puis revenir la mauvaise. `kAXMainWindowAttribute` sur
    /// l'application ferme ce trou.
    ///
    /// Les codes de retour sont ignorés volontairement : une fenêtre peut
    /// refuser l'un des trois — une palette flottante, une feuille modale — sans
    /// que le geste ait échoué pour autant. Ce qui compte est dit par le
    /// `Outcome`, pas par l'API.
    private static func raise(_ window: AXUIElement, in app: NSRunningApplication) {
        let application = AXUIElementCreateApplication(app.processIdentifier)
        _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        _ = AXUIElementSetAttributeValue(application, kAXMainWindowAttribute as CFString, window)
        _ = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
    }
}
