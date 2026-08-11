import Foundation
import Testing
@testable import BranCore

/// **Une purge qui se trompe supprime ce qu'on ne peut pas recréer.**
///
/// La politique décide sans ouvrir un seul fichier : elle lit des noms de
/// dossiers et rend des noms de dossiers. C'est ce qui la rend testable en une
/// milliseconde, et c'est aussi ce qui rend ces tests suffisants — il n'y a
/// aucune logique ailleurs qu'ici, seulement un `rm` qui obéit.
@Suite("La rétention du presse-papiers")
struct ClipboardRetentionTests {

    private let today = "2026-08-10"

    // MARK: - Décider par le nom du dossier

    @Test("Un dossier atteignant exactement la limite est purgé")
    func dossierALaLimite() {
        // `>=` comme `SnapshotRetention` et `RetentionPolicy`. Le contraire
        // ferait traîner 158 Mo de PNG une journée de plus pour une raison
        // inexplicable à qui a réglé « 30 jours ».
        let policy = ClipboardRetention.days(30)
        #expect(policy.dayFoldersToPurge(from: ["2026-07-11"], today: today) == ["2026-07-11"])
    }

    @Test("Un dossier d'un jour plus jeune survit")
    func dossierUnJourPlusJeune() {
        let policy = ClipboardRetention.days(30)
        #expect(policy.dayFoldersToPurge(from: ["2026-07-12"], today: today).isEmpty)
    }

    @Test("Un dossier d'un jour plus vieux part aussi")
    func dossierUnJourPlusVieux() {
        let policy = ClipboardRetention.days(30)
        #expect(policy.dayFoldersToPurge(from: ["2026-07-10"], today: today) == ["2026-07-10"])
    }

    @Test("Le dossier du jour n'est jamais touché, même à zéro jour")
    func jourVivantIntouchable() {
        // Ce n'est pas une décision de politique mais de mécanique : c'est le
        // dossier dans lequel la capture écrit en ce moment. Supprimer sous les
        // pieds de l'écrivain est une course, pas une purge. « Zéro jour » veut
        // donc dire « effacé à minuit », comme le journal du veilleur.
        let policy = ClipboardRetention.days(0)
        let names = [today, "2026-08-09"]
        #expect(policy.dayFoldersToPurge(from: names, today: today) == ["2026-08-09"])
    }

    @Test("Zéro jour ne conserve aucun contenu lourd passé")
    func zeroJour() {
        let policy = ClipboardRetention.days(0)
        #expect(policy.keepsNoBlobs)
        #expect(policy.label == "Aucun contenu lourd conservé")

        let names = ["2026-08-09", "2026-07-01", "2025-12-24"]
        #expect(policy.dayFoldersToPurge(from: names, today: today).count == 3)
    }

    @Test("Une bibliothèque vide ne fait rien purger")
    func entreeVide() {
        let policy = ClipboardRetention.days(30)
        #expect(policy.dayFoldersToPurge(from: [], today: today).isEmpty)
        #expect(policy.entriesToPurge(from: [], now: Date()).isEmpty)
    }

    @Test("Ce qui n'est pas manifestement une date survit")
    func nomsEtrangers() {
        // La seule chose qui empêche un dossier déposé à la main par
        // l'utilisateur, ou un `blobs/` mal rangé, d'être compté comme un jour
        // périmé et supprimé.
        let policy = ClipboardRetention.days(0)
        let names = [
            "blobs",
            ".DS_Store",
            "index.jsonl",
            "2026-8-1",            // pas de zéros de tête
            "2026-07-11.jsonl",    // une extension, donc pas un dossier-jour
            "AAAA-MM-JJ",
            "2026-07",
            "",
        ]
        #expect(policy.dayFoldersToPurge(from: names, today: today).isEmpty)
    }

    @Test("Un balayage rend les vieux et laisse les jeunes, dans l'ordre reçu")
    func balayageMixte() {
        let policy = ClipboardRetention.days(30)
        let names = ["2026-08-09", "2026-07-10", today, "2026-07-12", "2025-08-10", "blobs"]
        #expect(policy.dayFoldersToPurge(from: names, today: today) == ["2026-07-10", "2025-08-10"])
    }

    // MARK: - Décider entrée par entrée

