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
///
/// **Et une exception, qui n'en est pas une.** `copyHint` traverse cet
/// aiguilleur sans passer par l'arbitrage. Ce n'est pas une entorse à la règle
/// ci-dessus mais son domaine exact : la règle départage des *fonctions de bran*
/// qui se disputent l'écran et le micro. Un ⌘C ne dispute rien à personne — il
/// dit qu'un contenu vient de changer de main, et le jeter parce qu'une dictée
/// tourne perdrait précisément la copie qu'on allait coller.
@MainActor
final class ShortcutRouter {

    let monitor = HotkeyMonitor()

    private weak var dictation: DictationController?
    private weak var snapshot: SnapshotController?

    /// Ouvrir le panneau d'historique du presse-papiers.
    ///
    /// **Une fermeture et pas un `weak var` comme les deux autres, parce que le
    /// contrôleur n'existe pas encore.** Ce qui manque, et ce qu'il faudra
    /// brancher ici : un objet qui possède un `ClipboardMachine`, tient la liste
    /// des entrées, et sait poser le panneau. Le jour où il arrive, deux
    /// possibilités — une troisième référence faible et un `case` de plus dans
    /// `attach`, ou cette fermeture telle quelle. La fermeture suffit tant que
    /// l'aiguilleur n'a rien à *demander* au presse-papiers ; le passage à la
    /// référence faible se justifiera le jour où il devra l'interroger, par
    /// exemple pour un `isBusy` qui entrerait dans l'arbitrage.
    ///
    /// Tant qu'elle est `nil`, ⌘⇧C ne fait rien — et c'est l'état actuel : rien
    /// n'ouvre de panneau.
    var openClipboardPanel: (() -> Void)?

    /// « Le panneau du presse-papiers est-il ouvert ? »
    ///
    /// **Une fermeture, comme l'ouverture, et pour la même raison** : le
    /// contrôleur du presse-papiers n'est pas connu de cet aiguilleur. Elle
    /// complète l'arbitrage dans le sens qui manquait — les deux autres
    /// fonctions faisaient taire le panneau, le panneau ne faisait taire
    /// personne. Or il prend le clavier : démarrer une dictée pendant qu'il est
    /// ouvert poserait l'encoche par-dessus une liste qui attend une touche, et
    /// une capture y poserait le viseur de macOS.
    var clipboardIsBusy: (() -> Bool)?

    /// « Une copie vient d'avoir lieu, et voici le compte d'avant. »
    ///
    /// Le futur contrôleur y branchera `machine.handle(.hinted(changeCount:at:))`
    /// et exécutera les effets rendus. Rien d'autre n'a le droit de s'y mettre :
    /// l'indice n'a de valeur que relevé une fois, tout de suite.
    var onCopyHint: ((Int) -> Void)?

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
            guard snapshot?.isBusy != true, clipboardIsBusy?() != true else { return }
            dictation?.hotkeyDown()

        case .triggerUp(.dictation):
            dictation?.hotkeyUp()

        case .triggerDown(.snapshot):
            guard dictation?.isBusy != true, clipboardIsBusy?() != true else { return }
            snapshot?.triggered()

        case .triggerUp(.snapshot):
            // La capture ne fonctionne qu'en bascule : le viseur de macOS a
            // déjà son propre cycle appui/relâchement, lui en superposer un
            // second annulerait la sélection au moment où on la termine.
            break

        case .triggerDown(.clipboard):
            // La même règle que pour les deux autres, pas une nouvelle : une
            // fonction occupée l'emporte. Ouvrir le panneau pendant une dictée
            // poserait une fenêtre par-dessus l'encoche qui enregistre, et
            // pendant une capture, par-dessus le viseur de macOS.
            guard dictation?.isBusy != true, snapshot?.isBusy != true else {
                FeatureLog.record("presse-papiers : ⌘⇧C ignoré, une autre fonction est occupée")
                return
            }
            openClipboardPanel?()

        case .triggerUp(.clipboard):
            // Le panneau fonctionne en bascule, comme la capture : le relâchement
            // de ⌘⇧C n'a rien à dire.
            break

        case .copyHint(let changeCount):
            // **Relayé sans condition, et c'est le seul signal dans ce cas.** Ce
            // n'est pas une fonction de bran qui démarre, c'est une copie faite
            // dans une autre application. L'arbitrer reviendrait à décider que
            // ce qu'on copie pendant une dictée ne mérite pas d'être gardé —
            // alors que c'est exactement ce qu'on voudra coller à la fin.
            onCopyHint?(changeCount)

        case .cancel:
            // Échap n'annule que ce qui tourne. Sans ce filtre, la touche
            // « ferait quelque chose » à chaque frappe de texte.
            if dictation?.isBusy == true { dictation?.cancel() }
            if snapshot?.isBusy == true { snapshot?.cancel() }
        }
    }
}
