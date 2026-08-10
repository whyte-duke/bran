import Foundation
import Observation
import os

// MARK: - Ce qu'une entrée doit savoir dire

/// Ce qu'un dossier-bibliothèque exige d'une entrée pour pouvoir la ranger.
///
/// Trois choses, pas une de plus : une identité, une date de création, et le
/// nom du fichier lourd qui l'accompagne — `nil` quand il n'y en a pas, ou
/// plus. Tout le reste — un texte, une durée, une confiance, une application
/// source — appartient au type concret et ne regarde pas le rangement.
///
/// **Pourquoi un protocole plutôt que des `KeyPath` passés à l'initialiseur.**
/// La variante à clés a été écrite d'abord : `ContentStore` recevait un
/// `KeyPath<Entry, Date>` et un `WritableKeyPath<Entry, String?>`. Elle
/// compilait, et elle déplaçait l'erreur au lieu de la supprimer — rien
/// n'empêchait de brancher la date d'un type sur le nom de fichier d'un autre,
/// ni d'oublier une clé au troisième appelant. Un protocole rend l'oubli
/// impossible à écrire. Le coût est une conformité déclarée depuis `BranApp`,
/// seul module où `BranCore` et `BranVision` se voient — c'est précisément
/// l'usage prévu de `@retroactive`, et elle tient en trois lignes.
///
/// **Tout champ ajouté à un type conforme doit être `Optional`.** La synthèse
/// `Codable` de Swift n'utilise pas les valeurs par défaut, et `reload()`
/// ci-dessous avale les échecs de décodage par tolérance aux fichiers coupés :
/// un champ non optionnel ajouté à un type déjà écrit sur le disque effacerait
/// l'historique en silence, sans un seul message. `RecordingMetadata`,
/// `TranscriptEntry` et `ClipboardKind` documentent déjà ce piège.
public protocol ContentEntry: Codable, Sendable, Identifiable where ID == UUID {

    /// Sert à deux choses : l'ordre d'affichage, et le préfixe triable du nom
    /// de fichier. Elle ne change jamais après la première écriture.
    var createdAt: Date { get }

    /// Le nom — pas le chemin — du fichier lourd voisin, dans le même dossier.
    /// `nil` signifie « il n'y en a plus », ce qui est un **état à afficher, pas
    /// un défaut à prévenir** : une image purgée, un `.wav` supprimé à la main
    /// dans le Finder. L'entrée survit et le dit.
    var blobFileName: String? { get set }
}

// MARK: - Rétention

/// Ce que `ContentStore` a besoin de demander à une politique de rétention.
///
/// **Décidé le 2026-08-10 : les politiques ne déménagent pas.**
/// `SnapshotRetention` (`BranVision`) et `RetentionPolicy` (`BranSpeech`) sont
/// des quasi-jumelles, et il aurait été tentant de les fondre dans une
/// `ContentRetention` générique portée ici. Trois raisons de ne pas le faire :
///
/// 1. **Elles ne disent pas la même chose.** `SnapshotRetention` propose zéro
///    jour (« aucune image conservée », pour qui capture des informations
///    sensibles) et expose `keepsNothing` ; `RetentionPolicy` commence à un jour
///    et n'a pas de cas zéro. Leurs `label` diffèrent au cas zéro, leurs
///    `offeredDays` diffèrent, leurs champs se nomment `imageLifetime` et
///    `audioLifetime` et ces noms se lisent dans les réglages. Une générique qui
///    les réunirait prendrait une durée, une liste de jours offerts, un drapeau
///    « zéro autorisé » et deux fabriques d'étiquettes — la générique à huit
///    paramètres optionnels qui vaut moins que deux copies honnêtes.
/// 2. **Elles ont déjà 22 tests**, à leur place, dans les cibles qui les
///    portent. Les déplacer, c'est déplacer les tests, dans le même changement
///    qu'une extraction structurelle.
/// 3. Les fondre imposerait à `BranVision` et `BranSpeech` de dépendre de
///    `BranCore`, donc de modifier `Package.swift` pour un gain nul.
///
/// Ce protocole est donc une **abstraction au-dessus des deux types existants**,
/// pas leur remplacement. Les deux le satisfont déjà mot pour mot : leur
/// conformité est une extension vide.
public protocol ContentRetentionPolicy<Entry>: Sendable {

    associatedtype Entry: ContentEntry

    /// Les entrées arrivées à échéance **maintenant**. Ce que la purge en fait
    /// ensuite — le fichier seul ou l'entrée entière — n'est pas décidé ici mais
    /// par `ContentShape.purge`.
    func entriesToPurge(from entries: [Entry], now: Date) -> [Entry]

    /// Quand le fichier d'une entrée disparaîtra, pour pouvoir l'annoncer avant
    /// que ça arrive plutôt que de le constater après.
    func expiryDate(for entry: Entry) -> Date
}

// MARK: - Ce que la purge emporte

