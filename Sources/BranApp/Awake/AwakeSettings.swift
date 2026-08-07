import BranCore
import Foundation
import Observation

/// Les réglages de l'éveil, persistés dans `UserDefaults`. Trois, et chacun
/// répond à une question qu'on se pose vraiment.
@MainActor
@Observable
final class AwakeSettings {

    private enum Key {
        static let defaultDuration = "bran.awake.defaultDuration"
        static let startsAtLaunch = "bran.awake.startsAtLaunch"
        static let stopsOnManualSleep = "bran.awake.stopsOnManualSleep"
    }

    /// Ce qu'un clic déclenche.
    ///
    /// **« Sans limite » par défaut**, là où Caffeine propose cinq heures : la
    /// demande était « un clic = tout le temps ». Celui qui préfère une durée la
    /// choisit ici, et son clic la prendra — le geste reste un clic dans les
    /// deux cas.
    var defaultDuration: AwakeDuration {
        didSet { defaults.set(defaultDuration.rawValue, forKey: Key.defaultDuration) }
    }

    /// Allumer l'éveil au lancement de bran.
    ///
    /// Faux par défaut. Une application qui empêche le Mac de dormir sans que
    /// personne ne l'ait demandé est une application qu'on désinstalle après
    /// avoir cherché pendant une semaine pourquoi la batterie tombait la nuit.
    var startsAtLaunch: Bool {
        didSet { defaults.set(startsAtLaunch, forKey: Key.startsAtLaunch) }
    }

    /// Éteindre l'éveil quand le Mac est mis en veille **à la main**.
    ///
    /// Vrai par défaut, comme dans Caffeine, et le mot « à la main » est tout le
    /// réglage : endormir sa machine explicitement — menu Pomme, capot, ⌃⌘⏏ —
    /// est une façon de dire « j'ai fini ». Se réveiller le lendemain avec un
    /// éveil toujours actif qu'on croyait avoir clos serait une surprise, et
    /// l'éveil est précisément la fonction qui n'a pas le droit d'en faire.
    var stopsOnManualSleep: Bool {
        didSet { defaults.set(stopsOnManualSleep, forKey: Key.stopsOnManualSleep) }
    }

    private let defaults = UserDefaults.standard

    init() {
        // Une valeur brute inconnue — une liste de durées qui change entre deux
        // versions — retombe sur le défaut au lieu de refuser de démarrer.
        let stored = defaults.object(forKey: Key.defaultDuration) as? Int
        defaultDuration = stored.flatMap(AwakeDuration.init(rawValue:)) ?? .indefinite

        startsAtLaunch = defaults.bool(forKey: Key.startsAtLaunch)
        stopsOnManualSleep = defaults.object(forKey: Key.stopsOnManualSleep) as? Bool ?? true
    }
}
