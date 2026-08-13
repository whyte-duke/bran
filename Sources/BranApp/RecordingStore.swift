import AVFoundation
import BranCore
import Foundation
import Observation

/// La bibliothèque. **Le dossier est la source de vérité**, pas l'inverse.
///
/// `reload()` lit `~/Movies/bran`, apparie chaque `.mp4` avec son `.json`, et
/// fabrique des métadonnées minimales pour les fichiers orphelins. Conséquence
/// directe : un enregistrement fait avant l'existence de cette classe apparaît
/// quand même, et supprimer le `.json` ne fait pas disparaître la vidéo.
///
/// **Deux dispositions cohabitent, et elles cohabiteront indéfiniment.**
///
/// L'ancienne met tout à plat dans la racine, sous des noms d'UUID :
/// `<root>/<uuid>.mp4`, `<root>/<uuid>.json`, `<root>/<uuid>-seg000.mp4`. Rien
/// là-dedans ne se lit, mais c'est ce qui est sur le disque des gens, et un
/// balayage qui cesserait de la comprendre ferait disparaître des mois de
/// réunions d'un coup de mise à jour.
///
/// La nouvelle donne un dossier par rendez-vous, décrit par `MeetingFolder` et
/// lu par `MeetingBundle`. Le balayage produit les deux et les fusionne en une
/// seule liste triée ; le passage de l'une à l'autre est un geste **explicite**
/// de l'utilisateur — `tidyLegacyRecordings()` —, jamais un effet de bord d'un
/// lancement. Déplacer plusieurs gigaoctets de réunions à l'insu de quelqu'un
/// est exactement ce qu'on ne fait pas.
@MainActor
@Observable
final class RecordingStore {

    private(set) var recordings: [Recording] = []
    private(set) var isScanning = false

    private(set) var root: URL

    /// Le dossier des sessions ouvertes, avant qu'un balayage les ait vues.
    ///
    /// **Une passerelle, pas un cache.** `beginSession` crée le dossier et y
    /// écrit la fiche, mais ne relit pas le disque : entre ce moment et le
    /// premier `reload()`, `recordings` ne connaît pas encore la session, et
    /// c'est précisément la fenêtre pendant laquelle `CaptureSession` demande où
    /// écrire ses morceaux. Sans cette table, il écrirait dans la racine et on
    /// retrouverait une réunion coupée en deux dispositions.
    ///
    /// `recordings` reste prioritaire dès qu'il connaît l'enregistrement : c'est
    /// lui qui a lu le disque, donc lui qui sait si l'utilisateur a renommé le
    /// dossier dans le Finder pendant que la réunion tournait.
    private var sessionFolders: [UUID: URL] = [:]

    /// Ce que la bibliothèque n'a pas réussi à écrire, ou à relire fiche par
    /// fiche. Câblé par `AppModel` sur `lastFailure`.
    ///
    /// **Pas `problem`, volontairement.** `problem` remplace la liste entière par
    /// « Enregistrements introuvables » : c'est juste pour un dossier illisible,
    /// c'est absurde pour un titre qui n'a pas pu être sauvegardé — on masquerait
    /// quarante réunions intactes à cause d'une frappe. Ces ennuis-là passent par
    /// le canal d'échec unique de bran, celui du bandeau et du menu, exactement
    /// comme `AwakeController.onFailure`.
    var onProblem: (@MainActor (String) -> Void)?

    init(root: URL = StorageLocation.default) {
        self.root = root
    }

    func setRoot(_ url: URL) async {
        guard url != root else { return }
        root = url
        // Les dossiers de session retenus appartiennent à l'ancienne racine.
        // Les garder ferait écrire la fiche d'une réunion en cours dans un
        // dossier que l'utilisateur vient de quitter — donc hors de la
        // bibliothèque qu'il regarde.
        sessionFolders.removeAll()
        await reload()
    }

    // MARK: - Lecture

    func reload() async {
        isScanning = true
        defer { isScanning = false }

        let scan = await Self.scan(root: root)
        recordings = scan.recordings.sorted { $0.metadata.startedAt > $1.metadata.startedAt }
        problem = scan.problem

        // Une fiche abîmée n'empêche pas la bibliothèque de s'afficher — les
        // autres réunions sont là, et celle-ci aussi, sous sa date. Elle a
        // seulement perdu son identité, et ça se dit ailleurs que dans un écran
        // vide.
        for fault in scan.faults { onProblem?(fault) }
    }

    /// **Ce qui empêche de lire le dossier, quand quelque chose l'empêche.**
    ///
    /// `DictationStore` et `WatchStore` en ont un depuis toujours ; celui-ci
    /// n'en avait pas, et son `try?` rendait un tableau vide. Un volume externe
    /// démonté, un dossier renommé, une autorisation retirée : quarante réunions
    /// intactes sur le disque, et l'écran qui annonce « Aucun enregistrement ».
    /// C'est la pire forme d'un défaut de lecture — elle ressemble à une perte
    /// de données, et on cherche le problème là où il n'est pas.
    private(set) var problem: String?

    /// Suffixe des morceaux intermédiaires — `<base>-seg000.mp4`. Ils ne sont
    /// jamais des entrées de bibliothèque : ce sont les pièces détachées d'une
    /// session, pas des enregistrements.
    ///
    /// Repris de `MeetingFolder` plutôt que redéclaré ici, comme c'était le cas :
    /// deux constantes pour un même suffixe, c'est une occasion de les faire
    /// diverger, et le jour où elles divergent la fusion cesse de reconnaître ses
    /// propres morceaux.
    private nonisolated static var segmentMarker: String { MeetingFolder.segmentMarker }

    struct Scan: Sendable {
        let recordings: [Recording]

        /// Ce qui empêche de lire le **dossier**. Bloquant : sans lui, il n'y a
        /// pas de bibliothèque du tout.
        let problem: String?

        /// Ce qui a mal tourné **fiche par fiche**. Non bloquant : les autres
        /// enregistrements s'affichent normalement.
        let faults: [String]
    }

