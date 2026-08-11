import AppKit
import BranCore
import BranSpeech
import SwiftUI

/// La section « Presse-papiers » : la bibliothèque, dans la fenêtre principale.
///
/// ## Ce qu'elle est, et ce que le panneau n'est pas
///
/// L'historique a déjà une surface : le panneau flottant de ⌘⇧C, fait pour
/// choisir et coller en deux secondes. Celle-ci est l'autre moitié, et elle
/// répond à une question que l'autre ne peut pas porter — « où est passée cette
/// chose que j'ai copiée il y a trois semaines ». Tout ce qui les sépare découle
/// de là : ici on cherche plus profond (le texte complet, les chemins de
/// fichiers), on croise des filtres, on trie autrement que par l'heure, on lit
/// des détails que neuf lignes de 44 points ne peuvent pas tenir, et on épingle
/// ce qu'on veut garder. Il n'y a pas de budget de 50 ms : personne n'ouvre un
/// onglet pour coller dans la seconde.
///
/// La logique est ailleurs — `ClipboardBrowse`, dans `BranCore` — et c'est la
/// seule raison pour laquelle « chercher « resume » trouve « résumé » » est une
/// phrase qu'un test vérifie plutôt qu'une phrase qu'on croit.
///
/// ## La même forme que les trois autres sections
///
/// En-tête, barre de recherche, bandeaux, liste groupée par jour : c'est
/// `SnapshotPane` et `DictationPane`, jusqu'aux mots des états vides. Un
/// quatrième écran qui ne ressemblerait pas aux trois autres serait un défaut,
/// pas une originalité — on sait où regarder avant d'avoir lu, et c'est ce que
/// coûte chaque écart.
///
/// **Un seul écart, et il est argumenté sur place : la ligne.** Voir
/// `ClipboardLibraryRow` — hauteur fixe, vignette, pas de chevron, pas de
/// `branCard`.
///
/// ## Les animations
///
/// Une seule dans tout le fichier, sur les bandeaux, par `branAnimation` comme
/// les trois autres panes. **La liste n'est jamais animée** : un diff animé au
/// filtrage ferait glisser jusqu'à `ClipboardStore.windowSize` lignes à chaque
/// frappe. Et rien ici ne mute la liste de façon synchrone — épingler et
/// supprimer passent par le magasin, donc par une tâche —, si bien qu'il n'y a
/// pas même de `withAnimation` à honorer : `Motion.honouring` n'a pas d'emploi
/// dans ce fichier, alors qu'il en a un dans le panneau.
struct ClipboardPane: View {

    @Bindable var model: AppModel
    @Binding var query: String

    /// Ce que la recherche est allée chercher **sur le disque**, au-delà de la
    /// fenêtre en mémoire.
    ///
    /// **Sans ça, cet écran ne tenait pas sa promesse.** Il ne montrait que les
    /// ~500 entrées que `ClipboardStore` garde sous la main : tout ce qui est
    /// plus ancien était introuvable — pas cherchable, pas filtrable, pas
    /// épinglable, pas supprimable — alors que la question à laquelle un écran
    /// de bibliothèque répond est précisément « où est passée cette chose que
    /// j'ai copiée il y a trois semaines ». Une revue l'a relevé, et
    /// `ClipboardStore.search(_:limit:)` existait déjà pour exactement ça.
    ///
    /// **Uniquement sur validation, jamais à la frappe.** La descente lit un
    /// `index.jsonl` par jour — 365 petits fichiers pour une année. C'est
    /// tenable hors du chemin d'un geste, et un contresens à chaque caractère.
    /// La documentation de `search` le dit en toutes lettres.
    @State private var deeper: [ClipboardEntry] = []

    /// Les cases cochées. Un état de vue et non un réglage persisté : un filtre
    /// est une intention du moment, et retrouver son historique filtré au
    /// prochain lancement — sans se souvenir de l'avoir demandé — ressemble à un
    /// historique qui a perdu des lignes.
    @State private var kinds: Set<ClipboardKind> = []
    @State private var apps: Set<String> = []
    @State private var pinnedOnly = false
    @State private var sort: ClipboardBrowseSort = .newestFirst

    /// L'écrivain du presse-papiers, **construit dans `.task` et non en
    /// initialiseur de propriété**.
    ///
    /// `Paster` est `@MainActor` ; l'initialiseur d'un `@State` s'exécute au
    /// moment où la structure de vue est construite, c'est-à-dire dans un
    /// contexte que le compilateur ne considère pas comme isolé. L'optionnel
    /// coûte un `guard let` au moment de copier et évite d'avoir à promettre au
    /// compilateur une isolation qu'on ne peut pas lui prouver.
    ///
    /// **Passer par `Paster` et non par `NSPasteboard`** est ce qui empêche un
    /// doublon à chaque recopie : l'écriture est annoncée à
    /// `ClipboardController`, qui sait alors qu'elle vient de bran et ne la
    /// range pas une seconde fois dans la liste dont elle sort. Voir
    /// `PasteboardAccess.write(_:expecting:claiming:)`, dont c'est la condition
    /// d'existence.
    @State private var paster: Paster?