/// **Le seul endroit où les bibliothèques divergent vraiment.**
///
/// Une capture et une dictée purgent leur **fichier lourd** et gardent le texte
/// pour toujours : l'image pèse 250 Ko et ne sert qu'à relire, le texte pèse
/// trois lignes et c'est lui qu'on cherchera dans six mois. Un historique de
/// presse-papiers, lui, voudra purger **l'entrée entière** — garder pour
/// toujours le texte de chaque copie serait une archive que personne n'a
/// demandée.
///
/// Une générique qui aurait supposé l'un ou l'autre aurait changé un
/// comportement en silence, sans qu'aucun test ne s'en aperçoive : côté dictée,
/// un test s'appelle littéralement « Le texte n'est jamais concerné par la
/// purge ». D'où un choix explicite, à l'initialisation, sans valeur par défaut.
public enum ContentPurge: Sendable {

    /// Supprimer le fichier lourd, mettre `blobFileName` à `nil`, garder
    /// l'entrée et réécrire son sidecar. Captures et dictées.
    case blobOnly

    /// Supprimer le fichier lourd **et** le sidecar, et retirer l'entrée de la
    /// liste. Pour une bibliothèque dont le texte lui-même expire.
    case wholeEntry
}

// MARK: - La forme d'une bibliothèque

/// Ce qui distingue deux bibliothèques par ailleurs identiques.
///
/// Cinq valeurs, toutes obligatoires : aucune n'a de défaut raisonnable, et un
/// défaut raisonnable est exactement ce qui ferait qu'un troisième appelant
/// hériterait du comportement du premier sans l'avoir choisi.
public struct ContentShape: Sendable {

    /// Le sous-dossier, sous la racine rendue par la fermeture `root`.
    /// « Captures », « Dictées ».
    public var folderName: String

    /// L'extension du fichier lourd, sans point : « png », « wav ». Elle sert
    /// aussi à compter les octets occupés — et **seuls** les fichiers portant
    /// cette extension sont comptés, jamais les sidecars.
    public var blobExtension: String

    /// Ce que la purge emporte. Voir `ContentPurge` : c'est la décision qu'une
    /// générique ne doit surtout pas prendre à la place de l'appelant.
    public var purge: ContentPurge

    /// Ce qu'on affiche quand le dossier ne se lit pas. La raison technique est
    /// ajoutée après un « : ».
    ///
    /// Un dossier illisible — volume démonté, droits retirés, chemin devenu un
    /// fichier — ne doit **jamais** ressembler à une bibliothèque vide. C'est la
    /// pire forme d'un défaut de lecture : elle a l'air d'une perte de données.
    public var inaccessibleFolderMessage: String

    /// Ce qu'on affiche quand le fichier lourd n'a pas pu être écrit, ou `nil`
    /// pour ne rien afficher.
    ///
    /// Les deux appelants d'origine ne font pas le même choix, et ce n'est pas
    /// un oubli : côté capture, un enregistrement sans image est une entrée
    /// qu'on ne pourra plus relire, et la première version qui avalait l'erreur
    /// a empêché de diagnostiquer une capture vide. Côté dictée, l'audio est un
    /// confort. `nil` conserve ce silence-là au lieu de l'unifier au passage.
    public var blobFailureMessage: String?

    public init(
        folderName: String,
        blobExtension: String,
        purge: ContentPurge,
        inaccessibleFolderMessage: String,
        blobFailureMessage: String? = nil
    ) {
        self.folderName = folderName
        self.blobExtension = blobExtension
        self.purge = purge
        self.inaccessibleFolderMessage = inaccessibleFolderMessage
        self.blobFailureMessage = blobFailureMessage
    }
}

/// Comment écrire le fichier lourd d'une entrée, à l'URL que le store impose.
///
/// **La fermeture crée son dossier parent.** `ContentStore` ne le fait pas pour
/// elle : les deux écrivains d'origine (`CGImageDestination`, `AVAudioFile`) le
/// font déjà, et un `createDirectory` de plus à chaque enregistrement serait un
/// appel disque gratuit sur le chemin chaud.
public typealias ContentBlobWriter = @MainActor (URL) throws -> Void

// MARK: - Le journal

/// Où le ramassage rend compte. Voir `ContentStore.reload()` pour la raison
/// pour laquelle c'est un journal et pas un bandeau.
///
/// Hors de la classe, et pas par goût : `ContentStore` est générique, et Swift
/// n'accepte pas de propriété statique **stockée** dans un type générique —
/// c'est déjà pour cette raison que `encoder` et `decoder` y sont des
/// propriétés calculées. Un `Logger` recréé à chaque ligne serait un gâchis
/// pour un objet dont c'est justement le rôle d'être partagé.
private let libraryLog = Logger(subsystem: "com.opahventures.bran", category: "library")

// MARK: - Le store

