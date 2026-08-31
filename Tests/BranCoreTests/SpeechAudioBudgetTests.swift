import Foundation
import Testing
@testable import BranCore

@Suite("Le budget de l'audio envoyé au CRM")
struct SpeechAudioBudgetTests {

    // MARK: - Les bornes

    /// **Le test qui compte le plus de tout ce fichier.**
    ///
    /// La borne a valu 52 428 800 — soit 50 **Mio** — sous un commentaire qui
    /// disait pourtant « mesuré côté Supabase : 50 passent, 52 sont refusés ».
    /// Confondre Mo et Mio plaçait la garde de bran en plein dans la zone de
    /// refus : un fichier entre 50 et 52,4 Mo passait le contrôle local, montait
    /// en entier, et le serveur le rejetait à l'arrivée. Tout le temps de
    /// l'envoi était perdu, sur la seule catégorie de réunions assez longues
    /// pour approcher le plafond.
    ///
    /// Rien dans le code ne pouvait signaler l'écart, puisque les deux valeurs
    /// s'écrivent « 50 Mo » en français courant. Seule une constante posée en
    /// toutes lettres le peut.
    @Test("Le plafond se compte en méga-octets décimaux, comme le serveur")
    func plafondEnMegaOctetsDecimaux() {
        #expect(SpeechAudioBudget.maximumBytes == 50_000_000)
        #expect(SpeechAudioBudget.maximumBytes != 52_428_800, "50 Mio n'est pas 50 Mo")
    }

    @Test("Le budget de travail est 90 % du plafond")
    func budgetDeTravail() {
        #expect(SpeechAudioBudget.workingBudgetBytes == 45_000_000)
        #expect(SpeechAudioBudget.workingBudgetBytes < SpeechAudioBudget.maximumBytes)
    }

    @Test("Les débits sont ceux que LAME accepte à 16 kHz, bornés à 48 kbit/s")
    func tableDesDebits() {
        // Hors table, `lame_init_params` remplace le débit en silence par le
        // voisin le plus proche — et la taille du fichier n'est alors plus celle
        // que ce budget avait calculée. `MP3Encoder` relit ce que LAME a retenu
        // et refuse si ça diverge ; encore faut-il ne jamais lui demander
        // n'importe quoi.
        #expect(SpeechAudioBudget.bitrates == [8_000, 16_000, 24_000, 32_000, 40_000, 48_000])
        #expect(SpeechAudioBudget.minimumBitrate == 8_000)
        #expect(SpeechAudioBudget.maximumBitrate == 48_000)
    }

    // MARK: - Le choix du débit

    @Test("Un closing d'une heure garde la qualité maximale")
    func closingOrdinaireAuMaximum() {
        // C'est le cas de la quasi-totalité des réunions : rien ne doit changer
        // pour elles, ni en qualité ni en poids.
        #expect(SpeechAudioBudget.bitrate(forDurationSeconds: 60 * 60) == 48_000)
        #expect(SpeechAudioBudget.bitrate(forDurationSeconds: 32.7 * 60) == 48_000)
    }

    @Test("Le maximum tient jusqu'à un peu plus de deux heures")
    func bascule() {
        // 45 Mo à 48 kbit/s = 7 500 s. De part et d'autre de cette frontière, le
        // palier doit changer — et pas ailleurs.
        #expect(SpeechAudioBudget.bitrate(forDurationSeconds: 7_400) == 48_000)
        #expect(SpeechAudioBudget.bitrate(forDurationSeconds: 7_600) == 40_000)
    }

    @Test("Une réunion longue descend d'un palier au lieu d'être refusée")
    func reunionLongueDegradee() {
        // Le comportement que le débit fixe n'avait pas : à 48 kbit/s en dur,
        // bran refusait purement et simplement d'envoyer une réunion qu'il
        // suffisait d'encoder un cran plus bas.
        let quatreHeures = SpeechAudioBudget.bitrate(forDurationSeconds: 4 * 3600)
        #expect(quatreHeures == 24_000)
        #expect(quatreHeures >= SpeechAudioBudget.minimumBitrate)
    }

