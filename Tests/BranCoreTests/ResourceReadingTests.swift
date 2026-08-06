import Foundation
import Testing
@testable import BranCore

/// **Un moniteur faux est pire qu'un moniteur absent.**
///
/// L'utilisateur ouvrira ce chiffre pour décider si bran a le droit de rester
/// installé : « la surveillance de mon PC au repos, c'est 2 % de mon
/// processeur, c'est ok ». Un `NaN`, un `0 %` de complaisance ou un pic de
/// 4 000 % au réveil ne se corrigent pas en confiance.
///
/// Tout ce qui suit se joue sur des entiers et des `TimeInterval` : ni noyau,
/// ni horloge, ni écran. C'est exactement pour ça que le calcul vit dans
/// `BranCore` et pas à côté des deux appels système.
@Suite("Ce que bran coûte")
struct ResourceReadingTests {

    /// 16 Go, comme la machine de référence (M2 Pro, 12 cœurs).
    private let totalMemory: UInt64 = 17_179_869_184
    private let cores = 12

    /// Une seconde de temps processeur, en nanosecondes. Consommée en une
    /// seconde de temps réel, elle vaut exactement 100 % — un cœur.
    private let oneCoreSecond: UInt64 = 1_000_000_000

    private func tracker() -> ResourceTracker { ResourceTracker() }

    // MARK: - La dérivée et ses cas dégénérés

    @Test("Deux échantillons au même instant ne fabriquent pas un NaN")
    func divisionParZero() {
        var tracker = tracker()
        tracker.accept(cpuNanoseconds: 0, footprintBytes: 300_000_000, totalMemoryBytes: totalMemory, elapsed: 2)
        tracker.accept(cpuNanoseconds: 2 * oneCoreSecond, footprintBytes: 300_000_000, totalMemoryBytes: totalMemory, elapsed: 2)
        #expect(tracker.reading.cpuPercent == 100)

        // Le même instant : dénominateur nul.
        let reading = tracker.accept(
            cpuNanoseconds: 2 * oneCoreSecond,
            footprintBytes: 300_000_000,
            totalMemoryBytes: totalMemory,
            elapsed: 0
        )

        #expect(reading.cpuPercent?.isNaN == false)
        #expect(reading.cpuPercent == 100)
        #expect(ResourceFormat.percent(reading.cpuPercent) == "100")
    }

    /// Le compteur de référence ne doit pas être remplacé par l'échantillon d'un
    /// intervalle nul : sinon le tic suivant calculerait sa dérivée sur une
    /// durée qu'il n'a pas observée.
    @Test("Un intervalle nul ne perd pas le point de référence")
    func intervalleNulNePerdPasLaReference() {
        var tracker = tracker()
        tracker.accept(cpuNanoseconds: 0, footprintBytes: 0, totalMemoryBytes: totalMemory, elapsed: 2)
        tracker.accept(cpuNanoseconds: 0, footprintBytes: 0, totalMemoryBytes: totalMemory, elapsed: 0)

        // Une seconde de CPU sur deux secondes : 50 %, compté depuis zéro.
        let reading = tracker.accept(
            cpuNanoseconds: oneCoreSecond,
            footprintBytes: 0,
            totalMemoryBytes: totalMemory,
            elapsed: 2
        )
        #expect(reading.cpuPercent == 50)
    }

    @Test("Un intervalle négatif rend l'occupation inconnue, pas nulle")
    func deltaTemporelNegatif() {
        var tracker = tracker()
        tracker.accept(cpuNanoseconds: 0, footprintBytes: 0, totalMemoryBytes: totalMemory, elapsed: 2)
        tracker.accept(cpuNanoseconds: oneCoreSecond, footprintBytes: 0, totalMemoryBytes: totalMemory, elapsed: 2)
        #expect(tracker.reading.cpuPercent != nil)

        let reading = tracker.accept(
            cpuNanoseconds: 2 * oneCoreSecond,
            footprintBytes: 0,
            totalMemoryBytes: totalMemory,
            elapsed: -5
        )

        #expect(reading.cpuPercent == nil)
        #expect(ResourceFormat.percent(reading.cpuPercent) == "—")
    }

