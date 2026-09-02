import BranCore
import Foundation

/// **Les octets, et rien d'autre.** Ce fichier ouvre des connexions, compte ce
/// qui passe, et ne calcule aucun débit — c'est `SpeedTally` qui le fait, dans
/// `BranCore`, sans réseau.
///
/// C'est le même partage que `ResourceProbe` / `ResourceReading`, et pour la
/// même raison : ce qui se teste vit d'un côté, ce qui dépend du monde vit de
/// l'autre. Ici, il n'y a rien à tester — un serveur répond ou ne répond pas — et
/// tout ce qui pouvait rendre un chiffre faux a été déménagé chez le voisin.
///
/// ## Pourquoi un délégué et pas `URLSession.bytes(for:)`
///
/// `AsyncBytes` est une suite d'**octets**. Mesurer 80 Mo par ce chemin
/// demanderait quatre-vingts millions de tours de boucle `await`, et le
/// processeur du test deviendrait la limite mesurée à la place de la ligne — un
/// compteur qui mesure sa propre lenteur est exactement la farce que
/// `ResourceMeter` documente déjà pour lui-même. `urlSession(_:dataTask:didReceive:)`
/// livre des `Data` de quelques dizaines de kilo-octets, ce qui fait un millier
/// d'appels au lieu de quatre-vingts millions.
enum SpeedProbe {

    /// Ce qui peut mal se passer, nommé — parce que les trois cas appellent
    /// trois phrases différentes à l'écran, et que « une erreur est survenue »
    /// n'aide personne à savoir si le problème vient de la ligne ou de bran.
    enum Failure: Error {
        /// Le service a demandé une pause : `429`. **Ce n'est pas la ligne.**
        /// Mesuré : après une rafale d'essais, `speed.cloudflare.com` a refusé
        /// les requêtes de plus de 5 Mo pendant plus de vingt minutes. C'est la
        /// raison pour laquelle une montée refusée n'emporte pas le test : elle
        /// se range en `SpeedMiss.throttled`, qui dit « attendez » et non
        /// « votre connexion est cassée ». C'est la seule protection qui reste
        /// depuis que le délai entre deux mesures a été retiré — voir
        /// `SpeedPlan` — et c'est celle qui compte, puisqu'elle nomme le
        /// coupable au lieu de le laisser deviner.
        case throttled
        /// Un code inattendu. Porté avec son numéro : c'est la seule chose qui
        /// permette de distinguer un serveur en panne d'un serveur qui a bougé.
        case refused(Int)
        /// La connexion elle-même n'a pas abouti.
        case unreachable(String)

        var summary: String {
            switch self {
            case .throttled:
                "Le serveur de mesure demande une pause. Réessayez dans une minute."
            case .refused(let code):
                "Le serveur de mesure a répondu \(code)."
            case .unreachable(let reason):
                "Impossible de joindre le serveur de mesure — \(reason)"
            }
        }

        /// Comment cet échec se **conserve** dans un relevé.
        ///
        /// Trois cas d'un côté, deux de l'autre, et c'est volontaire :
        /// `SpeedMiss` vit dans `BranCore` et n'a pas à connaître les codes HTTP.
        /// Ce qu'il doit distinguer tient en une question — est-ce le serveur qui
        /// nous freine, ou la ligne qui ne répond pas ? — et un `refused(503)`
        /// se range du second côté parce qu'on ne peut pas en dire plus sans
        /// inventer.
        var miss: SpeedMiss {
            switch self {
            case .throttled: .throttled
            case .refused, .unreachable: .unreachable
            }
        }
    }

    // MARK: - Le compteur partagé

    /// Ce que le délégué remplit et que l'interface lit, dix fois par seconde.
    ///
    /// **`@unchecked Sendable` justifié :** les deux propriétés mutables sont
    /// gardées par le verrou, qui est la seule voie d'accès — il n'y a pas
    /// d'accesseur qui les laisse fuir. Le patron est celui de
    /// `CaptureDelegate`, avec la même justification écrite au même endroit.
    ///
    /// **Le sens de la lecture, et il compte.** Le délégué *pousse* les octets
    /// depuis la file de la session ; l'interface *tire* un instantané depuis
    /// l'acteur principal. L'inverse — une fermeture appelée à chaque `Data`
    /// reçue, qui sauterait sur `@MainActor` — ferait mille sauts d'acteur par
    /// seconde pour redessiner une aiguille que l'œil ne suit qu'à trente
    /// images. C'est la même décision que la boucle de `ResourceMeter`.
    final class Counter: @unchecked Sendable {

