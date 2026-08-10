import AppKit
import CryptoKit
import Foundation
import ImageIO
import Synchronization
import UniformTypeIdentifiers

/// Sonde du presse-papiers. **Ne décide rien, n'écrit rien : elle mesure.**
///
/// Elle répond aux trois questions sans lesquelles un historique de
/// presse-papiers ne peut pas être dessiné, et elle y répond sur le vrai
/// presse-papiers de son propriétaire, pendant qu'il travaille :
///
/// 1. **Quand le contenu est-il lisible ?** `clearContents()` incrémente le
///    compteur de 1, et les `setData` qui suivent l'incrémentent de 0. Une
///    application qui vide puis publie cinq représentations expose donc un
///    presse-papiers **vide** au compte N, et le remplit dans les
///    millisecondes suivantes. Un historique qui lit dès que le compteur bouge
///    enregistrerait du vide. Le mode `watch` re-échantillonne à +40, +120,
///    +300 et +1000 ms : c'est lui qui dit si le fait est réel, chez quelles
///    applications, et combien de temps il faut attendre.
/// 2. **Que coûte une lecture ?** Un type promis n'existe pas encore quand on
///    le demande : `data(forType:)` déclenche un XPC synchrone vers
///    l'application source, qui doit *fabriquer* la représentation. C'est le
///    mode `cost`, le seul qui les lise **tous**.
/// 3. **Que nous laisse faire l'autorisation de macOS 15.4 ?** C'est le mode
///    `access`, et il porte deux avertissements plutôt qu'un. Le premier : un
///    exécutable en ligne de commande hérite de l'autorisation du Terminal et
///    ne dit donc *rien* de ce que vivra `bran.app` signé. Le second : la
///    lecture par laquelle il observe la bascule est un `string(forType:)`,
///    c'est-à-dire du contenu, pas de la métadonnée — sur une représentation
///    promise, elle peut se figer exactement comme `data(forType:)`. On ne
///    l'interdit pas derrière `--force` : mesurer `accessBehavior` est toute la
///    raison d'être du mode, et l'exiger reviendrait à ne plus jamais le lancer.
///    On l'annonce, on la chronomètre, on affiche un compte à rebours pendant le
///    gel, et on dit en clair si elle a bloqué.
///
/// ```
///   changeCount ──▶ types (métadonnées, gratuit, aucune alerte)
///        │              │
///        │              ├── +40 ms ──┐
///        │              ├── +120 ms  ├── l'ensemble a-t-il grossi ?
///        │              ├── +300 ms  │
///        │              └── +1000 ms ┘
///        │
///        ├──▶ string(forType:) ─ mode access : UNE lecture, annoncée, chronométrée
///        │
///        └──▶ data(forType:) ─── mode cost : TOUS les types, --force obligatoire
/// ```
///
/// **Deux règles, non négociables, parce que ça tourne sur le vrai
/// presse-papiers de quelqu'un.**
///
/// - *Jamais d'écriture.* Aucun appel à `clearContents`, `setData`,
///   `writeObjects` ou `prepareForNewContents` n'existe dans ce fichier. Écrire
///   ferait perdre à son propriétaire ce qu'il venait de copier, et fausserait
///   toutes les mesures d'un coup. Les modes `access` et `cost` réimpriment le
///   compteur en fin de course : deux nombres identiques, et la promesse est
///   vérifiée plutôt que déclarée.
/// - *Jamais de contenu imprimé.* Identifiants de type, nombres d'octets,
///   dimensions d'image, durées, empreintes — jamais les octets, jamais la
///   chaîne. Ce presse-papiers contient des mots de passe et des clés d'API.
struct PasteboardProbe {

    enum Mode: String {
        /// La vraie mesure : un bloc par changement, sur une journée de
        /// travail. Le mode par défaut, et le seul qui ne coûte rien.
        case watch
        /// Une photographie de l'autorisation, à lire comme une base de
        /// référence et rien de plus. Fait **une** lecture de contenu, qui peut
        /// bloquer : elle est annoncée et chronométrée plutôt qu'interdite.
        case access
        /// Le prix des octets, type par type. Le seul qui exige `--force` : il
        /// lit *toutes* les représentations, y compris celles qui coûtent des
        /// secondes et des centaines de méga-octets.
        case cost
    }

    let mode: Mode
    /// Le pas de scrutin du compteur. 100 ms par défaut : c'est le pas que
    /// devra tenir le produit, donc c'est le pas qu'on mesure.
    let interval: Duration
    /// Exigé par `cost`, ignoré ailleurs.
    let force: Bool

