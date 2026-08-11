import BranCore
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import os

/// Le journal des vignettes. Hors de la classe pour la même raison que celui de
/// `ClipboardStore` : un `Logger` est fait pour être partagé, pas reconstruit à
/// chaque ligne. Même catégorie que le magasin — c'est la même fonctionnalité,
/// et deux catégories obligeraient à filtrer deux fois pour lire une panne.
private let thumbnailLog = Logger(subsystem: "com.opahventures.bran", category: "clipboard")

// MARK: - Le porteur

/// Un `CGImage` dans une boîte, pour deux raisons qui n'ont rien à voir l'une
/// avec l'autre.
///
/// **1. Traverser une frontière d'isolement.** Le décodage est
/// `nonisolated static`, donc il rend son résultat à un appelant `@MainActor` ;
/// et `Task` exige que son `Success` soit `Sendable`. `CGImage` ne l'est pas.
/// `BranVision.RecognisableImage` a le même problème et le résout de la même
/// façon — c'est le motif du dépôt.
///
/// **2. Servir de valeur à `NSCache`.** Il veut une classe ; `CGImage` est un
/// type CoreFoundation, et l'y ranger obligerait à des conversions à chaque
/// lecture.
///
/// **`@unchecked Sendable` justifié :** l'unique propriété est une constante, et
/// un `CGImage` est immuable après sa création — Apple le documente ainsi, c'est
/// ce qui permet de le partager entre fils sans verrou. Il n'y a rien à
/// protéger, donc rien que le compilateur pourrait vérifier à notre place.
final class ThumbnailImage: @unchecked Sendable {

    let image: CGImage

    init(_ image: CGImage) {
        self.image = image
    }

    /// Ce que cette vignette occupe **une fois décodée**, en octets — pas la
    /// taille de son PNG. C'est ce chiffre-là qui remplit la mémoire, donc c'est
    /// lui que `NSCache` doit compter : une vignette de détail pèse 100 Ko sur le
    /// disque et 262 Ko en RAM.
    var cost: Int { image.height * image.bytesPerRow }
}

/// Ce qu'une fabrication a produit.
///
/// `fabricated` distingue « relue depuis le disque » de « décodée à l'instant »,
/// et cette distinction n'est pas cosmétique : c'est elle qui déclenche le
/// balayage d'éviction. Compter les lectures ferait balayer le dossier à chaque
/// ouverture du panneau, pour un dossier qui n'a pas grossi d'un octet.
private struct ThumbnailReading: Sendable {
    let image: ThumbnailImage?
    let fabricated: Bool

    static let nothing = ThumbnailReading(image: nil, fabricated: false)
}

// MARK: - Le cache

/// Fabrique, range et relit les vignettes des images du presse-papiers.
///
/// ```
///   ligne ──▶ mémoire ──▶ disque ──▶ ImageIO (sous-échantillonné)
///             0 ms         ~0,3 ms    ~15 ms, hors du fil principal
/// ```
///
/// ## Ce que chaque étage achète
///
/// **Le cache mémoire achète le défilement.** SwiftUI reconstruit le corps d'une
/// ligne à chaque passage devant les yeux, plusieurs fois par seconde ; sans lui,
/// chaque reconstruction relancerait une lecture disque pour une image déjà
/// affichée. Il est interrogeable **synchroniquement** — voir `cached(for:size:)`
/// — parce que c'est la seule façon qu'une ligne se dessine sans jamais montrer
/// de trou : ce qui a déjà été vu réapparaît dans la même image.
///
/// **Le cache disque achète le lancement suivant, et la première ouverture du
/// panneau.** La mémoire part avec le processus ; le dossier, lui, reste. C'est
/// aussi lui qui rend l'étage mémoire bornable sans conséquence : ce qu'il évince
/// n'est pas perdu, seulement remis à 0,3 ms au lieu de 0.
///
/// **Et le nommage par empreinte achète le reste** : deux entrées qui citent la
/// même image n'en fabriquent qu'une, sans qu'aucun registre ne l'organise. Voir
/// `ThumbnailPlan`.
///
/// ## Ce que ce fichier ne décide pas
///
/// Rien. Où vit une vignette, comment elle s'appelle, ce qui n'en a jamais, ce
/// qui doit partir : tout est dans `ThumbnailPlan`, qui n'importe que
/// `Foundation` et se vérifie sans écran ni image. Ici il n'y a qu'ImageIO qui
/// obéit et un `removeItem` qui obéit à une liste de noms.
@MainActor
final class ThumbnailCache {

