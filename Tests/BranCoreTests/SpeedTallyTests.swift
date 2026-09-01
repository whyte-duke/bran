import Foundation
import Testing
@testable import BranCore

/// **Les quatre manières de se tromper de débit**, et la preuve qu'on ne les
/// prend pas.
///
/// Chaque cas de ce fichier reproduit une méthode naïve documentée dans
/// `SpeedTally`, avec les nombres réellement mesurés sur la ligne du poste le
/// 31/08/2026 : montée en régime de 0,8 → 5,0 → 11,3 Mo/s, plateau à 14 à 15,
/// creux passager à 2,1, et une dernière tranche partielle qui s'effondre. Un
/// test de débit est exactement le genre de fonction qui rend un chiffre faux
/// sans jamais échouer — il n'y a donc rien à observer en la lançant, et tout à
/// vérifier ici.
@Suite("Le calcul du débit")
struct SpeedTallyTests {

    /// Verse un débit constant pendant `windows` tranches, un échantillon par
    /// tranche, posé au milieu de celle-ci.
    private func fill(
        _ tally: inout SpeedTally,
        rates: [Double],
        from start: Int = 0
    ) {
        for (offset, rate) in rates.enumerated() {
            let index = start + offset
            let middle = (Double(index) + 0.5) * SpeedTally.window
            tally.accept(elapsed: middle, bytes: Int(rate * SpeedTally.window))
        }
    }

    // MARK: - La rampe

    @Test("La montée en régime est écartée : elle décrit TCP, pas la ligne")
    func rampIsDiscarded() {
        var tally = SpeedTally()
        // Les trois premières tranches sont la rampe mesurée, les suivantes le
        // plateau. Une tranche de plus que la rampe pour que la dernière,
        // partielle, ait de quoi être jetée.
        fill(&tally, rates: [800_000, 5_000_000, 11_300_000, 14_000_000]
            + Array(repeating: 14_300_000, count: 6))

        let rate = try! #require(tally.rate)
        // Sans l'écart de la rampe, la médiane des dix tranches tomberait entre
        // 11,3 et 14 : le test annoncerait une ligne d'un cinquième plus lente.
        #expect(rate == 14_300_000)
    }

    @Test("Sous une seconde de plateau, on ne répond pas — et surtout pas zéro")
    func silentUntilEnoughPlateau() {
        var tally = SpeedTally()
        // Quatre tranches de rampe + trois de plateau : il en faut quatre.
        fill(&tally, rates: Array(repeating: 14_000_000, count: 8))
        #expect(tally.rate == nil)

        // La neuvième close la huitième, et il y a enfin quatre tranches après
        // la rampe.
        fill(&tally, rates: [14_000_000], from: 8)
        #expect(tally.rate != nil)
    }

    // MARK: - La dernière tranche

    @Test("La tranche en cours n'est jamais comptée : elle est partielle")
    func openWindowExcluded() {
        var tally = SpeedTally()
        fill(&tally, rates: Array(repeating: 14_000_000, count: 9))

        // On s'arrête au tout début de la dixième : deux pour cent d'une tranche.
        tally.accept(elapsed: 9 * SpeedTally.window + 0.005, bytes: 70_000)

        // Cette tranche vaudrait 280 000 o/s — un cinquantième du plateau. Si
        // elle entrait dans la médiane de huit valeurs, elle tirerait la
        // moyenne des deux du milieu vers le bas.
        #expect(tally.rate == 14_000_000)
        #expect(tally.rates.count == 9)
    }

    // MARK: - Médiane contre moyenne

    @Test("Un creux passager ne déplace pas la médiane, il déplacerait la moyenne")
    func dipDoesNotMoveTheMedian() {
        var tally = SpeedTally()
        // Quatre de rampe, puis un plateau où trois tranches s'effondrent —
        // le décrochage mesuré à 6,5 / 3,9 / 2,1 Mo/s au milieu d'un transfert
        // par ailleurs régulier.
        fill(&tally, rates: Array(repeating: 1_000_000, count: 4)
            + [14_300_000, 14_300_000, 6_550_000, 3_930_000, 2_100_000,
               14_300_000, 14_300_000, 14_300_000, 14_300_000, 1])

        let plateau = Array(tally.rates.dropFirst(SpeedTally.rampWindows))
        let mean = plateau.reduce(0, +) / Double(plateau.count)

        let rate = try! #require(tally.rate)
        #expect(rate == 14_300_000)
        // La moyenne, elle, perd plus de trois mégaoctets par seconde sur trois
        // tranches qui ne disent rien de la ligne.
        #expect(mean < 11_000_000)
    }

