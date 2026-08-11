import Foundation
import Testing
@testable import BranCore

@Suite("FinalizationWatch")
struct FinalizationWatchTests {

    /// Le scénario mesuré le 11 août 2026, rejoué à la seconde près.
    ///
    /// Réunion de 2 191 s. `stopCapture()` rend la main, puis `replayd` écrit
    /// pendant 729 s — le fichier passe de 180 Mo à 2,56 Go — avant d'annoncer
    /// la fin. L'ancienne échéance de 60 s abandonnait à la 60ᵉ seconde, alors
    /// que le fichier grossissait de plusieurs mégaoctets par seconde.
    @Test("Douze minutes d'écriture continue : on attend, et on obtient le fichier")
    func waitsThroughTheRealWorldFinalization() {
        var watch = FinalizationWatch(recorded: .seconds(2_191))

        // Une sonde par seconde pendant 729 s, le fichier grossit tout du long.
        var verdict = FinalizationWatch.Verdict.keepWaiting(bytesWritten: 0, silentFor: .zero)
        for second in 0...729 {
            let bytes = 180_000_000 + Int64(second) * 3_260_000
            verdict = watch.observe(bytesWritten: bytes, didFinish: false, at: .seconds(second))
            #expect(verdict.isSettled == false, "abandon à la \(second)ᵉ seconde alors que le fichier grossit")
        }

        verdict = watch.observe(bytesWritten: 2_556_202_758, didFinish: true, at: .seconds(730))
        #expect(verdict == .finished(bytesWritten: 2_556_202_758))
    }

    /// Le cas que l'ancienne échéance attrapait correctement, et qu'il ne faut
    /// pas perdre : quand plus rien n'arrive, il faut le dire.
    @Test("Plus rien d'écrit pendant deux minutes → abandon, avec le poids écrit")
    func stallsOnSilence() {
        var watch = FinalizationWatch(recorded: .seconds(600))

        #expect(watch.observe(bytesWritten: 900, didFinish: false, at: .seconds(0)).isSettled == false)
        #expect(watch.observe(bytesWritten: 900, didFinish: false, at: .seconds(119)).isSettled == false)

        let verdict = watch.observe(bytesWritten: 900, didFinish: false, at: .seconds(120))
        #expect(verdict == .stalled(bytesWritten: 900, silentFor: .seconds(120)))
    }

    /// Une écriture par blocs : la taille ne bouge pas pendant une minute et
    /// demie, puis repart. C'est le fonctionnement normal d'un vidage de
    /// tampon, et ce n'est pas un échec.
    @Test("Un silence qui reprend avant l'échéance remet le compteur à zéro")
    func growthResetsTheSilence() {
        var watch = FinalizationWatch(recorded: .seconds(600))

        _ = watch.observe(bytesWritten: 1_000, didFinish: false, at: .seconds(0))
        _ = watch.observe(bytesWritten: 1_000, didFinish: false, at: .seconds(90))

        let resumed = watch.observe(bytesWritten: 2_000, didFinish: false, at: .seconds(100))
        #expect(resumed == .keepWaiting(bytesWritten: 2_000, silentFor: .zero))

        // 130 s après le dernier relevé identique, mais seulement 30 s après la
        // reprise : rien à signaler.
        let later = watch.observe(bytesWritten: 2_000, didFinish: false, at: .seconds(130))
        #expect(later.isSettled == false)
    }

    /// Le premier relevé arme la montre. Sans ça, une première sonde à la
    /// 200ᵉ seconde d'horloge monotone déclencherait un abandon immédiat.
    @Test("Le premier relevé arme la montre, il ne consomme pas le délai")
    func firstObservationArmsTheClock() {
        var watch = FinalizationWatch(recorded: .seconds(600))

        let first = watch.observe(bytesWritten: 500, didFinish: false, at: .seconds(9_999))
        #expect(first == .keepWaiting(bytesWritten: 500, silentFor: .zero))
    }

    /// La fin déclarée l'emporte sur tout, y compris sur un silence qui vient
    /// d'atteindre l'échéance dans le même coup de sonde : un fichier clos est
    /// un fichier clos.
    @Test("La fin annoncée l'emporte sur le silence")
    func finishBeatsSilence() {
        var watch = FinalizationWatch(recorded: .seconds(600))

        _ = watch.observe(bytesWritten: 42, didFinish: false, at: .seconds(0))
        let verdict = watch.observe(bytesWritten: 42, didFinish: true, at: .seconds(300))

        #expect(verdict == .finished(bytesWritten: 42))
    }