    /// Le magasin, pour deux questions qu'il est seul à savoir répondre : où il
    /// range sa bibliothèque (`folder`, une fermeture chez lui, donc changer le
    /// dossier dans les réglages déménage aussi le cache) et où est le contenu
    /// lourd d'une entrée (`blobURL(for:of:)`, qui rend déjà `nil` pour une
    /// entrée purgée sans toucher au disque).
    ///
    /// Le prendre en entier plutôt que deux fermetures garantit qu'on cherche le
    /// blob exactement là où il a été écrit — deux dérivations du même chemin
    /// finissent toujours par diverger.
    private let store: ClipboardStore

    private let plan: ThumbnailPlan

    /// **`NSCache` et non un dictionnaire à la main.** Un dictionnaire borné à
    /// N entrées est un pari sur une valeur de N qu'on ne saura jamais régler ;
    /// `NSCache` répond en plus à la pression mémoire du système, ce qu'aucun
    /// plafond fixe ne sait faire. On perd le déterminisme de l'éviction — sans
    /// aucune importance : ce qui disparaît de la mémoire est encore sur le
    /// disque, à 0,3 ms.
    private let memory = NSCache<NSString, ThumbnailImage>()

    /// Les fabrications en cours, par nom de fichier.
    ///
    /// **Ce qu'elles évitent :** l'ouverture du panneau fait apparaître dix lignes
    /// d'un coup, et SwiftUI appelle volontiers deux fois `task` sur la même ligne
    /// (apparition, réapparition, changement de taille). Sans cette table, la
    /// même image serait décodée deux fois en parallèle, et les deux écriraient
    /// le même fichier. Avec, le second appelant attend le premier.
    private var inFlight: [String: Task<ThumbnailReading, Never>] = [:]

    /// Combien de fabrications depuis le dernier balayage, et un verrou pour ne
    /// pas en lancer deux.
    private var writesSinceSweep = 0
    private var sweeping = false

    /// Un balayage tous les 64 fichiers écrits.
    ///
    /// Balayer à chaque écriture coûterait un listage de dossier par vignette,
    /// c'est-à-dire de l'I/O proportionnelle à ce qu'on essaie d'accélérer. Ne
    /// jamais balayer sauf au lancement laisserait une session très longue
    /// dépasser le plafond sans limite. 64 fichiers, c'est au plus ~7 Mo de
    /// dépassement entre deux balayages, et un listage de dossier de temps en
    /// temps.
    private static let sweepInterval = 64

    /// Le plafond de l'étage mémoire, en octets de bitmap décodé.
    ///
    /// 32 Mio, soit ~1 200 vignettes de ligne ou ~128 vignettes de détail. Une
    /// fenêtre de panneau en montre au plus quelques dizaines ; le reste du
    /// plafond sert à ce que remonter dans la liste ne redemande rien au disque.
    private static let memoryCostLimit = 32 * 1024 * 1024

    init(store: ClipboardStore, plan: ThumbnailPlan = .default) {
        self.store = store
        self.plan = plan
        memory.totalCostLimit = Self.memoryCostLimit
    }

    // MARK: - Ce que la ligne demande

    /// La vignette déjà en mémoire, ou `nil`. **Aucun accès disque, aucun
    /// décodage, aucune attente.**
    ///
    /// C'est la méthode que le corps d'une ligne appelle. `ThumbnailPlan.source`
    /// répond d'abord, sans toucher au disque, si cette entrée peut avoir une
    /// vignette du tout — un texte, un fichier, une entrée purgée ou refusée
    /// n'interrogent même pas la mémoire et dessinent leur symbole de repli.
    func cached(for entry: ClipboardEntry, size: ThumbnailSize = .row) -> CGImage? {
        guard let blob = ThumbnailPlan.source(for: entry) else { return nil }
        let name = ThumbnailPlan.fileName(for: blob, size: size)
        return memory.object(forKey: name as NSString)?.image
    }