    /// Les instants de re-échantillonnage après un changement, comptés depuis la
    /// détection. Le dernier borne la fenêtre : au-delà d'une seconde, un
    /// historique ne peut plus prétendre réagir à un ⌘C.
    private static let resampleOffsets: [Duration] = [
        .milliseconds(40), .milliseconds(120), .milliseconds(300), .milliseconds(1000),
    ]

    /// Les trois marqueurs de la convention nspasteboard.org. macOS ne les
    /// impose pas : ce sont des types vides qu'une application *polie* pose pour
    /// dire « ne garde pas ça ». Savoir combien d'applications les posent
    /// réellement décide si un historique peut s'y fier, ou s'il lui faut une
    /// règle à lui.
    private static let concealmentMarkers = [
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.TransientType",
        "org.nspasteboard.AutoGeneratedType",
    ]

    // MARK: - Entrée

    func run() async throws {
        // Sortie ligne par ligne même redirigée vers un fichier. Une sonde qui
        // tourne huit heures et dont le tampon n'est vidé qu'à la fin ne sert à
        // rien pendant ces huit heures.
        setvbuf(stdout, nil, _IOLBF, 0)

        switch mode {
        case .watch: try await runWatch()
        case .access: await runAccess()
        case .cost: try runCost()
        }
    }

    // MARK: - Mode watch

    private func runWatch() async throws {
        let stop = InterruptFlag()
        // `SIG_IGN` d'abord : sans ça le processus meurt avant que la source
        // Dispatch ne voie quoi que ce soit, et le récapitulatif — la seule
        // sortie qui répond vraiment aux questions posées — n'est jamais
        // imprimé.
        signal(SIGINT, SIG_IGN)
        let interrupts = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        interrupts.setEventHandler {
            // Le deuxième Ctrl-C ne discute pas.
            if stop.raise() == false { exit(130) }
        }
        interrupts.resume()
        defer {
            interrupts.cancel()
            signal(SIGINT, SIG_DFL)
        }

        let startedAt = Date.now
        var lastCount = Self.changeCount()
        var lastAt = ContinuousClock.now
        var changes: [Change] = []

        print("→ mode watch · tic \(interval) · re-échantillons à +40, +120, +300, +1000 ms")
        print("→ compteur au démarrage : \(lastCount)")
        print("→ LECTURE SEULE : aucune écriture, aucun contenu imprimé.")
        print("→ Ctrl-C pour arrêter et imprimer le récapitulatif.\n")

        while stop.isRaised == false {
            // Le cache d'applications de `NSWorkspace` est alimenté par le run
            // loop principal, et un exécutable en ligne de commande n'en fait
            // pas tourner un. Un tour à échéance nulle, une fois par tic, garde
            // ce cache frais à 100 ms près ; sans lui, « l'application au
            // premier plan » pourrait rester figée sur celle du lancement, et la
            // distribution par application du récapitulatif ne voudrait rien
            // dire. Le récapitulatif compte les lectures nulles, pour que le
            // doute soit visible plutôt que silencieux.
            await Self.pumpMainRunLoop()

            let current = Self.changeCount()
            if current != lastCount {
                let detectedAt = ContinuousClock.now
                let change = await observe(
                    count: current,
                    delta: current - lastCount,
                    sinceLast: changes.isEmpty ? nil : detectedAt - lastAt,
                    detectedAt: detectedAt,
                    index: changes.count + 1,
                    stop: stop
                )
                changes.append(change)
                lastAt = detectedAt
                // Volontairement `current`, et non le compteur relu après la
                // fenêtre : si le compteur a bougé pendant le
                // re-échantillonnage, c'est un vrai changement, et il doit être
                // observé au tic suivant plutôt qu'avalé ici.
                lastCount = current
            }

            try? await Task.sleep(for: interval)
        }

        printSummary(changes, since: startedAt)
    }

