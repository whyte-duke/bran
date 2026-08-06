import Foundation

/// Ce qu'une clé de voie désigne quand on veut y **revenir**.
///
/// Le geste de retour a deux natures parce que les voies en ont deux, et c'est
/// une asymétrie qu'il faut nommer plutôt que de la lisser :
///
/// - une voie de fenêtre vient de l'écran. On sait quelle application la porte
///   et quel titre elle avait ; il n'y a qu'à la retrouver.
/// - une voie Claude Code vient d'une **transcription**. Elle n'a jamais eu de
///   fenêtre du point de vue de bran : on connaît un dossier de travail et une
///   branche, et c'est tout. Il faut *chercher* la fenêtre.
public enum LaneTarget: Sendable, Equatable {

    /// `win:<identifiantDePaquet|nomApp>:<titreStable>`
    case window(owner: String, stableTitle: String)

    /// `cc:<dossierDeTravail>`
    case workspace(directory: String)

    /// **Le découpage se fait au premier deux-points, jamais au dernier.**
    ///
    /// Un titre stable en contient très souvent — « root@kvm4: ~ » est le cas le
    /// plus banal qui soit — alors qu'un identifiant de paquet n'en contient
    /// jamais. Couper au dernier rendrait un propriétaire absurde et un titre
    /// amputé, et le geste de retour ne trouverait plus rien.
    public init?(key: String) {
        if key.hasPrefix("cc:") {
            let directory = String(key.dropFirst(3))
            guard directory.isEmpty == false else { return nil }
            self = .workspace(directory: directory)
            return
        }

        guard key.hasPrefix("win:") else { return nil }
        let rest = key.dropFirst(4)
        guard let cut = rest.firstIndex(of: ":") else { return nil }

        let owner = String(rest[..<cut])
        guard owner.isEmpty == false else { return nil }
        self = .window(owner: owner, stableTitle: String(rest[rest.index(after: cut)...]))
    }
}

/// Une fenêtre proposée au geste de retour, réduite à ce qui sert à la choisir.
///
/// Pas d'`AXUIElement` ni de `CGWindowID` ici : le choix est de la logique pure,
/// et il doit se tester sans serveur de fenêtres. Le point d'appel garde la
/// correspondance entre ce couple et l'objet système qu'il faudra remonter.
public struct WindowCandidate: Sendable, Hashable {
    /// L'identifiant de paquet quand on l'a, le nom de l'application sinon —
    /// exactement ce que la clé de voie retient.
    public let owner: String
    public let title: String

    public init(owner: String, title: String) {
        self.owner = owner
        self.title = title
    }
}

/// **Choisir la bonne fenêtre parmi celles qui sont ouvertes.**
///
/// C'est la seule partie du geste de retour qui puisse se tromper de façon
/// intéressante — activer la mauvaise fenêtre est pire que de n'en activer
/// aucune, parce que l'utilisateur perd sa place *et* sa confiance. C'est donc
/// la partie qui vit ici, en logique pure, et qui se teste.
public enum WindowChoice {

    /// À quel point cette fenêtre ressemble à la voie cherchée. `nil` quand elle
    /// ne peut pas être la bonne — et « pas de candidate » est une réponse
    /// parfaitement acceptable, que le point d'appel doit savoir dire.
    ///
    /// Les poids sont ordinaux, pas métriques : seul leur ordre compte.
    public static func score(_ candidate: WindowCandidate, for identity: LaneIdentity) -> Int? {
        guard let target = LaneTarget(key: identity.key) else { return nil }

        switch target {
        case .window(let owner, let stableTitle):
            // **Le titre nettoyé est le critère, et pas le titre brut.** C'est
            // ce qui fait qu'une fenêtre redimensionnée entre le verdict et le
            // clic reste retrouvable : la géométrie qui a changé n'est plus
            // dans la comparaison.
            guard LaneIdentity.stableTitle(candidate.title) == stableTitle else { return nil }

            var score = 100
            if sameOwner(owner, candidate.owner) { score += 20 }
            // Départage deux fenêtres au même titre stable : celle qui n'a rien
            // eu à nettoyer est la plus proche de ce qu'on a observé.
            if candidate.title == stableTitle { score += 10 }
            return score

        case .workspace(let directory):
            let folder = LaneDeduplication.folderName(directory)
            guard containsWord(folder, in: candidate.title) else { return nil }

            var score = 50
            // Le chemin complet dans un titre est rare et décisif : un éditeur
            // qui l'affiche ne parle certainement pas d'un autre projet.
            if candidate.title.localizedCaseInsensitiveContains(directory) { score += 25 }
            // La branche départage deux fenêtres du même dossier — deux arbres
            // de travail git, ou deux onglets sur le même projet.
            if let branch = identity.branch, branch.isEmpty == false, branch != "HEAD",
               candidate.title.localizedCaseInsensitiveContains(branch) {
                score += 15
            }
            return score
        }
    }

