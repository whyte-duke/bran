import ApplicationServices
import BranSpeech
import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Le guet du raccourci global.
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
/// définitivement muette en silence. D'où `re-enable` ci-dessous, et d'où un
/// callback qui ne fait rien d'autre que poster sur la boucle principale.
@MainActor
final class HotkeyMonitor {

    enum Signal: Sendable {
        case triggerDown
        case triggerUp
        case cancel
    }

    var trigger: HotkeyBinding = .rightCommand
    var cancelKey: HotkeyBinding = .escape

    /// Appelé sur la boucle principale. Doit rester bref.
    var onSignal: ((Signal) -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    /// Dernier masque de modificateurs connu, pour distinguer un appui d'un
    /// relâchement dans `flagsChanged`.
    private var lastFlags: CGEventFlags = []
    private var isTriggerHeld = false

    private(set) var isInstalled = false

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
        isTriggerHeld = false
    }

    deinit {
        // `deinit` ne peut pas toucher à l'état `@MainActor` — la leçon a déjà
        // été apprise sur `RecordingEngine`. Le nettoyage se fait dans
        // `uninstall()`, appelé explicitement.
    }

    // MARK: - Réception (thread du tap, pas la boucle principale)

    /// Appelé par le callback C. Ne fait rien de coûteux : classer l'événement,
    /// et transmettre. Tout le reste attend la boucle principale.
    nonisolated private func receive(type: CGEventType, event: CGEvent) {
        // Le réarmement d'abord : c'est la seule branche dont dépend la survie
        // du raccourci.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            MainActor.assumeIsolated { self.reenable() }
            return
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags

        MainActor.assumeIsolated {
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
        if type == .keyDown, matches(cancelKey, keyCode: keyCode, flags: flags) {
            onSignal?(.cancel)
            return
        }

        // — Déclencheur modificateur seul ————————————————————————
        if trigger.isModifierOnly {
            guard type == .flagsChanged, keyCode == trigger.keyCode else { return }

            // Un `flagsChanged` ne dit pas s'il s'agit d'un appui ou d'un
            // relâchement : il faut regarder si le bit correspondant vient
            // d'apparaître ou de disparaître.
            let bit = Self.deviceBit(for: trigger.keyCode)
            let isDown = (flags.rawValue & bit) != 0
            let wasDown = (lastFlags.rawValue & bit) != 0
            guard isDown != wasDown else { return }

            isTriggerHeld = isDown
            onSignal?(isDown ? .triggerDown : .triggerUp)
            return
        }

        // — Déclencheur touche normale ——————————————————————————
        guard keyCode == trigger.keyCode else { return }
        if type == .keyDown, matches(trigger, keyCode: keyCode, flags: flags) {
            isTriggerHeld = true
            onSignal?(.triggerDown)
        } else if type == .keyUp, isTriggerHeld {
            isTriggerHeld = false
            onSignal?(.triggerUp)
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