    /// Tout ce qu'on peut savoir d'un changement **sans lire un seul octet**.
    private func observe(
        count: Int,
        delta: Int,
        sinceLast: Duration?,
        detectedAt: ContinuousClock.Instant,
        index: Int,
        stop: InterruptFlag
    ) async -> Change {
        let wallClock = Date.now
        // Lu en tout premier : c'est le seul instant où la question « qui a
        // copié ? » a une réponse.
        let front = NSWorkspace.shared.frontmostApplication
        let app = front?.bundleIdentifier ?? front?.localizedName

        // `types` et `pasteboardItems` sont de la métadonnée : la liste de ce
        // qui est *annoncé*, pas de ce qui est *rendu*. Elles ne réveillent
        // aucun fournisseur paresseux et ne déclenchent pas l'alerte d'accès de
        // macOS 15.4 — seul `data(forType:)` le fait, et il n'est appelé que par
        // le mode `cost`. C'est ce qui rend cette sonde tenable en continu, huit
        // heures durant, sur un presse-papiers qu'on ne veut pas lire.
        let atDetection = Self.currentTypes()
        let itemsAtDetection = Self.currentItemTypes()

        print(String(repeating: "─", count: 92))
        print("▸ \(Self.clock(wallClock))  #\(index)  compteur=\(count) (+\(delta))"
            + "  Δ=\(sinceLast.map { Self.human(Self.ms($0)) } ?? "—")"
            + "  app=\(app ?? "NON RÉSOLUE")")
        print("  détection : \(atDetection.count) type(s), \(itemsAtDetection.count) item(s)")

        var previous = atDetection
        var grew = false
        var shrank = false
        var lastMovement: Double?

        for offset in Self.resampleOffsets {
            if stop.isRaised { break }
            let target = detectedAt + offset
            if ContinuousClock.now < target {
                try? await Task.sleep(until: target, clock: ContinuousClock())
            }
            let sampled = Self.currentTypes()
            let actual = Self.ms(ContinuousClock.now - detectedAt)
            let difference = sampled.count - previous.count

            let marker: String
            if sampled == previous {
                marker = "="
            } else if difference > 0 {
                marker = "+\(difference)"
                grew = true
                lastMovement = actual
            } else if difference < 0 {
                marker = "\(difference)"
                shrank = true
                lastMovement = actual
            } else {
                // Même compte, ensemble différent : une représentation en a
                // remplacé une autre. Rare, mais un historique qui déduplique
                // sur le nombre de types passerait à côté.
                marker = "≠"
                grew = true
                lastMovement = actual
            }

            print("  +" + Self.leftPad(Self.round(actual), to: 5) + " ms : "
                + Self.leftPad("\(sampled.count)", to: 2) + " type(s)  [\(marker)]")
            previous = sampled
        }

        let finalTypes = previous
        let finalItems = Self.currentItemTypes()
        let countAfter = Self.changeCount()
        let markers = Self.concealmentMarkers.filter { marker in
            finalTypes.contains(marker) || finalItems.contains { $0.contains(marker) }
        }

        // Le verdict de la fenêtre. C'est cette ligne, répétée cent fois sur une
        // journée, qui décide de la stratégie de lecture du produit.
        if atDetection.isEmpty, finalTypes.isEmpty == false {
            print("  ⇒ VIDE À LA DÉTECTION, rempli à \(Self.human(lastMovement ?? 0))"
                + " — « clearContents puis setData » est CONFIRMÉ ici")
        } else if grew {
            print("  ⇒ EN PLUSIEURS TEMPS : \(atDetection.count) → \(finalTypes.count) type(s),"
                + " dernier mouvement à \(Self.human(lastMovement ?? 0))")
        } else if shrank {
            print("  ⇒ L'ENSEMBLE A RÉTRÉCI : \(atDetection.count) → \(finalTypes.count) type(s)")
        } else {
            print("  ⇒ écriture atomique : l'ensemble des types n'a pas bougé en 1 s")
        }

        if countAfter != count {
            print("  ⇒ ATTENTION : le compteur a bougé pendant la fenêtre (\(count) → \(countAfter))."
                + " Chez cette application, les écritures qui suivent n'incrémentent PAS de 0.")
        }

        if finalTypes.isEmpty {
            print("  types : aucun (presse-papiers vide au bout d'une seconde)")
        } else {
            print("  types (\(finalTypes.count), dans l'ordre) :")
            for (rank, type) in finalTypes.enumerated() {
                print("     " + Self.leftPad("\(rank + 1)", to: 2) + ". " + type)
            }
        }

        if finalItems.isEmpty == false {
            print("  items (\(finalItems.count)) :")
            for (rank, types) in finalItems.enumerated() {
                let list = types.isEmpty ? "aucun type" : types.joined(separator: ", ")
                print("     item \(rank + 1) : \(list)")
            }
        }

        print("  marqueurs : " + (markers.isEmpty
            ? "aucun"
            : markers.map(Self.shortMarker).joined(separator: ", ")))

        return Change(
            at: wallClock,
            app: app,
            finalTypes: finalTypes,
            items: finalItems.count,
            sinceLast: sinceLast,
            emptyAtDetection: atDetection.isEmpty && finalTypes.isEmpty == false,
            multiPhase: grew || shrank,
            countMovedDuringWindow: countAfter != count,
            markers: markers
        )
    }

    // MARK: - Mode access