    private nonisolated static func scan(root: URL) async -> Scan {
        let manager = FileManager.default
        let path = root.path(percentEncoded: false)

        let names: [String]
        do {
            names = try manager.contentsOfDirectory(atPath: path)
        } catch {
            // Un dossier absent est **normal** : c'est le premier lancement,
            // avant le premier enregistrement. Tout le reste — volume démonté,
            // droits retirés, chemin devenu un fichier — est un problème, et il
            // doit se dire. C'est la même distinction que `WeekLoader.harvest`
            // fait entre un jour sans veille et un journal refusé.
            let cocoa = error as NSError
            let missing = cocoa.domain == NSCocoaErrorDomain
                && cocoa.code == NSFileReadNoSuchFileError
            return Scan(
                recordings: [],
                problem: missing ? nil : "Dossier des enregistrements illisible : \(error.localizedDescription)",
                faults: []
            )
        }

        // Les sous-dossiers d'abord, les fichiers ensuite. L'ordre compte pour la
        // fusion plus bas : à identifiant égal, c'est le premier arrivé qui est
        // gardé, et la disposition en dossiers est celle vers laquelle on va.
        var directories: [String] = []
        var files: [String] = []

        for name in names.sorted() {
            var isDirectory: ObjCBool = false
            let entry = root.appending(path: name)
            guard manager.fileExists(atPath: entry.path(percentEncoded: false), isDirectory: &isDirectory)
            else { continue }
            if isDirectory.boolValue { directories.append(name) } else { files.append(name) }
        }

        var found: [Recording] = []
        var faults: [String] = []

        // MARK: Disposition en dossiers

        for name in directories {
            // `MeetingBundle.read` rend `nil` pour tout ce qui n'a pas de
            // `Fiche.json` : c'est ce qui laisse passer `Dictées`, `Captures`,
            // `Veille`, `Clipboard` et `Journal` sans les transformer en
            // réunions fantômes, alors même que plusieurs contiennent des
            // `.json`.
            guard let bundle = MeetingBundle.read(folder: root.appending(path: name)) else { continue }

            let outcome = await recording(from: bundle)
            found.append(outcome.recording)
            if let fault = outcome.fault { faults.append(fault) }
        }

        // MARK: Ancienne disposition, à plat

        let finals = files.filter { $0.hasSuffix(".mp4") && $0.contains(segmentMarker) == false }
        let segments = files.filter { $0.hasSuffix(".mp4") && $0.contains(segmentMarker) }

        for name in finals {
            let url = root.appending(path: name)
            let identifier = UUID(uuidString: (name as NSString).deletingPathExtension)

            let attributes = try? manager.attributesOfItem(atPath: url.path(percentEncoded: false))

            var stored: RecordingMetadata?
            var hasSidecar = false

            if let identifier {
                switch readSidecar(root: root, identifier: identifier) {
                case .success(let metadata):
                    stored = metadata
                    hasSidecar = true
                case .failure(let fault):
                    // Une fiche présente mais illisible n'est PAS une absence.
                    // `hasMetadataFile` reste vrai : la vidéo n'est pas une
                    // orpheline, elle est une réunion dont la fiche est cassée,
                    // et la bibliothèque la marque donc « interrompue » au lieu
                    // de la présenter comme un fichier quelconque.
                    hasSidecar = fault.isNormal == false
                    if let note = fault.listingNote(for: "\(identifier.uuidString).json") {
                        faults.append(note)
                    }
                }
            }

            found.append(
                Recording(
                    metadata: stored ?? RecordingMetadata(
                        id: identifier ?? UUID(),
                        startedAt: attributes?[.creationDate] as? Date ?? .now
                    ),
                    url: url,
                    fileSize: attributes?[.size] as? Int64 ?? 0,
                    duration: await durationOfFile(at: url),
                    existsOnDisk: true,
                    hasMetadataFile: hasSidecar,
                    // Relevés même quand le fichier final existe : après une
                    // session mal terminée, le post-traitement les conserve
                    // exprès, et ce sont eux qui portent les minutes que la
                    // fusion n'a peut-être pas reprises.
                    segmentURLs: identifier.map { Self.segmentURLs(of: $0, among: segments, in: root) } ?? [],
                    scannedFolder: root,
                    isFlat: true
                )
            )
        }

        // Sessions dont le fichier final n'existe pas encore : enregistrement en
        // cours, ou post-traitement pas terminé. Sans elles, une session
        // disparaîtrait de la bibliothèque entre l'arrêt et la fin de la
        // compression — le moment exact où on regarde si ça a marché.
        let finalIdentifiers = Set(
            found.filter(\.isFlat).map(\.id)
        )

        for name in files where name.hasSuffix(".json") {
            guard let identifier = UUID(uuidString: (name as NSString).deletingPathExtension),
                  finalIdentifiers.contains(identifier) == false
            else { continue }

            let metadata: RecordingMetadata
            switch readSidecar(root: root, identifier: identifier) {
            case .success(let decoded):
                metadata = decoded
            case .failure(let fault):
                // Ici, la fiche est tout ce qu'on a : aucun `.mp4` final ne
                // porte cette session. La perdre en silence, c'est faire
                // disparaître de la bibliothèque une réunion dont les segments
                // sont peut-être encore sur le disque.
                if let note = fault.listingNote(for: name) { faults.append(note) }
                continue
            }

            let pieces = Self.segmentURLs(of: identifier, among: segments, in: root)
            let size = pieces.reduce(Int64.zero) { total, piece in
                let attributes = try? manager.attributesOfItem(atPath: piece.path(percentEncoded: false))
                return total + (attributes?[.size] as? Int64 ?? 0)
            }

            found.append(
                Recording(
                    metadata: metadata,
                    url: root.appending(path: metadata.fileName),
                    fileSize: size,
                    duration: nil,
                    existsOnDisk: false,
                    hasMetadataFile: true,
                    segmentURLs: pieces,
                    scannedFolder: root,
                    isFlat: true
                )
            )
        }

        return Scan(recordings: merged(found), problem: nil, faults: faults)
    }

    /// Fusionne les deux dispositions en une seule liste, sans doublon.
    ///
    /// **Un même identifiant peut légitimement apparaître deux fois pendant un
    /// rangement.** `tidyLegacyRecordings` écrit la `Fiche.json` du dossier
    /// *avant* d'y déplacer la vidéo, et n'efface l'ancien `<uuid>.json` qu'à la
    /// toute fin : entre les deux, la réunion existe des deux côtés. Sans cette
    /// passe, la bibliothèque afficherait la même réunion deux fois, et une
    /// `List` SwiftUI avec deux identités égales ne se contente pas d'être
    /// laide — elle perd la sélection et les animations.
    ///
    /// La règle de départage est celle qui protège l'utilisateur : **le dossier
    /// gagne, sauf s'il est vide de média et que l'entrée à plat, elle, en a**.
    /// C'est exactement l'état d'un rangement interrompu juste après l'écriture
    /// de la fiche : préférer bêtement le dossier montrerait une réunion sans
    /// vidéo alors que la vidéo est sur le disque, à l'ancienne place, et
    /// l'utilisateur conclurait à une perte.
    ///
    /// La même règle sert au cas plus rare de deux dossiers portant la même
    /// fiche — un dossier dupliqué à la main dans le Finder.
    ///
    /// **Le départage se fait en deux temps, et « jouable » ne suffisait pas.**
    /// Le premier critère est la présence d'un fichier FINAL, pas d'un fichier
    /// quelconque : un rangement qui a déplacé un morceau brut puis buté sur la
    /// vidéo laisse un dossier « jouable » — il contient un `-seg000.mp4` — face
    /// à une entrée à plat qui porte, elle, la réunion entière et compressée.
    /// Départager sur « jouable » faisait alors gagner le dossier, et la
    /// bibliothèque montrait quelques minutes de morceau brut à la place d'une
    /// réunion complète qui était sur le disque, intacte, deux dossiers plus
    /// haut. Les morceaux ne servent de critère qu'entre deux candidats dont
    /// aucun n'a de fichier final.
    private nonisolated static func merged(_ candidates: [Recording]) -> [Recording] {
        var byIdentifier: [UUID: Recording] = [:]
        var order: [UUID] = []

        /// Ce qu'un candidat a de mieux à offrir : une vidéo finale, à défaut des
        /// morceaux bruts, à défaut rien.
        func substance(_ recording: Recording) -> Int {
            if recording.existsOnDisk { return 2 }
            if recording.segmentURLs.isEmpty == false { return 1 }
            return 0
        }

        for candidate in candidates {
            guard let existing = byIdentifier[candidate.id] else {
                byIdentifier[candidate.id] = candidate
                order.append(candidate.id)
                continue
            }

            // À égalité, le premier arrivé reste : le balayage lit les dossiers
            // avant les fichiers à plat, et c'est la disposition vers laquelle on
            // va.
            if substance(candidate) > substance(existing) {
                byIdentifier[candidate.id] = candidate
            }
        }

        return order.compactMap { byIdentifier[$0] }
    }

