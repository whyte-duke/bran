import Carbon.HIToolbox
import Foundation
import Synchronization

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

    /// ⌘⇧V pour le panneau du presse-papiers.
    ///
    /// **⌘⇧V et non ⌘⇧C, et le raisonnement est le même que pour ⌘⇧2.** ⌘⇧C
    /// n'est pas libre : le Finder en fait « Aller › Ordinateur », et un grand
    /// nombre d'applications s'en servent pour copier une variante — le style,
    /// le chemin, le lien. Un tap global qui s'en empare le fait **partout et en
    /// silence** : l'utilisateur ne verrait pas bran prendre la touche, il
    /// verrait le Finder cesser de répondre.
    ///
    /// ⌘⇧V est ce que les gestionnaires de presse-papiers emploient déjà, et
    /// c'est la seule des deux qui dise ce que la fonction fait : on ouvre le
    /// panneau pour **coller**, pas pour copier. La copie, elle, n'a pas de
    /// raccourci à bran — elle en a un, ⌘C, et il appartient à l'application de
    /// devant.
    ///
    /// Modifiable comme les deux autres, par la même ligne de réglages.
    ///
    /// **Ici et non dans `BranApp`, contrairement au premier jet.** C'est une
    /// valeur, elle se lit et se compare, et `BranApp` est une cible exécutable
    /// sans tests : posée là-bas, elle était la seule des trois liaisons par
    /// défaut que rien ne pouvait vérifier. C'est d'ailleurs par elle que le
    /// trou de `displayName` s'est vu.
    public static let clipboardPanel = HotkeyBinding(
        keyCode: 9,                        // touche « V » en QWERTY comme en AZERTY
        modifiers: 0x10_0000 | 0x2_0000    // ⌘ + ⇧
    )

    // MARK: - Affichage

    /// Les codes de touches que macOS n'expose nulle part sous forme lisible.
    /// Table volontairement courte : seules les touches qu'on peut raisonnablement
    /// vouloir comme raccourci global.
    ///
    /// **Elle ne couvre pas les lettres, et c'est délibéré** — voir
    /// `layoutName(for:)`. Un code de touche ne désigne pas une lettre mais une
    /// position sur le clavier ; la lettre dépend de la disposition, et l'écrire
    /// ici reviendrait à décider que tout le monde tape en QWERTY.
    static let names: [UInt16: String] = [
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

    /// Ce que les réglages affichent : « ⌘⇧V », « ⌘ droite », « Échap ».
    ///
    /// Interroge la disposition clavier réellement installée pour tout ce que la
    /// table ne nomme pas. Voir `displayName(naming:)` pour l'ordre des deux
    /// sources, et `layoutName(for:)` pour l'interrogation elle-même.
    public var displayName: String {
        displayName(naming: Self.layoutName)
    }

    /// La forme pure, sans clavier : `naming` est la seule chose qui sache
    /// traduire un code de touche en caractère.
    ///
    /// **Séparée pour être vérifiable.** La disposition clavier est une propriété
    /// de la machine qui exécute les tests ; une suite qui affirmerait « le code
    /// 12 s'affiche A » passerait en AZERTY et échouerait en QWERTY, ce qui est
    /// la définition d'un test qu'on finit par supprimer. Ici la règle — la table
    /// d'abord, la disposition ensuite, le code brut en dernier recours — se
    /// vérifie sur un nommeur inventé, et le vrai clavier n'est plus qu'un
    /// fournisseur parmi d'autres.
    ///
    /// **La table gagne quand elle parle, et l'ordre compte.** Elle nomme les
    /// chiffres de la rangée du haut, or en AZERTY ces touches produisent « & »,
    /// « é », « " » sans Majuscule. Demander la disposition d'abord ferait
    /// afficher « ⌘⇧é » là où l'utilisateur lit « ⌘⇧2 » depuis toujours, et là
    /// où il voit « 2 » gravé sur la touche.
    func displayName(naming: (UInt16) -> String?) -> String {
        let key = Self.names[keyCode] ?? naming(keyCode) ?? "Touche \(keyCode)"
        guard isModifierOnly == false, modifiers != 0 else { return key }
        return Self.modifierSymbols(modifiers) + key
    }

    /// Le caractère que la disposition clavier **courante** produit pour ce code
    /// de touche, sans modificateur, en majuscule — ou `nil` si la question n'a
    /// pas de réponse affichable.
    ///
    /// **Le défaut que ça corrige.** ⌘⇧V s'affichait « ⌘⇧Touche 9 » dans les
    /// réglages : la table ne couvrait que les modificateurs, les touches de
    /// fonction et les chiffres, et aucun raccourci par défaut n'était tombé sur
    /// une lettre jusqu'à celui du presse-papiers. Le trou existait depuis le
    /// début et ne s'était jamais vu.
    ///
    /// **Pourquoi interroger le système plutôt qu'ajouter vingt-six lignes.**
    /// Un `keyCode` est une position physique, pas une lettre. Le code 12 est
    /// « Q » en QWERTY et « A » en AZERTY ; une table écrite en dur afficherait
    /// donc « ⌘⇧Q » à quelqu'un qui vient d'appuyer sur A. C'est exactement la
    /// même classe de défaut que celui qu'on corrige — un raccourci mal nommé —,
    /// simplement plus difficile à voir depuis un clavier américain.
    ///
    /// `kUCKeyActionDisplay` et `kUCKeyTranslateNoDeadKeysBit` : on demande le
    /// caractère **gravé sur la touche**, pas ce que la frappe produirait. Sans
    /// le second bit, une touche morte — l'accent circonflexe en français — ne
    /// rendrait rien du tout et retomberait sur « Touche 33 ».
    ///
    /// Rend `nil` plutôt qu'une chaîne vide pour tout ce qui n'est pas un unique
    /// caractère imprimable : les touches muettes, les commandes, et le cas où
    /// aucune disposition n'est lisible. L'appelant retombe alors sur le code
    /// brut, qui est laid mais jamais faux.
    static func layoutName(for keyCode: UInt16) -> String? {
        guard let layoutData = currentLayoutData() else { return nil }

        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 8)

        let status = layoutData.withUnsafeBytes { buffer -> OSStatus in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self)
            else { return OSStatus(paramErr) }
            return UCKeyTranslate(
                layout,
                keyCode,
                UInt16(kUCKeyActionDisplay),
                0,  // aucun modificateur : on veut la gravure, pas la frappe
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                characters.count,
                &length,
                &characters
            )
        }

        guard status == noErr, length > 0 else { return nil }
        let text = String(utf16CodeUnits: characters, count: length)
        guard text.count == 1,
              let scalar = text.unicodeScalars.first,
              CharacterSet.whitespacesAndNewlines.contains(scalar) == false,
              CharacterSet.controlCharacters.contains(scalar) == false
        else { return nil }
        return text.localizedUppercase
    }

    /// Le verrou qui sérialise l'interrogation de la disposition clavier.
    ///
    /// **Il empêche un plantage, pas une donnée fausse — mesuré, pas supposé.**
    /// `TISCopyCurrentKeyboardLayoutInputSource()` appelé depuis huit fils à la
    /// fois **avorte le processus** : SIGABRT, sans un message, sans exception,
    /// sans rien dans la sortie d'erreur. Réduit à l'appel seul, sans
    /// `UCKeyTranslate` derrière, il avorte encore ; `UCKeyTranslate` sur des
    /// données déjà copiées, lui, encaisse les mêmes huit fils sans broncher, et
    /// un unique fil d'arrière-plan passe aussi. C'est donc la copie concurrente
    /// de la source d'entrée, et elle seule.
    ///
    /// Découvert par la suite de tests, qui exécute ses cas en parallèle : le
    /// programme, lui, n'appelle ceci que depuis une ligne de réglages, donc
    /// depuis le fil principal, et n'aurait jamais rencontré la panne. C'est
    /// exactement le genre de mine qu'un jour d'usage ordinaire n'aurait pas fait
    /// sauter — et qu'un `Task.detached` posé plus tard, n'importe où, aurait
    /// déclenché sans que rien ne désigne cette ligne-ci.
    ///
    /// Pas de cache derrière le verrou : la disposition change quand
    /// l'utilisateur change de clavier, et un nom de raccourci périmé dans les
    /// réglages est précisément le défaut que tout ceci corrige. Le coût est un
    /// verrou par ligne affichée.
    private static let layoutLock = Mutex<Void>(())

    /// Les données de la disposition courante, une interrogation à la fois.
    private static func currentLayoutData() -> Data? {
        layoutLock.withLock { _ in
            guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
                  let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
            else { return nil }
            return Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        }
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
