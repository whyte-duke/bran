import Foundation

/// **Les seules origines auxquelles bran a le droit de parler.**
///
/// Deux pannes, toutes deux muettes, toutes deux payées par le client.
///
/// **La première.** `created.upload.url` arrive dans la réponse du CRM, et le
/// seul garde était `URL(string:)`. Le `PUT` du MP3 de la réunion partait
/// ensuite vers cette adresse sans que ni son schéma ni son hôte ne soient
/// regardés : une réponse contenant exactement
/// `{"id":"x","upload":{"url":"http://100.64.3.7/upload"}}` suffisait à déposer
/// l'intégralité d'un closing, en clair, sur une machine choisie par la
/// réponse. Rien à l'écran ne distinguait cet envoi d'un envoi normal — la
/// barre de progression monte pareil.
///
/// **La seconde.** `baseURL` vit dans les préférences, où n'importe quel
/// processus tournant sous la même session peut écrire, alors que le jeton vit
/// dans le Trousseau, où il ne peut pas lire. Sans contrôle d'origine, il lui
/// suffisait d'écrire `https://collecteur.example` dans la préférence : au
/// prochain appel, bran lisait lui-même le secret — l'alerte du Trousseau, s'il
/// y en a une, nomme bran, pas l'attaquant — et l'envoyait dans
/// `x-castral-recorder-token` à l'adresse choisie.
///
/// D'où une liste d'hôtes explicite plutôt qu'une validation de forme. Ce que
/// ça coûte : déplacer le CRM ou changer d'hébergeur de stockage demande de
/// toucher à ce fichier et de republier. C'est le prix, et il est assumé — la
/// question « à qui bran a-t-il le droit d'envoyer l'audio d'un client » ne se
/// répond pas depuis un fichier de préférences.
public enum CRMOriginPolicy {

    /// Le CRM Castral. `castral.fr` et ses sous-domaines : la production est
    /// `crm.castral.fr`, et un déploiement de recette sur un autre
    /// sous-domaine doit rester joignable sans republier bran.
    public static let approvedCRMDomain = "castral.fr"

    /// Le stockage. Les octets ne passent pas par le CRM — une fonction Vercel
    /// plafonne à 4,5 Mo de corps, un closing pèse dix fois plus — ils vont
    /// directement à Supabase, sur une URL signée valable deux heures.
    ///
    /// **L'hôte complet, pas le domaine — et la nuance vaut l'audio d'un
    /// client.**
    ///
    /// La règle portait sur `supabase.co` et `supabase.in`, au motif qu'une
    /// migration de projet resterait dans le même domaine et qu'écrire la
    /// référence ici obligerait à republier l'application. L'argument est vrai
    /// et il ne suffit pas : `supabase.co` est un domaine **mutualisé**.
    /// N'importe qui ouvre un compte et obtient `<le sien>.supabase.co`, qui
    /// passait alors la garde exactement comme le nôtre.
    ///
    /// Le contrôle d'origine ne protégeait donc de rien contre le cas qu'il
    /// vise : une réponse CRM erronée ou falsifiée désignant un projet
    /// Supabase tiers, qui recevait l'enregistrement complet d'une réunion.
    ///
    /// Une liste d'hôtes complets, plutôt qu'un seul, laisse la migration
    /// possible : on y ajoute le nouveau projet, on publie, on retire l'ancien
    /// quand plus personne ne l'utilise. C'est une republication, et c'est le
    /// prix de la garantie — republier est justement ce que bran sait faire en
    /// une commande, et l'équipe reçoit la version dans l'heure.
    ///
    /// Le projet Castral est `nifvrjlcurdqzdwvwfxh`, région eu-west-3 (relevé
    /// le 02/09/2026).
    public static let approvedStorageHosts = [
        "nifvrjlcurdqzdwvwfxh.supabase.co",
    ]

    /// Pourquoi une adresse est refusée. Le message est écrit pour être affiché
    /// tel quel : c'est le seul endroit où l'utilisateur apprendra que bran a
    /// refusé d'envoyer, et « URL invalide » ne dit pas quoi corriger.
    public enum Refusal: Equatable, Sendable {
        case unreadable
        case notHTTPS(scheme: String?)
        case credentialsInURL
        case fragmentInURL
        case unapprovedHost(String)

