import Foundation
import Security

/// Stockage du jeton d'enregistrement.
///
/// Le Trousseau, pas `UserDefaults`. Un jeton dans les préférences finit en
/// clair dans un `.plist` lisible par n'importe quel processus de la session,
/// et dans toutes les sauvegardes Time Machine. Le doc du CRM insiste sur le
/// principe du moindre privilège côté serveur ; le tenir côté client aussi est
/// la moindre des choses.
///
/// **Une écriture au Trousseau peut être refusée, et elle l'était en silence.**
/// `SecItemAdd(insert as CFDictionary, nil)` jetait son `OSStatus`. L'écran des
/// réglages affichait alors le nouveau jeton — il est en mémoire — pendant que
/// le Trousseau gardait l'ancien, ou rien. Le symptôme arrivait un redémarrage
/// plus tard, sous la forme d'un dépôt CRM refusé avec un jeton que
/// l'utilisateur croyait avoir remplacé : c'est-à-dire au pire endroit et au
/// pire moment, et sans lien apparent avec la saisie de la veille.
///
/// Toutes les écritures rendent donc un `Outcome`. Il est `@discardableResult`
/// pour ne pas alourdir les appels qui n'ont rien à en faire, mais son
/// `problem` est une phrase prête à afficher, et l'échec part aussi dans
/// `FeatureLog` — qui, lui, survit à la fermeture de la fenêtre des réglages.
enum Keychain {
    private static let service = "com.opahventures.bran"

    /// Ce qu'une écriture a **obtenu**, pas ce qu'elle a tenté.
    enum Outcome: Equatable, Sendable {
        /// Le Trousseau contient la valeur demandée. Vérifié par relecture, pas
        /// déduit d'un code de retour.
        case saved
        /// Le Trousseau ne contient plus rien pour ce compte.
        case cleared
        case failed(String)

        /// La phrase à afficher, ou `nil` quand il n'y a rien à signaler.
        var problem: String? {
            if case .failed(let reason) = self { return reason }
            return nil
        }
    }

    /// Écrit, remplace ou efface la valeur d'un compte.
    ///
    /// **`SecItemAdd` d'abord, `SecItemUpdate` sur `errSecDuplicateItem`** — et
    /// non plus `SecItemDelete` puis `SecItemAdd`. L'ordre importe : supprimer
    /// avant d'ajouter ouvre une fenêtre où le Trousseau ne contient plus rien,
    /// et si l'ajout est alors refusé, l'utilisateur perd un jeton qu'il ne
    /// voulait que remplacer. Ici, une écriture refusée laisse l'ancienne valeur
    /// intacte et le dit.
    ///
    /// `errSecDuplicateItem` n'est d'ailleurs pas une erreur mais une réponse :
    /// « cette paire service + compte existe déjà ». Sa réparation est nommée,
    /// c'est `SecItemUpdate`, qui change la donnée sans jamais passer par un
    /// état vide.
    ///
    /// **La relecture n'est pas de la superstition.** C'est exactement le geste
    /// que fera l'utilisateur au prochain lancement — `Keychain.get` — et le
    /// seul moyen de répondre « oui » à « le jeton est-il enregistré ? » au lieu
    /// de « l'API n'a pas protesté ». Elle coûte un appel, sur une action
    /// humaine.
    @discardableResult
    static func set(_ value: String?, for account: String) -> Outcome {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        guard let value, value.isEmpty == false, let data = value.data(using: .utf8) else {
            return clear(query, account: account)
        }

        var insert = query
        insert[kSecValueData as String] = data
        // Le jeton n'est lu que quand la session est déverrouillée, et il ne
        // doit jamais migrer vers une autre machine par une sauvegarde.
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        var status = SecItemAdd(insert as CFDictionary, nil)

        if status == errSecDuplicateItem {
            let changes: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            ]
            status = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
        }

        guard status == errSecSuccess else {
            return fail("Jeton non enregistré dans le Trousseau", status, account: account)
        }