    /// La vignette, quel qu'en soit le prix : mémoire, puis disque, puis
    /// décodage sous-échantillonné.
    ///
    /// **Rend `nil` sans bruit** quand il n'y a rien à montrer — entrée sans
    /// image, blob purgé, fichier absent, fichier illisible. Une image manquante
    /// n'est jamais une panne bruyante : la ligne affiche son symbole de repli,
    /// et une entrée dont le blob a été purgé sait déjà dire *pourquoi*
    /// (« Image de 1,2 Mo, purgée le 10 août »). Un bandeau d'erreur pour une
    /// vignette occuperait le seul canal réservé aux pannes qui demandent une
    /// action.
    ///
    /// **Le décodage n'est jamais sur le fil de l'interface.** Tout ce qui touche
    /// vraiment le disque ou ImageIO est une `nonisolated static` attendue depuis
    /// ici — le motif de `RecordingStore.scan(root:)` et de `ClipboardStore`. Ce
    /// qui reste sur le `MainActor` : trois consultations de dictionnaire et deux
    /// constructions d'`URL`.
    @discardableResult
    func thumbnail(for entry: ClipboardEntry, size: ThumbnailSize = .row) async -> CGImage? {
        guard let blob = ThumbnailPlan.source(for: entry) else { return nil }
        let name = ThumbnailPlan.fileName(for: blob, size: size)

        if let hit = memory.object(forKey: name as NSString) { return hit.image }

        // Quelqu'un fabrique déjà celle-là : on attend son résultat plutôt que de
        // décoder la même image une seconde fois.
        if let running = inFlight[name] { return await running.value.image?.image }

        guard let source = store.blobURL(for: blob, of: entry) else { return nil }
        let destination = ThumbnailPlan.url(for: blob, size: size, in: store.folder)
        let maxPixelSize = size.maxPixelSize

        // `Task` hérite du `MainActor`, mais `make` est `nonisolated` : c'est
        // elle qui rend la main au fil principal, et tout le poids est derrière
        // elle.
        let task = Task<ThumbnailReading, Never> {
            await Self.make(source: source, destination: destination, maxPixelSize: maxPixelSize)
        }
        inFlight[name] = task

        let reading = await task.value
        inFlight[name] = nil

        guard let produced = reading.image else { return nil }
        memory.setObject(produced, forKey: name as NSString, cost: produced.cost)
        if reading.fabricated { noteFabrication() }
        return produced.image
    }

    /// Oublie l'étage mémoire, sans toucher au disque.
    ///
    /// Pour la fermeture du panneau si elle devait libérer de la mémoire, et pour
    /// les réglages qui changent la racine de la bibliothèque : les vignettes de
    /// l'ancien dossier sont encore valables par leur nom, mais rien ne garantit
    /// qu'elles soient encore là.
    func forgetMemory() {
        memory.removeAllObjects()
    }

    // MARK: - L'éviction

    /// Applique la politique du plan au dossier de cache.
    ///
    /// À appeler au lancement, à côté de `purgeExpired()` et de
    /// `collectOrphanedBlobs()` — c'est le même geste et le même moment. Le reste
    /// du temps, elle se déclenche seule tous les `sweepInterval` fichiers écrits.
    ///
    /// - Returns: le nombre de vignettes supprimées. Zéro dans la vie normale.
    @discardableResult
    func sweep() async -> Int {
        await Self.evict(in: ThumbnailPlan.folder(in: store.folder), plan: plan)
    }

    private func noteFabrication() {
        writesSinceSweep += 1
        guard writesSinceSweep >= Self.sweepInterval, sweeping == false else { return }
        writesSinceSweep = 0
        sweeping = true
        Task { [weak self] in
            _ = await self?.sweep()
            self?.sweeping = false
        }
    }

    // MARK: - Le disque, hors du fil principal

