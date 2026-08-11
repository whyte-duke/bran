import AppKit
import BranCore
import BranSpeech
import SwiftUI
import os

private let panelLog = Logger(subsystem: "com.opahventures.bran", category: "clipboard")

/// Le panneau d'historique : la fenêtre, la cible du collage, et la fermeture.
///
/// **Le plus gros risque de toute la fonctionnalité est ici, et il tient en une
/// phrase : un ↵ qui tombe dans la mauvaise fenêtre annule la valeur entière du
/// presse-papiers.** Le panneau prend le focus clavier, doit le rendre, puis
/// coller dans l'application qui était devant. Aucun de ces chemins n'avait
/// jamais été parcouru avec un panneau qui devient fenêtre clé : la dictée ne
/// l'a jamais fait, elle n'a jamais eu de fenêtre à donner.
///
/// ## Les cinq points de la cible, dans l'ordre
///
/// 1. **`rememberTarget()` à l'instant du raccourci**, avant l'affichage du
///    panneau — jamais au ↵, où l'application de devant peut déjà être bran.
/// 2. **`restoresClipboard = false`** sur ce chemin : l'entrée choisie doit
///    **rester** sur le presse-papiers. Un gestionnaire de presse-papiers qui
///    rend le presse-papiers d'avant se contredit lui-même.
/// 3. **Fermer le panneau et rendre le statut de fenêtre clé AVANT** de
///    synthétiser le ⌘V, en réutilisant le délai de 0,08 s que `Paster` a déjà
///    mesuré et argumenté plutôt que d'en inventer un second.
/// 4. **Exploiter la valeur de retour.** `paste` rend `false` quand la cible a
///    disparu ou que la saisie sécurisée est active. Dans ce cas le panneau **ne
///    se ferme pas en silence** : l'entrée reste sur le presse-papiers et on le
///    dit. La règle est déjà écrite dans `Paster` — « perdre le texte serait la
///    pire issue possible ».
/// 5. Le seul essai qui vaille : une entrée collée alors que le panneau avait le
///    focus atterrit dans l'application qui était devant **au moment du
///    raccourci**.
///
/// ## La fenêtre est construite une fois
///
/// `orderFront` / `orderOut`, jamais une reconstruction. C'est ce qui rend
/// tenable le budget de 50 ms à l'ouverture : reconstruire une hiérarchie
/// SwiftUI et un `NSHostingView` à chaque ⌘⇧C le dépenserait entièrement avant
/// d'avoir dessiné une seule ligne.
@MainActor
final class ClipboardPanelPresenter {

    private let store: ClipboardStore
    private let settings: ClipboardSettings
    private let thumbnails: ThumbnailCache

    /// Le colleur du panneau, **distinct** de ceux de la dictée et de la
    /// capture, et qui ne rend jamais le presse-papiers.
    ///
    /// Le drapeau est posé une fois ici, à la construction, et non juste avant
    /// chaque collage : c'est ce qui fait que `rememberTarget()` sait dès l'appui
    /// qu'il n'a aucune lecture détachée à lancer, et n'ira pas faire fabriquer à
    /// l'application source des représentations promises dont personne ne
    /// voudra. Même parti pris et même raison que `SnapshotController`.
    private let paster: Paster = {
        let paster = Paster()
        paster.restoresClipboard = false
        return paster
    }()

    private var panel: NSPanel?
    private var model: ClipboardPanelModel?

    /// Les deux observateurs de fermeture, tenus par un porteur qui sait se
    /// nettoyer tout seul.
    ///
    /// **Un `deinit` sur ce présentateur ne pourrait pas les retirer** : il est
    /// `@MainActor`, et un `deinit` n'a pas le droit de toucher à l'état isolé.
    /// Or un moniteur global oublié se déclenche pour **tous** les clics de la
    /// session, avec une fermeture qui ne mène plus nulle part. Le porteur, lui,
    /// n'est isolé sur rien : il meurt avec le présentateur et retire ses jetons
    /// dans son propre `deinit`.
    private var observers: DismissalObservers?

