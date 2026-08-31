import BranCore
import Foundation
import Observation

/// **Le test de débit : trois étapes, une aiguille, et rien qui tourne au repos.**
///
/// ```
///   clic ──▶ latence ──▶ descente ──▶ montée ──▶ verdict
///              (1 s)       (4 s)       (4 s)        │
///                │           │           │         └─▶ mémorisé, affiché
///                └───────────┴───────────┘
///                      boucle 10 Hz ──▶ aiguille ──▶ encoche + barre de menus
/// ```
///
/// Même doctrine que `ResourceMeter` et `AwakeController`, et pour les mêmes
/// raisons mesurées :
///
/// 1. **La boucle n'existe que pendant un test.** Au repos, zéro réveil. Un
///    compteur de débit n'a rien à mesurer tant qu'on ne le lui demande pas —
///    contrairement au moniteur de consommation, qui a une raison d'être
///    permanent.
/// 2. **`LabelGate`** : l'aiguille bat à 10 Hz pour être fluide, mais le libellé
///    de la barre de menus ne change qu'au dixième de mégaoctet près. Sept tics
///    sur dix n'ont rien à annoncer.
/// 3. **Un échec repart par une fermeture** (`onFailure`), comme partout
///    ailleurs dans bran : le contrôleur n'a pas à connaître `AppModel`, et
///    `AppModel` a déjà un canal pour dire ce qui a raté.
///
/// ## L'ordre des trois étapes, et il n'est pas indifférent
///
/// La latence **d'abord**, et pas parce qu'elle est rapide : parce qu'elle est
/// la seule à répondre honnêtement sur une ligne au repos. La mesurer pendant ou
/// après un transfert qui sature la ligne mesurerait le *bufferbloat* — la file
/// d'attente que le transfert vient de créer — c'est-à-dire un nombre vrai qui
/// répond à une autre question. Les compteurs qui affichent une latence sous
/// charge le disent ; celui-ci ne le dit pas, donc il ne doit pas le mesurer.
///
/// La descente ensuite, la montée en dernier : c'est l'ordre de ce qu'on regarde.
@MainActor
@Observable
final class SpeedController {

    // MARK: - État observable

    enum Phase: Equatable {
        case idle
        /// Les neuf sondes d'aller-retour.
        case sounding
        case downloading
        case uploading
        /// Le résultat vient de tomber. Distinct de `.idle` parce que l'encoche
        /// doit rester ouverte quelques secondes de plus pour qu'on le lise.
        case done
        case failed(String)

        var isRunning: Bool {
            switch self {
            case .sounding, .downloading, .uploading: true
            case .idle, .done, .failed: false
            }
        }

        /// Le titre affiché dans l'encoche. Court : elle fait deux cents points.
        var title: String {
            switch self {
            case .idle: "Débit"
            case .sounding: "Latence…"
            case .downloading: "Descente"
            case .uploading: "Montée"
            case .done: "Terminé"
            case .failed: "Échec"
            }
        }
    }

    private(set) var phase: Phase = .idle

    /// L'aiguille, en octets par seconde. `nil` hors mesure.
    private(set) var live: Double?

    /// Le dernier relevé complet, **conservé d'un lancement à l'autre**.
    ///
    /// Sans mémoire, le panneau est vide à chaque ouverture et la seule façon de
    /// savoir ce que vaut sa ligne est de relancer un test — donc de dépenser
    /// cent mégaoctets pour relire un chiffre qu'on avait déjà.
    private(set) var reading = SpeedReading()

    /// Le relevé d'**avant**, pour la comparaison.
    ///
    /// C'est la réponse au fait le plus surprenant de toute la mise au point :
    /// la ligne du poste a été mesurée à 14 Mo/s puis à 30 Mo/s dans la même
    /// heure, sans que rien change de visible. Un chiffre seul se lit comme une
    /// propriété de l'abonnement ; deux chiffres côte à côte disent la vérité,
    /// qui est qu'un débit est une météo.
    private(set) var previous: SpeedReading?