/// Un dossier tenu pour une bibliothèque : une entrée, son sidecar `.json`, et
/// un fichier lourd optionnel à côté.
///
/// **Le dossier est la source de vérité.** Pas de base de données à côté du
/// disque — deux sources de vérité divergent toujours, et c'est l'utilisateur
/// qui arbitre au pire moment. Supprimer un fichier dans le Finder rend
/// simplement l'entrée non-relisable au prochain balayage, ce qui est le
/// comportement souhaité, pas un défaut à corriger.
///
/// **Le défaut d'une bibliothèque n'est presque jamais ce qu'elle écrit ; c'est
/// ce qu'elle croit avoir supprimé.** La phrase mérite d'être écrite ici parce
/// que la maladie revient : la purge parcourait `entries`, donc un fichier
/// lourd dont le sidecar n'avait jamais été écrit — écriture ratée, plantage
/// entre les deux fichiers — n'était plus jamais vu. Il restait sur le disque,
/// invisible dans l'interface, impossible à supprimer depuis l'application, et
/// il continuait d'être compté dans `blobBytes`. Mesuré ailleurs sur cette
/// machine : la base de Maccy pèse 384 Mo pour 250 entrées vivantes, dont
/// 327 Mo de contenus dont la ligne parente a disparu sans les emporter. La
/// réconciliation est faite par `reload()`, et sa doc dit pourquoi là et pas
/// ailleurs.
///
/// ```
/// ~/…/bran/<folderName>/
///   2026-08-05T20-47-11-<uuid>.json   ← l'entrée, gardée selon `purge`
///   2026-08-05T20-47-11-<uuid>.<ext>  ← le fichier lourd, purgé à échéance
/// ```
///
/// **Pourquoi `@MainActor` et pas un `actor`.** Envisagé et écarté le
/// 2026-08-10 : la fermeture `root: @MainActor () -> URL` que partagent les
/// quatre stores est incompatible avec un `actor`, et empiler une migration de
/// concurrence sur une extraction structurelle casse la règle sur laquelle tout
/// le plan repose — jamais un changement de forme et un changement de
/// comportement dans le même commit. L'entrée « Move the content stores off the
/// MainActor » de `TODOS.md` garde la mesure à prendre avant de décider.
///
/// **Pourquoi une composition et pas un héritage ni un `typealias`.**
/// `SnapshotStore` et `DictationStore` restent des types nommés qui possèdent
/// un `ContentStore` : chacun garde son vocabulaire (`imageURL`, `audioURL`),
/// ses écrivains spécifiques, et sa politique concrète quand il a besoin de lui
/// poser une question que la générique ne connaît pas.
@MainActor
@Observable
public final class ContentStore<Entry: ContentEntry> {

    /// De la plus récente à la plus ancienne, comme les deux stores d'origine.
    public private(set) var entries: [Entry] = []

    /// **Ce qui empêche de lire ou d'écrire, quand quelque chose l'empêche.**
    ///
    /// Une seule propriété pour l'interface — les deux panneaux affichent
    /// `problem` et rien d'autre — mais **trois canaux derrière**, parce qu'ils
    /// ne s'éteignent pas au même moment. C'est le cas d'emplacements nommés que
    /// `FailureBanner` décrit : la question n'est pas combien de messages on
    /// garde, mais *qui les efface et quand*.
    ///
    /// | Canal          | Posé par                    | Effacé par                        |
    /// |----------------|-----------------------------|-----------------------------------|
    /// | `readProblem`  | un `reload()` qui échoue    | le premier `reload()` qui repasse |
    /// | `writeFailure` | le disque qui refuse        | la première écriture qui aboutit  |
    /// | `notice`       | `report(_:)`, sans échec    | un fichier lourd réellement écrit |
    ///
    /// **Les trois règles, et pourquoi elles ne se contredisent pas.**
    ///
    /// 1. *Une relecture ne réfute pas un échec d'écriture.* La version à un
    ///    seul canal l'effaçait à chaque `reload()` réussi. C'était défendable
    ///    sur le papier et faux à l'usage : les deux panneaux relisent le
    ///    dossier à leur apparition (`.task { await store.reload() }`). Une
    ///    capture dont l'image n'avait pas pu être écrite posait son « Image non
    ///    conservée », et l'utilisateur qui ouvrait la bibliothèque pour
    ///    comprendre effaçait le message **en l'ouvrant**.
    /// 2. *Une écriture qui aboutit, elle, réfute un échec d'écriture.* Le
    ///    symptôme inverse, et il coûte autant : un disque plein à 10 h et libre
    ///    à 10 h 05 se plaignait encore à 18 h. Un reproche qui survit à sa
    ///    propre réfutation apprend à ne plus lire le bandeau.
    /// 3. *Rien ne réfute une constatation.* Une constatation ne dit pas qu'une
    ///    écriture a raté ; elle dit ce que le magasin n'a **délibérément** pas
    ///    fait. Aucune réussite ultérieure ne la contredit — sauf celle qui fait
    ///    exactement ce qu'elle annonçait n'avoir pas fait, voir `notice`.
    ///
    /// Les règles 2 et 3 sont ce qui a imposé de séparer `writeFailure` de
    /// `notice`, qui partageaient un emplacement. `SnapshotStore` appelle
    /// `report(_:)` **juste avant** un `save` sans fichier lourd, pour dire « la
    /// durée de conservation est réglée sur zéro » ; avec un seul emplacement,
    /// la règle 2 aurait effacé ce message dans la microseconde qui suit sa
    /// pose. Deux emplacements, et l'ordre d'appel de `SnapshotStore` n'a plus
    /// besoin de changer.
    ///
    /// Quand plusieurs canaux parlent, `FailureBanner` les empile, et sa règle
    /// de deux lignes maximum vaut ici aussi : à trois messages, la constatation
    /// cède la place. C'est l'ordre voulu — une panne demande une action, une
    /// constatation ne demande rien.
    public var problem: String? {
        // L'ordre est celui de `FailureBanner` : le plus récent en dernier. Un
        // dossier devenu illisible est toujours le plus récent des trois, et
        // c'est bien celui qu'on veut lire en bas, juste au-dessus du reste de
        // l'interface qui, elle, sera vide.
        [notice, writeFailure, readProblem]
            .compactMap { $0 }
            .reduce(String?.none) { banner, message in
                FailureBanner.appending(message, to: banner)
            }
    }