    init(store: ClipboardStore, settings: ClipboardSettings, thumbnails: ThumbnailCache) {
        self.store = store
        self.settings = settings
        self.thumbnails = thumbnails
    }

    var isOpen: Bool { panel?.isVisible == true }

    // MARK: - Ouvrir et fermer

    /// Bascule le panneau. C'est ce que ⌘⇧C appelle.
    func toggle() {
        // Une ligne de journal de chaque côté de la bascule. Un panneau qui ne
        // s'ouvre pas est le défaut le plus difficile à diagnostiquer de toute
        // la fonction : il n'échoue pas, il ne se passe simplement rien, et il y
        // a six endroits entre la frappe et la fenêtre où le signal peut se
        // perdre. Sans ces deux lignes, la seule méthode est de regarder
        // l'écran.
        panelLog.notice("Panneau : bascule, ouvert = \(self.isOpen, privacy: .public)")
        if isOpen { close() } else { open() }
    }

    /// **Point 1 : la cible est retenue ici, avant que quoi que ce soit
    /// s'affiche.** À partir de la ligne suivante, l'application de devant peut
    /// déjà être bran — `NSApp.isActive` passe à vrai dès que le panneau devient
    /// clé, c'est mesuré — et la retenir plus tard donnerait bran comme cible du
    /// collage, c'est-à-dire nulle part.
    ///
    /// `readingClipboard: false` : on ne lit rien, on ne rendra rien. Voir le
    /// point 2.
    private func open() {
        paster.rememberTarget(readingClipboard: false)

        let panel = existingPanel() ?? makePanel()
        // Repositionné à chaque ouverture, jamais seulement à la construction :
        // le panneau doit s'ouvrir sur l'écran où l'on travaille, et on change
        // d'écran plus souvent qu'on ne relance bran.
        panel.setFrame(Self.frame(), display: false)
        self.panel = panel
        // Un échec est un événement, pas un état : il ne survit pas à
        // l'ouverture suivante.
        model?.lastFailure = nil
        model?.announceOpening()
        panel.makeKeyAndOrderFront(nil)
        observeDismissal(panel)
        let state = "visible=\(panel.isVisible) clé=\(panel.isKeyWindow) "
            + NSStringFromRect(panel.frame)
        panelLog.notice("Panneau ouvert : \(state, privacy: .public)")
    }

    /// Ferme, et défait tout ce que l'ouverture avait posé.
    ///
    /// **`orderOut` n'est que le dernier geste de la séquence**, et c'est
    /// exactement pourquoi la fermeture appartient au contrôleur et non à la
    /// fenêtre : une fenêtre qui se retirerait elle-même laisserait son
    /// propriétaire persuadé d'être encore ouvert, la frappe suivante
    /// basculerait contre un état périmé, et les observateurs resteraient posés
    /// pour la vie du processus.
    func close() {
        if isOpen { panelLog.notice("Panneau fermé") }
        stopObservingDismissal()
        model?.query = ""
        panel?.orderOut(nil)
    }

    private func existingPanel() -> NSPanel? {
        guard let panel, model != nil else { return nil }
        return panel
    }

    private func makePanel() -> NSPanel {
        let model = ClipboardPanelModel(
            store: store,
            shortcutName: settings.trigger.displayName,
            thumbnail: { [weak self] entry in self?.thumbnail(for: entry) },
            onPaste: { [weak self] in self?.paste($0, variant: .faithful) },
            onPastePlain: { [weak self] in self?.paste($0, variant: .plainText) },
            onCopyOnly: { [weak self] in self?.copyOnly($0) },
            onDelete: { [weak self] in self?.delete($0) },
            onDismiss: { [weak self] in self?.close() }
        )
        self.model = model

        // **La taille est imposée à la vue, pas déduite d'elle.** Mesuré : sans
        // cette contrainte, `NSHostingView` installe les contraintes de sa taille
        // intrinsèque et la fenêtre s'y plie — le panneau s'ouvrait à
        // `{{634, -1706}, {460, 2620}}`, c'est-à-dire 2 620 points de haut, la
        // hauteur de toutes ses lignes empilées, très majoritairement sous le
        // bord de l'écran. Il était bien visible et bien fenêtre clé ; il était
        // simplement ailleurs.
        //
        // Une liste bornée par sa fenêtre défile ; une liste qui dicte sa
        // fenêtre ne défile jamais et finit hors de l'écran dès la dixième
        // entrée. Les deux jetons viennent de `Design.swift` — une vue ne porte
        // aucun nombre — et ce sont les mêmes que ceux du cadre.
        let content = ClipboardPanelView(model: model)
            .frame(width: Size.clipboardPanelWidth, height: Size.clipboardPanelHeight)
        let hosting = NSHostingView(rootView: content)
        let frame = Self.frame()
        hosting.frame = NSRect(origin: .zero, size: frame.size)
        return OverlayPanel.makeFocusable(
            frame: frame, content: hosting, initialResponder: hosting
        )
    }