    private var controller: ClipboardController { model.clipboard }
    private var store: ClipboardStore { controller.store }


    private var filter: ClipboardBrowseFilter {
        ClipboardBrowseFilter(
            query: query, kinds: kinds, apps: apps, pinnedOnly: pinnedOnly, sort: sort
        )
    }

    var body: some View {
        // **Une seule lecture par passe de `body`.** Le calcul filtre jusqu'à
        // `ClipboardStore.windowSize` entrées ; le refaire une fois par ligne le
        // rendrait quadratique, ce qui est exactement le coût que tout le
        // stockage du presse-papiers a été conçu pour ne pas payer.
        let result = ClipboardBrowse.result(store.recent + deeper, filter: filter)

        return VStack(spacing: 0) {
            PaneHeader(
                title: LibraryPane.clipboard.title,
                subtitle: LibraryPane.clipboard.subtitle,
                query: $query,
                searchPrompt: "Chercher dans le presse-papiers, un chemin de fichier, ou par application"
            ) {
                ClipboardStatusChip(model: model)
            }
            // **À la validation, pas à la frappe.** `PaneHeader` ne propose pas
            // de rappel de soumission — les deux autres panes filtrent en
            // mémoire et n'en ont jamais eu besoin — donc on écoute la touche
            // Entrée là où elle remonte. Filtrer à chaque caractère resterait
            // instantané sur la fenêtre en mémoire ; c'est la **descente sur le
            // disque** qu'on ne veut pas déclencher à chaque frappe.
            .onSubmit { Task { await searchDeeper() } }

            Divider()

            toolbar(result)

            Divider()

            notices

            content(result)
        }
        .task {
            if paster == nil { paster = Paster() }
            // **Relire au lieu de faire confiance à la fenêtre en mémoire.**
            // `ClipboardController.start` l'a remplie au lancement et les
            // écritures la tiennent à jour ; mais la bibliothèque est un dossier
            // que l'utilisateur est invité à ouvrir, à déplacer et à
            // sauvegarder, et une restauration faite pendant que bran tourne ne
            // se voit par aucun autre chemin. Le coût est celui d'une dizaine de
            // `index.jsonl`, hors de tout geste — c'est ce que font déjà les
            // deux autres panes en arrivant.
            await store.load()
            await searchDeeper()
        }
    }

    // MARK: - La barre de filtres

    /// Ce que le panneau ne peut pas offrir : croiser, trier, et dire combien.
    ///
    /// **Sous l'en-tête et non dans une barre d'outils de fenêtre.** La
    /// recherche vit déjà au milieu du contenu — `PaneHeader` l'y a mise
    /// exprès, c'est là qu'on la cherche du regard — et poser ses filtres à
    /// trente centimètres de là, en haut de la fenêtre, obligerait à faire
    /// l'aller-retour pour comprendre pourquoi la liste est courte.
    private func toolbar(_ result: ClipboardBrowseResult) -> some View {
        HStack(spacing: Space.small) {
            sortMenu
            kindsMenu
            appsMenu(result.apps)
            pinnedToggle

            Spacer(minLength: Space.small)

            // Le résumé porte sur ce que le filtre a retenu, jamais sur
            // l'historique entier : un total que la liste juste en dessous
            // contredit est pire que pas de total.
            Text(result.summary.description)
                .font(Type.meta)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityLabel("Sélection : \(result.summary.description)")

            if filter.narrowsBeyondQuery {
                Button("Tout afficher", action: clearNarrowing)
                    .help("Décocher tous les filtres, sans effacer la recherche")
            }
        }
        .controlSize(.small)
        .padding(.horizontal, Space.gutter)
        .padding(.vertical, Space.small)
    }

