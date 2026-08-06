import Foundation

/// **L'identité d'une voie** — le problème que le plan désignait comme son
/// blocage numéro un.
///
/// Ni une fenêtre, ni un processus : une unité de travail qui doit survivre à un
/// changement de titre, à la fermeture puis réouverture d'une fenêtre, et à un
/// redémarrage. Sans elle, « ramène-moi sur la session backend » n'a pas de
/// sens, donc il n'y a pas de produit.
///
/// **Ce qui l'a débloquée** : les transcriptions de Claude Code portent `cwd`,
/// `gitBranch` et `sessionId` au premier niveau de chaque ligne. Un dossier de
/// projet plus une branche, c'est stable, c'est persistant, et surtout c'est
/// *dicible* : « la session backend CRM Castral » est littéralement
/// `castral/crm` sur `feat/recorder-api`.
///
/// Pour les tribus sans identifiant — un onglet `claude.ai`, l'app de bureau —
/// on retombe sur une clé composite dérivée du titre. Moins stable, et c'est
/// assumé : `precision` le dit.
public struct LaneIdentity: Hashable, Sendable, Codable {

    /// D'où vient l'identité. Détermine ce qu'on a le droit d'en conclure.
    public enum Precision: Int, Sendable, Codable, Comparable {
        /// Titre de fenêtre seul. Change quand l'utilisateur change d'onglet.
        case fragile = 0
        /// Application + dossier de travail déduit. Tient un redémarrage.
        case stable = 1
        /// Identifiant de session fourni par l'outil lui-même. Certain.
        case exact = 2

        public static func < (lhs: Precision, rhs: Precision) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    public let key: String
    public let precision: Precision

    /// Ce que l'humain lit dans l'alerte. Jamais un chemin complet : « la voie
    /// qui attend » doit se reconnaître d'un coup d'œil, pas se déchiffrer.
    public let displayName: String

    /// Le dossier de travail, quand on le connaît. Sert au geste de retour.
    public let workingDirectory: String?
    public let branch: String?

    public init(
        key: String,
        precision: Precision,
        displayName: String,
        workingDirectory: String? = nil,
        branch: String? = nil
    ) {
        self.key = key
        self.precision = precision
        self.displayName = displayName
        self.workingDirectory = workingDirectory
        self.branch = branch
    }

    /// Une session Claude Code, identifiée par son propre outil.
    ///
    /// La clé est le **dossier**, pas l'identifiant de session : reprendre une
    /// session avec `--resume` produit un nouvel identifiant pour le même
    /// travail, et l'utilisateur, lui, considère que c'est la même voie.
    public static func claudeCode(
        sessionID: String,
        workingDirectory: String,
        branch: String
    ) -> LaneIdentity {
        LaneIdentity(
            key: "cc:\(workingDirectory)",
            precision: .exact,
            displayName: Self.shortName(for: workingDirectory, branch: branch),
            workingDirectory: workingDirectory,
            branch: branch
        )
    }

    /// Une fenêtre quelconque : navigateur, application de bureau, terminal sans
    /// transcription lisible.
    ///
    /// **Le titre nettoyé n'est pas seulement la clé, il est parfois l'aveu du
    /// travail.** Un titre de terminal nomme la machine — `root@kvm4` — jamais
    /// ce qu'on y fait, et le même serveur porte souvent trois chantiers. Le
    /// seul remède honnête est de demander au shell distant d'écrire la vérité :
    /// c'est le rôle du fragment `precmd` documenté dans le README, qui fait
    /// écrire « scanner · feat/ocr ». Quand ce titre-là arrive, on cesse de
    /// deviner et la précision monte d'un cran.
    public static func window(
        bundleIdentifier: String?,
        applicationName: String,
        title: String
    ) -> LaneIdentity {
        let stable = Self.stableTitle(title)
        let key = "win:\(bundleIdentifier ?? applicationName):\(stable)"

        guard let work = Self.declaredWork(in: stable) else {
            return LaneIdentity(
                key: key,
                precision: .fragile,
                displayName: title.isEmpty ? applicationName : title
            )
        }

        return LaneIdentity(
            key: key,
            precision: .stable,
            displayName: stable,
            workingDirectory: work.folder,
            branch: work.branch
        )
    }

    /// Le titre qu'un shell instrumenté écrit lui-même : « scanner · feat/ocr ».
    ///
    /// Le séparateur est celui de `shortName(for:branch:)`, et ce n'est pas une
    /// coïncidence : les deux nomment la même chose, l'une depuis une
    /// transcription lue en local, l'autre depuis un shell à l'autre bout d'un
    /// `ssh` où aucune transcription n'est lisible.
    ///
    /// **Pourquoi ça vaut `.stable` et pas `.exact`.** Le titre survit à un
    /// redémarrage de l'émulateur et à un redimensionnement, donc il dépasse
    /// `.fragile`. Mais rien ne garantit qu'un autre programme n'écrira pas le
    /// même titre, et changer de branche change bien de voie — ce qui est
    /// correct, mais reste une déduction et non une déclaration de session.
    ///
    /// Les gardes contre le hasard : exactement un séparateur, et une branche
    /// sans espace. Un nom de branche git n'en contient pas ; une phrase
    /// française qui utiliserait « · » comme puce en contient toujours.
    static func declaredWork(in title: String) -> (folder: String, branch: String)? {
        let parts = title.components(separatedBy: " · ")
        guard parts.count == 2 else { return nil }

        let folder = parts[0].trimmingCharacters(in: .whitespaces)
        let branch = parts[1].trimmingCharacters(in: .whitespaces)
        guard folder.isEmpty == false, branch.isEmpty == false,
              branch.contains(" ") == false
        else { return nil }

        return (folder, branch)
    }

    /// « /Users/x/Documents/…/castral/crm » + « feat/recorder-api »
    /// devient « crm · feat/recorder-api ».
    static func shortName(for path: String, branch: String) -> String {
        let folder = path.split(separator: "/").last.map(String.init) ?? path
        guard branch.isEmpty == false, branch != "HEAD" else { return folder }
        return "\(folder) · \(branch)"
    }

    /// Retire d'un titre ce qui bouge tout seul, pour qu'une même fenêtre garde
    /// la même clé : compteurs de notification, indicateur de modification,
    /// caractères d'animation d'un spinner, géométrie de l'émulateur, drapeaux
    /// de tmux.
    ///
    /// Sans ça, un titre qui passe de « ⠂ Compilation » à « ⠄ Compilation »
    /// crée une nouvelle voie à chaque tic, et la file d'attente se remplit de
    /// fantômes.
    ///
    /// Les règles vivent dans `TitleNoise`, chacune nommée et justifiée par
    /// l'émulateur qu'elle vise. Elles n'ont pas leur place ici : ce type dit ce
    /// qu'est une voie, pas ce qu'un terminal a l'habitude d'écrire.
    public static func stableTitle(_ title: String) -> String {
        TitleNoise.strip(title)
    }
}
