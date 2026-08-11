import Foundation
import Testing
@testable import BranCore

/// **Une vignette qui s'écrase, un fichier supprimé à tort.**
///
/// Les trois décisions du plan sont pures — nommer, éligibiliser, évincer — et
/// c'est ce qui rend ces tests suffisants : il n'y a aucune logique dans
/// `ThumbnailCache`, seulement ImageIO qui obéit et un `removeItem` qui obéit à
/// une liste de noms. Ce fichier est donc l'endroit où l'on vérifie que deux
/// tailles ne se marchent pas dessus, qu'une entrée purgée ne montre rien, et
/// que l'éviction mord au bon moment sur les bons fichiers.
@Suite("Le plan des vignettes")
struct ThumbnailPlanTests {

    // MARK: - Fixtures

    /// 64 caractères hexadécimaux minuscules, comme ce que `ClipboardBlobPayload`
    /// calcule. La valeur n'a pas d'importance, sa **forme** en a une : c'est
    /// elle que `isSelfWritten` vérifie.
    private let hash = String(repeating: "a", count: 64)
    private let otherHash = String(repeating: "b", count: 64)

    private let clipboardFolder = URL(filePath: "/tmp/bran-tests/Clipboard", directoryHint: .isDirectory)

    private func blob(_ hash: String, ext: String = "png", bytes: Int = 1_024) -> ClipboardBlobRef {
        ClipboardBlobRef(hash: hash, ext: ext, bytes: bytes)
    }

    private func entry(
        kind: ClipboardKind = .image,
        blobs: [ClipboardBlobRef]?,
        refusedBytes: Int? = nil,
        purgedAt: Date? = nil
    ) -> ClipboardEntry {
        ClipboardEntry(
            copiedAt: Date(timeIntervalSince1970: 1_754_800_000),
            kind: kind,
            preview: "",
            blobs: blobs,
            refusedBytes: refusedBytes,
            blobsPurgedAt: purgedAt
        )
    }

    // MARK: - Le nom dérive de l'empreinte et de la taille

    @Test("Le nom d'une vignette est l'empreinte, la taille en pixels, et le format")
    func nommage() {
        let name = ThumbnailPlan.fileName(for: blob(hash), size: .row)
        #expect(name == "\(hash)-80.png")

        // La taille du nom est bien celle passée à ImageIO, pas la taille en
        // points : deux écritures différentes du même nombre finiraient par
        // diverger, et le fichier serait cherché sous un nom qui n'existe pas.
        #expect(name.contains("-\(ThumbnailSize.row.maxPixelSize)."))
    }

    @Test("Deux tailles demandées ne s'écrasent pas")
    func deuxTailles() {
        // Sans la taille dans le nom, ouvrir le détail d'une entrée écraserait la
        // vignette de sa ligne, et revenir à la liste coûterait un décodage.
        let row = ThumbnailPlan.fileName(for: blob(hash), size: .row)
        let detail = ThumbnailPlan.fileName(for: blob(hash), size: .detail)
        #expect(row != detail)
        #expect(ThumbnailSize.row.maxPixelSize != ThumbnailSize.detail.maxPixelSize)
    }

