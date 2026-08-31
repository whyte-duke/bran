import Foundation

/// **Le débit d'une ligne, calculé loin de ce qui le mesure.**
///
/// ```
///   octets reçus ─┬─▶ tranches de 250 ms ─▶ rampe écartée ─▶ médiane ─▶ « 14,3 Mo/s »
///                 └─▶ dernière tranche close ─────────────────────────▶ l'aiguille
/// ```
///
/// **Ce fichier n'ouvre aucune connexion**, et c'est exactement le partage de
/// `ResourceReading` : là-bas la dérivée du temps processeur, ici la dérivée des
/// octets. Les deux ont des cas dégénérés qui produisent un chiffre faux au lieu
/// d'une panne visible, et les deux se testent sur des entiers, sans réseau et
/// sans horloge.
///
/// ## Ce qui a été mesuré, et pas supposé
///
/// Quatre décisions viennent d'une mesure faite sur la ligne du poste
/// (31/08/2026, ≈ 115 Mbit/s), et chacune corrige une méthode naïve qui rendait
/// un chiffre faux **sans jamais échouer** :
///
/// | Méthode naïve | Ce qu'elle a rendu | Pourquoi elle se trompe |
/// |---|---|---|
/// | `octets ÷ durée totale` | 8,9 Mo/s | le premier octet arrive jusqu'à **0,9 s** après la requête ; on divise par du temps où rien ne passait |
/// | compter dès le premier octet | 12,6 Mo/s | la montée en régime TCP prend **750 ms** — mesurée : 0,8 puis 5,0 puis 11,3 Mo/s sur les trois premières tranches, plateau à 14,3 |
/// | moyenne des tranches | 12,6 Mo/s | un creux passager mesuré à 2,1 Mo/s tire toute la moyenne, alors qu'il ne dit rien de la ligne |
/// | garder la dernière tranche | tire vers le bas | elle est **partielle** : on s'arrête au milieu d'un quart de seconde, et le quotient divise peu d'octets par 250 ms pleines |
///
/// D'où les quatre règles de ce fichier : on part **du premier octet**, on
/// **écarte la première seconde**, on prend la **médiane** des tranches, et
/// **jamais la dernière**.
///
/// ## Les creux comptent
///
/// Une tranche qui ne reçoit aucun octet vaut zéro, elle n'est pas absente. Un
/// dictionnaire ne fait pas la différence tout seul : ne compter que les clés
/// présentes reviendrait à effacer les décrochages, c'est-à-dire précisément ce
/// qu'on mesure quand on se demande si une visio va tenir. `rates` reconstruit
/// donc la suite complète, trous compris.
public struct SpeedTally: Equatable, Sendable {

    /// La largeur d'une tranche.
    ///
    /// 250 ms est le compromis mesuré : plus court, une seule bouffée TCP suffit
    /// à faire osciller une tranche du simple au double et la médiane devient
    /// nerveuse ; plus long, il ne reste que six ou sept tranches sur un test de
    /// quatre secondes et la médiane n'a plus assez de matière pour ignorer un
    /// creux. À 250 ms, un test de 4 s en fournit seize, dont douze après la
    /// rampe.
    public static let window: TimeInterval = 0.25

    /// Ce qu'on jette au début : **une seconde**, soit quatre tranches.
    ///
    /// Mesuré, pas choisi : la première tranche a rendu 0,8 Mo/s, la deuxième
    /// 5,0, la troisième 11,3, et le plateau — 14 à 15 — n'est atteint qu'à la
    /// quatrième. Écarter moins revient à publier la montée en régime de TCP
    /// comme si c'était la ligne.
    public static let rampWindows = 4

    /// Combien de tranches closes il faut **après la rampe** avant d'oser un
    /// chiffre. Une seconde de plateau.
    ///
    /// En dessous, `rate` rend `nil`, et c'est un état à part entière : « je ne
    /// sais pas encore » n'est pas « 0 Mo/s ». Même doctrine que
    /// `ResourceReading.cpuPercent`, et pour la même raison — un zéro affiché se
    /// lit comme une ligne morte.
    public static let minimumWindows = 4

    /// Les octets par tranche. Creusé de trous : voir `rates`.
    private var buckets: [Int: Int] = [:]

    /// L'indice de la tranche en cours de remplissage. `-1` tant que rien n'est
    /// arrivé.
    ///
    /// **C'est lui qui exclut la dernière tranche**, et c'est la raison pour
    /// laquelle il est mémorisé plutôt que recalculé : la tranche la plus haute
    /// qu'on ait vue est, par construction, celle qu'on est en train de remplir
    /// — ou celle où l'on s'est arrêté. Dans les deux cas elle est partielle.
    private var openIndex = -1

    public private(set) var totalBytes = 0

    public init() {}

