import Foundation
import Testing
@testable import BranCore

@Suite("Ce que bran dit pendant qu'il termine")
struct SessionProgressTests {

    private static let consigne = "ne quittez pas bran"

    // MARK: - Les libellés

    @Test("Chaque étape dit ce que bran fait, et les trois se distinguent")
    func troisTitresDistincts() {
        // « Traitement en cours » pour les trois ne répondrait pas à la question
        // que l'utilisateur se pose : est-ce que ça avance, et est-ce que je peux
        // partir ?
        let titres = [
            SessionProgress(stage: .finalizing).title,
            SessionProgress(stage: .merging).title,
            SessionProgress(stage: .exportingAudio).title,
        ]

        #expect(Set(titres).count == 3)
        #expect(titres.allSatisfy { $0.isEmpty == false })
    }

    // MARK: - La ligne de détail

    @Test("Au démarrage d'une étape, ni « 0 % » ni « 0 octet » : seulement la consigne")
    func detailAuDemarrageNAffichePasDeZeros() {
        // Le défaut à empêcher : « 0 % · 0 octet · environ 0 min », qui a l'air
        // d'un blocage alors qu'il décrit un démarrage normal.
        let demarrages = [
            SessionProgress(stage: .finalizing),
            SessionProgress(stage: .merging, fraction: 0, bytesWritten: 0),
            SessionProgress(stage: .exportingAudio, fraction: 0, bytesWritten: 0),
        ]

        for progress in demarrages {
            #expect(progress.detail == Self.consigne, "détail bavard au démarrage : « \(progress.detail) »")
            #expect(progress.detail.contains("%") == false)
            #expect(progress.detail.contains("écrits") == false)
        }
    }

    @Test("Chaque morceau n'apparaît que lorsqu'il a quelque chose à dire")
    func detailNAfficheQueCeQuiExiste() {
        let avance = SessionProgress(
            stage: .merging,
            fraction: 0.5,
            bytesWritten: 1_200_000_000,
            elapsed: .seconds(10)
        )

        #expect(avance.detail.contains("50 %"))
        #expect(avance.detail.contains("écrits"))
        #expect(avance.detail.contains("moins d'une minute"))

        // Le poids seul, sans pourcentage, reste lisible : c'est le cas de la
        // finalisation, qui n'a aucune progression à offrir.
        let finalisation = SessionProgress(stage: .finalizing, bytesWritten: 180_000_000)
        #expect(finalisation.detail.contains("%") == false)
        #expect(finalisation.detail.contains("écrits"))
    }

    @Test("La consigne est toujours là, et toujours en dernier")
    func consigneToujoursEnDernier() {
        // C'est la seule action que l'utilisateur peut prendre, et fermer bran
        // pendant la fusion tue le travail en cours.
        let cas = [
            SessionProgress(stage: .finalizing),
            SessionProgress(stage: .finalizing, bytesWritten: 2_556_202_758, recorded: .seconds(2_191)),
            SessionProgress(stage: .merging, fraction: 0.5, bytesWritten: 42, elapsed: .seconds(10)),
            SessionProgress(stage: .exportingAudio, bytesWritten: 7),
        ]

        for progress in cas {
            #expect(progress.detail.hasSuffix(Self.consigne), "consigne absente ou déplacée : « \(progress.detail) »")
        }
    }

    // MARK: - Le temps restant : finalisation

    @Test("Sous trente secondes enregistrées, la finalisation n'annonce rien")
    func finalisationTropCourtePourEstimer() {
        // Le coût est fixe et minuscule à cette échelle : annoncer « environ
        // 0 min » vaudrait moins que se taire.
        #expect(SessionProgress(stage: .finalizing, recorded: .zero).remaining == nil)
        #expect(SessionProgress(stage: .finalizing, recorded: .seconds(30)).remaining == nil)
        #expect(SessionProgress(stage: .finalizing, recorded: .seconds(31)).remaining != nil)
    }

    @Test("La finalisation est estimée à un tiers de la durée enregistrée, moins le temps passé")
    func finalisationEstimeeAuTiers() {
        // La mesure du 11 août 2026 : 2 191 s enregistrées, 729 s de finalisation.
        let debut = SessionProgress(stage: .finalizing, recorded: .seconds(2_191))
        #expect(debut.remaining == .seconds(730))

        let aMiChemin = SessionProgress(stage: .finalizing, recorded: .seconds(2_191), elapsed: .seconds(365))
        #expect(aMiChemin.remaining == .seconds(365))
    }

    @Test("Une fois le tiers dépassé, on se tait plutôt que d'annoncer un temps négatif")
    func finalisationNAnnoncePasDeTempsNegatif() {
        // L'estimation vient d'une mesure faite une fois : elle sera dépassée un
        // jour, et « environ -3 min » serait le pire des affichages.
        #expect(SessionProgress(stage: .finalizing, recorded: .seconds(2_191), elapsed: .seconds(730)).remaining == nil)
        #expect(SessionProgress(stage: .finalizing, recorded: .seconds(2_191), elapsed: .seconds(900)).remaining == nil)
    }

    // MARK: - Le temps restant : fusion

