import AppKit
import AVFoundation
import BranSpeech
import Foundation
import Observation

/// Les réglages de la dictée, persistés dans `UserDefaults`.
///
/// Rien de secret ici : pas de jeton, pas de clé. Le trousseau serait du zèle.
@MainActor
@Observable
final class DictationSettings {

    private enum Key {
        static let enabled = "bran.dictation.enabled"
        static let trigger = "bran.dictation.trigger"
        static let triggerMode = "bran.dictation.triggerMode"
        static let cancelKey = "bran.dictation.cancelKey"
        static let language = "bran.dictation.language"
        static let retentionDays = "bran.dictation.retentionDays"
        static let inputDevice = "bran.dictation.inputDeviceUID"
        static let restoreClipboard = "bran.dictation.restoreClipboard"
        static let playsSound = "bran.dictation.playsSound"
        static let vocabulary = "bran.dictation.vocabulary"
        static let idleUnload = "bran.dictation.idleUnloadMinutes"
    }

    var isEnabled: Bool { didSet { defaults.set(isEnabled, forKey: Key.enabled) } }
    var trigger: HotkeyBinding { didSet { store(trigger, forKey: Key.trigger) } }
    var triggerMode: DictationMachine.Trigger { didSet { defaults.set(triggerMode.rawValue, forKey: Key.triggerMode) } }
    var cancelKey: HotkeyBinding { didSet { store(cancelKey, forKey: Key.cancelKey) } }
    var language: SpeechLanguage { didSet { defaults.set(language.rawValue, forKey: Key.language) } }
    var retentionDays: Int { didSet { defaults.set(retentionDays, forKey: Key.retentionDays) } }
    var restoresClipboard: Bool { didSet { defaults.set(restoresClipboard, forKey: Key.restoreClipboard) } }
    var playsSound: Bool { didSet { defaults.set(playsSound, forKey: Key.playsSound) } }
    var idleUnloadMinutes: Int { didSet { defaults.set(idleUnloadMinutes, forKey: Key.idleUnload) } }
    var vocabulary: VocabularyFixer { didSet { store(vocabulary, forKey: Key.vocabulary) } }

    /// UID du micro à utiliser, ou `nil` pour suivre le périphérique système.
    ///
    /// Le défaut est **le micro intégré**, et ce n'est pas un détail : sur
    /// macOS, les AirPods exposent une sortie 48 kHz et une entrée 16 kHz, et
    /// activer leur micro fait basculer le lien Bluetooth en HFP — toute la
    /// lecture retombe à 16 kHz jusqu'au relâchement. Quelqu'un qui dicte
    /// souvent avec un casque hacherait sa musique à chaque phrase. Le réseau
    /// de micros du MacBook est en prime nettement meilleur pour la
    /// reconnaissance.
    var inputDeviceUID: String? { didSet { defaults.set(inputDeviceUID, forKey: Key.inputDevice) } }

    private let defaults = UserDefaults.standard

    init() {
        isEnabled = defaults.object(forKey: Key.enabled) as? Bool ?? false
        trigger = Self.read(HotkeyBinding.self, forKey: Key.trigger) ?? .rightCommand
        triggerMode = (defaults.string(forKey: Key.triggerMode)).flatMap(DictationMachine.Trigger.init) ?? .toggle
        cancelKey = Self.read(HotkeyBinding.self, forKey: Key.cancelKey) ?? .escape
        language = (defaults.string(forKey: Key.language)).flatMap(SpeechLanguage.init) ?? .french
        retentionDays = defaults.object(forKey: Key.retentionDays) as? Int ?? 7
        restoresClipboard = defaults.object(forKey: Key.restoreClipboard) as? Bool ?? true
        playsSound = defaults.object(forKey: Key.playsSound) as? Bool ?? true
        idleUnloadMinutes = defaults.object(forKey: Key.idleUnload) as? Int ?? 5
        vocabulary = Self.read(VocabularyFixer.self, forKey: Key.vocabulary) ?? .starter
        inputDeviceUID = defaults.string(forKey: Key.inputDevice) ?? AudioInputDevice.builtIn?.uid
    }

    var retention: RetentionPolicy { .days(retentionDays) }

    // MARK: -

    private func store<T: Encodable>(_ value: T, forKey key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    private static func read<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

/// Un micro disponible.
///
/// On passe par CoreAudio et pas par `AVCaptureDevice` : il faut l'`AudioDeviceID`
/// pour l'imposer à `AVAudioEngine`, et `AVCaptureDevice` ne le donne pas.
struct AudioInputDevice: Identifiable, Hashable, Sendable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let isBuiltIn: Bool

    static var all: [AudioInputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
        ) == noErr else { return [] }

        return ids.compactMap(Self.describe).sorted { lhs, rhs in
            // Le micro intégré en tête : c'est celui qu'on recommande.
            if lhs.isBuiltIn != rhs.isBuiltIn { return lhs.isBuiltIn }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    static var builtIn: AudioInputDevice? { all.first(where: \.isBuiltIn) }

    static func device(uid: String?) -> AudioInputDevice? {
        guard let uid else { return nil }
        return all.first { $0.uid == uid }
    }

    private static func describe(_ id: AudioDeviceID) -> AudioInputDevice? {
        guard hasInput(id), let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
        let name = string(id, kAudioObjectPropertyName) ?? "Micro"
        return AudioInputDevice(
            id: id,
            uid: uid,
            name: name,
            // `transport type` plutôt que le nom : « Built-in » n'est pas
            // traduit pareil selon la langue du système.
            isBuiltIn: transport(id) == kAudioDeviceTransportTypeBuiltIn
        )
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else {
            return false
        }

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 8)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, buffer) == noErr else {
            return false
        }

        let list = buffer.assumingMemoryBound(to: AudioBufferList.self)
        return UnsafeMutableAudioBufferListPointer(list).contains { $0.mNumberChannels > 0 }
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value as String?
    }

    private static func transport(_ id: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<UInt32>.size)
        var value: UInt32 = 0
        _ = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
        return value
    }
}
