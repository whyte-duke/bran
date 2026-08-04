import Foundation
import Observation

/// Réglages de la liaison avec le CRM Castral.
@MainActor
@Observable
final class CRMConfiguration {

    /// Les trois personnes que le CRM accepte dans `created_by`.
    enum Author: String, CaseIterable, Identifiable, Sendable {
        case martial = "Martial"
        case julian = "Julian"
        case mathis = "Mathis"

        var id: String { rawValue }
    }

    private enum Key {
        static let baseURL = "bran.crm.baseURL"
        static let author = "bran.crm.author"
        static let autoUpload = "bran.crm.autoUpload"
        static let maxSpeakers = "bran.crm.maxSpeakers"
        static let token = "recorderToken"
    }

    var baseURL: String {
        didSet { UserDefaults.standard.set(baseURL, forKey: Key.baseURL) }
    }

    var author: Author {
        didSet { UserDefaults.standard.set(author.rawValue, forKey: Key.author) }
    }

    /// `3` = commercial + technique Castral + le prospect. Bornes 2 à 6.
    var maxSpeakers: Int {
        didSet { UserDefaults.standard.set(maxSpeakers, forKey: Key.maxSpeakers) }
    }

    /// N'envoie tout seul que si le rattachement est **certain** : un unique RDV
    /// dans la fenêtre de ±2 h. Sinon la question est posée. Un audio rattaché
    /// au mauvais lead écrase le compte-rendu de quelqu'un d'autre.
    var autoUpload: Bool {
        didSet { UserDefaults.standard.set(autoUpload, forKey: Key.autoUpload) }
    }

    /// Jamais persisté ailleurs que dans le Trousseau.
    var token: String {
        didSet { Keychain.set(token, for: Key.token) }
    }

    init() {
        let defaults = UserDefaults.standard
        baseURL = defaults.string(forKey: Key.baseURL) ?? "https://crm.castral.fr"
        author = defaults.string(forKey: Key.author).flatMap(Author.init(rawValue:)) ?? .martial
        maxSpeakers = defaults.object(forKey: Key.maxSpeakers) as? Int ?? 3
        autoUpload = defaults.object(forKey: Key.autoUpload) as? Bool ?? false
        token = Keychain.get(Key.token) ?? ""
    }

    var isConfigured: Bool {
        token.hasPrefix("rec_") && URL(string: baseURL)?.host != nil
    }

    var endpoint: URL? {
        URL(string: baseURL.trimmingCharacters(in: .whitespaces).trimmingSuffix("/"))
    }

    /// Le CRM ne renvoie `crm_url` que si `NEXT_PUBLIC_APP_URL` est définie côté
    /// serveur — elle ne l'est pas. On reconstruit, comme le contrat le prévoit.
    func dashboardURL(companyID: String) -> URL? {
        endpoint?.appending(path: "sales/dashboard/\(companyID)")
    }
}

private extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) ? String(dropLast(suffix.count)) : self
    }
}