    private var sortMenu: some View {
        Menu {
            Picker("Trier", selection: $sort) {
                ForEach(ClipboardBrowseSort.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Label(sort.label, systemImage: "arrow.up.arrow.down")
        }
        .fixedSize()
        .help("L'ordre de la liste")
        .accessibilityLabel("Trier : \(sort.label)")
    }

    private var kindsMenu: some View {
        Menu {
            ForEach(ClipboardKind.allCases, id: \.self) { kind in
                Toggle(ClipboardBrowse.name(for: kind), isOn: binding(for: kind))
            }
            if kinds.isEmpty == false {
                Divider()
                Button("Toutes les sortes") { kinds = [] }
            }
        } label: {
            Label(kindsLabel, systemImage: "square.grid.2x2")
        }
        .fixedSize()
        .help("Ne montrer que certaines sortes de contenus")
        .accessibilityLabel("Filtrer par sorte : \(kindsLabel)")
    }

    private func appsMenu(_ available: [ClipboardApp]) -> some View {
        Menu {
            if available.isEmpty {
                // Une source manquante n'est pas une panne — elle n'a
                // simplement pas pu être lue au moment de la copie, et
                // `ClipboardSource.isUnknown` demande alors de se taire plutôt
                // que d'écrire « Inconnu ». Un menu vide doit quand même dire
                // pourquoi il est vide.
                Text("Aucune application connue")
            }
            ForEach(available) { app in
                Toggle("\(app.name) (\(app.count))", isOn: binding(for: app.id))
            }
            if apps.isEmpty == false {
                Divider()
                Button("Toutes les applications") { apps = [] }
            }
        } label: {
            Label(appsLabel, systemImage: "app.dashed")
        }
        .fixedSize()
        .help("Ne montrer que ce qui vient de certaines applications")
        .accessibilityLabel("Filtrer par application : \(appsLabel)")
    }

    private var pinnedToggle: some View {
        Toggle(isOn: $pinnedOnly) {
            Label("Épinglées", systemImage: pinnedOnly ? "pin.fill" : "pin")
        }
        .toggleStyle(.button)
        .help("Ne montrer que les entrées épinglées")
    }

    private var kindsLabel: String {
        guard kinds.isEmpty == false else { return "Toutes les sortes" }
        guard kinds.count == 1, let only = kinds.first else { return "\(kinds.count) sortes" }
        return ClipboardBrowse.name(for: only)
    }

    private var appsLabel: String {
        guard apps.isEmpty == false else { return "Toutes les applications" }
        return apps.count == 1 ? "1 application" : "\(apps.count) applications"
    }

    private func binding(for kind: ClipboardKind) -> Binding<Bool> {
        Binding(
            get: { kinds.contains(kind) },
            set: { if $0 { kinds.insert(kind) } else { kinds.remove(kind) } }
        )
    }

    private func binding(for app: String) -> Binding<Bool> {
        Binding(
            get: { apps.contains(app) },
            set: { if $0 { apps.insert(app) } else { apps.remove(app) } }
        )
    }

    /// Décocher n'est pas recommencer : la recherche et l'ordre survivent. Voir
    /// `ClipboardBrowseFilter.withoutNarrowing`, qui porte la règle.
    private func clearNarrowing() {
        let cleared = filter.withoutNarrowing
        kinds = cleared.kinds
        apps = cleared.apps
        pinnedOnly = cleared.pinnedOnly
    }

    // MARK: - Les bandeaux

    /// Les deux choses qu'il faut dire avant la liste.
    ///
    /// Même forme, même symbole et mêmes mots que les trois autres panes : un
    /// bandeau qui dirait la même panne autrement obligerait à la reconnaître
    /// deux fois.
    @ViewBuilder
    /// Va chercher sur le disque ce que la fenêtre en mémoire ne contient pas.
    ///
    /// Appelée à l'arrivée sur l'écran **et à la validation de la recherche**,
    /// jamais à la frappe : la descente lit un `index.jsonl` par jour, ce qui
    /// est tenable hors du chemin d'un geste et un contresens à chaque
    /// caractère. C'est exactement le partage que documente
    /// `ClipboardStore.search(_:limit:)`.
    ///
    /// Le résultat s'**ajoute** à la fenêtre plutôt que de la remplacer, et
    /// `ClipboardBrowse` dédoublonne : une recherche vide laisse donc l'écran
    /// exactement tel qu'il était, et une recherche qui ne trouve rien de plus
    /// ne retire rien.
    private func searchDeeper() async {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard needle.isEmpty == false else {
            deeper = []
            return
        }
        let known = Set(store.recent.map(\.id))
        deeper = await store.search(needle).filter { known.contains($0.id) == false }
    }

    private var notices: some View {
        VStack(spacing: 0) {
            // **La capture éteinte doit se dire ici, et nulle part ailleurs
            // elle ne se dirait.** Ce n'est pas une panne : c'est un réglage, et
            // il est parfaitement légitime. Mais son symptôme — plus rien de
            // neuf n'apparaît dans une liste qui a l'air vivante — est
            // exactement celui d'un historique cassé, et rien d'autre dans
            // l'application ne détrompe.
            if model.clipboardSettings.capturesCopies == false {
                NoticeRow(
                    text: "La capture des copies est désactivée : cette liste ne s'enrichit plus. "
                        + "Rien n'a été supprimé, et \(model.clipboardSettings.trigger.displayName) "
                        + "ouvre toujours l'historique déjà rangé.",
                    symbol: "pause.circle",
                    tint: Palette.attention
                ) {
                    Button("Réglages") { model.showsSettings = true }
                        .controlSize(.small)
                }
            }

            if let problem = store.problem {
                NoticeRow(text: problem, symbol: "externaldrive.badge.xmark", tint: Palette.attention)
            }
        }
        // `.clipped()` avant l'animation : un bandeau qui entre par le haut
        // passerait sinon par-dessus la barre de filtres pendant la transition.
        .clipped()
        // Une seule animation, qui couvre les deux bandeaux. Sans elle, les
        // `.transition` déclarées par `NoticeRow` ne se déclencheraient jamais —
        // un `.transition` sans animation sur un ancêtre est du code mort.
        .branAnimation(Motion.enter, value: noticeSignature)
    }

    /// Ce qui doit relancer l'animation des bandeaux. Même motif que les trois
    /// autres panes : une chaîne unique, parce que SwiftUI n'anime une insertion
    /// que si la valeur surveillée change **au même instant**.
    private var noticeSignature: String {
        var parts: [String] = []
        if model.clipboardSettings.capturesCopies == false { parts.append("capture éteinte") }
        if let problem = store.problem { parts.append(problem) }
        return parts.joined(separator: "|")
    }

    // MARK: - La liste et ses deux absences

    @ViewBuilder
    private func content(_ result: ClipboardBrowseResult) -> some View {
        if store.recent.isEmpty {
            // Premier lancement, ou historique entièrement vidé. La phrase nomme
            // le raccourci : un état vide qui ne dit pas comment revenir est un
            // cul-de-sac.
            ContentUnavailableView {
                Label("Presse-papiers vide", systemImage: "clipboard")
            } description: {
                Text(emptyHint)
            } actions: {
                if model.clipboardSettings.capturesCopies == false {
                    Button("Activer la capture des copies") { model.showsSettings = true }
                        .buttonStyle(.borderedProminent)
                }
            }
        } else if result.isEmpty {
            // **Une branche distincte de la précédente.** Elles se ressemblent à
            // l'écran et ne veulent pas dire la même chose : ici il y a un
            // historique, ce sont la recherche ou les filtres qui ne laissent
            // rien passer. Et entre les deux, ce n'est pas le même geste qui
            // répare — d'où le bouton, qui n'apparaît que quand une case est
            // cochée.
            if filter.narrowsBeyondQuery {
                ContentUnavailableView {
                    Label("Aucun résultat", systemImage: "line.3.horizontal.decrease.circle")
                } description: {
                    Text(narrowedHint)
                } actions: {
                    Button("Tout afficher", action: clearNarrowing)
                        .buttonStyle(.borderedProminent)
                }
            } else {
                ContentUnavailableView.search(text: query)
            }
        } else {
            list(result)
        }
    }

    private var emptyHint: String {
        model.clipboardSettings.capturesCopies
            ? "Copiez quelque chose : tout ce qui passe par le presse-papiers arrive ici, et "
                + "\(model.clipboardSettings.trigger.displayName) le rouvre par-dessus n'importe "
                + "quelle application."
            : "La capture des copies est désactivée. Une fois activée, tout ce que vous copierez "
                + "sera gardé ici — le texte indéfiniment, les images et les fichiers lourds le "
                + "temps réglé dans les réglages."
    }

    private var narrowedHint: String {
        let count = filter.narrowingCount
        let filters = count == 1 ? "Un filtre est posé" : "\(count) filtres sont posés"
        return query.isEmpty
            ? "\(filters) et ne laissent rien passer."
            : "\(filters), en plus de la recherche « \(query) »."
    }

    private func list(_ result: ClipboardBrowseResult) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Space.hair) {
                if sort.groupsByDay {
                    // Le regroupement par jour est **partagé** : `DayGrouping`
                    // sert les quatre sections. Il y en avait deux copies dans
                    // le dépôt, chacune avec sa propre idée de « Hier ».
                    ForEach(DayGrouping.groups(result.entries, by: \.lastCopiedAt)) { group in
                        Section {
                            rows(group.items)
                        } header: {
                            Text(group.title)
                                .font(Type.groupHead)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, Space.small)
                        }
                    }
                } else {
                    // Un palmarès coupé en tranches de journées n'est plus un
                    // palmarès : voir `ClipboardBrowseSort.groupsByDay`.
                    rows(result.entries)
                }
            }
            .padding(.horizontal, Space.gutter)
            .padding(.vertical, Space.stack)
        }
    }

    private func rows(_ entries: [ClipboardEntry]) -> some View {
        ForEach(entries) { entry in
            ClipboardLibraryRow(
                entry: entry,
                thumbnails: controller.thumbnails,
                expiry: expiry(of: entry),
                showsDay: sort.groupsByDay == false,
                canReveal: revealURL(for: entry) != nil,
                onTogglePin: { togglePin(entry) },
                onCopy: { copy(entry) },
                onReveal: { reveal(entry) },
                onDelete: { delete(entry) }
            )
            .id(entry.id)
        }
    }

    // MARK: - Ce que chaque ligne a besoin de savoir

    /// Quand les contenus lourds de cette entrée s'en iront, ou `nil` quand la
    /// question ne se pose pas.
    ///
    /// Trois façons qu'elle ne se pose pas, et elles ne se ressemblent pas :
    /// l'entrée n'a aucun contenu lourd (le texte, lui, n'est jamais purgé —
    /// c'est la raison d'être de la fonctionnalité) ; ils sont déjà partis, et
    /// c'est alors la date de purge que la ligne affiche ; ou l'entrée est
    /// épinglée, auquel cas la rétention ne l'atteint plus.
    ///
    /// La date vient de `ClipboardRetention.expiryDate(for:)` et de la politique
    /// **en vigueur** — `store.currentRetention` — et non d'un calcul refait
    /// ici : changer la rétention dans les réglages doit changer cette date à
    /// l'instant, pas au prochain lancement.
    private func expiry(of entry: ClipboardEntry) -> Date? {
        guard entry.isPinned == false else { return nil }
        guard entry.blobsArePurged == false else { return nil }
        guard let blobs = entry.blobs, blobs.isEmpty == false else { return nil }
        return store.currentRetention.expiryDate(for: entry)
    }

    /// Le fichier à montrer dans le Finder, ou `nil` s'il n'y en a pas.
    ///
    /// Le fichier copié d'abord, le contenu lourd ensuite. `ClipboardEntry`
    /// documente exprès que `fileURLs` porte des **chaînes** que le site d'appel
    /// convertit et peut voir échouer sans rien perdre : c'est ce site d'appel,
    /// et la même conversion que `ClipboardPastePlan` — un chemin nu n'est pas
    /// une URL, et `URL(string:)` sur `/Users/…` rend quelque chose d'inutile
    /// plutôt que `nil`.
    private func revealURL(for entry: ClipboardEntry) -> URL? {
        if let path = entry.fileURLs?.first, path.isEmpty == false {
            return path.hasPrefix("file:") ? URL(string: path) : URL(fileURLWithPath: path)
        }
        guard let reference = entry.blobs?.first else { return nil }
        return store.blobURL(for: reference, of: entry)
    }

    // MARK: - Les gestes

    private func togglePin(_ entry: ClipboardEntry) {
        Task {
            if entry.isPinned {
                await store.unpin(entry)
            } else {
                await store.pin(entry)
            }
        }
    }

    /// Remet l'entrée au presse-papiers, **sans coller**.
    ///
    /// **Sans coller, et c'est le seul geste que cet écran peut offrir.** Le
    /// panneau colle parce qu'il sait dans quelle application on retournait — il
    /// a retenu sa cible à l'instant du raccourci, avant d'apparaître. Ici la
    /// fenêtre principale est au premier plan depuis un moment ; « l'application
    /// d'avant » ne veut plus rien dire, et synthétiser un ⌘V vers une cible
    /// devinée est exactement l'erreur qu'un historique de presse-papiers ne
    /// peut pas rattraper, puisque le texte est déjà parti ailleurs.
    ///
    /// **Le compteur de copies ne monte pas.** `ClipboardStore.recopy` existe et
    /// n'est pas appelé : `copyCount` mesure ce que **l'utilisateur** a recopié
    /// depuis ses applications — c'est de cette mesure que sortent les « 43
    /// entrées sur 250 » qui justifient le signe dans la ligne et le tri par
    /// recopies. Le faire monter depuis nos propres boutons polluerait le signal
    /// avec nos propres gestes ; et comme `recopy` avance `lastCopiedAt`,
    /// l'entrée quitterait de surcroît son groupe de jour sous les yeux, en
    /// promettant une fraîcheur que sa date de purge — comptée depuis `copiedAt`
    /// et depuis lui seul — ne lui donne pas. Le panneau ne le fait pas non
    /// plus : les deux surfaces restent d'accord.
    private func copy(_ entry: ClipboardEntry) {
        guard let paster, let payload = payload(for: entry) else { return }
        paster.copyOnly(payload)
    }

    /// Traduit le plan de collage en charge utile de `Paster`.
    ///
    /// `BranCore` ne connaît pas AppKit et parle de types et d'octets, `Paster`
    /// parle de `SavedItem` : le pont est ici. Il est aussi dans
    /// `ClipboardPanelPresenter`, en privé — le rapport de ce commit propose de
    /// l'extraire, ce qu'un commit qui n'a pas le droit de toucher aux fichiers
    /// existants ne peut pas faire.
    private func payload(for entry: ClipboardEntry) -> Paster.Payload? {
        let items = ClipboardPastePlan.items(for: entry, variant: .faithful) { reference in
            guard let url = store.blobURL(for: reference, of: entry) else { return nil }
            return try? Data(contentsOf: url)
        }
        guard items.isEmpty == false else { return nil }

        return .representations(
            items.map { representations in
                SavedItem(
                    representations: representations.map { representation in
                        SavedRepresentation(type: representation.type, data: representation.data)
                    }
                )
            }
        )
    }

    private func reveal(_ entry: ClipboardEntry) {
        guard let url = revealURL(for: entry) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func delete(_ entry: ClipboardEntry) {
        Task { await store.delete(entry) }
    }
}

