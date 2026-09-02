import BranBackup
import Foundation

/// Lit et écrit `BackupConfiguration` sur disque, et fournit ses valeurs par
/// défaut tant que rien n'a été provisionné.
///
/// **Pourquoi l'écriture atomique n'est pas un détail ici.** Ce fichier
/// gouverne si un run planifié se déclenche cette nuit (`isEnabled`), avec
/// quel seau et quelles règles d'ignore. Une coupure de courant au milieu
/// d'un `Data.write(to:)` ordinaire laisse un JSON à moitié écrit ; au
/// prochain lancement, bran lirait soit une erreur de décodage sur un fichier
/// qui a l'air presque valide, soit — pire — un fragment qui décode par
/// accident avec des champs par défaut de Swift qu'on n'a jamais choisis. Le
/// couple fichier temporaire + `replaceItemAt` garantit que le fichier visible
/// est toujours soit l'ancien, soit le nouveau, jamais un état intermédiaire.
enum BackupConfigurationStore {

    // MARK: - Le chemin

    /// `~/Library/Application Support/bran/backup/config.json`, résolu à
    /// l'exécution — jamais un chemin écrit en dur : le frère du propriétaire
    /// fait tourner la même application, sous un compte différent.
    ///
    /// **Pourquoi `FileManager.urls(for: .applicationSupportDirectory, …)`
    /// plutôt que reconstruire le chemin depuis le dossier personnel.** C'est
    /// la même source que macOS lui-même désigne comme dossier de support de
    /// cette session ; la recalculer à la main depuis
    /// `homeDirectoryForCurrentUser` serait une deuxième vérité, qui diverge
    /// le jour où un profil MDM redirige l'un des deux sans redirger l'autre.
    static func configurationURL() throws -> URL {
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else {
            throw Failure.applicationSupportUnavailable
        }
        return support.appending(path: "bran/backup/config.json", directoryHint: .notDirectory)
    }

    // MARK: - Lire

    /// Rend la configuration enregistrée, ou les valeurs par défaut si rien
    /// n'a encore été écrit.
    ///
    /// **Ne confond jamais « rien n'existe » et « ça existe et c'est
    /// corrompu ».** Le premier cas est celui d'un premier lancement — les
    /// valeurs par défaut conviennent. Le second est une erreur nommée : y
    /// répondre aussi par les valeurs par défaut ferait disparaître un seau et
    /// des clés déjà saisis sans que personne ne l'ait demandé, en silence.
    static func load() throws -> BackupConfiguration {
        let url = try configurationURL()
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            return defaultConfiguration()
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw Failure.unreadable(underlying: error)
        }

