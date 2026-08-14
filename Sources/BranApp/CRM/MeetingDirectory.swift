import BranCore
import Foundation
import Observation

/// Les rendez-vous à venir, tenus à jour depuis le CRM.
///
/// Ces données viennent de Supabase — table `bookings`, alimentée par le webhook
/// cal.com — mais bran les lit par `/api/transcriptions/targets`, pas en
/// attaquant la base. Une clé `service_role` sur un portable donnerait un accès
/// total en lecture-écriture à tout le CRM ; la clé `anon` ne verrait rien, les
/// `bookings` étant protégés par RLS. L'endpoint donne exactement ce qu'il faut,
/// avec exactement le privilège qu'il faut.
@MainActor
@Observable
final class MeetingDirectory {

    private(set) var bookings: [CRMBooking] = []
    private(set) var lastRefresh: Date?
    private(set) var problem: String?
    private(set) var isRefreshing = false

    private let configuration: CRMConfiguration
    private var refreshTask: Task<Void, Never>?

    /// Les RDV changent au rythme des réservations cal.com, pas à la seconde.
    private static let refreshInterval = Duration.seconds(300)

    init(configuration: CRMConfiguration) {
        self.configuration = configuration
    }

    /// Ce qui reste à venir, plus le rendez-vous en cours.
    ///
    /// Le quart d'heure de retard évite qu'un RDV disparaisse de la liste à la
    /// seconde où il commence — c'est précisément le moment où on le cherche.
    var upcoming: [CRMBooking] {
        let floor = Date.now.addingTimeInterval(-15 * 60)
        return bookings
            .filter { $0.start_at >= floor && $0.status != "no_show" }
            .sorted { $0.start_at < $1.start_at }
    }

    var next: CRMBooking? { upcoming.first }

    /// Rapprochement **certain** : le code d'une réunion Meet est unique.
    ///
    /// Bien plus solide que la fenêtre de ±2 h du contrat, qui n'est qu'un
    /// repli quand aucun code n'est disponible — un RDV déplacé, un lien
    /// personnel, une réunion improvisée.
    func booking(forMeetCode code: String) -> CRMBooking? {
        bookings.first { booking in
            guard let url = booking.meeting_url else { return false }
            return MeetTitleMatcher.meetCode(in: url) == code
        }
    }

    func start() {
        guard refreshTask == nil else { return }

        refreshTask = Task { [weak self] in
            while Task.isCancelled == false {
                // `userDriven: false` — personne n'a rien demandé, c'est la
                // veille. Voir `refresh(userDriven:)` : c'est cette ligne qui
                // décide que le lancement de bran n'ouvre pas le Trousseau.
                await self?.refresh(userDriven: false)
                try? await Task.sleep(for: Self.refreshInterval)
            }
        }
    }

    /// - Parameter userDriven: vrai quand quelqu'un vient de demander à voir ses
    ///   rendez-vous — la fenêtre s'ouvre, on tire pour rafraîchir, un envoi va
    ///   partir. **C'est la seule circonstance où cette veille a le droit
    ///   d'ouvrir le Trousseau.**
    ///
    ///   La boucle de fond, elle, passe `false` : sans ça, la toute première
    ///   itération — lancée au démarrage de bran — réclamait le jeton, donc
    ///   l'alerte « bran veut accéder à la clé … de votre trousseau » arrivait à
    ///   chaque ouverture de session, avant tout geste de l'utilisateur, pour un
    ///   rafraîchissement dont il n'avait rien demandé. macOS la pose parce que
    ///   la liste de contrôle d'accès de l'élément désigne la signature de
    ///   l'application qui l'a écrit, et que reconstruire bran la périme.
    ///
    ///   Ce que ça concède : au lancement, la liste des rendez-vous reste vide
    ///   jusqu'au premier geste. Une réunion qui démarrerait dans cet intervalle
    ///   est enregistrée quand même — c'est le rapprochement au rendez-vous qui
    ///   attend, pas la capture — et la première ouverture de la fenêtre le
    ///   rattrape.
    func refresh(userDriven: Bool = true) async {
        // Le jeton déjà en mémoire ne coûte rien : la restriction ne porte que
        // sur la **première** lecture, celle qui ouvre l'alerte.
        guard userDriven || configuration.isTokenLoaded else { return }

        guard configuration.isConfigured, let client = configuration.makeClient() else {
            bookings = []
            // **`problem = nil` était le défaut, et il a coûté une heure.**
            //
            // Une liste vide parce qu'il n'y a pas de rendez-vous et une liste
            // vide parce qu'on n'a pas pu la charger s'affichaient exactement
            // pareil : rien. Le 14 août 2026, un rendez-vous existait bel et
            // bien dans le CRM — vérifié à la main, HTTP 200, il était là — et
            // bran ne montrait pas même un avertissement. Il n'y avait aucun
            // endroit où regarder.
            //
            // La phrase distingue les deux causes possibles, parce qu'elles
            // n'appellent pas le même geste : renseigner la liaison, ou réparer
            // un jeton que le Trousseau ne rend plus.
            problem = configuration.tokenIsStored
                ? "Jeton du CRM illisible : il est bien dans le Trousseau, mais bran n'y a pas accès. "
                    + "Rouvrez les Réglages et ressaisissez-le."
                : "Liaison CRM non configurée — voir les Réglages."
            return
        }

        isRefreshing = true
        defer { isRefreshing = false }

        do {
            // Quatre heures en arrière : un RDV commencé il y a trois heures et
            // qui dure encore doit rester rapprochable.
            bookings = try await client.targets(
                from: Date.now.addingTimeInterval(-4 * 3600),
                to: Date.now.addingTimeInterval(7 * 24 * 3600)
            )
            lastRefresh = .now
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }
}