// MARK: - La ligne

/// Une entrée de l'historique, en hauteur fixe, avec tout ce qu'on peut en
/// faire.
///
/// ## Elle n'est pas une carte, et n'essaie pas de l'être
///
/// `branCard` n'est pas employé, et le refus est celui qu'une revue de
/// conception a déjà tranché pour le panneau — il vaut mot pour mot ici. Une
/// ligne de presse-papiers ne se déplie pas (pas de chevron : il n'y a pas de
/// second niveau, le contenu est le contenu) ; elle porte une vignette, que rien
/// d'autre dans l'application ne porte ; et sa **hauteur est fixe**, ce qu'une
/// carte ne peut pas donner puisqu'elle se dimensionne sur son contenu. La
/// hauteur fixe n'est pas un caprice : une liste dont les lignes ne font pas
/// toutes la même hauteur ne se parcourt pas en diagonale, et c'est ce qu'on
/// fait d'un historique.
///
/// ## Ce qu'elle montre de plus que la ligne du panneau
///
/// L'heure exacte plutôt qu'une durée relative, la taille **toujours** et non
/// seulement quand le texte déborde, la sorte du contenu, le nombre de copies en
/// toutes lettres, l'échéance des contenus lourds, l'épingle, et l'état du
/// contenu quand il n'est plus entier. C'est très exactement ce dont on a besoin
/// pour *décider* — supprimer, épingler, changer sa rétention — et dont on n'a
/// aucun besoin pour *coller*.
///
/// Le tout tient sur une ligne de méta qui se rogne par la fin : l'ordre des
/// morceaux est donc leur ordre d'importance, et ce qui se perd d'abord est ce
/// dont on se passe le mieux. Ce que l'écran rogne, `accessibilityLabel` le dit
/// en entier.
private struct ClipboardLibraryRow: View {

