import ApplicationServices
import BranSpeech
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import Synchronization

/// Le guet des raccourcis globaux.
///
/// Pourquoi un `CGEventTap` et pas Carbon `RegisterEventHotKey` : une touche
/// modificatrice seule — Command droite — n'émet jamais de `keyDown`. Elle
/// n'apparaît que dans `flagsChanged`, et il faut comparer l'ancien masque au
/// nouveau pour savoir si elle vient d'être enfoncée ou relâchée. Carbon ne sait
/// pas faire ça.
///
/// **Le piège que tout le monde oublie** : si le callback met trop de temps,
/// macOS désactive le tap et envoie `.tapDisabledByTimeout`. Sans réarmement, le
/// raccourci est mort jusqu'au redémarrage de l'application, **sans aucun
/// message**. C'est le seul défaut de cette fonctionnalité qui la rende
/// définitivement muette en silence. D'où `reenable` ci-dessous, et d'où un
/// callback qui ne fait rien d'autre que poster sur la boucle principale.
///
/// **Un seul tap pour toutes les fonctions.** La dictée et la capture de texte
/// partagent ce guet. Instancier un second `HotkeyMonitor` créerait un
/// deuxième tap sur tout le clavier du système : deux fois le travail à chaque
/// frappe, et surtout deux ports qui peuvent mourir indépendamment sur un
/// dépassement de délai. Un seul port, plusieurs liaisons.
///
/// ```
///   ┌─────────────────────┐
///   │     CGEventTap      │  un seul, listenOnly
///   └──────────┬──────────┘
///        ┌─────┴──────┬────────────┐
///        ▼            ▼            ▼
///     dictée      capture      annulation
///   (⌘ droite)   (⌘⇧2 …)         (Échap)
/// ```
@MainActor
final class HotkeyMonitor {

    /// Ce qu'un raccourci déclenche.
    ///
    /// L'énumération elle-même est `GlobalTrigger`, dans `BranSpeech` : la liste
    /// des fonctions déclenchables et l'arbitrage entre elles sont de la logique
    /// pure, et enfermées ici elles n'étaient testables par rien. L'alias existe
    /// pour que le vocabulaire du guet reste le sien — un `HotkeyMonitor` parle
    /// d'actions — sans dupliquer la liste.
    typealias Action = GlobalTrigger

    enum Signal: Sendable {
        case triggerDown(Action)
        case triggerUp(Action)
        case cancel
    }

    /// Les touches surveillées, par fonction. Une fonction absente n'est pas
    /// surveillée du tout.
    ///
    /// Cette table-ci ne contient que les fonctions **actives**. Celle des
    /// réglages — `GlobalTriggerRegistry` — contient tout ce qui est persisté,
    /// active ou non, et c'est elle que l'interface interroge.
    ///
    /// Le `didSet` fait trois choses et non une : réviser le filtre du callback,
    /// **relâcher les fonctions dont la touche vient de changer sous les
    /// doigts** — voir `releaseTriggersLosingTheirKey(since:)` —, puis remettre
    /// le masque de modificateurs à l'heure. Ces effets sont ici, sur la
    /// propriété, et non dans `bind` : c'est le seul endroit par lequel toute
    /// écriture de la table passe forcément.
    ///
    /// **L'ordre des trois compte.** `resyncFlags` protège les bits des
    /// fonctions encore dans `held` — c'est tout l'objet de
    /// `TriggerTable.resyncedFlags(from:held:)`. Le faire avant le relâchement
    /// protégerait justement celles qui viennent de perdre leur touche : leur
    /// bit resterait figé sur « enfoncé » dans `lastFlags`, et on aurait
    /// reconstruit à la main le défaut que la remise à l'heure existe pour
    /// corriger. Après le relâchement, `held` ne contient plus que des fonctions
    /// réellement tenues, sur des touches réellement surveillées.
    private(set) var bindings = TriggerTable() {
        didSet {
            refreshWatchedKeys()
            releaseTriggersLosingTheirKey(since: oldValue)
            resyncFlags()
        }
    }

    /// Déplacer l'annulation ne relâche rien — l'annulation n'entre jamais dans
    /// `held` — mais change bien le filtre, donc les touches dont `lastFlags`
    /// cessera d'être tenu à jour.
    var cancelKey: HotkeyBinding = .escape {
        didSet {
            refreshWatchedKeys()
            resyncFlags()
        }
    }