        do {
            return try JSONDecoder().decode(BackupConfiguration.self, from: data)
        } catch {
            throw Failure.corrupted(underlying: error)
        }
    }

    // MARK: - Écrire

    /// Écrit la configuration, atomiquement.
    ///
    /// Le fichier temporaire est déposé **dans le même dossier** que la
    /// cible — jamais dans `FileManager.default.temporaryDirectory`, qui peut
    /// être un volume différent. `replaceItemAt` dégrade en copie
    /// interruptible quand la source et la destination ne partagent pas le
    /// même système de fichiers ; les mettre côte à côte dès le départ est ce
    /// qui garantit un vrai renommage atomique plutôt qu'une copie qu'une
    /// coupure de courant peut surprendre à mi-chemin.
    static func save(_ configuration: BackupConfiguration) throws {
        let url = try configurationURL()
        let directory = url.deletingLastPathComponent()

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw Failure.directoryUnavailable(underlying: error)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(configuration)
        } catch {
            throw Failure.encodingFailed(underlying: error)
        }

        let temporaryURL = directory.appending(
            path: ".config.\(UUID().uuidString).json", directoryHint: .notDirectory
        )
        do {
            try data.write(to: temporaryURL, options: .atomic)
        } catch {
            throw Failure.writeFailed(underlying: error)
        }

        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporaryURL)
        } catch {
            // Le fichier temporaire ne doit pas traîner : une écriture ratée
            // ne doit laisser ni la cible corrompue, ni un débris à côté
            // qu'un `load()` suivant ignorera mais qu'un humain qui fouille le
            // dossier prendrait pour la configuration active.
            try? FileManager.default.removeItem(at: temporaryURL)
            throw Failure.replaceFailed(underlying: error)
        }
    }

    // MARK: - Les valeurs par défaut

    /// Aucun secret, aucune adresse. `isEnabled` reste faux tant que personne
    /// n'a provisionné le dépôt via `BackupProvisioning` — c'est cette valeur,
    /// pas un commentaire, qui empêche un run planifié de partir sur un seau
    /// vide et des identifiants absents.
    static func defaultConfiguration() -> BackupConfiguration {
        BackupConfiguration(
            s3Endpoint: "",
            s3Bucket: "",
            s3Region: "",
            disableTLS: false,
            s3AccessKeyID: "",
            sourcePaths: [FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)],
            ignoreRules: defaultIgnoreRules,
            intervalHours: 48,
            tailscaleMinioNodeName: "",
            minioTailscaleIP: "",
            // Un an sans secteur n'existe pas ; ce plancher existe pour
            // qu'« attendre le secteur » ne devienne jamais, de fait, « ne
            // plus jamais sauvegarder ce Mac » — la panne fondatrice du
            // projet, version batterie plutôt que version réseau.
            onBatteryPolicy: .waitForPower(forceAfterHours: 24),
            // Serré : un maillon réseau mort (Tailscale, TCP, santé MinIO)
            // doit se voir en quelques secondes, pas retarder tout le
            // diagnostic derrière lui.
            probeTimeout: 5,
            // Généreux : une ouverture mesurée à 1,2 s peut, d'après le même
            // relevé, monter à une vingtaine de secondes à froid — et le
            // propriétaire travaille parfois depuis un lien plus lent que
            // celui où cette mesure a été prise.
            repositoryTimeout: 45,
            isEnabled: false
        )
    }

    /// Les règles d'ignore par défaut — celles mesurées sur la politique
    /// réelle de ce dépôt, pas une liste générique recopiée d'un
    /// `.gitignore` exemple.
    ///
    /// **Volontairement absents : `.ssh` et tout dossier de secrets.** Le
    /// dépôt est chiffré de bout en bout ; ce sont précisément les fichiers
    /// qu'on veut pouvoir retrouver si ce Mac disparaît.
    static let defaultIgnoreRules: [String] = [
        "*.log", "*.pyc", ".DS_Store", ".docker", ".mypy_cache", ".next",
        ".nuxt", ".parcel-cache", ".pytest_cache", ".ruff_cache",
        ".svelte-kit", ".turbo", ".venv", ".vite", "__pycache__",
        "build", "coverage", "dist", "node_modules", "out", "target",
        "vendor", "venv",
    ]

    // MARK: - Les échecs

    enum Failure: Error, CustomStringConvertible {
        case applicationSupportUnavailable
        case directoryUnavailable(underlying: Error)
        case unreadable(underlying: Error)
        case corrupted(underlying: Error)
        case encodingFailed(underlying: Error)
        case writeFailed(underlying: Error)
        case replaceFailed(underlying: Error)

        var description: String {
            switch self {
            case .applicationSupportUnavailable:
                "macOS ne rend aucun dossier de support applicatif pour cette session."
            case .directoryUnavailable(let underlying):
                "Le dossier de configuration de la sauvegarde est inaccessible : \(underlying)."
            case .unreadable(let underlying):
                "config.json existe mais n'a pas pu être lu : \(underlying)."
            case .corrupted(let underlying):
                "config.json existe mais n'est pas une configuration valide : \(underlying)."
            case .encodingFailed(let underlying):
                "La configuration n'a pas pu être mise en JSON : \(underlying)."
            case .writeFailed(let underlying):
                "Le fichier temporaire de configuration n'a pas pu être écrit : \(underlying)."
            case .replaceFailed(let underlying):
                "La configuration n'a pas pu être remplacée atomiquement : \(underlying)."
            }
        }
    }
}
