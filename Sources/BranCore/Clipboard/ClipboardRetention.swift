import Foundation

/// Deux durées de vie dans la même bibliothèque : le texte pour toujours, les
/// blobs trente jours.
///
/// **Pourquoi le texte n'est pas purgé du tout.** Tout l'argument de cette
/// fonctionnalité est que Maccy oublie : mesuré sur l'installation du
/// propriétaire, son historique ne remontait pas au-delà de 4,7 jours. Un outil
/// qui oublie au bout d'une semaine ne remplace pas la mémoire, il la simule.
/// Le coût de ne rien oublier est connu : ~53 entrées par jour, dont
/// l'écrasante majorité sont quelques centaines d'octets de texte — quelques
/// mégaoctets par an. Il n'y a rien à arbitrer à ce prix-là.
///
/// **Pourquoi les blobs à trente jours.** Ce sont eux qui pèsent : 158 Mo de PNG
/// pour 250 entrées sur la même installation, soit plus de 99 % du volume pour
/// moins de 10 % des lignes. Trente jours, c'est le double des sept jours des
/// captures d'écran, et volontairement : une image *copiée* est cherchée à
/// nouveau bien plus souvent qu'une capture d'écran, qui est un intermédiaire
/// jetable dès que son texte est extrait.
///
/// **Le tour de force est repris de `WatchRetention` : décider par le nom.** La
/// bibliothèque range un dossier par jour, `Clipboard/2026-08-10/`. Savoir ce
/// qui doit disparaître se réduit donc à lire des noms de dossiers — aucune
/// ouverture de fichier, aucun `stat`, aucune date de système de fichiers à
/// laquelle se fier. L'alternative rejetée était de relire chaque index, de le
/// filtrer et de le réécrire : c'est une réécriture de fichier vivant à chaque
/// démarrage, pour répondre à une question qu'un nom de dossier contient déjà.
///
/// **Une seule horloge, et c'est celle du rangement.** Tout ce qui a une
/// échéance ici la compte depuis `copiedAt`, la date qui nomme le dossier : le
/// balayage des dossiers, le marquage des entrées, et la date annoncée dans les
/// réglages. L'entrée avait autrefois sa propre horloge — `lastCopiedAt`, que
/// chaque recopie repousse — et deux horloges pour une seule suppression
/// finissent toujours par diverger : une image copiée le jour J puis recopiée
/// le jour J+6 perdait son blob avec le dossier J, sans que l'entrée l'apprenne
/// ni le dise. L'invariant est désormais structurel : **une entrée ne peut pas
/// revendiquer un blob que la purge des dossiers a emporté**, parce que les
/// deux verdicts sortent de la même fonction appliquée à la même clé de jour.
///
/// **Purger ne tue pas l'entrée.** Le dossier du jour perd son sous-dossier
/// `blobs/`, jamais son `index.jsonl`. Les entrées restent lisibles, gardent le
/// type et la taille de ce qu'elles montraient, et le disent — même parti pris
/// que `SnapshotRetention`, où une capture survit à son image. Une référence
/// morte est un état à afficher, pas un défaut à prévenir.
public struct ClipboardRetention: Equatable, Sendable, Codable {

    /// Le nombre de jours pendant lesquels les contenus lourds sont conservés.
    /// Le texte, lui, n'est jamais supprimé automatiquement — ce n'est pas un
    /// réglage, c'est la raison d'être de la fonctionnalité.
    ///
    /// Nommé `blobDays` et non `days` exprès : un futur lecteur des réglages ne
    /// doit pas pouvoir croire une seconde que ce nombre gouverne l'historique
    /// entier.
    public var blobDays: Int

    public init(blobDays: Int = 30) {
        self.blobDays = blobDays
    }

    public static let `default` = ClipboardRetention()

    public static func days(_ count: Int) -> ClipboardRetention {
        ClipboardRetention(blobDays: count)
    }

    /// Les choix offerts dans les réglages, en jours. Même forme de liste que
    /// `SnapshotRetention.offeredDays` et `WatchRetention.offeredDays`, pour que
    /// les trois sections des réglages se lisent de la même façon.
    ///
    /// Zéro est proposé en premier, comme chez les deux autres : c'est le choix
    /// de qui copie des choses sensibles et ne veut aucune image sur le disque
    /// au-delà de la journée en cours.
    public static let offeredDays = [0, 7, 14, 30, 90, 365]

    /// Ce que les réglages affichent au-dessus du choix des jours.
    ///
    /// Sans cette ligne, « 30 jours » se lit comme « on perd tout au bout de
    /// 30 jours », c'est-à-dire exactement le défaut que cette fonctionnalité
    /// existe pour corriger.
    public static let textLabel = "Texte conservé indéfiniment"