    /// Le libellé de la barre de menus. Il ne change que quand il change.
    private(set) var label = "…"

    /// La position de l'aiguille sur le cadran, de 0 à 1. Pilote le symbole à
    /// valeur variable de la barre de menus et l'arc de l'encoche.
    private(set) var needle: Double = 0

    var onFailure: (String) -> Void = { _ in }

    /// Ce que l'encoche doit montrer. Posé par `AppModel`, comme partout.
    var onPresent: (Bool) -> Void = { _ in }

    // MARK: - Machinerie

    private enum Key {
        static let reading = "bran.speed.lastReading"
        static let previous = "bran.speed.previousReading"
    }

    private let defaults = UserDefaults.standard
    private let version: String
    private var run: Task<Void, Never>?
    private var gate = LabelGate()
    private var lastFinished: Date?

    init(version: String) {
        self.version = version
        reading = Self.load(Key.reading, from: defaults) ?? SpeedReading()
        previous = Self.load(Key.previous, from: defaults)
        lastFinished = reading.measuredAt
    }

    // MARK: - Le geste

    /// Peut-on lancer un test maintenant ?
    ///
    /// Le délai est celui de `SpeedPlan.cooldown`, et il existe pour une raison
    /// mesurée qui n'a rien à voir avec les octets : les services de mesure
    /// limitent le débit de requêtes, et Cloudflare a fermé la porte plus de
    /// vingt minutes après une rafale d'essais. Un bouton qu'on peut mitrailler
    /// finit par afficher une panne que bran a lui-même provoquée, sur une ligne
    /// qui va très bien.
    var canStart: Bool {
        guard phase.isRunning == false else { return false }
        guard let lastFinished else { return true }
        return Date.now.timeIntervalSince(lastFinished) >= SpeedPlan.cooldown
    }

    /// Combien de temps il reste à attendre, en secondes entières. `nil` quand
    /// on peut y aller.
    var cooldownRemaining: Int? {
        guard phase.isRunning == false, let lastFinished else { return nil }
        let remaining = SpeedPlan.cooldown - Date.now.timeIntervalSince(lastFinished)
        return remaining > 0 ? Int(remaining.rounded(.up)) : nil
    }

    func start() {
        guard canStart else { return }
        run?.cancel()
        run = Task { [weak self] in await self?.measure() }
    }

    /// Arrêt à la demande. **Ce qui a déjà été mesuré est jeté**, et c'est
    /// délibéré : un test interrompu au milieu de la rampe rendrait un chiffre
    /// qui décrit TCP et non la ligne, et personne ne saurait, en le relisant
    /// demain, qu'il vient d'un test avorté.
    func cancel() {
        run?.cancel()
        run = nil
        // **Le délai court aussi après une annulation.** Il ne compte pas les
        // octets, il compte les requêtes : celles-ci sont bel et bien parties, et
        // c'est d'elles que les serveurs de mesure se protègent. Un bouton
        // « Arrêter » qui remettrait le compteur à zéro offrirait exactement la
        // rafale que le délai existe pour empêcher.
        lastFinished = .now
        settle(.idle)
    }

    // MARK: - La mesure

