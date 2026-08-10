import Foundation

/// Les fonctions dont la touche est physiquement enfoncée — et la règle qui
/// veut qu'**un appui produise exactement un signal**.
///
/// ## Le défaut que ce type existe pour rendre impossible
///
/// `HotkeyMonitor.classify` traite les deux familles de raccourcis dans deux
/// branches séparées, et une seule des deux savait compter :
///
/// - **une touche modificatrice seule** arrive en `flagsChanged`, et le guet
///   compare l'ancien masque au nouveau. `isDown != wasDown` est une
///   déduplication : tenir la touche n'émet rien de plus ;
/// - **une touche normale** arrive en `keyDown` — et macOS **répète** les
///   `keyDown` tant que la touche est tenue, plusieurs fois par seconde. Le
///   guet faisait un `insert` dans un `Set` sans regarder ce qu'il rendait, et
///   réémettait `.triggerDown` à chaque répétition.
///
/// Ce n'est pas une gêne théorique : c'est une averse de signaux dans tout ce
/// qui écoute. Le premier dégât trouvé — la cible du collage réaimée à chaque
/// répétition, donc la dictée qui atterrit dans la fenêtre du moment plutôt que
/// dans celle du début — a été colmaté chez l'appelant, ce qui traitait le
/// symptôme. Le signal, lui, restait faux, et le prochain appelant aurait
/// rattrapé le même défaut à son tour.
///
/// D'où ce type. `press` et `release` **rendent ce qui a changé**, et ne sont
/// pas `@discardableResult` : le compilateur oblige à regarder. La règle « un
/// appui, un signal » cesse d'être une convention que la prochaine branche
/// oubliera, et devient une propriété du type — les deux branches passent par
/// la même porte et se dédupliquent de la même façon.
///
/// **Ce que ce type ne fait pas.** Il ne remplace pas le filtre sur
/// `keyboardEventAutorepeat` : celui-là écarte la répétition dans le callback du
/// tap, avant le saut vers le main actor, et évite donc une tâche par
/// répétition. Les deux visent deux choses différentes — l'un le coût, l'autre
/// la justesse — et il faut les deux. Voir `HotkeyMonitor.receive`.
public struct HeldTriggers: Equatable, Sendable {

    private var pressed: Set<GlobalTrigger>

    public init(_ pressed: Set<GlobalTrigger> = []) {
        self.pressed = pressed
    }

    /// L'ensemble nu, pour les fonctions de `TriggerTable` qui raisonnent
    /// dessus — `resyncedFlags(from:held:)` et
    /// `triggersLosingTheirKey(since:among:)`.
    public var triggers: Set<GlobalTrigger> { pressed }

    public var isEmpty: Bool { pressed.isEmpty }

    public func contains(_ trigger: GlobalTrigger) -> Bool {
        pressed.contains(trigger)
    }

    /// Note un appui.
    ///
    /// - Returns: `true` si c'est un **nouvel** appui, donc le seul cas où il y a
    ///   quelque chose à signaler. `false` veut dire que la touche était déjà
    ///   tenue : répétition automatique du système, ou masque de modificateurs
    ///   qui repasse par « enfoncé » sans que le doigt ait bougé.
    public mutating func press(_ trigger: GlobalTrigger) -> Bool {
        pressed.insert(trigger).inserted
    }

    /// Note un relâchement.
    ///
    /// - Returns: `true` si la fonction était bien tenue. `false` veut dire
    ///   qu'on n'a jamais vu son appui — un relâchement dont personne n'attend
    ///   la nouvelle, et qu'annoncer quand même fermerait une capture qui n'a
    ///   pas été ouverte par cette touche-là.
    public mutating func release(_ trigger: GlobalTrigger) -> Bool {
        pressed.remove(trigger) != nil
    }

    /// Oublie plusieurs fonctions d'un coup, **sans rien conclure**.
    ///
    /// Sert au seul cas où le relâchement n'est pas déduit d'une touche mais
    /// d'un changement de réglage : `releaseTriggersLosingTheirKey` retire tout
    /// le lot *avant* d'émettre le moindre signal, parce qu'un `onSignal` peut
    /// rentrer une seconde fois dans le même chemin. Retirer une par une au fil
    /// des signaux laisserait la réentrance trouver un ensemble à moitié plein.
    public mutating func subtract(_ triggers: [GlobalTrigger]) {
        pressed.subtract(triggers)
    }

    /// Tout oublier — le retrait du tap, où plus aucune touche ne sera suivie.
    public mutating func releaseEverything() {
        pressed.removeAll()
    }
}
