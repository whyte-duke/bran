import Testing
@testable import BranSpeech

/// Ces tests existent parce que la logique qu'ils couvrent était, jusqu'ici,
/// impossible à tester : elle vivait dans une vue SwiftUI, dans une cible
/// exécutable sans cible de test. Personne ne pouvait donc constater que
/// l'écran de la dictée ne détectait aucun conflit.
@Suite("Table des raccourcis globaux")
struct TriggerTableTests {

    private static let f1 = HotkeyBinding(keyCode: 122)
    private static let f2 = HotkeyBinding(keyCode: 120)
    private static let f3 = HotkeyBinding(keyCode: 99)

    // MARK: - Conflits

    @Test("Une touche libre n'a pas de détenteur")
    func freeBindingHasNoHolder() {
        let table = TriggerTable([.dictation: Self.f1, .snapshot: Self.f2])
        #expect(table.holder(of: Self.f3, excluding: .snapshot) == nil)
        #expect(table.conflicts(for: Self.f3, excluding: .snapshot).isEmpty)
    }

    @Test("La touche d'une autre fonction est signalée, et nommée")
    func takenBindingNamesItsHolder() {
        let table = TriggerTable([.dictation: Self.f1, .snapshot: Self.f2])
        #expect(table.holder(of: Self.f1, excluding: .snapshot) == .dictation)
        #expect(table.holder(of: Self.f2, excluding: .dictation) == .snapshot)
    }

    /// Le cas que l'ancien code interdisait sans le dire : garder sa propre
    /// touche n'est pas un conflit avec soi-même.
    @Test("Sa propre touche n'est pas un conflit")
    func ownBindingIsNotAConflict() {
        let table = TriggerTable([.dictation: Self.f1])
        #expect(table.holder(of: Self.f1, excluding: .dictation) == nil)
    }

    /// Une fonction absente de la table — désactivée, ou pas encore réglée —
    /// ne revendique rien.
    @Test("Une fonction sans touche ne bloque personne")
    func unboundTriggerBlocksNothing() {
        let table = TriggerTable([.dictation: Self.f1])
        #expect(table.holder(of: Self.f2, excluding: .dictation) == nil)
        #expect(table[.snapshot] == nil)
    }

    @Test("Le détenteur nommé est celui qui gagnerait l'arbitrage")
    func holderFollowsPriorityOrder() {
        // Un état que seule une modification manuelle des réglages produit :
        // deux fonctions sur la même touche. `HotkeyMonitor` déclenche la
        // première de `allCases` ; l'interface doit nommer celle-là, parce que
        // c'est celle dont l'utilisateur constate l'effet.
        let table = TriggerTable([.dictation: Self.f1, .snapshot: Self.f1])
        let first = GlobalTrigger.allCases.first { $0 != .snapshot }
        #expect(table.holder(of: Self.f1, excluding: .snapshot) == first)
    }

    // MARK: - Ordre de priorité

    @Test("Les liaisons sont rendues dans l'ordre de allCases, pas celui du dictionnaire")
    func assignedFollowsAllCases() {
        // Toutes les fonctions inscrites, dans un ordre de saisie qui n'est
        // celui d'aucune priorité : c'est la table qui doit les remettre en
        // ordre, pas l'appelant.
        let table = TriggerTable([.snapshot: Self.f2, .clipboard: Self.f3, .dictation: Self.f1])
        #expect(table.assigned.map(\.trigger) == GlobalTrigger.allCases)
    }

    /// L'ordre porte la priorité d'arbitrage : le réordonner changerait
    /// silencieusement quelle fonction gagne un raccourci partagé.
    @Test("L'ordre des cas existants est figé")
    func caseOrderIsFrozen() {
        #expect(Array(GlobalTrigger.allCases.prefix(2)) == [.dictation, .snapshot])
    }

    /// Un cas ajouté doit l'être **à la fin**. Le vérifier ici plutôt que dans
    /// la revue : la règle est écrite dans `GlobalTrigger`, et une règle écrite
    /// que rien ne constate se perd au troisième ajout.
    @Test("Le presse-papiers est en dernier")
    func clipboardComesLast() {
        #expect(GlobalTrigger.allCases.last == .clipboard)
    }

    @Test("Chaque déclencheur a ses trois formes de nom, toutes non vides")
    func everyTriggerIsNamed() {
        for trigger in GlobalTrigger.allCases {
            #expect(trigger.label.isEmpty == false)
            #expect(trigger.definiteName.isEmpty == false)
            #expect(trigger.possessiveName.isEmpty == false)
        }
    }