    private func measure() async {
        let userAgent = SpeedPlan.userAgent(version: version)
        var fresh = SpeedReading()

        onPresent(true)

        // **Latence et descente forment un couple, par source.**
        //
        // La première version sondait la latence vers la source n° 1, puis
        // laissait la descente basculer sur la n° 2 en cas de panne. Le panneau
        // affichait alors « 26 ms » et « 21,5 Mo/s » côte à côte en les
        // présentant comme un même trajet, alors qu'ils décrivaient deux
        // serveurs, deux pays et deux opérateurs de transit. Deux vérités qui ne
        // se sont jamais rencontrées valent moins qu'une seule.
        //
        // La sonde de latence sert donc aussi de test de joignabilité : la
        // première source qui répond est celle qu'on mesure, et c'est gratuit
        // puisqu'il fallait la sonder de toute façon.
        var lastFailure: SpeedProbe.Failure?

        for candidate in SpeedPlan.downloadSources {
            // 1. La latence, sur une ligne encore au repos. Voir l'en-tête pour
            //    ce que la mesurer sous charge donnerait à la place.
            publish(.sounding)
            let latency = await SpeedProbe.latency(from: candidate, userAgent: userAgent)
            guard Task.isCancelled == false else { return settle(.idle) }

            // 2. La descente, depuis la même source.
            publish(.downloading)
            let counter = SpeedProbe.Counter(budget: .quick)
            // L'aiguille suit ce compteur-ci tant que ce candidat-ci tire. Le
            // `defer` la libère sur les trois sorties — succès, échec, repli sur
            // la source suivante — et c'est ce qui évite deux suiveuses en
            // parallèle poussant deux aiguilles dans la même propriété.
            let follower = Task { [weak self] in await self?.follow(counter) }
            defer { follower.cancel() }

            do {
                try await SpeedProbe.download(
                    from: candidate, budget: .quick, userAgent: userAgent, into: counter
                )
                let tally = counter.snapshot
                fresh.download = tally.rate
                fresh.latency = latency.latency
                fresh.jitter = latency.jitter
                fresh.spentBytes += tally.totalBytes
                fresh.source = candidate.name
                lastFailure = nil
                break
            } catch let failure as SpeedProbe.Failure {
                // Les octets déjà tirés sont comptés même si le relevé est perdu :
                // ils ont bel et bien été consommés, et le panneau ne doit pas
                // les cacher parce que le test a raté.
                fresh.spentBytes += counter.snapshot.totalBytes
                lastFailure = failure
                continue
            } catch {
                fresh.spentBytes += counter.snapshot.totalBytes
                lastFailure = .unreachable(error.localizedDescription)
                continue
            }
        }

        guard Task.isCancelled == false else { return settle(.idle) }

        // Une descente perdue est fatale : c'est le chiffre qu'on est venu
        // chercher, et enchaîner sur la montée ferait attendre quatre secondes
        // de plus pour un panneau qui dira quand même « — ».
        if fresh.download == nil {
            FeatureLog.record("débit — descente échouée")
            let reason = lastFailure?.summary
                ?? "Aucun serveur de mesure n'a répondu. La connexion est-elle active ?"
            return fail(reason, spending: fresh.spentBytes)
        }

        // 3. La montée. Un échec ici n'emporte pas le reste : le serveur est un
        // autre hôte, avec ses propres pannes.
        publish(.uploading)
        let counter = SpeedProbe.Counter(budget: .upload)
        let follower = Task { [weak self] in await self?.follow(counter) }
        defer { follower.cancel() }

        do {
            try await SpeedProbe.upload(budget: .upload, userAgent: userAgent, into: counter)
            // **Libérée avant de lire, pas au retour de la fonction.** Le `defer`
            // ci-dessus porte jusqu'à la fin de `measure()`, donc la suiveuse
            // tournerait encore pendant `commit`, et son tic suivant écraserait
            // l'aiguille que `publish(.done)` vient de remettre à zéro. `cancel()`
            // est idempotent : le `defer` reste comme filet.
            follower.cancel()
            let tally = counter.snapshot
            // **L'intégrale, pas la médiane.** Voir `SpeedTally.plateauMean` :
            // les tranches de la montée sont quantifiées par blocs d'un
            // mégaoctet, et une médiane y choisit un multiple au lieu de mesurer.
            fresh.upload = tally.plateauMean
            fresh.spentBytes += tally.totalBytes
        } catch {
            follower.cancel()
            fresh.spentBytes += counter.snapshot.totalBytes
            FeatureLog.record("débit — montée échouée")
        }

        guard Task.isCancelled == false else { return settle(.idle) }

        fresh.measuredAt = .now
        commit(fresh)
    }