    // MARK: - Les vignettes

    /// Les entrées dont la vignette est en cours de fabrication, pour ne pas la
    /// demander une fois par passe de dessin.
    private var pendingThumbnails: Set<ClipboardEntry.ID> = []

    /// La vignette d'une entrée **tout de suite**, et sa fabrication si elle
    /// manque.
    ///
    /// **Sans la seconde moitié, les images n'apparaissaient jamais.** Le modèle
    /// ne demandait que le cache mémoire, qui est vide à froid : chaque image
    /// affichait donc son symbole de repli indéfiniment, et le cache disque ne se
    /// remplissait pas non plus puisque rien ne le sollicitait. Une revue l'a
    /// trouvé — c'est le genre de défaut qui ne casse aucun test parce qu'il ne
    /// casse rien, il ne montre simplement jamais ce qu'il promet.
    ///
    /// Le décodage est lancé **et oublié** : il ne fait attendre personne, la
    /// ligne se dessine avec son symbole, et l'incrément de
    /// `thumbnailGeneration` fait redessiner quand l'image est prête. C'est ce
    /// que le commentaire du modèle appelle « une vignette qui arrive plus
    /// tard » — il fallait encore que quelqu'un la fasse arriver.
    private func thumbnail(for entry: ClipboardEntry) -> Image? {
        if let image = thumbnails.cached(for: entry) {
            return Image(decorative: image, scale: 1)
        }
        guard ThumbnailPlan.hasThumbnail(entry), pendingThumbnails.contains(entry.id) == false
        else { return nil }

        pendingThumbnails.insert(entry.id)
        Task { [weak self] in
            _ = await self?.thumbnails.thumbnail(for: entry)
            guard let self else { return }
            pendingThumbnails.remove(entry.id)
            // Un compteur et non l'image : le modèle ne porte aucune image, il
            // porte de quoi savoir qu'il faut en redemander une.
            model?.thumbnailGeneration &+= 1
        }
        return nil
    }

