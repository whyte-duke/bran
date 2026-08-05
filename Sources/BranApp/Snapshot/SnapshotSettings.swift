import BranSpeech
import BranVision
import Foundation
import Observation

/// Les réglages de la capture de texte, persistés dans `UserDefaults`.
///
/// Rien de secret ici non plus : pas de jeton, pas de clé. Le trousseau serait
/// du zèle.
@MainActor
@Observable
final class SnapshotSettings {

    private enum Key {
        static let enabled = "bran.snapshot.enabled"
        static let trigger = "bran.snapshot.trigger"
        static let language = "bran.snapshot.language"
        static let layout = "bran.snapshot.layout"
        static let retentionDays = "bran.snapshot.retentionDays"
        static let playsSound = "bran.snapshot.playsSound"
        static let pastesAutomatically = "bran.snapshot.pastesAutomatically"
        static let trimsTrailingSpace = "bran.snapshot.trimsTrailingSpace"
    }

    var isEnabled: Bool { didSet { defaults.set(isEnabled, forKey: Key.enabled) } }
    var trigger: HotkeyBinding { didSet { store(trigger, forKey: Key.trigger) } }
    var language: OCRLanguage { didSet { defaults.set(language.rawValue, forKey: Key.language) } }
    var retentionDays: Int { didSet { defaults.set(retentionDays, forKey: Key.retentionDays) } }
    var playsSound: Bool { didSet { defaults.set(playsSound, forKey: Key.playsSound) } }

    /// Coller en plus de copier.
    ///
    /// Faux par défaut : ce qui a été demandé, c'est le presse-papiers. Coller
    /// automatiquement dans la fenêtre d'où l'on vient est parfois exactement ce
    /// qu'on veut, et parfois une catastrophe — on capture souvent du texte
    /// *depuis* l'application où l'on écrit.
    var pastesAutomatically: Bool { didSet { defaults.set(pastesAutomatically, forKey: Key.pastesAutomatically) } }

    /// Supprimer les espaces en fin de ligne produits par la reconstruction des
    /// colonnes. Vrai par défaut : personne ne veut d'espaces invisibles dans un
    /// message qu'il vient de coller.
    var trimsTrailingSpace: Bool { didSet { defaults.set(trimsTrailingSpace, forKey: Key.trimsTrailingSpace) } }

    /// Le mode de mise en page par défaut.
    ///
    /// `.monospaced` par défaut, et c'est un choix mesuré : appliqué à de la
    /// prose il ajoute quelques espaces sans rien casser, alors que l'inverse —
    /// lire du terminal en mode prose — détruit l'alignement des colonnes et
    /// l'indentation. Le coût de l'erreur n'est pas symétrique.
    var defaultLayout: LayoutMode { didSet { defaults.set(defaultLayout.rawValue, forKey: Key.layout) } }

    private let defaults = UserDefaults.standard

    init() {
        // Activée par défaut, comme la dictée, et pour la même raison. Elle ne
        // demande aucune autorisation supplémentaire : celle de l'écran suffit,
        // et elle est déjà nécessaire aux réunions.
        isEnabled = defaults.object(forKey: Key.enabled) as? Bool ?? true
        trigger = Self.read(HotkeyBinding.self, forKey: Key.trigger) ?? .textCapture
        language = (defaults.string(forKey: Key.language)).flatMap(OCRLanguage.init) ?? .french
        defaultLayout = (defaults.string(forKey: Key.layout)).flatMap(LayoutMode.init) ?? .monospaced
        retentionDays = defaults.object(forKey: Key.retentionDays) as? Int ?? 7
        playsSound = defaults.object(forKey: Key.playsSound) as? Bool ?? true
        pastesAutomatically = defaults.object(forKey: Key.pastesAutomatically) as? Bool ?? false
        trimsTrailingSpace = defaults.object(forKey: Key.trimsTrailingSpace) as? Bool ?? true
    }

    var retention: SnapshotRetention { .days(retentionDays) }

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

extension HotkeyBinding {
    /// ⌘⇧2 pour la capture de texte.
    ///
    /// Choisi pour se ranger juste à côté des raccourcis de capture d'écran de
    /// macOS — ⌘⇧3 pour l'écran entier, ⌘⇧4 pour une zone, ⌘⇧5 pour le
    /// panneau. ⌘⇧2 est libre et tombe dans la même famille de gestes : c'est
    /// la place que la fonction occuperait si Apple l'avait livrée.
    public static let textCapture = HotkeyBinding(
        keyCode: 19,                       // touche « 2 »
        modifiers: 0x10_0000 | 0x2_0000    // ⌘ + ⇧
    )
}