    @Test("La fusion ne s'engage pas sur une estimation faite trop tôt")
    func fusionNEstimePasTropTot() {
        // Une estimation faite sur 2 % d'avancement se trompe d'un facteur dix ;
        // l'annoncer puis la voir tripler est pire que ne rien annoncer.
        #expect(SessionProgress(stage: .merging, fraction: nil, elapsed: .seconds(30)).remaining == nil)
        #expect(SessionProgress(stage: .merging, fraction: 0.02, elapsed: .seconds(30)).remaining == nil)

        // Fraction suffisante mais temps passé dérisoire : deux secondes de
        // mesure ne disent rien non plus.
        #expect(SessionProgress(stage: .merging, fraction: 0.5, elapsed: .seconds(1)).remaining == nil)
        #expect(SessionProgress(stage: .merging, fraction: 0.5, elapsed: .zero).remaining == nil)
    }

    @Test("La fusion extrapole depuis le temps déjà passé")
    func fusionExtrapoleDepuisLeTempsPasse() {
        // À moitié faite après 10 s, il reste environ 10 s. Extrapoler vaut mieux
        // qu'une constante : la vitesse dépend de l'écran, du codec et de ce que
        // la machine fait par ailleurs.
        #expect(SessionProgress(stage: .merging, fraction: 0.5, elapsed: .seconds(10)).remaining == .seconds(10))
        #expect(SessionProgress(stage: .merging, fraction: 0.25, elapsed: .seconds(10)).remaining == .seconds(30))
        #expect(SessionProgress(stage: .merging, fraction: 0.8, elapsed: .seconds(40)).remaining == .seconds(10))
    }

    @Test("Sur la dernière seconde, la fusion se tait plutôt que d'annoncer zéro")
    func fusionSeTaitALaFin() {
        #expect(SessionProgress(stage: .merging, fraction: 1, elapsed: .seconds(100)).remaining == nil)
        #expect(SessionProgress(stage: .merging, fraction: 0.999, elapsed: .seconds(100)).remaining == nil)
    }

    @Test("L'extraction audio n'annonce jamais de temps restant")
    func extractionAudioNAnnonceRien() {
        // Quelques secondes, y compris sur une réunion de trois heures : estimer
        // aurait plus de chances de se tromper que d'aider.
        #expect(SessionProgress(stage: .exportingAudio).remaining == nil)
        #expect(SessionProgress(stage: .exportingAudio, fraction: 0.5, elapsed: .seconds(60)).remaining == nil)
        #expect(
            SessionProgress(stage: .exportingAudio, fraction: 0.5, recorded: .seconds(10_800), elapsed: .seconds(60))
                .remaining == nil
        )
    }

    // MARK: - La phrase du menu

    @Test("La phrase du menu tient en une ligne")
    func resumeSurUneLigne() {
        let cas = [
            SessionProgress(stage: .finalizing, bytesWritten: 2_556_202_758, recorded: .seconds(2_191)),
            SessionProgress(stage: .merging, fraction: 0.5, bytesWritten: 42, elapsed: .seconds(10)),
            SessionProgress(stage: .exportingAudio),
        ]

        for progress in cas {
            #expect(progress.summary.contains("\n") == false)
            #expect(progress.summary.contains("·") == false, "le menu n'a pas la place d'une énumération")
        }
    }

    @Test("Le résumé ne laisse jamais « … » collé à un tiret")
    func resumeSansPointsDeSuspensionAvantLeTiret() {
        // Le défaut à empêcher : « Fusion et compression de la vidéo… — 50 % »,
        // qui suspend une phrase pour la reprendre aussitôt.
        let cas = [
            SessionProgress(stage: .finalizing, bytesWritten: 2_556_202_758, recorded: .seconds(2_191)),
            SessionProgress(stage: .merging, fraction: 0.5, elapsed: .seconds(10)),
            SessionProgress(stage: .exportingAudio),
        ]

        for progress in cas {
            #expect(progress.summary.contains("… —") == false, "« \(progress.summary) »")
            #expect(progress.summary.contains("…") == false, "« \(progress.summary) »")
        }
    }

    @Test("Le résumé porte le pourcentage quand il existe, le poids sinon")
    func resumePorteLeChiffreDisponible() {
        let avecFraction = SessionProgress(stage: .merging, fraction: 0.5, bytesWritten: 1_000_000)
        #expect(avecFraction.summary.contains("50 %"))

        // La finalisation n'a pas de fraction : c'est le poids écrit qui devient
        // le seul signe que quelque chose avance.
        let sansFraction = SessionProgress(stage: .finalizing, bytesWritten: 1_000_000)
        #expect(sansFraction.summary.contains("%") == false)
        #expect(sansFraction.summary.contains("écrits"))

        // Rien à dire : le titre seul, sans tiret orphelin.
        let muet = SessionProgress(stage: .exportingAudio)
        #expect(muet.summary.contains("—") == false)
    }

    // MARK: - Les fractions absurdes

    @Test("Une fraction hors bornes ne produit pas un pourcentage absurde")
    func fractionHorsBornes() {
        // Une fraction vient d'un compteur externe (AVAssetExportSession) : elle
        // peut sortir des clous, et « -50 % » ou « 1 200 % » détruirait la seule
        // information dont l'utilisateur dispose.
        let negative = SessionProgress(stage: .merging, fraction: -0.5)
        #expect(negative.detail == Self.consigne)
        #expect(negative.summary.contains("%") == false)

        let excessive = SessionProgress(stage: .merging, fraction: 12)
        #expect(excessive.detail.contains("100 %"))
        #expect(excessive.detail.contains("1 200") == false)
        #expect(excessive.summary.contains("100 %"))
    }
}
