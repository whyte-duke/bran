import Foundation

/// **Quand a-t-on le droit de relancer une mesure**, et pourquoi ce n'est pas
/// une simple soustraction.
///
/// Le délai n'existe pas pour économiser les octets — le plafond de
/// `SpeedPlan.Budget` s'en charge — mais parce que **les services de mesure
/// limitent le débit de requêtes**. Cloudflare a refusé toute requête de plus de
/// 5 Mo pendant plus de vingt minutes après une rafale d'essais. Un bouton qu'on
/// peut mitrailler finit donc par afficher une panne que bran a lui-même
/// provoquée, sur une ligne qui va parfaitement bien — le pire message d'erreur
/// possible, puisqu'il accuse le mauvais coupable.
///
/// ## Les deux façons de finir, et elles ne comptent pas pareil
///
/// C'est toute la raison d'être de ce type, et le défaut qu'il ferme.
///
/// | Ce qui se passe | Estampille ? | Pourquoi |
/// |---|---|---|
/// | La mesure va au bout | oui | des dizaines de requêtes sont parties |
/// | La mesure est interrompue | oui | les neuf sondes de latence partent dans la première seconde |
/// | Un résultat déjà affiché est chassé | **non** | rien ne part sur le réseau |
///
/// La troisième ligne manquait. La croix du panneau sert aux deux derniers
/// gestes, et estampiller sans regarder repoussait le délai de trente secondes
/// **à partir du clic** : plus on refermait vite le panneau — c'est-à-dire plus
/// on était pressé — plus on attendait avant de pouvoir remesurer. La punition
/// tombait exactement à l'envers, et rien à l'écran ne l'expliquait.
public struct SpeedGate: Equatable, Sendable {

    /// La fin de la dernière chose qui a réellement parlé au réseau. `nil` tant
    /// qu'aucune mesure n'a été lancée — auquel cas on peut y aller.
    public private(set) var lastReached: Date?

    public init(lastReached: Date? = nil) {
        self.lastReached = lastReached
    }

    /// Une mesure est allée au bout, ou a échoué après avoir émis.
    public mutating func reached(at instant: Date) {
        lastReached = instant
    }

    /// Quelque chose a été interrompu.
    ///
    /// - Parameter wasMeasuring: la mesure tournait-elle ? C'est **le** paramètre
    ///   du type. `false` veut dire qu'on a seulement refermé un panneau, donc
    ///   qu'aucune requête n'est partie, donc qu'il n'y a rien à faire payer.
    public mutating func interrupted(wasMeasuring: Bool, at instant: Date) {
        guard wasMeasuring else { return }
        lastReached = instant
    }

    /// Peut-on lancer une mesure ?
    public func allows(at instant: Date) -> Bool {
        remaining(at: instant) == nil
    }

    /// Combien de secondes entières il reste à attendre. `nil` quand on peut y
    /// aller.
    ///
    /// Arrondi **au supérieur** : afficher « 0 s » sur un bouton encore éteint
    /// serait la seule chose que ce compte à rebours ne doit pas faire.
    ///
    /// Une date future — l'horloge du Mac remise en arrière, un changement
    /// d'heure — rendrait un délai plus long que le délai lui-même, donc un
    /// bouton éteint pour un temps arbitraire. On le borne : au pire, on attend
    /// le délai nominal.
    public func remaining(at instant: Date) -> Int? {
        guard let lastReached else { return nil }
        let elapsed = min(max(0, instant.timeIntervalSince(lastReached)), SpeedPlan.cooldown)
        let left = SpeedPlan.cooldown - elapsed
        return left > 0 ? Int(left.rounded(.up)) : nil
    }
}