        private let lock = NSLock()
        private var tally = SpeedTally()
        private var origin: SuspendingClock.Instant?
        private var stopped = false

        let budget: SpeedPlan.Budget

        init(budget: SpeedPlan.Budget) {
            self.budget = budget
        }

        /// Verse des octets. Rend `true` quand le budget est épuisé, c'est-à-dire
        /// quand l'appelant doit annuler la tâche.
        ///
        /// **L'origine est posée au premier octet, ici et nulle part ailleurs.**
        /// C'est la première des quatre règles de `SpeedTally`, et c'est le seul
        /// endroit du programme qui sache quand le premier octet est tombé : le
        /// délai avant ce premier octet a été mesuré jusqu'à 0,9 s, et le compter
        /// comme du transfert coûtait un quart du chiffre.
        @discardableResult
        func record(_ bytes: Int) -> Bool {
            lock.lock()
            defer { lock.unlock() }

            guard stopped == false else { return true }

            let now = SuspendingClock.now
            guard let origin else {
                origin = now
                tally.accept(elapsed: 0, bytes: bytes)
                return false
            }

            let span = origin.duration(to: now).components
            let elapsed = Double(span.seconds) + Double(span.attoseconds) / 1e18
            tally.accept(elapsed: elapsed, bytes: bytes)

            if budget.isSpent(elapsed: elapsed, bytes: tally.totalBytes) {
                stopped = true
                return true
            }
            return false
        }

        /// L'instantané que lit l'interface.
        var snapshot: SpeedTally {
            lock.lock()
            defer { lock.unlock() }
            return tally
        }

        /// L'instant du **premier octet**, `nil` tant qu'il n'est pas tombé.
        ///
        /// Lu par l'échéance murale de `run`, qui doit compter à partir du même
        /// zéro que le budget — sans quoi elle inclurait la résolution DNS et la
        /// poignée TLS, mesurées jusqu'à 0,9 s, dans les quatre secondes qu'on
        /// a promis de consacrer au transfert.
        var startedAt: SuspendingClock.Instant? {
            lock.lock()
            defer { lock.unlock() }
            return origin
        }
    }

    // MARK: - La descente

