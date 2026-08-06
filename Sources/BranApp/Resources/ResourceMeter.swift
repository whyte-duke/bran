import BranCore
import BranWatch
import Foundation
import Observation

/// **Le moniteur : une boucle, un libellé, et rien qui coûte.**
///
/// ```
///   toutes les 2 s ─▶ ResourceProbe (hors MainActor)
///                          │
///                          ▼
///                     ResourceTracker (BranCore) ─▶ « 2·2 »
///                          │                            │
///                          │                     LabelGate ─▶ barre de menus
///                          ▼                     (≈ 4 fois sur 5 : rien)
///                     panneau déroulant
/// ```
///
/// **Le budget de ce fichier est son propre sujet.** Un moniteur qui coûte ce
/// qu'il mesure est une farce, et celui-ci a le mauvais goût de l'écrire en gros
/// à côté. Trois décisions en découlent :
///
/// 1. **2 s de cadence**, le plancher documenté du dépôt (`docs/PLAN.md`, §11 :
///    « ne pas descendre sous 2 s »).
/// 2. **Les appels système hors du `MainActor`**, comme le veilleur le fait déjà
///    pour la lecture des transcriptions.
/// 3. **`LabelGate`** : au repos, « 2·2 » reste « 2·2 », donc on ne pousse rien.
///    L'élément de barre de menus cesse de se redessiner en boucle pour
///    réafficher les mêmes pixels.
///
/// Et quand le réglage est éteint, **la boucle s'arrête** — pas seulement
/// l'affichage. Mesurer ce que personne ne regarde serait exactement le reproche
/// que ce panneau existe pour permettre de faire.
@MainActor
@Observable
final class ResourceMeter {

    /// Le plancher du dépôt. Descendre à 1 s doublerait le coût du moniteur pour
    /// une nervosité que la médiane effacerait de toute façon.
    static let interval: TimeInterval = 2

    private enum Key {
        static let showsInMenuBar = "bran.resources.showsInMenuBar"
    }

    // MARK: - État observable

    /// La dernière lecture publiable. Le panneau déroulant s'en sert ; il n'est
    /// construit que lorsqu'on ouvre le menu.
    private(set) var reading: ResourceReading = .unknown

    /// Le libellé de la barre de menus. **Il ne change que quand il change.**
    private(set) var label: String = ResourceFormat.menuBarLabel(cpu: nil, memory: nil)

    /// Le second élément de barre de menus, séparé de celui de bran.
    ///
    /// Allumé par défaut : la demande était « affiché quelque part tout le temps
    /// visible ». Un instrument qu'il faut d'abord trouver dans les réglages
    /// n'aurait jamais donné sa ligne de base.
    var showsInMenuBar: Bool {
        didSet {
            guard showsInMenuBar != oldValue else { return }
            defaults.set(showsInMenuBar, forKey: Key.showsInMenuBar)
            setRunning(showsInMenuBar)
        }
    }

    /// Ce qui tourne en ce moment, fourni par `AppModel`.
    ///
    /// **Une fermeture, pas des références.** C'est le patron du dépôt
    /// (`WatchController.isMuted`, `DictationStore(root:)`) et il vaut ici pour
    /// la raison habituelle : le moniteur n'a aucune raison de savoir ce qu'est
    /// Parakeet, un veilleur ou une réunion. Il sait afficher des lignes.
    ///
    /// Le défaut rend une liste vide, c'est-à-dire « bran est au repos » : un
    /// câblage oublié fait dire moins, jamais faux.
    var activities: @MainActor () -> [Activity] = { [] }

    /// Une ligne de la section « En ce moment ».
    ///
    /// **Le mot compte.** Ce ne sont pas des *causes* : personne n'a mesuré que
    /// le chargement de Parakeet explique ces 104 %. Ce sont des états
    /// simultanés. « En ce moment » est honnête et ne coûte rien de plus qu'un
    /// mot juste.
    struct Activity: Identifiable, Equatable {
        var id: String { title }
        var title: String
        var detail: String
    }

