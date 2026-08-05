import Testing
@testable import BranSpeech

@Suite("Machine à états de la dictée")
struct DictationMachineTests {

    // MARK: - Chemin nominal

    @Test("Bascule : appui démarre, second appui transcrit, collage revient au repos")
    func toggleRoundTrip() {
        var machine = DictationMachine(trigger: .toggle)

        #expect(machine.handle(.hotkeyDown) == [.startCapture])
        #expect(machine.phase == .capturing)

        #expect(machine.handle(.hotkeyDown) == [.finishCaptureAndTranscribe])
        #expect(machine.phase == .transcribing)

        #expect(machine.handle(.transcribed("bonjour")) == [.paste("bonjour")])
        #expect(machine.phase == .pasting)

        #expect(machine.handle(.pasted).isEmpty)
        #expect(machine.phase == .idle)
    }

    @Test("Maintien : le relâchement transcrit")
    func holdRoundTrip() {
        var machine = DictationMachine(trigger: .hold)

        machine.handle(.hotkeyDown)
        #expect(machine.handle(.hotkeyUp) == [.finishCaptureAndTranscribe])
        #expect(machine.phase == .transcribing)
    }

    /// Le système répète `keyDown` tant qu'une touche reste enfoncée. En mode
    /// maintien, traiter cette répétition comme un arrêt couperait la dictée au
    /// bout d'une demi-seconde — le bug le plus facile à écrire ici.
    @Test("Maintien : les appuis répétés ne coupent pas la capture")
    func holdIgnoresKeyRepeat() {
        var machine = DictationMachine(trigger: .hold)
        machine.handle(.hotkeyDown)

        for _ in 0..<5 {
            #expect(machine.handle(.hotkeyDown).isEmpty)
            #expect(machine.phase == .capturing)
        }
    }

    /// Symétrique : en bascule, un relâchement ne doit rien faire, sinon le
    /// premier appui démarrerait et s'arrêterait aussitôt.
    @Test("Bascule : le relâchement est sans effet")
    func toggleIgnoresKeyUp() {
        var machine = DictationMachine(trigger: .toggle)
        machine.handle(.hotkeyDown)

        #expect(machine.handle(.hotkeyUp).isEmpty)
        #expect(machine.phase == .capturing)
    }

    // MARK: - Annulation

    @Test("Échap pendant la capture jette l'audio sans rien coller")
    func cancelWhileCapturing() {
        var machine = DictationMachine()
        machine.handle(.hotkeyDown)

        #expect(machine.handle(.cancelRequested) == [.discardCapture])
        #expect(machine.phase == .idle)
    }

    @Test("Échap pendant la transcription n'aboutit à aucun collage")
    func cancelWhileTranscribing() {
        var machine = DictationMachine()
        machine.handle(.hotkeyDown)
        machine.handle(.hotkeyDown)

        #expect(machine.handle(.cancelRequested) == [.discardCapture])
        #expect(machine.phase == .idle)

        // Le calcul continue en arrière-plan : son résultat arrive après coup et
        // doit être ignoré, pas collé dans le document où l'utilisateur a repris
        // sa saisie.
        #expect(machine.handle(.transcribed("trop tard")).isEmpty)
        #expect(machine.phase == .idle)
    }

    @Test("Échap au repos ne fait rien")
    func cancelWhenIdle() {
        var machine = DictationMachine()
        #expect(machine.handle(.cancelRequested).isEmpty)
        #expect(machine.phase == .idle)
    }

    // MARK: - Silence et plafond

    @Test("Une transcription vide ne colle rien et ne crée pas d'entrée")
    func emptyTranscriptionPastesNothing() {
        var machine = DictationMachine()
        machine.handle(.hotkeyDown)
        machine.handle(.hotkeyDown)

        #expect(machine.handle(.transcribedNothing) == [.announceEmpty])
        #expect(machine.phase == .idle)
    }

    @Test("Le plafond de durée arrête la capture mais transcrit quand même")
    func durationCapStillTranscribes() {
        var machine = DictationMachine()
        machine.handle(.hotkeyDown)

        #expect(machine.handle(.durationCapReached) == [.finishCaptureAndTranscribe])
        #expect(machine.phase == .transcribing)
    }

    // MARK: - Échecs

    @Test("Un échec pendant la capture jette l'audio")
    func failureDuringCaptureDiscards() {
        var machine = DictationMachine()
        machine.handle(.hotkeyDown)

        #expect(machine.handle(.failed(.diskFull)) == [.discardCapture])
        #expect(machine.phase == .failed(.diskFull))
    }

    @Test("Un échec hors capture ne jette rien")
    func failureOutsideCaptureDiscardsNothing() {
        var machine = DictationMachine()
        machine.handle(.hotkeyDown)
        machine.handle(.hotkeyDown)

        #expect(machine.handle(.failed(.transcriptionFailed("modèle absent"))).isEmpty)
    }

    @Test("Le raccourci redémarre une dictée depuis un état d'échec")
    func hotkeyRecoversFromFailure() {
        var machine = DictationMachine()
        machine.handle(.failed(.microphoneDenied))

        #expect(machine.handle(.hotkeyDown) == [.startCapture])
        #expect(machine.phase == .capturing)
    }

    @Test("Accuser réception d'un échec revient au repos")
    func acknowledgeFailure() {
        var machine = DictationMachine()
        machine.handle(.failed(.microphoneDenied))
        machine.acknowledgeFailure()
        #expect(machine.phase == .idle)
    }

    @Test("Accuser réception n'a aucun effet hors état d'échec")
    func acknowledgeIsHarmlessOtherwise() {
        var machine = DictationMachine()
        machine.handle(.hotkeyDown)
        machine.acknowledgeFailure()
        #expect(machine.phase == .capturing)
    }

    // MARK: - Robustesse

    @Test("Un texte arrivé alors qu'on ne transcrit pas est ignoré")
    func strayTranscriptionIsIgnored() {
        var machine = DictationMachine()
        #expect(machine.handle(.transcribed("perdu")).isEmpty)
        #expect(machine.phase == .idle)
    }

    @Test("Chaque échec porte un message et une réparation")
    func everyFailureExplainsItself() {
        let failures: [DictationFailure] = [
            .microphoneDenied,
            .accessibilityDenied,
            .secureInputActive(app: "Terminal"),
            .secureInputActive(app: nil),
            .modelUnavailable("hors ligne"),
            .captureFailed("périphérique absent"),
            .transcriptionFailed("erreur CoreML"),
            .diskFull,
        ]

        for failure in failures {
            #expect(failure.summary.isEmpty == false)
            #expect(failure.remedy.isEmpty == false)
        }
    }

    @Test("La saisie sécurisée nomme l'application coupable quand on la connaît")
    func secureInputNamesTheCulprit() {
        #expect(DictationFailure.secureInputActive(app: "Terminal").summary.contains("Terminal"))
    }
}