    /// « 0 % » se lirait « bran ne coûte rien ». La mémoire, elle, est un niveau
    /// et non une dérivée : elle est juste dès le premier échantillon.
    @Test("Le tout premier échantillon rend une occupation inconnue, jamais 0 %")
    func premierEchantillon() {
        var tracker = tracker()
        let reading = tracker.accept(
            cpuNanoseconds: 5 * oneCoreSecond,
            footprintBytes: 335_000_000,
            totalMemoryBytes: totalMemory,
            elapsed: 2
        )

        #expect(reading.cpuPercent == nil)
        #expect(ResourceFormat.percent(reading.cpuPercent) == "—")
        #expect(reading.memoryBytes == 335_000_000)
        #expect(reading.memoryPercent != nil)
    }

    /// Un compteur cumulé ne recule pas. S'il recule quand même, la soustraction
    /// en `UInt64` déborderait vers dix-huit milliards de milliards de
    /// nanosecondes — soit un pourcentage à dix-neuf chiffres dans la barre de
    /// menus.
    @Test("Un compteur CPU qui recule est borné à zéro, pas à l'infini")
    func compteurQuiRecule() {
        var tracker = tracker()
        tracker.accept(cpuNanoseconds: 5 * oneCoreSecond, footprintBytes: 0, totalMemoryBytes: totalMemory, elapsed: 2)

        let reading = tracker.accept(
            cpuNanoseconds: oneCoreSecond,
            footprintBytes: 0,
            totalMemoryBytes: totalMemory,
            elapsed: 2
        )

        #expect(reading.cpuPercent == 0)
        #expect(ResourceFormat.percent(reading.cpuPercent) == "<1")
    }

    /// Le piège déjà payé une fois dans ce dépôt, sur les durées du veilleur
    /// (correctif CR-2). `WatchClock` le détecte, ce tracker s'y fie : le
    /// premier échantillon après un réveil est jeté, et la fenêtre de lissage
    /// avec — une médiane qui mélangerait l'avant et l'après-veille ne décrirait
    /// aucun moment réel.
    @Test("Le premier échantillon après un réveil de veille est jeté")
    func reveilDeVeille() {
        var tracker = tracker()
        tracker.accept(cpuNanoseconds: 0, footprintBytes: 0, totalMemoryBytes: totalMemory, elapsed: 2)
        tracker.accept(cpuNanoseconds: oneCoreSecond, footprintBytes: 0, totalMemoryBytes: totalMemory, elapsed: 2)
        #expect(tracker.reading.cpuPercent == 50)

        // Le tic du réveil : huit heures de veille, un compteur qui a très peu
        // avancé, un `elapsed` qui ne décrit rien.
        let wake = tracker.accept(
            cpuNanoseconds: oneCoreSecond + 3_000_000,
            footprintBytes: 400_000_000,
            totalMemoryBytes: totalMemory,
            elapsed: 2,
            clockJumped: true
        )
        #expect(wake.cpuPercent == nil)
        // La mémoire, elle, reste lisible : elle n'a pas de dérivée à fausser.
        #expect(wake.memoryBytes == 400_000_000)

        // Et le tic suivant repart proprement du nouveau point de référence.
        let after = tracker.accept(
            cpuNanoseconds: oneCoreSecond + 3_000_000 + oneCoreSecond,
            footprintBytes: 400_000_000,
            totalMemoryBytes: totalMemory,
            elapsed: 2
        )
        #expect(after.cpuPercent == 50)
    }

    // MARK: - La mémoire