    // MARK: - Machinerie

    private var tracker = ResourceTracker()
    private var gate = LabelGate()
    private var loop: Task<Void, Never>?

    /// L'origine des durées, sur l'horloge **qui s'arrête pendant la veille**.
    /// Voir `WatchClock` : le dépôt a déjà payé ce bogue une fois (CR-2), il n'y
    /// aura pas de second détecteur de réveil.
    private var previousInstant = WatchClock.Instant.now

    private let defaults = UserDefaults.standard

    init() {
        showsInMenuBar = defaults.object(forKey: Key.showsInMenuBar) as? Bool ?? true
    }

    /// Démarre la boucle si le réglage le demande. Appelé une fois, par
    /// `AppModel`, après que tout le reste est câblé.
    func start() {
        setRunning(showsInMenuBar)
    }

    private func setRunning(_ running: Bool) {
        guard running else {
            loop?.cancel()
            loop = nil
            // Le point de référence est jeté : la dérivée qui enjamberait la
            // pause serait calculée sur un intervalle que personne n'a observé.
            tracker.forget()
            reading = tracker.reading
            gate = LabelGate()
            label = ResourceFormat.menuBarLabel(cpu: nil, memory: nil)
            return
        }

        guard loop == nil else { return }
        previousInstant = .now
        loop = Task { [weak self] in await self?.run() }
    }

    // MARK: - La boucle

    /// L'échéance est calculée **en tête de boucle**, comme dans
    /// `WatchController.run()` et pour la même raison mesurée : dormir
    /// `interval` *après* le travail fait dériver le tic, et une dérive silencieuse
    /// fausserait ici la dérivée elle-même.
    private func run() async {
        var deadline = SuspendingClock.now

        while Task.isCancelled == false {
            let now = SuspendingClock.now
            if deadline < now { deadline = now }
            deadline = deadline.advanced(by: .seconds(Self.interval))

            await tick()

            // Une tolérance large : ce réveil n'a aucune raison d'être
            // ponctuel, et la laisser au système lui permet de le grouper avec
            // les autres — c'est ce qui coûte le moins d'énergie.
            try? await Task.sleep(
                until: deadline,
                tolerance: .milliseconds(500),
                clock: .suspending
            )
        }
    }

    private func tick() async {
        let clock = WatchClock(tickInterval: Self.interval)
        let step = clock.step(from: previousInstant)
        previousInstant = .now

        // Les deux appels système, hors du MainActor.
        guard let sample = await Task.detached(priority: .utility, operation: {
            ResourceProbe.sample()
        }).value else { return }

        let fresh = tracker.accept(
            cpuNanoseconds: sample.cpuNanoseconds,
            footprintBytes: sample.footprintBytes,
            totalMemoryBytes: ResourceProbe.physicalMemory,
            elapsed: step.elapsed,
            clockJumped: step.jumped
        )

        // `@Observable` publie sur simple affectation, même à valeur égale.
        if fresh != reading { reading = fresh }

        let rendered = ResourceFormat.menuBarLabel(
            cpu: fresh.cpuPercent,
            memory: fresh.memoryPercent
        )
        if gate.offer(rendered) { label = rendered }
    }

    // MARK: - Ce qui s'affiche

    var cpuText: String { ResourceFormat.percentSigned(reading.cpuPercent) }

    /// La lecture normalisée, celle qui répond à « ma machine est-elle
    /// saturée ». Affichée **à côté** de la précédente, jamais à la place.
    var cpuShareText: String {
        ResourceFormat.share(reading.cpuShare(cores: ResourceProbe.cores))
    }

    var memoryText: String { ResourceFormat.bytes(reading.memoryBytes) }
    var memoryShareText: String { ResourceFormat.share(reading.memoryPercent) }

    var coresText: String { "\(ResourceProbe.cores) cœurs" }
    var installedMemoryText: String { ResourceFormat.installedMemory(ResourceProbe.physicalMemory) }
}
