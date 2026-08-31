import Foundation

/// **Un relevé de débit**, tel qu'il s'affiche et tel qu'il se conserve.
///
/// Les quatre nombres sont indépendamment optionnels, et c'est le point du type :
/// un test peut très bien réussir sa descente et échouer sa montée — le serveur
/// de montée est un autre hôte, avec ses propres pannes et sa propre limite de
/// débit. Un enregistrement qui exigerait les quatre obligerait à jeter trois
/// mesures bonnes à cause d'une quatrième.
public struct SpeedReading: Equatable, Sendable, Codable {

    /// Octets par seconde. `nil` = pas mesuré, jamais « zéro ».
    public var download: Double?
    public var upload: Double?

    /// Secondes.
    public var latency: TimeInterval?
    public var jitter: TimeInterval?

    /// D'où venaient les octets, en clair : « OVH — Roubaix ». Affiché parce
    /// qu'un débit sans son point de mesure ne se compare à rien, et que la
    /// première question devant un chiffre décevant est « contre quoi ? ».
    public var source: String?

    public var measuredAt: Date?

    /// Combien d'octets le test a consommés. **Affiché**, pas seulement compté :
    /// c'est la contrepartie honnête d'une fonction qui télécharge des dizaines
    /// de mégaoctets sur commande, et quelqu'un en partage de connexion a le
    /// droit de le savoir avant de recliquer.
    public var spentBytes: Int = 0

    public init(
        download: Double? = nil,
        upload: Double? = nil,
        latency: TimeInterval? = nil,
        jitter: TimeInterval? = nil,
        source: String? = nil,
        measuredAt: Date? = nil,
        spentBytes: Int = 0
    ) {
        self.download = download
        self.upload = upload
        self.latency = latency
        self.jitter = jitter
        self.source = source
        self.measuredAt = measuredAt
        self.spentBytes = spentBytes
    }

    /// Rien de mesurable n'a été obtenu. Un test qui finit là est un échec, même
    /// s'il n'a levé aucune erreur.
    public var isEmpty: Bool {
        download == nil && upload == nil && latency == nil
    }

    // MARK: - Relecture

    /// **Écrit à la main pour une seule ligne : `spentBytes`.**
    ///
    /// Tous les autres champs sont optionnels, donc un enregistrement écrit par
    /// une version plus ancienne se relit tout seul — une clé absente devient
    /// `nil`. `spentBytes` ne l'est pas, et le décodeur que Swift synthétise
    /// **échoue** sur une clé manquante même quand la propriété a une valeur par
    /// défaut. La lecture passant par un `try?`, l'échec serait silencieux : le
    /// dernier relevé disparaîtrait à la mise à jour suivante, sans message, et
    /// la seule façon de le récupérer serait de redépenser cent mégaoctets.
    ///
    /// C'est une classe de défaut, pas un cas : le prochain champ non optionnel
    /// ajouté ici la rouvrirait. `decodeIfPresent` la ferme une fois pour toutes.
    public init(from decoder: any Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        download = try box.decodeIfPresent(Double.self, forKey: .download)
        upload = try box.decodeIfPresent(Double.self, forKey: .upload)
        latency = try box.decodeIfPresent(TimeInterval.self, forKey: .latency)
        jitter = try box.decodeIfPresent(TimeInterval.self, forKey: .jitter)
        source = try box.decodeIfPresent(String.self, forKey: .source)
        measuredAt = try box.decodeIfPresent(Date.self, forKey: .measuredAt)
        spentBytes = try box.decodeIfPresent(Int.self, forKey: .spentBytes) ?? 0
    }
}

/// Comment ces nombres s'écrivent. Même doctrine que `ResourceFormat`, dont ce
/// type est le voisin : locale française **fixée** — l'interface de bran est en
/// français en dur, un séparateur décimal qui suivrait la région du Mac
/// afficherait « 14.3 Mo/s » au milieu de phrases françaises — et « — » quand on
/// ne sait pas, jamais « 0 ».
public enum SpeedFormat {

    public static let unknown = ResourceFormat.unknown
    public static let locale = ResourceFormat.locale

    /// **Le mégaoctet vaut 10⁶ octets ici, et c'est un choix.**
    ///
    /// bran écrit ailleurs la mémoire en base 2 (« 16 Go » de RAM) parce que
    /// c'est ainsi que le matériel se vend. Un débit se vend dans l'autre
    /// convention : l'offre est en mégabits décimaux, et diviser par 1 048 576
    /// afficherait 13,6 là où le fournisseur promet 14,3. L'écart de 4,9 % se
    /// remarque, et il se remarque **du mauvais côté** — celui qui fait croire
    /// qu'on ne reçoit pas ce qu'on paie.
    public static let bytesPerMegabyte: Double = 1_000_000