    /// **Le seul test de grammaire du programme, et il a une raison d'être.**
    /// Les trois formes sont écrites à la main précisément parce qu'une
    /// dérivation depuis `definiteName` produirait « de le presse-papiers ».
    /// Le presse-papiers est le premier déclencheur masculin : si la
    /// dérivation revenait un jour par la petite porte, c'est ce cas-là qu'elle
    /// casserait, et la phrase de `GlobalTriggerRow` deviendrait fausse.
    @Test("Le complément du nom contracte « de le » en « du »")
    func masculineTriggerContractsItsArticle() {
        #expect(GlobalTrigger.clipboard.definiteName == "le presse-papiers")
        #expect(GlobalTrigger.clipboard.possessiveName == "du presse-papiers")

        // Et les deux féminines ne contractent pas.
        #expect(GlobalTrigger.dictation.possessiveName.hasPrefix("de la"))
        #expect(GlobalTrigger.snapshot.possessiveName.hasPrefix("de la"))
    }

    /// Ce que la table fait pour une fonction dont l'écran n'existe pas encore.
    /// Elle n'a rien de particulier à faire, et c'est le résultat attendu : le
    /// presse-papiers se dispute une touche comme les deux autres, et s'échange
    /// comme elles.
    @Test("Le presse-papiers entre dans les conflits et dans l'échange")
    func clipboardTakesPartInArbitration() {
        let table = TriggerTable([.dictation: Self.f1, .clipboard: Self.f2])
        #expect(table.holder(of: Self.f2, excluding: .dictation) == .clipboard)

        let swapped = table.exchanging(.dictation, to: Self.f2)
        #expect(swapped[.dictation] == Self.f2)
        #expect(swapped[.clipboard] == Self.f1)
    }

    // MARK: - Échange

    @Test("L'échange rend au détenteur la touche libérée")
    func exchangeSwapsBothWays() {
        let table = TriggerTable([.dictation: Self.f1, .snapshot: Self.f2])
        let next = table.exchanging(.snapshot, to: Self.f1)

        #expect(next[.snapshot] == Self.f1)
        #expect(next[.dictation] == Self.f2)
    }

    @Test("Un échange laisse la table sans conflit")
    func exchangeLeavesNoConflict() {
        let table = TriggerTable([.dictation: Self.f1, .snapshot: Self.f2])
        let next = table.exchanging(.snapshot, to: Self.f1)

        for entry in next.assigned {
            #expect(next.conflicts(for: entry.binding, excluding: entry.trigger).isEmpty)
        }
    }

    @Test("Sur une touche libre, l'échange est une simple affectation")
    func exchangeOnFreeBindingIsAnAssignment() {
        let table = TriggerTable([.dictation: Self.f1, .snapshot: Self.f2])
        let next = table.exchanging(.snapshot, to: Self.f3)

        #expect(next[.snapshot] == Self.f3)
        #expect(next[.dictation] == Self.f1)
    }

    /// Sinon l'ancien détenteur garderait la touche qu'on vient de lui prendre,
    /// et le conflit renaîtrait de l'échange censé le résoudre.
    @Test("Un demandeur sans touche laisse l'ancien détenteur sans touche")
    func exchangeFromUnboundTriggerClearsTheHolder() {
        let table = TriggerTable([.dictation: Self.f1])
        let next = table.exchanging(.snapshot, to: Self.f1)

        #expect(next[.snapshot] == Self.f1)
        #expect(next[.dictation] == nil)
    }

    // MARK: - Ce qu'un changement de table libère

    /// Le défaut d'origine : la touche de la dictée change pendant qu'elle est
    /// tenue, le `keyUp` de l'ancienne touche n'est plus surveillé, et sans ce
    /// calcul personne ne relâche jamais la dictée.
    @Test("Une fonction tenue dont la touche change est à relâcher")
    func rebindingAHeldTriggerReleasesIt() {
        let before = TriggerTable([.dictation: Self.f1, .snapshot: Self.f2])
        let after = before.exchanging(.dictation, to: Self.f3)

        #expect(after.triggersLosingTheirKey(since: before, among: [.dictation]) == [.dictation])
    }

    /// Le cas que l'ancien code traitait — et le seul.
    @Test("Une fonction tenue qui perd sa touche est à relâcher")
    func unbindingAHeldTriggerReleasesIt() {
        let before = TriggerTable([.dictation: Self.f1])
        var after = before
        after[.dictation] = nil

        #expect(after.triggersLosingTheirKey(since: before, among: [.dictation]) == [.dictation])
    }