    // MARK: - Les trous

    @Test("Une tranche sans octets vaut zéro, elle n'est pas absente")
    func stallsAreCounted() {
        var tally = SpeedTally()
        fill(&tally, rates: Array(repeating: 14_000_000, count: 6))
        // Rien pendant une seconde — un décrochage complet — puis ça repart.
        fill(&tally, rates: Array(repeating: 14_000_000, count: 6), from: 10)

        // Quinze tranches closes, dont quatre vides. Si les trous étaient
        // simplement absents du dictionnaire, il n'en resterait que onze et le
        // décrochage aurait disparu du relevé.
        #expect(tally.rates.count == 15)
        #expect(tally.rates.filter { $0 == 0 }.count == 4)
    }

    @Test("Un décrochage minoritaire ne déplace pas la médiane, un majoritaire si")
    func stallsMoveTheMedianOnlyWhenTheyDominate() {
        // Onze tranches après la rampe, dont quatre à zéro : la ligne a
        // transmis pendant la majorité du test, et la médiane le dit.
        var brief = SpeedTally()
        fill(&brief, rates: Array(repeating: 14_000_000, count: 6))
        fill(&brief, rates: Array(repeating: 14_000_000, count: 6), from: 10)
        #expect(brief.rate == 14_000_000)

        // Le même transfert, mais le trou dure trois secondes au lieu d'une :
        // la majorité des tranches sont vides, et là le chiffre **doit**
        // s'effondrer. Une médiane qui resterait à 14 Mo/s sur une ligne muette
        // les trois quarts du temps serait le pire mensonge possible ici.
        var long = SpeedTally()
        fill(&long, rates: Array(repeating: 14_000_000, count: 6))
        fill(&long, rates: Array(repeating: 14_000_000, count: 2), from: 22)
        #expect(long.rate == 0)
    }

    // MARK: - Cas dégénérés

    @Test("Un temps négatif ne fait pas disparaître les octets")
    func negativeElapsedIsFolded() {
        var tally = SpeedTally()
        tally.accept(elapsed: -3, bytes: 5_000)
        // Il entre dans le total, donc dans le coût annoncé à l'utilisateur, et
        // il se range dans la première tranche — celle que la rampe écarte de
        // toute façon.
        #expect(tally.totalBytes == 5_000)
    }

    @Test("Zéro octet n'ouvre pas de tranche")
    func emptyChunksIgnored() {
        var tally = SpeedTally()
        tally.accept(elapsed: 5, bytes: 0)
        #expect(tally.rates.isEmpty)
        #expect(tally.totalBytes == 0)
        #expect(tally.rate == nil)
        #expect(tally.live == nil)
    }

    @Test("L'aiguille suit la dernière tranche close, rampe comprise")
    func liveFollowsTheLastWindow() {
        var tally = SpeedTally()
        fill(&tally, rates: [800_000, 5_000_000, 11_300_000])
        // `rate` se tait encore — il n'a pas de plateau — mais l'aiguille doit
        // déjà monter, sinon le compteur reste à zéro pendant le quart du test.
        #expect(tally.rate == nil)
        #expect(tally.live == 5_000_000)
    }

    @Test("La montée s'intègre au lieu de se médianer : ses tranches sont quantifiées")
    func uploadUsesThePlateauMean() {
        // La suite réellement relevée par la sonde sur la montée. `didSendBodyData`
        // livre des blocs d'environ un mégaoctet, donc une tranche de 250 ms
        // reçoit zéro, un, deux ou trois blocs — jamais autre chose.
        var tally = SpeedTally()
        fill(&tally, rates: [8_400_000, 0, 4_200_000, 4_200_000,
                             0, 4_200_000, 8_400_000, 4_200_000,
                             4_200_000, 12_600_000, 4_200_000, 8_400_000, 1])

        // La médiane ne mesure pas la ligne, elle choisit un multiple de 4,2.
        #expect(tally.rate == 4_200_000)

        // L'intégrale du plateau, elle, tombe entre les barreaux — c'est-à-dire
        // au bon endroit.
        let mean = try! #require(tally.plateauMean)
        #expect(mean > 5_000_000 && mean < 6_500_000)
    }

