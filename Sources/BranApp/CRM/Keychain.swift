import Foundation
import Security

/// Stockage du jeton d'enregistrement.
///
/// Le Trousseau, pas `UserDefaults`. Un jeton dans les préférences finit en
/// clair dans un `.plist` lisible par n'importe quel processus de la session,
/// et dans toutes les sauvegardes Time Machine. Le doc du CRM insiste sur le
/// principe du moindre privilège côté serveur ; le tenir côté client aussi est
/// la moindre des choses.
enum Keychain {
    private static let service = "com.opahventures.bran"

    static func set(_ value: String?, for account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)

        guard let value, value.isEmpty == false, let data = value.data(using: .utf8) else { return }

        var insert = query
        insert[kSecValueData as String] = data
        // Le jeton n'est lu que quand la session est déverrouillée, et il ne
        // doit jamais migrer vers une autre machine par une sauvegarde.
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(insert as CFDictionary, nil)
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
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }

        return String(data: data, encoding: .utf8)
    }
}