    @Test("Une mémoire totale nulle rend une part inconnue, pas une division par zéro")
    func memoireTotaleNulle() {
        #expect(ResourceMath.memoryPercent(footprint: 300_000_000, total: 0) == nil)

        var tracker = tracker()
        let reading = tracker.accept(
            cpuNanoseconds: 0,
            footprintBytes: 300_000_000,
            totalMemoryBytes: 0,
            elapsed: 2
        )
        #expect(reading.memoryPercent == nil)
        #expect(ResourceFormat.percent(reading.memoryPercent) == "—")
    }

    /// La comptabilité mémoire de macOS est compressée : `phys_footprint` peut
    /// dépasser la mémoire installée. « 103 % de la RAM » détruirait la
    /// crédibilité de tout le panneau.
    @Test("Une empreinte supérieure à la mémoire installée est bornée à 100 %")
    func empreinteSuperieureAuTotal() {
        #expect(ResourceMath.memoryPercent(footprint: 20_000_000_000, total: totalMemory) == 100)
        #expect(ResourceMath.memoryPercent(footprint: totalMemory, total: totalMemory) == 100)
    }

    // MARK: - Le formatage

    @Test("Sous un pour cent, on écrit « <1 » et jamais « 0 »")
    func formatageSousUnPourCent() {
        #expect(ResourceFormat.percent(0) == "<1")
        #expect(ResourceFormat.percent(0.4) == "<1")
        #expect(ResourceFormat.percent(0.999) == "<1")
        #expect(ResourceFormat.percent(1) == "1")
        // Une valeur négative ne peut pas venir du calcul, mais la fonction est
        // publique : « -0 » serait le pire des trois affichages.
        #expect(ResourceFormat.percent(-3) == "<1")
    }

    /// 104 % est légitime, et c'est tout l'intérêt de la convention retenue :
    /// celle du Moniteur d'activité, où 100 % vaut **un cœur**. Le nombre
    /// coïncide donc avec celui qu'on lit en recoupant.
    @Test("Cent pour cent et au-delà s'affichent tels quels")
    func formatageAuDelaDeCent() {
        #expect(ResourceFormat.percent(100) == "100")
        #expect(ResourceFormat.percent(104.4) == "104")
        #expect(ResourceFormat.percent(1200) == "1200")
        // Pas de séparateur de milliers : « 1 200 » se lirait comme deux nombres.
        #expect(ResourceFormat.percent(1200).contains(" ") == false)

        // La lecture normalisée est offerte à côté, pas à la place.
        let reading = ResourceReading(cpuPercent: 104.4)
        #expect(reading.cpuShare(cores: cores).map { ($0 * 10).rounded() / 10 } == 8.7)
        #expect(ResourceFormat.share(reading.cpuShare(cores: cores)) == "8,7\u{202F}%")
        // Zéro cœur ne peut pas venir du système, mais diviser sans regarder
        // rendrait un infini.
        #expect(reading.cpuShare(cores: 0) == nil)
    }

    @Test("Un état inconnu s'écrit « — », jamais « 0 »")
    func etatInconnu() {
        #expect(ResourceFormat.percent(nil) == "—")
        #expect(ResourceFormat.percent(.nan) == "—")
        #expect(ResourceFormat.percent(.infinity) == "—")
        #expect(ResourceFormat.share(nil) == "—")
        #expect(ResourceFormat.bytes(nil) == "—")
        #expect(ResourceFormat.percentSigned(nil) == "—")
        #expect(ResourceFormat.menuBarLabel(cpu: nil, memory: nil).contains("0") == false)
    }

    // MARK: - Le lissage

    /// Attendre trois tics avant d'afficher quoi que ce soit ferait six secondes
    /// de « — » à chaque lancement, ce qui ressemble à une panne.
    @Test("Une fenêtre partielle rend quand même la médiane de ce qu'on a")
    func medianeSurFenetrePartielle() {
        var median = SlidingMedian(capacity: 3)

        median.push(4)
        #expect(median.value == 4)

        median.push(10)
        #expect(median.value == 7)

        median.push(6)
        #expect(median.value == 6)

        // Et le pic isolé, la raison d'être de la médiane : une capture d'écran
        // du veilleur tombée dans l'intervalle ne doit pas déteindre.
        median.push(30)
        #expect(median.value == 10)
        median.push(5)
        #expect(median.value == 6)
    }