    /// Le budget d'une lecture, en millisecondes. Au-delà, ce n'est plus une
    /// lecture, c'est une attente : c'est le seuil que `runCost` retient déjà
    /// pour dire qu'une représentation doit être lue en tâche de fond, et il n'y
    /// a aucune raison qu'il change de valeur selon le mode qui l'observe.
    private static let accessBudgetMs: Double = 500

    /// Le pas du compte à rebours affiché pendant que l'appel n'est pas revenu.
    private static let accessTick: Duration = .milliseconds(500)

    private func runAccess() async {
        print("""
        ⚠︎  CE CHIFFRE NE DIT RIEN DE bran.app
        ────────────────────────────────────────────────────────────────────────
        Un exécutable en ligne de commande n'a pas d'identité propre : il hérite
        de l'autorisation presse-papiers du Terminal, qui, lui, a déjà derrière
        lui des années d'accès et de boîtes de dialogue. Le bundle signé
        `bran.app` partira d'un état vierge, sous son propre identifiant, et sera
        listé séparément dans Réglages Système.

        À lire comme une base de référence — « voilà à quoi ressemble l'API » —
        et jamais comme une prédiction.

        """)

        let tick = Self.human(Self.ms(Self.accessTick))
        let budget = Self.human(Self.accessBudgetMs)
        print("""
        ⚠︎  ET CETTE LECTURE PEUT BLOQUER
        ────────────────────────────────────────────────────────────────────────
        Observer `accessBehavior` suppose d'y toucher : sans lecture, il n'y a
        pas de bascule à constater. Or `string(forType:.string)` lit le CONTENU,
        pas la métadonnée. Si la représentation texte est *promise* — copiée
        depuis une application occupée, ou encore en train d'arriver de l'iPhone
        par le presse-papiers universel — la demander est un XPC SYNCHRONE vers
        l'application source, qui doit la fabriquer. Comme le `data(forType:)`
        du mode `cost`, cet appel peut donc durer des secondes.

        Ce mode n'exige pas `--force` pour autant : il est fait pour être lancé,
        et une barrière le rendrait inutile. Il borne le risque autrement — une
        seule lecture, de la plus banale des représentations, chronométrée, un
        point d'attente affiché toutes les \(tick) tant qu'elle n'est pas
        revenue, et un verdict explicite au-delà de \(budget). Rien n'est écrit,
        aucun octet n'est imprimé.

        """)

        let before = Self.accessBehaviourDescription()
        let countBefore = Self.changeCount()
        print("accessBehavior avant : \(before)")
        print("compteur avant       : \(countBefore)")
        print("types présents       : \(Self.currentTypes().count)")
        print("")
        print("→ lecture de string(forType:.string)…")

        // UNE seule lecture, et de la plus banale des représentations : c'est
        // exactement ce qu'un historique ferait à son réveil.
        //
        // Détachée, pour que le compte à rebours puisse s'imprimer PENDANT le
        // gel. Rien ne l'interrompt — un XPC synchrone ne s'annule pas, et
        // prétendre le contraire avec un `withTimeout` laisserait un thread
        // bloqué derrière un résultat abandonné —, mais l'attente cesse d'être
        // muette. C'est la seule borne qu'on puisse honnêtement poser : la
        // rendre visible pendant qu'elle dure, et la nommer après.
        let clock = ContinuousClock()
        let started = clock.now
        let reading = Task.detached(priority: .userInitiated) {
            NSPasteboard.general.string(forType: .string)
        }
        let countdown = Task {
            while true {
                try? await Task.sleep(for: Self.accessTick)
                guard Task.isCancelled == false else { return }
                print("  ⏳ toujours dans string(forType:) après "
                    + "\(Self.human(Self.ms(clock.now - started))) — l'application source n'a "
                    + "pas encore rendu la représentation")
            }
        }
        let text = await reading.value
        countdown.cancel()
        let elapsed = Self.ms(clock.now - started)

        switch text {
        case nil:
            print("string(forType:.string) → nil (aucune représentation texte)")
        case let value? where value.isEmpty:
            print("string(forType:.string) → chaîne VIDE (le type existe, le contenu est nul)")
        case let value?:
            let data = Data(value.utf8)
            print("string(forType:.string) → \(value.count) caractère(s), \(Self.bytes(data.count))"
                + ", empreinte salée \(Self.fingerprint(data))")
        }
        print("durée de l'appel     : \(Self.human(elapsed))")

        // Le verdict du temps, rendu **avant** celui de l'autorisation et
        // indépendamment de lui. Il était auparavant glissé en incise dans la
        // branche « rien n'a changé » : un appel qui bloquait *et* faisait
        // basculer l'état — le cas le plus intéressant des deux, puisque c'est
        // celui du tout premier accès — ne le mentionnait donc jamais.
        if elapsed > Self.accessBudgetMs {
            print("→ L'APPEL A BLOQUÉ : \(Self.human(elapsed)), au-dessus du budget de \(budget).")
            print("  La représentation texte n'était pas prête : l'application source a dû la")
            print("  fabriquer pendant qu'on attendait. C'est le gel que le mode `cost` mesure sur")
            print("  tous les types, et il arrive aussi ici, sur un seul, sans qu'on l'ait demandé.")
            print("  Un historique qui lirait sur le fil principal aurait figé l'interface d'autant.")
        } else {
            print("→ L'appel n'a pas bloqué : \(Self.human(elapsed)), sous le budget de \(budget).")
            print("  Ce n'est pas une garantie pour la fois suivante : ce presse-papiers-ci n'avait")
            print("  simplement rien de promis à fabriquer.")
        }
        print("")

        // Le signal observable, et il vient de l'en-tête d'Apple : au tout
        // premier accès qui déclenche l'alerte, l'état passe *automatiquement*
        // de `default` à `ask` et l'application apparaît dans Réglages Système.
        // Si ces deux lignes diffèrent, la bascule vient d'avoir lieu.
        let after = Self.accessBehaviourDescription()
        print("accessBehavior après : \(after)")
        print("compteur après       : \(Self.changeCount())  (identique = rien n'a été écrit)")
        print("")

        if before == after {
            print("→ Rien d'observable du côté de l'autorisation : l'état n'a pas changé.")
        } else {
            print("→ OBSERVABLE : l'état est passé de « \(before) » à « \(after) ».")
            print("  C'est la bascule décrite par Apple : le premier accès qui déclenche l'alerte")
            print("  fait passer l'application de `default` à `ask` et la fait apparaître dans")
            print("  Réglages Système. Elle arrivera une fois à bran.app, et ce jour-là la boîte")
            print("  de dialogue sera vue par l'utilisateur.")
        }

        print("""

        CE QUE ÇA DÉCIDE — `default` signifie « on n'a encore jamais demandé »,
        pas « autorisé » : l'alerte est devant, pas derrière. Un historique qui
        lit le presse-papiers à chaque changement la déclenchera au premier accès
        non sollicité ; un historique qui ne lit que `types` ne la déclenche
        jamais. Le vrai chiffre ne sera connu qu'en relançant ce mode DEPUIS
        bran.app signé.

        Et la durée ci-dessus dit l'autre moitié du prix : même une lecture
        autorisée peut coûter des secondes. Les deux verdicts se lisent ensemble
        — l'autorisation décide si on PEUT lire, la durée décide d'OÙ on lit. La
        réponse au second est déjà connue : jamais depuis le fil principal.
        """)
    }

