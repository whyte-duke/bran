import Foundation

/// **Ce que bran coûte**, calculé loin de ce qui le mesure.
///
/// ```
///   compteur CPU cumulé ─┐
///                        ├─▶ dérivée ─▶ médiane ─▶ « 2 » ─┐
///   Δt de WatchClock ────┘                                ├─▶ barre de menus
///   phys_footprint ────────▶ part de la RAM ─▶ « 2 » ─────┘
/// ```
///
/// **Pourquoi ce fichier n'appelle rien.** Le pourcentage processeur n'est pas
/// une lecture, c'est une **dérivée** : `Δ(temps CPU) / Δ(temps écoulé)`. Une
/// dérivée a des cas dégénérés — dénominateur nul, dénominateur négatif, pas de
/// point précédent — et chacun d'eux produit un affichage faux d'une manière
/// particulièrement coûteuse ici :
///
/// | Cas | Ce qu'on afficherait sans garde | Pourquoi c'est grave |
/// |---|---|---|
/// | `Δt == 0` | `NaN` | Un `NaN` dans la barre de menus, en permanence |
/// | `Δt < 0` | une valeur inventée | Un pic de 4 000 % au réveil |
/// | premier échantillon | `0 %` | « bran ne coûte rien », ce qui est faux |
/// | compteur qui recule | un pourcentage négatif | `-3 %` n'existe pas |
///
/// Tout cela se teste sur des entiers, sans noyau, sans écran et sans horloge.
/// Le fichier voisin `Sources/BranApp/Resources/ResourceProbe.swift` fait les
/// deux appels système et ne calcule rien.
///
/// **L'unité, et elle est décidée : celle du Moniteur d'activité, où
/// `100 % = un cœur`.** Le maximum est donc 1 200 % sur un M2 Pro à douze
/// cœurs. C'est tout l'intérêt : quand l'utilisateur ouvre le vrai Moniteur
/// d'activité pour recouper, les deux nombres coïncident. La lecture normalisée
/// sur le nombre de cœurs — celle qui répond à « ma machine est-elle saturée » —
/// est offerte par `cpuShare(cores:)` et s'affiche **à côté**, jamais à la
/// place : un « 104 % » tout seul se lirait comme une machine à genoux.
public struct ResourceReading: Equatable, Sendable {

    /// Convention Moniteur d'activité : `100 %` = un cœur pleinement occupé.
    /// `nil` veut dire **inconnu**, et c'est un état à part entière — voir le
    /// tableau ci-dessus, `0` serait un mensonge.
    public var cpuPercent: Double?

    /// L'empreinte mémoire du processus, en octets. `phys_footprint`, c'est-à-dire
    /// exactement ce que le Moniteur d'activité appelle « Mémoire ».
    public var memoryBytes: UInt64?

    /// Part de la mémoire physique de la machine, en pourcentage.
    public var memoryPercent: Double?

    public init(
        cpuPercent: Double? = nil,
        memoryBytes: UInt64? = nil,
        memoryPercent: Double? = nil
    ) {
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.memoryPercent = memoryPercent
    }

    /// Rien n'a encore été mesuré. **Distinct de « tout est à zéro ».**
    public static let unknown = ResourceReading()

    /// La même occupation processeur, mais rapportée à la machine entière.
    ///
    /// C'est le nombre qui répond à la question posée — « la surveillance de mon
    /// PC au repos, c'est 2 % de mon processeur, c'est ok » — alors que
    /// `cpuPercent` répond à « est-ce que je vois la même chose que le Moniteur
    /// d'activité ». Les deux sont vrais, ils ne disent simplement pas la même
    /// chose, et c'est pour ça qu'ils sont affichés côte à côte.
    ///
    /// Un nombre de cœurs nul ou négatif ne peut pas venir du système, mais
    /// `activeProcessorCount` est un `Int` : diviser sans regarder rendrait un
    /// infini au premier jour où Apple renvoie 0 sur une machine en veille.
    public func cpuShare(cores: Int) -> Double? {
        guard let cpuPercent, cores > 0 else { return nil }
        return cpuPercent / Double(cores)
    }
}

