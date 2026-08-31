import Foundation

/// **La latence et la gigue**, calculées sur des allers-retours déjà chronométrés.
///
/// ```
///   8 requêtes minuscules ─▶ [70, 82, 65, 96, 72, 108, 67, 69] ms
///                              │                    │
///                        médiane ─▶ 71 ms      écarts successifs ─▶ gigue 24 ms
/// ```
///
/// **Ce n'est pas un `ping`.** Un vrai ICMP demande une socket brute, donc des
/// privilèges que bran n'a pas et ne demandera pas pour afficher un nombre à
/// trois chiffres. Ce qui est mesuré ici est l'aller-retour **applicatif** :
/// requête HTTP minuscule, réponse minuscule, sur une connexion déjà ouverte.
/// C'est un peu plus que l'ICMP — il y a une pile TLS et un serveur au bout —
/// et c'est aussi ce qui compte réellement : personne ne fait de visio en ICMP.
///
/// ## La gigue, et pourquoi c'est la bonne définition
///
/// La gigue n'est pas l'écart-type des latences, c'est la moyenne des **écarts
/// entre mesures consécutives** — la convention de la RFC 3550, celle
/// qu'affichent les compteurs grand public. La différence n'est pas
/// académique : une ligne qui monte lentement de 60 à 120 ms a un gros
/// écart-type et une gigue nulle, et c'est la gigue qui a raison — une visio
/// n'entend pas une dérive lente, elle entend les sauts.
///
/// ## La première sonde est jetée, et il a fallu se tromper pour le savoir
///
/// Elle ne l'était pas. Cinq séries de huit sondes avaient été relevées **avec
/// `curl`** (31/08/2026) : les premières valeurs étaient 97, 62, 73, 65 et
/// 80 ms, pour des médianes de série comprises entre 68 et 72 ms. Aucun biais
/// visible, donc aucune raison d'écarter un échantillon sur huit.
///
/// La mesure était juste et la conclusion fausse, parce que `curl` ne mesure pas
/// la même chose : **chaque invocation est un processus neuf qui rouvre sa
/// propre connexion**, donc les huit sondes payaient la poignée de main, et
/// aucune ne se distinguait. URLSession, lui, garde la connexion ouverte : seule
/// la première paie la résolution DNS et TLS. La sonde intégrée l'a montré du
/// premier coup, et deux fois de suite :
///
/// ```
///   200  29  27  27  111  27  29  28   ms
///   229  32  34  31   30  28  31  31   ms
/// ```
///
/// La médiane s'en moquait — 28 ms dans les deux cas — mais **la gigue était
/// détruite** : 49 ms annoncés sur une ligne dont les écarts réels tournent
/// autour de 2 ms, parce que le saut de 200 à 29 compte pour un septième de la
/// moyenne des écarts. Une ligne saine était présentée comme instable.
///
/// D'où la règle actuelle : **la première sonde est retirée**, et on en tire
/// neuf pour qu'il en reste huit. Ce qu'elle mesurait — l'ouverture d'une
/// connexion — est une vraie durée, simplement pas celle qu'on affiche.
public struct SpeedLatency: Equatable, Sendable {

    /// Combien d'allers-retours on **tire**. Neuf, pour qu'il en reste huit une
    /// fois la première retirée — voir l'en-tête.
    ///
    /// Huit tient en moins d'une seconde sur une ligne à 30 ms, et donne sept
    /// écarts successifs : assez pour que la gigue veuille dire quelque chose,
    /// sans allonger un test qu'on a demandé rapide.
    public static let probeCount = 9

    /// La première, celle qui porte DNS et TLS.
    public static let warmupCount = 1

    public private(set) var samples: [TimeInterval] = []

    public init() {}

    public init(samples: [TimeInterval]) {
        self.samples = samples.filter { $0.isFinite && $0 >= 0 }
    }

    /// Une sonde de plus. Les valeurs non finies et négatives sont refusées :
    /// elles ne peuvent venir que d'une horloge cassée, et une seule suffirait à
    /// empoisonner la moyenne des écarts.
    ///
    /// **Tout est conservé, y compris l'ouverture de connexion.** Le retrait se
    /// fait à la lecture, pas à l'écriture : `samples` reste ce qui a été
    /// réellement mesuré, ce que la sonde en ligne de commande affiche tel quel,
    /// et ce sur quoi on peut revenir le jour où la première valeur intéresse
    /// quelqu'un.
    public mutating func accept(_ roundTrip: TimeInterval) {
        guard roundTrip.isFinite, roundTrip >= 0 else { return }
        samples.append(roundTrip)
    }

    /// Les sondes qui comptent : toutes sauf l'ouverture de connexion.
    ///
    /// Le retrait n'a lieu que s'il **reste** quelque chose : sur une ligne qui
    /// n'a répondu qu'une fois, une mesure imparfaite vaut mieux qu'un « — ».
    public var settled: [TimeInterval] {
        samples.count > Self.warmupCount ? Array(samples.dropFirst(Self.warmupCount)) : samples
    }

    /// La latence publiable, en secondes. `nil` tant qu'il n'y a rien.
    ///
    /// **La médiane, pas le minimum.** Les compteurs qui affichent le minimum
    /// annoncent le meilleur cas d'un réseau, ce qui flatte la ligne et ne
    /// décrit aucune seconde vécue. La médiane décrit la moitié des paquets.
    public var latency: TimeInterval? {
        SpeedTally.median(settled)
    }

    /// La gigue, en secondes. `nil` sous deux sondes — il n'y a pas d'écart
    /// entre une mesure et elle-même.
    public var jitter: TimeInterval? {
        let usable = settled
        guard usable.count >= 2 else { return nil }
        let steps = zip(usable, usable.dropFirst()).map { abs($1 - $0) }
        return steps.reduce(0, +) / Double(steps.count)
    }
}