    // MARK: - Mode cost

    private func runCost() throws {
        guard force else { throw PasteboardProbeError.forceRequired }

        print("""
        ⚠︎  CE MODE LIT LES OCTETS. C'est le seul.
        ────────────────────────────────────────────────────────────────────────
        • Un type promis n'existe pas encore : `data(forType:)` est un XPC
          SYNCHRONE vers l'application source, qui doit fabriquer la
          représentation. Si elle est occupée, la sonde se fige — et ce gel EST
          la mesure.
        • Le mode `access` fait UNE lecture ; celui-ci en fait autant qu'il y a
          de types annoncés, et c'est le seul qui puisse faire rendre à une
          application un TIFF de plusieurs centaines de méga-octets. L'alerte
          d'accès de macOS 15.4, elle, peut se déclencher sur l'un comme sur
          l'autre.

        Aucun octet n'est imprimé : taille, durée, dimensions, empreinte salée.

        """)

        let types = Self.currentTypes()
        let countBefore = Self.changeCount()
        print("compteur avant : \(countBefore) · \(types.count) type(s) à mesurer\n")

        guard types.isEmpty == false else {
            print("Presse-papiers vide : rien à mesurer.")
            return
        }

        print(Self.row("DURÉE", "TAILLE", "DÉTAIL", "TYPE"))
        print(String(repeating: "─", count: 100))

        let clock = ContinuousClock()
        var total = 0
        var slowestType = ""
        var slowestMs = -1.0

        for type in types {
            let started = clock.now
            let data = NSPasteboard.general.data(forType: NSPasteboard.PasteboardType(type))
            let elapsed = Self.ms(clock.now - started)

            if elapsed > slowestMs {
                slowestMs = elapsed
                slowestType = type
            }

            guard let data else {
                print(Self.row(Self.human(elapsed), "—", "nil (type promis non rendu)", type))
                continue
            }
            total += data.count

            var detail = Self.fingerprint(data)
            if let size = Self.imageDimensions(data, type: type) { detail = "\(size) · \(detail)" }
            print(Self.row(Self.human(elapsed), Self.bytes(data.count), detail, type))
        }

        print(String(repeating: "─", count: 100))
        print("total : \(Self.bytes(total)) sur \(types.count) type(s)")
        print("le plus lent : \(Self.human(slowestMs)) — \(slowestType)")
        print("compteur après : \(Self.changeCount())  (identique = rien n'a été écrit)")
        print("""

        CE QUE ÇA DÉCIDE — Le total en octets est le coût de stockage d'UNE entrée
        d'historique qui garderait tout ; multiplié par la taille de l'historique,
        c'est le budget disque. Le type le plus lent est le budget d'une lecture
        synchrone : au-delà de ~50 ms elle fige l'interface si elle est faite sur
        le fil principal, au-delà de ~500 ms il faut soit ne garder que les types
        bon marché, soit lire en tâche de fond en acceptant que l'entrée arrive
        après coup. Un `nil` sur un type pourtant annoncé est un type promis que
        l'application source a refusé de rendre : l'historique ne peut pas compter
        dessus.
        """)
    }

