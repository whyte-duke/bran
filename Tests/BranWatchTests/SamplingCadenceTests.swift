import Foundation
import Testing
@testable import BranWatch

/// **Ce que le veilleur choisit de regarder, et ce qu'il choisit d'ignorer.**
///
/// Le budget de six captures par tic n'est pas une optimisation : au-delà, le
/// tic de 2 s dérive vers 3 s et les trois seuils temporels du résolveur
/// glissent d'un tiers sans que rien ne le dise. La conséquence, c'est qu'à
/// vingt fenêtres, quatorze ne sont pas mesurées à chaque tour — et que le choix
/// des six décide de la justesse des alertes.
@Suite("Cadence d'échantillonnage")
struct SamplingCadenceTests {

    private let seuil: TimeInterval = 180

    private func cadence(
        budget: Int = 6,
        states: [String: LaneState] = [:],
        certain: Set<String> = []
    ) -> SamplingCadence {
        SamplingCadence(budget: budget, waitingAfter: seuil, states: states, certain: certain)
    }

    private func window(
        _ key: String,
        onScreen: Bool = true,
        last: Int? = nil,
        still: TimeInterval? = nil
    ) -> SamplingCadence.Candidate {
        .init(key: key, isOnScreen: onScreen, lastCapturedTick: last, stillFor: still)
    }

    // MARK: - Les rangs

    /// Rang 0, sans condition : une voie jamais mesurée n'existe pas encore dans
    /// la liste. La laisser attendre son tour, c'est ne pas l'afficher.
    @Test("Une voie jamais mesurée passe avant tout le monde")
    func jamaisMesuree() {
        let plan = cadence(states: ["a": .working])
        #expect(plan.rank(window("a")) == 0)
        #expect(plan.period(for: window("a")) == 1)
    }

    /// Là où se décide une alerte. Sans ce rang, l'alerte des trois minutes
    /// partirait sur une observation vieille de plusieurs échantillons.
    @Test("Une voie qui approche du seuil est mesurée à chaque tic")
    func procheDuSeuil() {
        let plan = cadence(states: ["a": .abandoned])
        #expect(plan.rank(window("a", last: 1, still: 90)) == 1)
        #expect(plan.rank(window("a", last: 1, still: 179)) == 1)
        #expect(plan.period(for: window("a", last: 1, still: 90)) == 1)
    }

    /// Sous la moitié du seuil, rien ne se joue ; au-dessus du seuil, l'alerte
    /// est déjà partie. Dans les deux cas, c'est l'état qui décide.
    @Test("Hors de la fenêtre d'approche, c'est l'état qui commande")
    func horsFenetreDApproche() {
        let plan = cadence(states: ["a": .stale])
        #expect(plan.rank(window("a", last: 1, still: 89)) == 3)
        #expect(plan.rank(window("a", last: 1, still: 180)) == 3)
    }

    @Test("Chaque état a son rang et sa période")
    func rangsParEtat() {
        let attendu: [(LaneState?, Int, Int)] = [
            (.working, 2, 3),
            (.waiting, 2, 3),
            (nil, 2, 3),
            (.stale, 3, 15),
            (.abandoned, 4, 60),
            (.unknown, 4, 60),
        ]

        for (state, rank, period) in attendu {
            let plan = cadence(states: state.map { ["a": $0] } ?? [:])
            let voie = window("a", last: 0, still: 10)
            #expect(plan.rank(voie) == rank, "état \(String(describing: state))")
            #expect(plan.period(for: voie) == period, "état \(String(describing: state))")
        }
    }

    // MARK: - Le droit de capturer

    /// Le compositeur n'a plus les pixels d'une fenêtre minimisée : la capturer
    /// rendrait une image uniforme, qu'on lirait comme « immobile » — et une voie
    /// vieillirait vers l'alerte sans qu'aucun pixel ne l'ait justifié.
    @Test("Une fenêtre hors écran n'est jamais capturée")
    func horsEcranJamais() {
        #expect(cadence().allowsCapture(window("a", onScreen: false), tick: 1) == false)
    }

