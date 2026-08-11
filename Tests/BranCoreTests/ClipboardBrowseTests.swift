import Foundation
import Testing
@testable import BranCore

/// **La bibliothèque est l'écran où l'on vient chercher ce que le panneau ne
/// sait plus montrer.** Le panneau ouvre sur les dernières copies et se ferme
/// dans la seconde ; ici on remonte à trois semaines, on croise des filtres, et
/// on décide de supprimer ou d'épingler. Une recherche qui rate ne se voit donc
/// pas comme une recherche qui rate : elle se voit comme un historique qui a
/// perdu quelque chose, et c'est la seule accusation dont cette fonctionnalité
/// ne se relève pas.
///
/// D'où la forme de cette suite. Elle ne vérifie pas que « le filtre marche »,
/// elle garde les endroits où l'écran pourrait **taire** une entrée qui est là :
/// un mot au-delà de l'aperçu, un accent, un chemin encodé, une case cochée qui
/// en annule une autre, un menu d'applications qui se vide sous le curseur.
///
/// **`@MainActor` sur la suite entière** : `ClipboardBrowse.matches` renvoie
/// vers `ClipboardFilter.matches`, isolé parce que `ClipboardStore` l'est. Voir
/// la documentation des deux, qui explique le renvoi et pourquoi l'annotation
/// disparaîtra le jour où le corps de la règle descendra.
@Suite("La bibliothèque du presse-papiers")
@MainActor
struct ClipboardBrowseTests {

    // MARK: - Fabriques

    /// Une entrée, dont chaque paramètre correspond à une chose que l'écran sait
    /// filtrer ou compter. `minute` sert à rendre l'ordre des listes lisible :
    /// la minute la plus grande est la copie la plus récente.
    private func entry(
        _ preview: String,
        full: String? = nil,
        kind: ClipboardKind = .text,
        app: String? = nil,
        bundle: String? = nil,
        files: [String]? = nil,
        bytes: Int = 0,
        copies: Int = 1,
        pinned: Bool = false,
        minute: Double = 0
    ) -> ClipboardEntry {
        var made = ClipboardEntry(
            copiedAt: Date(timeIntervalSince1970: minute * 60),
            kind: kind,
            preview: preview,
            repeatCount: copies > 1 ? copies - 1 : nil,
            source: app == nil && bundle == nil
                ? nil
                : ClipboardSource(bundleIdentifier: bundle, name: app),
            plainText: full,
            blobs: bytes > 0
                ? [ClipboardBlobRef(hash: "hash-\(Int(minute))", ext: "png", bytes: bytes)]
                : nil,
            fileURLs: files
        )
        if pinned { made.pinnedAt = Date(timeIntervalSince1970: 0) }
        return made
    }

    private func previews(_ entries: [ClipboardEntry]) -> [String] {
        entries.map(\.preview)
    }

    // MARK: - Chercher

    @Test("Une requête vide rend tout l'historique")
    func requeteVide() {
        let entries = [entry("un", minute: 0), entry("deux", minute: 1)]
        let kept = ClipboardBrowse.filtered(entries, filter: ClipboardBrowseFilter())
        #expect(kept.count == 2)
    }

