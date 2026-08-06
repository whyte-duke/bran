import Foundation
import Testing
@testable import BranWatch

@Suite("Résolveur du veilleur")
struct WatchResolverTests {

    private let crm = LaneIdentity.claudeCode(
        sessionID: "s1", workingDirectory: "/p/crm", branch: "feat/recorder-api"
    )
    private let bran = LaneIdentity.claudeCode(
        sessionID: "s2", workingDirectory: "/p/bran", branch: "main"
    )
    private let onglet = LaneIdentity.window(
        bundleIdentifier: "com.google.Chrome", applicationName: "Chrome", title: "claude.ai"
    )

    // MARK: - Priorité

    @Test("Une voie immobile depuis trois heures est abandonnée, pas en attente")
    func abandonBatAttente() {
        let verdict = WatchResolver(thresholds: .measuredOnce).resolve(
            observations: [LaneObservation(identity: crm, motionRatio: 0, stillFor: 3 * 3600)],
            human: .active
        )

        #expect(verdict.lanes.first?.state == .abandoned)
        #expect(verdict.next == nil)
    }

    @Test("Les quatre seuils se suivent sans se chevaucher")
    func seuilsOrdonnes() {
        let resolver = WatchResolver(thresholds: .measuredOnce)
        let attendus: [(TimeInterval, LaneState)] = [
            (10, .working), (200, .waiting), (2000, .stale), (8000, .abandoned),
        ]

        for (immobile, attendu) in attendus {
            let verdict = resolver.resolve(
                observations: [LaneObservation(
                    identity: crm, motionRatio: 0, stillFor: immobile, lastTouchedByHuman: immobile
                )],
                human: .active
            )
            #expect(verdict.lanes.first?.state == attendu, "immobile depuis \(immobile) s")
        }
    }

    @Test("Un capteur certain l'emporte sur les pixels")
    func certainBatLesPixels() {
        // L'écran ne bouge pas depuis une heure, mais la session appelle des
        // outils : elle travaille. C'est exactement le cas mesuré sur une vraie
        // session, lue « immobile » pendant 76 secondes alors qu'elle tournait.
        let verdict = WatchResolver(thresholds: .measuredOnce).resolve(
            observations: [
                LaneObservation(identity: crm, motionRatio: 0, stillFor: 3600, certain: .working)
            ],
            human: .active
        )

        #expect(verdict.lanes.first?.state == .working)
        #expect(verdict.waitingNow == 0)
    }

    // MARK: - CR-1, la présence humaine

    /// Le défaut le plus grave de la révision 2 : « ou aucun capteur ne
    /// contredit » était toujours vrai pour un onglet `claude.ai`, puisqu'aucun
    /// capteur certain n'existe pour cette tribu. Tout onglet immobile devenait
    /// une alerte. Ici, un onglet immobile depuis peu reste `working`.
    @Test("Un onglet sans capteur certain ne devient pas une alerte pour autant")
    func ongletSansCapteurNAlertePas() {
        // 600 s, très au-dessus du seuil de 180 : c'est la CLAUSE qui doit
        // retenir l'alerte, pas le seuil. La version précédente de ce test
        // utilisait 30 s et passait donc pour la mauvaise raison — elle
        // vérifiait le seuil et prétendait vérifier la clause.
        let verdict = WatchResolver(thresholds: .measuredOnce).resolve(
            observations: [LaneObservation(identity: onglet, motionRatio: 0, stillFor: 600)],
            human: .active
        )

        #expect(verdict.lanes.first?.state == .stale)
        #expect(verdict.next == nil, "un onglet immobile n'est pas une voie qui vous attend")
    }

    @Test("Sans capteur certain, une voie n'attend que si l'humain n'y est pas revenu")
    func clauseDuDernierContact() {
        let resolver = WatchResolver(thresholds: .measuredOnce)

        // L'humain a regardé cette fenêtre il y a dix secondes : il est devant,
        // elle ne l'« attend » pas.
        let devant = resolver.resolve(
            observations: [LaneObservation(
                identity: onglet, motionRatio: 0, stillFor: 600, lastTouchedByHuman: 10
            )],
            human: .active
        )
        #expect(devant.lanes.first?.state == .stale)

        // Il n'y est pas revenu depuis dix minutes : là, elle l'attend.
        let parti = resolver.resolve(
            observations: [LaneObservation(
                identity: onglet, motionRatio: 0, stillFor: 600, lastTouchedByHuman: 600
            )],
            human: .active
        )
        #expect(parti.lanes.first?.state == .waiting)
        #expect(parti.next?.identity == onglet)
    }