    /// La durée réglée, en secondes.
    ///
    /// **Ce n'est pas elle qui décide de la purge.** La suppression se fait par
    /// nom de dossier, donc par jour entier ; compter en secondes ici et en
    /// jours là-bas est précisément le désaccord qui laissait une entrée
    /// prétendre posséder un fichier déjà effacé. Gardée parce qu'un réglage se
    /// compare et s'affiche, jamais pour trancher une échéance — c'est
    /// `purges(day:on:)` qui tranche.
    public var blobLifetime: TimeInterval { TimeInterval(blobDays) * 86_400 }

    /// Ne conserver aucun contenu lourd : les blobs de la veille partent au
    /// premier balayage. Ceux du jour survivent jusqu'à minuit — voir
    /// `dayFoldersToPurge`, qui explique pourquoi le jour vivant est intouchable.
    public var keepsNoBlobs: Bool { blobDays <= 0 }

    public var label: String {
        switch blobDays {
        case 0: "Aucun contenu lourd conservé"
        case 1: "1 jour"
        case 365: "1 an"
        case let count: "\(count) jours"
        }
    }

    // MARK: - Décider par le nom, sans toucher au disque

    /// Les dossiers-jours dont le sous-dossier `blobs/` doit disparaître, sur le
    /// format `AAAA-MM-JJ`.
    ///
    /// Prend des noms et rend des noms : aucun accès disque, donc testable en
    /// une milliseconde comme le reste du target. C'est la même signature que
    /// `WatchRetention.filesToPurge(from:today:)`, à l'extension près — un
    /// dossier n'en a pas.
    ///
    /// **Le jour en cours n'est jamais touché, quel que soit le réglage.** Ce
    /// n'est pas une décision de politique mais de mécanique : c'est le dossier
    /// dans lequel la capture écrit en ce moment, et supprimer sous les pieds de
    /// l'écrivain est une course, pas une purge. Un réglage à zéro jour signifie
    /// donc « effacé à minuit », exactement comme le journal du veilleur.
    public func dayFoldersToPurge(from names: [String], today: String) -> [String] {
        names.filter { name in
            guard let day = Self.day(from: name) else { return false }
            return purges(day: day, on: today)
        }
    }

    /// La règle, une fois pour toutes : ce jour-là a-t-il perdu ses blobs à la
    /// date `today` ?
    ///
    /// Extraite parce qu'elle a deux appelants qui doivent être d'accord au
    /// caractère près — le balayage par nom de dossier et le marquage entrée par
    /// entrée. Tant qu'ils partagent cette fonction, ils ne peuvent pas
    /// diverger ; deux copies de la même condition, elles, auraient divergé au
    /// premier correctif appliqué d'un seul côté. C'est exactement la panne que
    /// ce fichier vient de réparer.
    func purges(day: String, on today: String) -> Bool {
        guard day != today else { return false }              // jamais le jour vivant
        guard keepsNoBlobs == false else { return true }
        guard let age = Self.daysBetween(day, and: today) else { return false }
        return age >= blobDays
    }