// MARK: - L'arithmétique

/// Les deux seules formules du moniteur, isolées pour que leurs cas dégénérés
/// soient visibles et testés un par un.
public enum ResourceMath {

    /// La dérivée. `nil` quand elle n'a pas de sens.
    ///
    /// Le delta arrive déjà en `UInt64` — donc jamais négatif — parce que c'est
    /// l'appelant qui a borné le recul du compteur ; voir `ResourceTracker`.
    ///
    /// **`elapsed <= 0` rend `nil` et non zéro.** Zéro se lirait « bran n'a rien
    /// consommé pendant cet intervalle », alors que la vérité est « on ne sait
    /// pas combien de temps s'est écoulé ».
    public static func cpuPercent(deltaNanoseconds: UInt64, elapsed: TimeInterval) -> Double? {
        guard elapsed > 0, elapsed.isFinite else { return nil }
        return Double(deltaNanoseconds) / 1e9 / elapsed * 100
    }

    /// La part de mémoire physique occupée, bornée à 100.
    ///
    /// **Le bornage n'est pas décoratif.** La comptabilité mémoire de macOS est
    /// compressée : `phys_footprint` inclut des pages compressées et des pages
    /// facturées à ce processus mais partagées, et la somme peut dépasser la
    /// mémoire physique installée. « 103 % de la RAM » est un affichage qui
    /// détruit la confiance dans tout le reste du panneau.
    ///
    /// Un total nul veut dire que le système n'a pas répondu : **inconnu**, pas
    /// zéro, et surtout pas une division par zéro.
    public static func memoryPercent(footprint: UInt64, total: UInt64) -> Double? {
        guard total > 0 else { return nil }
        return min(100, Double(footprint) / Double(total) * 100)
    }

    /// Convertit un temps processeur en **nanosecondes**, depuis les unités que
    /// le noyau rend réellement.
    ///
    /// **Le bug que cette fonction répare, et pourquoi aucun test ne l'a vu.**
    /// `ri_user_time` et `ri_system_time` de `proc_pid_rusage` sont documentés
    /// « nanoseconds » et ne le sont pas : sur Apple Silicon ils comptent des
    /// **unités de `mach_absolute_time`**. Mesuré sur cette machine, en brûlant
    /// une seconde de mur sur un seul fil :
    ///
    /// ```
    ///   mur           1 000 000 083 ns
    ///   delta rusage     23 996 610
    ///   ratio                 0,024      ← soit exactement 1/41,67
    ///   timebase mach       125/3 = 41,67 ns par unité
    /// ```
    ///
    /// Le moniteur sous-estimait donc le processeur d'un facteur **24** : un
    /// chargement de Parakeet qui occupe un cœur entier s'affichait à 4 % au lieu
    /// de 100 %. C'est-à-dire précisément l'événement que l'instrument existe
    /// pour montrer, rendu invisible par l'instrument lui-même.
    ///
    /// Les tests de `cpuPercent` ne pouvaient rien y faire : ils vérifient
    /// l'arithmétique **en supposant** des nanosecondes. Le défaut vivait à la
    /// frontière entre le noyau et le calcul, là où il n'y avait rien. D'où cette
    /// fonction, qui est pure et donc testable, plutôt qu'une multiplication
    /// enfouie dans la sonde.
    ///
    /// `numer` et `denom` viennent de `mach_timebase_info`. Sur Intel ils valent
    /// 1/1 et cette fonction est l'identité — ce qui explique que le défaut ait
    /// pu survivre : il n'existe pas sur les machines où ce code a été écrit à
    /// l'origine.
    public static func nanoseconds(
        machTicks: UInt64,
        numer: UInt32,
        denom: UInt32
    ) -> UInt64? {
        guard denom > 0, numer > 0 else { return nil }
        // Le produit peut déborder pour des compteurs absurdes ; un moniteur n'a
        // pas le droit de tuer ce qu'il observe.
        let (product, overflowed) = machTicks.multipliedReportingOverflow(by: UInt64(numer))
        guard overflowed == false else { return nil }
        return product / UInt64(denom)
    }
}