    @Test("Le plateau moyen se tait tant que la médiane se tait")
    func plateauMeanIsAsPrudent() {
        var tally = SpeedTally()
        fill(&tally, rates: Array(repeating: 4_200_000, count: 8))
        // Les deux lectures partagent le même plancher : il n'y a aucune raison
        // qu'une des deux ose un chiffre que l'autre refuse.
        #expect(tally.rate == nil)
        #expect(tally.plateauMean == nil)
    }

    @Test("La médiane d'un nombre pair moyenne les deux du milieu")
    func evenMedian() {
        // Prendre celle du bas ferait, sur les quatre tranches minimales, une
        // préférence systématique pour le creux.
        #expect(SpeedTally.median([1, 2, 3, 4]) == 2.5)
        #expect(SpeedTally.median([3, 1]) == 2)
        #expect(SpeedTally.median([]) == nil)
    }
}

@Suite("La latence et la gigue")
struct SpeedLatencyTests {

    /// La série relevée par la sonde intégrée, en secondes. La première valeur
    /// est l'ouverture de connexion — DNS puis TLS — et les sept suivantes sont
    /// des allers-retours sur une connexion déjà ouverte.
    private let observed: [TimeInterval] = [
        0.200, 0.029, 0.027, 0.027, 0.111, 0.027, 0.029, 0.028,
    ]

    @Test("La première sonde est retirée : elle mesure une ouverture, pas un aller-retour")
    func warmupIsDropped() {
        let latency = SpeedLatency(samples: observed)
        #expect(latency.samples.count == 8)
        #expect(latency.settled.count == 7)
        // Ce qui est conservé reste consultable tel quel : la sonde en ligne de
        // commande l'affiche, et c'est ce qui a permis de voir le défaut.
        #expect(latency.samples.first == 0.200)
        #expect(latency.settled.first == 0.029)
    }

    @Test("Sans le retrait, la gigue accusait une ligne saine d'être instable")
    func warmupWreckedTheJitter() {
        // Ce que le calcul rendait avant le correctif : la moyenne des écarts
        // sur la série entière, saut de 200 → 29 ms compris.
        let withWarmup = zip(observed, observed.dropFirst())
            .map { abs($1 - $0) }
            .reduce(0, +) / Double(observed.count - 1)
        #expect(abs(withWarmup - 0.0491) < 0.0005)

        let jitter = try! #require(SpeedLatency(samples: observed).jitter)
        // Il reste 29 ms, et c'est **juste** : la série porte un vrai pic à
        // 111 ms au milieu. Ce qui a disparu est l'artefact, pas la mesure.
        #expect(abs(jitter - 0.0288) < 0.0005)
        #expect(jitter < withWarmup / 1.6)
    }

    @Test("La médiane, elle, ne bougeait pas — c'est pour ça que le défaut a duré")
    func medianWasNeverWrong() {
        let latency = try! #require(SpeedLatency(samples: observed).latency)
        #expect(abs(latency - 0.028) < 0.0005)
        // Une médiane sur les huit valeurs donnait déjà 28 ms : le point aberrant
        // était invisible dans le chiffre le plus regardé, et n'apparaissait que
        // dans celui d'à côté.
        let naive = try! #require(SpeedTally.median(observed))
        #expect(abs(naive - 0.0285) < 0.001)
    }

    @Test("La médiane décrit la moitié des paquets, le minimum flatterait la ligne")
    func medianNotMinimum() {
        let latency = SpeedLatency(samples: observed)
        let value = try! #require(latency.latency)
        // Le minimum aurait annoncé 27 ms — le meilleur cas d'un réseau,
        // c'est-à-dire une seconde que personne n'a vécue.
        #expect(value > latency.settled.min()!)
    }

