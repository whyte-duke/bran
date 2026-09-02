import Foundation
import Security

/// Le trousseau des deux secrets de la sauvegarde — **et rien d'autre n'écrit
/// sous ce service.** `BackupConfiguration` (voir `BackupContract.swift`) est
/// sérialisée en clair à côté, dans `BackupConfigurationStore` ; ce fichier
/// porte précisément ce qui ne peut pas l'être : la clé secrète S3, et le mot
/// de passe de dépôt Kopia, qui est aussi la clé de chiffrement de bout en
/// bout du dépôt.
///
/// **Pourquoi un service distinct de celui du CRM (`CRM/Keychain.swift`).**
/// Les deux trousseaux n'ont rien en commun — durées de vie différentes,
/// personnes différentes qui les liront un jour en cas de panne — et les
/// mélanger sous le même `service` ferait qu'une purge du jeton CRM et une
/// purge d'un secret de sauvegarde partageraient une même surface d'erreur
/// pour deux fonctionnalités qui n'ont aucune raison de se connaître.
///
/// ## Pourquoi ni `kSecUseDataProtectionKeychain` ni un `kSecAttrAccess` explicite
///
/// Les deux ont été examinés comme correctifs à la fenêtre « bran veut accéder
/// au trousseau », et aucun des deux n'est retenu — pour des raisons vérifiées,
/// pas supposées.
///
/// **`kSecUseDataProtectionKeychain`.** Sa documentation Apple est explicite :
/// il fait basculer l'élément du modèle historique — une liste d'applications
/// de confiance, construite depuis l'identité de code de l'appelant — vers le
/// modèle par « groupe d'accès » d'iOS, où l'appartenance se décide par
/// l'entitlement `application-identifier`, formé de l'identifiant d'**équipe**
/// Apple plus l'identifiant de paquet. bran n'a pas d'équipe : `bran-dev`
/// (`Scripts/make-signing-identity.sh`) est un certificat auto-signé, sans
/// compte développeur Apple, et `Resources/bran.entitlements` ne déclare ni
/// `application-identifier` ni `keychain-access-groups` — il n'y a donc aucun
/// groupe d'accès à qui l'ACL par défaut pourrait rattacher l'élément. Activer
/// la clé changerait le mécanisme de contrôle d'accès sans rien lui donner à
/// contrôler, avec pour risque documenté un refus (`errSecMissingEntitlement`)
/// plutôt qu'une amélioration. Ce n'est testable qu'en le construisant et en le
/// lançant sur une vraie machine ; cet agent ne compile pas, donc ce n'est pas
/// tenté ici plutôt que deviné.
///
/// **`kSecAttrAccess` explicite.** Il ne contourne pas le vrai problème, il le
/// déplace : sans lui, macOS construit implicitement l'ACL à partir de
/// l'exigence de conception (« designated requirement ») que `codesign`
/// attribue au binaire signant. Pour une identité ancrée chez Apple, cette
/// exigence porte sur le **certificat** et survit à une recompilation. Pour un
/// certificat auto-signé comme `bran-dev`, non ancré à une autorité qu'Apple
/// reconnaît, `codesign` n'a que le condensé du code (`cdhash`) à y mettre —
/// c'est-à-dire une exigence propre à **ce build précis**. Écrire un
/// `kSecAttrAccess` à la main reconstruirait la même ACL par défaut, avec la
/// même exigence par `cdhash`, donc la même instabilité à chaque
/// recompilation. La seule échappatoire — fabriquer une exigence d'accès
/// ancrée sur le certificat plutôt que sur le binaire, via
/// `SecTrustedApplicationCreateFromPath` et une chaîne de `SecRequirement`
/// personnalisée — est une piste réelle, non écartée par principe, mais non
/// tentée ici : elle touche des API historiques (`SecAccess`,
/// `SecTrustedApplication`) qui ne se vérifient qu'à l'exécution, sur cette
/// machine précisément, et cet agent ne compile pas.
///
/// **Ce que ça laisse.** Tant que la signature reste locale, une invite reste
/// possible au premier accès qui suit chaque nouvelle construction — c'est un
/// coût de la signature locale documentée dans `Scripts/build-app.sh`, pas un
/// bogue de ce fichier. Ce que ce fichier contrôle, et qui est corrigé
/// ailleurs (`BackupController.swift`, `BackupWiring.swift`) : ne jamais
/// solliciter le trousseau plus souvent que nécessaire, pour qu'une invite qui
/// reste possible ne devienne pas une invite qui revient en boucle.
enum BackupSecrets {