    @Test("Une fenêtre vide ne rend pas zéro, elle rend inconnu")
    func medianeSurFenetreVide() {
        var median = SlidingMedian(capacity: 3)
        #expect(median.value == nil)

        median.push(7)
        median.forget()
        #expect(median.value == nil)

        // Un NaN ne doit pas entrer : il rendrait l'ordre du tri indéfini.
        median.push(.nan)
        #expect(median.value == nil)
    }

    // MARK: - Le libellé

    /// Un élément de barre de menus qui change de largeur pousse l'horloge du
    /// système à chaque pic. Le remplissage se fait en U+2007 FIGURE SPACE, dont
    /// la définition *est* la largeur d'un chiffre.
    @Test("La largeur du libellé ne bouge pas d'une valeur à l'autre")
    func largeurDuLibelleStable() {
        let reference = ResourceFormat.menuBarLabel(cpu: 2, memory: 2).count
        #expect(reference == 7)

        var widths: Set<Int> = []
        for cpu in stride(from: 0.0, through: 999, by: 7) {
            for memory in stride(from: 0.0, through: 100, by: 3) {
                widths.insert(ResourceFormat.menuBarLabel(cpu: cpu, memory: memory).count)
            }
        }
        widths.insert(ResourceFormat.menuBarLabel(cpu: nil, memory: nil).count)
        widths.insert(ResourceFormat.menuBarLabel(cpu: 0.2, memory: 0.4).count)
        #expect(widths == [reference])

        // L'exception documentée, et la seule : au-delà de 999 % — les dix cœurs
        // pris par bran seul — le libellé s'élargit d'un caractère plutôt que de
        // réserver ce quatrième chiffre en permanence.
        #expect(ResourceFormat.menuBarLabel(cpu: 1200, memory: 11).count == reference + 1)
    }

    /// Au repos, « 2·2 » reste « 2·2 » : environ quatre mises à jour sur cinq
    /// n'ont rien à annoncer, et les laisser passer ferait redessiner la barre de
    /// menus toutes les deux secondes pour les mêmes pixels.
    @Test("Une chaîne inchangée ne déclenche aucune mise à jour")
    func chaineInchangeeNeDeclencheRien() {
        var gate = LabelGate()

        #expect(gate.offer("␣␣2·␣␣2") == true)
        #expect(gate.offer("␣␣2·␣␣2") == false)
        #expect(gate.offer("␣␣2·␣␣2") == false)
        #expect(gate.offer("104·␣11") == true)
        #expect(gate.offer("104·␣11") == false)
        #expect(gate.published == "104·␣11")

        // Le cas réel : deux échantillons différents qui rendent le même
        // libellé. C'est là que se gagnent les 80 %.
        var gate2 = LabelGate()
        #expect(gate2.offer(ResourceFormat.menuBarLabel(cpu: 2.1, memory: 1.9)) == true)
        #expect(gate2.offer(ResourceFormat.menuBarLabel(cpu: 2.4, memory: 2.2)) == false)
    }

    // MARK: - Les deux lectures côte à côte

    @Test("La mémoire installée se lit en base 2 et l'empreinte en base 10, comme sur le Mac")
    func lesDeuxBasesDOctets() {
        // « À propos de ce Mac » annonce 16 Go pour 17 179 869 184 octets.
        #expect(ResourceFormat.installedMemory(totalMemory).hasPrefix("16"))
        // Le Moniteur d'activité affiche 335 Mo pour 335 000 000 octets.
        #expect(ResourceFormat.bytes(335_000_000).hasPrefix("335"))
    }

