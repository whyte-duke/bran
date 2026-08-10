import Foundation

/// Un raccourci global, réduit à ce que `CGEventTap` sait observer.
///
/// Deux familles, et la différence n'est pas cosmétique :
///
/// - **une touche modificatrice seule** (Command droite) n'émet jamais de
///   `keyDown`. Elle n'apparaît que dans `flagsChanged`, et il faut comparer
///   l'ancien et le nouveau masque pour savoir si elle vient d'être enfoncée ou
///   relâchée. C'est pour ça que Carbon `RegisterEventHotKey` ne sait pas la
///   capter — et pour ça qu'on passe par un tap ;
/// - **une touche normale** (Échap) arrive en `keyDown` avec ses modificateurs.
public struct HotkeyBinding: Codable, Equatable, Sendable {

    public var keyCode: UInt16
    /// Masque `CGEventFlags` brut des modificateurs exigés, nettoyé des bits
    /// parasites (verrouillage majuscule, pavé numérique).
    public var modifiers: UInt64
    /// `true` quand `keyCode` désigne une touche modificatrice, donc observable
    /// uniquement via `flagsChanged`.
    public var isModifierOnly: Bool

    public init(keyCode: UInt16, modifiers: UInt64 = 0, isModifierOnly: Bool = false) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.isModifierOnly = isModifierOnly
    }

    // MARK: - Valeurs par défaut

    /// Command droite. Choisie parce qu'aucune application ne s'en sert seule,
    /// et qu'elle tombe sous le pouce droit au repos.
    public static let rightCommand = HotkeyBinding(keyCode: 54, isModifierOnly: true)

    /// Échap pour annuler. Le geste universel pour « laisse tomber ».
    public static let escape = HotkeyBinding(keyCode: 53)

    // MARK: - Affichage

    /// Les codes de touches que macOS n'expose nulle part sous forme lisible.
    /// Table volontairement courte : seules les touches qu'on peut raisonnablement
    /// vouloir comme raccourci global.
    private static let names: [UInt16: String] = [
        53: "Échap", 54: "⌘ droite", 55: "⌘ gauche", 56: "⇧ gauche", 60: "⇧ droite",
        58: "⌥ gauche", 61: "⌥ droite", 59: "⌃ gauche", 62: "⌃ droite", 63: "Fn",
        49: "Espace", 36: "Entrée", 48: "Tab", 51: "Suppr",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        // Les chiffres de la rangée du haut : ⌘⇧2 range la capture de texte
        // juste à côté de ⌘⇧3, ⌘⇧4 et ⌘⇧5 du système.
        18: "1", 19: "2", 20: "3", 21: "4", 23: "5",
        22: "6", 26: "7", 28: "8", 25: "9", 29: "0",
    ]

    public var displayName: String {
        let key = Self.names[keyCode] ?? "Touche \(keyCode)"
        guard isModifierOnly == false, modifiers != 0 else { return key }
        return Self.modifierSymbols(modifiers) + key
    }

    private static func modifierSymbols(_ mask: UInt64) -> String {
        var out = ""
        if mask & 0x4_0000 != 0 { out += "⌃" }   // control
        if mask & 0x8_0000 != 0 { out += "⌥" }   // option
        if mask & 0x2_0000 != 0 { out += "⇧" }   // shift
        if mask & 0x10_0000 != 0 { out += "⌘" }  // command
        return out
    }

    /// Les touches qu'on refuse comme raccourci principal.
    ///
    /// Retour et Espace seuls rendraient toute saisie de texte impossible :
    /// chaque espace démarrerait une dictée. Mieux vaut refuser que laisser
    /// quelqu'un se verrouiller hors de son propre clavier.
    public static let forbiddenAlone: Set<UInt16> = [36, 48, 49, 51, 76, 117]

    public var isAcceptableAsTrigger: Bool {
        if isModifierOnly { return true }
        if modifiers != 0 { return true }
        return Self.forbiddenAlone.contains(keyCode) == false
    }

    // MARK: - Le bit qui distingue la gauche de la droite

    /// Le bit « périphérique » du masque de modificateurs qui correspond à cette
    /// touche, ou `0` si ce n'est pas une touche modificatrice.
    ///
    /// **Pourquoi ces bits-là et pas `CGEventFlags.maskCommand`.** Le masque
    /// *indépendant du périphérique* dit « une touche Command est enfoncée »
    /// sans dire laquelle. Un raccourci sur ⌘ droite ne peut donc pas s'y fier :
    /// tenir ⌘ gauche allumerait le même bit. Les bits gauche/droite ci-dessous
    /// — les `NX_DEVICE…KEYMASK` de `IOLLEvent.h` — sont les seuls à répondre à
    /// la question posée. Ils ne sont pas exposés par `CGEventFlags`, mais ils
    /// sont stables depuis toujours et présents aussi bien dans les événements
    /// que dans l'état du système (mesuré, voir `HotkeyMonitor.resyncFlags`).
    ///
    /// Vit ici, sur la liaison, et non dans `HotkeyMonitor` : c'est une
    /// propriété de la touche, la seule chose qui la détermine est `keyCode`, et
    /// enfermée dans une cible exécutable elle n'était vérifiable par rien.
    public var deviceModifierBit: UInt64 {
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
