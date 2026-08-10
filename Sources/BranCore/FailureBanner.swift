import Foundation

/// Le fil des motifs d'échec affichés à l'utilisateur.
///
/// bran n'a qu'un canal pour dire ce qui a raté, et c'est délibéré. Mais ce
/// canal était une simple affectation : deux pannes dans la même seconde — un
/// arrêt qui échoue, puis des segments que le disque refuse de supprimer — et la
/// seconde effaçait la première avant que personne ne l'ait lue.
///
/// L'accumulation sans limite serait pire : un dossier en lecture seule fait
/// échouer une écriture à chaque frappe dans le champ « titre », et le bandeau
/// deviendrait un mur. D'où la capacité fixe et le dédoublonnage.
///
/// ## Accumulateur ou emplacements nommés
///
/// bran contient deux façons de tenir « un canal, plusieurs pannes ». Elles ne
/// sont pas en concurrence, et la troisième qu'on serait tenté d'écrire est
/// presque toujours l'une des deux. La question à se poser n'est pas « combien
/// de messages » mais **qui les efface, et quand** :
///
/// - **Un accumulateur** — celui-ci — pour des échecs passagers venus de
///   sources nombreuses et non énumérables, dont aucun n'a de durée de vie
///   propre. Ils s'effacent tous ensemble, à la prochaine action de
///   l'utilisateur, et le seul risque est qu'ils se chassent l'un l'autre :
///   c'est ce que la file bornée et le dédoublonnage règlent.
///
/// - **Des emplacements nommés** pour un petit ensemble fixe de catégories qui
///   s'effacent sur des événements *différents*. Là, il ne suffit pas de garder
///   les messages : il faut savoir lequel retirer.
///
/// Le cas d'école du second est `WatchStore`, et il montre exactement ce que le
/// premier y aurait cassé. Il tient deux pannes : l'écriture du journal, et la
/// rétention. `reload()` efface la panne d'écriture dès qu'une lecture repasse
/// — et la purge appelle `reload()` juste derrière elle. Avec un accumulateur,
/// l'avertissement de rétention aurait donc disparu dans la milliseconde qui
/// suit sa pose : un silence de plus, exactement du type que ce fichier existe
/// pour supprimer. Deux champs séparés, chacun effacé par le retour de *sa*
/// réussite, et les deux messages coexistent sans jamais s'annuler.
public enum FailureBanner {

    /// Deux lignes. Le bandeau en affiche deux, et au-delà personne ne lit.
    public static let capacity = 2

    public static func appending(_ message: String, to existing: String?) -> String {
        var lines = (existing?.components(separatedBy: "\n") ?? [])
            .filter { $0.isEmpty == false && $0 != message }
        lines.append(message)
        return lines.suffix(capacity).joined(separator: "\n")
    }
}