    /// Le disque d'abord, ImageIO seulement s'il le faut.
    private nonisolated static func make(
        source: URL, destination: URL, maxPixelSize: Int
    ) async -> ThumbnailReading {
        if let existing = read(destination) {
            // La date de dernier usage est ce sur quoi l'éviction classe. Elle
            // n'est touchée qu'ici — donc au plus une fois par vignette et par
            // lancement, puisque l'étage mémoire absorbe toutes les relectures
            // suivantes. Touchée à chaque affichage, elle coûterait une écriture
            // de métadonnées par ligne dessinée.
            touch(destination)
            return ThumbnailReading(image: existing, fabricated: false)
        }

        guard let rendered = render(source: source, maxPixelSize: maxPixelSize) else {
            return .nothing
        }
        return ThumbnailReading(image: ThumbnailImage(rendered), fabricated: write(rendered, to: destination))
    }

    /// Fabrique la vignette **sans jamais matérialiser l'image entière**.
    ///
    /// `CGImageSourceCreateThumbnailAtIndex` avec
    /// `kCGImageSourceThumbnailMaxPixelSize` sous-échantillonne pendant le
    /// décodage : une image de 10000×10000 rend une vignette de 256 px sans que
    /// les 400 Mo de bitmap plein n'existent jamais. L'alternative — décoder puis
    /// redimensionner avec un `CGContext` — donne le même pixel à l'arrivée et
    /// fait exactement exploser la mémoire qu'on cherche à protéger. C'est le
    /// seul point non négociable de ce fichier.
    ///
    /// Les options comptent :
    ///
    /// - `…FromImageAlways` et non `…IfAbsent` : la vignette intégrée d'un JPEG
    ///   fait souvent 160 px, parfois moins, et ne correspond parfois plus à
    ///   l'image après une retouche. On paierait un décodage pour une image
    ///   floue, ce qui est le pire des deux mondes ;
    /// - `…WithTransform` : sans lui, une photo prise au téléphone et collée
    ///   s'affiche couchée. L'orientation est dans l'EXIF, pas dans les pixels ;
    /// - `…ShouldCacheImmediately` : force le décodage **ici**, sur ce fil. Sans
    ///   lui, ImageIO peut rendre une image paresseuse dont les pixels seront lus
    ///   au premier dessin — c'est-à-dire sur le fil de l'interface, exactement
    ///   ce que toute cette machinerie existe pour éviter ;
    /// - `kCGImageSourceShouldCache: false` à l'ouverture de la source : on ne
    ///   veut pas qu'ImageIO garde l'image plein format en cache après avoir
    ///   fabriqué la vignette. Elle est justement ce qu'on refuse de tenir en
    ///   mémoire.
    private nonisolated static func render(source: URL, maxPixelSize: Int) -> CGImage? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let imageSource = CGImageSourceCreateWithURL(
            source as CFURL, sourceOptions as CFDictionary
        ) else {
            // Fichier absent, illisible, ou format qu'ImageIO ne connaît pas. Ce
            // n'est pas une panne : la ligne affiche son symbole de repli. Une
            // trace au journal, et rien dans `problem`.
            thumbnailLog.debug("Vignette : source illisible \(source.lastPathComponent, privacy: .public)")
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary)
    }

    /// Relit une vignette déjà fabriquée.
    ///
    /// **`ShouldCacheImmediately` n'est pas une optimisation ici, c'est une
    /// correction.** `CGImageSourceCreateWithURL` rend un `CGImage` *paresseux* :
    /// les pixels ne sont lus qu'au moment où on les demande. Deux conséquences,
    /// et le dépôt a déjà payé la première au prix fort dans
    /// `SystemRegionCapturer.decoded(_:)` — une image « valide » de 1800×240 sans
    /// un seul pixel derrière, parce que le fichier avait disparu entre-temps.
    /// Ici le fichier peut disparaître pour de bon : c'est **notre propre
    /// éviction** qui le supprime. Et le décodage paresseux se ferait au premier
    /// dessin, donc sur le fil de l'interface.
    private nonisolated static func read(_ url: URL) -> ThumbnailImage? {
        let options: [CFString: Any] = [kCGImageSourceShouldCacheImmediately: true]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return ThumbnailImage(image)
    }

    /// Écrit la vignette à côté des autres.
    ///
    /// **Écriture directe, sans fichier temporaire ni renommage.** Un plantage en
    /// plein milieu laisse un PNG tronqué, que la relecture suivante ne saura pas
    /// décoder — donc qu'elle refabriquera et réécrira par-dessus. Le défaut se
    /// répare tout seul. Le détour par un `<nom>.part` renommé ensuite
    /// échangerait ça contre pire : un `.part` abandonné par le même plantage
    /// échoue à `ThumbnailPlan.isSelfWritten`, donc l'éviction refuse d'y toucher,
    /// donc il reste pour toujours. On préfère un défaut qui se répare à une
    /// fuite qui ne se répare pas.
    ///
    /// - Returns: `true` si le fichier a bien été écrit. `false` n'empêche rien :
    ///   la vignette est en mémoire et s'affichera, elle sera simplement
    ///   refabriquée au prochain lancement.
    private nonisolated static func write(_ image: CGImage, to url: URL) -> Bool {
        let folder = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            thumbnailLog.error("Dossier des vignettes non créé : \(error.localizedDescription, privacy: .public)")
            return false
        }

        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else {
            thumbnailLog.error("Vignette non écrite : destination refusée")
            return false
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            thumbnailLog.error("Vignette non écrite : encodage refusé")
            return false
        }
        return true
    }

    /// Marque la vignette comme utilisée à l'instant. C'est la seule chose qui
    /// alimente le classement de l'éviction.
    private nonisolated static func touch(_ url: URL) {
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()], ofItemAtPath: url.path(percentEncoded: false)
        )
    }

    /// Supprime ce que le plan désigne, et **rien d'autre**.
    ///
    /// Trois gardes, dont deux sont redondantes exprès :
    ///
    /// - le plan ne rend que des **noms**, jamais des chemins. Ils sont joints
    ///   ici au dossier de cache, donc une suppression ne peut pas désigner un
    ///   fichier ailleurs, quelle que soit la façon dont la liste a été obtenue ;
    /// - `isSelfWritten` est redemandé au moment du `removeItem` — c'est cette
    ///   ligne-là qui détruit, c'est donc elle qui doit poser la question. Il
    ///   interdit du même coup tout nom capable de sortir du dossier : un `/` ou
    ///   un `..` échoue au test hexadécimal ;
    /// - un dossier nommé comme une vignette n'est pas un fichier régulier, donc
    ///   n'entre même pas dans la liste : `removeItem` l'emporterait avec son
    ///   contenu.
    ///
    /// Un dossier illisible rend zéro sans rien dire. Une éviction est un
    /// confort ; ne pas pouvoir l'exécuter ne coûte que des octets, et il n'y a
    /// rien que l'utilisateur puisse en faire.
    private nonisolated static func evict(in folder: URL, plan: ThumbnailPlan) async -> Int {
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let urls = try? manager.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return 0 }

        var files: [CachedThumbnail] = []
        for url in urls {
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }
            files.append(
                CachedThumbnail(
                    name: url.lastPathComponent,
                    bytes: values?.fileSize ?? 0,
                    // Une date absente vaut « jamais utilisée » : c'est le
                    // classement le plus défavorable, donc celui qui ne peut pas
                    // faire évincer une vignette réellement utilisée à sa place.
                    lastUsed: values?.contentModificationDate ?? .distantPast
                )
            )
        }

        let doomed = plan.filesToEvict(from: files)
        guard doomed.isEmpty == false else { return 0 }

        var removed = 0
        var reclaimed = 0
        for name in doomed where ThumbnailPlan.isSelfWritten(name) {
            let url = folder.appending(path: name)
            let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            do {
                try manager.removeItem(at: url)
                removed += 1
                reclaimed += bytes
            } catch {
                thumbnailLog.error(
                    "Vignette non évincée : \(name, privacy: .public) — \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        if removed > 0 {
            thumbnailLog.notice(
                "\(removed, privacy: .public) vignette(s) évincée(s), \(reclaimed, privacy: .public) octets"
            )
        }
        return removed
    }
}