    let entry: ClipboardEntry
    let thumbnails: ThumbnailCache

    /// Quand les contenus lourds s'en iront, ou `nil` si la question ne se pose
    /// pas. Calculé par la pane, qui connaît la politique en vigueur.
    let expiry: Date?

    /// Faut-il écrire le jour avec l'heure ? Vrai dans les tris qui ne se
    /// regroupent pas par jour, où aucun en-tête ne porte plus la date : une
    /// heure toute seule dans un palmarès ne dit rien du tout.
    let showsDay: Bool

    let canReveal: Bool

    let onTogglePin: () -> Void
    let onCopy: () -> Void
    let onReveal: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false
    @State private var thumbnail: Image?
    @State private var justCopied = false
    /// Voir `DictationCard` : un booléen seul laisse la première copie éteindre
    /// le retour de la seconde.
    @State private var copyTicket = 0

    private var row: ClipboardFilter.RowText { ClipboardFilter.rowText(for: entry) }

    var body: some View {
        HStack(spacing: Space.small) {
            leading

            VStack(alignment: .leading, spacing: Space.line) {
                title
                meta
            }

            Spacer(minLength: Space.small)

            marks
            actions
        }
        .padding(.horizontal, Space.inset)
        // La hauteur fixe est la décision structurante de la ligne, et son
        // chiffre se défend dans `Design.swift`. Elle vaut aussi pour les lignes
        // sans texte : une image et un paragraphe doivent occuper la même place.
        .frame(height: Size.clipboardRow)
        .background(
            Palette.row(hover: isHovering, selected: false),
            in: .rect(cornerRadius: Radius.field)
        )
        .contentShape(.rect)
        .onHover { isHovering = $0 }
        .branAnimation(Motion.hover, value: isHovering)
        .contextMenu { menu }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAction(named: entry.isPinned ? "Désépingler" : "Épingler") { onTogglePin() }
        .accessibilityAction(named: "Remettre au presse-papiers") { copyNow() }
        .accessibilityAction(named: "Afficher dans le Finder") { onReveal() }
        .accessibilityAction(named: "Supprimer") { onDelete() }
        .task(id: entry.id) { await loadThumbnail() }
        .task(id: copyTicket) {
            guard copyTicket > 0 else { return }
            try? await Task.sleep(for: .seconds(1.4))
            guard Task.isCancelled == false else { return }
            justCopied = false
        }
    }