    /// Les codes de touche qui méritent qu'on regarde de plus près, lisibles
    /// depuis le callback du tap.
    ///
    /// Le tap voit **tout le clavier du système**. Sans ce filtre, écrire un
    /// message dans une autre application créerait une tâche par frappe — pour
    /// que `classify` conclue aussitôt qu'il n'y a rien à faire. À quatre-vingts
    /// mots la minute ça fait une dizaine de tâches par seconde, et c'est
    /// précisément le genre de charge qui fait dépasser au callback le budget de
    /// temps que macOS lui accorde.
    ///
    /// Un `Mutex` et non l'état de l'acteur : le callback n'est pas un contexte
    /// isolé, et il doit pouvoir répondre sans attendre personne.
    private let watchedKeys = Mutex<Set<UInt16>>([HotkeyBinding.escape.keyCode])

    private func refreshWatchedKeys() {
        var codes = bindings.keyCodes
        codes.insert(cancelKey.keyCode)
        watchedKeys.withLock { $0 = codes }
    }

    /// Remet `lastFlags` sur l'état réel du clavier.
    ///
    /// **Pourquoi c'est indispensable dès que la liste des touches surveillées
    /// change.** `lastFlags` n'est écrit que par `classify`, donc seulement pour
    /// les touches qui passent le filtre. Une touche qui cesse d'être surveillée
    /// fige son bit sur la dernière valeur vue — et un bit figé sur « enfoncé »
    /// rend le prochain appui *invisible* : `isDown != wasDown` est faux,
    /// `classify` passe son chemin, et la fonction ne répond qu'au deuxième
    /// appui. C'est le même défaut que celui du relâchement perdu, vu de
    /// l'autre côté : couper la dictée en tenant ⌘ droite, la rallumer, et le
    /// premier appui ne fait rien.
    ///
    /// `CGEventSource.flagsState` demande l'état courant au système au lieu de
    /// le déduire. Écarté : remettre `lastFlags` à `[]`, qui fabriquerait un
    /// faux appui à la première frappe si la touche est réellement tenue pendant
    /// le réglage.
    ///
    /// ## Pourquoi `.hidSystemState` et pas les deux autres
    ///
    /// Mesuré sur macOS 26.5 (Apple Silicon) avec une sonde jetable, en postant
    /// des `flagsChanged` au niveau pilote et au niveau session puis en lisant
    /// les trois identifiants. Trois choses, dont deux ne s'inventaient pas :
    ///
    /// - **les bits gauche/droite y sont**, ce dont dépend tout
    ///   `deviceModifierBit`. ⌘ droite tenue donne `0x0000_0000_2010_0110` —
    ///   `maskCommand`, `nonCoalesced`, et `0x10` qui est le bit périphérique de
    ///   ⌘ droite. De même `0x…0108` pour ⌘ gauche, `0x…0102` pour ⇧ gauche,
    ///   `0x…0120` pour ⌥ gauche, `0x…0101` pour ⌃ gauche. La crainte d'un
    ///   masque qui ne porterait que `maskCommand` ne se vérifie pas ;
    /// - **`.combinedSessionState` voit le synthétique de session, pas
    ///   `.hidSystemState`.** Un `flagsChanged` ⌘ gauche posté sur
    ///   `.cgSessionEventTap` — ce que fait n'importe quelle application ayant
    ///   l'Accessibilité — donne `0x…2010_0108` en état combiné, avec le bit
    ///   périphérique, pendant que l'état HID reste à `0x0` d'un bout à l'autre.
    ///   L'état combiné retarde en plus d'un échantillon (~80 ms). C'est
    ///   exactement la fragilité que l'on nous signalait, et elle est réelle :
    ///   un correcteur orthographique ou un automatisme tiers suffirait à faire
    ///   croire à bran qu'un modificateur est tenu ;
    /// - **`.privateState` est à ne jamais appeler.**
    ///   `CGEventSource.flagsState(.privateState)` **ne rend pas la main** :
    ///   interblocage dans SkyLight (`CGSEventSourceForID` → `std::mutex::lock`).
    ///   Constaté trois fois sur trois, processus tué au bout de six secondes.
    ///
    /// `.hidSystemState` est donc le seul des trois qui décrive un état
    /// *physique*, et c'est déjà celui que `Paster.sendCommandV` et
    /// `WatchController` emploient.
    ///
    /// ## Ce que le choix de l'identifiant ne règle pas
    ///
    /// Le ⌘V que bran synthétise est posté sur `.cghidEventTap` — délibérément,
    /// pour que toutes les applications le voient. Il entre donc dans l'état HID
    /// comme le ferait du vrai matériel, et les deux identifiants sont pollués
    /// de la même façon : mesuré, l'état reste à `0x0000_0000_2010_0000` —
    /// `maskCommand` **sans aucun bit périphérique** — pendant au moins quinze
    /// secondes après le collage, jusqu'au prochain événement quel qu'il soit.
    /// Pire, avec ⌘ droite réellement tenue, l'état passe de `0x…2010_0110` à
    /// `0x…2010_0000` : **le faux ⌘V efface le bit de la touche tenue.**
    ///
    /// Le `maskCommand` parasite est inoffensif — rien ne lit `lastFlags`
    /// autrement que bit périphérique par bit périphérique. L'effacement, lui,
    /// ferait perdre un relâchement, et c'est `TriggerTable.resyncedFlags` qui
    /// le ferme : les bits des fonctions encore tenues ne sont jamais retirés.
    private func resyncFlags() {
        let systemFlags = CGEventSource.flagsState(.hidSystemState).rawValue
        lastFlags = CGEventFlags(
            rawValue: bindings.resyncedFlags(from: systemFlags, held: held)
        )
    }

