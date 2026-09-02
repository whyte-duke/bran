import BranCore
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

    /// Le compte du Trousseau où vit le jeton de cette adresse.
    ///
    /// L'hôte de production garde le compte historique — `recorderToken` — pour
    /// que les jetons déjà enregistrés continuent d'être trouvés sans que
    /// personne n'ait à ressaisir quoi que ce soit. Tout autre hôte a le sien.
    ///
    /// Une adresse refusée par `CRMOriginPolicy` retombe sur le compte de
    /// production : elle ne sert de toute façon à rien, `endpoint` est alors
    /// `nil` et aucun client n'est construit.
    private static func tokenAccount(for baseURL: String) -> String {
        guard let host = CRMOriginPolicy.crmBase(baseURL).url?.host()?.lowercased(),
              host != URL(string: productionBaseURL)?.host()
        else { return Key.token }
        return "\(Key.token)@\(host)"
    }

    /// L'adresse de production. Sert de valeur par défaut **et** de repère pour
    /// le compte du Trousseau : le jeton déjà enregistré par les versions
    /// précédentes est celui de cet hôte-là, et il doit le rester.
    static let productionBaseURL = "https://crm.castral.fr"

    var baseURL: String {
        didSet {
            UserDefaults.standard.set(baseURL, forKey: Key.baseURL)

            // **Changer d'hôte change de jeton.** C'est la deuxième moitié du
            // correctif d'origine, et elle est ici plutôt que dans une
            // vérification : le jeton est rangé dans le Trousseau sous un compte
            // qui porte le nom de l'hôte, donc une adresse réécrite ne désigne
            // plus le même secret. Un processus local qui modifie la préférence
            // n'obtient pas un envoi du jeton ailleurs, il obtient « pas de
            // jeton » — et l'utilisateur légitime qui bascule sur une recette
            // saisit le sien une fois, puis retrouve celui de la production en
            // revenant.
            let previous = Self.tokenAccount(for: oldValue)
            let current = Self.tokenAccount(for: baseURL)
            guard previous != current else { return }
            storedToken = ""
            isLoaded = false
            tokenProblem = nil
            tokenIsStored = Keychain.exists(current)
        }
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

    /// La valeur en mémoire, vide tant que `loadToken()` n'a pas eu lieu.
    ///
    /// Stockée et non calculée : c'est elle que l'observation suit, donc c'est
    /// elle qui redessine l'écran des réglages quand la lecture aboutit.
    private var storedToken = ""

    /// Jamais persisté ailleurs que dans le Trousseau.
    ///
    /// Le résultat de l'écriture est **lu**. `Keychain.set` rend un `Outcome`
    /// depuis qu'une écriture refusée a cessé d'être silencieuse, mais un
    /// résultat que personne ne regarde ne vaut pas mieux qu'un `Void` : l'écran
    /// affichait le jeton — il est en mémoire — pendant que le Trousseau gardait
    /// l'ancien. L'utilisateur collait son nouveau jeton, le voyait accepté,
    /// quittait, et le dépôt suivant échouait avec un identifiant qu'il croyait
    /// remplacé.
    ///
    /// **Vide n'est pas « pas de jeton » tant que `isLoaded` est faux** : c'est
    /// « on n'a pas encore demandé ». La distinction est portée par
    /// `isConfigured`, et c'est elle qui évite l'alerte du Trousseau au
    /// démarrage.
    var token: String {
        get { storedToken }
        set {
            storedToken = newValue
            // Écrire vaut lecture : la valeur en mémoire est désormais celle du
            // Trousseau, et la relire par-dessus n'apprendrait rien.
            isLoaded = true
            tokenProblem = Keychain.set(newValue, for: Self.tokenAccount(for: baseURL)).problem
            tokenIsStored = newValue.isEmpty == false
        }
    }

    /// Le jeton a-t-il été lu depuis le Trousseau dans cette session ?
    ///
    /// Faux au lancement, et c'est tout l'objet de la manœuvre : voir
    /// `loadToken()`.
    private var isLoaded = false

    /// Le jeton est-il déjà en mémoire ?
    ///
    /// Lu par `MeetingDirectory` pour savoir si sa veille de fond a le droit de
    /// parler au CRM : tant que la réponse est non, l'interroger réclamerait le
    /// Trousseau, et une veille n'est pas un geste de l'utilisateur.
    var isTokenLoaded: Bool { isLoaded }

    /// Un jeton est-il enregistré ? Relevé **auprès du Trousseau lui-même**, par
    /// une question sur l'existence et non sur la valeur — voir
    /// `Keychain.exists(_:)`, qui explique pourquoi celle-là n'ouvre aucune
    /// alerte.
    ///
    /// Retenu en mémoire plutôt que redemandé : `isConfigured` est lu depuis le
    /// corps de plusieurs vues, et une requête au Trousseau par passe de dessin
    /// serait de l'entrée-sortie dans une boucle d'affichage. Réévalué à chaque
    /// écriture et à chaque lecture, c'est-à-dire aux deux seuls moments où la
    /// réponse peut changer du fait de bran.
    ///
    /// **Un miroir dans les préférences aurait été plus simple et faux** : le
    /// premier utilisateur à qui l'application est donnée n'en aurait aucun —
    /// donc pas de CRM configuré, alors que son jeton est là.
    ///
    /// **Ce que ça ne couvre pas, et c'est assumé.** Un élément supprimé dans
    /// Trousseau d'accès *pendant* que bran tourne ne se voit pas : ni cette
    /// valeur ni le jeton déjà chargé ne changent, et l'interface continue
    /// d'annoncer un CRM configuré jusqu'au prochain lancement. Le rattraper
    /// demanderait d'interroger le Trousseau à chaque passe de dessin, pour un
    /// geste que personne ne fait en cours de session ; le premier envoi qui
    /// échoue le dira, ce qui est le canal prévu.
    private(set) var tokenIsStored: Bool

    /// Lit le jeton, une fois par session, et seulement quand il va servir.
    ///
    /// **Le lancement ne doit jamais toucher au Trousseau**, et c'est un défaut
    /// qui se voyait : `init` lisait le jeton, donc chaque démarrage du Mac
    /// ouvrait l'alerte « bran souhaite accéder à vos informations
    /// confidentielles stockées dans … ». macOS la pose parce que la liste de
    /// contrôle d'accès de l'élément désigne la **signature** de l'application
    /// qui l'a écrit : reconstruire bran la périme, et le Trousseau redemande.
    /// Elle arrivait donc avant toute intention de l'utilisateur, pour une
    /// fonctionnalité — le dépôt d'un compte rendu dans le CRM — dont la plupart
    /// des lancements ne se servent jamais.
    ///
    /// Pour quelqu'un qui reçoit l'application et n'a pas de CRM, c'est pire
    /// qu'une gêne : la première chose que bran fait est de réclamer un accès
    /// qu'il ne saurait pas justifier.
    ///
    /// La lecture est donc repoussée jusqu'au premier geste qui a besoin du
    /// jeton — construire un client, ou l'afficher dans les réglages. Là,
    /// l'alerte est compréhensible : on vient de demander quelque chose qui
    /// touche au CRM.
    func loadToken() {
        guard isLoaded == false else { return }
        isLoaded = true
        let stored = Keychain.get(Self.tokenAccount(for: baseURL))

        // **La lecture qui échoue alors que l'élément existe se dit.**
        //
        // `Keychain.get` ne journalise que les codes d'erreur ; le cas qui a
        // vraiment fait perdre du temps n'en produit aucun visible ici : le
        // Trousseau contient l'élément — `exists` répond oui — et la lecture
        // rend quand même `nil`, parce que la liste de contrôle d'accès désigne
        // une signature qui n'est plus celle de l'application. bran concluait
        // alors « pas de CRM », vidait la liste des rendez-vous, et se taisait.
        if stored == nil, tokenIsStored {
            FeatureLog.record(
                "✗ CRM — le jeton est dans le Trousseau mais illisible : la liste de contrôle "
                + "d'accès ne reconnaît plus la signature de bran. Ressaisir le jeton la refait."
            )
        }
        // La valeur est posée sans passer par `token`, dont le setter réécrirait
        // dans le Trousseau ce qu'on vient d'en lire.
        storedToken = stored ?? ""
        tokenIsStored = stored?.isEmpty == false
    }

    /// Ce que le Trousseau a refusé, déjà écrit pour un humain, ou `nil` quand
    /// la valeur à l'écran est bien celle qui est stockée.
    ///
    /// Remis à `nil` par la première écriture qui passe : c'est l'état du
    /// stockage, pas un historique.
    var tokenProblem: String?

    init() {
        let defaults = UserDefaults.standard
        let address = defaults.string(forKey: Key.baseURL) ?? Self.productionBaseURL
        baseURL = address
        author = defaults.string(forKey: Key.author).flatMap(Author.init(rawValue:)) ?? .martial
        maxSpeakers = defaults.object(forKey: Key.maxSpeakers) as? Int ?? 3
        autoUpload = defaults.object(forKey: Key.autoUpload) as? Bool ?? false
        // La seule question posée au Trousseau au lancement, et elle ne réclame
        // aucune autorisation : « y a-t-il un élément ? », jamais « donne-le ».
        tokenIsStored = Keychain.exists(Self.tokenAccount(for: address))

    }

    /// Le CRM est-il utilisable ?
    ///
    /// **Répond sans ouvrir le Trousseau tant que personne ne l'a ouvert**, et
    /// c'est la raison d'être du marqueur : cette question est posée depuis le
    /// corps de plusieurs vues, dont la liste des réunions, donc au premier
    /// dessin de la fenêtre. La faire dépendre du jeton lui-même ramènerait
    /// l'alerte du Trousseau au lancement par une autre porte.
    ///
    /// Une fois le jeton lu, c'est lui qui fait foi — le marqueur ne dit que
    /// « il y en a un », pas « il ressemble à un jeton du CRM ».
    /// Les trois valeurs dont le produit décide de tout, écrites au journal.
    ///
    /// **Appelée par `AppModel` et non depuis `init`**, et c'est la deuxième
    /// fois que ce piège se referme : `FeatureLog` n'apprend le dossier où
    /// écrire qu'après la construction des services, si bien qu'une trace posée
    /// dans `init` part dans le vide sans que rien ne le signale.
    ///
    /// Ce qu'elle permet d'observer : `isConfigured` commande l'affichage du
    /// panneau des prochains rendez-vous ; faux, le panneau n'est pas monté,
    /// donc son `.task` ne tourne pas, donc `refresh()` n'est jamais appelé — et
    /// le message d'erreur que `refresh()` pose ne peut pas s'afficher non plus.
    /// Le cercle se referme sur un écran vide, sans une ligne à lire nulle part.
    func logConfiguration() {
        FeatureLog.record(
            "CRM — jeton dans le Trousseau : \(tokenIsStored), adresse : « \(baseURL) », "
            + "origine autorisée : \(endpointProblem ?? "oui"), configuré : \(isConfigured)"
        )
    }

    var isConfigured: Bool {
        let looksUsable = isLoaded ? storedToken.hasPrefix("rec_") : tokenIsStored
        return looksUsable && endpoint != nil
    }

    /// Pourquoi l'adresse saisie est refusée, ou `nil` si elle convient.
    ///
    /// Affiché dans les réglages : une adresse refusée sans phrase pour le dire
    /// donnerait un CRM « non configuré » que rien n'explique, exactement le
    /// cercle qu'on a déjà payé une fois — panneau non monté, donc `refresh()`
    /// jamais appelé, donc message d'erreur jamais affiché.
    var endpointProblem: String? {
        CRMOriginPolicy.crmBase(baseURL).refusal?.message
    }

    /// **Le seul chemin qui a le droit de réclamer le Trousseau**, avec l'écran
    /// des réglages : construire un client, c'est être sur le point de parler au
    /// CRM, donc avoir besoin du jeton pour de bon.
    func makeClient() -> CRMClient? {
        loadToken()
        guard isConfigured, let endpoint else { return nil }
        return CRMClient(endpoint: endpoint, token: token)
    }

    /// L'adresse du CRM, **si elle fait partie des origines autorisées**.
    ///
    /// La validation ne vit pas ici mais dans `CRMOriginPolicy`, avec ses tests,
    /// et son en-tête raconte l'attaque : `baseURL` est dans les préférences, où
    /// un processus local écrit sans rien demander ; le jeton est dans le
    /// Trousseau, où le même processus ne peut pas lire. Il lui suffisait donc
    /// d'écrire l'adresse de son choix pour que bran lise le secret **pour lui**
    /// et l'envoie dans `x-castral-recorder-token` à l'hôte indiqué.
    ///
    /// Le jeton reste dans le Trousseau et n'est jamais effacé au passage : une
    /// adresse refusée rend simplement `nil`, donc aucun client, donc aucun
    /// appel — et remettre la bonne adresse rétablit tout sans avoir à
    /// ressaisir quoi que ce soit.
    var endpoint: URL? {
        CRMOriginPolicy.crmBase(baseURL).url
    }

    /// Le CRM ne renvoie `crm_url` que si `NEXT_PUBLIC_APP_URL` est définie côté
    /// serveur — elle ne l'est pas. On reconstruit, comme le contrat le prévoit.
    func dashboardURL(companyID: String) -> URL? {
        endpoint?.appending(path: "sales/dashboard/\(companyID)")
    }
}