    /// L'horodatage écrit par l'outil lui-même ne compte pas la veille,
    /// contrairement à une soustraction d'horloge murale.
    @Test("Avec un capteur certain, l'attente se mesure sur l'horodatage de l'outil")
    func attenteMesureeSurLHorodatageCertain() {
        let maintenant = Date(timeIntervalSince1970: 1_000_000)
        let verdict = WatchResolver(thresholds: .measuredOnce).resolve(
            observations: [LaneObservation(
                identity: crm, motionRatio: 0, stillFor: 99999,
                certain: .waiting, certainSince: maintenant.addingTimeInterval(-300)
            )],
            human: .active,
            now: maintenant
        )

        #expect(verdict.lanes.first?.waitingFor == 300)
    }

    /// CR-1. Un `CGEventTap` mort ne doit produire ni « toujours actif »
    /// (silence total) ni « toujours inactif » (alertes en rafale).
    @Test("Sans signal de présence, le silence partagé est inconnu, jamais faux")
    func presenceInconnue() {
        let verdict = WatchResolver(thresholds: .measuredOnce).resolve(
            observations: [LaneObservation(
                identity: crm, motionRatio: 0, stillFor: 600, lastTouchedByHuman: 600
            )],
            human: .unavailable(reason: "Secure Keyboard Entry")
        )

        #expect(verdict.lanes.first?.state == .waiting)
        #expect(verdict.sharedSilence == nil)
    }

    @Test("L'humain inactif pendant que des voies attendent : c'est le silence partagé")
    func silencePartage() {
        let verdict = WatchResolver(thresholds: .measuredOnce).resolve(
            observations: [LaneObservation(
                identity: crm, motionRatio: 0, stillFor: 600, lastTouchedByHuman: 600
            )],
            human: .idle(seconds: 400)
        )

        #expect(verdict.sharedSilence == true)
    }

    @Test("L'humain occupé ailleurs pendant que ça attend n'est pas un silence partagé")
    func humainOccupe() {
        let verdict = WatchResolver(thresholds: .measuredOnce).resolve(
            observations: [LaneObservation(
                identity: crm, motionRatio: 0, stillFor: 600, lastTouchedByHuman: 600
            )],
            human: .active
        )

        #expect(verdict.sharedSilence == false)
    }

    // MARK: - CR-2 et CR-4

    /// CR-2. Après une nuit capot fermé, toutes les durées valent dix heures.
    /// Sans ce garde-fou, bran réveille l'utilisateur avec cinq alertes fausses.
    @Test("Au réveil, tout repart d'inconnu plutôt que d'alerter en rafale")
    func reveilDeVeille() {
        let verdict = WatchResolver(thresholds: .measuredOnce).resolve(
            observations: [
                LaneObservation(identity: crm, motionRatio: 0, stillFor: 36000),
                LaneObservation(identity: bran, motionRatio: 0, stillFor: 36000),
            ],
            human: .idle(seconds: 36000),
            clockJumped: true
        )

        #expect(verdict.lanes.allSatisfy { $0.state == .unknown })
        #expect(verdict.next == nil)
        #expect(verdict.waitingNow == 0)
    }

    /// CR-4. Le routeur est un panneau toujours au-dessus, et bran enregistre
    /// les réunions. Pendant un partage d'écran, il montrerait le nom de vos
    /// clients à vos clients.
    @Test("Pendant une réunion à l'écran, le résolveur se tait complètement")
    func muetPendantUneReunion() {
        let verdict = WatchResolver(thresholds: .measuredOnce).resolve(
            observations: [LaneObservation(
                identity: crm, motionRatio: 0, stillFor: 600, lastTouchedByHuman: 600
            )],
            human: .idle(seconds: 300),
            isMuted: true
        )

        #expect(verdict.muted)
        #expect(verdict.lanes.isEmpty)
        #expect(verdict.next == nil)
    }

    // MARK: - Le routeur

