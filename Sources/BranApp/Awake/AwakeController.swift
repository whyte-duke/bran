import AppKit
import BranCore
import Foundation
import Observation

/// **L'éveil : un état, une assertion, et un décompte qui ne se pousse que
/// quand il change.**
///
/// ```
///   clic ──▶ start(durée) ──▶ SleepBlocker.engage()
///                         └─▶ AwakeState ──▶ boucle 1 s ──▶ LabelGate ──▶ barre
///                                                       └─▶ expiré ──▶ stop()
///
///   NSWorkspace.willSleep ──▶ (si le réglage le demande) ──▶ stop()
///   NSWorkspace.didWake   ──▶ vérifie l'échéance tout de suite
/// ```
///
/// Trois décisions, et ce sont les mêmes que celles du moniteur de
/// consommation, pour les mêmes raisons mesurées :
///
/// 1. **La boucle ne tourne que pendant une session minutée.** « Sans limite »
///    n'a rien à décompter : zéro réveil, zéro travail, pendant des heures.
/// 2. **`LabelGate`** : le décompte change de texte une fois par minute au-delà
///    de la minute, mais la boucle bat à la seconde pour être juste sous la
///    minute. Cinquante-neuf tics sur soixante n'ont donc rien à annoncer, et
///    l'élément de barre de menus ne se redessine pas pour rien.
/// 3. **L'échéance est une `Date`**, pas un compteur : voir `AwakeState`. Au
///    réveil, la session expirée l'est déjà, sans que personne n'ait compté
///    pendant le sommeil.
@MainActor
@Observable
final class AwakeController {

    // MARK: - État observable

    private(set) var state: AwakeState = .off

    /// Le temps restant, tel qu'il s'affiche. `nil` quand il n'y a rien à
    /// décompter — éteint, ou sans limite.
    private(set) var countdown: String?

    let settings: AwakeSettings

    /// Un échec remonte par une fermeture, comme partout ailleurs dans bran
    /// (`AttentionOverlay.onReturn`, `WatchController.isMuted`) : le contrôleur
    /// n'a pas à connaître `AppModel`, et `AppModel` a déjà un canal pour dire
    /// ce qui a raté.
    var onFailure: (String) -> Void = { _ in }

    // MARK: - Machinerie

    private let blocker = SleepBlocker()
    private var gate = LabelGate()
    private var loop: Task<Void, Never>?
    private var observers: [any NSObjectProtocol] = []

    init(settings: AwakeSettings) {
        self.settings = settings
    }

    /// Appelé une fois par `AppModel`. Installe l'écoute de la veille système et
    /// applique le réglage « activer au lancement ».
    func start() {
        observeSleep()
        guard settings.startsAtLaunch else { return }
        begin(settings.defaultDuration)
    }

    // MARK: - Les trois gestes

    var isOn: Bool { state.isOn }

    /// Le clic. **Allumer prend la durée par défaut**, qui vaut « sans limite »
    /// tant que personne n'en a choisi une autre — c'est-à-dire « un clic = tout
    /// le temps », et un second clic pour éteindre.
    func toggle() {
        isOn ? stop() : begin(settings.defaultDuration)
    }

    /// Une durée choisie dans le menu. Redémarre l'échéance même si l'éveil est
    /// déjà actif : demander « deux heures » alors qu'il en reste douze minutes
    /// veut dire deux heures, pas douze minutes.
    func begin(_ duration: AwakeDuration) {
        guard blocker.engage() else {
            // L'interrupteur ne reste pas allumé sur une assertion qui n'existe
            // pas : c'est le seul mensonge qu'une fonction pareille ne peut pas
            // se permettre. Et on relâche avant d'éteindre — `release()` est
            // idempotent, l'ordre inverse laisserait une assertion orpheline le
            // jour où `engage` échouerait sur une session déjà ouverte.
            blocker.release()
            apply(.off)
            let reason = "Le gestionnaire d'énergie a refusé l'éveil — le Mac s'endormira normalement."
            FeatureLog.record("éveil — refusé par le système")
            onFailure(reason)
            return
        }

        apply(.begin(duration, at: .now))
        FeatureLog.record("éveil — démarré (\(duration.label))")
    }