// MARK: - La fenêtre glissante

/// Une médiane sur les `capacity` dernières valeurs.
///
/// **Pourquoi une médiane et pas une moyenne.** L'instantané saute : un tic où
/// une capture d'écran du veilleur tombe dans l'intervalle affiche 30 % là où
/// les voisins affichent 2 %. Une moyenne traîne cet unique tic pendant toute la
/// fenêtre ; une médiane le jette purement et simplement.
///
/// **Pourquoi trois échantillons, et pas cinq.** À la cadence de 2 s, cinq
/// échantillons font dix secondes de retard : un chargement de Parakeet qui dure
/// six secondes serait *entièrement* absorbé par le lissage — c'est-à-dire que
/// l'instrument raterait précisément l'événement pour lequel l'utilisateur l'a
/// demandé (« savoir quand il importe / active le modèle »). Trois échantillons
/// suffisent à supprimer un pic isolé, coûtent quatre secondes pour suivre un
/// vrai palier, et laissent passer tout ce qui dure plus de deux tics.
///
/// L'arbitrage est donc explicite : **on préfère un chiffre un peu nerveux à un
/// chiffre qui ment par omission.**
public struct SlidingMedian: Equatable, Sendable {

    public let capacity: Int
    public private(set) var samples: [Double] = []

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    public mutating func push(_ value: Double) {
        // Un `NaN` entré ici contaminerait le tri lui-même : `NaN < x` et
        // `x < NaN` sont tous deux faux, et l'ordre obtenu dépendrait alors de
        // l'algorithme de tri. On refuse à la porte.
        guard value.isFinite else { return }
        samples.append(value)
        if samples.count > capacity { samples.removeFirst(samples.count - capacity) }
    }

    /// La médiane de ce qu'on a. **Une fenêtre partielle répond quand même** :
    /// attendre trois tics avant d'afficher quoi que ce soit ferait passer six
    /// secondes de « — » à chaque lancement, ce qui ressemble à une panne.
    ///
    /// Une fenêtre vide, elle, rend `nil` : c'est le cas « rien n'a encore été
    /// mesuré », pas le cas « zéro ».
    public var value: Double? {
        guard samples.isEmpty == false else { return nil }
        let sorted = samples.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    public mutating func forget() {
        samples.removeAll(keepingCapacity: true)
    }
}

// MARK: - Le suivi

/// L'état du moniteur entre deux échantillons : le compteur CPU précédent et la
/// fenêtre de lissage.
///
/// **Il ne connaît ni l'horloge ni le noyau, et c'est délibéré.** `elapsed` et
/// `clockJumped` viennent de `WatchClock.Step` (cible `BranWatch`), qui détecte
/// déjà la veille via `SuspendingClock` — le dépôt a payé ce bogue une fois sur
/// les durées du veilleur (correctif CR-2), il n'y aura pas de second détecteur.
/// Ils arrivent ici sous forme de nombres plutôt que par un `import BranWatch`
/// parce que `BranCore` est la cible de base : la faire dépendre du veilleur
/// pour lire un `Bool` inverserait l'empilement pour rien.
public struct ResourceTracker: Sendable {

    /// Trois échantillons, soit six secondes de fenêtre à la cadence de 2 s.
    /// Voir `SlidingMedian` pour l'arbitrage.
    public static let medianWindow = 3

    public private(set) var reading: ResourceReading = .unknown