        public var message: String {
            switch self {
            case .unreadable:
                "Adresse illisible."
            case .notHTTPS(let scheme):
                "Seul HTTPS est accepté" + (scheme.map { " (reçu : \($0))." } ?? ".")
            case .credentialsInURL:
                "Une adresse qui porte un identifiant ou un mot de passe est refusée."
            case .fragmentInURL:
                "Une adresse qui porte un fragment (#…) est refusée."
            case .unapprovedHost(let host):
                "L'hôte « \(host) » ne fait pas partie des origines autorisées."
            }
        }
    }

    public enum Verdict: Equatable, Sendable {
        case approved(URL)
        case refused(Refusal)

        public var url: URL? {
            if case .approved(let url) = self { url } else { nil }
        }

        public var refusal: Refusal? {
            if case .refused(let refusal) = self { refusal } else { nil }
        }
    }

    /// L'adresse du CRM, telle qu'elle est saisie dans les réglages.
    ///
    /// La barre oblique finale est retirée ici et pas chez l'appelant : c'est la
    /// même adresse, et deux endroits qui la normalisent différemment finissent
    /// par ne plus être d'accord sur ce qui est configuré.
    public static func crmBase(_ text: String) -> Verdict {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutTrailingSlash = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed

        guard let url = URL(string: withoutTrailingSlash), let host = url.host() else {
            return .refused(.unreadable)
        }
        if let refusal = commonRefusal(url) { return .refused(refusal) }
        guard isWithin(approvedCRMDomain, host: host) else {
            return .refused(.unapprovedHost(host))
        }
        return .approved(url)
    }

    /// L'adresse de dépôt renvoyée par le CRM.
    ///
    /// - Parameter crmHost: l'hôte du CRM lui-même, accepté en plus du stockage
    ///   pour qu'un déploiement qui relaierait les octets reste possible sans
    ///   toucher à cette liste.
    public static func uploadDestination(_ text: String, crmHost: String?) -> Verdict {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host()
        else { return .refused(.unreadable) }

        if let refusal = commonRefusal(url) { return .refused(refusal) }

        let approved = approvedStorageHosts.contains { isSameHost($0, host) }
            || crmHost.map { isSameHost(host, $0) } == true
        guard approved else { return .refused(.unapprovedHost(host)) }
        return .approved(url)
    }

    /// Une redirection a-t-elle le droit d'être suivie ?
    ///
    /// **Non, dès qu'elle change d'hôte.** Sans ça, tout le contrôle d'origine
    /// ci-dessus se contourne d'un `302` : l'adresse approuvée répond « va
    /// déposer ça ailleurs », et `URLSession` obéit sans rien demander. Le cas
    /// se produit aussi sans malveillance — un stockage qui bascule vers un
    /// domaine de secours — et il ne doit pas plus passer : l'audio d'un client
    /// ne part pas vers un hôte que personne n'a approuvé.
    public static func allowsRedirection(from origin: URL, to destination: URL) -> Bool {
        guard let source = origin.host(), let target = destination.host() else { return false }
        guard destination.scheme?.lowercased() == "https" else { return false }
        return isSameHost(source, target)
    }

    private static func commonRefusal(_ url: URL) -> Refusal? {
        guard url.scheme?.lowercased() == "https" else { return .notHTTPS(scheme: url.scheme) }
        if url.user() != nil || url.password() != nil { return .credentialsInURL }
        if url.fragment() != nil { return .fragmentInURL }
        return nil
    }

    /// Appartenance à un domaine, sans le piège classique du suffixe : la règle
    /// est « le domaine lui-même, ou quelque chose qui finit par un point suivi
    /// du domaine ». Comparer par `hasSuffix("castral.fr")` seul aurait accepté
    /// `evilcastral.fr`.
    private static func isWithin(_ domain: String, host: String) -> Bool {
        let host = host.lowercased()
        let domain = domain.lowercased()
        return host == domain || host.hasSuffix("." + domain)
    }

    private static func isSameHost(_ left: String, _ right: String) -> Bool {
        left.lowercased() == right.lowercased()
    }
}
