import Foundation
import Testing
@testable import BranCore

/// **Un éveil qui ment est un Mac qui s'endort en réunion.**
///
/// Deux façons de mentir, et les deux se testent ici sans écran ni assertion
/// système : afficher un temps restant faux, et laisser une session expirée se
/// croire encore active après un saut d'horloge — mise en veille manuelle,
/// capot refermé, recalage réseau.
@Suite("L'éveil")
struct AwakeSessionTests {

    private let origin = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Démarrer

    @Test("Sans limite n'a pas d'échéance, et n'expire donc jamais")
    func sansLimite() {
        let state = AwakeState.begin(.indefinite, at: origin)
        #expect(state == .indefinite)
        #expect(state.isOn)
        #expect(state.remaining(at: origin) == nil)
        // Un siècle plus tard, toujours pas expiré : c'est ce que « sans
        // limite » veut dire, et c'est le défaut de bran.
        #expect(state.hasExpired(at: origin.addingTimeInterval(3_155_760_000)) == false)
    }

    @Test("Une durée pose son échéance à l'instant du clic plus la durée")
    func echeance() {
        let state = AwakeState.begin(.oneHour, at: origin)
        #expect(state == .until(origin.addingTimeInterval(3600)))
        #expect(state.remaining(at: origin) == 3600)
        #expect(state.remaining(at: origin.addingTimeInterval(600)) == 3000)
    }

    @Test("Éteint : rien à décompter, rien à expirer")
    func eteint() {
        let state = AwakeState.off
        #expect(state.isOn == false)
        #expect(state.remaining(at: origin) == nil)
        #expect(state.hasExpired(at: origin) == false)
    }

    // MARK: - Expirer

    @Test("L'échéance passée est expirée, quelle que soit la façon dont on y arrive")
    func expiration() {
        let state = AwakeState.begin(.fiveMinutes, at: origin)

        #expect(state.hasExpired(at: origin.addingTimeInterval(299)) == false)
        #expect(state.hasExpired(at: origin.addingTimeInterval(300)))

        // **Le cas qui justifie la date absolue.** Le Mac dort trois heures,
        // aucune boucle ne tourne, aucun compteur ne décrémente. Au réveil, la
        // session est expirée sans que personne n'ait eu à compter.
        #expect(state.hasExpired(at: origin.addingTimeInterval(10_800)))

        // Et le temps restant est borné à zéro : jamais un nombre négatif dans
        // la barre de menus.
        #expect(state.remaining(at: origin.addingTimeInterval(10_800)) == 0)
    }

    // MARK: - Le décompte

    @Test("Le décompte arrondit vers le haut : le nombre affiché est une promesse tenue")
    func arrondiVersLeHaut() {
        // Une session de 5 minutes affiche « 5 min » dès la première seconde.
        // Arrondi au plus proche, elle aurait affiché « 4 min » pendant trente
        // secondes — un mensonge de trente secondes sur cinq minutes.
        #expect(AwakeFormat.countdown(300) == "5 min")
        #expect(AwakeFormat.countdown(241) == "5 min")
        #expect(AwakeFormat.countdown(240) == "4 min")

        // Sous la minute, on passe aux secondes : « 0 min » sur une session
        // encore active serait le même mensonge, en pire.
        #expect(AwakeFormat.countdown(59) == "59 s")
        #expect(AwakeFormat.countdown(0.4) == "1 s")
        #expect(AwakeFormat.countdown(0) == "0 s")
        #expect(AwakeFormat.countdown(-12) == "0 s")
    }

    @Test("Le passage aux heures se fait sur les minutes déjà arrondies")
    func passageAuxHeures() {
        // 3 599 s arrondit à 60 minutes. Affiché tel quel, ce serait « 60 min »
        // — une unité qui n'existe pas sur une horloge.
        #expect(AwakeFormat.countdown(3599) == "1 h 00")
        #expect(AwakeFormat.countdown(3600) == "1 h 00")
        #expect(AwakeFormat.countdown(18_000) == "5 h 00")
        #expect(AwakeFormat.countdown(4500) == "1 h 15")
    }

    @Test("Les minutes gardent deux chiffres, pour que le libellé ne change pas de largeur")
    func largeurConstante() {
        // « 1 h 9 » puis « 1 h 10 » : un caractère de plus, et tout ce qui est à
        // gauche dans la barre de menus se décale.
        #expect(AwakeFormat.countdown(3600 + 540) == "1 h 09")
        #expect(AwakeFormat.countdown(3600 + 60) == "1 h 01")
    }

    // MARK: - Ce que la barre de menus reçoit

    @Test("La barre de menus n'ajoute rien quand l'éveil est éteint")
    func barreDeMenus() {
        #expect(AwakeFormat.menuBar(.off, at: origin) == nil)
        #expect(AwakeFormat.menuBar(.indefinite, at: origin) == "∞")
        #expect(AwakeFormat.menuBar(.begin(.twoHours, at: origin), at: origin) == "2 h 00")
    }

    @Test("Le résumé du menu dit l'état en une phrase, y compris l'état éteint")
    func resume() {
        #expect(AwakeFormat.summary(.off, at: origin) == "Le Mac s'endort normalement.")
        #expect(AwakeFormat.summary(.indefinite, at: origin) == "Éveillé — sans limite.")
        #expect(
            AwakeFormat.summary(.begin(.thirtyMinutes, at: origin), at: origin.addingTimeInterval(60))
                == "Éveillé — encore 29 min."
        )
    }

    // MARK: - Les durées

    @Test("La liste des durées finit par « Sans limite », et zéro seconde la désigne")
    func durees() {
        #expect(AwakeDuration.allCases.last == .indefinite)
        #expect(AwakeDuration.indefinite.seconds == 0)
        #expect(AwakeDuration.indefinite.isIndefinite)
        #expect(AwakeDuration.fiveHours.seconds == 18_000)

        // La valeur brute est persistée telle quelle : une valeur inconnue
        // relue plus tard rend `nil`, et l'appelant retombe sur son défaut.
        #expect(AwakeDuration(rawValue: 999) == nil)
        #expect(AwakeDuration(rawValue: 3600) == .oneHour)
    }
}