    /// La boucle qui suit l'aiguille pendant qu'un transfert court.
    ///
    /// **Elle tire, le délégué ne pousse pas.** Un rappel à chaque bloc reçu
    /// ferait mille sauts vers l'acteur principal par seconde pour redessiner
    /// une aiguille que l'œil ne suit qu'à trente images. C'est la décision de
    /// `SpeedProbe.Counter`, et c'est aussi celle de `ResourceMeter`.
    ///
    /// L'échéance est calculée **en tête de boucle**, comme dans
    /// `ResourceMeter.run()` et `WatchController.run()` : dormir après le
    /// travail fait dériver le tic.
    private func follow(_ counter: SpeedProbe.Counter) async {
        var deadline = SuspendingClock.now
        while Task.isCancelled == false {
            let now = SuspendingClock.now
            if deadline < now { deadline = now }
            deadline = deadline.advanced(by: .milliseconds(100))

            let tally = counter.snapshot
            apply(live: tally.live)

            try? await Task.sleep(until: deadline, tolerance: .milliseconds(30), clock: .suspending)
        }
    }

    // MARK: - Ce qui s'affiche

    /// Le plein cadran, en octets par seconde.
    ///
    /// **Un cadran fixe et pas automatique.** Une échelle qui s'adapterait au
    /// chiffre mesuré ferait la même image pour une ligne à 2 Mo/s et pour une
    /// à 60 : l'aiguille irait au bout dans les deux cas, et le cadran ne dirait
    /// plus rien. 40 Mo/s — 320 Mbit/s — laisse la plupart des lignes françaises
    /// dans les deux premiers tiers, et une fibre saturée bute en haut, ce qui
    /// est une information exacte.
    static let fullScale: Double = 40_000_000

    private func apply(live value: Double?) {
        live = value
        // Racine carrée : sur une échelle linéaire, tout ce qui est sous
        // 5 Mo/s se tasse dans le premier huitième du cadran — c'est-à-dire
        // exactement la plage où la différence intéresse le plus.
        let fraction = min(1, max(0, (value ?? 0) / Self.fullScale))
        needle = fraction.squareRoot()

        let rendered = SpeedFormat.menuBarLabel(value)
        if gate.offer(rendered) { label = rendered }
    }

    private func publish(_ next: Phase) {
        phase = next
        gate = LabelGate()
        if next.isRunning == false { apply(live: nil) }
    }

    private func commit(_ fresh: SpeedReading) {
        previous = reading.isEmpty ? nil : reading
        reading = fresh
        lastFinished = fresh.measuredAt
        Self.save(fresh, at: Key.reading, in: defaults)
        if let previous { Self.save(previous, at: Key.previous, in: defaults) }

        FeatureLog.record("débit — \(SpeedFormat.megabytesSigned(fresh.download)) descendant")
        settle(.done)
    }

    private func fail(_ reason: String, spending bytes: Int) {
        lastFinished = .now
        reading.spentBytes = bytes
        publish(.failed(reason))
        onFailure(reason)
        onPresent(true)
        hideLater(after: 5)
    }

    /// Referme l'encoche après un délai — ou tout de suite si l'on retombe au
    /// repos sans rien à dire.
    private func settle(_ next: Phase) {
        publish(next)
        onPresent(next != .idle)
        guard next != .idle else { return }
        // Cinq secondes : le temps de lire trois nombres. C'est plus long que
        // les 1,8 s de l'encoche de la dictée, parce qu'il y a plus à lire —
        // et parce qu'un test qu'on vient d'attendre neuf secondes mérite qu'on
        // regarde son résultat.
        hideLater(after: 5)
    }

    private func hideLater(after seconds: Double) {
        run = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard Task.isCancelled == false else { return }
            self?.onPresent(false)
            self?.publish(.idle)
        }
    }

    // MARK: - La mémoire

    private static func load(_ key: String, from defaults: UserDefaults) -> SpeedReading? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(SpeedReading.self, from: data)
    }

    private static func save(_ reading: SpeedReading, at key: String, in defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(reading) else { return }
        defaults.set(data, forKey: key)
    }
}
