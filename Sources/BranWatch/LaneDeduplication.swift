import Foundation

/// **Le dédoublonnage entre un capteur certain et une voie devinée aux pixels.**
///
/// Le cas visé : un terminal qui fait tourner `claude` dans `castral/crm`
/// s'intitule « crm — claude — 120×30 ». La transcription donne déjà une voie
/// pour ce travail, avec son dossier et sa branche ; les pixels en fabriqueraient
/// une seconde pour la même chose — une qui sait ce qu'elle fait, une qui devine.
/// L'utilisateur verrait deux lignes, dont une qui n'existe pas.
///
/// **L'heuristique est fragile, et le choix qu'elle impose l'est aussi.** En cas
/// de doute on **cache** le doublon plutôt que de montrer deux fois la même
/// chose : une fenêtre légitimement nommée comme un dossier suivi disparaît de
/// la liste tant que la session est vivante, et réapparaît ensuite. Fabriquer
/// une voie fantôme coûte plus cher que d'en masquer une — la première déclenche
/// des alertes que rien ne justifie, la seconde ne fait que taire une voie dont
/// le vrai jumeau est déjà affiché.
public enum LaneDeduplication {

    /// Les noms de dossier des voies connues de façon certaine.
    ///
    /// Le dernier segment seulement, en minuscules : c'est ce qu'un terminal ou
    /// un éditeur met dans son titre. Le chemin complet n'y apparaît jamais.
    public static func folderNames(of identities: some Sequence<LaneIdentity>) -> Set<String> {
        Set(identities.compactMap { $0.workingDirectory.map(folderName) })
    }

    /// « /Users/x/Documents/castral/crm » → « crm ».
    public static func folderName(_ path: String) -> String {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        return (trimmed.split(separator: "/").last.map(String.init) ?? trimmed).lowercased()
    }

    /// Cette voie observée à l'image est-elle **autre chose** qu'une voie déjà
    /// connue de façon certaine ?
    ///
    /// Un dossier au nom vide ne masque rien : `"".contains` est vrai pour tout
    /// titre, et une seule entrée vide ferait disparaître la liste entière.
    public static func isDistinct(_ identity: LaneIdentity, from folders: Set<String>) -> Bool {
        let title = identity.displayName.lowercased()
        return folders.contains { $0.isEmpty == false && title.contains($0) } == false
    }
}