    private static let service = "com.opahventures.bran.backup"

    /// Les deux secrets, et leurs comptes au Trousseau. Aucun autre secret ne
    /// doit rejoindre cette liste sans une vraie raison : chaque entrée est un
    /// item que l'utilisateur devra un jour reconnaître dans Trousseau
    /// d'accès, en train de dépanner sa propre machine.
    enum Secret: String, CaseIterable, Sendable {
        /// La clé secrète S3 — `secretAccessKey` du dépôt Kopia.
        /// L'**identifiant** de clé n'est pas un secret : il vit en clair
        /// dans `BackupConfiguration.s3AccessKeyID`.
        case s3SecretAccessKey

        /// Le mot de passe de dépôt Kopia. **C'est la clé de chiffrement de
        /// bout en bout** : sans lui, aucun octet posé sur le QNAP ne se
        /// relit, pas même par le propriétaire.
        case repositoryPassword

        var account: String { "bran.backup." + rawValue }
    }

    // MARK: - Lire

    /// Ce qu'une lecture a obtenu.
    ///
    /// **La distinction entre `.absent` et `.denied` est celle qui compte.**
    /// Les confondre en un simple `nil` ferait afficher « pas encore
    /// configuré » à quelqu'un dont le Trousseau est verrouillé — c'est-à-dire
    /// lui faire ressaisir un mot de passe de dépôt qui n'a jamais bougé,
    /// exactement à l'endroit où ce projet ne tolère aucune fausse alerte.
    enum ReadOutcome {
        case found(String)
        case absent
        /// Le Trousseau a refusé de répondre pour une autre raison qu'une
        /// absence : verrouillé, interaction non permise, ou une donnée
        /// trouvée mais qui n'est pas de l'UTF-8 lisible. Ce dernier cas
        /// n'est ni « trouvé » (rien d'utilisable) ni « absent » (il y a bien
        /// un élément) : il est rangé ici parce qu'un secret illisible se
        /// traite exactement comme un secret inaccessible — bran ne peut rien
        /// en faire dans les deux cas.
        case denied(BackupSecretsError)
    }