    /// La meilleure candidate, ou `nil` s'il n'y en a aucune.
    ///
    /// **L'ordre doit être total, et il doit être stable.** Le système énumère
    /// ses fenêtres dans un ordre qui change d'un appel à l'autre ; sans
    /// départage, le même clic ramènerait tantôt l'une, tantôt l'autre, et le
    /// geste de retour deviendrait quelque chose qu'on n'ose plus utiliser. À
    /// score égal, le titre le plus court gagne — c'est celui qui porte le moins
    /// de contenu étranger au dossier cherché — puis l'ordre alphabétique
    /// tranche, faute de mieux, mais toujours de la même façon.
    public static func best(
        among candidates: [WindowCandidate],
        for identity: LaneIdentity
    ) -> WindowCandidate? {
        let scored = candidates.compactMap { candidate -> (candidate: WindowCandidate, score: Int)? in
            guard let score = score(candidate, for: identity) else { return nil }
            return (candidate, score)
        }

        return scored.max { left, right in
            if left.score != right.score { return left.score < right.score }
            if left.candidate.title.count != right.candidate.title.count {
                return left.candidate.title.count > right.candidate.title.count
            }
            return left.candidate.title > right.candidate.title
        }?.candidate
    }

    // MARK: - Les deux comparaisons délicates

    /// « crm » ne doit pas se reconnaître dans « crmsoftware.com ».
    ///
    /// Sans cette garde, un onglet de navigateur ouvert sur la page d'un
    /// homonyme volerait le geste de retour d'une session Claude Code, et
    /// l'utilisateur atterrirait dans son navigateur en pensant revenir sur son
    /// terminal. Un nom de dossier compte donc comme un **mot** : ce qui
    /// l'entoure ne doit être ni lettre ni chiffre.
    static func containsWord(_ needle: String, in haystack: String) -> Bool {
        guard needle.isEmpty == false else { return false }

        var search = haystack.startIndex..<haystack.endIndex
        while let range = haystack.range(of: needle, options: .caseInsensitive, range: search) {
            let openBefore = range.lowerBound == haystack.startIndex
                || isBoundary(haystack[haystack.index(before: range.lowerBound)])
            let openAfter = range.upperBound == haystack.endIndex
                || isBoundary(haystack[range.upperBound])

            if openBefore, openAfter { return true }
            guard range.upperBound < haystack.endIndex else { return false }
            search = haystack.index(after: range.lowerBound)..<haystack.endIndex
        }
        return false
    }

    private static func isBoundary(_ character: Character) -> Bool {
        character.isLetter == false && character.isNumber == false
    }

    /// « com.apple.Terminal » et « Terminal » désignent la même application.
    ///
    /// La clé retient l'identifiant de paquet quand le système le donne, et le
    /// nom quand il ne le donne pas ; l'énumération des fenêtres, elle, ne donne
    /// pas toujours le même des deux. Comparer les deux formes évite de perdre
    /// un bonus sur une simple différence de source — et ce n'est **qu'un
    /// bonus** : le propriétaire ne filtre rien, il départage.
    static func sameOwner(_ left: String, _ right: String) -> Bool {
        if left.compare(right, options: .caseInsensitive) == .orderedSame { return true }
        let leftTail = left.split(separator: ".").last.map(String.init) ?? left
        let rightTail = right.split(separator: ".").last.map(String.init) ?? right
        return leftTail.compare(rightTail, options: .caseInsensitive) == .orderedSame
    }
}