    @Test("La gigue est la moyenne des écarts successifs, pas l'écart-type")
    func jitterIsConsecutive() {
        // Une ligne qui dérive lentement de 60 à 130 ms : gros écart-type,
        // gigue faible. C'est la gigue qui a raison — une visio n'entend pas
        // une dérive, elle entend les sauts.
        let drifting = SpeedLatency(samples: [0.050] + [0.060, 0.070, 0.080, 0.090, 0.100, 0.110, 0.120, 0.130])
        let jitter = try! #require(drifting.jitter)
        #expect(abs(jitter - 0.010) < 0.000_01)

        // La même moyenne, mais en dents de scie : même latence médiane,
        // gigue six fois pire.
        let jumpy = SpeedLatency(samples: [0.050] + [0.060, 0.130, 0.060, 0.130, 0.060, 0.130, 0.060, 0.130])
        let bad = try! #require(jumpy.jitter)
        #expect(bad > jitter * 6)
        #expect(drifting.latency == jumpy.latency)
    }

    @Test("Une seule sonde n'est pas retirée : une mesure imparfaite vaut mieux que rien")
    func loneSampleSurvives() {
        var latency = SpeedLatency()
        latency.accept(0.070)
        // Elle porte l'ouverture de connexion, donc elle surestime. Elle reste
        // affichée : sur une ligne qui n'a répondu qu'une fois, « 70 ms » dit
        // quelque chose et « — » ne dit rien.
        #expect(latency.latency == 0.070)
        #expect(latency.jitter == nil)
    }

    @Test("Une horloge cassée n'empoisonne pas la moyenne des écarts")
    func brokenClockRefused() {
        var latency = SpeedLatency()
        latency.accept(0.070)
        latency.accept(.nan)
        latency.accept(-1)
        latency.accept(.infinity)
        latency.accept(0.072)
        #expect(latency.samples.count == 2)
        // Deux sondes dont une d'ouverture : il en reste une, donc une latence
        // et pas de gigue.
        #expect(latency.latency == 0.072)
        #expect(latency.jitter == nil)
    }
}

@Suite("Le budget d'un test")
struct SpeedBudgetTests {

    @Test("L'échéance coupe à tout moment")
    func deadlineAlwaysCuts() {
        let budget = SpeedPlan.Budget.quick
        #expect(budget.isSpent(elapsed: 3.9, bytes: 58_000_000) == false)
        #expect(budget.isSpent(elapsed: 4.0, bytes: 60_000_000))
        // Sur un partage de connexion à 200 ko/s, c'est elle qui mord, et le
        // test n'aura coûté que 800 ko.
        #expect(budget.isSpent(elapsed: 4.0, bytes: 800_000))
    }

    @Test("Le plafond d'octets ne coupe jamais avant qu'il y ait de quoi répondre")
    func capNeverCutsBelowTheFloor() {
        let budget = SpeedPlan.Budget.upload

        // Le défaut observé : 24 Mo envoyés en 1,08 s sur une ligne à 32 Mo/s,
        // trois tranches closes, et « — » affiché. Le plafond dépensait sans
        // rien pouvoir conclure.
        #expect(budget.isSpent(elapsed: 1.08, bytes: 200_000_000) == false)

        // Passé le plancher, il reprend son rôle.
        #expect(budget.isSpent(elapsed: SpeedPlan.Budget.floor, bytes: budget.byteCap))
        #expect(budget.isSpent(elapsed: SpeedPlan.Budget.floor, bytes: budget.byteCap - 1) == false)
    }

    @Test("Le plancher est celui de la mesure, pas un nombre recopié")
    func floorFollowsTheTally() {
        // Rampe + plateau minimal + la tranche ouverte qu'on ne compte jamais.
        // S'il était écrit en dur, changer `SpeedTally.rampWindows` laisserait
        // les deux fichiers se contredire en silence.
        #expect(SpeedPlan.Budget.floor == 2.25)
        #expect(SpeedPlan.Budget.floor
            == Double(SpeedTally.rampWindows + SpeedTally.minimumWindows + 1) * SpeedTally.window)
    }

    @Test("Les deux budgets laissent de la marge au-dessus du plancher")
    func budgetsExceedTheFloor() {
        // Une échéance sous le plancher rendrait un test qui ne peut jamais
        // conclure — le défaut d'à côté, dans l'autre sens.
        #expect(SpeedPlan.Budget.quick.duration > SpeedPlan.Budget.floor)
        #expect(SpeedPlan.Budget.upload.duration > SpeedPlan.Budget.floor)
    }

    @Test("Le plafond de la montée est plus bas que celui de la descente")
    func uploadIsCheaper() {
        // La plupart des lignes françaises montent trois à cinq fois moins vite
        // qu'elles ne descendent : sur celles-là, ce plafond n'est jamais
        // atteint et c'est l'échéance qui décide.
        #expect(SpeedPlan.Budget.upload.byteCap < SpeedPlan.Budget.quick.byteCap)
    }
}

