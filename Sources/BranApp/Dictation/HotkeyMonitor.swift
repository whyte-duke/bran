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

    /// Ce qu'un raccourci déclenche. L'ordre de `allCases` fixe la priorité
    /// quand deux fonctions partagent la même touche — l'interface empêche ce
    /// cas, mais un fichier de réglages écrit à la main peut le produire.
    enum Action: String, CaseIterable, Sendable, Codable {
        case dictation
        case snapshot

        var label: String {
            switch self {
            case .dictation: "Dictée"
            case .snapshot: "Capture de texte"
            }
        }
    }

    enum Signal: Sendable {
        case triggerDown(Action)
        case triggerUp(Action)
        case cancel
    }

    /// Les touches surveillées, par fonction. Une fonction absente n'est pas
    /// surveillée du tout.
    private(set) var bindings: [Action: HotkeyBinding] = [:] {
        didSet { refreshWatchedKeys() }
    }

    var cancelKey: HotkeyBinding = .escape {
        didSet { refreshWatchedKeys() }
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
        var codes = Set(bindings.values.map(\.keyCode))
        codes.insert(cancelKey.keyCode)
        watchedKeys.withLock { $0 = codes }
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
    func bind(_ action: Action, to binding: HotkeyBinding?) {
        if let binding {
            bindings[action] = binding
        } else {
            bindings.removeValue(forKey: action)
            held.remove(action)
        }
    }

    /// Les fonctions qui partagent la même touche qu'`action`. L'interface s'en
    /// sert pour refuser un réglage avant qu'il ne casse quelque chose, plutôt
    /// que de laisser deux fonctions se déclencher ensemble.
    func conflicts(for binding: HotkeyBinding, excluding action: Action) -> [Action] {
        bindings.compactMap { key, value in
            guard key != action, value == binding else { return nil }
            return key
        }
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
        return true
    }

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
           bindings.values.contains(cancelKey) == false {
            onSignal?(.cancel)
            return
        }

        // — Fonctions ——————————————————————————————————————————————
        //
        // Ordre stable via `allCases` : deux fonctions sur la même touche ne
        // doivent pas se déclencher dans un ordre qui change d'un lancement à
        // l'autre.
        for action in Action.allCases {
            guard let binding = bindings[action] else { continue }

            if binding.isModifierOnly {
                guard type == .flagsChanged, keyCode == binding.keyCode else { continue }

                // Un `flagsChanged` ne dit pas s'il s'agit d'un appui ou d'un
                // relâchement : il faut regarder si le bit correspondant vient
                // d'apparaître ou de disparaître.
                let bit = Self.deviceBit(for: binding.keyCode)
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

    /// Les bits « périphérique » qui distinguent gauche et droite. Ils ne sont
    /// pas exposés par `CGEventFlags`, mais ils sont stables depuis toujours.
    private static func deviceBit(for keyCode: UInt16) -> UInt64 {
        switch keyCode {
        case 54: 0x0000_0010  // ⌘ droite
        case 55: 0x0000_0008  // ⌘ gauche
        case 56: 0x0000_0002  // ⇧ gauche
        case 60: 0x0000_0004  // ⇧ droite
        case 58: 0x0000_0020  // ⌥ gauche
        case 61: 0x0000_0040  // ⌥ droite
        case 59: 0x0000_0001  // ⌃ gauche
        case 62: 0x0000_2000  // ⌃ droite
        default: 0
        }
    }
}
