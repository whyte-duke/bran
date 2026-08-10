import Testing
@testable import BranSpeech

/// La règle « un appui, un signal », vérifiée là où elle vit.
///
/// Elle vivait dans `HotkeyMonitor.classify`, dans une cible exécutable adossée
/// à un `CGEventTap` : rien ne pouvait constater que la branche des touches
/// normales réémettait `.triggerDown` à chaque répétition du système, pendant
/// que la branche des modificateurs, elle, comptait juste.
@Suite("Touches tenues")
struct HeldTriggersTests {

    @Test("Un premier appui est un appui")
    func firstPressIsNew() {
        var held = HeldTriggers()
        #expect(held.press(.dictation) == true)
        #expect(held.contains(.dictation))
    }

    /// Le défaut : macOS répète les `keyDown` tant que la touche est tenue.
    @Test("La répétition d'un appui n'en est pas un second")
    func repeatedPressIsNotANewPress() {
        var held = HeldTriggers()
        _ = held.press(.dictation)
        #expect(held.press(.dictation) == false)
        #expect(held.press(.dictation) == false)
        #expect(held.triggers == [.dictation])
    }

    @Test("Le relâchement d'une touche tenue est un relâchement")
    func releaseOfHeldTriggerCounts() {
        var held = HeldTriggers()
        _ = held.press(.snapshot)
        #expect(held.release(.snapshot) == true)
        #expect(held.contains(.snapshot) == false)
    }

    /// Le pendant du précédent : un `keyUp` dont on n'a pas vu le `keyDown` —
    /// la touche a été enfoncée avant que la fonction soit branchée, ou son
    /// appui a déjà été rendu par un changement de réglage.
    @Test("Le relâchement de ce qu'on ne tient pas ne s'annonce pas")
    func releaseOfUnheldTriggerIsSilent() {
        var held = HeldTriggers()
        #expect(held.release(.dictation) == false)
        _ = held.press(.dictation)
        _ = held.release(.dictation)
        #expect(held.release(.dictation) == false)
    }

    /// Le cas qui a fait choisir un ensemble plutôt qu'un booléen : maintenir
    /// Command droite pour dicter pendant qu'un autre raccourci va et vient.
    @Test("Deux fonctions se tiennent indépendamment")
    func triggersAreIndependent() {
        var held = HeldTriggers()
        #expect(held.press(.dictation) == true)
        #expect(held.press(.snapshot) == true)
        #expect(held.release(.snapshot) == true)
        #expect(held.contains(.dictation))
        #expect(held.press(.dictation) == false)
    }

    @Test("Un appui rendu peut être repris")
    func pressAgainAfterRelease() {
        var held = HeldTriggers()
        _ = held.press(.dictation)
        _ = held.release(.dictation)
        #expect(held.press(.dictation) == true)
    }

    @Test("Le retrait en lot ne conclut rien")
    func subtractForgetsWithoutSignalling() {
        var held = HeldTriggers([.dictation, .snapshot])
        held.subtract([.dictation])
        #expect(held.triggers == [.snapshot])
        // Retiré, donc son appui est à reprendre de zéro.
        #expect(held.press(.dictation) == true)
    }

    @Test("Tout oublier vide l'ensemble")
    func releaseEverythingEmpties() {
        var held = HeldTriggers([.dictation, .snapshot])
        held.releaseEverything()
        #expect(held.isEmpty)
        #expect(held.triggers.isEmpty)
    }

    /// `TriggerTable` raisonne sur l'ensemble nu : les deux doivent rester
    /// d'accord, sinon la remise à l'heure du masque protégerait les bits des
    /// mauvaises fonctions.
    @Test("L'ensemble nu est celui que la table reçoit")
    func rawSetFeedsTheTable() {
        var held = HeldTriggers()
        _ = held.press(.dictation)
        let table = TriggerTable([.dictation: .rightCommand])
        let flags = table.resyncedFlags(from: 0, held: held.triggers)
        #expect(flags == HotkeyBinding.rightCommand.deviceModifierBit)
    }
}