        // La relecture. Un `errSecSuccess` sur un élément qu'on ne retrouve pas
        // ensuite ne s'est jamais vu, mais c'est précisément la classe de
        // défauts qu'on corrige : ne rien tenir pour acquis d'une opération dont
        // on n'a pas vu le résultat.
        guard get(account) == value else {
            let message = """
                Jeton non enregistré dans le Trousseau : il n'y est pas relu après écriture. \
                Il fonctionnera jusqu'à la fermeture de bran, puis disparaîtra.
                """
            FeatureLog.record("✗ Trousseau — \(account) : relecture négative après écriture")
            return .failed(message)
        }

        return .saved
    }

    /// Efface la valeur d'un compte.
    ///
    /// **`errSecItemNotFound` est un succès** : il n'y avait rien, il n'y a
    /// toujours rien, c'est ce qui était demandé. Tout autre code est un échec
    /// réel — Trousseau verrouillé, refus d'interaction — et celui-là compte :
    /// l'écran affiche un champ vide pendant que le jeton, lui, est toujours
    /// stocké. Un identifiant qu'on croit révoqué et qui ne l'est pas est le
    /// plus mauvais des deux sens de cette panne.
    private static func clear(_ query: [String: Any], account: String) -> Outcome {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            return fail("Jeton non supprimé du Trousseau", status, account: account)
        }
        return .cleared
    }

    /// Y a-t-il un élément pour ce compte ? **Sans demander sa donnée.**
    ///
    /// La liste de contrôle d'accès d'un élément du Trousseau protège sa
    /// **donnée**, pas son existence : une requête qui ne demande que les
    /// attributs y répond sans autorisation. Mesuré à la ligne de commande sur
    /// l'élément réel de bran — `security find-generic-password -s
    /// com.opahventures.bran` rend les attributs sans un mot, là où le même
    /// appel avec `-g`, qui réclame la donnée, déclenche l'alerte.
    ///
    /// C'est ce qui permet à `CRMConfiguration.isConfigured` de répondre au
    /// lancement, et à l'application de ne réclamer le Trousseau que le jour où
    /// elle a vraiment besoin du jeton.
    ///
    /// **Ce n'est pas une garantie, c'est une mesure.** Apple documente que
    /// copier la *donnée* d'un mot de passe peut demander une authentification ;
    /// elle ne promet nulle part qu'aucune lecture d'attributs ne le fera
    /// jamais. Pour les éléments écrits par `set(_:for:)` — sans
    /// `SecAccessControl`, donc sans exigence biométrique — le comportement
    /// constaté est celui décrit ci-dessus. Un élément créé autrement pourrait
    /// se comporter autrement.
    static func exists(_ account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            // **Les attributs, jamais la donnée.** Poser `kSecReturnData` ici
            // reviendrait à écrire `get` une seconde fois, avec l'alerte qui va
            // avec — et personne ne verrait la différence avant le prochain
            // redémarrage du Mac.
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess
    }

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        // Absent est le cas normal : première installation, jeton jamais saisi.
        // Verrouillé, refusé ou corrompu ne l'est pas, et rendait le même `nil`
        // — donc le même écran vide, qui invite à ressaisir un jeton déjà là.
        // Rien à afficher ici : `get` est appelée à l'initialisation, avant
        // qu'il y ait un écran. Le journal, lui, gardera la trace.
        guard status != errSecItemNotFound else { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            FeatureLog.record("✗ Trousseau — \(account) illisible : \(explain(status))")
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    // MARK: - Diagnostic

    /// Compose la phrase et laisse une trace datée. **Ne journalise jamais la
    /// valeur** : ce sont des jetons, et le journal est un fichier texte.
    private static func fail(_ what: String, _ status: OSStatus, account: String) -> Outcome {
        let reason = explain(status)
        FeatureLog.record("✗ Trousseau — \(what) (\(account)) : \(reason)")
        return .failed("\(what) : \(reason)")
    }

    /// Le texte du Trousseau plutôt qu'un numéro. `errSecInteractionNotAllowed`
    /// n'apprend rien à personne ; « l'interaction avec le trousseau n'est pas
    /// autorisée » se cherche dans les Réglages.
    private static func explain(_ status: OSStatus) -> String {
        if let message = SecCopyErrorMessageString(status, nil) as String? {
            return "\(message) (\(status))"
        }
        return "erreur Trousseau \(status)"
    }
}