    /// Où le panneau se pose : centré horizontalement, dans le tiers supérieur
    /// de l'écran qui porte la souris.
    ///
    /// Le tiers supérieur et non le centre exact : une liste qui grandit vers le
    /// bas depuis un point fixe se lit mieux qu'une liste qui s'étale de part et
    /// d'autre, et le regard revient toujours à la première ligne — celle qu'on
    /// vient de copier, celle qu'on veut neuf fois sur dix.
    private static func frame() -> NSRect {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: Size.clipboardPanelWidth, height: Size.clipboardPanelHeight)
        return NSRect(
            x: visible.midX - size.width / 2,
            y: visible.maxY - size.height - visible.height / 6,
            width: size.width,
            height: size.height
        )
    }

    // MARK: - La fermeture au clic dehors

    /// **La moitié du travail est faite par le système, gratuitement.** Le
    /// panneau devenant clé rend bran actif au sens d'AppKit — mesuré —, donc
    /// partir ailleurs déclenche un vrai `didResignActive`. Le moniteur global,
    /// lui, ne sert qu'à ce que la notification ne couvre pas : le clic qui reste
    /// **dans** l'application déjà au premier plan, laquelle ne s'« active » pas
    /// puisqu'elle y est.
    ///
    /// Les deux jetons sont retirés à la fermeture. Un moniteur global se
    /// déclenche pour *tous* les clics de la session, y compris ceux qui
    /// atterrissent sur les autres surfaces de bran : le laisser posé ferait
    /// payer une fermeture à chaque clic de la journée.
    private func observeDismissal(_ panel: NSPanel) {
        stopObservingDismissal()

        // **La perte du statut de fenêtre clé, et surtout pas
        // `didResignActive`.** Mesuré, et le premier essai est mort dessus : le
        // panneau s'ouvrait correctement — visible, clé, bien placé — et se
        // refermait 440 ms plus tard. La cause est la nature même d'un panneau
        // *non activant* : ouvrir ne garde pas bran au premier plan, le système
        // rend l'avant-plan à l'application d'où l'on vient, et bran perd donc
        // `active` presque aussitôt qu'il l'a pris. Écouter `didResignActive`
        // revenait à se congédier soi-même.
        //
        // Perdre la **clé**, en revanche, veut dire exactement ce qu'on cherche :
        // les frappes ne nous arrivent plus, quelqu'un d'autre les reçoit, il n'y
        // a plus de raison de rester à l'écran. C'est aussi le comportement que
        // la sonde avait constaté — « quand une autre application s'active
        // vraiment, le panneau rend la clé tout seul ».
        let resignation = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }

        let outsideClick = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }

        observers = DismissalObservers(resignation: resignation, outsideClick: outsideClick)
    }

    private func stopObservingDismissal() {
        observers = nil
    }

    // MARK: - Coller

    /// **Points 3 et 4.** Le panneau se ferme d'abord — il rend le statut de
    /// fenêtre clé — puis `Paster` réactive la cible et attend les 0,08 s qu'il a
    /// déjà mesurées avant de synthétiser le ⌘V. Aucun second délai n'est
    /// inventé ici : celui de `Paster` existe précisément pour laisser le
    /// changement d'application aboutir, et en poser un deuxième par-dessus
    /// rendrait le total impossible à raisonner.
    private func paste(_ entry: ClipboardEntry, variant: ClipboardPastePlan.Variant) {
        guard let payload = payload(for: entry, variant: variant) else {
            // L'interface a déjà désactivé ↵ dans ce cas — `canPaste` le dit
            // avec sa raison. On n'y arrive donc que si le disque a changé sous
            // nos pieds entre l'affichage et la touche.
            report("Ce contenu n'est plus disponible.")
            panelLog.notice("Collage impossible : plus rien à reposer")
            return
        }

        close()

        let willTry = paster.paste(payload) { [weak self] landing in
            guard let self, let notice = landing.notice else { return }
            // `Landing` porte déjà les phrases de la dictée, mesurées et
            // relues ; les réécrire ici en donnerait deux versions. C'est
            // **ici seulement** qu'on a le droit de promettre le presse-papiers :
            // `.clipboardOnly` veut dire que l'écriture a abouti, et
            // `Landing.notice` est formulé en conséquence.
            report(notice)
            panelLog.error("Le collage n'a pas abouti : \(notice, privacy: .public)")
        }

        // **Point 4, corrigé par une revue.** `false` dit que le ⌘V ne sera pas
        // envoyé — cible disparue, ou saisie sécurisée. Il ne dit **pas** que le
        // contenu est arrivé au presse-papiers : `Paster` documente que seule la
        // réponse `.clipboardOnly` le garantit, et l'écriture peut encore être en
        // vol derrière une lecture bloquée. Annoncer « faites ⌘V » ici ferait
        // coller **l'ancien** presse-papiers à quelqu'un qui a suivi
        // l'instruction — la seule issue pire que ne rien dire.
        //
        // On dit donc ce qu'on sait, et rien de plus ; la promesse du
        // presse-papiers arrive par le rappel ci-dessus, quand elle est vraie.
        if willTry == false {
            report(
                "Le collage automatique n'a pas pu avoir lieu — la fenêtre visée a disparu, "
                + "ou une saisie sécurisée est active."
            )
            panelLog.notice("Cible perdue ou saisie sécurisée : pas de ⌘V")
        }
    }

    /// Dit ce qui n'a pas marché, **dans le panneau**, en le rouvrant si besoin.
    ///
    /// **Rouvrir, et non renoncer.** Le panneau est fermé avant le ⌘V — c'est le
    /// troisième point, il doit rendre le statut de fenêtre clé — donc au moment
    /// où l'on apprend l'échec il n'y a plus de surface pour le dire. Poser
    /// l'avis sans rouvrir reviendrait à écrire dans une fenêtre invisible,
    /// c'est-à-dire à se taire ; et se taire est exactement ce que le quatrième
    /// point interdit. La réouverture se fait dans le même tour de boucle que la
    /// fermeture quand l'échec est synchrone : la fenêtre n'a jamais disparu à
    /// l'œil.
    ///
    /// Le contenu, lui, **est** au presse-papiers dans presque tous ces cas : ce
    /// qu'on annonce n'est pas une perte, c'est un ⌘V qui reste à faire.
    private func report(_ message: String) {
        if isOpen == false { open() }
        model?.lastFailure = message
    }

    /// Mettre au presse-papiers sans coller. Le panneau se ferme quand même :
    /// le geste est terminé, et une fenêtre qui resterait ouverte après une
    /// action réussie ferait douter qu'elle ait eu lieu.
    private func copyOnly(_ entry: ClipboardEntry) {
        guard let payload = payload(for: entry, variant: .faithful) else {
            report("Ce contenu n'est plus disponible.")
            return
        }
        close()
        paster.copyOnly(payload) { [weak self] written in
            guard written == false else { return }
            self?.report(Paster.stalledNotice)
        }
    }

    private func delete(_ entry: ClipboardEntry) {
        Task { await store.delete(entry) }
    }

    /// Traduit le plan de collage en charge utile de `Paster`.
    ///
    /// Les deux formes disent la même chose sous deux vocabulaires : `BranCore`
    /// ne connaît pas AppKit et parle de types et d'octets, `Paster` parle de
    /// `SavedItem`. Le pont est ici, une fois.
    ///
    /// La lecture des contenus lourds est **synchrone et sur le fil principal**,
    /// et c'est un choix : elle a lieu au ↵, sur un ou deux fichiers déjà
    /// dimensionnés par `maximumBlobBytes`, et la repousser sur une tâche
    /// ajouterait un aller-retour entre le moment où l'utilisateur appuie et
    /// celui où la cible est réactivée — précisément l'intervalle que les cinq
    /// points existent pour garder le plus court possible.
    private func payload(
        for entry: ClipboardEntry, variant: ClipboardPastePlan.Variant
    ) -> Paster.Payload? {
        let items = ClipboardPastePlan.items(for: entry, variant: variant) { [store] reference in
            guard let url = store.blobURL(for: reference, of: entry) else { return nil }
            return try? Data(contentsOf: url)
        }
        guard items.isEmpty == false else { return nil }

        return .representations(
            items.map { representations in
                SavedItem(
                    representations: representations.map {
                        SavedRepresentation(type: $0.type, data: $0.data)
                    }
                )
            }
        )
    }
}


/// Les deux jetons de fermeture, et leur retrait garanti.
///
/// Un type minuscule dont le seul rôle est d'avoir un `deinit` que le
/// présentateur ne peut pas avoir : il est `@MainActor`, et un `deinit` n'a pas
/// le droit d'y toucher à l'état isolé. Ici il n'y a pas d'isolation, donc pas
/// d'obstacle — et le retrait devient une propriété de la durée de vie plutôt
/// qu'un appel qu'on peut oublier.
private final class DismissalObservers {

    private let resignation: any NSObjectProtocol
    private let outsideClick: Any

    init(resignation: any NSObjectProtocol, outsideClick: Any) {
        self.resignation = resignation
        self.outsideClick = outsideClick
    }

    deinit {
        NotificationCenter.default.removeObserver(resignation)
        NSEvent.removeMonitor(outsideClick)
    }
}