    /// La lecture complète d'un repos plausible, bout en bout : c'est la ligne
    /// que le README doit pouvoir citer.
    @Test("Un repos plausible se lit « 2·2 » et rien d'autre")
    func lectureAuRepos() {
        var tracker = tracker()
        let footprint: UInt64 = 350_000_000

        tracker.accept(cpuNanoseconds: 0, footprintBytes: footprint, totalMemoryBytes: totalMemory, elapsed: 2)
        // 2 % d'un cœur pendant deux secondes : 40 ms de temps processeur.
        for tick in 1 ... 3 {
            tracker.accept(
                cpuNanoseconds: UInt64(tick) * 40_000_000,
                footprintBytes: footprint,
                totalMemoryBytes: totalMemory,
                elapsed: 2
            )
        }

        #expect(tracker.reading.cpuPercent == 2)
        #expect(ResourceFormat.percent(tracker.reading.memoryPercent) == "2")
        let label = ResourceFormat.menuBarLabel(
            cpu: tracker.reading.cpuPercent,
            memory: tracker.reading.memoryPercent
        )
        #expect(label.replacingOccurrences(of: ResourceFormat.figureSpace, with: "") == "2·2")
    }
}

// MARK: - La frontière entre le noyau et le calcul

/// **Les tests que le premier jet ne pouvait pas avoir.**
///
/// Tout le reste de ce fichier vérifie l'arithmétique *en supposant* que le
/// noyau rend des nanosecondes. Il n'en rend pas : `proc_pid_rusage` compte des
/// unités de `mach_absolute_time`, qui valent 41,67 ns sur Apple Silicon. Le
/// défaut vivait exactement là où il n'y avait aucun test — entre l'appel
/// système et le calcul — et il faisait afficher 4 % un chargement de modèle qui
/// occupait un cœur entier.
@Suite("Unités du temps processeur")
struct ResourceTimebaseTests {

    @Test("Sur Apple Silicon, une unité mach vaut 41,67 nanosecondes")
    func appleSilicon() {
        // 125/3 est la base de temps mesurée sur M2 Pro.
        let ticks: UInt64 = 23_996_610
        let nanoseconds = ResourceMath.nanoseconds(machTicks: ticks, numer: 125, denom: 3)
        #expect(nanoseconds != nil)
        // Une seconde de mur brûlée sur un fil doit rendre ~1 milliard de ns.
        let seconds = Double(nanoseconds ?? 0) / 1e9
        #expect(seconds > 0.95 && seconds < 1.05)
    }

    @Test("Sur Intel, la conversion est l'identité")
    func intel() {
        #expect(ResourceMath.nanoseconds(machTicks: 1_000_000, numer: 1, denom: 1) == 1_000_000)
    }

    @Test("Une base de temps nulle ne divise pas par zéro")
    func degenerate() {
        #expect(ResourceMath.nanoseconds(machTicks: 42, numer: 125, denom: 0) == nil)
        #expect(ResourceMath.nanoseconds(machTicks: 42, numer: 0, denom: 3) == nil)
    }

    @Test("Un compteur absurde rend inconnu au lieu de déborder")
    func overflow() {
        #expect(ResourceMath.nanoseconds(machTicks: .max, numer: 125, denom: 3) == nil)
    }

    @Test("Le pourcentage traverse la conversion sans se perdre")
    func endToEnd() {
        // Un cœur saturé pendant deux secondes : 2 s de temps CPU sur 2 s de mur.
        let ticks = UInt64(2.0 * 1e9 / (125.0 / 3.0))
        let nanoseconds = ResourceMath.nanoseconds(machTicks: ticks, numer: 125, denom: 3)
        let percent = ResourceMath.cpuPercent(deltaNanoseconds: nanoseconds ?? 0, elapsed: 2)
        #expect(percent != nil)
        // Convention Moniteur d'activité : 100 % = un cœur.
        #expect(abs((percent ?? 0) - 100) < 1)
    }
}