@Suite("Ce que la ligne permet")
struct SpeedGradeTests {

    /// La ligne du poste un bon jour : 14,3 Mo/s, 71 ms, 2 ms de gigue.
    private let download: Double = 14_300_000
    private let latency: TimeInterval = 0.071
    private let jitter: TimeInterval = 0.002

    // MARK: - La régularité

    @Test("Une ligne irrégulière ne permet ni la visio ni le jeu, même à latence basse")
    func jitterBreaksRealTime() {
        // **Les chiffres exacts relevés sur la ligne du propriétaire**, capture à
        // l'appui : 0,2 Mo/s, 40 ms de latence, 153 ms de gigue. bran annonçait
        // « suffisant jusqu'à : jeu en ligne », donc aussi la visioconférence.
        // Les deux sont impraticables à cette gigue-là, et la gigue était
        // affichée deux lignes plus haut dans le même menu.
        let d = 200_000.0, l = 0.040, j = 0.153

        let video = SpeedGrade.uses.first { $0.title == "Visioconférence" }!
        let game = SpeedGrade.uses.first { $0.title == "Jeu en ligne" }!
        let calls = SpeedGrade.uses.first { $0.title == "Appels audio" }!

        #expect(video.verdict(download: d, latency: l, jitter: j) == false)
        #expect(game.verdict(download: d, latency: l, jitter: j) == false)
        #expect(calls.verdict(download: d, latency: l, jitter: j) == false)

        // Ce qui se met en mémoire tampon encaisse : un morceau de musique ne
        // sait pas que la ligne est irrégulière.
        let music = SpeedGrade.uses.first { $0.title == "Musique en streaming" }!
        #expect(music.verdict(download: d, latency: l, jitter: j) == true)
    }

    @Test("Le jeu tient le seuil le plus serré : il n'a aucun tampon à opposer")
    func gamingIsStrictest() {
        let game = SpeedGrade.uses.first { $0.title == "Jeu en ligne" }!
        let video = SpeedGrade.uses.first { $0.title == "Visioconférence" }!

        // 40 ms de gigue : la visio encaisse, le jeu non.
        #expect(video.verdict(download: download, latency: latency, jitter: 0.040) == true)
        #expect(game.verdict(download: download, latency: latency, jitter: 0.040) == false)
    }

    @Test("Le résumé dit ce que la gigue coûte, et le nomme")
    func summaryNamesWhatJitterCosts() {
        let text = SpeedGrade.summary(download: 200_000, latency: 0.040, jitter: 0.153)
        // Le plafond descend jusqu'à la musique, puisque tout le temps réel tombe.
        #expect(text.contains("musique"))
        // Et la seconde phrase dit pourquoi, avec le chiffre.
        #expect(text.contains("gigue"))
        #expect(text.contains("153"))
        #expect(text.contains("visioconférence"))
        #expect(text.contains("jeu en ligne"))
    }

    @Test("Une ligne rapide mais irrégulière ne s'annonce pas simplement « 4K »")
    func fastButJitteryIsNotJustFast() {
        // Le cas le plus trompeur : tous les seuils de débit passent largement,
        // et pourtant c'est l'usage pour lequel on a lancé le test qui échoue.
        let text = SpeedGrade.summary(download: 26_900_000, latency: 0.040, jitter: 0.153)
        #expect(text.contains("4k"))
        #expect(text.contains("gigue"))
        #expect(text.contains("visioconférence"))
    }

    @Test("Une ligne régulière n'a pas de seconde phrase")
    func steadyLineSaysNothingMore() {
        let text = SpeedGrade.summary(download: download, latency: latency, jitter: jitter)
        #expect(text == "Suffisant jusqu'à : streaming 4k.")
    }