    @Test("Le plancher n'est atteint qu'au-delà de douze heures")
    func plancherTresTard() {
        #expect(SpeechAudioBudget.bitrate(forDurationSeconds: 11 * 3600) == 8_000)

        // Le plancher tient 45 000 s dans le budget, soit 12 h 30 : c'est la
        // conséquence directe du passage de l'AAC — dont l'encodeur refusait le
        // média entier sous 12 kbit/s, ce qui plafonnait les envois à 8 h 20 —
        // au MP3, qui descend à 8.
        #expect(SpeechAudioBudget.bitrate(forDurationSeconds: 20 * 3600) == 8_000)
    }

    @Test("Le débit choisi ne fait jamais déborder le budget de travail")
    func jamaisDeDepassement() {
        // La propriété qui justifie tout le reste, vérifiée minute par minute
        // sur douze heures. Un arrondi au millier le plus PROCHE — la version
        // qu'on aurait écrite spontanément — la casserait juste au-dessus de
        // chaque frontière de palier.
        for minutes in 1...(12 * 60) {
            let seconds = Double(minutes * 60)
            let bitrate = SpeechAudioBudget.bitrate(forDurationSeconds: seconds)
            guard bitrate > SpeechAudioBudget.minimumBitrate else { continue }

            let predicted = Int(Double(bitrate) * seconds / 8)
            #expect(
                predicted <= SpeechAudioBudget.workingBudgetBytes,
                "\(minutes) min à \(bitrate / 1000) kbit/s ferait \(predicted) octets"
            )
        }
    }

    @Test("Plus la réunion est longue, moins le débit est élevé")
    func decroissanceMonotone() {
        var previous = Int.max
        for minutes in stride(from: 5, through: 14 * 60, by: 5) {
            let bitrate = SpeechAudioBudget.bitrate(forDurationSeconds: Double(minutes * 60))
            #expect(bitrate <= previous, "le débit remonte à \(minutes) min")
            previous = bitrate
        }
    }

    @Test("Une durée illisible fait viser le maximum, pas le minimum")
    func dureeInconnueViseHaut() {
        // Un fichier abîmé rend une durée nulle ou non numérique. Deviner bas
        // « au cas où » dégraderait tous les fichiers dont on ne sait rien ;
        // c'est la mesure de la taille écrite, en fin d'extraction, qui tranche.
        #expect(SpeechAudioBudget.bitrate(forDurationSeconds: 0) == 48_000)
        #expect(SpeechAudioBudget.bitrate(forDurationSeconds: -1) == 48_000)
        #expect(SpeechAudioBudget.bitrate(forDurationSeconds: .nan) == 48_000)
        #expect(SpeechAudioBudget.bitrate(forDurationSeconds: .infinity) == 48_000)
    }

    // MARK: - Le refus

    @Test("Le refus se juge au plafond réel, pas au budget de travail")
    func refusJugeAuPlafond() {
        // Le budget est une marge qu'on s'accorde pour VISER ; le faire entrer
        // dans la décision de renoncer ferait refuser d'encoder une bande de
        // durées où le fichier serait pourtant passé — entre 45 000 et 50 000 s
        // au plancher, soit une heure et demie de réunions sacrifiées à une
        // marge de prudence qui n'avait rien à faire là.
        #expect(SpeechAudioBudget.fits(durationSeconds: 46_000))
        #expect(SpeechAudioBudget.fits(durationSeconds: 49_000))
        #expect(SpeechAudioBudget.fits(durationSeconds: 51_000) == false)
    }

    @Test("Une durée inconnue n'est jamais refusée d'avance")
    func dureeInconnueJamaisRefusee() {
        // On ne renonce pas sur une absence d'information : on encode, et la
        // taille écrite décide.
        #expect(SpeechAudioBudget.fits(durationSeconds: 0))
        #expect(SpeechAudioBudget.fits(durationSeconds: .nan))
    }

    @Test("Le poids annoncé au refus est celui du plancher")
    func poidsAnnonceAuRefus() {
        // Rien n'a été encodé quand ce message s'écrit : la seule taille qu'on
        // puisse honnêtement citer est celle qu'aurait donnée le meilleur
        // réglage possible.
        let seconds = 51_000.0
        let expected = Int(seconds * 8_000 / 8)
        #expect(SpeechAudioBudget.floorSizeBytes(durationSeconds: seconds) == expected)
        #expect(expected > SpeechAudioBudget.maximumBytes)
    }
}