    /// Une entrée de bibliothèque à partir d'un dossier de rendez-vous.
    private nonisolated static func recording(
        from bundle: MeetingBundle
    ) async -> (recording: Recording, fault: String?) {
        let manager = FileManager.default

        var stored: RecordingMetadata?
        var hasSidecar = false
        var fault: String?

        switch readSidecar(at: bundle.sidecar) {
        case .success(let metadata):
            stored = metadata
            hasSidecar = true
        case .failure(let problem):
            // Même règle qu'à plat, et elle compte davantage ici : une
            // `Fiche.json` corrompue ne doit pas faire disparaître le dossier de
            // la bibliothèque. La vidéo et l'audio du CRM sont juste à côté,
            // intacts, et c'est le moment précis où on a besoin de les voir pour
            // les récupérer. On perd le titre, pas la réunion.
            hasSidecar = problem.isNormal == false
            // Le nom affiché porte le dossier : « Fiche.json » tout court
            // désignerait n'importe laquelle des quarante réunions, et un
            // message qui ne dit pas où chercher ne sert à rien.
            fault = problem.listingNote(
                for: "\(bundle.folder.lastPathComponent)/\(MeetingFolder.sidecarName)"
            )
        }

        let videoAttributes = bundle.video.flatMap {
            try? manager.attributesOfItem(atPath: $0.path(percentEncoded: false))
        }
        let audioAttributes = bundle.audio.flatMap {
            try? manager.attributesOfItem(atPath: $0.path(percentEncoded: false))
        }

        // Poids : la vidéo finale, ou à défaut la somme des morceaux bruts.
        // Afficher « 0 octet » pendant qu'une session tourne donnerait
        // l'impression que rien n'est capturé, alors que le disque se remplit.
        let size: Int64
        if let attributes = videoAttributes {
            size = attributes[.size] as? Int64 ?? 0
        } else {
            size = bundle.segments.reduce(Int64.zero) { total, piece in
                let attributes = try? manager.attributesOfItem(atPath: piece.path(percentEncoded: false))
                return total + (attributes?[.size] as? Int64 ?? 0)
            }
        }

        let folderAttributes = try? manager.attributesOfItem(
            atPath: bundle.folder.path(percentEncoded: false)
        )
        let started = (videoAttributes?[.creationDate] as? Date)
            ?? (folderAttributes?[.creationDate] as? Date)
            ?? .now

        // Pas de durée sans fichier final : `AVURLAsset` sur un chemin qui
        // n'existe pas rend zéro, et « 0 min 00 s » sur une réunion en cours se
        // lit comme un enregistrement vide.
        var duration: TimeInterval?
        if let video = bundle.video { duration = await durationOfFile(at: video) }

        let metadata = stored ?? RecordingMetadata(
            // Un identifiant **dérivé du chemin**, et non un `UUID()` neuf.
            // Sans fiche lisible, on n'a pas d'identité à lire ; en tirer une au
            // hasard donnerait une identité différente à chaque balayage, donc
            // une ligne qui perd sa sélection et se réanime toutes les fois que
            // la bibliothèque se rafraîchit — sur la seule réunion pour laquelle
            // l'utilisateur est en train de se battre.
            id: syntheticIdentifier(for: bundle.folder),
            startedAt: started
        )

        return (
            Recording(
                metadata: metadata,
                // Sans vidéo, on pointe là où elle **doit** aller : c'est ce que
                // le lecteur et le repli de « Afficher dans le Finder »
                // attendent, et ça reste dans le dossier de la réunion.
                url: bundle.video ?? MeetingBundle.videoDestination(in: bundle.folder),
                fileSize: size,
                duration: duration,
                existsOnDisk: bundle.video != nil,
                hasMetadataFile: hasSidecar,
                segmentURLs: bundle.segments,
                scannedFolder: bundle.folder,
                isFlat: false,
                audioURL: bundle.audio,
                audioBytes: audioAttributes?[.size] as? Int64
            ),
            fault
        )
    }

    /// Les morceaux bruts d'une session à plat, dans l'ordre où ils ont été
    /// écrits.
    ///
    /// Triés par nom, ce qui suffit : `seg000`, `seg001`… sont zéro-remplis
    /// précisément pour que l'ordre alphabétique soit l'ordre chronologique.
    private nonisolated static func segmentURLs(
        of identifier: UUID,
        among segments: [String],
        in root: URL
    ) -> [URL] {
        let prefix = "\(identifier.uuidString)\(segmentMarker)"
        return segments
            .filter { $0.hasPrefix(prefix) }
            .sorted()
            .map { root.appending(path: $0) }
    }

    /// Le numéro d'un morceau brut, lu dans son nom. `nil` si le nom ne se
    /// termine pas par des chiffres — un fichier renommé à la main, par exemple.
    private nonisolated static func segmentIndex(of url: URL) -> Int? {
        let base = url.deletingPathExtension().lastPathComponent
        guard let marker = base.range(of: segmentMarker, options: .backwards) else { return nil }
        return Int(base[marker.upperBound...])
    }

    /// Une identité stable pour un dossier dont la fiche ne se décode pas.
    ///
    /// FNV-1a, deux passes de sens opposés pour remplir les seize octets. Ni
    /// `Hasher` (sa graine change à chaque lancement du processus, donc la
    /// sélection sauterait au redémarrage) ni CryptoKit (on ne cherche pas à
    /// résister à une attaque, seulement à ce que le même dossier donne toujours
    /// la même ligne). Ce n'est pas un UUID au sens de la RFC — il n'est ni tiré
    /// au sort ni versionné —, et il n'a pas à l'être : il ne sert qu'à
    /// identifier une ligne de liste, et il n'est jamais écrit dans une fiche.
    private nonisolated static func syntheticIdentifier(for folder: URL) -> UUID {
        func hash(_ bytes: [UInt8], seed: UInt64) -> UInt64 {
            var value = seed
            for byte in bytes {
                value ^= UInt64(byte)
                value = value &* 0x0000_0100_0000_01B3
            }
            return value
        }

        let bytes = Array(folder.path(percentEncoded: false).utf8)
        let high = hash(bytes, seed: 0xCBF2_9CE4_8422_2325)
        let low = hash(Array(bytes.reversed()), seed: 0x9E37_79B9_7F4A_7C15)

        let digits = String(format: "%016llx%016llx", high, low)
        let first = digits.prefix(8)
        let rest = digits.dropFirst(8)
        let second = rest.prefix(4)
        let third = rest.dropFirst(4).prefix(4)
        let fourth = rest.dropFirst(8).prefix(4)
        let fifth = rest.dropFirst(12)

        return UUID(uuidString: "\(first)-\(second)-\(third)-\(fourth)-\(fifth)") ?? UUID()
    }