    /// `2026-08-06` → `2026-08-06`. Rend `nil` sur tout le reste.
    ///
    /// La validation n'est pas de la coquetterie : elle est la seule chose qui
    /// empêche un `blobs`, un `.DS_Store` ou un dossier déposé à la main par
    /// l'utilisateur d'être compté comme un jour périmé et supprimé. Rendre
    /// `nil` par défaut fait que tout ce qui n'est pas manifestement une date
    /// survit.
    static func day(from name: String) -> String? {
        let parts = name.split(separator: "-")
        guard parts.count == 3,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isNumber) })
        else { return nil }
        return name
    }

    /// Différence en jours entre deux dates `AAAA-MM-JJ`, via un calendrier
    /// grégorien en UTC. Le fuseau n'a pas d'importance ici : les deux chaînes
    /// sont produites par le même `dayKey(for:)`, dans le même fuseau, et on ne
    /// fait que les soustraire.
    static func daysBetween(_ from: String, and to: String) -> Int? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt

        guard let start = date(from, calendar), let end = date(to, calendar) else { return nil }
        return calendar.dateComponents([.day], from: start, to: end).day
    }

    private static func date(_ text: String, _ calendar: Calendar) -> Date? {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// Le nom du dossier d'un instant, **dans le calendrier de l'utilisateur**.
    ///
    /// Fuseau local et non UTC : la journée de quelqu'un se termine à minuit
    /// chez lui, et un historique coupé à 2 h du matin parce que le code pense
    /// en UTC serait incompréhensible à la relecture.
    ///
    /// Composé à la main plutôt qu'avec un `DateFormatter`, qui suit les
    /// réglages régionaux et rendrait autre chose que `2026-08-10` en calendrier
    /// bouddhiste ou japonais — des dossiers qui ne se trient plus et une
    /// rétention qui ne reconnaît plus rien.
    ///
    /// **Oui, c'est `WatchDay.key(for:)` recopié.** `BranWatch` ne peut pas être
    /// importé ici : `BranCore` est le socle et ne dépend de rien, c'est
    /// `BranApp` qui dépend des deux. Déplacer `WatchDay` dans `BranCore` serait
    /// la bonne réponse, mais c'est toucher au veilleur pendant que quatre
    /// agents travaillent. Six lignes recopiées, et une entrée à ouvrir.
    public static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0
        )
    }

    // MARK: - Décider entrée par entrée

    /// Les entrées dont les blobs viennent de partir — ou vont partir au
    /// balayage de ce jour-ci.
    ///
    /// **Une seule horloge, celle du dossier.** Ce que la purge supprime
    /// réellement, c'est un dossier-jour, et ce dossier est nommé par le
    /// `copiedAt` de ses entrées. Cette fonction ne recalcule donc rien : elle
    /// demande à `purges(day:on:)` — la fonction même qu'utilise
    /// `dayFoldersToPurge` — si le dossier de l'entrée est parti. Les deux
    /// chemins rendent le même verdict parce que c'est le même code, pas parce
    /// qu'ils ont été réglés pour tomber d'accord.
    ///
    /// **Pourquoi `copiedAt` et non `lastCopiedAt`, alors que recopier veut
    /// visiblement dire « je m'en sers encore ».** Compter depuis la dernière
    /// copie exigeait que le blob survive à son dossier, donc de le déplacer
    /// dans le dossier du jour à chaque recopie — une écriture disque dans le
    /// chemin chaud de la copie, sur une entrée déjà écrite — ou de renoncer à
    /// supprimer des dossiers entiers, c'est-à-dire à tout le tour de force de
    /// décider par le nom. Le prix mesuré de ce renoncement est nul : sur les
    /// 250 entrées de l'historique réel, **aucune** n'a été recopiée à plus d'un
    /// jour d'écart, donc les deux horloges désignaient déjà le même jour. On ne
    /// paie pas une machinerie de déplacement de blobs pour un cas qui ne s'est
    /// jamais produit — on choisit le modèle honnête.
    ///
    /// **Et la granularité est le jour, pas la seconde.** Une comparaison en
    /// secondes contre `blobLifetime` laissait l'entrée survivre quelques heures
    /// à son propre dossier : une image copiée à 18 h le jour J avait encore six
    /// jours et quinze heures au balayage de 9 h du jour J+7, alors que le
    /// dossier J, lui, venait de disparaître. L'entrée aurait juré posséder un
    /// fichier effacé. En cas de désaccord, c'est l'entrée qui cède : c'est elle
    /// que l'interface lit.
    ///
    /// Deux exclusions, et elles comptent autant que l'inclusion : une entrée
    /// sans blob n'a rien à perdre, et une entrée déjà purgée ne doit pas
    /// ressortir à chaque balayage — sinon la date de purge affichée avancerait
    /// toute seule, tous les jours.
    public func entriesToPurge(from entries: [ClipboardEntry], now: Date) -> [ClipboardEntry] {
        entriesToPurge(from: entries, now: now, calendar: .current)
    }

    /// La même chose, avec le calendrier explicite — pour que les tests soient
    /// déterminants ailleurs qu'à Paris.
    func entriesToPurge(
        from entries: [ClipboardEntry], now: Date, calendar: Calendar
    ) -> [ClipboardEntry] {
        let today = Self.dayKey(for: now, calendar: calendar)
        return entries.filter { entry in
            guard let blobs = entry.blobs, blobs.isEmpty == false else { return false }
            guard entry.blobsArePurged == false else { return false }
            return purges(day: entry.dayFolderName(calendar: calendar), on: today)
        }
    }

    /// La date à laquelle les blobs de cette entrée s'en iront, annonçable avant
    /// qu'elle arrive.
    ///
    /// **C'est minuit qui est rendu, et c'est voulu.** La suppression est
    /// gouvernée par un nom de dossier, donc elle a la granularité du jour :
    /// le dossier du jour J s'en va au premier balayage du jour
    /// `J + max(blobDays, 1)`, et l'instant le plus tôt où le fichier peut avoir
    /// disparu est le minuit qui ouvre ce jour-là. Rendre ce minuit, c'est
    /// nommer la date que les réglages affichent — la vraie, celle où le fichier
    /// s'en va, et non une date dérivée d'une horloge qui ne supprime rien.
    ///
    /// **`max(blobDays, 1)` et non `blobDays`.** Le jour en cours n'est jamais
    /// touché : un réglage à zéro jour veut dire « effacé à minuit », pas
    /// « effacé maintenant ». Sans ce plancher, les réglages annonceraient une
    /// date déjà passée pour un contenu encore là.
    ///
    /// Arithmétique de calendrier et non `+ 86 400 × n` : un changement d'heure
    /// dans l'intervalle déplacerait la réponse d'une heure, et donc parfois
    /// d'un jour affiché.
    public func expiryDate(for entry: ClipboardEntry) -> Date {
        expiryDate(for: entry, calendar: .current)
    }

    /// La même chose, avec le calendrier explicite.
    func expiryDate(for entry: ClipboardEntry, calendar: Calendar) -> Date {
        let start = calendar.startOfDay(for: entry.copiedAt)
        return calendar.date(byAdding: .day, value: Swift.max(blobDays, 1), to: start) ?? start
    }
}