    @Test("Le routeur désigne la voie qui attend depuis le plus longtemps")
    func routeurChoisitLaPlusAncienne() {
        let verdict = WatchResolver(thresholds: .measuredOnce).resolve(
            observations: [
                LaneObservation(identity: crm, motionRatio: 0, stillFor: 400, lastTouchedByHuman: 400),
                LaneObservation(identity: bran, motionRatio: 0, stillFor: 900, lastTouchedByHuman: 900),
            ],
            human: .active
        )

        #expect(verdict.next?.identity == bran)
        #expect(verdict.waitingNow == 1300)
    }

    @Test("À égalité, la voie la mieux identifiée passe devant")
    func egaliteTranchéeParLaPrecision() {
        let verdict = WatchResolver(thresholds: .measuredOnce).resolve(
            observations: [
                LaneObservation(identity: onglet, motionRatio: 0, stillFor: 600, lastTouchedByHuman: 600),
                LaneObservation(identity: crm, motionRatio: 0, stillFor: 600, lastTouchedByHuman: 600),
            ],
            human: .active
        )

        #expect(verdict.next?.identity == crm)
    }

    @Test("Une fenêtre non observable est inconnue, elle ne disparaît pas")
    func fenetreNonObservable() {
        let verdict = WatchResolver(thresholds: .measuredOnce).resolve(
            observations: [LaneObservation(identity: onglet, motionRatio: nil)],
            human: .active
        )

        #expect(verdict.lanes.count == 1)
        #expect(verdict.lanes.first?.state == .unknown)
    }

    @Test("Chaque voie sait dire pourquoi elle est dans cet état")
    func chaqueVoieSExplique() {
        let verdict = WatchResolver(thresholds: .measuredOnce).resolve(
            observations: [LaneObservation(
                identity: crm, motionRatio: 0, stillFor: 600, lastTouchedByHuman: 600
            )],
            human: .active
        )

        #expect(verdict.lanes.first?.because.isEmpty == false)
    }
}

@Suite("Identité des voies")
struct LaneIdentityTests {

    /// Reprendre une session avec `--resume` change l'identifiant mais pas le
    /// travail. Pour l'utilisateur c'est la même voie, donc la clé est le
    /// dossier.
    @Test("Deux sessions dans le même dossier sont la même voie")
    func memeDossierMemeVoie() {
        let avant = LaneIdentity.claudeCode(sessionID: "s1", workingDirectory: "/p/crm", branch: "main")
        let apres = LaneIdentity.claudeCode(sessionID: "s2", workingDirectory: "/p/crm", branch: "main")

        #expect(avant.key == apres.key)
    }

    @Test("Le nom affiché est court et dicible")
    func nomAffiche() {
        let voie = LaneIdentity.claudeCode(
            sessionID: "s", workingDirectory: "/Users/x/Documents/castral/crm", branch: "feat/recorder-api"
        )

        #expect(voie.displayName == "crm · feat/recorder-api")
    }

    @Test("Sans branche nommée, on n'affiche que le dossier")
    func sansBranche() {
        let voie = LaneIdentity.claudeCode(sessionID: "s", workingDirectory: "/p/bran", branch: "HEAD")
        #expect(voie.displayName == "bran")
    }

    /// Sans ça, un titre qui passe de « ⠂ Compilation » à « ⠄ Compilation »
    /// crée une voie neuve à chaque tic et la file se remplit de fantômes.
    @Test("Un spinner dans le titre ne crée pas une voie par image")
    func spinnerNeCreePasDeVoie() {
        let a = LaneIdentity.window(bundleIdentifier: "t", applicationName: "Terminal", title: "⠂ Compilation")
        let b = LaneIdentity.window(bundleIdentifier: "t", applicationName: "Terminal", title: "⠄ Compilation")

        #expect(a.key == b.key)
    }

    @Test("Un compteur de notifications ne crée pas une voie par message")
    func compteurNeCreePasDeVoie() {
        let a = LaneIdentity.window(bundleIdentifier: "m", applicationName: "Mail", title: "(3) Boîte de réception")
        let b = LaneIdentity.window(bundleIdentifier: "m", applicationName: "Mail", title: "(7) Boîte de réception")

        #expect(a.key == b.key)
    }

    @Test("La précision d'une session déclarée dépasse celle d'un titre de fenêtre")
    func precisionOrdonnee() {
        let session = LaneIdentity.claudeCode(sessionID: "s", workingDirectory: "/p", branch: "main")
        let fenetre = LaneIdentity.window(bundleIdentifier: "c", applicationName: "Chrome", title: "claude.ai")

        #expect(fenetre.precision < session.precision)
    }
}