    /// Lit une fiche, ou dit pourquoi elle n'est pas lisible.
    ///
    /// L'ancienne version rendait `nil` dans les deux cas, et c'est ce qui
    /// rendait le défaut invisible : « aucune fiche » — un `.mp4` déposé à la
    /// main, parfaitement normal — et « une fiche qui ne se décode pas » — le
    /// titre, les notes, le rattachement CRM et l'état de la session partis sans
    /// un mot — donnaient exactement le même résultat à l'écran.
    private nonisolated static func readSidecar(at url: URL) -> Result<RecordingMetadata, SidecarFault> {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return .failure(.reading(error))
        }

        do {
            return .success(try JSONDecoder.bran.decode(RecordingMetadata.self, from: data))
        } catch {
            return .failure(.decoding(error))
        }
    }

    /// La fiche d'un enregistrement resté à plat, `<root>/<uuid>.json`.
    private nonisolated static func readSidecar(
        root: URL,
        identifier: UUID
    ) -> Result<RecordingMetadata, SidecarFault> {
        readSidecar(at: root.appending(path: "\(identifier.uuidString).json"))
    }

    private nonisolated static func durationOfFile(at url: URL) async -> TimeInterval? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration), duration.isNumeric else { return nil }
        return duration.seconds
    }

    // MARK: - Emplacements

    /// Le dossier d'un enregistrement connu, ou `nil`.
    ///
    /// `nil` veut dire « cette réunion n'a pas de dossier à elle » : soit elle
    /// est restée dans l'ancienne disposition, soit bran ne la connaît pas. Dans
    /// les deux cas l'appelant doit retomber sur la racine plutôt que d'inventer
    /// un chemin — rendre la racine ici aurait été plus commode et aurait fait
    /// écrire l'audio du CRM à côté des UUID, ce que le rangement en dossiers
    /// existe précisément pour éviter.
    func folder(for id: UUID) -> URL? {
        if let known = recordings.first(where: { $0.id == id }) {
            return known.isFlat ? nil : known.folderURL
        }
        return sessionFolders[id]
    }

    /// Où la fiche d'un enregistrement doit s'écrire : dans son dossier s'il en
    /// a un, à plat sinon.
    private func sidecarURL(for id: UUID) -> URL {
        guard let folder = folder(for: id) else {
            return root.appending(path: "\(id.uuidString).json")
        }
        return folder.appending(path: MeetingFolder.sidecarName)
    }

    /// Le nom d'une fiche tel qu'on le montre dans un message.
    ///
    /// `Fiche.json` tout court désignerait n'importe laquelle des réunions du
    /// disque ; un message d'erreur qui ne dit pas où chercher fait perdre plus
    /// de temps qu'il n'en fait gagner.
    private nonisolated static func displayName(of sidecar: URL) -> String {
        guard sidecar.lastPathComponent == MeetingFolder.sidecarName else {
            return sidecar.lastPathComponent
        }
        return "\(sidecar.deletingLastPathComponent().lastPathComponent)/\(MeetingFolder.sidecarName)"
    }

    /// Retient un nom de dossier libre dans la racine, et le crée si demandé.
    ///
    /// Trois cas se présentent quand le nom voulu est déjà pris, et ils
    /// n'appellent pas la même réponse :
    ///
    /// - **le dossier contient déjà notre `Fiche.json`** : c'est le nôtre, on le
    ///   reprend. C'est ce qui permet à un rangement interrompu de continuer là
    ///   où il s'était arrêté au lieu de fabriquer un « (2) » à côté ;
    /// - **le dossier existe sans `Fiche.json`** : on l'adopte. Le nom porte
    ///   l'horodatage à la minute près et le titre du rendez-vous ; un dossier
    ///   qui porte déjà ce nom-là est presque sûrement notre propre passage
    ///   précédent, interrompu avant d'avoir écrit sa fiche. Ne pas l'adopter
    ///   orphelinerait les gigaoctets qu'il contient — invisibles pour la
    ///   bibliothèque, puisque sans fiche, il n'est pas un dossier de réunion ;
    /// - **le dossier contient la `Fiche.json` d'un autre identifiant** : on
    ///   passe au suivant, sans discussion. C'est la règle non négociable : deux
    ///   réunions démarrées dans la même minute ne partagent jamais un dossier,
    ///   parce que la seconde écraserait la vidéo de la première, qui porte le
    ///   même nom qu'elle.
    ///
    /// `create: false` sert au renommage, qui a besoin d'un nom **entièrement
    /// libre** : `moveItem` refuse une destination existante, et l'adoption
    /// n'aurait aucun sens — on ne fusionne pas deux dossiers pour changer un
    /// titre.
    ///
    /// **Un type à soi plutôt qu'un `Result<URL, String>`.** `Result` exige un
    /// `Error` du côté de l'échec, et faire conformer `String` à `Error` pour la
    /// commodité de trois lignes rendrait toutes les chaînes de bran lançables :
    /// un `throw "quelque chose a raté"` deviendrait possible partout, et c'est
    /// exactement la sorte de raccourci qui remplace peu à peu les erreurs
    /// typées du dépôt par des phrases dont personne ne sait d'où elles
    /// viennent. Deux cas nommés coûtent quatre lignes et ne se propagent pas.
    private enum FolderReservation {
        case reserved(URL)
        /// La phrase à afficher, déjà écrite pour un humain.
        case refused(String)
    }

    private func reserveFolder(base: String, for id: UUID, create: Bool) -> FolderReservation {
        let manager = FileManager.default

        // Cinquante voisins suffisent très largement (il faudrait cinquante
        // réunions démarrées dans la même minute avec le même titre), et une
        // borne évite qu'un dossier en lecture seule fasse tourner la boucle
        // sans fin pendant qu'une réunion attend de commencer.
        for attempt in 1...50 {
            let name = attempt == 1 ? base : "\(base) (\(attempt))"
            // Sans `directoryHint: .isDirectory`, donc sans barre oblique
            // finale : c'est la forme que le balayage produit, et deux formes
            // pour un même dossier finiraient par se croiser dans une
            // comparaison d'URL.
            let candidate = root.appending(path: name)

            var isDirectory: ObjCBool = false
            let exists = manager.fileExists(
                atPath: candidate.path(percentEncoded: false),
                isDirectory: &isDirectory
            )

            if exists {
                guard create, isDirectory.boolValue else { continue }

                let sidecar = candidate.appending(path: MeetingFolder.sidecarName)
                guard manager.fileExists(atPath: sidecar.path(percentEncoded: false)) else {
                    return .reserved(candidate)
                }

                // Une fiche illisible vaut « occupé par quelqu'un d'autre » :
                // on ne sait pas de qui elle est, donc on n'y touche pas.
                guard case .success(let occupant) = Self.readSidecar(at: sidecar),
                      occupant.id == id
                else { continue }

                return .reserved(candidate)
            }

            if create {
                do {
                    try manager.createDirectory(at: candidate, withIntermediateDirectories: true)
                } catch {
                    return .refused(
                        "Dossier de réunion non créé (\(name)) : \(error.localizedDescription)."
                    )
                }
            }

            return .reserved(candidate)
        }

        return .refused(
            "Dossier de réunion non créé : cinquante noms voisins de « \(base) » sont déjà pris."
        )
    }

    // MARK: - Écriture

    /// Ouvre la session : crée le dossier du rendez-vous et y écrit la fiche.
    ///
    /// La fiche est écrite **dès le démarrage**, avant qu'une panne devienne
    /// possible. Un `.json` sans `endedAt` signale une session interrompue —
    /// c'est la sentinelle du §10, sans fichier `.lock` séparé à gérer.
    ///
    /// **Le repli quand le dossier ne peut pas être créé écrit quand même la
    /// fiche, à plat.** Disque plein, racine devenue lecture seule, volume
    /// démonté : renoncer à la sentinelle parce qu'un `mkdir` a échoué ferait
    /// perdre le seul signal qui survive à la fermeture de la fenêtre, et la
    /// réunion s'enregistrerait sans que rien ne sache qu'elle a commencé.
    /// L'appelant reçoit `nil`, comprend qu'il doit écrire dans la racine, et
    /// la réunion reste rangeable plus tard par `tidyLegacyRecordings()`.
    @discardableResult
    func beginSession(_ meeting: MeetingRef) -> URL? {
        let metadata = RecordingMetadata(meeting: meeting)
        let base = MeetingFolder.name(startedAt: meeting.startedAt, title: meeting.title)

        switch reserveFolder(base: base, for: meeting.id, create: true) {
        case .refused(let reason):
            onProblem?(
                reason + " La réunion est enregistrée dans le dossier principal ; "
                + "elle pourra être rangée plus tard depuis les réglages."
            )
            write(metadata, to: root.appending(path: metadata.sidecarName))
            return nil

        case .reserved(let folder):
            // La table est renseignée tout de suite, avant même que le balayage
            // ait vu ce dossier : c'est elle que `folder(for:)` lit pendant
            // toute la réunion, et donc elle qui décide où `CaptureSession`
            // écrit ses morceaux et où `mutate` écrit le titre saisi en cours de
            // route. Sans elle, la fiche de départ serait dans le dossier et
            // tout le reste dans la racine.
            sessionFolders[meeting.id] = folder

            guard write(metadata, to: folder.appending(path: MeetingFolder.sidecarName)) else {
                // Sans fiche, ce dossier n'est pas un dossier de réunion : le
                // retenir ferait écrire la vidéo dans un dossier que le balayage
                // ignore, donc invisible dans la bibliothèque.
                sessionFolders[meeting.id] = nil
                return nil
            }

            return folder
        }
    }

    /// Aligne le nom du dossier — et celui de ses fichiers média — sur le titre
    /// courant de la fiche.
    ///
    /// Le titre arrive presque toujours **après** le début : on nomme une
    /// réunion pendant qu'elle tourne, ou le CRM le fournit à l'arrivée. Le
    /// dossier naît donc sous son seul horodatage et se renomme une fois, ici.
    ///
    /// **Un renommage refusé laisse tout en place et se dit.** Le nom d'un
    /// dossier est du confort ; son contenu est une heure de réunion. On ne perd
    /// jamais un fichier pour un nom, et la fonction rend alors le dossier tel
    /// qu'il est resté — pas `nil` —, parce que l'appelant s'en sert pour
    /// continuer à écrire dedans.
    ///
    /// Les morceaux bruts gardent leur nom : ils sont bâtis sur l'horodatage
    /// seul, exprès, pour ne dépendre d'aucun renommage ultérieur.
    @discardableResult
    func alignFolderName(for id: UUID) async -> URL? {
        // Sans effet sur un enregistrement à plat : il n'a pas de dossier à
        // renommer, et lui en fabriquer un ici serait un déplacement de fichiers
        // que personne n'a demandé.
        guard var folder = folder(for: id) else { return nil }

        // Une fiche illisible n'autorise aucun renommage : on ne connaît ni le
        // titre ni la date de début, donc le nom qu'on écrirait serait une
        // invention. `loadForEditing` a déjà dit ce qui cloche.
        guard let metadata = loadForEditing(id) else { return folder }

        let manager = FileManager.default
        let desired = MeetingFolder.name(startedAt: metadata.startedAt, title: metadata.title)

        // **Un dossier que l'utilisateur a renommé à la main n'est pas
        // renommé.** Tous les noms que bran écrit commencent par l'horodatage de
        // la réunion ; un dossier dont le nom ne commence plus par là a été
        // reclassé à la main, et le CRM qui fournit un titre une heure plus tard
        // n'a pas à effacer ce classement. C'est le pendant de la lecture par
        // extension : renommer un dossier de réunion doit rester sans
        // conséquence, dans les deux sens.
        let isOurs = folder.lastPathComponent.hasPrefix(MeetingFolder.stamp(metadata.startedAt))

        if isOurs, folder.lastPathComponent != desired {
            switch reserveFolder(base: desired, for: id, create: false) {
            case .refused(let reason):
                onProblem?(reason + " Le dossier garde son nom actuel ; son contenu est intact.")

            case .reserved(let target):
                do {
                    try manager.moveItem(at: folder, to: target)
                    folder = target
                } catch {
                    onProblem?(
                        "Dossier non renommé (« \(folder.lastPathComponent) » → "
                        + "« \(target.lastPathComponent) ») : \(error.localizedDescription). "
                        + "Les fichiers de la réunion sont intacts, sous l'ancien nom."
                    )
                }
            }
        }

        // Les médias suivent le dossier — celui d'après le renommage, ou celui
        // d'avant s'il a échoué. On les relit sur le disque plutôt que de
        // déduire leur ancien nom : l'utilisateur a pu renommer le dossier à la
        // main entre-temps, et c'est justement ce que la lecture par extension
        // permet de rattraper sans rien casser.
        if let bundle = MeetingBundle.read(folder: folder) {
            rename(bundle.video, to: MeetingBundle.videoDestination(in: folder))
            rename(bundle.audio, to: MeetingBundle.audioDestination(in: folder))
        }

        sessionFolders[id] = folder
        await reload()
        return folder
    }

    /// Renomme un média dans son dossier. Sans effet s'il est déjà au bon nom.
    private func rename(_ source: URL?, to destination: URL) {
        guard let source, source != destination else { return }

        let manager = FileManager.default
        guard manager.fileExists(atPath: destination.path(percentEncoded: false)) == false else {
            onProblem?(
                "Fichier non renommé (« \(source.lastPathComponent) ») : "
                + "« \(destination.lastPathComponent) » existe déjà dans le même dossier. "
                + "Aucun des deux n'a été touché."
            )
            return
        }

        do {
            try manager.moveItem(at: source, to: destination)
        } catch {
            onProblem?(
                "Fichier non renommé (« \(source.lastPathComponent) ») : \(error.localizedDescription). "
                + "Il est toujours dans le dossier de la réunion, sous son ancien nom."
            )
        }
    }

    func completeSession(id: UUID, endedAt: Date = .now) async {
        guard var metadata = loadForEditing(id) else { return }
        metadata.endedAt = endedAt
        write(metadata)
        await reload()
    }

    /// Relit une fiche avant de la modifier, en disant ce qui empêche de le
    /// faire.
    ///
    /// Deux règles, et la seconde est celle qui compte : une fiche corrompue
    /// **n'est jamais réécrite**. Ses octets contiennent peut-être encore le
    /// titre et le rattachement CRM de la réunion, et un `.json` réparable à la
    /// main vaut infiniment mieux qu'un `.json` propre et vide.
    private func loadForEditing(_ id: UUID) -> RecordingMetadata? {
        let sidecar = sidecarURL(for: id)

        switch Self.readSidecar(at: sidecar) {
        case .success(let metadata):
            return metadata
        case .failure(let fault):
            onProblem?(fault.editingNote(for: Self.displayName(of: sidecar)))
            return nil
        }
    }

    /// Renommage. Fonctionne pendant l'enregistrement : seule la fiche change,
    /// le dossier et la vidéo sont alignés à la fin, par `alignFolderName`.
    /// Modification arbitraire du sidecar, relue depuis le disque à chaque fois.
    ///
    /// Relire plutôt que muter la copie en mémoire évite d'écraser un champ
    /// qu'un autre chemin vient d'écrire — le suivi CRM et la saisie de notes
    /// touchent le même fichier sans se coordonner.
    func mutate(_ id: UUID, _ change: (inout RecordingMetadata) -> Void) async {
        guard var metadata = loadForEditing(id) else { return }
        change(&metadata)
        publish(metadata, for: id)
    }

    func completeProcessing(id: UUID, originalBytes: Int64, segmentCount: Int) async {
        guard var metadata = loadForEditing(id) else { return }
        metadata.originalBytes = originalBytes
        metadata.segmentCount = segmentCount
        metadata.processedAt = .now
        write(metadata)
        await reload()
    }

    func updateTitle(_ title: String, for id: UUID) {
        guard var metadata = loadForEditing(id) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        metadata.title = trimmed.isEmpty ? nil : trimmed
        publish(metadata, for: id)
    }

    func updateNotes(_ notes: String, for id: UUID) {
        guard var metadata = loadForEditing(id) else { return }
        metadata.notes = notes
        publish(metadata, for: id)
    }

    /// Écrit, **puis** met la copie en mémoire à jour — dans cet ordre, et
    /// seulement si l'écriture a réussi.
    ///
    /// L'ordre inverse afficherait un titre que le disque n'a pas : la
    /// bibliothèque montrerait la saisie comme prise en compte, jusqu'au
    /// prochain balayage qui la ferait disparaître sans explication.
    private func publish(_ metadata: RecordingMetadata, for id: UUID) {
        guard write(metadata) else { return }

        if let index = recordings.firstIndex(where: { $0.id == id }) {
            recordings[index].metadata = metadata
        }
    }

    // MARK: - Rangement

    /// Combien d'enregistrements sont encore rangés à plat.
    ///
    /// Dérivé de `recordings`, jamais stocké à côté : un compteur tenu en
    /// parallèle du balayage est un compteur qui finit par mentir, et il
    /// mentirait ici sur la seule question qui décide d'un déplacement de
    /// plusieurs gigaoctets.
    var legacyCount: Int {
        recordings.reduce(0) { $0 + ($1.isFlat ? 1 : 0) }
    }

    /// Range les anciens enregistrements, un dossier chacun.
    ///
    /// **Geste explicite de l'utilisateur, jamais automatique.** Déplacer
    /// plusieurs gigaoctets de réunions à l'insu de quelqu'un — pendant un
    /// lancement, pendant une sauvegarde Time Machine, pendant qu'un `.mp4` est
    /// ouvert dans QuickTime — est exactement ce qu'on ne fait pas.
    ///
    /// **L'ordre des opérations est la seule chose qui compte ici**, et il est
    /// contre-intuitif : la fiche d'abord, les médias ensuite, l'ancienne fiche
    /// en dernier. L'ordre naturel — déplacer la vidéo, puis écrire la fiche —
    /// ouvre une fenêtre pendant laquelle la vidéo est dans un dossier qui n'a
    /// pas encore de `Fiche.json`, donc qui n'est pas un dossier de réunion,
    /// donc invisible pour le balayage : la réunion disparaît de la bibliothèque
    /// alors qu'elle est intacte sur le disque. C'est le pire résultat possible,
    /// parce qu'il ressemble à une perte de données.
    ///
    /// Dans l'ordre retenu, chaque état intermédiaire reste lisible :
    ///
    /// 1. fiche écrite, médias encore à plat → `merged` garde l'entrée à plat,
    ///    qui a la vidéo ; la réunion s'affiche, complète ;
    /// 2. médias déplacés → l'entrée en dossier a la vidéo et l'emporte ;
    /// 3. ancienne fiche effacée → il ne reste qu'une disposition.
    ///
    /// Un échec à n'importe quelle étape laisse donc l'enregistrement lisible
    /// dans l'une **ou** l'autre disposition, jamais dans aucune des deux, et
    /// le passage suivant reprend là où celui-ci s'est arrêté. Le prix de ce
    /// compromis est un moment où la réunion existe des deux côtés — c'est ce
    /// que `merged` absorbe.
    ///
    /// Rien n'est jamais copié ni supprimé : `moveItem` renomme, ce qui est
    /// instantané et sans risque de disque plein, et l'ancienne fiche n'est
    /// effacée qu'après que la nouvelle a été écrite **et relue**.
    func tidyLegacyRecordings() async -> String? {
        let legacy = recordings.filter(\.isFlat)
        guard legacy.isEmpty == false else { return nil }

        let manager = FileManager.default
        var tidied = 0
        var refused = 0

        for recording in legacy {
            // Les métadonnées sont relues sur le disque, pas reprises du
            // balayage : entre les deux, le titre a pu changer, et c'est ce
            // titre qui va nommer le dossier.
            var metadata = recording.metadata
            var hadSidecar = false
            let flatSidecar = root.appending(path: "\(recording.id.uuidString).json")

            switch Self.readSidecar(at: flatSidecar) {
            case .success(let decoded):
                metadata = decoded
                hadSidecar = true
            case .failure(let fault):
                // Une fiche corrompue n'est jamais réécrite ailleurs : ses
                // octets contiennent peut-être encore le titre et le lien CRM,
                // et les recopier sous une forme « propre et vide » les perdrait
                // définitivement. La réunion reste à plat, lisible, réparable.
                guard fault.isNormal else {
                    onProblem?(
                        fault.listingNote(for: flatSidecar.lastPathComponent)
                            ?? "Fiche illisible (\(flatSidecar.lastPathComponent))."
                    )
                    refused += 1
                    continue
                }
            }

            // Un fichier déposé à la main n'a pas de fiche, mais il a un nom, et
            // ce nom est la seule chose que son propriétaire lui a donnée. Le
            // remplacer par un horodatage nu, c'est effacer la seule information
            // qui restait. On le promeut donc en titre — le dossier et les
            // fichiers le porteront.
            if metadata.title == nil, hadSidecar == false, recording.existsOnDisk {
                let base = recording.url.deletingPathExtension().lastPathComponent
                if UUID(uuidString: base) == nil { metadata.title = base }
            }

            let base = MeetingFolder.name(startedAt: metadata.startedAt, title: metadata.title)
            let folder: URL

            switch reserveFolder(base: base, for: metadata.id, create: true) {
            case .reserved(let reserved):
                folder = reserved
            case .refused(let reason):
                onProblem?(reason + " Cette réunion reste où elle est.")
                refused += 1
                continue
            }

            // Étape 1 — la fiche, qui fait du dossier un dossier de réunion.
            let sidecar = folder.appending(path: MeetingFolder.sidecarName)
            guard write(metadata, to: sidecar) else {
                // `write` a déjà dit pourquoi. Rien n'a bougé : la réunion est
                // toujours entière dans la racine.
                refused += 1
                continue
            }

            // …et sa relecture. Une fiche écrite qui ne se relit pas ferait un
            // dossier de réunion sans identité : le balayage lui donnerait un
            // identifiant dérivé du chemin, différent de celui de l'entrée à
            // plat, et la même réunion apparaîtrait deux fois — l'une avec sa
            // vidéo, l'autre sans. On défait donc ce qu'on vient d'écrire.
            guard case .success = Self.readSidecar(at: sidecar) else {
                try? manager.removeItem(at: sidecar)
                onProblem?(
                    "Réunion non rangée (\(base)) : la fiche écrite dans le nouveau dossier ne se relit pas. "
                    + "Rien n'a été déplacé."
                )
                refused += 1
                continue
            }

            // Étape 2 — les médias. On repart de l'état réel du disque : la
            // liste du balayage peut avoir une heure, et déplacer d'après une
            // liste périmée, c'est manquer un fichier arrivé depuis.
            let source = MeetingBundle.flat(root: root, identifier: metadata.id)
            let video = source.video ?? (recording.existsOnDisk ? recording.url : nil)

            var videoMoved = true
            if let video {
                videoMoved = move(video, to: MeetingBundle.videoDestination(in: folder))
            }

            var strandedSegments = 0
            for (offset, segment) in source.segments.enumerated() {
                // Le numéro d'origine est **conservé**, pas renuméroté. Si un
                // passage précédent a déplacé `seg000` et buté sur `seg001`, une
                // renumérotation ferait viser `seg000` au rescapé — un nom déjà
                // pris — et le rangement resterait bloqué sur cette réunion pour
                // toujours. Le numéro porte aussi l'ordre de la fusion : le
                // décaler recollerait la réunion dans le désordre.
                let destination = MeetingBundle.segmentDestination(
                    in: folder,
                    startedAt: metadata.startedAt,
                    index: Self.segmentIndex(of: segment) ?? offset
                )
                if move(segment, to: destination) == false { strandedSegments += 1 }
            }

            // Étape 3 — l'ancienne fiche, et seulement si ce qui rend la réunion
            // lisible a bien changé de place. Sans vidéo, ce sont les morceaux
            // bruts qui SONT la réunion : les laisser derrière tout en effaçant
            // la fiche à plat les rendrait invisibles des deux côtés.
            let carriesPlayable = videoMoved && (video != nil || strandedSegments == 0)

            if carriesPlayable, hadSidecar {
                do {
                    // `removeItem` et non la corbeille : ces octets viennent
                    // d'être réécrits à l'identique dans le dossier, et relus.
                    // C'est un doublon qu'on retire, pas une donnée qu'on
                    // supprime — et quarante fiches dans la corbeille ne
                    // rassureraient personne.
                    try manager.removeItem(at: flatSidecar)
                } catch {
                    onProblem?(
                        "Ancienne fiche non effacée (\(flatSidecar.lastPathComponent)) : "
                        + "\(error.localizedDescription). La réunion est bien rangée dans son dossier ; "
                        + "ce fichier peut être jeté à la main."
                    )
                }
            }

            if strandedSegments > 0 {
                onProblem?(
                    "\(strandedSegments) morceau(x) brut(s) de « \(base) » sont restés dans le dossier "
                    + "principal : ils n'ont pas pu être déplacés. La réunion, elle, est dans son dossier."
                )
            }

            if carriesPlayable { tidied += 1 } else { refused += 1 }
        }

        await reload()

        return report(tidied: tidied, refused: refused)
    }

    /// Déplace un fichier, en traitant « déjà à destination » comme un succès.
    ///
    /// C'est ce qui rend le rangement reprenable : après une interruption, une
    /// partie des fichiers est déjà arrivée, et échouer dessus bloquerait pour
    /// toujours une réunion à moitié rangée. La source absente **et** la
    /// destination présente ne peuvent vouloir dire qu'une chose — le passage
    /// précédent l'a fait.
    private func move(_ source: URL, to destination: URL) -> Bool {
        let manager = FileManager.default

        if manager.fileExists(atPath: destination.path(percentEncoded: false)) {
            guard manager.fileExists(atPath: source.path(percentEncoded: false)) else { return true }

            // Les deux existent : on ne choisit pas à la place de l'utilisateur
            // lequel des deux fichiers est le bon. Écraser reviendrait à
            // supprimer une vidéo sans le dire.
            onProblem?(
                "Fichier non déplacé (« \(source.lastPathComponent) ») : "
                + "« \(destination.lastPathComponent) » existe déjà. Aucun des deux n'a été touché."
            )
            return false
        }

        do {
            try manager.moveItem(at: source, to: destination)
            return true
        } catch {
            onProblem?(
                "Fichier non déplacé (« \(source.lastPathComponent) ») : \(error.localizedDescription)."
            )
            return false
        }
    }

    /// Le compte rendu du rangement, écrit pour être lu tel quel.
    ///
    /// Les motifs des échecs sont déjà partis par `onProblem`, un par un : les
    /// répéter ici ferait un pavé qu'on ne lit pas, alors que le compte rendu
    /// répond à la seule question qu'on se pose après avoir cliqué — est-ce que
    /// mes réunions sont toujours là ?
    private func report(tidied: Int, refused: Int) -> String? {
        let left = refused == 1
            ? "1 est restée en place ; elle est toujours lisible là où elle était, et rien n'a été perdu."
            : "\(refused) sont restées en place ; elles sont toujours lisibles là où elles étaient, "
            + "et rien n'a été perdu."

        switch (tidied, refused) {
        case (0, 0):
            return nil
        case (0, _):
            return "Aucune réunion rangée : \(left)"
        case (1, 0):
            return "1 réunion rangée dans son dossier."
        case (_, 0):
            return "\(tidied) réunions rangées, un dossier chacune."
        case (1, _):
            return "1 réunion rangée dans son dossier. \(left)"
        default:
            return "\(tidied) réunions rangées, un dossier chacune. \(left)"
        }
    }

    // MARK: - Suppression

    /// Corbeille, jamais suppression.
    ///
    /// Une heure de réunion effacée depuis un bouton de 24 points ne se
    /// récupère pas. `trashItem` rend l'annulation possible sans écrire une
    /// seule ligne de plus — c'est le Finder qui la porte.
    ///
    /// Et **une suppression refusée n'est pas une suppression** : elle se dit.
    /// Sans ça, le bouton « Supprimer » sur un fichier verrouillé ne faisait
    /// rien du tout, l'enregistrement réapparaissait au balayage suivant, et
    /// l'utilisateur pouvait tout aussi bien conclure que bran avait perdu la
    /// trace de sa réunion.
    ///
    /// Pour un enregistrement en dossier, c'est **le dossier entier** qui part,
    /// en une seule opération : la vidéo, l'audio du CRM, la fiche et les
    /// morceaux bruts reviennent ensemble d'un `⌘Z` dans le Finder. Quatre
    /// `trashItem` séparés se seraient annulés un par un, dans le désordre, et
    /// auraient pu échouer à mi-chemin en laissant un dossier à moitié vide.
    func delete(_ recording: Recording) async {
        let manager = FileManager.default

        if recording.isFlat == false {
            let folder = recording.folderURL

            // Garde-fou : jamais la racine. Un enregistrement en dossier ne
            // devrait jamais pointer dessus, mais la conséquence d'un bug qui le
            // ferait — toute la bibliothèque à la corbeille — justifie les deux
            // lignes.
            guard folder.standardizedFileURL != root.standardizedFileURL else {
                onProblem?(
                    "Réunion non supprimée : son dossier est le dossier principal des enregistrements."
                )
                return
            }

            do {
                try manager.trashItem(at: folder, resultingItemURL: nil)
                sessionFolders[recording.id] = nil
            } catch {
                onProblem?(
                    "Réunion non supprimée (\(folder.lastPathComponent)) : \(error.localizedDescription)"
                )
            }

            await reload()
            return
        }

        // Le fichier final n'existe pas toujours : après une session mal
        // terminée, la réunion n'est présente que sous ses morceaux bruts. Le
        // mettre à la corbeille sans condition rapportait alors une erreur pour
        // un fichier qui n'a jamais existé.
        var mediaLeftBehind = false

        if recording.existsOnDisk {
            do {
                try manager.trashItem(at: recording.url, resultingItemURL: nil)
            } catch {
                mediaLeftBehind = true
                onProblem?(
                    "Enregistrement non supprimé (\(recording.url.lastPathComponent)) : \(error.localizedDescription)"
                )
            }
        }

        // **Les morceaux bruts partent avec.** Ils étaient oubliés, et c'est un
        // défaut qui perdait des fichiers sans le dire : une session interrompue
        // à plat n'a souvent AUCUN fichier final — la bibliothèque l'affiche
        // grâce à ses morceaux —, et la supprimer mettait sa fiche à la
        // corbeille en laissant les `<uuid>-segNNN.mp4` dans la racine. Le
        // balayage suivant, qui n'énumère les morceaux que par leur fiche, ne
        // les voyait plus : plusieurs gigaoctets devenus invisibles à la fois
        // dans bran et dans le Finder, où ils n'étaient plus qu'une ligne d'UUID
        // sans rien pour l'expliquer.
        for segment in recording.segmentURLs {
            guard manager.fileExists(atPath: segment.path(percentEncoded: false)) else { continue }
            do {
                try manager.trashItem(at: segment, resultingItemURL: nil)
            } catch {
                mediaLeftBehind = true
                onProblem?(
                    "Morceau non supprimé (\(segment.lastPathComponent)) : \(error.localizedDescription)"
                )
            }
        }

        // **La fiche part en dernier, et seulement si tout le reste est parti.**
        //
        // À plat, c'est elle qui rattache les morceaux à une réunion : le
        // balayage n'énumère les `<uuid>-segNNN.mp4` que parce qu'un
        // `<uuid>.json` lui a donné l'identifiant à chercher. La supprimer alors
        // qu'un fichier verrouillé a résisté ferait disparaître de la
        // bibliothèque des gigaoctets qui sont toujours sur le disque, sous des
        // noms d'UUID que plus rien n'explique — la forme la plus désagréable
        // d'une suppression ratée, puisqu'elle ressemble à une suppression
        // réussie.
        //
        // Garder la fiche laisse au contraire la réunion visible, avec ses
        // morceaux, et un second clic sur « Supprimer » reprendra le travail une
        // fois le verrou levé.
        let sidecar = root.appending(path: recording.metadata.sidecarName)
        if mediaLeftBehind {
            onProblem?(
                "Fiche conservée (\(recording.metadata.sidecarName)) : des fichiers de cette réunion "
                + "n'ont pas pu être supprimés, et sans elle ils deviendraient introuvables."
            )
        } else if manager.fileExists(atPath: sidecar.path(percentEncoded: false)) {
            do {
                try manager.trashItem(at: sidecar, resultingItemURL: nil)
            } catch {
                onProblem?(
                    "Fiche non supprimée (\(recording.metadata.sidecarName)) : \(error.localizedDescription)"
                )
            }
        }

        await reload()
    }

    /// Écrit la fiche, ou dit pourquoi elle n'a pas été écrite.
    ///
    /// **Trois `try?` d'affilée : le titre, les notes, l'heure de fin et le lien
    /// CRM pouvaient partir sans un mot.** Disque plein, dossier déplacé pendant
    /// la réunion, volume externe démonté — l'écriture échouait, la fonction
    /// rendait la main comme si de rien n'était, et l'interface continuait
    /// d'afficher ce que le disque ne contenait pas.
    ///
    /// La destination est explicite pour `beginSession` et le rangement, qui
    /// écrivent dans un dossier que `folder(for:)` ne connaît pas encore — ou
    /// pas comme ils l'entendent. Partout ailleurs elle se déduit : dans le
    /// dossier du rendez-vous s'il y en a un, à plat sinon.
    ///
    /// Le résultat est consommé (`@discardableResult` pour les appels où l'échec
    /// est déjà rapporté par le canal d'échec).
    @discardableResult
    private func write(_ metadata: RecordingMetadata, to sidecar: URL? = nil) -> Bool {
        let target = sidecar ?? sidecarURL(for: metadata.id)

        do {
            // Le dossier parent, pas la racine : pour une fiche de rendez-vous,
            // c'est le dossier de la réunion qu'il faut avoir sous la main, et
            // il peut ne pas encore exister au tout premier appel.
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder.bran.encode(metadata)
            try data.write(to: target, options: .atomic)
            return true
        } catch {
            onProblem?(
                "Fiche non enregistrée (\(Self.displayName(of: target))) : \(error.localizedDescription). "
                + "Le titre, les notes, l'heure de fin et le lien CRM de cette réunion ne sont pas sur le disque."
            )
            return false
        }
    }
}

extension JSONEncoder {
    /// Dates ISO-8601 : lisibles à l'œil dans le `.json`, et non ambiguës.
    static let bran: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
}

extension JSONDecoder {
    static let bran: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