    @Test("« Limité par la gigue » ne se dit que si le reste passait")
    func jitterBlameIsPrecise() {
        let video = SpeedGrade.uses.first { $0.title == "Visioconférence" }!
        // Débit et latence bons, gigue mauvaise → c'est bien elle la coupable.
        #expect(video.limitedByJitter(download: download, latency: latency, jitter: 0.153))
        // Débit insuffisant : la gigue n'est pas ce qu'il faut corriger, et
        // l'accuser enverrait régler le mauvais problème.
        #expect(video.limitedByJitter(download: 50_000, latency: latency, jitter: 0.153) == false)
        // Tout va bien : rien à dire.
        #expect(video.limitedByJitter(download: download, latency: latency, jitter: jitter) == false)
        // Un usage sans plafond de gigue n'est jamais accusé.
        let music = SpeedGrade.uses.first { $0.title == "Musique en streaming" }!
        #expect(music.limitedByJitter(download: download, latency: latency, jitter: 0.153) == false)
    }

    // MARK: - Ce qu'on ne sait pas

    @Test("Un usage jugé sur la latence ne répond pas oui faute de latence")
    func unknownPropagates() {
        let game = SpeedGrade.uses.first { $0.title == "Jeu en ligne" }!
        // Sans latence mesurée, la ligne du jeu ne peut rien affirmer — même
        // avec un débit de fibre.
        #expect(game.verdict(download: 125_000_000, latency: nil, jitter: jitter) == nil)
        // Sans gigue non plus : c'est une exigence comme les autres.
        #expect(game.verdict(download: 125_000_000, latency: 0.030, jitter: nil) == nil)
        #expect(game.verdict(download: nil, latency: 0.030, jitter: 0.002) == true)
        #expect(game.verdict(download: nil, latency: 0.200, jitter: 0.002) == false)
    }

    @Test("Les trois exigences sont conjonctives")
    func allRequirementsMustHold() {
        let video = SpeedGrade.uses.first { $0.title == "Visioconférence" }!
        // Le débit passe largement, la latence non : une ligne satellite.
        #expect(video.verdict(download: download, latency: 0.400, jitter: jitter) == false)
        // La latence passe, le débit non.
        #expect(video.verdict(download: 100_000, latency: latency, jitter: jitter) == false)
        // Les trois passent.
        #expect(video.verdict(download: download, latency: latency, jitter: jitter) == true)
    }

    // MARK: - L'ordre

    @Test("Les exigences de débit sont croissantes")
    func listIsOrdered() {
        // C'est ce qui fait que la colonne des coches se remplit par le haut,
        // donc que la première ligne sans coche est la frontière de la ligne.
        //
        // **Ce test a trouvé un vrai défaut.** La première liste plaçait la
        // musique en streaming (0,32 Mbit/s) après les appels audio (0,5),
        // parce que la musique *semble* plus lourde qu'un appel. Sur une ligne
        // à 0,4 Mbit/s la colonne affichait coche, croix, coche.
        let graded = SpeedGrade.uses.compactMap(\.megabits)
        #expect(graded == graded.sorted())

        // Le jeu en ligne est la seule exception admise : il ne se juge pas sur
        // le débit, donc il n'a pas sa place sur cette échelle.
        #expect(SpeedGrade.uses.filter { $0.megabits == nil }.count == 1)

        // Et la conséquence recherchée, **sur une ligne régulière** : tout ce
        // qui est tenu précède tout ce qui ne l'est pas. La régularité, elle,
        // coupe en travers de cet ordre — c'est justement ce qui la rend digne
        // d'une phrase à part dans le résumé.
        let byBandwidth = SpeedGrade.uses.filter { $0.megabits != nil }
        let verdicts = byBandwidth.map { $0.verdict(download: 700_000, latency: 0.071, jitter: 0.002) }
        #expect(verdicts.drop(while: { $0 == true }).allSatisfy { $0 != true })
    }