    func stop() {
        guard isOn else { return }
        blocker.release()
        apply(.off)
        FeatureLog.record("éveil — arrêté")
    }

    // MARK: - Le décompte

    private func apply(_ next: AwakeState) {
        state = next
        gate = LabelGate()
        refreshCountdown()
        setTicking(next)
    }

    /// La boucle **n'existe que pour une session minutée**.
    private func setTicking(_ state: AwakeState) {
        loop?.cancel()
        loop = nil

        guard case .until = state else { return }

        loop = Task { [weak self] in
            while Task.isCancelled == false {
                // Une tolérance large : ce réveil n'a aucune raison d'être
                // ponctuel à la milliseconde, et la laisser au système lui
                // permet de le grouper avec les autres.
                try? await Task.sleep(for: .seconds(1), tolerance: .milliseconds(250))
                guard let self, Task.isCancelled == false else { return }
                guard self.expireIfDue() == false else { return }
                self.refreshCountdown()
            }
        }
    }

    /// Rend `true` si la session vient d'être close par son échéance.
    @discardableResult
    private func expireIfDue() -> Bool {
        guard state.hasExpired(at: .now) else { return false }
        blocker.release()
        apply(.off)
        FeatureLog.record("éveil — échéance atteinte")
        return true
    }

    private func refreshCountdown() {
        guard let remaining = state.remaining(at: .now) else {
            countdown = nil
            return
        }
        let rendered = AwakeFormat.countdown(remaining)
        // La porte : cinquante-neuf tics sur soixante ne changent rien au texte.
        if gate.offer(rendered) { countdown = rendered }
    }

    /// La phrase du menu déroulant, qui a la place d'en être une.
    ///
    /// **Elle passe par `countdown` et pas par `Date.now`.** C'est cette lecture
    /// qui abonne la vue aux battements de la boucle : sans elle, la phrase se
    /// figerait dans un menu resté ouvert, à l'instant où on l'a ouvert.
    var summary: String {
        guard case .until = state else { return AwakeFormat.summary(state, at: .now) }
        return AwakeFormat.timed(remainingText)
    }

    /// Ce que la barre de menus ajoute quand l'icône, elle, montre autre chose.
    /// `nil` quand l'éveil est éteint.
    var menuBarMark: String? {
        switch state {
        case .off: nil
        case .indefinite: AwakeFormat.forever
        case .until: remainingText
        }
    }

    /// Le décompte publié par la boucle. Le repli recalcule au lieu d'inventer :
    /// `countdown` est posé par `apply` avant que la boucle ne démarre, donc il
    /// n'est jamais nul pendant une session minutée — mais un jour où cet
    /// enchaînement changerait, mieux vaut une seconde de retard qu'un « ∞ » sur
    /// une session qui finit dans deux minutes.
    private var remainingText: String {
        countdown ?? AwakeFormat.countdown(state.remaining(at: .now) ?? 0)
    }

    // MARK: - La veille du Mac

    /// **Deux notifications, deux rôles distincts.**
    ///
    /// `willSleep` applique le réglage : une veille demandée à la main veut dire
    /// « j'ai fini ». Elle arrive aussi bien pour une veille système que pour un
    /// capot refermé — et l'assertion, elle, n'empêche que la veille par
    /// *inactivité*. Les deux cas qui restent sont donc exactement les cas
    /// explicites que le réglage vise.
    ///
    /// `didWake` ne fait rien d'autre que rafraîchir tout de suite : sans elle,
    /// une session expirée pendant le sommeil resterait affichée jusqu'au
    /// premier tic de la boucle — une seconde d'un chiffre faux, mais au moment
    /// précis où l'utilisateur regarde son écran se rallumer.
    private func observeSleep() {
        let center = NSWorkspace.shared.notificationCenter

        observers.append(center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, settings.stopsOnManualSleep, isOn else { return }
                FeatureLog.record("éveil — arrêté par la mise en veille du Mac")
                stop()
            }
        })

        observers.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, isOn else { return }
                guard expireIfDue() == false else { return }
                refreshCountdown()
            }
        })
    }
}