    // MARK: La vignette

    @ViewBuilder
    private var leading: some View {
        // **La purge est revérifiée ici, pas seulement au chargement.** La tâche
        // de vignette est indexée par l'identifiant de l'entrée ; celui-ci ne
        // change pas quand la rétention marque ses contenus comme partis, donc
        // SwiftUI garde l'état local de la ligne et l'image resterait affichée
        // au-dessus d'un contenu qui n'existe plus. Ce n'est pas une perte, mais
        // c'est une promesse visuelle fausse — et cette ligne montre par
        // ailleurs, en toutes lettres, la date à laquelle le contenu s'en va.
        if let thumbnail, ThumbnailPlan.hasThumbnail(entry) {
            thumbnail
                .resizable()
                // Rempli puis rogné, jamais déformé : un carré au rapport de
                // l'image désalignerait les colonnes de texte d'une ligne à
                // l'autre, ce qui rend une liste illisible en diagonale.
                .scaledToFill()
                .frame(width: Size.clipboardThumbnail, height: Size.clipboardThumbnail)
                .clipShape(.rect(cornerRadius: Radius.control))
                .accessibilityHidden(true)
        } else {
            Image(systemName: ClipboardPanelVocabulary.symbolName(entry))
                .font(Type.cardBody)
                .foregroundStyle(.secondary)
                .frame(width: Size.clipboardThumbnail, height: Size.clipboardThumbnail)
                .accessibilityHidden(true)
        }
    }

    /// Demande la vignette au cache, et la fabrique si elle manque.
    ///
    /// **Dans un `.task` de la ligne et non dans une fermeture du modèle**,
    /// contrairement au panneau : là-bas la vue est reconstruite en entier à
    /// chaque frappe et le cache mémoire est le seul chemin assez rapide ; ici
    /// la liste est paresseuse, chaque `.task` naît avec sa ligne visible et
    /// meurt avec elle, et l'annulation à la disparition est exactement ce qu'on
    /// veut d'un décodage d'image qu'on a fait défiler.
    ///
    /// **Jamais l'image entière** : une capture Retina pèse plusieurs dizaines
    /// de mégaoctets décodée, et la liste en montre vingt à la fois.
    private func loadThumbnail() async {
        guard ThumbnailPlan.hasThumbnail(entry) else { return }
        if let cached = thumbnails.cached(for: entry) {
            thumbnail = Image(decorative: cached, scale: 1)
            return
        }
        guard let made = await thumbnails.thumbnail(for: entry) else { return }
        guard Task.isCancelled == false else { return }
        thumbnail = Image(decorative: made, scale: 1)
    }

