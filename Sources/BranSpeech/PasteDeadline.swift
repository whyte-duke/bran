import Foundation
import Synchronization

/// Le moment où bran cesse d'attendre le presse-papiers, et le jeton qui fait
/// qu'une seule des deux issues sera racontée.
///
/// **Le problème.** Écrire le presse-papiers passe par une file série, parce
/// que bran ne doit pas se courir après (`Paster`, point 8). Sur cette même
/// file peut dormir une lecture bloquée dans un XPC synchrone vers
/// `pasteboardd` — pièce jointe de Mail, rendu de Photoshop, presse-papiers
/// universel qui tire depuis l'iPhone (point 6). **Rien dans Swift ne peut
/// interrompre cet appel** : ni `Task.cancel()`, ni la mort de la tâche, ni un
/// délai. Un appel synchrone en cours va jusqu'à son terme, et l'écriture
/// derrière lui attend aussi longtemps que l'application source reste
/// coincée — des secondes, des minutes.
///
/// Ce qu'on ne peut donc pas faire : l'interrompre. Ce qu'on peut faire :
/// **arrêter de l'attendre, et dire la vérité sur ce qui s'est passé.**
///
/// ## Deux coureurs, un seul vainqueur
///
/// À partir du moment où l'écriture est postée, deux choses peuvent arriver en
/// premier, et elles vivent dans deux domaines d'isolation différents :
///
/// - l'écriture atteint la file et touche le presse-papiers ;
/// - le minuteur du main actor expire.
///
/// Les deux veulent répondre à l'appelant, et l'appelant ne doit être répondu
/// **qu'une fois** : deux réponses feraient avancer deux fois une machine à
/// états qui n'a qu'une transition à faire. Comparer deux horloges — l'une sur
/// le main actor, l'autre sur la file — ne suffit pas : entre « il reste 1 ms »
/// et « j'écris » il y a un intervalle, et les deux côtés peuvent le traverser
/// en même temps.
///
/// D'où ce jeton. `claim()` réussit **une seule fois**, quel que soit le nombre
/// de fils qui la demandent. Le vainqueur possède l'issue : c'est lui qui parle
/// à l'appelant, et c'est lui seul. Le perdant se retire sans un mot.
///
/// `Mutex` et non un acteur : la prise doit se faire depuis le main actor
/// *sans* `await` — attendre un acteur, c'est rouvrir très exactement le trou
/// qu'on est en train de fermer. Sous verrou il n'y a qu'une lecture et une
/// écriture de `Bool`, quelques nanosecondes, jamais de contention réelle.
///
/// ## Ce que la défaite veut dire pour l'écriture
///
/// Quand c'est le minuteur qui gagne, l'écriture qui se réveille plus tard
/// trouve le jeton pris et **renonce à écrire**. Ce n'est pas un effet de bord,
/// c'est la décision : on a dit à l'utilisateur que le texte n'était pas parti,
/// donc il ne doit pas partir. Le faire quand même remplirait son presse-papiers
/// d'une dictée d'il y a deux minutes, par-dessus ce qu'il a copié depuis, sans
/// que rien ne l'annonce — le pire des deux mondes, puisqu'on lui a affirmé le
/// contraire.
///
/// Renoncer ne perd pas le texte : la dictée comme la capture écrivent leur
/// entrée dans l'historique **avant** de la livrer, et l'historique a un bouton
/// « copier ». C'est ce qui rend ce choix tenable, et c'est ce que le message
/// affiché doit dire.
public final class PasteDeadline: Sendable {

    /// Combien de temps on laisse au presse-papiers avant de renoncer.
    ///
    /// **0,5 s, et le choix se défend des deux côtés.**
    ///
    /// *Trop court, jamais.* Une écriture saine coûte des microsecondes : le
    /// délai est quatre ordres de grandeur au-dessus, il ne peut pas se
    /// déclencher sur un chemin sain. Et l'attente qu'il couvre n'est pas celle
    /// de la lecture : celle-ci démarre à l'appui sur le raccourci et a devant
    /// elle **toute la durée de la dictée ou de la reconnaissance** — des
    /// secondes — pour aboutir. Une lecture encore en cours au moment où
    /// l'écriture est postée n'est pas une lecture lente, c'est une lecture
    /// coincée. Lui donner une seconde de plus ne la débloquerait pas.
    ///
    /// *Trop long, non plus.* Au-delà, l'utilisateur regarde une encoche qui
    /// dit « collage en cours » sans savoir si ça va aboutir, et la seule chose
    /// qu'il puisse faire — refaire ⌘V, recommencer sa dictée — est justement ce
    /// qu'il ne faut pas faire.
    ///
    /// *Pourquoi 500 ms exactement.* C'est déjà le budget que
    /// `ClipboardMachine.budget` accorde à `pasteboardd` avant de trancher.
    /// La question y est différente — « cette frappe était-elle une copie ? » —
    /// mais la mesure est la même : combien de temps le presse-papiers a le
    /// droit de ne pas répondre avant qu'on décide sans lui. Un seul nombre pour
    /// cette question dans tout le programme vaut mieux que deux qui dériveront.
    public static let grace: Duration = .milliseconds(500)

    /// Le même délai en secondes, pour les API qui n'ont pas de `Duration` —
    /// `DispatchQueue.asyncAfter` en particulier.
    public static var graceInSeconds: TimeInterval { seconds(grace) }

    /// Conversion exposée pour elle-même : elle a une division par 10¹⁸ dedans,
    /// et une erreur d'un facteur mille sur un délai ne se voit pas à la
    /// lecture.
    public static func seconds(_ duration: Duration) -> TimeInterval {
        let parts = duration.components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }

    private let taken = Mutex(false)

    public init() {}

    /// Prend possession de l'issue. Rend `true` **au premier appelant
    /// seulement** ; tous les suivants reçoivent `false` et doivent se taire.
    public func claim() -> Bool {
        taken.withLock { alreadyTaken in
            if alreadyTaken { return false }
            alreadyTaken = true
            return true
        }
    }

    /// L'issue est-elle déjà racontée ? À usage de diagnostic et de test : une
    /// décision se prend avec `claim()`, jamais en lisant ceci puis en agissant,
    /// ce qui rouvrirait l'intervalle que le jeton existe pour fermer.
    public var isSettled: Bool { taken.withLock { $0 } }
}