    @Test("Le résumé nomme le plus exigeant des usages tenus")
    func summaryNamesTheCeiling() {
        #expect(SpeedGrade.summary(download: download, latency: latency, jitter: jitter).contains("4k"))
        // Une ligne à 6 Mbit/s : la HD passe, la 4K non.
        #expect(SpeedGrade.summary(download: 750_000, latency: latency, jitter: jitter).contains("hd"))
        // Rien mesuré du tout : on le dit, on n'invente pas une liste vide.
        #expect(SpeedGrade.summary(download: nil, latency: nil, jitter: nil) == "Rien n'a pu être mesuré.")
    }
}

@Suite("L'écriture des débits")
struct SpeedFormatTests {

    @Test("Le mégaoctet vaut 10⁶ octets, comme l'offre du fournisseur")
    func decimalMegabyte() {
        // En base 2, 14 300 000 octets s'écriraient 13,6 — l'écart se remarque,
        // et du mauvais côté : celui qui fait croire qu'on ne reçoit pas ce
        // qu'on paie.
        #expect(SpeedFormat.megabytes(14_300_000) == "14,3")
        #expect(SpeedFormat.megabits(14_300_000) == "114\u{202F}Mbit/s")
    }

    @Test("On ne sait pas, on le dit — et jamais « 0 »")
    func unknownIsNotZero() {
        #expect(SpeedFormat.megabytes(nil) == SpeedFormat.unknown)
        #expect(SpeedFormat.megabytes(.nan) == SpeedFormat.unknown)
        #expect(SpeedFormat.megabytes(-1) == SpeedFormat.unknown)
        #expect(SpeedFormat.milliseconds(nil) == SpeedFormat.unknown)
        // Une ligne très lente n'est pas une ligne morte.
        #expect(SpeedFormat.megabytes(20_000) == "<0,1")
        #expect(SpeedFormat.milliseconds(0.0001) == "<1\u{202F}ms")
    }

    @Test("La virgule est française, quelle que soit la région du Mac")
    func frenchDecimalSeparator() {
        // Toute l'interface de bran est en français en dur ; « 14.3 Mo/s » au
        // milieu d'une phrase française serait une faute visible.
        #expect(SpeedFormat.megabytes(14_300_000).contains(","))
        #expect(SpeedFormat.megabytes(14_300_000).contains(".") == false)
    }

    @Test("Le libellé de barre de menus garde une largeur fixe")
    func menuBarLabelIsPadded() {
        // Sans remplissage, passer de 9,8 à 10,2 décale l'icône et les quinze
        // icônes voisines, vingt fois par seconde.
        let narrow = SpeedFormat.menuBarLabel(4_200_000)
        let wide = SpeedFormat.menuBarLabel(15_500_000)
        #expect(narrow.count == wide.count)
        #expect(narrow.hasPrefix(ResourceFormat.figureSpace))
        #expect(SpeedFormat.menuBarLabel(nil) == "…")
    }

    @Test("Au-delà de mille, pas de séparateur de milliers")
    func noGroupingInLabels() {
        // Le séparateur de milliers français est une espace fine : « 1 200 »
        // dans un libellé de barre de menus se lit comme deux nombres. Même
        // règle que `ResourceFormat.percent`.
        #expect(SpeedFormat.megabits(150_000_000).contains("\u{202F}Mbit/s"))
        #expect(SpeedFormat.megabits(150_000_000) == "1200\u{202F}Mbit/s")
    }
}


@Suite("La relecture d'un relevé")
struct SpeedReadingCodingTests {

    @Test("Un relevé écrit par une version plus ancienne se relit encore")
    func missingKeysDecode() throws {
        // Le champ `spentBytes` est arrivé après coup. Le décodeur que Swift
        // synthétise échoue sur une clé absente **même quand la propriété a une
        // valeur par défaut** — et la lecture passant par un `try?`, l'échec
        // serait silencieux : le dernier relevé disparaîtrait à la mise à jour,
        // sans message.
        let legacy = Data(#"{"download":21500000,"latency":0.026}"#.utf8)
        let reading = try JSONDecoder().decode(SpeedReading.self, from: legacy)
        #expect(reading.download == 21_500_000)
        #expect(reading.latency == 0.026)
        #expect(reading.spentBytes == 0)
        #expect(reading.upload == nil)
    }

    @Test("Un aller-retour complet ne perd rien")
    func roundTrip() throws {
        let original = SpeedReading(
            download: 21_500_000, upload: 19_900_000,
            latency: 0.026, jitter: 0.001,
            source: "OVH — Roubaix",
            measuredAt: Date(timeIntervalSince1970: 1_788_000_000),
            spentBytes: 140_000_000
        )
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(SpeedReading.self, from: data) == original)
    }

