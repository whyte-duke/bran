import BranWatch
import Foundation
import Observation

/// Les réglages du veilleur, persistés dans `UserDefaults`.
///
/// Rien de secret ici non plus : pas de jeton, pas de clé. Le trousseau serait
/// du zèle.
@MainActor
@Observable
final class WatchSettings {

    private enum Key {
        static let enabled = "bran.watch.enabled"
        static let watchesWindows = "bran.watch.watchesWindows"
        static let tickSeconds = "bran.watch.tickSeconds"
        static let waitingAfterMinutes = "bran.watch.waitingAfterMinutes"
        static let busyRatio = "bran.watch.busyRatio"
        static let busyRatioMeasured = "bran.watch.busyRatioMeasured"
        static let retentionDays = "bran.watch.retentionDays"
        static let showsOverlay = "bran.watch.showsOverlay"
        static let dailyTargetHours = "bran.watch.dailyTargetHours"
    }

    var isEnabled: Bool { didSet { defaults.set(isEnabled, forKey: Key.enabled) } }

    /// Observer aussi les fenêtres, en comparant leurs pixels.
    ///
    /// **Faux par défaut, et ce n'est pas de la prudence décorative.** Les
    /// transcriptions d'agents donnent un verdict *certain* sans coûter une
    /// autorisation ni une capture d'écran : le veilleur est déjà utile sans
    /// ça. Les pixels ajoutent les tribus sans transcription — un onglet
    /// `claude.ai`, une compilation dans un terminal — mais ils demandent
    /// l'autorisation d'enregistrement de l'écran et de la batterie. On fait
    /// donc payer ce prix quand quelqu'un le demande, pas avant.
    var watchesWindows: Bool { didSet { defaults.set(watchesWindows, forKey: Key.watchesWindows) } }

    /// Le pas de la boucle.
    ///
    /// Quatre secondes, contre deux dans le spike : le spike cherchait à
    /// caractériser un signal, l'application cherche à ne pas se faire
    /// remarquer. Le seuil le plus court du résolveur vaut trois minutes, soit
    /// quarante-cinq tics — largement de quoi décider.
    var tickSeconds: Int { didSet { defaults.set(tickSeconds, forKey: Key.tickSeconds) } }

    /// Immobile plus longtemps que ça : la voie attend.
    var waitingAfterMinutes: Int { didSet { defaults.set(waitingAfterMinutes, forKey: Key.waitingAfterMinutes) } }

    /// Part des blocs d'image qui doivent bouger pour qu'une fenêtre soit dite
    /// active.
    ///
    /// **Ce nombre est une grandeur physique, pas un choix de produit**, et
    /// c'est pour ça qu'il vit dans les réglages et non dans `WatchResolver` :
    /// un seuil inventé placé dans « le seul endroit qui décide » ressemblerait
    /// à une mesure. La valeur de départ vient d'un unique relevé du spike —
    /// ratio maximal 0,0364 sur un terminal en travail, 0,0000 sur les fenêtres
    /// immobiles — et l'interface dit qu'elle n'a pas été mesurée *ici*.
    var busyRatio: Double { didSet { defaults.set(busyRatio, forKey: Key.busyRatio) } }

    /// Vrai une fois que l'utilisateur a réglé le seuil lui-même. Sert
    /// uniquement à cesser d'afficher l'avertissement « valeur non mesurée sur
    /// ce Mac » : une mise en garde qu'on ne peut pas faire taire finit par ne
    /// plus rien vouloir dire.
    var busyRatioMeasured: Bool { didSet { defaults.set(busyRatioMeasured, forKey: Key.busyRatioMeasured) } }

    var retentionDays: Int { didSet { defaults.set(retentionDays, forKey: Key.retentionDays) } }

    /// Le panneau d'attention, au-dessus de tout.
    var showsOverlay: Bool { didSet { defaults.set(showsOverlay, forKey: Key.showsOverlay) } }

    /// **La journée de référence, en heures.** Le dénominateur de l'écran
    /// Aujourd'hui.
    ///
    /// « 4 h 08 de travail » ne veut rien dire tout seul. « 4 h 08, soit 68 %
    /// d'une journée de 6 h » veut dire quelque chose — et le jour où la barre
    /// affiche 140 %, c'est ce 140 % qui est l'information, pas les heures.
    ///
    /// Six heures par défaut, et pas huit. Huit heures est la durée d'une
    /// présence au bureau, pas d'un travail mesuré : personne ne fait huit
    /// heures de travail attribué dans une journée de huit heures, et fixer un
    /// objectif qu'on n'atteint jamais transforme un instrument de mesure en
    /// reproche quotidien.
    ///
    /// Zéro éteint la comparaison : la phrase retombe alors sur les heures
    /// seules, ce qui est la bonne sortie pour qui ne veut pas d'objectif.
    var dailyTargetHours: Int { didSet { defaults.set(dailyTargetHours, forKey: Key.dailyTargetHours) } }

    private let defaults = UserDefaults.standard

    init() {
        isEnabled = defaults.object(forKey: Key.enabled) as? Bool ?? true

        // Allumé par défaut, et c'est un choix qui coûte quelque chose.
        //
        // Sans l'observation des fenêtres, seul Claude Code en local est vu :
        // ni l'onglet `claude.ai`, ni l'application de bureau, ni ce qui tourne
        // au bout d'un SSH. Or c'est précisément la couverture partielle qui
        // rendait la vue intégrée de Claude Code insuffisante — un veilleur qui
        // ne voit qu'une tribu se fait oublier en trois jours.
        //
        // Le prix : l'autorisation Écran, déjà accordée pour les réunions, et
        // un budget de captures qui se réduit tout seul sur batterie.
        watchesWindows = defaults.object(forKey: Key.watchesWindows) as? Bool ?? true
        tickSeconds = defaults.object(forKey: Key.tickSeconds) as? Int ?? 4
        waitingAfterMinutes = defaults.object(forKey: Key.waitingAfterMinutes) as? Int ?? 3
        busyRatio = defaults.object(forKey: Key.busyRatio) as? Double ?? 0.01
        busyRatioMeasured = defaults.object(forKey: Key.busyRatioMeasured) as? Bool ?? false
        retentionDays = defaults.object(forKey: Key.retentionDays) as? Int ?? 30
        showsOverlay = defaults.object(forKey: Key.showsOverlay) as? Bool ?? true
        dailyTargetHours = defaults.object(forKey: Key.dailyTargetHours) as? Int ?? 6
    }

    /// Les seuils du résolveur.
    ///
    /// Seuls deux des cinq sont exposés dans l'interface. Les trois autres —
    /// « sans nouvelles », « abandonnée », « humain absent » — ont des défauts
    /// défendables et n'ont jamais eu besoin d'être touchés ; les offrir
    /// remplirait l'écran de réglages de curseurs dont personne ne connaît la
    /// bonne valeur.
    var thresholds: WatchResolver.Thresholds {
        var thresholds = WatchResolver.Thresholds(busyRatio: busyRatio)
        thresholds.waitingAfter = TimeInterval(waitingAfterMinutes) * 60
        return thresholds
    }

    var tickInterval: TimeInterval { TimeInterval(max(1, tickSeconds)) }

    var retention: WatchRetention { WatchRetention(days: retentionDays) }
}