    // MARK: - Récapitulatif

    private func printSummary(_ changes: [Change], since started: Date) {
        let elapsed = Date.now.timeIntervalSince(started)
        print("\n" + String(repeating: "═", count: 92))
        print("RÉCAPITULATIF — \(changes.count) changement(s) en \(Self.human(elapsed * 1000))\n")

        guard let first = changes.first, let last = changes.last else {
            print("Aucun changement observé. Soit la mesure a été trop courte, soit le compteur de")
            print("`NSPasteboard.general` ne bouge pas dans ce contexte — auquel cas c'est le")
            print("scrutin par `changeCount` lui-même qui est à revoir, et c'est un résultat.")
            return
        }

        let multiPhase = changes.filter(\.multiPhase).count
        let empty = changes.filter(\.emptyAtDetection).count
        let moved = changes.filter(\.countMovedDuringWindow).count
        let unresolved = changes.filter { $0.app == nil }.count
        let total = changes.count

        print("  du \(Self.clock(first.at)) au \(Self.clock(last.at))")
        print("  écritures en plusieurs temps     \(multiPhase) / \(total)\(Self.percent(multiPhase, total))")
        print("  vides à la détection             \(empty) / \(total)\(Self.percent(empty, total))")
        print("  compteur mobile dans la fenêtre  \(moved) / \(total)")
        print("  application non résolue          \(unresolved) / \(total)")

        for marker in Self.concealmentMarkers {
            let hits = changes.filter { $0.markers.contains(marker) }.count
            print("  marqueur " + Self.rightPad(Self.shortMarker(marker), to: 24) + "\(hits) / \(total)")
        }

        let intervals = changes.compactMap { $0.sinceLast.map(Self.ms) }
        if let stats = Self.stats(intervals) {
            print("\n  INTERVALLES ENTRE CHANGEMENTS")
            print("     min \(Self.human(stats.min)) · médiane \(Self.human(stats.median))"
                + " · max \(Self.human(stats.max))")
            print("     à moins d'une seconde d'écart : \(intervals.filter { $0 < 1000 }.count)")
            print("     plus courts que le pas de scrutin : \(intervals.filter { $0 < Self.ms(interval) }.count)")
        }

        if let stats = Self.stats(changes.map { Double($0.items) }) {
            print("\n  ITEMS PAR CHANGEMENT")
            print("     min \(Self.round(stats.min)) · médiane \(Self.round(stats.median))"
                + " · max \(Self.round(stats.max))")
        }

        print("\n  APPLICATIONS SOURCES")
        for (name, hits) in Self.tally(changes.map { $0.app ?? "(non résolue)" }) {
            print("     " + Self.leftPad("\(hits)", to: 4) + "  " + name)
        }

        print("\n  TYPES LES PLUS FRÉQUENTS (ensemble final de chaque changement)")
        for (type, hits) in Self.tally(changes.flatMap(\.finalTypes)).prefix(15) {
            print("     " + Self.leftPad("\(hits)", to: 4) + "  " + type)
        }

        print("""

        CE QUE ÇA DÉCIDE
          — « vides à la détection » non nul : lire au premier mouvement du
            compteur enregistrerait des entrées vides. L'historique doit attendre
            la stabilisation, et les « dernier mouvement à » ci-dessus donnent le
            délai à retenir. Tout à zéro : la lecture immédiate suffit, et
            l'entrée apparaît sans latence.
          — « compteur mobile dans la fenêtre » non nul : certaines applications
            publient en plusieurs incréments. Dédupliquer sur le seul
            `changeCount` fabriquerait alors des doublons.
          — un intervalle plus court que le pas de scrutin : le scrutin perd des
            changements. Il faut descendre le pas, ou l'assumer par écrit.
          — les marqueurs : s'ils restent à zéro sur une journée entière, aucune
            application réelle ne les pose, et l'historique ne peut pas s'en
            servir pour écarter les mots de passe. Il lui faudra une autre règle.
          — la distribution par application dit quelles sources méritent un cas
            particulier ; les types fréquents disent ce qu'il suffit de garder.
        """)
    }