    /// Sinon rebrancher la capture de texte couperait la dictée en cours.
    @Test("Rebrancher une autre fonction ne relâche pas celle qui est tenue")
    func rebindingAnotherTriggerLeavesTheHeldOneAlone() {
        let before = TriggerTable([.dictation: Self.f1, .snapshot: Self.f2])
        let after = before.exchanging(.snapshot, to: Self.f3)

        #expect(after.triggersLosingTheirKey(since: before, among: [.dictation]).isEmpty)
    }

    @Test("Une fonction qui n'est pas tenue n'est jamais à relâcher")
    func anUnheldTriggerIsNeverReleased() {
        let before = TriggerTable([.dictation: Self.f1])
        var after = before
        after[.dictation] = Self.f2

        #expect(after.triggersLosingTheirKey(since: before, among: []).isEmpty)
    }

    /// Le choix documenté : on compare la liaison entière, pas le seul code de
    /// touche. Un relâchement en avance ne coûte rien ; une capture qui ne
    /// s'arrête plus coûte une dictée.
    @Test("Un changement de modificateurs seul relâche quand même")
    func changingOnlyTheModifiersStillReleases() {
        let plain = HotkeyBinding(keyCode: 19, modifiers: 0x12_0000)
        let other = HotkeyBinding(keyCode: 19, modifiers: 0x6_0000)
        let before = TriggerTable([.dictation: plain])
        var after = before
        after[.dictation] = other

        #expect(after.triggersLosingTheirKey(since: before, among: [.dictation]) == [.dictation])
    }

    @Test("Deux fonctions libérées d'un coup le sont dans l'ordre de allCases")
    func releasesFollowPriorityOrder() {
        let before = TriggerTable([.dictation: Self.f1, .snapshot: Self.f2])
        var after = before
        after[.dictation] = Self.f3
        after[.snapshot] = nil

        let released = after.triggersLosingTheirKey(since: before, among: [.snapshot, .dictation])
        #expect(released == GlobalTrigger.allCases.filter { released.contains($0) })
        #expect(released == [.dictation, .snapshot])
    }

    /// Une table inchangée ne libère rien : le calcul ne doit pas transformer
    /// une simple réécriture des réglages en relâchement fantôme.
    @Test("Une table réécrite à l'identique ne relâche personne")
    func anUnchangedTableReleasesNobody() {
        let table = TriggerTable([.dictation: Self.f1, .snapshot: Self.f2])
        #expect(table.triggersLosingTheirKey(since: table, among: [.dictation, .snapshot]).isEmpty)
    }

    // MARK: - Ce que le guet en tire

    @Test("Les codes surveillés couvrent toutes les liaisons, sans doublon")
    func keyCodesCoverEveryBinding() {
        let table = TriggerTable([.dictation: Self.f1, .snapshot: Self.f1])
        #expect(table.keyCodes == [Self.f1.keyCode])
    }

    /// Régler une fonction sur Échap doit désarmer Échap comme geste
    /// d'abandon : sinon annuler et déclencher deviennent indiscernables.
    @Test("Une touche revendiquée est reconnue comme prise")
    func isTakenSeesEveryBinding() {
        let table = TriggerTable([.dictation: .escape])
        #expect(table.isTaken(.escape))
        #expect(table.isTaken(Self.f1) == false)
    }

    // MARK: - Remise à l'heure du masque de modificateurs

    /// Les valeurs de cette section ne sont pas choisies : ce sont celles que le
    /// système rend réellement, relevées sur macOS 26.5 avec une sonde jetable
    /// qui postait des `flagsChanged` au niveau pilote et lisait
    /// `CGEventSource.flagsState(.hidSystemState)`.
    private enum Measured {
        /// ⌘ droite tenue : `maskCommand`, `nonCoalesced`, et `0x10`, le bit
        /// périphérique de ⌘ droite.
        static let rightCommandHeld: UInt64 = 0x0000_0000_2010_0110
        /// L'état juste après le ⌘V que `Paster` synthétise : `maskCommand`
        /// **et aucun bit périphérique**. Il dure jusqu'au prochain événement,
        /// mesuré à plus de quinze secondes.
        static let afterSyntheticCommandV: UInt64 = 0x0000_0000_2010_0000
    }

    private static let rightCommand = HotkeyBinding.rightCommand
    private static let rightCommandBit: UInt64 = 0x10

    /// Le cas nominal : rien n'est tenu, on prend l'état du système tel quel.
    @Test("Sans fonction tenue, l'état du système est repris sans retouche")
    func nothingHeldKeepsTheSystemReadingIntact() {
        let table = TriggerTable([.dictation: Self.rightCommand])
        #expect(table.resyncedFlags(from: Measured.rightCommandHeld, held: []) == Measured.rightCommandHeld)
        #expect(table.resyncedFlags(from: 0, held: []) == 0)
    }

