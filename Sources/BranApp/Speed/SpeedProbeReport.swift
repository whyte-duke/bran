import BranCore
import Foundation

/// **La sonde de débit en ligne de commande**, sur le modèle de
/// `PasteboardAccessProbe` : un drapeau explicite, un rapport, et une sortie
/// sans jamais afficher d'interface.
///
/// Elle existe pour la raison qui a fait écrire l'autre : le jour où quelqu'un
/// annonce un chiffre qui lui paraît faux, la question est « le compteur
/// se trompe-t-il, ou la ligne est-elle vraiment à ça ? ». Sans cette porte, il
/// faut relancer l'application, ouvrir un panneau, et croire ce qu'il montre.
/// Avec elle, on voit **les tranches une par une** — la rampe, le plateau, les
/// creux — c'est-à-dire la matière première du calcul et non son résultat.
///
/// ```
///   ./bran --speed-probe
/// ```
enum SpeedProbeReport {

    private static let flag = "--speed-probe"

    static func runIfRequested() -> Bool {
        guard CommandLine.arguments.contains(flag) else { return false }

        let semaphore = DispatchSemaphore(value: 0)
        Task {
            await run()
            semaphore.signal()
        }
        semaphore.wait()
        return true
    }

    private static func run() async {
        let userAgent = SpeedPlan.userAgent(version: "sonde")
        print("── débit : ce que la ligne rend vraiment ────────────────────────")
        print("annoncé          : \(userAgent)")
        print("")

        // La latence d'abord : elle est bon marché et elle dit tout de suite si
        // la source répond.
        let source = SpeedPlan.downloadSources[0]
        let latency = await SpeedProbe.latency(from: source, userAgent: userAgent)
        print("source           : \(source.name)")
        print("sondes           : \(latency.samples.map { String(format: "%.0f", $0 * 1000) }.joined(separator: " ")) ms")
        print("                   ↑ la 1re est l'ouverture de connexion (DNS + TLS), elle est retirée")
        print("latence          : \(SpeedFormat.milliseconds(latency.latency))")
        print("gigue            : \(SpeedFormat.milliseconds(latency.jitter))")
        print("")

        await leg("descente", budget: .quick, reading: \.rate) { counter in
            try await SpeedProbe.download(
                from: source, budget: .quick, userAgent: userAgent, into: counter
            )
        }

        // La montée s'intègre au lieu de se médianer. Voir `SpeedTally.plateauMean`
        // pour la suite quantifiée qui a imposé ce choix.
        await leg("montée", budget: .upload, reading: \.plateauMean) { counter in
            try await SpeedProbe.upload(
                budget: .upload, userAgent: userAgent, into: counter
            )
        }
    }

    /// Un aller, chronométré et **détaillé tranche par tranche**.
    ///
    /// C'est le détail qui fait tout l'intérêt de la sonde : un chiffre seul ne
    /// permet pas de distinguer une ligne lente d'une ligne qui décroche, alors
    /// que la suite des tranches montre la différence d'un coup d'œil.
    private static func leg(
        _ title: String,
        budget: SpeedPlan.Budget,
        reading: KeyPath<SpeedTally, Double?>,
        body: (SpeedProbe.Counter) async throws -> Void
    ) async {
        let counter = SpeedProbe.Counter(budget: budget)
        let start = ContinuousClock.now
        do {
            try await body(counter)
        } catch let failure as SpeedProbe.Failure {
            print("\(title) : ✗ \(failure.summary)")
            print("")
            return
        } catch {
            print("\(title) : ✗ \(error.localizedDescription)")
            print("")
            return
        }

        let tally = counter.snapshot
        print("\(title)")
        print("  durée          : \(start.duration(to: .now))")
        print("  consommé       : \(SpeedFormat.spent(tally.totalBytes))")
        print("  tranches       : \(tally.rates.map { String(format: "%.1f", $0 / 1e6) }.joined(separator: " "))")
        print("                   ↑ les \(SpeedTally.rampWindows) premières sont écartées (montée en régime)")
        print("  RÉSULTAT       : \(SpeedFormat.megabytesSigned(tally[keyPath: reading]))  ·  \(SpeedFormat.megabits(tally[keyPath: reading]))")
        // Ce que le calcul naïf aurait rendu, pour que l'écart reste visible et
        // qu'on n'ait pas à croire la table de `SpeedTally` sur parole.
        let naive = Double(tally.totalBytes) / max(0.001, Double(tally.rates.count) * SpeedTally.window)
        print("  (naïf : \(SpeedFormat.megabytesSigned(naive)) — tout divisé par tout)")
        print("")
    }
}