    /// Tire un gros fichier et compte, jusqu'à ce que le budget soit épuisé.
    ///
    /// **On coupe volontairement au milieu du fichier**, et c'est pour ça que
    /// les sources font un gigaoctet : un fichier qui se terminerait tout seul
    /// finirait le test sur une tranche partielle et un débit qui s'effondre,
    /// c'est-à-dire exactement le défaut que `SpeedTally` écarte à l'autre bout.
    /// La coupure n'est donc pas un abandon, c'est la fin normale.
    static func download(
        from source: SpeedPlan.Source,
        budget: SpeedPlan.Budget,
        userAgent: String,
        into counter: Counter
    ) async throws {
        var request = URLRequest(url: source.url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        // Sans ça, un intermédiaire — ou le serveur — pourrait servir une copie
        // en cache, et l'on mesurerait un disque local.
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        // La compression ferait mesurer un taux de compression et non une ligne.
        // Les fichiers de test sont incompressibles, mais le dire coûte une ligne
        // et ferme la question.
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

        try await run(request, counter: counter, budget: budget, kind: .download)
    }

    // MARK: - La montée

    /// Pousse un corps et compte ce qui part.
    ///
    /// **Ce qui est compté est ce que le noyau a accepté, pas ce que le serveur a
    /// reçu**, et il n'y a pas de meilleure mesure disponible côté client. La
    /// conséquence est connue : la mémoire tampon d'émission de la socket —
    /// quelques centaines de kilo-octets — part instantanément, donc la première
    /// fraction de seconde affiche un débit imaginaire. C'est précisément ce que
    /// la rampe d'une seconde de `SpeedTally` écarte, et c'est une raison de plus
    /// de ne pas la raccourcir.
    static func upload(
        budget: SpeedPlan.Budget,
        userAgent: String,
        into counter: Counter
    ) async throws {
        var request = URLRequest(url: SpeedPlan.uploadSource.url)
        request.httpMethod = "POST"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        // **Des zéros, et c'est sans conséquence.** La question habituelle — un
        // intermédiaire pourrait-il compresser une charge nulle et faire mesurer
        // un débit fantaisiste ? — ne se pose pas sous TLS : personne entre le
        // Mac et le serveur ne voit le corps, donc personne ne peut le
        // compresser. Fabriquer des octets aléatoires coûterait du processeur au
        // moment précis où l'on mesure autre chose.
        //
        // **Streamé, et non matérialisé, et c'est un correctif double.**
        //
        // Le corps valait `Data(count: budget.byteCap)`, soit 60 Mo alloués et
        // rendus résidents pendant la montée. Surtout, il **se terminait tout
        // seul** : 60 Mo à 30 Mo/s font deux secondes, et
        // `SpeedTally.plateauMean` réclame le plancher de 2,25 s — quatre
        // tranches closes après la rampe. Sur une fibre symétrique, le test
        // dépensait donc 60 Mo pour afficher « Montée — », sans erreur ni
        // explication, puisqu'il ne s'était rien passé d'anormal. Le plafond du
        // budget doit couper la mesure ; ce n'est pas au corps HTTP de décider
        // quand elle s'arrête.
        //
        // `/dev/zero` n'a pas de fin : c'est `Counter.record` qui annule au
        // budget, et l'échéance murale de `run` qui borne le reste. Le corps
        // sans longueur connue passe en `Transfer-Encoding: chunked` —
        // **vérifié contre le vrai serveur**, `speed.cloudflare.com/__up`
        // répond 200 et accepte le flux ; mesuré, 9,4 Mo montés en continu là
        // où le corps matérialisé en montait 10,5 pour 60 Mo alloués.
        guard let body = InputStream(fileAtPath: "/dev/zero") else {
            throw Failure.unreachable("le flux de montée n'a pas pu être ouvert")
        }
        request.httpBodyStream = body

        try await run(request, counter: counter, budget: budget, kind: .upload)
    }

    // MARK: - La latence

    /// Huit allers-retours minuscules. Voir `SpeedLatency` pour ce que ça mesure
    /// exactement — et pour ce que ça ne mesure pas, qui est un `ping`.
    ///
    /// **Une plage d'un octet.** Les deux sources répondent `206 Partial
    /// Content` à `Range: bytes=0-0` (vérifié), donc la sonde coûte un octet de
    /// charge utile et le reste est de l'en-tête. Demander le fichier entier et
    /// annuler tout de suite marcherait aussi, et laisserait le serveur pousser
    /// une fenêtre TCP entière dans le vide huit fois de suite.
    ///
    /// Une sonde qui échoue est **ignorée**, pas fatale : la latence est le seul
    /// des trois nombres dont l'absence n'empêche rien, et huit sondes existent
    /// justement pour qu'une de perdue ne coûte que sa part.
    static func latency(from source: SpeedPlan.Source, userAgent: String) async -> SpeedLatency {
        var request = URLRequest(url: SpeedPlan.latencyProbe(for: source))
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        // **Les deux délais sont posés, et sans eux la série n'a aucune borne.**
        //
        // `URLSessionConfiguration.ephemeral` part sur le défaut système :
        // 60 s d'inactivité par requête, aucune borne de durée totale. Neuf
        // sondes séquentielles par source et deux sources font donc, dans le
        // pire cas — un DNS qui ne répond pas, un serveur qui accepte la
        // connexion et se tait — **dix-huit minutes** avant que le test n'ait
        // seulement commencé à transférer quoi que ce soit. Le panneau reste
        // figé sur « Latence » tout ce temps, pour un nombre dont l'absence
        // n'empêche rien.
        //
        // Cinq secondes : la plus mauvaise ligne qu'on veuille mesurer est un
        // partage de connexion en bord de réseau, où l'aller-retour applicatif
        // — DNS, TLS, HTTP — reste très en dessous. Descendre plus bas
        // exclurait des lignes réelles ; c'est la borne haute d'un RTT
        // mesurable, pas une préférence.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 5
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        var latency = SpeedLatency()
        // **Trois échecs d'affilée arrêtent la série.** Chaque erreur était
        // ignorée et la boucle continuait : un serveur qui refuse coûtait neuf
        // délais au lieu d'un. Trois plutôt qu'un, parce qu'une perte isolée
        // est exactement ce que huit sondes existent pour absorber — c'est
        // écrit dans `SpeedLatency`.
        var consecutiveFailures = 0
        for _ in 0..<SpeedLatency.probeCount {
            if Task.isCancelled { break }
            let start = SuspendingClock.now
            do {
                _ = try await session.data(for: request)
                let d = start.duration(to: .now)
                latency.accept(Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18)
                consecutiveFailures = 0
            } catch {
                consecutiveFailures += 1
                if consecutiveFailures >= 3 { break }
                continue
            }
        }
        return latency
    }

    // MARK: - La mécanique commune

    fileprivate enum Kind { case download, upload }

    /// Lance la requête, compte, et s'arrête au budget.
    ///
    /// **Une annulation au budget n'est pas une erreur.** C'est la fin normale
    /// d'un test : `NSURLErrorCancelled` remonte du délégué et serait affiché
    /// comme une panne si on ne l'attrapait pas ici. Le tri se fait sur le code,
    /// pas sur un drapeau, parce que la vraie annulation — l'utilisateur qui
    /// ferme le panneau — passe par le même chemin et doit se taire pareil.
    /// Ce qu'on laisse à la résolution DNS et à la poignée TLS avant de
    /// renoncer. Trois secondes : le délai avant le premier octet a été mesuré
    /// jusqu'à 0,9 s sur cette ligne, et au-delà de trois il n'y a plus de
    /// serveur à mesurer, il y a une panne.
    private static let connectionGrace: TimeInterval = 3

    private static func run(
        _ request: URLRequest, counter: Counter, budget: SpeedPlan.Budget, kind: Kind
    ) async throws {
        let pump = Pump(counter: counter, kind: kind)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        // **`.responsiveData`, et surtout pas `.background`.**
        //
        // La première version demandait `.background`, au motif honorable que le
        // test doit pouvoir tourner pendant qu'une réunion s'enregistre et ne
        // pas voler la bande passante du flux de capture. C'était un bug, et la
        // sonde l'a montré en une exécution : `.background` demande au système
        // de **brider** le transfert, donc le compteur mesurait le bridage.
        // Les tranches montaient encore à la fin des quatre secondes — 0,4 puis
        // 1,4 … 12,8 puis 19,3 — au lieu de se poser sur un plateau, et le
        // résultat annonçait 10,5 Mo/s sur une ligne mesurée à 15 par ailleurs.
        //
        // Un compteur de débit est le seul endroit du programme où céder le
        // passage est une faute : il n'y a rien à mesurer d'autre que le débit
        // maximal, et un chiffre poli est un chiffre faux. La politesse est
        // ailleurs — dans les quatre secondes que dure le test, et dans le
        // délai qui sépare deux tests.
        configuration.networkServiceType = .responsiveData

        let session = URLSession(configuration: configuration, delegate: pump, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        do {
            // **Une échéance murale, parce que le budget n'était consulté qu'à
            // l'arrivée d'octets.**
            //
            // `Counter.record` décide d'arrêter, mais il n'est appelé que
            // depuis un callback de données. À 100 ko/s, ou après un premier
            // bloc suivi d'un gel de la ligne, le callback suivant peut arriver
            // bien après les quatre secondes annoncées — et rien d'autre ne
            // bornait la durée : `timeoutIntervalForRequest` est un délai
            // d'*inactivité* de 15 s, pas une durée totale, et il se réarme à
            // chaque paquet. Le bouton promettait une mesure courte et pouvait
            // attendre indéfiniment sur une ligne qui goutte.
            //
            // L'échéance compte à partir du **premier octet**, comme le budget :
            // partir de la requête ferait payer DNS et TLS sur le temps de
            // mesure. D'où la petite attente d'établissement, bornée à part.
            //
            // L'annulation de groupe est sûre ici, contrairement au cas de
            // `SpeedLinkProbe` : `Pump.run` est enveloppé dans un
            // `withTaskCancellationHandler` qui annule la tâche URLSession, ce
            // qui provoque `didCompleteWithError`, donc la reprise de sa
            // continuation. Rien ne reste suspendu.
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await pump.run(session: session, request: request) }
                group.addTask {
                    let giveUp = SuspendingClock.now.advanced(by: .seconds(Self.connectionGrace))
                    while counter.startedAt == nil {
                        guard SuspendingClock.now < giveUp else { return }
                        try await Task.sleep(for: .milliseconds(50), clock: .suspending)
                    }
                    guard let origin = counter.startedAt else { return }
                    try await Task.sleep(
                        until: origin.advanced(by: .seconds(budget.duration)),
                        clock: .suspending
                    )
                }

                // Le premier des deux tranche : soit le transfert s'est terminé
                // seul, soit l'échéance est tombée. Les deux sont des fins
                // normales, et `cancelAll` referme l'autre.
                try await group.next()
                group.cancelAll()
            }
        } catch let error as URLError where error.code == .cancelled {
            // Budget atteint, échéance murale, ou panneau refermé. Trois fins.
            return
        } catch is CancellationError {
            return
        } catch let error as URLError {
            throw Failure.unreachable(error.localizedDescription)
        }
    }
}