    /// **Le défaut que tout ceci existe pour empêcher.** Le ⌘V synthétique de
    /// bran efface le bit périphérique de la touche que l'utilisateur tient
    /// vraiment. Reprendre cet état pendant une dictée en mode « maintenir »
    /// noterait ⌘ droite relâchée, et le vrai relâchement ne changerait plus
    /// rien : la capture ne s'arrêterait jamais.
    @Test("Le ⌘V synthétique n'efface pas le bit d'une fonction tenue")
    func aSyntheticPasteCannotClearAHeldTrigger() {
        let table = TriggerTable([.dictation: Self.rightCommand])
        let flags = table.resyncedFlags(from: Measured.afterSyntheticCommandV, held: [.dictation])
        #expect(flags & Self.rightCommandBit != 0)
        // Et rien de ce que le système rapportait n'est perdu au passage.
        #expect(flags & Measured.afterSyntheticCommandV == Measured.afterSyntheticCommandV)
    }

    /// L'autre sens : le système peut *ajouter* un appui. C'est le modificateur
    /// réellement tenu pendant qu'on règle ses raccourcis, et le pire qu'il
    /// produise est un `.triggerUp` au relâchement suivant — jamais une capture
    /// qui ne s'arrête plus.
    @Test("Le système peut ajouter un appui que le guet ignorait")
    func theSystemMayAddAPressTheMonitorDidNotKnow() {
        let table = TriggerTable([.dictation: Self.rightCommand])
        let flags = table.resyncedFlags(from: Measured.rightCommandHeld, held: [])
        #expect(flags & Self.rightCommandBit != 0)
    }

    /// Une fonction tenue sur une touche normale n'est pas protégée : son
    /// relâchement arrive en `keyUp`, qui ne se perd pas dans un masque.
    @Test("Une fonction à touche normale ne force aucun bit")
    func aRegularKeyForcesNothing() {
        let table = TriggerTable([.snapshot: HotkeyBinding(keyCode: 19, modifiers: 0x12_0000)])
        #expect(table.resyncedFlags(from: 0, held: [.snapshot]) == 0)
    }

    /// Une fonction tenue mais absente de la table — elle vient de perdre sa
    /// touche — ne force rien. C'est ce qui rend l'ordre du `didSet` de
    /// `HotkeyMonitor.bindings` sûr : relâcher d'abord, remettre à l'heure
    /// ensuite.
    @Test("Une fonction sans touche ne force aucun bit")
    func anUnboundTriggerForcesNothing() {
        let table = TriggerTable()
        #expect(table.resyncedFlags(from: 0, held: [.dictation, .snapshot]) == 0)
    }

    /// Deux modificateurs tenus en même temps gardent chacun le sien.
    @Test("Deux fonctions tenues gardent chacune son bit")
    func twoHeldTriggersKeepBothBits() {
        let leftShift = HotkeyBinding(keyCode: 56, isModifierOnly: true)
        let table = TriggerTable([.dictation: Self.rightCommand, .snapshot: leftShift])
        let flags = table.resyncedFlags(from: 0, held: [.dictation, .snapshot])
        #expect(flags == Self.rightCommandBit | leftShift.deviceModifierBit)
    }

    /// La table des bits périphériques : chaque touche modificatrice a le sien,
    /// tous distincts, et rien d'autre n'en a.
    @Test("Chaque touche modificatrice a un bit périphérique unique")
    func everyModifierKeyHasItsOwnBit() {
        let codes: [UInt16] = [54, 55, 56, 60, 58, 61, 59, 62]
        let bits = codes.map { HotkeyBinding(keyCode: $0, isModifierOnly: true).deviceModifierBit }
        #expect(bits.allSatisfy { $0 != 0 })
        #expect(Set(bits).count == codes.count)
        #expect(HotkeyBinding.escape.deviceModifierBit == 0)
        #expect(HotkeyBinding(keyCode: 19).deviceModifierBit == 0)
    }

    /// Le bit de ⌘ droite est celui qu'on a mesuré dans l'état du système, pas
    /// une valeur recopiée d'une documentation.
    @Test("Le bit de ⌘ droite est celui que le système rapporte")
    func rightCommandBitMatchesTheSystemReading() {
        #expect(HotkeyBinding.rightCommand.deviceModifierBit == Self.rightCommandBit)
        #expect(Measured.rightCommandHeld & Self.rightCommandBit != 0)
        #expect(Measured.afterSyntheticCommandV & Self.rightCommandBit == 0)
    }
}