    /// Le verdict certain est meilleur *et* gratuit. Y ajouter des pixels ne
    /// changerait rien au résultat et coûterait une place sur six.
    @Test("Une voie déjà certaine ne coûte aucune capture")
    func certainGratuit() {
        let plan = cadence(certain: ["a"])
        #expect(plan.allowsCapture(window("a"), tick: 1) == false)
        #expect(plan.allowsCapture(window("b"), tick: 1))
    }

    @Test("La période est respectée au tic près")
    func periodeAuTicPres() {
        let plan = cadence(states: ["a": .working])   // période 3
        let voie = window("a", last: 10, still: 10)

        #expect(plan.allowsCapture(voie, tick: 12) == false)
        #expect(plan.allowsCapture(voie, tick: 13))
        #expect(plan.allowsCapture(voie, tick: 99))
    }

    /// Une voie abandonnée coûte une capture par minute à 1 s de tic, contre une
    /// sur trois pour une voie vivante. C'est ce rapport de soixante qui laisse
    /// de la place aux voies qui comptent.
    @Test("Une voie abandonnée n'est reprise qu'un tic sur soixante")
    func abandonneeUneFoisParMinute() {
        let plan = cadence(states: ["a": .abandoned])
        #expect(plan.allowsCapture(window("a", last: 100, still: 9_000), tick: 159) == false)
        #expect(plan.allowsCapture(window("a", last: 100, still: 9_000), tick: 160))
    }

    // MARK: - La répartition du budget

    @Test("Le budget est une borne dure")
    func budgetBorne() {
        let plan = cadence(budget: 6)
        let voies = (0 ..< 20).map { window("w\($0)") }
        #expect(plan.selection(voies, tick: 1).count == 6)
        #expect(cadence(budget: 0).selection(voies, tick: 1).isEmpty)
    }

    /// Sans ça, les six mêmes fenêtres se partageraient le budget éternellement
    /// et les autres ne seraient jamais vues.
    @Test("À rang égal, les voies les plus anciennement mesurées passent devant")
    func pasDeFamine() {
        let plan = cadence(budget: 6, states: Dictionary(
            uniqueKeysWithValues: (0 ..< 8).map { ("w\($0)", LaneState.working) }
        ))
        // Toutes éligibles à ce tic (100 − 97 ≥ 3), toutes de rang 2.
        let voies = (0 ..< 8).map { window("w\($0)", last: 90 + $0, still: 10) }

        #expect(plan.selection(voies, tick: 100) == [0, 1, 2, 3, 4, 5])
    }

    /// Une fenêtre écartée est sautée, pas décomptée. Sinon un écran plein de
    /// fenêtres minimisées affamerait les rares voies réellement observables.
    @Test("Les voies écartées ne consomment pas de budget")
    func ecarteesNeConsommentRien() {
        let plan = cadence(budget: 2, certain: ["certaine"])
        let voies = [
            window("cachée", onScreen: false),
            window("certaine"),
            window("cachée2", onScreen: false),
            window("vraie1"),
            window("vraie2"),
        ]

        #expect(plan.selection(voies, tick: 1) == [3, 4])
    }

    /// L'ordre complet, sur un cas qui ressemble à un vrai bureau : une voie
    /// neuve, une qui approche du seuil, deux vivantes, une endormie.
    @Test("L'ordre de priorité complet")
    func ordreComplet() {
        let plan = cadence(budget: 6, states: [
            "vivante": .working,
            "endormie": .abandoned,
            "sans-nouvelles": .stale,
        ])
        let voies = [
            window("endormie", last: 0, still: 9_000),
            window("vivante", last: 0, still: 10),
            window("neuve"),
            window("approche", last: 0, still: 120),
            window("sans-nouvelles", last: 0, still: 400),
        ]

        #expect(plan.order(voies) == [2, 3, 1, 4, 0])
    }

    @Test("Aucune fenêtre, aucune capture")
    func aucuneFenetre() {
        #expect(cadence().selection([], tick: 1).isEmpty)
        #expect(cadence().order([]).isEmpty)
    }
}