    /// Un calendrier fixe. Sans lui, ces tests répondraient autre chose à Tokyo
    /// qu'à Paris : une clé de jour se lit dans le fuseau de l'utilisateur, et
    /// une purge qui dépend de la machine où le test tourne n'est pas testée.
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }

    /// Un instant nommé par son jour et son heure. Les dates de ces tests sont
    /// des dates de calendrier, pas des offsets depuis 1970 : c'est la seule
    /// façon de lire le cas limite sans le recalculer de tête.
    private func instant(_ day: String, hour: Int = 12) -> Date {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        return utc.date(
            from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: hour)
        ) ?? .distantPast
    }

    private func imageEntry(copiedAt: Date, purgedAt: Date? = nil) -> ClipboardEntry {
        ClipboardEntry(
            copiedAt: copiedAt,
            kind: .image,
            preview: "",
            blobs: [ClipboardBlobRef(hash: "beef", ext: "png", bytes: 158_000)],
            blobsPurgedAt: purgedAt
        )
    }

    private func purged(_ policy: ClipboardRetention, _ entry: ClipboardEntry, at now: Date) -> Bool {
        policy.entriesToPurge(from: [entry], now: now, calendar: utc).isEmpty == false
    }

    @Test("Une entrée dont le dossier atteint la limite part avec lui")
    func entreeALaLimite() {
        let policy = ClipboardRetention.days(30)
        let entry = imageEntry(copiedAt: instant("2026-07-11"))
        #expect(purged(policy, entry, at: instant(today)))
    }

    @Test("Une entrée d'un jour plus jeune survit")
    func entreeUnJourPlusJeune() {
        let policy = ClipboardRetention.days(30)
        let entry = imageEntry(copiedAt: instant("2026-07-12"))
        #expect(purged(policy, entry, at: instant(today)) == false)
    }

    // MARK: - L'invariant : une entrée ne survit jamais à son dossier

    @Test("Les deux chemins de purge rendent toujours le même verdict")
    func lesDeuxCheminsSontDAccord() {
        // **Le test qui tient tout ce fichier.** Ce qui supprime réellement le
        // PNG, c'est `rm` sur un dossier-jour ; ce que l'interface lit, c'est
        // l'entrée. Si les deux peuvent différer ne serait-ce qu'une heure,
        // `canPaste` finit par répondre « oui » au-dessus d'un fichier effacé.
        // Balayé sur quatre réglages, trente-six âges et quatre heures de copie.
        let now = instant(today, hour: 9)
        for blobDays in [0, 1, 7, 30] {
            let policy = ClipboardRetention.days(blobDays)
            for age in 0...35 {
                for hour in [0, 9, 18, 23] {
                    guard let copied = utc.date(
                        byAdding: .day, value: -age, to: instant(today, hour: hour)
                    ) else { continue }

                    let entry = imageEntry(copiedAt: copied)
                    let folder = entry.dayFolderName(calendar: utc)
                    let folderIsGone = policy
                        .dayFoldersToPurge(from: [folder], today: today).isEmpty == false

                    #expect(
                        purged(policy, entry, at: now) == folderIsGone,
                        "\(blobDays) jours, copiée \(age) jours plus tôt à \(hour) h"
                    )
                }
            }
        }
    }

    @Test("Une entrée copiée le soir ne survit pas à la matinée qui vide son dossier")
    func coinInfraJournalier() {
        // Copiée à 18 h le jour J, balayée à 9 h le jour J+7 : il ne s'est
        // écoulé que six jours et quinze heures. Compter en secondes gardait
        // l'entrée vivante au-dessus d'un dossier déjà supprimé — le désaccord
        // existait même sans aucune recopie.
        let policy = ClipboardRetention.days(7)
        let entry = imageEntry(copiedAt: instant("2026-08-01", hour: 18))
        let now = instant("2026-08-08", hour: 9)

        #expect(now.timeIntervalSince(entry.copiedAt) < policy.blobLifetime)
        #expect(policy.dayFoldersToPurge(from: ["2026-08-01"], today: "2026-08-08").isEmpty == false)
        #expect(purged(policy, entry, at: now))
    }

    @Test("Une image recopiée à cheval sur la limite ne prétend plus posséder son blob")
    func recopieACheval() {
        // Le cas exact qui a motivé le changement de modèle : copiée le jour J,
        // recopiée le jour J+6, rétention de sept jours. Le dossier J s'en va le
        // jour J+7 en emportant le PNG. L'ancienne règle comptait depuis la
        // recopie, ne sélectionnait pas l'entrée, ne posait jamais
        // `blobsPurgedAt` — et `canPaste` restait vrai au-dessus d'un fichier
        // qui n'existait plus.
        let policy = ClipboardRetention.days(7)
        let entry = imageEntry(copiedAt: instant("2026-08-01", hour: 18))
            .recopied(at: instant("2026-08-07", hour: 10))
        let now = instant("2026-08-08", hour: 9)

        #expect(entry.dayFolderName(calendar: utc) == "2026-08-01")
        #expect(policy.dayFoldersToPurge(from: ["2026-08-01"], today: "2026-08-08") == ["2026-08-01"])
        #expect(policy.entriesToPurge(from: [entry], now: now, calendar: utc).count == 1)
        #expect(policy.expiryDate(for: entry, calendar: utc) == instant("2026-08-08", hour: 0))
    }

    @Test("Recopier ne prolonge pas la vie du blob, et la date annoncée ne bouge pas")
    func recopieNeProlongePas() {
        // Le blob est posé dans le dossier de la première copie et n'en bouge
        // jamais ; le prolonger serait promettre une image que le balayage du
        // lendemain contredit. Le prix mesuré est nul : aucune recopie à plus
        // d'un jour d'écart sur les 250 entrées de l'historique réel, donc les
        // deux horloges désignaient déjà le même jour.
        let policy = ClipboardRetention.days(30)
        let once = imageEntry(copiedAt: instant("2026-07-01"))
        let twice = once.recopied(at: instant("2026-08-09"))

        #expect(twice.lastCopiedAt != twice.copiedAt)
        #expect(
            policy.expiryDate(for: twice, calendar: utc)
                == policy.expiryDate(for: once, calendar: utc)
        )
        #expect(purged(policy, twice, at: instant(today)))
    }

    @Test("Une entrée sans blob n'est jamais purgée")
    func entreeSansBlob() {
        // Le texte est conservé indéfiniment : c'est tout l'argument de la
        // fonctionnalité contre Maccy, qui n'a gardé que 4,7 jours sur
        // l'installation mesurée.
        let policy = ClipboardRetention.days(1)
        let entry = ClipboardEntry(
            copiedAt: instant("2025-08-10"),
            kind: .text,
            text: "un mot copié il y a un an"
        )
        #expect(purged(policy, entry, at: instant(today)) == false)
    }

    @Test("Une entrée déjà purgée ne ressort pas au balayage suivant")
    func pasDeDoublePurge() {
        // Sinon la date de purge affichée avancerait toute seule, tous les
        // jours, et l'entrée mentirait sur son propre passé.
        let policy = ClipboardRetention.days(30)
        let entry = imageEntry(
            copiedAt: instant("2026-05-12"),
            purgedAt: instant("2026-06-11")
        )
        #expect(purged(policy, entry, at: instant(today)) == false)
    }

    // MARK: - L'exception épinglée, et ce qu'elle exige du magasin

    @Test("Le dossier des épingles n'est jamais vu comme un jour")
    func leDossierEpingleNestJamaisUnJour() {
        // **Le test qui garde ce que l'utilisateur a demandé à garder pour
        // toujours.** Les contenus épinglés vivent dans `Clipboard/Pinned/blobs/`
        // et rien d'autre ne les protège que ceci : `day(from:)` n'y reconnaît
        // pas une date, donc `dayFoldersToPurge` ne les nomme jamais, donc le
        // `rm` ne les voit jamais. C'est exactement le genre de propriété qu'un
        // « nettoyage » du filtre — accepter les mois sans zéro de tête, ignorer
        // la casse, tolérer un suffixe — casserait sans que rien ne le dise, et
        // le dégât serait définitif.
        //
        // **Le nom testé est celui que le magasin écrit réellement**, et pas une
        // copie littérale posée ici : c'est ce qui fait tomber ce test si
        // quelqu'un renomme le dossier en « 2026-Pinned » plutôt que si
        // quelqu'un oublie de mettre les deux à jour. Le littéral est vérifié
        // juste à côté, pour que l'attente reste lisible sans ouvrir l'autre
        // fichier.
        #expect(ClipboardStore.pinnedFolderName == "Pinned")
        #expect(ClipboardRetention.day(from: ClipboardStore.pinnedFolderName) == nil)
        #expect(ClipboardRetention.day(from: "Pinned") == nil)

        // Et au réglage le plus destructeur, le balayage ne rend que le jour.
        let policy = ClipboardRetention.days(0)
        let names = [
            ClipboardStore.pinnedFolderName,
            "Pinned/blobs",
            "pinned",
            "PINNED",
            "2026-08-09",
        ]
        #expect(policy.dayFoldersToPurge(from: names, today: today) == ["2026-08-09"])
    }

    @Test("Une entrée épinglée n'est jamais purgée, même très ancienne")
    func entreeEpingleeJamaisPurgee() {
        // « Indéfiniment » veut dire à tous les réglages, y compris celui qui ne
        // conserve rien, et à tous les âges, y compris sept ans.
        let entry = imageEntry(copiedAt: instant("2019-01-01"))
            .pinned(at: instant("2019-01-02"))

        for blobDays in [0, 1, 7, 30, 365] {
            let policy = ClipboardRetention.days(blobDays)
            #expect(
                purged(policy, entry, at: instant(today)) == false,
                "réglage de \(blobDays) jours"
            )
        }
    }

    @Test("Épingler une entrée ne sauve pas le dossier de son jour")
    func lEpingleNeSauvePasLeDossier() {
        // **Le point difficile, écrit en test.** L'exclusion de `entriesToPurge`
        // ne suffit pas et ne peut pas suffire : ce qui supprime réellement le
        // PNG est un `rm` sur le sous-dossier `blobs/` d'un dossier-jour, choisi
        // sur son seul nom, sans qu'aucune entrée soit ouverte. Le dossier part
        // donc quand même — et si le magasin n'avait pas recopié le contenu dans
        // `Pinned/blobs/` avant, l'entrée survivrait en promettant un fichier
        // effacé. C'est le pire des deux mondes, et c'est ce que cette paire
        // d'attentes rend visible : le dossier s'en va, l'entrée ne bouge pas.
        let policy = ClipboardRetention.days(30)
        let entry = imageEntry(copiedAt: instant("2026-05-12"))
            .pinned(at: instant("2026-05-13"))

        #expect(entry.dayFolderName(calendar: utc) == "2026-05-12")
        #expect(policy.dayFoldersToPurge(from: ["2026-05-12"], today: today) == ["2026-05-12"])
        #expect(purged(policy, entry, at: instant(today)) == false)
        // Et l'entrée continue de dire qu'elle a son contenu, ce qui n'est vrai
        // que grâce à la recopie faite par `ClipboardStore`.
        #expect(entry.blobsArePurged == false)
        #expect(entry.canPaste)
    }

    @Test("Une épingle dans le lot n'empêche pas les autres d'être purgées")
    func lotMixteAvecUneEpingle() {
        let policy = ClipboardRetention.days(30)
        let ancienne = imageEntry(copiedAt: instant("2026-06-01"))
        let epinglee = imageEntry(copiedAt: instant("2026-06-01")).pinned(at: instant("2026-06-02"))
        let recente = imageEntry(copiedAt: instant("2026-08-09"))

        let selected = policy.entriesToPurge(
            from: [ancienne, epinglee, recente], now: instant(today), calendar: utc
        )
        let ids = selected.map { $0.id }
        #expect(ids == [ancienne.id])
    }

    @Test("Désépingler remet l'entrée sous la rétention")
    func desepinglerRemetSousLaRetention() {
        // L'épingle n'est pas un aller simple. Une fois lâchée, l'entrée
        // redevient exactement ce qu'elle était : son dossier est toujours
        // candidat, donc le balayage suivant la marque enfin purgée — avec la
        // date de ce balayage-là, qui est celle où le magasin supprime la copie
        // de `Pinned/blobs/`, et non celle où le dossier d'origine a été vidé.
        let policy = ClipboardRetention.days(30)
        let entry = imageEntry(copiedAt: instant("2026-05-12"))

        #expect(purged(policy, entry.pinned(at: instant("2026-05-13")), at: instant(today)) == false)
        #expect(purged(policy, entry.pinned(at: instant("2026-05-13")).unpinned(), at: instant(today)))
    }

    // MARK: - La date annoncée avant qu'elle arrive

    @Test("La date annoncée est le minuit où le dossier disparaît")
    func dateDExpiration() {
        // Elle doit nommer le jour où le fichier s'en va vraiment — donc être
        // dérivée de l'horloge qui supprime, et pas d'une autre. Copiée à 23 h,
        // l'entrée expire quand même au minuit qui ouvre J+3, pas trois fois
        // 86 400 secondes plus tard.
        let policy = ClipboardRetention.days(3)
        let entry = imageEntry(copiedAt: instant("2026-08-01", hour: 23))
        #expect(policy.expiryDate(for: entry, calendar: utc) == instant("2026-08-04", hour: 0))
        #expect(policy.dayFoldersToPurge(from: ["2026-08-01"], today: "2026-08-04").isEmpty == false)
    }

    @Test("Rien ne part avant la date annoncée, tout est parti à partir d'elle")
    func laDateAnnonceeEstTenue() throws {
        // La promesse faite aux réglages, vérifiée à la seconde près des deux
        // côtés de l'instant annoncé.
        let policy = ClipboardRetention.days(14)
        let entry = imageEntry(copiedAt: instant("2026-07-20", hour: 7))
        let expiry = try #require(policy.expiryDate(for: entry, calendar: utc))

        #expect(purged(policy, entry, at: expiry.addingTimeInterval(-1)) == false)
        #expect(purged(policy, entry, at: expiry))
    }

    @Test("Une entrée épinglée n'annonce aucune date, et n'en invente pas une lointaine")
    func aucuneDatePourUneEpingle() {
        // **Le type de retour a été rendu optionnel pour cette ligne-ci.** Les
        // trois autres réponses possibles étaient des mensonges : `copiedAt + 30
        // jours` afficherait dans les réglages une échéance que plus rien
        // n'honore, `.distantFuture` ferait écrire « 1 janvier 4001 » au premier
        // appelant qui formate sans réfléchir, et une date passée dirait
        // « déjà purgé » d'un contenu qui est là. `nil` ne se formate pas par
        // accident : le compilateur oblige l'interface à écrire la phrase du cas
        // épinglé au lieu de la deviner.
        let policy = ClipboardRetention.days(30)
        let entry = imageEntry(copiedAt: instant("2026-07-01"))
        let pinned = entry.pinned(at: instant("2026-07-02"))

        #expect(policy.expiryDate(for: entry, calendar: utc) == instant("2026-07-31", hour: 0))
        #expect(policy.expiryDate(for: pinned, calendar: utc) == nil)

        // Et lâcher l'épingle rend la date d'origine, inchangée : épingler n'a
        // pas déplacé le dossier-jour, donc n'a pas déplacé l'échéance.
        #expect(
            policy.expiryDate(for: pinned.unpinned(), calendar: utc)
                == policy.expiryDate(for: entry, calendar: utc)
        )
    }

    @Test("À zéro jour, la date annoncée est le minuit suivant et non l'instant même")
    func expirationAZeroJour() {
        // Le jour en cours n'est jamais touché : « zéro jour » veut dire
        // « effacé à minuit ». Sans plancher à un jour, les réglages
        // annonceraient une date déjà passée pour un contenu encore là.
        let policy = ClipboardRetention.days(0)
        let entry = imageEntry(copiedAt: instant("2026-08-09", hour: 14))

        #expect(policy.expiryDate(for: entry, calendar: utc) == instant("2026-08-10", hour: 0))
        #expect(purged(policy, entry, at: instant("2026-08-09", hour: 23)) == false)
        #expect(purged(policy, entry, at: instant("2026-08-10", hour: 0)))
    }

    // MARK: - Ce que les réglages montrent

    @Test("Les durées proposées sont ordonnées et commencent à zéro")
    func dureesProposees() {
        #expect(ClipboardRetention.offeredDays.first == 0)
        #expect(ClipboardRetention.offeredDays == ClipboardRetention.offeredDays.sorted())
        #expect(ClipboardRetention.offeredDays.contains(ClipboardRetention.default.blobDays))
    }

    @Test("Le défaut est trente jours, le double des captures d'écran")
    func valeurParDefaut() {
        #expect(ClipboardRetention.default.blobDays == 30)
        #expect(ClipboardRetention.default.blobLifetime == 2_592_000)
        #expect(ClipboardRetention.default.keepsNoBlobs == false)
    }

    @Test("Les libellés se lisent sans compter les jours")
    func libelles() {
        #expect(ClipboardRetention.days(1).label == "1 jour")
        #expect(ClipboardRetention.days(30).label == "30 jours")
        #expect(ClipboardRetention.days(365).label == "1 an")
        // La ligne qui empêche « 30 jours » de se lire comme « on perd tout au
        // bout de 30 jours ».
        #expect(ClipboardRetention.textLabel == "Texte conservé indéfiniment")
    }

    @Test("La politique se relit telle qu'elle a été écrite")
    func allerRetour() throws {
        let policy = ClipboardRetention.days(90)
        let data = try JSONEncoder().encode(policy)
        #expect(try JSONDecoder().decode(ClipboardRetention.self, from: data) == policy)
    }

    // MARK: - Nommer le dossier du jour

    @Test("La clé de jour est composée à la main, dans le calendrier de l'utilisateur")
    func cleDeJour() {
        // Un `DateFormatter` suivrait les réglages régionaux et rendrait autre
        // chose que `2026-08-06` en calendrier bouddhiste — des dossiers qui ne
        // se trient plus et une rétention qui ne reconnaît plus rien.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let date = Date(timeIntervalSince1970: 1_786_000_000)   // 2026-08-06 07:06:40 UTC

        let key = ClipboardRetention.dayKey(for: date, calendar: calendar)
        #expect(key == "2026-08-06")
        // Et ce que la clé produit, la politique doit savoir le relire.
        #expect(ClipboardRetention.day(from: key) == key)
    }
}