    static func read(_ secret: Secret) -> ReadOutcome {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: secret.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecItemNotFound:
            return .absent
        case errSecSuccess:
            guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
                return .denied(BackupSecretsError(status: errSecDecode, context: "\(secret.rawValue) illisible"))
            }
            return .found(value)
        default:
            return .denied(BackupSecretsError(status: status, context: "lecture de \(secret.rawValue)"))
        }
    }

    // MARK: - Savoir si un secret existe, sans le lire

    /// Ce qu'une vérification de présence a obtenu — jamais la valeur.
    enum ExistsOutcome {
        case present
        case absent
        case denied(BackupSecretsError)
    }

    /// Y a-t-il un élément pour ce secret ? **Sans jamais réclamer sa donnée.**
    ///
    /// Le précédent qui justifie cette fonction est mesuré, pas supposé : voir
    /// `CRM/Keychain.swift.exists(_:)`, où une sonde de pile d'appel a montré
    /// que c'est la demande de **données** (ou d'attributs) qui déclenche
    /// l'autorisation du Trousseau — une requête qui ne réclame ni l'une ni
    /// les autres y répond sans la solliciter. `read(_:)` demande
    /// `kSecReturnData`, ce qui est juste quand l'appelant va se servir de la
    /// valeur ; un appelant qui ne veut que savoir « ce secret est-il
    /// enregistré ? » — c'est le seul besoin de
    /// `BackupController.hasStoredSecret(_:)`, via `refreshStoredSecrets()` —
    /// n'a aucune raison de payer ce risque pour une réponse qu'il jette
    /// aussitôt.
    static func exists(_ secret: Secret) -> ExistsOutcome {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: secret.account,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)

        switch status {
        case errSecItemNotFound:
            return .absent
        case errSecSuccess:
            return .present
        default:
            return .denied(BackupSecretsError(status: status, context: "présence de \(secret.rawValue)"))
        }
    }

    // MARK: - Écrire

    enum WriteOutcome {
        case saved
        case failed(BackupSecretsError)
    }

    /// Écrit un secret.
    ///
    /// **`SecItemAdd` d'abord, `SecItemUpdate` sur `errSecDuplicateItem`** —
    /// jamais un `SecItemDelete` préalable. Supprimer avant d'ajouter ouvre
    /// une fenêtre où le secret n'existe nulle part ; si l'ajout qui devait le
    /// remplacer échoue à cet instant, le mot de passe de dépôt disparaît
    /// pour de bon alors que l'utilisateur croyait seulement le changer. Ici,
    /// une écriture refusée laisse l'ancienne valeur intacte.
    @discardableResult
    static func write(_ value: String, for secret: Secret) -> WriteOutcome {
        guard let data = value.data(using: .utf8), !data.isEmpty else {
            return .failed(BackupSecretsError(status: errSecParam, context: "valeur vide pour \(secret.rawValue)"))
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: secret.account,
        ]

        var insert = query
        insert[kSecValueData as String] = data
        // **`AfterFirstUnlockThisDeviceOnly`, pas `WhenUnlocked`.** C'est le
        // réglage qui décide si la sauvegarde planifiée peut tourner du tout.
        // Un job réveillé par launchd pendant que l'écran est verrouillé —
        // le cas normal d'une sauvegarde de nuit — ne peut PAS lire un secret
        // `WhenUnlocked` : le Trousseau refuse, `read` rend `.denied`, et la
        // sauvegarde échoue en silence toutes les nuits, sans qu'aucun
        // message ne dise pourquoi puisque rien n'a jamais eu de quoi
        // démarrer pour se plaindre. `AfterFirstUnlock` survit à l'écran
        // verrouillé et ne demande que le premier déverrouillage après
        // démarrage — largement acquis au moment où une sauvegarde de nuit se
        // déclenche des jours plus tard.
        //
        // `ThisDeviceOnly` en plus, parce qu'un mot de passe de dépôt est
        // propre à **une** machine : le laisser migrer par iCloud Trousseau
        // donnerait à n'importe quel autre Mac du même identifiant Apple
        // accès à un dépôt qu'il n'a pas provisionné, sans que personne ne
        // l'ait demandé pour ce Mac-là précisément.
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        var status = SecItemAdd(insert as CFDictionary, nil)

        if status == errSecDuplicateItem {
            let changes: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ]
            status = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
        }

        guard status == errSecSuccess else {
            return .failed(BackupSecretsError(status: status, context: "écriture de \(secret.rawValue)"))
        }

        // La relecture n'est pas de la superstition : c'est le seul moyen de
        // répondre « oui » à « le secret est-il vraiment enregistré ? » au
        // lieu de « l'API n'a pas protesté ». Voir `CRM/Keychain.swift`, qui
        // applique la même discipline pour la même raison.
        guard case .found(let readBack) = read(secret), readBack == value else {
            return .failed(BackupSecretsError(status: status, context: "\(secret.rawValue) non relu après écriture"))
        }

        return .saved
    }

    // MARK: - Effacer

    enum DeleteOutcome {
        case cleared
        case failed(BackupSecretsError)
    }

    /// `errSecItemNotFound` est un succès : il n'y avait rien, il n'y a
    /// toujours rien, c'est ce qui était demandé.
    @discardableResult
    static func delete(_ secret: Secret) -> DeleteOutcome {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: secret.account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            return .failed(BackupSecretsError(status: status, context: "suppression de \(secret.rawValue)"))
        }
        return .cleared
    }
}

/// Un échec du Trousseau, avec son `OSStatus` **et** le message que macOS lui
/// associe. Un entier nu ne se cherche pas dans la documentation aussi vite
/// qu'une phrase ; la phrase seule ne se compare pas à un code relevé ailleurs
/// dans un rapport de bogue. Les deux ensemble se suffisent à eux-mêmes.
struct BackupSecretsError: Error, CustomStringConvertible, Sendable {
    let status: OSStatus
    let context: String

    var message: String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "code Trousseau \(status) sans message connu"
    }

    var description: String { "\(context) : \(message) (\(status))" }
}