    /// `CaptureDelegate.markFailed` coche `didFinish` en même temps que le
    /// motif, pour débloquer l'attente. Lire la fin en premier ferait donc
    /// passer une panne de ScreenCaptureKit pour un fichier bien clos — et la
    /// réunion serait horodatée comme complète.
    @Test("Une panne rapportée l'emporte sur la fin qu'elle a elle-même cochée")
    func reportedFailureBeatsItsOwnFinishFlag() {
        var watch = FinalizationWatch(recorded: .seconds(600))

        let verdict = watch.observe(
            bytesWritten: 1_500,
            didFinish: true,
            failure: "flux de capture interrompu",
            at: .seconds(0)
        )

        #expect(verdict == .failed(bytesWritten: 1_500, reason: "flux de capture interrompu"))
        #expect(verdict.isSettled)
    }

    /// Un motif d'échec qui ne dit pas le poids écrit laisse croire à une perte
    /// sèche. C'est exactement ce qui s'est passé le 11 août : « finalisation
    /// impossible : finalizationTimedOut » pendant que 2,5 Go arrivaient.
    @Test("Chaque motif d'échec dit combien d'octets sont sur le disque")
    func failureReasonsAlwaysNameTheBytes() {
        let format: (Int64) -> String = { "\($0) o" }

        #expect(FinalizationWatch.Verdict.finished(bytesWritten: 1).failureReason(formattedBytes: format) == nil)

        let stalled = FinalizationWatch.Verdict
            .stalled(bytesWritten: 2_556_202_758, silentFor: .seconds(120))
            .failureReason(formattedBytes: format)
        #expect(stalled?.contains("2556202758 o") == true)
        #expect(stalled?.contains("120 s") == true)

        let failed = FinalizationWatch.Verdict
            .failed(bytesWritten: 42, reason: "disque plein")
            .failureReason(formattedBytes: format)
        #expect(failed?.contains("disque plein") == true)
        #expect(failed?.contains("42 o") == true)
    }

    /// Le filet de sécurité : un fichier qui grossirait indéfiniment — capture
    /// jamais arrêtée — ne doit pas retenir bran jusqu'à la fin des temps.
    @Test("Un fichier qui grossit sans fin bute sur le plafond absolu")
    func hardLimitEndsAnEndlessWait() {
        var watch = FinalizationWatch(recorded: .seconds(600))   // plafond : 1 800 s

        for second in stride(from: 0, to: 1_800, by: 10) {
            let verdict = watch.observe(
                bytesWritten: Int64(second) * 1_000_000,
                didFinish: false,
                at: .seconds(second)
            )
            #expect(verdict.isSettled == false)
        }

        let verdict = watch.observe(bytesWritten: 1_800_000_000, didFinish: false, at: .seconds(1_800))
        #expect(verdict == .exhausted(bytesWritten: 1_800_000_000, after: .seconds(1_800)))
    }

    /// Le plancher protège les enregistrements courts, dont la finalisation a un
    /// coût fixe sans rapport avec leur durée.
    @Test("Le plafond ne descend jamais sous dix minutes")
    func hardLimitHasAFloor() {
        #expect(FinalizationWatch.hardLimit(forRecorded: .seconds(9)) == .seconds(600))
        #expect(FinalizationWatch.hardLimit(forRecorded: .seconds(2_191)) == .seconds(6_573))
    }

    /// Le poids écrit se lit sur tous les verdicts. C'est ce qui permet à un
    /// message d'échec de dire « 2,1 Go sont sur le disque » plutôt que de
    /// laisser croire que tout est perdu.
    @Test("Tout verdict porte le poids écrit")
    func everyVerdictCarriesTheBytes() {
        #expect(FinalizationWatch.Verdict.finished(bytesWritten: 7).bytesWritten == 7)
        #expect(FinalizationWatch.Verdict.stalled(bytesWritten: 8, silentFor: .zero).bytesWritten == 8)
        #expect(FinalizationWatch.Verdict.exhausted(bytesWritten: 9, after: .zero).bytesWritten == 9)
        #expect(FinalizationWatch.Verdict.keepWaiting(bytesWritten: 10, silentFor: .zero).bytesWritten == 10)
    }
}