/// Le délégué qui compte. Séparé de `SpeedProbe` parce qu'il faut un objet, et
/// gardé privé parce que personne d'autre n'a de raison de le construire.
///
/// **`@unchecked Sendable` justifié :** `counter` et `kind` sont des constantes,
/// et la continuation n'est touchée que sous le verrou de `state`, qui garantit
/// aussi qu'elle n'est reprise qu'une fois — le seul défaut qui compte
/// réellement ici, puisque reprendre deux fois une continuation est un plantage
/// immédiat et non une valeur fausse.
private final class Pump: NSObject, URLSessionDataDelegate, @unchecked Sendable {

    private let counter: SpeedProbe.Counter
    private let isUpload: Bool
    private let state = NSLock()
    private var continuation: CheckedContinuation<Void, any Error>?
    private var finished = false

    init(counter: SpeedProbe.Counter, kind: SpeedProbe.Kind) {
        self.counter = counter
        self.isUpload = kind == .upload
    }

    func run(session: URLSession, request: URLRequest) async throws {
        let task = session.dataTask(with: request)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.lock()
                // La tâche appelante a pu être annulée avant même qu'on arrive
                // ici : sans ce garde, la continuation ne serait jamais reprise
                // et l'appel resterait suspendu pour toujours.
                if finished {
                    state.unlock()
                    continuation.resume()
                    return
                }
                self.continuation = continuation
                state.unlock()
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// Le code HTTP, décidé **avant** de compter un seul octet.
    ///
    /// Un `429` a un corps — une ligne de texte — et le compter comme du débit
    /// afficherait « 0,1 Mo/s » sur une ligne parfaitement saine. C'est le seul
    /// endroit où l'on peut encore refuser proprement.
    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse
    ) async -> URLSession.ResponseDisposition {
        guard let http = response as? HTTPURLResponse else { return .allow }
        switch http.statusCode {
        case 200...299:
            return .allow
        case 429:
            finish(with: SpeedProbe.Failure.throttled)
            return .cancel
        default:
            finish(with: SpeedProbe.Failure.refused(http.statusCode))
            return .cancel
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard isUpload == false else { return }
        if counter.record(data.count) { dataTask.cancel() }
    }

    /// La montée se compte ici : il n'y a pas de `Data` reçue à mesurer.
    ///
    /// `bytesSent` est l'incrément depuis le dernier appel, pas le cumul — le
    /// confondre avec `totalBytesSent` ferait croître le compteur en carré, et
    /// afficherait une ligne montante à plusieurs gigaoctets par seconde.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard isUpload else { return }
        if counter.record(Int(bytesSent)) { task.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        finish(with: error)
    }

    /// URLSession réclame un corps neuf : redirection, réauthentification, ou
    /// simple réessai. Un `InputStream` déjà consommé ne peut pas être rejoué,
    /// et sans cette méthode la requête échouerait avec un corps vide — un
    /// « 0 Mo/s » qui accuserait la ligne pour une mécanique HTTP.
    func urlSession(
        _ session: URLSession, task: URLSessionTask, needNewBodyStream completionHandler: @escaping (InputStream?) -> Void
    ) {
        completionHandler(isUpload ? InputStream(fileAtPath: "/dev/zero") : nil)
    }

    /// Reprend la continuation **une seule fois**. Trois chemins y mènent — un
    /// code refusé, la fin du transfert, l'annulation — et deux d'entre eux
    /// peuvent se produire coup sur coup : refuser un `429` provoque aussitôt un
    /// `didCompleteWithError` d'annulation.
    private func finish(with error: (any Error)?) {
        state.lock()
        guard finished == false else { return state.unlock() }
        finished = true
        let pending = continuation
        continuation = nil
        state.unlock()

        guard let pending else { return }
        if let error { pending.resume(throwing: error) } else { pending.resume() }
    }
}