    /// Le compteur cumulé du tic précédent. `nil` = aucun point de référence,
    /// donc aucune dérivée possible.
    private var previousCPU: UInt64?
    private var median: SlidingMedian

    public init(window: Int = ResourceTracker.medianWindow) {
        self.median = SlidingMedian(capacity: window)
    }

    /// Prend un échantillon et rend la lecture publiable.
    ///
    /// - Parameters:
    ///   - cpuNanoseconds: `ri_user_time + ri_system_time`, **cumulé depuis le
    ///     lancement du processus**. C'est un compteur, pas une mesure.
    ///   - footprintBytes: `phys_footprint`, instantané.
    ///   - totalMemoryBytes: `ProcessInfo.physicalMemory`.
    ///   - elapsed: `WatchClock.Step.elapsed` — le temps écoulé **hors veille**.
    ///   - clockJumped: `WatchClock.Step.jumped`.
    @discardableResult
    public mutating func accept(
        cpuNanoseconds: UInt64,
        footprintBytes: UInt64,
        totalMemoryBytes: UInt64,
        elapsed: TimeInterval,
        clockJumped: Bool = false
    ) -> ResourceReading {
        // La mémoire est un niveau, pas une dérivée : elle est valide dès le
        // premier échantillon, elle survit à un réveil, et elle n'est pas
        // lissée. Lisser un niveau retarderait de six secondes le palier de
        // +500 Mo que Parakeet fait apparaître — l'événement même qu'on veut
        // voir.
        reading.memoryBytes = footprintBytes
        reading.memoryPercent = ResourceMath.memoryPercent(
            footprint: footprintBytes,
            total: totalMemoryBytes
        )

        // Le réveil de veille. Le compteur CPU, lui, a continué de compter le
        // temps *processeur*, qui n'avance pas pendant la veille — mais
        // l'intervalle, lui, est ininterprétable, et le premier tic après un
        // réveil est justement celui où le système relance tout le monde d'un
        // coup. On jette, et on repart d'inconnu.
        if clockJumped {
            previousCPU = cpuNanoseconds
            median.forget()
            reading.cpuPercent = nil
            return reading
        }

        // Deux échantillons au même instant. Le dénominateur est nul : la seule
        // réponse acceptable est celle d'avant, jamais un `NaN`. Et le compteur
        // de référence n'est **pas** remplacé : au tic suivant, la dérivée se
        // calculera sur l'intervalle complet plutôt que sur un intervalle
        // amputé.
        if elapsed == 0, previousCPU != nil {
            return reading
        }

        // Saut d'horloge à l'envers, ou durée absurde. On ne sait pas sur quelle
        // durée rapporter le travail : on le dit.
        guard elapsed > 0, elapsed.isFinite else {
            previousCPU = cpuNanoseconds
            median.forget()
            reading.cpuPercent = nil
            return reading
        }

        guard let previous = previousCPU else {
            // Premier échantillon. Aucune dérivée n'existe encore — et surtout
            // pas « 0 % », qui se lirait « bran ne coûte rien ».
            previousCPU = cpuNanoseconds
            reading.cpuPercent = nil
            return reading
        }

        // Un compteur cumulé ne recule pas. S'il recule quand même — compteur
        // remis à zéro, lecture partielle du noyau — la soustraction en `UInt64`
        // déborderait vers 18 milliards de milliards. Borné à zéro.
        let delta = cpuNanoseconds >= previous ? cpuNanoseconds - previous : 0
        previousCPU = cpuNanoseconds

        if let instant = ResourceMath.cpuPercent(deltaNanoseconds: delta, elapsed: elapsed) {
            median.push(instant)
        }
        reading.cpuPercent = median.value
        return reading
    }