    /// Ce que la **lecture** du dossier reproche. Effacé par le premier
    /// `reload()` qui repasse : un volume remonté est une bonne nouvelle qui
    /// n'a pas besoin d'être acquittée.
    ///
    /// Interne et non public : l'application n'a qu'un bandeau, et lui offrir
    /// trois propriétés l'inviterait à en oublier une. Les tests, eux, ont
    /// besoin de vérifier que les trois ne s'éteignent pas ensemble.
    private(set) var readProblem: String?

    /// **Ce que le disque a refusé**, fichier lourd ou sidecar.
    ///
    /// Survit à `reload()` (règle 1) et s'efface à la première écriture qui
    /// aboutit (règle 2) — le fichier lourd enfin écrit, ou simplement le
    /// sidecar posé sans encombre par le `save` ou le `mutate` suivant. Une
    /// écriture qui aboutit prouve que le disque accepte à nouveau ce qu'on lui
    /// donne, et c'est toute la portée que ce message avait.
    ///
    /// L'échec qui reste **silencieux** — `blobFailureMessage` à `nil`, le choix
    /// de la dictée — n'efface rien non plus : il n'a rien réfuté, il s'est tu.
    ///
    /// Il ne survit pas au quitter, et c'est assumé : ce canal dit ce qui vient
    /// de rater, pas l'historique des pannes.
    private(set) var writeFailure: String?

    /// **Ce que l'appelant a annoncé lui-même**, par `report(_:)`, alors que
    /// rien n'avait raté.
    ///
    /// « Image non conservée : la durée de conservation est réglée sur zéro » en
    /// est le seul exemple aujourd'hui : le magasin a fait exactement ce qu'on
    /// lui demandait, et il le dit parce qu'une absence d'image ressemblerait
    /// sinon à une panne.
    ///
    /// Ni un `reload()`, ni un `save` réussi, ni un sidecar réécrit ne
    /// l'effacent : aucun des trois ne contredit la phrase. Une seule chose la
    /// contredit — **un fichier lourd effectivement conservé**, qui est
    /// littéralement le contraire de ce qu'elle annonce. C'est le seul
    /// effacement, et il vaut mieux que « jamais » : une rétention remontée
    /// au-dessus de zéro laisserait sinon le message en place pour toute la
    /// séance, à parler d'un réglage qui n'existe plus.
    ///
    /// Un `report(_:)` remplace le précédent. Le canal porte l'état courant du
    /// magasin, pas la liste de ce qu'il a dit.
    private(set) var notice: String?

    /// Octets occupés par les fichiers lourds conservés. Affiché dans les
    /// réglages : une rétention se règle mieux quand on voit ce qu'elle coûte.
    public private(set) var blobBytes: Int64 = 0

    /// Le dossier suit la racine choisie dans les réglages : la changer déplace
    /// toutes les bibliothèques d'un coup. Une fermeture plutôt qu'une `URL`
    /// figée, sinon le store garderait l'ancien dossier jusqu'au prochain
    /// lancement.
    private let root: @MainActor () -> URL
    private let shape: ContentShape
    private var retention: any ContentRetentionPolicy<Entry>

    public init(
        root: @escaping @MainActor () -> URL,
        shape: ContentShape,
        retention: some ContentRetentionPolicy<Entry>
    ) {
        self.root = root
        self.shape = shape
        self.retention = retention
    }

    public var folder: URL {
        root().appending(path: shape.folderName, directoryHint: .isDirectory)
    }

    /// Change la politique et applique tout de suite ce qu'elle rend caduc :
    /// raccourcir la rétention dans les réglages doit libérer le disque à cet
    /// instant, pas au prochain lancement.
    public func setRetention(_ policy: some ContentRetentionPolicy<Entry>) {
        retention = policy
        Task { await purgeExpired() }
    }

    // MARK: - Lecture