    // MARK: - Accès au presse-papiers, en lecture seule

    private static func changeCount() -> Int {
        NSPasteboard.general.changeCount
    }

    private static func currentTypes() -> [String] {
        (NSPasteboard.general.types ?? []).map(\.rawValue)
    }

    private static func currentItemTypes() -> [[String]] {
        (NSPasteboard.general.pasteboardItems ?? []).map { $0.types.map(\.rawValue) }
    }

    private static func accessBehaviourDescription() -> String {
        guard #available(macOS 15.4, *) else {
            return "indisponible (API introduite en macOS 15.4)"
        }
        let behaviour = NSPasteboard.general.accessBehavior
        return "\(behaviour.rawValue) · \(Self.name(of: behaviour))"
    }

    @available(macOS 15.4, *)
    private static func name(of behaviour: NSPasteboard.AccessBehavior) -> String {
        switch behaviour {
        case .default: return "default — on n'a jamais encore demandé ; l'alerte est DEVANT"
        case .ask: return "ask — le système demandera, sauf collage déclenché par l'utilisateur"
        case .alwaysAllow: return "alwaysAllow — accès accordé sans notification"
        case .alwaysDeny: return "alwaysDeny — accès refusé sans notification"
        @unknown default: return "valeur inconnue de ce binaire"
        }
    }

    /// Un tour de run loop principal, à échéance nulle. Voir le commentaire de la
    /// boucle de `runWatch` : c'est ce qui empêche « l'application au premier
    /// plan » d'être éternellement celle du lancement.
    @MainActor
    private static func pumpMainRunLoop() {
        RunLoop.main.run(until: .now)
    }

    // MARK: - Empreintes

    /// Le sel, tiré à chaque lancement et jamais imprimé. Un SHA-256 nu d'un mot
    /// de passe court se retrouve dans un dictionnaire ; un SHA-256 salé d'un sel
    /// que personne ne verra ne se retrouve nulle part. L'empreinte reste
    /// comparable au sein d'une exécution — c'est tout ce qu'on lui demande.
    private static let salt = UInt64.random(in: UInt64.min...UInt64.max)

    private static func fingerprint(_ data: Data) -> String {
        var hasher = SHA256()
        withUnsafeBytes(of: salt.littleEndian) { hasher.update(bufferPointer: $0) }
        hasher.update(data: data)
        return hasher.finalize().prefix(4).map { byte in
            let hex = String(byte, radix: 16)
            return byte < 16 ? "0" + hex : hex
        }.joined()
    }

    /// Les dimensions d'une image **sans la décoder** : `CGImageSource` lit
    /// l'en-tête et s'arrête là. Décoder pour afficher « 4000×3000 » ferait payer
    /// à la mesure de coût un coût qui n'est pas celui du presse-papiers.
    private static func imageDimensions(_ data: Data, type: String) -> String? {
        guard let utType = UTType(type), utType.conforms(to: .image) else { return nil }
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return "\(width)×\(height) px"
    }

    // MARK: - Mise en forme

    private static func bytes(_ count: Int) -> String {
        if count < 1024 { return "\(count) o" }
        if count < 1024 * 1024 { return String(format: "%.1f Ko", Double(count) / 1024) }
        return String(format: "%.2f Mo", Double(count) / (1024 * 1024))
    }

    private static func ms(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
    }

    private static func human(_ milliseconds: Double) -> String {
        if milliseconds < 1000 { return String(format: "%.0f ms", milliseconds) }
        if milliseconds < 60_000 { return String(format: "%.1f s", milliseconds / 1000) }
        return String(format: "%.1f min", milliseconds / 60_000)
    }

    private static func round(_ value: Double) -> String {
        String(format: "%.0f", value)
    }

    private static func percent(_ part: Int, _ whole: Int) -> String {
        guard whole > 0 else { return "" }
        return String(format: "  (%.0f %%)", Double(part) / Double(whole) * 100)
    }

    private static func shortMarker(_ identifier: String) -> String {
        identifier.replacing("org.nspasteboard.", with: "")
    }

    private static func stats(_ values: [Double]) -> (min: Double, median: Double, max: Double)? {
        guard values.isEmpty == false else { return nil }
        let sorted = values.sorted()
        return (sorted[0], sorted[sorted.count / 2], sorted[sorted.count - 1])
    }

    private static func tally(_ values: [String]) -> [(String, Int)] {
        var counts: [String: Int] = [:]
        for value in values { counts[value, default: 0] += 1 }
        return counts
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map { ($0.key, $0.value) }
    }

    /// L'heure à la milliseconde, montée à la main plutôt que par
    /// `formatted(date:time:)`.
    ///
    /// Deux raisons : le fractionnement compte — deux changements séparés de
    /// 80 ms sont indiscernables à la seconde près, et ce sont justement eux qui
    /// décident du pas de scrutin — et un style localisé peut rendre
    /// « 2:22:07 PM », après quoi coller « .412 » ne veut plus rien dire.
    private static func clock(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents(
            [.hour, .minute, .second, .nanosecond], from: date
        )
        let milliseconds = (parts.nanosecond ?? 0) / 1_000_000
        return leftPad("\(parts.hour ?? 0)", to: 2, with: "0")
            + ":" + leftPad("\(parts.minute ?? 0)", to: 2, with: "0")
            + ":" + leftPad("\(parts.second ?? 0)", to: 2, with: "0")
            + "." + leftPad("\(milliseconds)", to: 3, with: "0")
    }

    /// Remplissage manuel, pour la même raison que dans `WatchProbe` : `%@`
    /// s'appuie sur le pontage NSString et se comporte mal avec les accents.
    private static func leftPad(_ text: String, to width: Int, with pad: String = " ") -> String {
        String(repeating: pad, count: max(0, width - text.count)) + text
    }

    private static func rightPad(_ text: String, to width: Int) -> String {
        text + String(repeating: " ", count: max(0, width - text.count))
    }

    private static func row(_ cells: String...) -> String {
        let widths = [10, 11, 30]
        return cells.enumerated()
            .map { index, cell in
                index < widths.count ? rightPad(cell, to: widths[index]) : cell
            }
            .joined(separator: " ")
    }
}

