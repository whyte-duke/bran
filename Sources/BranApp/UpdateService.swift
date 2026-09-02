import Foundation
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

    /// Le garde. Retenu ici parce que Sparkle ne tient son delegate que
    /// faiblement : sans cette référence, il disparaîtrait aussitôt construit et
    /// le verrou ci-dessous n'existerait plus qu'en intention.
    @ObservationIgnored
    private let guardian = SessionGuard()

    /// **L'accroche : « bran a-t-il quelque chose à perdre en ce moment ? ».**
    ///
    /// Vrai pendant la capture *et* pendant la finalisation. La finalisation
    /// compte au moins autant que la capture, et c'est mesuré sur ce projet :
    /// ScreenCaptureKit écrit **93 % du fichier après `stopCapture()`**, et
    /// cette écriture a duré **douze minutes sur une réunion de trente-six**.
    /// Une relance dans cette fenêtre-là ne coûte pas quelques secondes de
    /// vidéo, elle coûte la réunion entière — et l'`Info.plist` publie
    /// `SUAutomaticallyUpdate` à `true`, donc l'installation se fait sans rien
    /// demander à personne.
    ///
    /// C'est une fermeture et pas une dépendance : `UpdateService` n'a pas à
    /// savoir ce qu'est une réunion, et le moteur n'a pas à savoir qu'un
    /// vérificateur de mises à jour existe. C'est la même mécanique que le
    /// veilleur de sessions et que le dossier de destination de la dictée.
    ///
    /// **Ce qu'il faut y brancher est `AppModel.showsSessionBar`, et surtout
    /// pas `hasOpenSession`.** Ce dernier devient faux à l'instant où la machine
    /// repasse au repos, c'est-à-dire juste avant que la fusion, la compression
    /// et l'extraction de l'audio commencent — plusieurs dizaines de minutes de
    /// travail réel sur une réunion de trente-six. Le dépôt s'est déjà fait
    /// prendre deux fois par cette nuance : la barre de session, puis le
    /// rangement des anciens dossiers, qui déplaçait des fichiers sous une
    /// compression en cours.
    ///
    /// Tant que personne ne la branche, elle répond `false` : le comportement
    /// est alors exactement celui d'avant, sans verrou.
    @ObservationIgnored
    var hasSomethingToLose: @MainActor () -> Bool {
        get { guardian.hasSomethingToLose }
        set { guardian.hasSomethingToLose = newValue }
    }

    /// **Sans `@ObservationIgnored`, ce champ ferait redessiner l'interface à
    /// chaque battement de la minuterie de Sparkle.** Rien de ce qu'il contient
    /// n'est affiché : ce qui se voit, c'est la fenêtre que Sparkle présente
    /// lui-même.
    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: guardian,
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

/// **Aucune mise à jour ne s'installe pendant qu'une réunion est en jeu.**
///
/// Ce que Sparkle faisait sans ce garde : `SUAutomaticallyUpdate` à `true` et
/// une vérification par heure, sans delegate, donc sans la moindre idée de ce
/// que fait le reste de l'application. Une mise à jour qui finit de s'installer
/// pendant une réunion propose la relance ; la relance tue le processus ; et
/// si elle tombe pendant la finalisation, elle emporte les 93 % du fichier que
/// ScreenCaptureKit écrit *après* `stopCapture()` — douze minutes de rédaction
/// sur une réunion de trente-six, mesurées sur ce projet.
///
/// Trois portes, parce qu'une seule ne suffit pas : la vérification de fond
/// peut avoir commencé **avant** que l'enregistrement démarre, et la relance
/// peut être proposée bien après le téléchargement.
///
/// 1. On ne **cherche** pas de mise à jour en tâche de fond pendant une
///    session. La vérification demandée à la main, elle, reste permise : elle
///    répond à une question que quelqu'un vient de poser, et elle n'installe
///    rien toute seule.
/// 2. On ne **poursuit** pas une mise à jour de fond trouvée entre-temps.
/// 3. On ne **relance** pas : la relance est repoussée jusqu'au retour au
///    repos, et elle a lieu toute seule à ce moment-là.
///
/// Ce que ça concède : une session laissée ouverte indéfiniment repousse une
/// mise à jour indéfiniment. C'est le bon sens de l'échange — une mise à jour
/// en retard se rattrape, un enregistrement détruit ne se rattrape pas — mais
/// la relance en attente n'est visible nulle part, et c'est le point à
/// surveiller.
@MainActor
private final class SessionGuard: NSObject, SPUUpdaterDelegate {

    /// Branché par `AppModel`. Voir `UpdateService.hasSomethingToLose`.
    var hasSomethingToLose: @MainActor () -> Bool = { false }

    /// À quelle cadence on regarde si la session est finie, une fois la relance
    /// repoussée. Cinq secondes : la finalisation se compte en minutes, et
    /// quelques secondes de retard sur une relance n'ont jamais gêné personne.
    private static let idleCheckInterval = Duration.seconds(5)

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard updateCheck == .updatesInBackground, hasSomethingToLose() else { return }
        throw Refusal.sessionInProgress
    }

    func updater(
        _ updater: SPUUpdater,
        shouldProceedWithUpdate updateItem: SUAppcastItem,
        updateCheck: SPUUpdateCheck
    ) throws {
        guard updateCheck == .updatesInBackground, hasSomethingToLose() else { return }
        throw Refusal.sessionInProgress
    }

    /// **L'étiquette est `untilInvokingBlock`, et se tromper d'un mot rendait
    /// tout ce correctif inerte.**
    ///
    /// L'en-tête de Sparkle déclare
    /// `updater:shouldPostponeRelaunchForUpdate:untilInvokingBlock:`. Écrite
    /// `untilInvoking:`, la méthode ne conforme à rien : le protocole n'exige
    /// pas ce membre — il est optionnel —, donc **rien n'échoue à la
    /// compilation**. Sparkle ne l'appelle jamais, la relance n'est jamais
    /// repoussée, et l'enregistrement en finalisation est perdu comme avant.
    ///
    /// Le compilateur le disait pourtant, en avertissement et non en erreur :
    /// « nearly matches optional requirement ». C'est exactement le genre de
    /// ligne qu'un `swift build` bruyant enterre.
    func updater(
        _ updater: SPUUpdater,
        shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        guard hasSomethingToLose() else { return false }

        FeatureLog.record(
            "Mise à jour prête, relance repoussée : un enregistrement est en cours ou en finalisation."
        )
        Task { @MainActor in
            while hasSomethingToLose() {
                try? await Task.sleep(for: Self.idleCheckInterval)
            }
            FeatureLog.record("Session terminée — relance pour la mise à jour.")
            installHandler()
        }
        return true
    }

    /// L'erreur que Sparkle attend pour dire non. Son texte n'est jamais
    /// affiché à l'utilisateur — Sparkle abandonne silencieusement une
    /// vérification de fond refusée — mais il part dans son journal, où il vaut
    /// mieux qu'il soit lisible.
    private enum Refusal: LocalizedError {
        case sessionInProgress

        var errorDescription: String? {
            "Un enregistrement est en cours ou en cours de finalisation : mise à jour repoussée."
        }
    }
}
