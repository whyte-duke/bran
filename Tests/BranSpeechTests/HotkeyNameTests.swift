import Testing

@testable import BranSpeech

/// Comment un raccourci se donne à lire dans les réglages.
///
/// **Ce que ces tests gardent.** ⌘⇧V s'affichait « ⌘⇧Touche 9 » : la table de
/// noms couvrait les modificateurs, les touches de fonction et les chiffres,
/// jamais les lettres, et aucun raccourci par défaut n'était tombé sur une
/// lettre avant celui du presse-papiers. Le trou était là depuis le début.
///
/// La règle qui le comble a trois étages — la table, la disposition clavier, le
/// code brut — et l'ordre des deux premiers est la seule chose subtile :
/// interroger la disposition d'abord ferait afficher « ⌘⇧É » sur un clavier
/// français là où l'utilisateur lit « ⌘⇧2 » depuis toujours.
@Suite("Le nom affiché d'un raccourci")
struct HotkeyNameTests {

    /// Un clavier inventé, pour que ces tests ne dépendent pas de celui de la
    /// machine qui les exécute. C'est tout l'intérêt de `displayName(naming:)`.
    private static func fakeLayout(_ keyCode: UInt16) -> String? {
        switch keyCode {
        case 8: "C"
        case 9: "V"
        case 12: "A"    // « Q » en QWERTY : la position, pas la lettre
        case 19: "É"    // ce que le code 19 produit vraiment en AZERTY
        case 33: "^"
        default: nil
        }
    }

    private static let commandShift: UInt64 = 0x10_0000 | 0x2_0000

    // MARK: - Les trois étages

    @Test("Une lettre est nommée par la disposition clavier, pas par son code")
    func lettersComeFromTheLayout() {
        let binding = HotkeyBinding(keyCode: 9, modifiers: Self.commandShift)
        #expect(binding.displayName(naming: Self.fakeLayout) == "⇧⌘V")
    }

    @Test("Un code que rien ne nomme retombe sur le code, laid mais jamais faux")
    func unknownKeysFallBackToTheirCode() {
        let binding = HotkeyBinding(keyCode: 200, modifiers: Self.commandShift)
        #expect(binding.displayName(naming: Self.fakeLayout) == "⇧⌘Touche 200")
    }

    /// **Le test qui fixe l'ordre.** Le code 19 produit « é » sur un clavier
    /// français ; la touche, elle, porte « 2 » gravé, et c'est « ⌘⇧2 » que les
    /// réglages affichent depuis que la capture de texte existe. La table doit
    /// donc l'emporter partout où elle parle.
    @Test("La table l'emporte sur la disposition pour les chiffres")
    func theTableWinsWhereItSpeaks() {
        let binding = HotkeyBinding(keyCode: 19, modifiers: Self.commandShift)
        #expect(binding.displayName(naming: Self.fakeLayout) == "⇧⌘2")
    }

    @Test("Une touche modificatrice seule garde son nom et perd ses symboles")
    func modifierOnlyKeepsItsName() {
        #expect(HotkeyBinding.rightCommand.displayName(naming: Self.fakeLayout) == "⌘ droite")
        #expect(HotkeyBinding.escape.displayName(naming: Self.fakeLayout) == "Échap")
    }

    // MARK: - Le raccourci du presse-papiers

    /// Le cas concret qui a révélé le trou. Le raccourci du presse-papiers est
    /// le premier raccourci par défaut posé sur une lettre — ⌘⇧V à l'origine,
    /// ⌘⇧C depuis que le propriétaire l'a tranché. Le test suit la constante et
    /// non la lettre : c'est la *lisibilité* qu'il garde, pas le choix.
    @Test("Le raccourci du presse-papiers s'affiche, et non « Touche 8 »")
    func clipboardPanelIsReadable() {
        #expect(HotkeyBinding.clipboardPanel.displayName(naming: Self.fakeLayout) == "⇧⌘C")
        // Et sur le vrai clavier de la machine, quelle qu'elle soit : on ne peut
        // pas prédire la lettre, on peut exiger qu'il y en ait une.
        #expect(HotkeyBinding.clipboardPanel.displayName.contains("Touche") == false)
    }

    // MARK: - Ce que la disposition refuse de nommer

    /// Échap et Entrée n'ont pas de gravure imprimable — mesuré : la traduction
    /// rend une chaîne vide ou un caractère de commande. La table les couvre, et
    /// c'est elle qui doit répondre.
    @Test("Les touches muettes ne sont jamais nommées par la disposition")
    func silentKeysAreNotNamedByTheLayout() {
        #expect(HotkeyBinding.layoutName(for: 53) == nil)  // Échap
        #expect(HotkeyBinding.layoutName(for: 36) == nil)  // Entrée
    }

    /// La disposition ne rend qu'un caractère unique et imprimable, ou rien.
    /// Vérifié sur le clavier réel : quelle qu'en soit la lettre, c'en est une.
    @Test("La disposition nomme la rangée des lettres")
    func theLayoutNamesLetterKeys() {
        for keyCode: UInt16 in [0, 1, 6, 7, 8, 9, 12, 13] {
            let name = HotkeyBinding.layoutName(for: keyCode)
            #expect(name?.count == 1)
        }
    }
}