    // MARK: Le texte

    private var title: some View {
        // `row.text` est déjà borné à `ClipboardEntry.previewLimit` par
        // `ClipboardFilter.rowText` : un `Text` qui porterait les 2 Mio d'un
        // aperçu géant les mettrait en page à chaque image, `lineLimit` ou pas.
        // L'ellipse vient du modèle, jamais du stockage.
        Text(displayedTitle)
            .font(Type.cardBody)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var displayedTitle: String {
        guard row.text.isEmpty else { return row.isClipped ? row.text + "…" : row.text }
        // Rien à écrire : une image, ou un fichier sans nom lisible. On nomme le
        // type plutôt que de laisser une ligne muette.
        return ClipboardPanelVocabulary.kindName(entry)
    }

    /// Les faits, dans leur ordre d'importance — c'est aussi l'ordre inverse de
    /// ce qui se perd quand la fenêtre rétrécit.
    private var meta: some View {
        HStack(spacing: Space.tight) {
            // Le nom **stocké** fait foi : il a été lu au moment de la copie,
            // quand l'application existait encore. Silence quand on ne sait
            // rien, plutôt qu'« Inconnu », qui occupe la même place sans rien
            // dire.
            if let name = entry.source?.name {
                Text(name)
                Text("·")
            }

            // L'heure exacte, là où le panneau écrit « il y a 3 min ». C'est la
            // différence entre reconnaître une copie et la situer.
            Text(entry.lastCopiedAt, format: dateFormat)

            Text("·")
            Text(entry.sizeDescription)

            Text("·")
            Text(ClipboardPanelVocabulary.kindName(entry))

            if entry.wasRecopied {
                Text("·")
                Text("\(entry.copyCount) copies")
            }

            if let expiry {
                Text("·")
                // La date que le réglage de rétention produit, dite avant
                // qu'elle arrive plutôt que constatée après. C'est elle qui
                // relie ce qu'on voit au réglage qui la cause — et donc la seule
                // façon de comprendre qu'on peut le changer.
                Text("contenu jusqu'au \(expiry.formatted(date: .abbreviated, time: .omitted))")
            } else if let purged = entry.blobsPurgedAt {
                Text("·")
                Text("contenu purgé le \(purged.formatted(date: .abbreviated, time: .omitted))")
            }
        }
        .font(Type.meta)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private var dateFormat: Date.FormatStyle {
        showsDay
            ? .dateTime.day().month(.abbreviated).hour().minute()
            : .dateTime.hour().minute()
    }

    // MARK: Les marques

    /// Ce qui est vrai de l'entrée, qu'on survole ou non.
    @ViewBuilder
    private var marks: some View {
        HStack(spacing: Space.tight) {
            // **L'épingle se voit sans la souris, et c'est tout son intérêt.**
            // L'accent porte l'état sur un symbole et non en fond : un fond
            // coloré imposerait sa couleur au texte posé dessus, ce que
            // `Palette` interdit et démontre.
            if entry.isPinned {
                Image(systemName: "pin.fill")
                    .font(Type.meta)
                    .foregroundStyle(.tint)
                    .help("Épinglée : gardée quelle que soit la rétention.")
            }

            // La ligne reste, le texte reste, seul le contenu lourd est parti.
            // `ClipboardEntry` conserve exprès ses références mortes pour qu'on
            // puisse dire *quoi* a disparu et *quand*.
            if entry.isComplete == false {
                Image(systemName: entry.isRefused ? "exclamationmark.triangle" : "clock.badge.xmark")
                    .font(Type.meta)
                    .foregroundStyle(.secondary)
                    .help(incompleteReason)
            }
        }
    }

    private var incompleteReason: String {
        if entry.isRefused {
            return "Contenu trop lourd pour être conservé (\(entry.sizeDescription)) : "
                + "l'entrée reste, son contenu n'a jamais été écrit."
        }
        guard let purged = entry.blobsPurgedAt else {
            return "Le contenu attaché à cette entrée n'est plus disponible."
        }
        return "Contenu purgé le \(purged.formatted(date: .long, time: .omitted)) par la rétention. "
            + "Le texte, lui, n'est jamais purgé."
    }

    // MARK: Les gestes

    /// Voir `DictationCard.actions` : toujours dans l'arbre, seulement
    /// transparentes hors survol, sinon rien de tout ça n'existe au clavier ni
    /// pour VoiceOver.
    ///
    /// **L'épingle échappe à l'estompage quand elle est posée.** Désépingler est
    /// le seul de ces gestes dont l'inverse ne se devine pas : une ligne
    /// épinglée doit porter le bouton qui la libère, sans qu'il faille survoler
    /// pour découvrir qu'il existe.
    private var actions: some View {
        HStack(spacing: Space.hair) {
            CardAction(
                symbol: entry.isPinned ? "pin.slash" : "pin",
                help: entry.isPinned
                    ? "Désépingler : l'entrée redevient soumise à la rétention"
                    : "Épingler : garder cette entrée et son contenu quelle que soit la rétention",
                tint: entry.isPinned ? .accentColor : nil,
                action: onTogglePin
            )
            .opacity(isHovering || entry.isPinned ? 1 : 0)

            CardAction(
                symbol: justCopied ? "checkmark" : "doc.on.doc",
                help: "Remettre au presse-papiers",
                tint: justCopied ? Palette.done : nil,
                action: copyNow
            )
            .disabled(entry.canPaste == false)

            Group {
                CardAction(symbol: "folder", help: revealHelp, action: onReveal)
                    .disabled(canReveal == false)

                CardAction(symbol: "trash", help: "Supprimer", tint: Palette.broken, action: onDelete)
            }
            .opacity(isHovering ? 1 : 0)
        }
        .branAnimation(Motion.hover, value: isHovering)
    }

    private var revealHelp: String {
        canReveal
            ? "Afficher le fichier dans le Finder"
            : "Il n'y a plus de fichier à montrer pour cette entrée"
    }

    /// Les mêmes gestes, nommés, au clic droit — le seul endroit où une action
    /// de ligne porte un nom plutôt qu'un pictogramme, et le seul qui reste
    /// atteignable sans survoler.
    @ViewBuilder
    private var menu: some View {
        Button(entry.isPinned ? "Désépingler" : "Épingler", action: onTogglePin)
        Button("Remettre au presse-papiers", action: copyNow)
            .disabled(entry.canPaste == false)
        Button("Afficher dans le Finder", action: onReveal)
            .disabled(canReveal == false)
        Divider()
        Button("Supprimer", role: .destructive, action: onDelete)
    }

    private func copyNow() {
        onCopy()
        justCopied = true
        copyTicket += 1
    }

    // MARK: Ce que VoiceOver lit

    /// Le libellé de la ligne, dans l'ordre où on le lirait à voix haute.
    ///
    /// Le contenu d'abord, parce que c'est ce qu'on cherche ; la provenance et
    /// la date ensuite, parce que ce sont les deux critères dont on se souvient
    /// trois semaines plus tard ; les états à la fin, parce qu'ils ne se lisent
    /// qu'une fois qu'on a reconnu l'entrée.
    ///
    /// **Il dit tout ce que la ligne rogne.** La méta se coupe par la fin quand
    /// la fenêtre est étroite ; ce libellé, lui, n'a pas de largeur, et rien de
    /// ce qui décide d'une suppression ou d'une épingle ne doit dépendre de la
    /// place disponible.
    private var accessibilityLabel: String {
        var parts: [String] = []

        switch entry.kind {
        case .text, .richText:
            parts.append(
                row.text.isEmpty ? ClipboardPanelVocabulary.kindName(entry) : "« \(row.text) »"
            )
        case .image, .file:
            // Le type d'abord — « Image », « 3 fichiers » — puis le nom quand il
            // y en a un.
            parts.append(ClipboardPanelVocabulary.kindName(entry))
            if row.text.isEmpty == false { parts.append("« \(row.text) »") }
        }

        if let name = entry.source?.name { parts.append(name) }
        parts.append(entry.lastCopiedAt.formatted(date: .abbreviated, time: .shortened))
        parts.append(entry.sizeDescription)

        if entry.wasRecopied { parts.append("copié \(entry.copyCount) fois") }
        if entry.isPinned { parts.append("épinglée") }
        if entry.isComplete == false { parts.append(incompleteReason) }
        if let expiry {
            parts.append(
                "contenu conservé jusqu'au \(expiry.formatted(date: .abbreviated, time: .omitted))"
            )
        }

        return parts.joined(separator: ", ")
    }
}

// MARK: - L'état, dans l'en-tête

/// Dit en un coup d'œil si l'historique se remplit, et par quel raccourci on le
/// rouvre.
///
/// **Volontairement identique à `SnapshotStatusChip` et `DictationStatusChip`**,
/// jusqu'à la capsule : l'en-tête aligne le grand titre sur la ligne de base du
/// contenu de droite, et un contrôle d'une autre hauteur ferait tomber le titre
/// « Presse-papiers » à une autre hauteur que « Réunions » et « Dictées ».
///
/// Le point est un symbole et non un `Circle` de six points de côté : une vue ne
/// porte pas de nombre, et `Design.swift` n'a pas d'échelle de diamètres. La
/// taille suit alors la préférence de taille de texte du système, ce qu'un
/// `frame` fixe ne fait pas.
struct ClipboardStatusChip: View {

    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: Space.tight) {
            Image(systemName: "circle.fill")
                .font(Type.metaFaint)
                .foregroundStyle(color)
                .accessibilityHidden(true)
            Text(label)
                .font(Type.meta)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Space.small)
        .padding(.vertical, Space.tight)
        .background(Palette.well, in: .capsule)
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        model.clipboardSettings.capturesCopies ? Palette.done : Palette.asleep
    }

    private var label: String {
        model.clipboardSettings.capturesCopies
            ? "\(model.clipboardSettings.trigger.displayName) · en veille"
            : "capture désactivée"
    }
}