// MARK: - Un changement observé

/// Ce qu'on retient d'un changement une fois la fenêtre d'une seconde écoulée.
/// **Aucun champ ne contient de contenu** : des identifiants, des comptes, des
/// durées. C'est ce qui rend le récapitulatif imprimable sans avoir à réfléchir.
private struct Change {
    let at: Date
    let app: String?
    let finalTypes: [String]
    let items: Int
    let sinceLast: Duration?
    let emptyAtDetection: Bool
    let multiPhase: Bool
    let countMovedDuringWindow: Bool
    let markers: [String]
}

// MARK: - Ctrl-C

/// Un drapeau qu'un gestionnaire de signal lève et qu'une boucle `async` lit.
///
/// `Mutex` plutôt qu'un `var` global marqué `nonisolated(unsafe)` : le
/// gestionnaire tourne sur une file Dispatch et la boucle sur l'exécuteur
/// concurrent. « Ce n'est qu'un booléen » n'est pas un modèle mémoire.
private final class InterruptFlag: Sendable {
    private let flag = Mutex(false)

    /// Rend `true` si c'est le premier Ctrl-C, `false` si le drapeau était déjà
    /// levé — ce qui laisse à l'appelant le soin de ne pas insister.
    @discardableResult
    func raise() -> Bool {
        flag.withLock { raised in
            let first = raised == false
            raised = true
            return first
        }
    }

    var isRaised: Bool { flag.withLock { $0 } }
}

// MARK: - Erreurs

enum PasteboardProbeError: Error, CustomStringConvertible {
    case forceRequired

    var description: String {
        switch self {
        case .forceRequired:
            """
            `--mode cost` refuse de démarrer sans `--force`.

            C'est le mode qui lit TOUTES les représentations, donc le seul qui :
              • force l'application source à fabriquer chacune de celles qui sont
                promises — autant d'XPC synchrones, autant d'occasions de bloquer
                plusieurs secondes chacune ;
              • peut faire rendre une image de plusieurs centaines de méga-octets.

            `--mode access` fait UNE lecture, et peut donc bloquer lui aussi et
            déclencher la même alerte d'accès de macOS 15.4. Il ne demande pas
            `--force` — mesurer `accessBehavior` est sa raison d'être — mais il
            l'annonce et le chronomètre. La barrière n'est ici que parce que le
            coût est multiplié par le nombre de types.

            Aucun octet n'est imprimé, et rien n'est écrit sur le presse-papiers.
            Relancer : swift run BranSpike pasteboard --mode cost --force
            """
        }
    }
}