    /// Oublie le point de référence et la fenêtre, sans oublier la mémoire.
    /// Appelé quand le moniteur est éteint puis rallumé : la dérivée qui
    /// enjamberait la pause serait calculée sur un intervalle qui n'a jamais été
    /// observé.
    public mutating func forget() {
        previousCPU = nil
        median.forget()
        reading.cpuPercent = nil
    }
}

// MARK: - Le formatage

/// **Le formatage compte autant que le calcul.** Un pourcentage juste rendu
/// « 0 » est un affichage faux ; un libellé qui change de largeur à chaque pic
/// pousse l'horloge du système et se fait désinstaller en trois jours.
public enum ResourceFormat {

    /// Ce qu'on affiche quand on ne sait pas. **Jamais « 0 ».**
    public static let unknown = "—"

    /// U+2007 FIGURE SPACE : par définition la largeur d'un chiffre. C'est elle,
    /// et non `.monospacedDigit()`, qui garantit la largeur du libellé — le
    /// modificateur de police n'est pas toujours honoré sur l'élément de barre
    /// de menus, le contenu de la chaîne l'est toujours.
    public static let figureSpace = "\u{2007}"

    /// La locale est **fixée**, pas héritée.
    ///
    /// Toute l'interface de bran est écrite en français en dur ; un séparateur
    /// décimal qui suivrait la région du Mac afficherait « 6.7 % » au milieu de
    /// phrases françaises. Accessoirement, c'est ce qui rend les tests
    /// indépendants de la machine qui les exécute.
    public static let locale = Locale(identifier: "fr_FR")

    // MARK: Pourcentages

    /// Un pourcentage entier, sans son signe `%`.
    ///
    /// Trois règles, chacune payée par un affichage faux :
    /// - `nil` ou non fini → `—`. On ne sait pas, on le dit.
    /// - sous 1 % → `<1`, **jamais `0`**. « 0 % » se lit « bran ne coûte rien ».
    /// - au-delà de 100 → tel quel. 104 % est légitime : c'est un cœur et des
    ///   poussières, pas une machine saturée.
    public static func percent(_ value: Double?) -> String {
        guard let value, value.isFinite else { return unknown }
        let clamped = max(0, value)
        if clamped < 1 { return "<1" }
        // `.grouping(.never)` : au-delà de mille, le séparateur de milliers
        // français est une espace fine — « 1 200 » dans un libellé de barre de
        // menus se lit comme deux nombres.
        return clamped.rounded().formatted(
            .number.precision(.fractionLength(0)).grouping(.never).locale(locale)
        )
    }

    /// Le même, suivi de son signe. Espace insécable : « 104 » et « % » ne se
    /// séparent pas en fin de ligne.
    public static func percentSigned(_ value: Double?) -> String {
        let text = percent(value)
        return text == unknown ? unknown : "\(text)\u{202F}%"
    }

    /// La lecture normalisée, celle du menu déroulant : une décimale, et pas de
    /// `,0` inutile. « 0,2 % des 12 cœurs » et « 2 % des 16 Go ».
    /// La part de la machine entière. **Même doctrine que `percent` : jamais
    /// « 0 ».**
    ///
    /// bran au repos occupe 4 % d'un cœur, soit 0,33 % de douze cœurs. Arrondi à
    /// une décimale ça passe encore, mais un dixième de moins et la ligne du menu
    /// devenait « Processeur <1 % · 0 % des 12 cœurs » : la colonne de gauche dit
    /// « trop petit pour être dit », celle de droite dit « rien ». Or c'est
    /// précisément la ligne qu'on lit pour décider si on garde l'application.
    public static func share(_ value: Double?) -> String {
        guard let value, value.isFinite else { return unknown }
        // Même doctrine que `percent`, et elle manquait ici : un arrondi qui
        // rend « 0 » dit « rien », alors que la mesure dit « trop petit pour
        // être écrit ». Sur la même ligne du menu, la colonne de gauche disait
        // déjà « <1 » — deux réponses contradictoires à la même question.
        if value > 0, value < 0.05 { return "<0,1\u{202F}%" }
        let text = max(0, value).formatted(
            .number.precision(.fractionLength(0...1)).locale(locale)
        )
        return "\(text)\u{202F}%"
    }