    /// Relit le dossier — et **ramasse au passage les fichiers lourds que plus
    /// aucune entrée ne réclame**.
    ///
    /// ## Pourquoi le ramassage est ici, et nulle part ailleurs
    ///
    /// Le premier réflexe était d'en faire une méthode publique, appelée au
    /// lancement à côté de `purgeExpired()`. Deux raisons de ne pas le faire, et
    /// la seconde est la vraie.
    ///
    /// 1. **Le coût.** Réconcilier demande la liste du dossier ; `reload()` la
    ///    fait déjà, avec les tailles. Le ramassage n'ajoute donc pas un seul
    ///    appel disque tant qu'il n'y a rien à supprimer — c'est une soustraction
    ///    d'ensembles sur des données déjà en main, pas un second passage.
    /// 2. **La sûreté.** Un ramassage est une suppression décidée par une
    ///    absence, et l'absence n'est une information que si l'on sait avoir
    ///    tout lu. `entries` n'est un recensement fidèle du dossier qu'ici,
    ///    juste après avoir décodé chaque sidecar. Ailleurs — au retour d'un
    ///    `save` sur un store fraîchement construit, par exemple — `entries` ne
    ///    contient qu'une entrée et le dossier en compte deux cents : un
    ///    ramassage à ce moment-là effacerait la bibliothèque entière. C'est
    ///    pour cette raison que `refreshBlobBytes()`, qui liste pourtant le
    ///    dossier lui aussi après chaque écriture, ne ramasse rien.
    ///
    /// Conséquence assumée : un orphelin créé en cours de séance survit jusqu'à
    /// la prochaine relecture. Elle a lieu au lancement, à l'ouverture de chaque
    /// panneau et au changement de dossier — largement assez pour un fichier que
    /// personne ne voit.
    ///
    /// ## Ce qu'il refuse de toucher
    ///
    /// Le dossier est délibérément un dossier ordinaire, que l'utilisateur est
    /// invité à ouvrir, déplacer et sauvegarder. **Supprimer le fichier d'un
    /// tiers parce qu'il traînait chez nous serait un défaut bien pire que celui
    /// qu'on corrige ici.** Un fichier qu'on ne sait pas classer reste donc où
    /// il est, pour toujours :
    ///
    /// - tout ce qui ne porte pas `blobExtension` — les sidecars `.json`, un
    ///   `notes.txt`, un `.png` déposé dans une bibliothèque de `.wav` ;
    /// - tout ce qui n'est pas un fichier régulier : un dossier nommé
    ///   `archive.png` serait emporté avec son contenu par `removeItem` ;
    /// - tout ce qui porte la bonne extension sans porter **un nom que ce store
    ///   aurait pu écrire** (voir `isSelfWritten`) : une image glissée à la main
    ///   dans le dossier des captures n'a ni horodatage ni UUID, elle reste ;
    /// - le fichier lourd d'un sidecar présent mais **illisible**. Celui-là est
    ///   le piège : son entrée n'a pas décodé, donc personne ne le réclame, donc
    ///   la soustraction le donne orphelin. Or `SidecarFault` dit déjà ce qu'on
    ///   en pense — un `.json` abîmé est peut-être récupérable à la main, et
    ///   détruire l'image qui va avec transformerait une panne réparable en
    ///   perte sèche.
    ///
    /// ## Ce qu'il en dit
    ///
    /// Une ligne de journal, et rien dans `problem`. Un bandeau annonçant
    /// « 3 fichiers récupérés » parlerait de fichiers dont l'utilisateur ignore
    /// l'existence, au lancement, sans rien à faire de l'information — et
    /// occuperait le seul canal dont on dispose pour les pannes qui, elles,
    /// demandent une action. Un échec de suppression ne remonte pas non plus :
    /// l'orphelin qui résiste laisse exactement l'état d'avant ce correctif, et
    /// un volume en lecture seule ferait sinon clignoter le même avertissement à
    /// chaque ouverture de panneau. Les deux cas sont dans le journal, avec les
    /// noms, ce qui suffit à instruire une plainte du genre « ce dossier pèse
    /// trois fois ce qu'il devrait ».
    ///
    /// - Returns: le nombre de fichiers orphelins ramassés. Zéro dans la vie
    ///   normale ; non nul veut dire qu'une écriture ou un plantage a laissé
    ///   quelque chose derrière lui.
    @discardableResult
    public func reload() async -> Int {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let files = try FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            )

            let decoder = Self.decoder
            var found: [Entry] = []
            var bytes: Int64 = 0

            // Les trois ensembles de la réconciliation, remplis pendant le seul
            // et unique parcours. La soustraction se fait après : rien ne dit
            // qu'un fichier lourd sera énuméré après le sidecar qui le réclame.
            var blobs: [String: Int64] = [:]
            var claimed: Set<String> = []
            var undecoded: Set<String> = []

            for url in files {
                if url.pathExtension == "json" {
                    guard let data = try? Data(contentsOf: url),
                          var entry = try? decoder.decode(Entry.self, from: data)
                    else {
                        // Illisible ou indécodable : ignoré pour l'affichage
                        // comme avant, mais retenu ici — son fichier lourd ne
                        // doit pas être pris pour un orphelin.
                        undecoded.insert(url.deletingPathExtension().lastPathComponent)
                        continue
                    }

                    // Un fichier lourd supprimé à la main dans le Finder doit
                    // rendre l'entrée non-relisable, pas planter au clic.
                    if let name = entry.blobFileName,
                       FileManager.default.fileExists(
                           atPath: folder.appending(path: name).path(percentEncoded: false)
                       ) == false {
                        entry.blobFileName = nil
                    }
                    if let name = entry.blobFileName { claimed.insert(name) }
                    found.append(entry)
                } else if url.pathExtension == shape.blobExtension {
                    let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                    let size = Int64(values?.fileSize ?? 0)
                    bytes += size
                    // Le comptage des octets reste ce qu'il était — tout ce qui
                    // porte l'extension pèse dans le dossier, y compris ce qu'on
                    // n'a pas écrit. Seul le ramassage est plus exigeant : se
                    // tromper d'un fichier dans une somme est un défaut
                    // d'affichage, se tromper d'un fichier dans un `removeItem`
                    // ne se rattrape pas.
                    if values?.isRegularFile == true { blobs[url.lastPathComponent] = size }
                }
            }