    /// Rend son relâchement à toute fonction dont la touche a changé pendant
    /// qu'elle était tenue.
    ///
    /// **Ce qui se passait sans ça.** `bind` ne nettoyait `held` que sur un
    /// `nil`, et sans jamais signaler quoi que ce soit. Deux trous, pas un :
    ///
    /// - **rebrancher** la dictée pendant que l'ancienne touche est enfoncée la
    ///   laissait dans `held`, et le `keyUp` de cette touche — désormais hors du
    ///   filtre `watchedKeys` — n'arrivait jamais jusqu'à `classify`. Une dictée
    ///   en mode « maintenir » restait en capture indéfiniment ;
    /// - **débrancher** la nettoyait bien de `held`, mais en silence : personne
    ///   ne recevait le `.triggerUp`, et la capture en cours restait ouverte
    ///   exactement de la même façon. Le nettoyage traitait le symptôme visible
    ///   dans le débogueur, pas celui que l'utilisateur constate.
    ///
    /// On émet donc `.triggerUp`, et pas `.cancel` : c'est très exactement le
    /// signal qu'aurait produit le relâchement physique de la touche qu'on vient
    /// de retirer. L'utilisateur a parlé ; jeter ce qu'il a dit parce qu'il a
    /// touché à ses réglages serait un choix, et ce n'est pas celui-là. Rien à
    /// faire du côté de `ShortcutRouter` : c'est un signal qu'il sait déjà
    /// router.
    ///
    /// `cancelKey` n'a pas besoin du même traitement : l'annulation ne s'observe
    /// qu'au `keyDown`, n'entre jamais dans `held` et ne laisse donc aucun état
    /// à libérer quand on la déplace.
    private func releaseTriggersLosingTheirKey(since previous: TriggerTable) {
        let released = bindings.triggersLosingTheirKey(since: previous, among: held)
        guard released.isEmpty == false else { return }

        // Retirées de `held` **avant** d'être signalées. Un `onSignal` peut
        // rappeler `bind` — l'écran des réglages est à un clic, et
        // `applySettings` rebranche tout —, ce qui rentrerait une seconde fois
        // dans le `didSet` de `bindings`. Dans cet ordre, la réentrance trouve
        // un ensemble déjà vidé et s'arrête ; dans l'autre, elle n'a pas de
        // fond.
        held.subtract(released)
        for action in released { onSignal?(.triggerUp(action)) }
    }