    /// **Le gain de cet écran sur le panneau tient dans ce test.**
    /// `ClipboardEntry.preview` s'arrête à 512 caractères ; le panneau ne cherche
    /// que là. Un mot du troisième paragraphe d'un texte copié était donc
    /// introuvable, sans qu'aucun signe ne dise que la recherche n'avait pas
    /// regardé jusque-là.
    @Test("La recherche descend dans le texte complet, au-delà de l'aperçu")
    func rechercheTexteComplet() {
        let entries = [
            entry("Le début du contrat", full: "Le début du contrat, puis la clause de résiliation")
        ]
        #expect(
            ClipboardBrowse.filtered(
                entries, filter: ClipboardBrowseFilter(query: "résiliation")
            ).count == 1
        )
        // Contre-épreuve : le panneau, lui, ne la trouve pas. Si un jour il la
        // trouve, ce n'est pas ce test-ci qui doit changer — c'est que la règle
        // aura déménagé, et alors la bibliothèque en héritera gratuitement.
        #expect(ClipboardFilter.visible(entries, matching: "résiliation").isEmpty)
    }

    /// Une recherche qui punit de taper vite n'est pas utilisée deux fois. La
    /// règle vaut pour l'aperçu — le panneau la tient déjà — **et pour les deux
    /// gisements que la bibliothèque ajoute**, qui auraient très bien pu la
    /// perdre en chemin.
    @Test("Chercher « resume » trouve « résumé », y compris dans le texte complet")
    func insensibleAuxDiacritiques() {
        let entries = [entry("Notes", full: "Voici le résumé de la réunion")]
        #expect(
            ClipboardBrowse.filtered(
                entries, filter: ClipboardBrowseFilter(query: "resume")
            ).count == 1
        )
        #expect(
            ClipboardBrowse.filtered(
                entries, filter: ClipboardBrowseFilter(query: "REUNION")
            ).count == 1
        )
    }

    @Test("La recherche trouve un fichier par son chemin")
    func rechercheParChemin() {
        let entries = [
            entry("", kind: .file, files: ["/Users/moi/Factures/2026/juillet.pdf"])
        ]
        #expect(
            ClipboardBrowse.filtered(
                entries, filter: ClipboardBrowseFilter(query: "Factures")
            ).count == 1
        )
        #expect(
            ClipboardBrowse.filtered(
                entries, filter: ClipboardBrowseFilter(query: "juillet")
            ).count == 1
        )
    }

    /// **Ce que le presse-papiers donne n'est pas toujours un chemin nu.** Une
    /// URL de fichier écrit l'espace `%20` ; chercher « Mon dossier » ne rendait
    /// alors rien, et l'échec ne s'attribue jamais à l'encodage — on conclut que
    /// la recherche ne marche pas sur les fichiers, et on cesse de s'en servir.
    @Test("Un chemin encodé en pourcents reste cherchable en clair")
    func cheminEncode() {
        let entries = [
            entry("", kind: .file, files: ["file:///Users/moi/Mon%20dossier/note%20de%20frais.pdf"])
        ]
        #expect(
            ClipboardBrowse.filtered(
                entries, filter: ClipboardBrowseFilter(query: "Mon dossier")
            ).count == 1
        )
        #expect(
            ClipboardBrowse.filtered(
                entries, filter: ClipboardBrowseFilter(query: "note de frais")
            ).count == 1
        )
    }

    /// **L'invariant qui ne doit jamais se casser en silence.** Une bibliothèque
    /// qui trouverait *moins* que la fenêtre flottante serait absurde ; et comme
    /// la recherche de l'une renvoie vers celle de l'autre, la seule façon de
    /// rompre l'inclusion serait de recopier la règle ici. Ce test est ce qui
    /// rendrait cette recopie bruyante.
    @Test("Tout ce que le panneau trouve, la bibliothèque le trouve aussi")
    func surEnsembleDuPanneau() {
        let entries = [
            entry("bonjour tout le monde", app: "Terminal", minute: 0),
            entry("facture 2026", app: "Google Chrome", minute: 1),
            entry("rien à voir", minute: 2),
        ]
        for query in ["bonjour", "chrome", "2026", "TERMINAL", "à voir"] {
            let panel = Set(ClipboardFilter.visible(entries, matching: query).map(\.id))
            let library = Set(
                ClipboardBrowse.filtered(
                    entries, filter: ClipboardBrowseFilter(query: query)
                ).map(\.id)
            )
            #expect(panel.isSubset(of: library), "« \(query) » n'est plus un sur-ensemble")
        }
    }

    // MARK: - Filtrer par sorte

    @Test("Le filtre par sorte ne garde que les sortes cochées")
    func filtreParSorte() {
        let entries = [
            entry("texte", kind: .text, minute: 0),
            entry("", kind: .image, bytes: 1_000, minute: 1),
            entry("", kind: .file, files: ["/tmp/a.txt"], minute: 2),
        ]
        let kept = ClipboardBrowse.filtered(
            entries, filter: ClipboardBrowseFilter(kinds: [.image])
        )
        #expect(kept.count == 1)
        #expect(kept.first?.kind == .image)
    }

    /// **Le piège de ce modèle, et il se paie cher.** Un écran qui ouvrirait sur
    /// une liste vide parce qu'aucune case n'est cochée serait tenu pour cassé
    /// avant qu'on ait eu l'idée d'en cocher une. Décocher la dernière case rend
    /// donc l'écran complet — ce que fait aussi le Finder.
    @Test("Aucune sorte cochée vaut toutes les sortes")
    func aucuneSorteCochee() {
        let entries = [
            entry("texte", kind: .text, minute: 0),
            entry("", kind: .image, bytes: 10, minute: 1),
        ]
        #expect(ClipboardBrowse.filtered(entries, filter: ClipboardBrowseFilter()).count == 2)
    }

    // MARK: - Filtrer par application

    @Test("Le filtre par application ne garde que cette application")
    func filtreParApplication() {
        let entries = [
            entry("un", app: "Terminal", bundle: "com.apple.Terminal", minute: 0),
            entry("deux", app: "Google Chrome", bundle: "com.google.Chrome", minute: 1),
        ]
        let kept = ClipboardBrowse.filtered(
            entries, filter: ClipboardBrowseFilter(apps: ["com.apple.Terminal"])
        )
        #expect(previews(kept) == ["un"])
    }

    /// `ClipboardSource.isUnknown` demande à l'interface de **se taire** plutôt
    /// que d'écrire « Inconnu ». Il n'y a donc aucune ligne à cocher pour les
    /// entrées sans source, et un filtre qui nomme des applications ne peut pas
    /// en retenir une dont on ignore la provenance. Le cas est réel : la source
    /// n'est pas toujours lisible au moment de la copie.
    @Test("Une entrée sans source ne passe aucun filtre d'application")
    func entreeSansSource() {
        let entries = [
            entry("sans source", minute: 0),
            entry("avec source", app: "Terminal", bundle: "com.apple.Terminal", minute: 1),
        ]
        let kept = ClipboardBrowse.filtered(
            entries, filter: ClipboardBrowseFilter(apps: ["com.apple.Terminal"])
        )
        #expect(previews(kept) == ["avec source"])
    }

    /// Une source sans identifiant de paquet se replie sur son nom plutôt que de
    /// disparaître du menu : la clé est l'identifiant **quand on l'a**.
    @Test("Une source sans identifiant de paquet se filtre par son nom")
    func sourceSansIdentifiant() {
        let entries = [entry("un", app: "Éditeur maison", minute: 0)]
        let kept = ClipboardBrowse.filtered(
            entries, filter: ClipboardBrowseFilter(apps: ["Éditeur maison"])
        )
        #expect(kept.count == 1)
    }

    // MARK: - Filtrer les épingles

    @Test("Le filtre des épinglées ne garde que les épingles")
    func filtreEpingles() {
        let entries = [
            entry("gardée", pinned: true, minute: 0),
            entry("ordinaire", minute: 1),
        ]
        let kept = ClipboardBrowse.filtered(
            entries, filter: ClipboardBrowseFilter(pinnedOnly: true)
        )
        #expect(previews(kept) == ["gardée"])
    }

    // MARK: - Croiser

    @Test("Deux filtres cochés se cumulent au lieu de s'annuler")
    func deuxFiltres() {
        let entries = [
            entry("image de Chrome", kind: .image, app: "Chrome", bundle: "com.google.Chrome", bytes: 10, minute: 0),
            entry("texte de Chrome", kind: .text, app: "Chrome", bundle: "com.google.Chrome", minute: 1),
            entry("image du Terminal", kind: .image, app: "Terminal", bundle: "com.apple.Terminal", bytes: 10, minute: 2),
        ]
        let kept = ClipboardBrowse.filtered(
            entries,
            filter: ClipboardBrowseFilter(kinds: [.image], apps: ["com.google.Chrome"])
        )
        #expect(previews(kept) == ["image de Chrome"])
    }

    @Test("Une recherche et un filtre se cumulent aussi")
    func rechercheEtFiltre() {
        let entries = [
            entry("contrat signé", pinned: true, minute: 0),
            entry("contrat brouillon", minute: 1),
            entry("facture", pinned: true, minute: 2),
        ]
        let kept = ClipboardBrowse.filtered(
            entries, filter: ClipboardBrowseFilter(query: "contrat", pinnedOnly: true)
        )
        #expect(previews(kept) == ["contrat signé"])
    }

    // MARK: - Le résumé

    @Test("Le résumé compte les entrées, les épingles et les octets")
    func resume() {
        let entries = [
            entry("un", bytes: 1_000, pinned: true, minute: 0),
            entry("deux", bytes: 2_500, minute: 1),
            entry("trois", minute: 2),
        ]
        let summary = ClipboardBrowse.summary(of: entries)
        #expect(summary.count == 3)
        #expect(summary.pinnedCount == 1)
        #expect(summary.bytes == 3_500)
        #expect(summary.characters == "un".count + "deux".count + "trois".count)
        #expect(summary.earliest == Date(timeIntervalSince1970: 0))
        #expect(summary.latest == Date(timeIntervalSince1970: 120))
    }

    /// Le résumé porte sur **ce que le filtre a retenu**, jamais sur
    /// l'historique entier — sinon il annonce un total que la liste juste en
    /// dessous contredit.
    @Test("Le résumé porte sur la liste filtrée, pas sur l'historique")
    func resumeDuFiltre() {
        let entries = [
            entry("gardée", bytes: 400, pinned: true, minute: 0),
            entry("ordinaire", bytes: 9_000, minute: 1),
        ]
        let result = ClipboardBrowse.result(
            entries, filter: ClipboardBrowseFilter(pinnedOnly: true)
        )
        #expect(result.summary.count == 1)
        #expect(result.summary.bytes == 400)
    }

    @Test("Le résumé d'une liste vide n'a ni date ni octet")
    func resumeVide() {
        let summary = ClipboardBrowse.summary(of: [])
        #expect(summary.isEmpty)
        #expect(summary.bytes == 0)
        #expect(summary.earliest == nil)
        #expect(summary.latest == nil)
    }

    /// Écrire « 0 octet » sur un historique de texte pur — le cas de loin le
    /// plus fréquent — occuperait la ligne pour dire que la fonctionnalité ne
    /// consomme rien, ce que personne n'est venu vérifier.
    @Test("Le résumé ne parle d'octets que s'il y en a")
    func resumeSansOctets() {
        let sans = ClipboardBrowse.summary(of: [entry("un"), entry("deux", minute: 1)])
        #expect(sans.description == "2 entrées")

        let avec = ClipboardBrowse.summary(of: [entry("un", bytes: 2_048, pinned: true)])
        #expect(avec.description.hasPrefix("1 entrée · 1 épinglée · "))
    }

    // MARK: - Les applications présentes

    @Test("Les applications présentes sont dédupliquées et comptées")
    func applicationsPresentes() {
        let entries = [
            entry("un", app: "Terminal", bundle: "com.apple.Terminal", minute: 0),
            entry("deux", app: "Terminal", bundle: "com.apple.Terminal", minute: 1),
            entry("trois", app: "Google Chrome", bundle: "com.google.Chrome", minute: 2),
        ]
        let apps = ClipboardBrowse.apps(in: entries)
        #expect(apps.count == 2)
        #expect(apps.first?.id == "com.apple.Terminal")
        #expect(apps.first?.name == "Terminal")
        #expect(apps.first?.count == 2)
    }

    /// Mesuré : Chrome et Terminal produisent 77 % de tout l'historique réel. Un
    /// menu dont les deux premières lignes répondent aux trois quarts des
    /// intentions vaut le risque qu'un jour deux applications s'échangent leur
    /// rang.
    @Test("Les applications sont classées par fréquence")
    func applicationsClassees() {
        let entries = [
            entry("a", app: "Rare", bundle: "com.rare", minute: 0),
            entry("b", app: "Fréquente", bundle: "com.frequente", minute: 1),
            entry("c", app: "Fréquente", bundle: "com.frequente", minute: 2),
        ]
        #expect(ClipboardBrowse.apps(in: entries).map(\.id) == ["com.frequente", "com.rare"])
    }

    @Test("Le menu des applications ignore les entrées sans source")
    func applicationsSansSource() {
        let entries = [entry("un", minute: 0), entry("deux", app: "Terminal", minute: 1)]
        #expect(ClipboardBrowse.apps(in: entries).map(\.name) == ["Terminal"])
    }

    /// **Un filtre doit pouvoir se défaire par là où il s'est fait.** Un menu
    /// construit sur le résultat se viderait au premier clic : cocher
    /// « Terminal » ferait disparaître les autres applications du menu, et il n'y
    /// aurait plus aucun moyen de changer d'avis.
    @Test("Le menu des applications reste celui de l'historique entier")
    func menuStableApresFiltrage() {
        let entries = [
            entry("un", app: "Terminal", bundle: "com.apple.Terminal", minute: 0),
            entry("deux", app: "Chrome", bundle: "com.google.Chrome", minute: 1),
        ]
        let result = ClipboardBrowse.result(
            entries, filter: ClipboardBrowseFilter(apps: ["com.apple.Terminal"])
        )
        #expect(result.entries.count == 1)
        #expect(result.apps.count == 2)
    }

    // MARK: - Trier

    @Test("L'ordre par défaut est celui du magasin : la copie la plus récente en tête")
    func ordreParDefaut() {
        let entries = [
            entry("vieille", minute: 0),
            entry("récente", minute: 2),
            entry("moyenne", minute: 1),
        ]
        let kept = ClipboardBrowse.filtered(entries, filter: ClipboardBrowseFilter())
        #expect(previews(kept) == ["récente", "moyenne", "vieille"])
        // Le même ordre que le magasin, parce que c'est le magasin qu'on appelle.
        #expect(previews(kept) == previews(ClipboardStore.ordered(entries)))
    }

    /// Le fond de la pile est précisément ce que le panneau ne montre jamais.
    /// Sans ce tri, « on garde tout » est une affirmation invérifiable.
    @Test("Le tri par ancienneté remonte le temps")
    func triAncien() {
        let entries = [entry("vieille", minute: 0), entry("récente", minute: 2)]
        let kept = ClipboardBrowse.sorted(entries, by: .oldestFirst)
        #expect(previews(kept) == ["vieille", "récente"])
    }

    @Test("Le tri par recopies met la plus recopiée en tête")
    func triRecopies() {
        let entries = [
            entry("une fois", copies: 1, minute: 2),
            entry("quatre fois", copies: 4, minute: 0),
            entry("deux fois", copies: 2, minute: 1),
        ]
        let kept = ClipboardBrowse.sorted(entries, by: .mostCopied)
        #expect(previews(kept) == ["quatre fois", "deux fois", "une fois"])
    }

    @Test("Le tri par taille met la plus lourde en tête")
    func triTaille() {
        let entries = [
            entry("petite", bytes: 1_000, minute: 2),
            entry("énorme", bytes: 900_000, minute: 0),
            entry("moyenne", bytes: 50_000, minute: 1),
        ]
        let kept = ClipboardBrowse.sorted(entries, by: .largest)
        #expect(previews(kept) == ["énorme", "moyenne", "petite"])
    }

    /// Les ex æquo départagent par la chronologie, puis par l'identifiant : sans
    /// cette cascade, deux entrées de même poids changeraient d'ordre entre deux
    /// passes de dessin, ce qui se lit comme une liste qui bouge toute seule.
    @Test("Deux entrées de même poids gardent un ordre stable")
    func triStable() {
        let entries = [
            entry("ancienne", bytes: 500, minute: 0),
            entry("récente", bytes: 500, minute: 1),
        ]
        let once = ClipboardBrowse.sorted(entries, by: .largest)
        let twice = ClipboardBrowse.sorted(Array(entries.reversed()), by: .largest)
        #expect(previews(once) == ["récente", "ancienne"])
        #expect(previews(once) == previews(twice))
    }

    /// Un regroupement par jour impose son propre ordre. L'appliquer à un
    /// classement par poids effacerait le tri demandé : on obtiendrait une liste
    /// chronologique sous un intitulé qui promet autre chose — pire que de ne
    /// pas offrir le tri.
    @Test("Seule la chronologie descendante se regroupe par jour")
    func regroupementParJour() {
        let grouping = ClipboardBrowseSort.allCases.filter { $0.groupsByDay }
        #expect(grouping == [.newestFirst])
    }

    // MARK: - Le filtre comme valeur

    @Test("Un filtre neuf ne restreint rien")
    func filtreNeutre() {
        #expect(ClipboardBrowseFilter.everything.narrowsBeyondQuery == false)
        #expect(ClipboardBrowseFilter.everything.narrowingCount == 0)
    }

    /// La distinction entre « votre recherche ne rend rien » et « vos filtres ne
    /// laissent rien passer » n'est pas cosmétique : ce n'est pas le même geste
    /// qui répare, et un état vide qui ne dit pas pourquoi il est vide est un
    /// cul-de-sac.
    @Test("Une recherche seule ne compte pas comme un filtre")
    func rechercheNestPasUnFiltre() {
        let filter = ClipboardBrowseFilter(query: "contrat")
        #expect(filter.narrowsBeyondQuery == false)

        let narrowed = ClipboardBrowseFilter(query: "contrat", kinds: [.image], pinnedOnly: true)
        #expect(narrowed.narrowsBeyondQuery)
        #expect(narrowed.narrowingCount == 2)
    }

    /// Décocher n'est pas recommencer : quelqu'un qui a tapé trois mots puis
    /// décoche veut voir ses trois mots sur tout l'historique.
    @Test("Décocher les filtres garde la recherche et l'ordre")
    func decocher() {
        let filter = ClipboardBrowseFilter(
            query: "contrat", kinds: [.image], apps: ["com.apple.Terminal"],
            pinnedOnly: true, sort: .largest
        )
        let cleared = filter.withoutNarrowing
        #expect(cleared.query == "contrat")
        #expect(cleared.sort == .largest)
        #expect(cleared.narrowsBeyondQuery == false)
    }

    @Test("Cocher deux fois la même case la décoche")
    func cocherDecocher() {
        var filter = ClipboardBrowseFilter()
        filter.toggle(.image)
        #expect(filter.kinds == [.image])
        filter.toggle(.image)
        #expect(filter.kinds.isEmpty)

        filter.toggle(app: "com.apple.Terminal")
        #expect(filter.apps == ["com.apple.Terminal"])
        filter.toggle(app: "com.apple.Terminal")
        #expect(filter.apps.isEmpty)
    }
}