    // MARK: Octets

    /// L'empreinte du processus, en base 10 — c'est la convention du Moniteur
    /// d'activité, et recouper est tout l'objet de ce panneau.
    public static func bytes(_ value: UInt64?) -> String {
        guard let value else { return unknown }
        return value.formatted(.byteCount(style: .file).locale(locale))
    }

    /// La mémoire installée, en base 2 — « 16 Go » et non « 17,18 Go ».
    ///
    /// **Oui, ce n'est pas la même base que `bytes(_:)`, et c'est volontaire.**
    /// C'est le mélange qu'Apple fait elle-même : « À propos de ce Mac » annonce
    /// 16 Go (base 2), le Moniteur d'activité affiche 335 Mo (base 10). Écrire
    /// « des 17,18 Go » serait exact et pourtant illisible, puisque personne
    /// n'appelle sa machine comme ça. Le pourcentage, lui, est calculé sur les
    /// octets bruts : aucune des deux mises en forme ne le touche.
    public static func installedMemory(_ value: UInt64?) -> String {
        guard let value else { return unknown }
        return value.formatted(.byteCount(style: .memory).locale(locale))
    }

    // MARK: Le libellé de la barre de menus

    /// Largeur réservée au processeur, en chiffres.
    ///
    /// Trois : de `<1` à `999`. Le maximum théorique est 1 200 % — les douze
    /// cœurs pris par bran seul — mais réserver un quatrième chiffre coûterait
    /// une largeur permanente dans la barre de menus pour couvrir un cas qui
    /// signifierait de toute façon que quelque chose de bien plus grave est en
    /// train de se passer. Au-delà de 999, le libellé s'élargit d'un caractère,
    /// et cet élargissement est alors lui-même une information.
    public static let cpuDigits = 3

    /// Largeur réservée à la mémoire, en chiffres. Trois aussi : `memoryPercent`
    /// est borné à 100, qui en fait trois.
    public static let memoryDigits = 3

    /// Le séparateur. Un point médian, pas un slash : `/` se lit comme une
    /// division, et « 2/2 » ressemble à « 2 sur 2 ».
    public static let separator = "·"

    /// Le libellé complet : `2·2` au repos, `104·11` quand Parakeet charge, et
    /// **toujours la même largeur** grâce au remplissage en espaces-chiffres.
    public static func menuBarLabel(cpu: Double?, memory: Double?) -> String {
        pad(percent(cpu), to: cpuDigits)
            + separator
            + pad(percent(memory), to: memoryDigits)
    }

    /// Complète à gauche, avec des espaces de la largeur d'un chiffre.
    private static func pad(_ text: String, to width: Int) -> String {
        let missing = width - text.count
        guard missing > 0 else { return text }
        return String(repeating: figureSpace, count: missing) + text
    }
}

// MARK: - La porte du libellé

/// **Ne redessine la barre de menus que si la chaîne a changé.**
///
/// Au repos, « 2·2 » reste « 2·2 » d'un échantillon à l'autre : environ quatre
/// mises à jour sur cinq n'ont rien à annoncer. Les laisser passer ferait
/// invalider l'élément de barre de menus toutes les deux secondes pour
/// réafficher les mêmes pixels — un moniteur qui coûte ce qu'il mesure est une
/// farce, et celui-ci a le mauvais goût de l'écrire en gros à côté.
public struct LabelGate: Sendable {

    /// La dernière chaîne réellement publiée. `nil` tant que rien ne l'a été,
    /// ce qui garantit que la toute première valeur passe.
    public private(set) var published: String?

    public init() {}

    /// Rend `true` si la chaîne est nouvelle — c'est-à-dire s'il y a quelque
    /// chose à redessiner.
    public mutating func offer(_ label: String) -> Bool {
        guard label != published else { return false }
        published = label
        return true
    }
}
