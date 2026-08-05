import Testing
@testable import BranVision

@Suite("Machine à états de la capture")
struct SnapshotMachineTests {

    @Test("Le parcours nominal avec un moteur déjà chaud saute le chargement")
    func parcoursAChaud() {
        var machine = SnapshotMachine()

        #expect(machine.handle(.triggered) == [.beginSelection])
        #expect(machine.phase == .selecting)

        #expect(machine.handle(.regionSelected(engineReady: true)) == [.recognise])
        #expect(machine.phase == .recognising)

        #expect(machine.handle(.recognised("texte")) == [.deliver("texte")])
        #expect(machine.phase == .copying)

        #expect(machine.handle(.copied).isEmpty)
        #expect(machine.phase == .idle)
    }

    @Test("À froid, le chargement du moteur devient visible")
    func parcoursAFroid() {
        var machine = SnapshotMachine()
        machine.handle(.triggered)

        #expect(machine.handle(.regionSelected(engineReady: false)) == [.prepareEngine])
        #expect(machine.phase == .preparing(nil))

        #expect(machine.handle(.engineProgress(0.4)).isEmpty)
        #expect(machine.phase == .preparing(0.4))

        #expect(machine.handle(.engineReady) == [.recognise])
        #expect(machine.phase == .recognising)
    }

    @Test("La progression est bornée entre zéro et un")
    func progressionBornee() {
        var machine = SnapshotMachine()
        machine.handle(.triggered)
        machine.handle(.regionSelected(engineReady: false))

        machine.handle(.engineProgress(-3))
        #expect(machine.phase == .preparing(0))
        machine.handle(.engineProgress(42))
        #expect(machine.phase == .preparing(1))
    }

    // MARK: - Annulation

    @Test("Annuler au viseur revient au repos sans rien annoncer")
    func annulationAuViseur() {
        var machine = SnapshotMachine()
        machine.handle(.triggered)

        // Pas d'effet : dire « annulé » à quelqu'un qui vient d'appuyer sur
        // Échap, c'est lui répéter ce qu'il vient de faire.
        #expect(machine.handle(.selectionCancelled).isEmpty)
        #expect(machine.phase == .idle)
    }

    @Test("Échap pendant le viseur équivaut à une annulation")
    func echapPendantViseur() {
        var machine = SnapshotMachine()
        machine.handle(.triggered)
        #expect(machine.handle(.cancelRequested).isEmpty)
        #expect(machine.phase == .idle)
    }

    @Test("Annuler pendant la reconnaissance jette le résultat à venir")
    func annulationPendantReconnaissance() {
        var machine = SnapshotMachine()
        machine.handle(.triggered)
        machine.handle(.regionSelected(engineReady: true))

        #expect(machine.handle(.cancelRequested) == [.discard])
        #expect(machine.phase == .idle)

        // Le résultat arrive après coup : il ne doit rien produire.
        #expect(machine.handle(.recognised("trop tard")).isEmpty)
        #expect(machine.phase == .idle)
    }

    @Test("Annuler pendant le chargement du moteur revient au repos")
    func annulationPendantChargement() {
        var machine = SnapshotMachine()
        machine.handle(.triggered)
        machine.handle(.regionSelected(engineReady: false))
        #expect(machine.handle(.cancelRequested) == [.discard])
        #expect(machine.phase == .idle)
    }

    // MARK: - Le piège du double appui

    @Test("Un second appui pendant le viseur ne relance pas de sélection")
    func doubleAppuiPendantViseur() {
        var machine = SnapshotMachine()
        machine.handle(.triggered)

        // Sans ce garde-fou, on lancerait un second processus `screencapture`
        // condamné à attendre une sélection qui n'arrivera jamais.
        #expect(machine.handle(.triggered).isEmpty)
        #expect(machine.phase == .selecting)
    }

    @Test("Un appui pendant la reconnaissance est ignoré")
    func appuiPendantReconnaissance() {
        var machine = SnapshotMachine()
        machine.handle(.triggered)
        machine.handle(.regionSelected(engineReady: true))
        #expect(machine.handle(.triggered).isEmpty)
        #expect(machine.phase == .recognising)
    }

    // MARK: - Zone sans texte

    @Test("Une zone sans texte le dit au lieu de copier du vide")
    func zoneSansTexte() {
        var machine = SnapshotMachine()
        machine.handle(.triggered)
        machine.handle(.regionSelected(engineReady: true))

        #expect(machine.handle(.recognisedNothing) == [.announceEmpty])
        #expect(machine.phase == .idle)
    }

    // MARK: - Échecs

    @Test("Un échec est atteignable depuis n'importe quel état")
    func echecDepuisPartout() {
        for setup in [
            [SnapshotMachine.Event.triggered],
            [.triggered, .regionSelected(engineReady: true)],
            [.triggered, .regionSelected(engineReady: false)],
        ] {
            var machine = SnapshotMachine()
            for event in setup { machine.handle(event) }
            #expect(machine.handle(.failed(.screenRecordingDenied)) == [.discard])
            #expect(machine.phase == .failed(.screenRecordingDenied))
        }
    }

    @Test("Après un échec, le raccourci relance une capture")
    func relanceApresEchec() {
        var machine = SnapshotMachine()
        machine.handle(.failed(.recognitionFailed("boum")))
        #expect(machine.handle(.triggered) == [.beginSelection])
        #expect(machine.phase == .selecting)
    }

    @Test("Un échec acquitté ramène au repos")
    func acquittement() {
        var machine = SnapshotMachine()
        machine.handle(.failed(.diskFull))
        machine.acknowledgeFailure()
        #expect(machine.phase == .idle)
    }

    @Test("Chaque échec dit quoi faire, pas seulement ce qui s'est passé")
    func chaqueEchecEstReparable() {
        let cas: [SnapshotFailure] = [
            .screenRecordingDenied,
            .accessibilityDenied,
            .selectionFailed("x"),
            .engineUnavailable("x"),
            .recognitionFailed("x"),
            .diskFull,
        ]
        for échec in cas {
            #expect(échec.summary.isEmpty == false)
            #expect(échec.remedy.isEmpty == false)
        }
    }

    // MARK: - Invariants d'affichage

    @Test("L'encoche se tait tant que macOS tient l'écran")
    func encocheMuettePendantViseur() {
        var machine = SnapshotMachine()
        machine.handle(.triggered)
        #expect(machine.phase.isSystemOwningScreen)

        machine.handle(.regionSelected(engineReady: true))
        #expect(machine.phase.isSystemOwningScreen == false)
    }

    @Test("isBusy couvre exactement les états en cours")
    func occupation() {
        #expect(SnapshotMachine.Phase.idle.isBusy == false)
        #expect(SnapshotMachine.Phase.failed(.diskFull).isBusy == false)
        #expect(SnapshotMachine.Phase.selecting.isBusy)
        #expect(SnapshotMachine.Phase.preparing(nil).isBusy)
        #expect(SnapshotMachine.Phase.recognising.isBusy)
        #expect(SnapshotMachine.Phase.copying.isBusy)
    }
}