    /// Verse des octets dans la tranche où ils sont arrivés.
    ///
    /// - Parameter elapsed: le temps écoulé **depuis le premier octet reçu**, et
    ///   non depuis l'envoi de la requête. C'est l'appelant qui tient cette
    ///   origine, parce que lui seul sait quand le premier octet est tombé ; ce
    ///   fichier n'a pas d'horloge.
    ///
    ///   Un `elapsed` négatif ne peut pas venir d'une horloge monotone, mais il
    ///   viendrait d'un appelant qui se tromperait d'origine — et il rangerait
    ///   les octets dans une tranche d'indice négatif, donc hors de la suite que
    ///   `rates` reconstruit : ils disparaîtraient du total sans que rien ne le
    ///   dise. Ils sont versés dans la première tranche, qui est de toute façon
    ///   écartée par la rampe.
    public mutating func accept(elapsed: TimeInterval, bytes: Int) {
        guard bytes > 0 else { return }
        let index = elapsed > 0 ? Int(elapsed / Self.window) : 0
        buckets[index, default: 0] += bytes
        openIndex = max(openIndex, index)
        totalBytes += bytes
    }

    /// Les débits des tranches **closes**, en octets par seconde, trous compris.
    ///
    /// Vide tant qu'aucune tranche n'est close — ce qui est le cas pendant les
    /// 250 premières millisecondes, et pendant tout un transfert plus court que
    /// ça.
    public var rates: [Double] {
        guard openIndex > 0 else { return [] }
        return (0..<openIndex).map { Double(buckets[$0] ?? 0) / Self.window }
    }

    /// Le débit publiable, en octets par seconde. `nil` tant qu'il n'y a pas
    /// assez de plateau pour en répondre.
    public var rate: Double? {
        let plateau = Array(rates.dropFirst(Self.rampWindows))
        guard plateau.count >= Self.minimumWindows else { return nil }
        return Self.median(plateau)
    }

    /// **Le débit moyen du plateau**, pour les transferts dont les tranches sont
    /// trop grossières pour qu'une médiane veuille dire quelque chose.
    ///
    /// C'est la lecture de la **montée**, et elle existe parce que la sonde a
    /// montré un défaut que la descente n'a pas. `didSendBodyData` ne rapporte
    /// pas les octets au fil de l'eau : URLSession les livre par blocs d'environ
    /// un mégaoctet. Sur des tranches de 250 ms, une tranche reçoit donc zéro,
    /// un, deux ou trois blocs — jamais autre chose — et les débits relevés
    /// tombaient tous sur des multiples de 4,2 Mo/s :
    ///
    /// ```
    ///   8,4  0,0  4,2  4,2  0,0  4,2  8,4  4,2  4,2  12,6  4,2  8,4
    /// ```
    ///
    /// Une médiane sur cette suite ne mesure pas la ligne, elle choisit un
    /// multiple : elle rendait 4,2 Mo/s là où l'intégrale du transfert en dit
    /// 5,8. Le remède n'est pas d'élargir les tranches — il faudrait des
    /// secondes entières, et il n'en resterait plus assez pour un test de
    /// quelques secondes — mais de renoncer à la médiane **là où elle n'a pas de
    /// matière**, et d'intégrer sur tout le plateau.
    ///
    /// **Ce qu'on perd en échange, et c'est assumé.** La médiane rejette un creux
    /// passager ; la moyenne l'absorbe. Sur une montée de quelques secondes c'est
    /// le bon arbitrage : un décrochage y est rare, et quand il arrive il *est*
    /// l'information — une ligne montante qui décroche n'est pas une ligne
    /// montante qui va bien.
    public var plateauMean: Double? {
        let plateau = Array(rates.dropFirst(Self.rampWindows))
        guard plateau.count >= Self.minimumWindows else { return nil }
        return plateau.reduce(0, +) / Double(plateau.count)
    }

    /// L'aiguille du compteur : la dernière tranche close.
    ///
    /// **Elle n'écarte pas la rampe**, contrairement à `rate`, et c'est
    /// délibéré : pendant la première seconde l'aiguille doit monter, sinon le
    /// compteur reste à zéro pendant le quart du test et donne l'impression que
    /// rien ne se passe. Ce qu'elle montre est vrai — c'est le débit instantané
    /// — ce n'est simplement pas la réponse à « combien fait ma ligne », et
    /// c'est `rate` qui répond à celle-là.
    public var live: Double? {
        rates.last
    }

    /// La médiane, écrite ici parce que `BranCore` ne dépend de rien.
    ///
    /// Sur un nombre pair de tranches, la moyenne des deux du milieu : prendre
    /// arbitrairement celle du bas ferait, sur les quatre tranches minimales,
    /// une préférence systématique pour le creux.
    static func median(_ values: [Double]) -> Double? {
        guard values.isEmpty == false else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }
}
