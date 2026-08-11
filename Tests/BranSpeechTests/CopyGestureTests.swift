import Testing
@testable import BranSpeech

/// L'indice de copie, jugé sans clavier ni autorisation.
///
/// Cette logique-ci a toutes les raisons de finir dans le callback du
/// `CGEventTap` — c'est là qu'elle s'exécute — et aucune d'y être écrite : un
/// tap demande l'Accessibilité, une frappe réelle, et ne se rejoue pas. Le
/// callback ne garde donc que la lecture de l'événement ; ce qu'on en conclut
/// est ici.
@Suite("Le geste de copie")
struct CopyGestureTests {

    /// Les masques `CGEventFlags`, en clair. Recopiés plutôt qu'importés :
    /// `BranSpeech` ne dépend pas de CoreGraphics, et c'est ce qui permet à ces
    /// tests de tourner en millisecondes.
    private enum Mask {
        static let command: UInt64 = 0x10_0000
        static let shift: UInt64 = 0x2_0000
        static let option: UInt64 = 0x8_0000
        static let control: UInt64 = 0x4_0000
        static let capsLock: UInt64 = 0x1_0000
    }

    private static let c: UInt16 = 8
    private static let x: UInt16 = 7
    private static let v: UInt16 = 9

    @Test("⌘C et ⌘X sont des copies")
    func plainCopyAndCut() {
        #expect(CopyGesture.matches(keyCode: Self.c, flags: Mask.command))
        #expect(CopyGesture.matches(keyCode: Self.x, flags: Mask.command))
    }

    /// **Le test est « contient Commande », pas « égale Commande ».** ⌘⌥C copie
    /// le chemin dans le Finder, ⌘⇧C le nom du fichier ; toutes deux écrivent
    /// dans le presse-papiers. Une égalité stricte — celle qu'exige un
    /// raccourci, à raison — les laisserait passer sans indice.
    @Test("Les copies à modificateurs supplémentaires comptent aussi")
    func extraModifiersStillCopy() {
        #expect(CopyGesture.matches(keyCode: Self.c, flags: Mask.command | Mask.option))
        #expect(CopyGesture.matches(keyCode: Self.c, flags: Mask.command | Mask.shift))
        #expect(
            CopyGesture.matches(
                keyCode: Self.c,
                flags: Mask.command | Mask.shift | Mask.option
            )
        )
        // Le verrouillage majuscule pollue le masque sans rien vouloir dire.
        #expect(CopyGesture.matches(keyCode: Self.c, flags: Mask.command | Mask.capsLock))
    }

    /// La raison d'être du test de modificateur : sans lui, écrire de la prose
    /// produirait un indice par « c ». Ce n'est pas qu'une dépense — chaque
    /// indice fait relever le presse-papiers.
    @Test("Une lettre nue n'est pas une copie")
    func bareLetterIsNotACopy() {
        #expect(CopyGesture.matches(keyCode: Self.c, flags: 0) == false)
        #expect(CopyGesture.matches(keyCode: Self.x, flags: 0) == false)
        #expect(CopyGesture.matches(keyCode: Self.c, flags: Mask.shift) == false)
        #expect(CopyGesture.matches(keyCode: Self.c, flags: Mask.control) == false)
        // ⌃C interrompt un programme dans un terminal ; il ne copie rien.
        #expect(CopyGesture.matches(keyCode: Self.x, flags: Mask.control) == false)
    }

    /// Coller ne change pas le presse-papiers, donc ni ⌘V ni ⌘⇧V ne sont des
    /// copies.
    @Test("Coller n'est pas copier")
    func pasteIsNotACopy() {
        #expect(CopyGesture.matches(keyCode: Self.v, flags: Mask.command) == false)
        #expect(CopyGesture.matches(keyCode: Self.v, flags: Mask.command | Mask.shift) == false)
    }

    /// **Le raccourci du panneau est ⌘⇧C, donc il est AUSSI un indice de copie
    /// — et c'est voulu.**
    ///
    /// Le propriétaire a choisi ⌘⇧C contre l'avis de la conception. La
    /// conséquence est que la même frappe porte deux sens : elle ouvre le
    /// panneau de bran, et dans beaucoup d'applications elle copie une variante
    /// — le Finder en copie le chemin. Les deux doivent partir.
    ///
    /// `HotkeyMonitor.WatchedKeys` sépare exprès les touches « réclamées » des
    /// touches « indice » au lieu de les fondre, précisément pour qu'une même
    /// touche puisse porter les deux droits. Ce test gèle le fait que l'indice
    /// n'a pas été perdu en chemin : le manquer voudrait dire qu'un ⌘⇧C dans le
    /// Finder copie un chemin que l'historique ne verrait jamais.
    @Test("⌘⇧C ouvre le panneau ET s'annonce comme une copie")
    func panelShortcutIsAlsoACopy() {
        #expect(HotkeyBinding.clipboardPanel.keyCode == Self.c)
        #expect(CopyGesture.matches(keyCode: Self.c, flags: Mask.command | Mask.shift))
    }

    /// Ces deux codes sont ce que `HotkeyMonitor.refreshWatchedKeys` insère dans
    /// le filtre du callback. Les figer ici : une faute de frappe y serait
    /// invisible — le presse-papiers ne verrait simplement plus aucune copie,
    /// sans erreur ni journal.
    @Test("Les touches observées sont C et X, et rien d'autre")
    func watchedKeyCodes() {
        #expect(CopyGesture.keyCodes == [8, 7])
        #expect(CopyGesture.keyCodes.contains(Self.v) == false)
    }

    /// Un code de touche quelconque avec Commande n'est pas une copie : le
    /// filtre porte d'abord sur la touche.
    @Test("Commande seule ne suffit pas")
    func commandAloneIsNotACopy() {
        for keyCode in UInt16(0)...UInt16(60) where CopyGesture.keyCodes.contains(keyCode) == false {
            #expect(CopyGesture.matches(keyCode: keyCode, flags: Mask.command) == false)
        }
    }
}