    /// Appelé sur la boucle principale. Doit rester bref.
    var onSignal: ((Signal) -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    /// Dernier masque de modificateurs connu, pour distinguer un appui d'un
    /// relâchement dans `flagsChanged`.
    private var lastFlags: CGEventFlags = []
    /// Les fonctions dont la touche est actuellement enfoncée. Un ensemble et
    /// non un booléen : maintenir Command droite pour dicter pendant qu'un
    /// autre raccourci va et vient doit rester cohérent.
    private var held: Set<Action> = []

    private(set) var isInstalled = false

    // MARK: - Liaisons

    /// Associe une touche à une fonction. `nil` retire la surveillance.
    ///
    /// Si la fonction était tenue au moment du changement, son relâchement est
    /// signalé — voir `releaseTriggersLosingTheirKey(since:)`. Rien à écrire
    /// ici : le `didSet` de `bindings` s'en charge, quel que soit le chemin par
    /// lequel la table a changé.
    func bind(_ action: Action, to binding: HotkeyBinding?) {
        bindings[action] = binding
    }

    /// Les fonctions **actives** qui partagent la même touche qu'`action`.
    ///
    /// Reste ici pour le diagnostic — un journal, un test manuel — mais
    /// l'interface ne s'en sert pas : elle passe par
    /// `GlobalTriggerRegistry.conflicts`, qui voit aussi les fonctions
    /// désactivées. Deux réponses différentes à la même question, chacune juste
    /// pour son appelant ; l'algorithme, lui, est unique — `TriggerTable`.
    func conflicts(for binding: HotkeyBinding, excluding action: Action) -> [Action] {
        bindings.conflicts(for: binding, excluding: action)
    }

    // MARK: - Autorisation

    /// L'Accessibilité est-elle accordée ? Sans elle, `CGEvent.tapCreate`
    /// renvoie `nil` et rien ne fonctionnera — ni la lecture, ni le collage.
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Ouvre la fenêtre système. macOS ne rend l'autorisation effective qu'au
    /// prochain lancement du processus.
    static func requestTrust() {
        // La constante `kAXTrustedCheckOptionPrompt` est une variable globale
        // mutable côté C, que Swift 6 refuse de lire depuis un contexte
        // concurrent. Sa valeur est figée depuis toujours.
        let options = ["AXTrustedCheckOptionPrompt": true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    /// macOS coupe tous les taps quand le curseur est dans un champ de mot de
    /// passe. Rien ne le contourne — c'est le but. On peut seulement le
    /// constater et l'expliquer, plutôt que laisser croire à une panne.
    static var isSecureInputActive: Bool { IsSecureEventInputEnabled() }

    // MARK: - Installation

    @discardableResult
    func install() -> Bool {
        guard tap == nil else { return true }
        guard Self.isTrusted else { return false }

        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)

        // `listenOnly` : on observe sans consommer. Consommer Command droite
        // casserait les raccourcis à deux mains de toutes les autres apps.
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(context).takeUnretainedValue()
                monitor.receive(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)

        tap = port
        source = runLoopSource
        isInstalled = true
        // Le guet peut très bien s'armer alors qu'un modificateur est déjà
        // enfoncé — on accorde l'Accessibilité, on revient à l'application avec
        // ⌘⇥. Sans cette remise à l'heure, `lastFlags` prétend que rien n'est
        // tenu et le premier relâchement se lit comme un appui.
        resyncFlags()
        return true
    }

    /// Retire le tap. **N'annonce rien** : les fonctions encore tenues sont
    /// oubliées sans `.triggerUp`, comme au retrait d'une liaison avant
    /// correction. Ce n'est pas un choix documenté, c'est un cas qui n'arrive
    /// pas encore — rien n'appelle `uninstall()` aujourd'hui. Le jour où
    /// quelqu'un l'appellera avec une dictée en cours, il faudra passer par
    /// `releaseTriggersLosingTheirKey` ou son équivalent.
    func uninstall() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        tap = nil
        source = nil
        isInstalled = false
        held.removeAll()
    }

    deinit {
        // `deinit` ne peut pas toucher à l'état `@MainActor` — la leçon a déjà
        // été apprise sur `RecordingEngine`. Le nettoyage se fait dans
        // `uninstall()`, appelé explicitement.
    }

    // MARK: - Réception (callback du port Mach)

    /// Appelé par le callback C. Lit l'événement — il n'est valide que pendant
    /// l'appel — et rend la main immédiatement.
    ///
    /// **Pourquoi ce `Task` et pas `MainActor.assumeIsolated`.** Le callback est
    /// bien exécuté sur le thread principal : la source est ajoutée à
    /// `CFRunLoopGetMain()`. `assumeIsolated` était donc formellement correct,
    /// et c'est précisément ce qui rendait le piège invisible — tout ce que la
    /// fonction déclenche s'exécutait **à l'intérieur du callback** :
    ///
    /// ```
    ///   callback du port Mach
    ///     └─ classify → onSignal → hotkeyDown → startCapture
    ///          ├─ AVAudioEngine.start()        ~30 ms
    ///          └─ NotchOverlay.show()
    ///               └─ NSPanel + NSHostingView.layout()   ← SwiftUI complet
    /// ```
    ///
    /// Deux dégâts, tous deux constatés :
    ///
    /// - **le tap se fait couper.** macOS accorde un budget de temps au
    ///   callback ; démarrer le moteur audio et poser un panneau SwiftUI le
    ///   dépasse. Le système répond `.tapDisabledByTimeout`, et sans le
    ///   réarmement ci-dessus le raccourci serait mort en silence ;
    /// - **on tourne hors de toute tâche.** Un callback de `CFRunLoop` n'a
    ///   aucune information d'exécuteur attachée. Chaque vérification
    ///   d'isolation insérée par Swift 6 sous cette pile — et SwiftUI en fait
    ///   une par image dans l'encoche — prend alors le chemin lent du runtime.
    ///   C'est là que le processus tombait, systématiquement, à chaque appui sur
    ///   Command droite.
    ///
    /// Un `Task { @MainActor }` rend la main au callback tout de suite et
    /// exécute la suite comme n'importe quel autre travail de l'application.
    /// L'ordre est conservé : les jobs d'un acteur sont traités dans l'ordre où
    /// ils sont soumis, donc un appui ne peut pas doubler son relâchement.
    nonisolated private func receive(type: CGEventType, event: CGEvent) {
        // Le réarmement d'abord : c'est la seule branche dont dépend la survie
        // des raccourcis.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Task { @MainActor in self.reenable() }
            return
        }

        // Lu ici, pas dans la tâche : `event` appartient au système et n'est
        // valide que le temps du callback.
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))

        // Le filtre porte sur le seul code de touche, jamais sur les
        // modificateurs : un raccourci à modificateur seul — Command droite —
        // n'apparaît que dans `flagsChanged`, et son code y est celui de la
        // touche elle-même. Filtrer sur le masque le manquerait.
        guard watchedKeys.withLock({ $0.contains(keyCode) }) else { return }

        let flags = event.flags

        Task { @MainActor in
            self.classify(type: type, keyCode: keyCode, flags: flags)
        }
    }

    private func reenable() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func classify(type: CGEventType, keyCode: UInt16, flags: CGEventFlags) {
        defer { lastFlags = flags }

        // — Annulation ————————————————————————————————————————————
        //
        // Testée en premier, et seulement si aucune fonction ne revendique la
        // même touche : sinon régler la capture sur Échap rendrait l'annulation
        // et le déclenchement indiscernables.
        if type == .keyDown,
           matches(cancelKey, keyCode: keyCode, flags: flags),
           bindings.isTaken(cancelKey) == false {
            onSignal?(.cancel)
            return
        }

        // — Fonctions ——————————————————————————————————————————————
        //
        // Ordre stable : `assigned` rend les liaisons dans l'ordre de
        // `allCases`, pas dans celui d'un dictionnaire. Deux fonctions sur la
        // même touche ne doivent pas se déclencher dans un ordre qui change
        // d'un lancement à l'autre.
        for (action, binding) in bindings.assigned {
            if binding.isModifierOnly {
                guard type == .flagsChanged, keyCode == binding.keyCode else { continue }

                // Un `flagsChanged` ne dit pas s'il s'agit d'un appui ou d'un
                // relâchement : il faut regarder si le bit correspondant vient
                // d'apparaître ou de disparaître.
                let bit = binding.deviceModifierBit
                let isDown = (flags.rawValue & bit) != 0
                let wasDown = (lastFlags.rawValue & bit) != 0
                guard isDown != wasDown else { continue }

                if isDown { held.insert(action) } else { held.remove(action) }
                onSignal?(isDown ? .triggerDown(action) : .triggerUp(action))
                return
            }

            guard keyCode == binding.keyCode else { continue }
            if type == .keyDown, matches(binding, keyCode: keyCode, flags: flags) {
                held.insert(action)
                onSignal?(.triggerDown(action))
                return
            }
            if type == .keyUp, held.contains(action) {
                held.remove(action)
                onSignal?(.triggerUp(action))
                return
            }
        }
    }

    private func matches(_ binding: HotkeyBinding, keyCode: UInt16, flags: CGEventFlags) -> Bool {
        guard binding.keyCode == keyCode else { return false }
        guard binding.modifiers != 0 else {
            // Sans modificateur exigé, on refuse quand même les combinaisons :
            // ⌘Échap ne doit pas annuler une dictée.
            return flags.rawValue & Self.significantModifiers == 0
        }
        return flags.rawValue & Self.significantModifiers == binding.modifiers
    }

    /// Les bits qui comptent : Commande, Option, Contrôle, Majuscule. On ignore
    /// le verrouillage majuscule et le pavé numérique, qui polluent le masque
    /// sans jamais faire partie d'un raccourci.
    private static let significantModifiers: UInt64 =
        CGEventFlags.maskCommand.rawValue
        | CGEventFlags.maskAlternate.rawValue
        | CGEventFlags.maskControl.rawValue
        | CGEventFlags.maskShift.rawValue
}
