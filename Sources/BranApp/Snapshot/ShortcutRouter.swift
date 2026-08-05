import BranSpeech
import Foundation

/// Aiguille les raccourcis vers la bonne fonction, et arbitre entre elles.
///
/// Il existe parce que le `CGEventTap` est unique et n'a qu'un seul callback :
/// il fallait bien un endroit qui sache que Command droite va à la dictée et
/// ⌘⇧2 à la capture de texte.
///
/// **La règle d'arbitrage, et pourquoi celle-là.** Une fonction occupée
/// l'emporte : appuyer sur ⌘⇧2 pendant une dictée ne fait rien, et
/// inversement. Les deux autres possibilités ont été écartées :
///
/// - *tout autoriser en parallèle* — l'encoche ne peut afficher qu'un état, et
///   le viseur de macOS prend la main sur l'écran pendant qu'on parlerait au
///   micro. On finirait par ne plus savoir ce qui enregistre ;
/// - *la nouvelle demande annule l'ancienne* — une frappe malheureuse
///   détruirait une dictée de deux minutes. Une action destructrice ne doit pas
///   être le comportement par défaut d'un raccourci voisin.
///
/// Ignorer est le seul choix qui ne perd jamais de travail.
@MainActor
final class ShortcutRouter {

    let monitor = HotkeyMonitor()

    private weak var dictation: DictationController?
    private weak var snapshot: SnapshotController?

    init() {
        monitor.onSignal = { [weak self] signal in
            self?.route(signal)
        }
    }

    func attach(dictation: DictationController, snapshot: SnapshotController) {
        self.dictation = dictation
        self.snapshot = snapshot
    }

    private func route(_ signal: HotkeyMonitor.Signal) {
        switch signal {
        case .triggerDown(.dictation):
            guard snapshot?.isBusy != true else { return }
            dictation?.hotkeyDown()

        case .triggerUp(.dictation):
            dictation?.hotkeyUp()

        case .triggerDown(.snapshot):
            guard dictation?.isBusy != true else { return }
            snapshot?.triggered()

        case .triggerUp(.snapshot):
            // La capture ne fonctionne qu'en bascule : le viseur de macOS a
            // déjà son propre cycle appui/relâchement, lui en superposer un
            // second annulerait la sélection au moment où on la termine.
            break

        case .cancel:
            // Échap n'annule que ce qui tourne. Sans ce filtre, la touche
            // « ferait quelque chose » à chaque frappe de texte.
            if dictation?.isBusy == true { dictation?.cancel() }
            if snapshot?.isBusy == true { snapshot?.cancel() }
        }
    }
}
