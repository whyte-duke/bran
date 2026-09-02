import BranBackup
import Foundation

// Le raccord entre des pièces écrites séparément : le trousseau d'un côté, le
// pilote Kopia de l'autre, et la configuration qui dit où pointer.
//
// **Pourquoi ce fichier existe plutôt qu'un appel direct.** `KopiaDriver` ne
// lit pas le trousseau, et c'est délibéré : il reçoit un fournisseur de mot de
// passe. Ça le rend utilisable sous test avec un secret fabriqué, et ça garantit
// surtout qu'il n'existe **qu'un seul endroit** dans le programme qui sache
// aller chercher la clé de chiffrement. Un pilote qui lirait lui-même le
// trousseau en ferait deux.

/// Le mot de passe de dépôt, lu au trousseau puis retenu pour la durée du
/// processus.
///
/// ## Le cache est un arbitrage, et il a changé de sens
///
/// Il n'y en avait pas au départ, avec un argument qui se défendait : garder la
/// clé de chiffrement de bout en bout dans l'espace d'adressage de
/// l'application toute sa vie durant, c'est l'exposer à un vidage mémoire pour
/// épargner quelques millisecondes sur un run qui dure des heures.
///
/// **Ce que l'usage réel a montré coûte plus cher que ça.** Le maillon 6 rouvre
/// le dépôt toutes les dix minutes, et chaque ouverture relisait le trousseau.
/// Sur une application signée localement — dont la signature change à chaque
/// construction, ce qui invalide l'autorisation accordée à l'entrée — macOS
/// repose sa question à chaque fois. Le propriétaire a vu la fenêtre « bran veut
/// accéder au trousseau » revenir en boucle.
///
/// Une alerte de sécurité qui revient toutes les dix minutes n'est pas une
/// protection : c'est un entraînement à cliquer « Autoriser » sans lire, sur
/// toutes les alertes, y compris celles qui comptent. Le cache est donc le
/// choix le plus sûr des deux — et il est borné au processus : il ne survit ni
/// à une fermeture de l'application, ni au job launchd, qui en démarre un neuf
/// à chaque réveil.
struct KeychainKopiaPassword: KopiaPasswordProviding {

    /// Le cache, partagé par toutes les instances du processus.
    private static let cache = PasswordCache()

    private final class PasswordCache: @unchecked Sendable {
        private let lock = NSLock()
        private var value: String?

        func read() -> String? {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func store(_ password: String) {
            lock.lock()
            value = password
            lock.unlock()
        }
    }

    /// Oublie le mot de passe retenu. Appelé quand il vient d'être remplacé :
    /// continuer à présenter l'ancien ferait échouer l'ouverture du dépôt avec
    /// un message d'authentification incompréhensible, juste après une saisie
    /// que l'utilisateur sait correcte.
    static func forget() {
        cache.store("")
    }

    func kopiaPassword() async throws -> String {
        if let cached = Self.cache.read(), !cached.isEmpty { return cached }

        switch BackupSecrets.read(.repositoryPassword) {
        case .found(let password):
            Self.cache.store(password)
            return password

        case .absent:
            // Rien au trousseau : la sauvegarde n'a jamais été provisionnée sur
            // ce Mac, ou quelqu'un a retiré l'entrée. Un message qui dit quoi
            // faire, pas un code d'erreur.
            throw BackupWiringFailure.repositoryPasswordMissing

        case .denied(let error):
            // **Le cas qui compte, et celui qu'on aurait avalé.** Le trousseau
            // existe mais refuse de répondre — verrouillé, interaction non
            // permise. Le confondre avec une absence ferait redemander à
            // l'utilisateur une clé qui n'a jamais bougé, et ferait échouer la
            // sauvegarde planifiée toutes les nuits en annonçant « pas
            // configuré ».
            throw BackupWiringFailure.repositoryPasswordUnreadable(error)
        }
    }
}

/// Ce qui peut manquer entre la configuration, le trousseau et le binaire.
enum BackupWiringFailure: Error, CustomStringConvertible {
    case repositoryPasswordMissing
    case repositoryPasswordUnreadable(BackupSecretsError)

    var description: String {
        switch self {
        case .repositoryPasswordMissing:
            """
            Le mot de passe du dépôt n'est pas enregistré sur ce Mac. \
            Ouvrez les réglages de sauvegarde pour le saisir — c'est la clé de \
            chiffrement du dépôt, et personne d'autre ne peut la fournir.
            """
        case .repositoryPasswordUnreadable(let error):
            """
            Le trousseau a refusé de rendre le mot de passe du dépôt \
            (\(error.description)). Ce n'est pas une absence : la clé est \
            probablement là, mais le trousseau est verrouillé ou l'accès a été \
            refusé. Aucune sauvegarde n'est lancée tant que ce n'est pas levé.
            """
        }
    }
}

/// Fabrique le pilote pour la configuration en vigueur.
enum BackupEngine {

    /// Le pilote prêt à parler au dépôt de ce Mac.
    ///
    /// Le binaire est cherché dans le paquet de l'application — `build-app.sh`
    /// l'y dépose et le signe, donc c'est le seul dont on sache qu'il est celui
    /// qu'on a testé. `configuredPath` reste ouvert pour le développement, où
    /// l'exécutable de SwiftPM n'a pas de paquet autour de lui.
    static func driver(configuredKopiaPath: String? = nil) throws -> KopiaDriver {
        let executable = try KopiaExecutable.locate(configuredPath: configuredKopiaPath)
        return KopiaDriver(
            executable: executable,
            configFileURL: nil,
            passwordProvider: KeychainKopiaPassword()
        )
    }
}
