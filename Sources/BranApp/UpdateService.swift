import Observation
import Sparkle

/// Les mises à jour, telles que ceux qui reçoivent bran les vivront.
///
/// **Le problème que ça résout n'est pas technique.** bran est donné de la main
/// à la main à trois personnes. Sans mécanisme, chaque correctif suppose de
/// refabriquer une image disque, de la transmettre, d'expliquer qu'il faut
/// glisser par-dessus l'ancienne — et, surtout, de savoir qui a quelle version
/// quand quelqu'un signale un défaut déjà corrigé la semaine précédente. Ce
/// coût-là ne se paie pas une fois : il se paie à chaque amélioration, et il
/// finit par décider lesquelles valent la peine d'être livrées.
///
/// **Sparkle plutôt qu'un vérificateur maison**, et ce n'est pas de la
/// paresse. Remplacer un paquet d'application pendant qu'il tourne est un
/// exercice où l'on se coupe : il faut attendre la sortie du processus,
/// permuter les dossiers, relancer, et savoir revenir en arrière si l'une des
/// trois étapes échoue à mi-chemin. Sparkle fait ça depuis vingt ans, avec un
/// assistant séparé — `Updater.app`, embarqué dans le framework — précisément
/// parce qu'un programme ne peut pas se remplacer lui-même en toute sécurité.
///
/// **La signature EdDSA est la moitié qui compte.** Le flux et l'archive sont
/// servis par GitHub en HTTPS, ce qui est déjà correct ; mais bran n'accepte
/// d'installer une archive que si elle est signée par la clé privée qui vit
/// dans le trousseau de celui qui publie. Un compte GitHub compromis ne suffit
/// donc pas à pousser un binaire sur les machines de l'équipe — et c'est bien
/// le pire scénario d'un mécanisme de mise à jour automatique : il installe ce
/// qu'on lui donne, avec l'accès à l'écran et au micro que l'utilisateur a déjà
/// accordé.
///
/// Ce que l'utilisateur voit, et c'est tout ce qu'on lui demande : rien pendant
/// le téléchargement, puis « une mise à jour est prête, relancer bran ».
@MainActor
@Observable
final class UpdateService {

    /// Le contrôleur de Sparkle, démarré à la construction.
    ///
    /// `startingUpdater: true` lance la vérification programmée tout de suite.
    /// Les paramètres — fréquence, téléchargement automatique — sont dans
    /// `Info.plist` et non ici : ce sont des réglages de distribution, ils
    /// doivent pouvoir changer sans recompiler, et Sparkle les lit lui-même.
    @ObservationIgnored
    private let controller: SPUStandardUpdaterController

    /// **Sans `@ObservationIgnored`, ce champ ferait redessiner l'interface à
    /// chaque battement de la minuterie de Sparkle.** Rien de ce qu'il contient
    /// n'est affiché : ce qui se voit, c'est la fenêtre que Sparkle présente
    /// lui-même.
    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    /// La vérification demandée à la main, depuis le menu.
    ///
    /// Elle existe en plus de la vérification programmée parce que les deux ne
    /// répondent pas à la même question. La programmée dit « tiens-moi à jour » ;
    /// celle-ci dit « je viens de te signaler un défaut, est-ce qu'il est
    /// corrigé ? » — et cette question-là se pose dans la minute, pas au
    /// prochain intervalle.
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    /// Une vérification est-elle possible en ce moment ?
    ///
    /// Faux pendant qu'une autre tourne, et pendant une installation. L'entrée
    /// de menu s'éteint plutôt que de ne rien faire quand on clique : c'est la
    /// même règle que les boutons de la barre de session pendant la
    /// finalisation.
    var canCheckForUpdates: Bool {
        controller.updater.canCheckForUpdates
    }

    /// La version installée, telle qu'elle s'affiche dans le menu.
    ///
    /// Lue dans le paquet et non écrite en dur : c'est `Scripts/release.sh` qui
    /// l'incrémente, et une constante recopiée ici finirait par annoncer une
    /// version qui n'est pas celle qui tourne — sur le seul écran où quelqu'un
    /// vient justement vérifier laquelle il a.
    var installedVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }
}