            entries = found.sorted { $0.createdAt > $1.createdAt }
            let collected = sweepOrphanedBlobs(among: blobs, claimed: claimed, sparing: undecoded)
            blobBytes = bytes - collected.bytes
            readProblem = nil
            return collected.count
        } catch {
            readProblem = "\(shape.inaccessibleFolderMessage) : \(error.localizedDescription)"
            return 0
        }
    }

    // MARK: - Écriture

    /// Écrit le fichier lourd puis le sidecar, dans cet ordre.
    ///
    /// L'ordre compte : un `.json` qui référencerait un fichier inexistant
    /// serait une entrée qui promet une relecture impossible. Le désordre
    /// inverse — un fichier lourd écrit alors que son sidecar a échoué — est
    /// bénin à la lecture : l'entrée n'existe simplement pas.
    ///
    /// **Et il est ramassé à la relecture suivante.** Les deux stores d'origine
    /// affirmaient qu'un fichier orphelin « se nettoie tout seul à la purge » ;
    /// c'était faux — la purge parcourt `entries`, donc un fichier sans entrée
    /// n'était jamais vu, restait sur le disque pour toujours et continuait
    /// d'être compté dans `blobBytes`. C'est `reload()` qui le ramasse
    /// désormais, et sa doc dit à quelles conditions.
    ///
    /// **L'ordre d'insertion suit `createdAt`, pas l'ordre d'arrivée.** La
    /// première version insérait en tête sans regarder la date : enregistrer une
    /// entrée antidatée donnait une liste en mémoire que `reload()` n'aurait pas
    /// reproduite. Les deux appelants d'alors enregistraient tous les deux
    /// `.now`, donc l'invariant tenait par chance ; un historique de
    /// presse-papiers qui importerait l'existant le casserait au premier essai,
    /// et le symptôme — une liste qui se réordonne toute seule au redémarrage —
    /// ne se relie à rien.
    ///
    /// - Parameter blob: comment écrire le fichier lourd, ou `nil` s'il n'y en a
    ///   pas à écrire. **C'est l'appelant qui décide** s'il y en a un : une
    ///   image absente, un tampon audio vide et une rétention réglée sur zéro
    ///   sont trois raisons différentes de ne rien écrire, et elles ne se
    ///   racontent pas de la même façon à l'utilisateur.
    public func save(_ entry: Entry, blob: ContentBlobWriter? = nil) async {
        var stored = entry

        // Ce qui décidera d'effacer `writeFailure` à la fin. Un `write` réussi
        // ne suffit pas : dans l'ordre où ce corps s'exécute, le sidecar est
        // posé *après* le fichier lourd, donc un sidecar qui aboutit derrière un
        // fichier lourd refusé effacerait le message qu'on vient d'écrire, à
        // l'instruction suivante. La réfutation demande que **rien** de ce
        // `save` n'ait raté.
        var everythingWritten = true

        if let blob {
            let name = Self.blobName(for: entry, extension: shape.blobExtension)
            do {
                try blob(folder.appending(path: name))
                stored.blobFileName = name
                // Un fichier lourd conservé est le contraire exact de « aucun
                // fichier n'a été conservé ». C'est la seule chose qui réfute
                // une constatation, et elle vient d'arriver.
                notice = nil
            } catch {
                // Le fichier lourd est un confort ; l'entrée est l'essentiel. On
                // la garde sans son fichier plutôt que de tout perdre.
                stored.blobFileName = nil
                everythingWritten = false
                if let message = shape.blobFailureMessage {
                    writeFailure = "\(message) : \(error.localizedDescription)"
                }
            }
        }

        if write(stored) == false { everythingWritten = false }
        // La preuve du contraire : le disque était plein, il ne l'est plus.
        if everythingWritten { writeFailure = nil }

        entries.insert(stored, at: insertionIndex(for: stored))
        await refreshBlobBytes()
    }

    /// Où placer une entrée qui vient d'être écrite, pour que la liste en
    /// mémoire soit celle que `reload()` reconstruirait.
    ///
    /// À égalité de date, la nouvelle passe devant — c'est ce que faisait
    /// l'insertion en tête, et deux copies dans la même seconde sont un cas réel
    /// pour un historique de presse-papiers.
    private func insertionIndex(for entry: Entry) -> Int {
        entries.firstIndex { $0.createdAt <= entry.createdAt } ?? entries.count
    }

    /// Modifie une entrée en réécrivant son sidecar. Une entrée inconnue est
    /// ignorée sans bruit : l'appelant travaille souvent sur une entrée qu'une
    /// suppression concurrente vient de retirer.
    public func mutate(_ id: UUID, _ change: (inout Entry) -> Void) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        var entry = entries[index]
        change(&entry)
        entries[index] = entry
        // Un sidecar réécrit sans encombre est une écriture qui aboutit, donc
        // une réfutation. Contrairement à `save`, il n'y a rien d'autre à
        // écrire ici : la réussite de `write` est toute la réussite du geste.
        if write(entry) { writeFailure = nil }
    }

    public func delete(_ entry: Entry) async {
        removeBlob(of: entry)
        try? FileManager.default.removeItem(at: sidecarURL(for: entry))
        entries.removeAll { $0.id == entry.id }
        await refreshBlobBytes()
    }

    /// `nil` quand le fichier lourd n'existe plus. Le bouton qui en dépend se
    /// désactive avec sa raison plutôt que d'échouer au clic.
    public func blobURL(for entry: Entry) -> URL? {
        entry.blobFileName.map { folder.appending(path: $0) }
    }

    /// Annonce une **constatation** que la générique ne peut pas formuler à la
    /// place de l'appelant — par exemple « la durée de conservation est réglée
    /// sur zéro », qui suppose de connaître la politique concrète.
    ///
    /// Ce n'est pas un échec : rien n'a raté, le magasin a fait ce qu'on lui
    /// demandait et il le dit. D'où son emplacement à part, `notice`, et la
    /// règle qui va avec — aucune écriture réussie ne l'efface, sauf celle d'un
    /// fichier lourd, qui est le contraire de ce qu'elle annonce.
    ///
    /// **L'appel a lieu avant le `save` qu'il commente**, chez son seul
    /// appelant, et il faut que cela reste sans conséquence : c'est la raison
    /// d'être de la séparation des deux emplacements. Voir `problem`.
    ///
    /// Comme les échecs, une constatation survit à la relecture que l'ouverture
    /// du panneau déclenche — sans quoi elle ne serait lue que par qui regardait
    /// déjà.
    public func report(_ message: String) {
        notice = message
    }

    // MARK: - Purge

    /// Supprime ce qui est arrivé à échéance, selon `ContentShape.purge`.
    ///
    /// Appelée au lancement, une fois par jour et à chaque changement de
    /// rétention — pas à chaque ouverture de la vue, où elle ne ferait que
    /// ralentir un affichage.
    ///
    /// - Returns: le nombre d'entrées concernées.
    @discardableResult
    public func purgeExpired(now: Date = .now) async -> Int {
        let expired = retention.entriesToPurge(from: entries, now: now)
        guard expired.isEmpty == false else { return 0 }

        for entry in expired {
            removeBlob(of: entry)
            switch shape.purge {
            case .blobOnly:
                // `mutate` réécrit le sidecar : l'oubli du fichier doit survivre
                // au redémarrage, sinon la prochaine lecture le redemanderait.
                mutate(entry.id) { $0.blobFileName = nil }
            case .wholeEntry:
                try? FileManager.default.removeItem(at: sidecarURL(for: entry))
                entries.removeAll { $0.id == entry.id }
            }
        }

        await refreshBlobBytes()
        return expired.count
    }

    public func expiryDate(for entry: Entry) -> Date {
        retention.expiryDate(for: entry)
    }

    // MARK: - Interne

    /// Pose le sidecar, et dit s'il est posé.
    ///
    /// Il pose le reproche en cas d'échec mais **ne l'efface jamais en cas de
    /// réussite**, et ce n'est pas une omission : `save` l'appelle après avoir
    /// peut-être déjà constaté qu'un fichier lourd manquait à l'appel, et un
    /// effacement ici emporterait ce message-là. C'est l'appelant qui sait si le
    /// geste entier a abouti ; lui seul efface.
    @discardableResult
    private func write(_ entry: Entry) -> Bool {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let data = try Self.encoder.encode(entry)
            // `.atomic` écrit dans un temporaire puis renomme. Un utilitaire
            // `fsync` maison a été envisagé et écarté : le mode de défaillance
            // annoncé est un plantage de l'application, pas une coupure de
            // courant, et `.atomic` couvre déjà le premier.
            try data.write(to: sidecarURL(for: entry), options: .atomic)
            return true
        } catch {
            writeFailure = "Écriture impossible : \(error.localizedDescription)"
            return false
        }
    }

    // MARK: - Réconciliation

    /// Supprime les fichiers lourds que plus aucune entrée ne réclame.
    ///
    /// Appelée par `reload()` seul, avec les trois ensembles que son parcours a
    /// remplis. La liste des conditions et leurs raisons sont dans la doc de
    /// `reload()` ; ici, seulement ce que le code ne montre pas :
    ///
    /// **Ce n'est pas un comptage de références.** Un fichier lourd porte le nom
    /// de son entrée, une entrée n'en réclame qu'un, et deux entrées ne peuvent
    /// pas partager le même fichier. La réconciliation est donc une soustraction
    /// d'ensembles, pas un ramasse-miettes.
    ///
    /// **La soustraction se fait sur ce que les entrées réclament, pas sur la
    /// présence du sidecar voisin.** La règle du voisin aurait été plus simple —
    /// même radical, extension différente — et elle aurait manqué le cas le plus
    /// vicieux : une purge dont le `removeItem` a échoué en silence laisse un
    /// fichier lourd avec son sidecar intact et un `blobFileName` remis à `nil`.
    /// Le fichier n'est plus réclamé par personne, la rétention avait promis sa
    /// suppression, et sur des images d'écran ou de l'audio une promesse de
    /// suppression non tenue est pire que pas de promesse : elle rassure.
    private func sweepOrphanedBlobs(
        among blobs: [String: Int64],
        claimed: Set<String>,
        sparing undecoded: Set<String>
    ) -> (count: Int, bytes: Int64) {
        // Un seul formateur pour tout le passage : `isSelfWritten` en a besoin à
        // chaque candidat, et `DateFormatter` coûte plus cher que la comparaison
        // qu'il sert.
        let formatter = Self.stampFormatter
        let library = shape.folderName
        var count = 0
        var reclaimed: Int64 = 0

        for (name, size) in blobs where claimed.contains(name) == false {
            let stem = (name as NSString).deletingPathExtension
            guard undecoded.contains(stem) == false,
                  Self.isSelfWritten(stem, formatter: formatter)
            else { continue }

            do {
                try FileManager.default.removeItem(at: folder.appending(path: name))
                count += 1
                reclaimed += size
            } catch {
                // Les noms sont cités en clair : ce sont un horodatage et un
                // UUID, ils ne nomment personne, et c'est la seule information
                // qui rende le ménage possible à la main.
                let line = "\(library) : orphelin non supprimé \(name) — \(error.localizedDescription)"
                libraryLog.error("\(line, privacy: .public)")
            }
        }

        if count > 0 {
            let line = "\(library) : \(count) fichier(s) sans entrée ramassé(s), \(reclaimed) octets"
            libraryLog.notice("\(line, privacy: .public)")
        }
        return (count, reclaimed)
    }

    /// Ce nom aurait-il pu être écrit par ce store ?
    ///
    /// `<horodatage>-<UUID>` et rien d'autre : les deux moitiés que
    /// `blobName(for:extension:)` assemble, vérifiées en les redécomposant.
    /// C'est volontairement plus strict que « ça porte la bonne extension ».
    /// Une capture d'écran que l'utilisateur a glissée dans le dossier, ou l'un
    /// de nos fichiers qu'il a renommé pour le retrouver, échoue au test et
    /// reste sur le disque — un fichier de trop coûte des octets, un fichier de
    /// tiers supprimé coûte la confiance dans un dossier qu'on l'invite
    /// justement à ouvrir.
    ///
    /// L'horodatage n'est pas relu pour ce qu'il vaut, seulement pour sa forme :
    /// un fichier daté de 1998 dans un dossier créé cette année reste un fichier
    /// que nous avons écrit — l'utilisateur peut avoir remonté l'horloge, et une
    /// date jugée invraisemblable n'a jamais été une raison de supprimer.
    private nonisolated static func isSelfWritten(_ stem: String, formatter: DateFormatter) -> Bool {
        let identity = stem.suffix(36)
        let head = stem.dropLast(36)
        guard head.isEmpty == false, head.last == "-",
              UUID(uuidString: String(identity)) != nil
        else { return false }
        return formatter.date(from: String(head.dropLast())) != nil
    }

    /// Le `try?` est délibéré et n'est plus un trou : un fichier que le disque
    /// refuse de rendre reste sur place, cesse d'être réclamé par son entrée, et
    /// se fait ramasser à la prochaine relecture. C'était l'autre moitié du
    /// défaut — la purge annonçait des suppressions qu'elle n'avait pas faites.
    private func removeBlob(of entry: Entry) {
        guard let name = entry.blobFileName else { return }
        try? FileManager.default.removeItem(at: folder.appending(path: name))
    }

    private func sidecarURL(for entry: Entry) -> URL {
        folder.appending(path: Self.blobName(for: entry, extension: "json"))
    }

    private func refreshBlobBytes() async {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]
        )) ?? []

        blobBytes = files
            .filter { $0.pathExtension == shape.blobExtension }
            .reduce(into: Int64(0)) { total, url in
                total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            }
    }

    /// Le sidecar et le fichier lourd portent le même nom à l'extension près :
    /// c'est ce qui rend le dossier lisible à l'œil, et c'est ce qui permet de
    /// retrouver l'un depuis l'autre sans index.
    private nonisolated static func blobName(for entry: Entry, extension suffix: String) -> String {
        "\(stamp(entry.createdAt))-\(entry.id.uuidString).\(suffix)"
    }

    /// Horodatage triable en tête de nom de fichier : le dossier se lit dans
    /// l'ordre chronologique sans outil.
    private nonisolated static func stamp(_ date: Date) -> String {
        stampFormatter.string(from: date)
    }

    /// Sert dans les deux sens : écrire le nom, et reconnaître un nom qu'on a
    /// écrit. Le second usage est ce qui empêche le ramassage de toucher au
    /// fichier de quelqu'un d'autre, et il exige que ce soit **le même**
    /// formateur — un second, réglé ailleurs, dériverait sans bruit.
    private nonisolated static var stampFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }

    private nonisolated static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    private nonisolated static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