    /// Le chiffre principal : des mégaoctets par seconde, une décimale.
    ///
    /// Une décimale et pas deux : la ligne a été mesurée entre 11,3 et 15,5 Mo/s
    /// sur quatre relevés du même quart d'heure. Le deuxième chiffre après la
    /// virgule décrirait une précision que la ligne n'a pas.
    public static func megabytes(_ bytesPerSecond: Double?) -> String {
        guard let bytesPerSecond, bytesPerSecond.isFinite, bytesPerSecond >= 0 else { return unknown }
        let value = bytesPerSecond / bytesPerMegabyte
        // Sous un dixième de Mo/s on ne dit pas « 0,0 » : c'est une ligne très
        // lente, pas une ligne morte. Même règle que `ResourceFormat.percent`.
        if value > 0, value < 0.05 { return "<0,1" }
        return value.formatted(.number.precision(.fractionLength(1)).locale(locale))
    }

    /// Le chiffre principal **avec son unité**, pour les endroits qui n'ont pas
    /// de libellé séparé. Espace insécable étroite : « 14,3 » et « Mo/s » ne se
    /// séparent pas en fin de ligne.
    public static func megabytesSigned(_ bytesPerSecond: Double?) -> String {
        let text = megabytes(bytesPerSecond)
        return text == unknown ? unknown : "\(text)\u{202F}Mo/s"
    }

    /// L'unité du fournisseur d'accès, affichée **à côté** et jamais à la place.
    ///
    /// C'est la même règle que `ResourceReading.cpuShare` : deux unités disent
    /// deux choses vraies, et les afficher côte à côte évite la conversion
    /// mentale par huit qui est la source d'à peu près toutes les disputes avec
    /// un fournisseur d'accès.
    public static func megabits(_ bytesPerSecond: Double?) -> String {
        guard let bytesPerSecond, bytesPerSecond.isFinite, bytesPerSecond >= 0 else { return unknown }
        let value = bytesPerSecond * 8 / bytesPerMegabyte
        if value > 0, value < 0.5 { return "<1\u{202F}Mbit/s" }
        let text = value.rounded().formatted(
            .number.precision(.fractionLength(0)).grouping(.never).locale(locale)
        )
        return "\(text)\u{202F}Mbit/s"
    }

    /// Une durée d'aller-retour, en millisecondes entières. Sous la
    /// milliseconde, « <1 » — une latence nulle n'existe pas.
    public static func milliseconds(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return unknown }
        let value = seconds * 1000
        if value > 0, value < 0.5 { return "<1\u{202F}ms" }
        let text = value.rounded().formatted(
            .number.precision(.fractionLength(0)).grouping(.never).locale(locale)
        )
        return "\(text)\u{202F}ms"
    }

    /// Ce que le test a consommé. En base 10 comme le reste de bran.
    public static func spent(_ bytes: Int) -> String {
        guard bytes > 0 else { return unknown }
        return Int64(bytes).formatted(.byteCount(style: .file).locale(locale))
    }

    /// Le libellé de la barre de menus **pendant** le test.
    ///
    /// **Le remplissage en U+2007 est obligatoire ici**, et pas décoratif : c'est
    /// la leçon déjà payée par `ResourceFormat`. `.monospacedDigit()` n'est pas
    /// toujours honoré sur un élément de barre de menus, alors que le contenu de
    /// la chaîne l'est toujours. Sans largeur fixe, l'aiguille qui passe de 9,8
    /// à 10,2 fait sauter l'icône et les quinze icônes voisines d'un demi-point,
    /// vingt fois par seconde. C'est le genre de détail qui rend une animation
    /// pénible sans qu'on sache dire pourquoi.
    public static func menuBarLabel(_ bytesPerSecond: Double?) -> String {
        let text = megabytes(bytesPerSecond)
        guard text != unknown else { return "…" }
        // Quatre positions : « 15,5 », « 4,2 » → « ␇4,2 », « 132,7 » déborde et
        // c'est très bien, une ligne à 1 Gbit/s a le droit de prendre un point de
        // plus une fois par test.
        let padding = String(repeating: ResourceFormat.figureSpace, count: max(0, 4 - text.count))
        return "\(padding)\(text)"
    }
}
