import Foundation
import Testing

@testable import BranCore

/// **Ce que ce fichier protège** : le filet lent du presse-papiers ne doit
/// réveiller le processus toutes les deux secondes que lorsque quelqu'un est
/// devant la machine. Il tournait à cadence fixe, batterie et écran éteint
/// compris — 1 800 réveils par heure, jour et nuit, pour relire un entier
/// inchangé. Le ralentissement ne doit jamais dépasser dix secondes tant que
/// l'écran est allumé : au-delà, une copie faite à la souris arriverait avec un
/// retard qu'on lirait comme une panne.
@Suite("Cadence du filet lent du presse-papiers")
struct ClipboardCadenceTests {

    @Test("Quelqu'un vient de taper : on relit toutes les deux secondes")
    func humainPresentDonneLaCadenceRapide() {
        let facts = ClipboardCadence.Facts(idleSeconds: 0.4)
        #expect(ClipboardCadence.interval(for: facts) == 2)
    }

    @Test("Une lecture qui reste sous la minute garde la cadence rapide")
    func inactiviteCourteNeRalentitPas() {
        let facts = ClipboardCadence.Facts(idleSeconds: 59)
        #expect(ClipboardCadence.interval(for: facts) == 2)
    }

    @Test("Une minute sans clavier ni souris ralentit à dix secondes")
    func inactiviteDUneMinuteRalentit() {
        let facts = ClipboardCadence.Facts(idleSeconds: 60)
        #expect(ClipboardCadence.interval(for: facts) == 10)
    }

    @Test("L'écran éteint parque le sondeur à une minute")
    func ecranEteintParqueLeSondeur() {
        let facts = ClipboardCadence.Facts(idleSeconds: 1, isDisplayAsleep: true)
        #expect(ClipboardCadence.interval(for: facts) == 60)
    }

    @Test("La session verrouillée parque le sondeur, même clavier actif")
    func sessionVerrouilleeParqueLeSondeur() {
        // L'inactivité peut rester basse écran verrouillé : la saisie du mot de
        // passe est un événement clavier. C'est le verrou qui décide, pas elle.
        let facts = ClipboardCadence.Facts(idleSeconds: 0, isScreenLocked: true)
        #expect(ClipboardCadence.interval(for: facts) == 60)
    }

    @Test("Un capteur d'inactivité muet ne fait jamais ralentir")
    func capteurMuetGardeLaCadenceRapide() {
        // Ralentir sur une mesure qu'on n'a pas, c'est éteindre à moitié une
        // fonction que l'utilisateur croit allumée.
        #expect(ClipboardCadence.interval(for: ClipboardCadence.Facts(idleSeconds: nil)) == 2)
        #expect(ClipboardCadence.interval(for: ClipboardCadence.Facts(idleSeconds: -1)) == 2)
        #expect(ClipboardCadence.interval(for: ClipboardCadence.Facts(idleSeconds: .infinity)) == 2)
    }

    @Test("Une nuit écran éteint coûte soixante réveils par heure au lieu de 1 800")
    func lEconomieAnnonceeSeRecalcule() {
        #expect(ClipboardCadence.wakeupsPerHour(ClipboardCadence.attentive) == 1800)
        #expect(ClipboardCadence.wakeupsPerHour(ClipboardCadence.relaxed) == 360)
        #expect(ClipboardCadence.wakeupsPerHour(ClipboardCadence.parked) == 60)
    }

    @Test("Le palier lent reste sous les dix secondes de retard promises")
    func lePalierLentNeDepassePasDixSecondes() {
        // La borne est une promesse faite à l'utilisateur, pas un détail : une
        // copie faite à la souris juste après une pause ne doit jamais mettre
        // plus de dix secondes à apparaître tant que l'écran est allumé.
        let facts = ClipboardCadence.Facts(idleSeconds: 12 * 3600)
        #expect(ClipboardCadence.interval(for: facts) <= 10)
    }
}