    @Test("Un relevé vide se reconnaît")
    func emptiness() {
        #expect(SpeedReading().isEmpty)
        // Une latence seule suffit à ne plus être vide : c'est une mesure, et le
        // menu doit l'afficher plutôt que de faire comme si rien n'avait été
        // tenté.
        #expect(SpeedReading(latency: 0.026).isEmpty == false)
        #expect(SpeedReading(spentBytes: 80_000_000).isEmpty)
    }
}


@Suite("Pourquoi un sens manque")
struct SpeedMissTests {

    /// **Ce qui remplace `SpeedGateTests`.**
    ///
    /// Il y avait ici six cas qui vérifiaient un délai de trente secondes entre
    /// deux mesures. Le délai a été retiré — voir `SpeedPlan` — et les garder
    /// avec un plafond nul aurait produit exactement ce qu'un dépôt ne doit pas
    /// contenir : des tests qui passent en ne vérifiant rien.
    ///
    /// Ce qui les remplace teste la protection qui **reste**, et qui est la
    /// seule à porter du sens maintenant : quand la montée manque, le relevé
    /// dit-il à qui la faute ?

    @Test("Un refus du serveur ne se lit pas comme une panne de la ligne")
    func throttledBlamesTheServer() {
        // C'est toute la raison d'être du type. `429` veut dire « bran en a trop
        // demandé », jamais « votre connexion est cassée » — et les deux phrases
        // envoient faire deux choses opposées : attendre une minute, ou appeler
        // son opérateur.
        #expect(SpeedMiss.throttled.summary.contains("pas votre ligne"))
        #expect(SpeedMiss.unreachable.summary.contains("pas votre ligne") == false)
        // Les deux se présentent quand même comme ce qu'elles sont.
        #expect(SpeedMiss.throttled.summary.hasPrefix("Montée non mesurée"))
        #expect(SpeedMiss.unreachable.summary.hasPrefix("Montée non mesurée"))
    }

    @Test("Une montée manquée n'emporte pas une descente réussie")
    func downloadSurvivesAMissedUpload() {
        // Le serveur de montée est un autre hôte, avec ses propres pannes : un
        // relevé qui exigerait les quatre nombres jetterait trois mesures bonnes
        // à cause d'une quatrième.
        let reading = SpeedReading(
            download: 21_500_000, upload: nil, uploadMiss: .throttled,
            latency: 0.026, jitter: 0.001
        )
        #expect(reading.isEmpty == false)
        #expect(reading.download == 21_500_000)
        #expect(reading.uploadMiss == .throttled)
    }

    @Test("La raison se conserve d'un lancement à l'autre")
    func missSurvivesTheRoundTrip() throws {
        let original = SpeedReading(
            download: 21_500_000, uploadMiss: .unreachable,
            latency: 0.026, jitter: 0.001, spentBytes: 80_000_000
        )
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(SpeedReading.self, from: data) == original)
    }

    @Test("Un relevé écrit avant ce champ se relit sans raison, pas sans relevé")
    func olderReadingsDecode() throws {
        // Même défaut que celui que `spentBytes` a déjà coûté : un décodeur qui
        // échouerait sur la clé absente ferait disparaître, en silence, le
        // dernier relevé de quelqu'un qui met bran à jour.
        let legacy = Data(#"{"download":21500000,"upload":19900000,"spentBytes":140000000}"#.utf8)
        let reading = try JSONDecoder().decode(SpeedReading.self, from: legacy)
        #expect(reading.download == 21_500_000)
        #expect(reading.upload == 19_900_000)
        #expect(reading.uploadMiss == nil)
    }

    @Test("Un relevé complet n'a pas de raison à donner")
    func measuredUploadHasNoMiss() {
        let reading = SpeedReading(download: 21_500_000, upload: 19_900_000)
        #expect(reading.uploadMiss == nil)
    }
}