    @Test("Deux entrées qui citent la même image partagent leur vignette")
    func empreintePartagee() throws {
        // C'est le cadeau de l'adressage par contenu : aucune table de
        // correspondance, aucun compteur de références, et la deuxième entrée ne
        // paie aucun décodage. Mesuré : 43 entrées sur 250 sont des recopies.
        let first = entry(blobs: [blob(hash)])
        let second = entry(blobs: [blob(hash)])

        let a = try #require(ThumbnailPlan.source(for: first))
        let b = try #require(ThumbnailPlan.source(for: second))
        #expect(
            ThumbnailPlan.fileName(for: a, size: .row)
                == ThumbnailPlan.fileName(for: b, size: .row)
        )
    }

    @Test("Le nom du blob source ne change pas celui de la vignette")
    func extensionSourceIgnoree() {
        // Ce qui est mis en cache, ce sont des pixels. Deux fichiers de même
        // contenu ont les mêmes pixels, quel que soit le nom qu'on leur a donné.
        #expect(
            ThumbnailPlan.fileName(for: blob(hash, ext: "png"), size: .row)
                == ThumbnailPlan.fileName(for: blob(hash, ext: "tiff"), size: .row)
        )
        #expect(
            ThumbnailPlan.fileName(for: blob(hash), size: .row)
                != ThumbnailPlan.fileName(for: blob(otherHash), size: .row)
        )
    }

    // MARK: - Où le cache vit

    @Test("Le cache vit hors des dossiers-jours, et n'est jamais pris pour un jour")
    func dossierDuCache() {
        let folder = ThumbnailPlan.folder(in: clipboardFolder)
        #expect(folder.lastPathComponent == ThumbnailPlan.folderName)
        #expect(folder.deletingLastPathComponent().lastPathComponent == "Clipboard")

        // La garde qui empêche la rétention de le balayer comme un jour périmé,
        // et le ramassage d'orphelins de le visiter. Le nom du dossier de cache
        // ne doit jamais s'analyser en AAAA-MM-JJ.
        #expect(ClipboardRetention.day(from: ThumbnailPlan.folderName) == nil)

        let url = ThumbnailPlan.url(for: blob(hash), size: .detail, in: clipboardFolder)
        #expect(url.deletingLastPathComponent().lastPathComponent == ThumbnailPlan.folderName)
        #expect(url.lastPathComponent == "\(hash)-256.png")
    }

    // MARK: - Ce qui n'a pas de vignette du tout

    @Test("Une sorte autre qu'image n'a jamais de vignette")
    func sorteSansVignette() {
        // Le blob d'un `richText` est du RTF ou du HTML : le donner à ImageIO
        // rendrait `nil` après un accès disque, alors que la question se répond
        // sans toucher au disque.
        for kind in [ClipboardKind.text, .richText, .file] {
            #expect(ThumbnailPlan.source(for: entry(kind: kind, blobs: [blob(hash)])) == nil)
            #expect(ThumbnailPlan.hasThumbnail(entry(kind: kind, blobs: [blob(hash)])) == false)
        }
    }

    @Test("Une entrée purgée n'a pas de vignette")
    func entreePurgee() {
        // Elle sait déjà dire pourquoi — « Image de 1,2 Mo, purgée le 10 août ».
        // Une vignette survivante prétendrait le contraire au même endroit de
        // l'écran.
        let purged = entry(blobs: [blob(hash)], purgedAt: Date(timeIntervalSince1970: 1_754_900_000))
        #expect(purged.blobsArePurged)
        #expect(ThumbnailPlan.source(for: purged) == nil)
    }

    @Test("Une entrée refusée n'a pas de vignette, même si elle cite un blob")
    func entreeRefusee() {
        // Le magasin met déjà `blobs` à `nil` en cas de refus. Le test est
        // explicite quand même : dépendre d'un invariant écrit dans un autre
        // fichier pour décider d'ouvrir un fichier est un pari qu'on perd au
        // premier correctif.
        let refused = entry(blobs: [blob(hash)], refusedBytes: 40 * 1024 * 1024)
        #expect(refused.isRefused)
        #expect(ThumbnailPlan.source(for: refused) == nil)
    }

    @Test("Une entrée image sans blob n'a pas de vignette")
    func entreeSansBlob() {
        #expect(ThumbnailPlan.source(for: entry(blobs: nil)) == nil)
        #expect(ThumbnailPlan.source(for: entry(blobs: [])) == nil)
    }

    @Test("Une entrée image intacte a une vignette, et c'est son premier blob")
    func entreeAvecVignette() throws {
        let subject = entry(blobs: [blob(hash), blob(otherHash)])
        let source = try #require(ThumbnailPlan.source(for: subject))
        #expect(source.hash == hash)
        #expect(ThumbnailPlan.hasThumbnail(subject))
    }

    // MARK: - Ce que le cache aurait pu écrire

    @Test("Un nom que ce cache fabrique se reconnaît")
    func nomReconnu() {
        for size in ThumbnailSize.allCases {
            #expect(ThumbnailPlan.isSelfWritten(ThumbnailPlan.fileName(for: blob(hash), size: size)))
        }
    }

    @Test("Ce que ce cache n'aurait pas pu écrire n'est jamais supprimé")
    func nomEtranger() {
        let names = [
            "\(hash).png",                       // un nom de blob, pas de vignette
            "\(hash)-80.jpg",                    // un autre format
            "\(hash)-.png",                      // pas de taille
            "\(hash)-80-160.png",                // deux tirets
            "\(hash.uppercased())-80.png",       // majuscules : nous écrivons en minuscules
            "abcd-80.png",                       // empreinte trop courte
            "\(String(repeating: "z", count: 64))-80.png", // pas de l'hexadécimal
            "capture d'écran.png",
            "../\(hash)-80.png",                 // et surtout : rien qui puisse sortir du dossier
            ".DS_Store",
            "",
        ]
        for name in names {
            #expect(ThumbnailPlan.isSelfWritten(name) == false, "\(name) ne devrait pas être des nôtres")
        }
    }

    // MARK: - L'éviction

    /// Trois vignettes de dix octets, de la plus récente à la plus ancienne.
    private var three: [CachedThumbnail] {
        let now = Date(timeIntervalSince1970: 1_754_800_000)
        return [
            CachedThumbnail(name: "\(hash)-80.png", bytes: 10, lastUsed: now),
            CachedThumbnail(name: "\(otherHash)-80.png", bytes: 10, lastUsed: now - 3_600),
            CachedThumbnail(
                name: "\(String(repeating: "c", count: 64))-80.png",
                bytes: 10,
                lastUsed: now - 7_200
            ),
        ]
    }

    @Test("L'éviction ne mord pas tant que le dossier tient sous le plafond")
    func evictionQuiNeMordPas() {
        // 30 octets pour un plafond de 30 : un plafond qu'on n'a pas le droit
        // d'atteindre est un plafond dont le chiffre annoncé est faux — même
        // parti pris que `ClipboardEntry.isTooLarge(bytes:)`.
        #expect(ThumbnailPlan.budget(bytes: 30).filesToEvict(from: three).isEmpty)
        #expect(ThumbnailPlan.default.filesToEvict(from: three).isEmpty)
    }

    @Test("L'éviction mord sur les moins récemment utilisées")
    func evictionQuiMord() {
        // 25 octets de plafond pour 30 sur le disque : la plus ancienne s'en va,
        // et elle seule. Ce qu'on garde est ce que le panneau montre.
        let doomed = ThumbnailPlan.budget(bytes: 25).filesToEvict(from: three)
        #expect(doomed == ["\(String(repeating: "c", count: 64))-80.png"])

        // Plus serré : il ne reste que la plus récemment utilisée.
        let tighter = ThumbnailPlan.budget(bytes: 10).filesToEvict(from: three)
        #expect(tighter.count == 2)
        #expect(tighter.contains("\(hash)-80.png") == false)
    }

    @Test("Un plafond à zéro vide le dossier")
    func plafondNul() {
        #expect(ThumbnailPlan.budget(bytes: 0).filesToEvict(from: three).count == 3)
    }

    @Test("Un fichier étranger n'est ni compté dans le budget ni supprimé")
    func etrangerEpargne() {
        // Un film déposé dans le dossier ne doit pas faire évincer nos vignettes,
        // et surtout ne doit pas partir avec elles. Même verdict que
        // `ClipboardStore.collectOrphanedBlobs()` : ce qu'on ne sait pas classer
        // reste, pour toujours.
        let intruder = CachedThumbnail(
            name: "vacances.mov",
            bytes: 4_000_000_000,
            lastUsed: Date(timeIntervalSince1970: 0)
        )
        let doomed = ThumbnailPlan.budget(bytes: 30).filesToEvict(from: three + [intruder])
        #expect(doomed.isEmpty)
    }

    @Test("Une vignette anormalement lourde n'emporte pas celles d'après")
    func lourdeIsolee() {
        let now = Date(timeIntervalSince1970: 1_754_800_000)
        let heavy = CachedThumbnail(name: "\(hash)-256.png", bytes: 1_000, lastUsed: now)
        let light = CachedThumbnail(name: "\(otherHash)-80.png", bytes: 10, lastUsed: now - 3_600)

        // S'arrêter au premier dépassement condamnerait `light`, qui tient
        // pourtant très bien sous le plafond.
        let doomed = ThumbnailPlan.budget(bytes: 20).filesToEvict(from: [heavy, light])
        #expect(doomed == [heavy.name])
    }

    @Test("À égalité de date, le sort d'une vignette ne change pas d'un balayage à l'autre")
    func evictionDeterministe() {
        let now = Date(timeIntervalSince1970: 1_754_800_000)
        let files = [
            CachedThumbnail(name: "\(otherHash)-80.png", bytes: 10, lastUsed: now),
            CachedThumbnail(name: "\(hash)-80.png", bytes: 10, lastUsed: now),
        ]
        let plan = ThumbnailPlan.budget(bytes: 10)
        // Le nom départage, donc les deux ordres d'entrée rendent le même verdict.
        #expect(plan.filesToEvict(from: files) == plan.filesToEvict(from: files.reversed()))
        #expect(plan.filesToEvict(from: files) == ["\(otherHash)-80.png"])
    }

    @Test("Une liste vide ne fait rien supprimer")
    func listeVide() {
        #expect(ThumbnailPlan.budget(bytes: 0).filesToEvict(from: []).isEmpty)
    }
}
