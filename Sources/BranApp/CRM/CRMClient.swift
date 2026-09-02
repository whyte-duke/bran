import BranCore
import Foundation

/// Les six appels du contrat CRM, et rien d'autre.
///
/// Le jeton ne peut faire que ça : un jeton volé ne détruit pas de données.
/// Ce client respecte la même limite — il n'y a pas d'échappatoire vers le reste
/// du CRM, et pas de clé `service_role` en vue.
actor CRMClient {

    struct Failure: LocalizedError {
        let statusCode: Int
        let message: String

        var errorDescription: String? { message }

        /// Le jeton est refusé, ou la variable `CASTRAL_RECORDER_TOKEN` n'est
        /// pas définie côté serveur — sur Vercel, elle n'existe qu'au
        /// déploiement suivant son ajout.
        var isAuthenticationFailure: Bool { statusCode == 401 }
    }

    private let endpoint: URL
    private let token: String
    private let session: URLSession

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        // Le CRM renvoie de l'ISO 8601 avec ou sans fraction de seconde selon
        // les champs. Un décodeur unique doit accepter les deux.
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = ISO8601DateFormatter.branFractional.date(from: text) { return date }
            if let date = ISO8601DateFormatter.branPlain.date(from: text) { return date }
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Date illisible : \(text)"
            )
        }
        return decoder
    }()

    init(endpoint: URL, token: String, session: URLSession? = nil) {
        self.endpoint = endpoint
        self.token = token
        self.session = session ?? Self.controlSession
    }

    /// **Les appels de commande ne doivent pas pouvoir geler l'interface.**
    ///
    /// Aucune session CRM ne fixait `timeoutIntervalForResource` : seul
    /// `URLRequest.timeoutInterval` était réglé, et il ne borne que le silence
    /// entre deux octets. Un serveur qui répond une ligne toutes les vingt-cinq
    /// secondes tenait donc la requête indéfiniment, et l'écran des rendez-vous
    /// restait sur son tourniquet sans jamais rien dire. Ces deux valeurs bornent
    /// le tout : 15 s sans un octet, 30 s en tout.
    ///
    /// `waitsForConnectivity` reste faux ici : quand la ligne est coupée, un
    /// panneau qui dit « CRM injoignable » vaut mieux qu'un panneau qui attend.
    /// L'envoi des octets, lui, fait le choix inverse — voir `upload`.
    ///
    /// **Une seule session pour toute l'application**, et pas une par client :
    /// une `URLSession` construite avec un delegate se retient elle-même
    /// jusqu'à `invalidate`, et un client CRM est fabriqué à chaque
    /// rafraîchissement des rendez-vous — toutes les cinq minutes. Une session
    /// par client aurait fait fuir une session toutes les cinq minutes, plus ses
    /// connexions.
    private static let controlSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration, delegate: OriginGuard.shared, delegateQueue: nil)
    }()

    /// Le plafond d'une réponse de commande, en octets.
    ///
    /// `session.data(for:)` accumule tout le corps avant que qui que ce soit
    /// puisse regarder le code HTTP : le délai borne le temps, pas le volume.
    /// Une réponse `200` annonçant `content-length: 2147483648` avec deux
    /// gigaoctets de caractères dans un champ `label` était donc accumulée
    /// jusqu'à épuisement de la mémoire, sur une ligne rapide en quelques
    /// dizaines de secondes.
    ///
    /// 4 Mio laisse deux ordres de grandeur de marge : la réponse la plus
    /// lourde du contrat est `targets`, plafonnée à 100 rendez-vous, soit une
    /// cinquantaine de kilooctets.
    private static let maximumResponseBytes = 4 << 20

    // MARK: - 5.1 · À quel RDV rattacher

    func targets(from: Date? = nil, to: Date? = nil) async throws -> [CRMBooking] {
        var components = URLComponents(
            url: endpoint.appending(path: "api/transcriptions/targets"),
            resolvingAgainstBaseURL: false
        )
        var items: [URLQueryItem] = []
        if let from { items.append(.init(name: "from", value: ISO8601DateFormatter.branPlain.string(from: from))) }
        if let to { items.append(.init(name: "to", value: ISO8601DateFormatter.branPlain.string(from: to))) }
        components?.queryItems = items.isEmpty ? nil : items

        guard let url = components?.url else { throw Failure(statusCode: 0, message: "URL du CRM invalide.") }
        let targets: CRMTargets = try await send(request(url))
        return targets.bookings
    }

    // MARK: - 5.2 · Ouvrir le dépôt

    func createTranscription(_ body: CRMCreateRequest) async throws -> CRMCreateResponse {
        var urlRequest = request(endpoint.appending(path: "api/transcriptions"), method: "POST")
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.httpBody = try JSONEncoder().encode(body)
        return try await send(urlRequest)
    }

    // MARK: - 5.3 · Envoyer les octets

    /// Les octets vont **directement** du Mac à Supabase : une fonction Vercel
    /// plafonne à 4,5 Mo de corps, un closing pèse dix fois plus.
    ///
    /// Pas d'en-tête d'authentification : le jeton est dans l'URL, valable 2 h,
    /// pour un seul chemin. Le même `PUT` est rejouable tant qu'elle n'a pas
    /// expiré.
    /// **L'adresse de dépôt est vérifiée ici aussi**, et pas seulement chez
    /// l'appelant. Ce n'est pas la même décision écrite deux fois — les deux
    /// appellent `CRMOriginPolicy` — c'est la même décision posée aux deux
    /// endroits d'où l'audio peut sortir. Le jour où un second appelant
    /// apparaîtra, il ne pourra pas passer à côté.
    nonisolated func upload(
        file: URL,
        to uploadURL: URL,
        mimeType: String,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        // `endpoint` est un `let` de type `Sendable` : il se lit depuis ce
        // contexte non isolé sans passer par l'acteur.
        guard case .approved = CRMOriginPolicy.uploadDestination(
            uploadURL.absoluteString,
            crmHost: endpoint.host()
        ) else {
            throw Failure(statusCode: 0, message: "Adresse de dépôt refusée : \(uploadURL.absoluteString)")
        }

        var request = URLRequest(url: uploadURL)
        request.httpMethod = "PUT"
        request.setValue(mimeType, forHTTPHeaderField: "content-type")

        let delegate = UploadProgressDelegate(onProgress: onProgress)
        let session = URLSession(
            configuration: Self.uploadConfiguration(for: file),
            delegate: delegate,
            delegateQueue: nil
        )
        defer { session.finishTasksAndInvalidate() }

        let (data, response) = try await session.upload(for: request, fromFile: file)
        guard let http = response as? HTTPURLResponse else {
            throw Failure(statusCode: 0, message: "Réponse inattendue du stockage.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw Failure(
                statusCode: http.statusCode,
                message: (300..<400).contains(http.statusCode)
                    ? "Le stockage a renvoyé une redirection vers un autre hôte : envoi interrompu."
                    : "Envoi refusé par le stockage (\(http.statusCode)). \(body.prefix(200))"
            )
        }
    }

    /// Le délai total d'un envoi, dérivé du poids du fichier.
    ///
    /// Une borne fixe ne peut pas marcher : trop courte, elle refuse un closing
    /// de 50 Mo sur une ligne lente ; trop longue, elle laisse l'écran sur
    /// « Envoi 40 % » pendant une heure alors que le Wi-Fi est tombé. Elle est
    /// donc calculée à partir d'un plancher de débit délibérément pessimiste —
    /// 20 ko/s, soit 160 kbit/s — parce que la ligne mesurée sur cette machine
    /// varie du simple au double en une heure et qu'un plancher optimiste
    /// couperait un envoi qui avançait.
    ///
    /// Dix minutes au minimum, deux heures au plus : un fichier de 50 Mo obtient
    /// 42 minutes, ce qu'aucun envoi normal n'approche (mesuré : quelques
    /// dizaines de secondes).
    ///
    /// `waitsForConnectivity` est vrai ici, à l'inverse des appels de commande :
    /// une bascule Wi-Fi au milieu d'un envoi doit être attendue, pas comptée
    /// comme un échec — la borne totale ci-dessus reste le garde-fou.
    private nonisolated static func uploadConfiguration(for file: URL) -> URLSessionConfiguration {
        let attributes = try? FileManager.default.attributesOfItem(atPath: file.path(percentEncoded: false))
        let bytes = (attributes?[.size] as? Int) ?? 0

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = min(max(600, Double(bytes) / 20_000), 7200)
        configuration.waitsForConnectivity = true
        return configuration
    }

    // MARK: - 5.4 · Lancer le traitement

    /// Rejouable sans risque : un second appel répond `alreadyStarted` sans rien
    /// relancer. À partir d'ici, bran peut se fermer.
    @discardableResult
    func start(_ id: String) async throws -> CRMStartResponse {
        try await send(request(endpoint.appending(path: "api/transcriptions/\(id)/start"), method: "POST"))
    }

    // MARK: - 5.5 · Suivre

    func status(_ id: String) async throws -> CRMStatus {
        try await send(request(endpoint.appending(path: "api/transcriptions/\(id)/status")))
    }

    // MARK: - 5.6 · Réessayer

    func retry(_ id: String) async throws {
        _ = try await sendRaw(request(endpoint.appending(path: "api/transcriptions/\(id)/retry"), method: "POST"))
    }

    /// Autorisé **uniquement** si le statut vaut `uploading` ou `failed` : le
    /// jeton ne peut pas effacer un closing déjà transcrit.
    func deleteFailedUpload(_ id: String) async throws {
        _ = try await sendRaw(request(endpoint.appending(path: "api/transcriptions/\(id)"), method: "DELETE"))
    }

    // MARK: - Transport

    private func request(_ url: URL, method: String = "GET") -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(token, forHTTPHeaderField: "x-castral-recorder-token")
        // La même valeur que `timeoutIntervalForRequest` de la session, écrite
        // ici parce que `URLRequest.timeoutInterval` a le dernier mot : la
        // laisser à 30 aurait annulé en silence la borne de 15 s.
        request.timeoutInterval = 15
        return request
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let data = try await sendRaw(request)
        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            throw Failure(statusCode: 0, message: "Réponse du CRM illisible : \(error.localizedDescription)")
        }
    }

    /// **`bytes(for:)` et pas `data(for:)`, et c'est mesuré.**
    ///
    /// Le plafond de `maximumResponseBytes` ne peut pas être posé par un
    /// delegate : vérifié le 02/09/2026 contre un serveur local, ni un delegate
    /// de session ni un delegate de tâche ne reçoit
    /// `urlSession(_:dataTask:didReceive:)` quand on appelle `data(for:)` — les
    /// méthodes de commodité asynchrones accumulent le corps avec leur propre
    /// delegate interne. Huit mégaoctets arrivaient intégralement, delegate
    /// jamais appelé. Les rappels de **tâche**, eux, sont bien reçus : c'est ce
    /// qui rend `OriginGuard` possible.
    ///
    /// `bytes(for:)` rend l'en-tête avant le corps, donc l'annonce se refuse
    /// sans rien lire, et l'accumulation octet par octet permet de couper un
    /// serveur qui ment sur `content-length`. Le coût mesuré au même endroit :
    /// 11,28 Mo/s, soit 4 ms pour une réponse `targets` de 50 ko et 0,37 s pour
    /// atteindre le plafond de 4 Mio.
    private func sendRaw(_ request: URLRequest) async throws -> Data {
        let (stream, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw Failure(statusCode: 0, message: "Réponse inattendue du CRM.")
        }

        guard http.expectedContentLength <= Int64(Self.maximumResponseBytes) else {
            throw Failure(
                statusCode: http.statusCode,
                message: "Réponse du CRM démesurée : \(http.expectedContentLength) octets annoncés."
            )
        }

        var data = Data()
        data.reserveCapacity(min(Self.maximumResponseBytes, max(0, Int(http.expectedContentLength))))
        for try await byte in stream {
            data.append(byte)
            guard data.count <= Self.maximumResponseBytes else {
                throw Failure(
                    statusCode: http.statusCode,
                    message: "Réponse du CRM démesurée : plus de \(Self.maximumResponseBytes) octets reçus."
                )
            }
        }

        guard (300..<400).contains(http.statusCode) == false else {
            throw Failure(
                statusCode: http.statusCode,
                message: "Le CRM a renvoyé une redirection vers un autre hôte : requête abandonnée."
            )
        }

        guard (200..<300).contains(http.statusCode) else {
            // Le CRM répond toujours {"error": "..."} : le message est écrit
            // pour un humain, on le remonte tel quel plutôt que d'inventer.
            let message = (try? JSONDecoder().decode(CRMErrorBody.self, from: data))?.error
                ?? "Le CRM a répondu \(http.statusCode)."
            throw Failure(statusCode: http.statusCode, message: message)
        }

        return data
    }
}

/// **Aucune redirection ne change d'hôte.**
///
/// Sans ce garde, tout le contrôle d'origine se contourne d'un `302` : l'hôte
/// approuvé répond « c'est ailleurs », et `URLSession` obéit sans rien demander.
/// Deux fuites, pas une seule — les octets de la réunion pour l'envoi, et le
/// jeton du Trousseau pour les appels de commande, car `URLSession` ne retire
/// que l'en-tête `Authorization` sur une redirection inter-origine, jamais un
/// en-tête maison comme `x-castral-recorder-token`.
///
/// Mesuré le 02/09/2026 contre un serveur local : rendre `nil` au
/// `completionHandler` ne suit pas la redirection et livre le `302` tel quel à
/// l'appelant, corps vide. C'est `sendRaw` qui le transforme ensuite en erreur
/// lisible — un `3xx` n'est jamais un succès ici.
///
/// Sans état : la comparaison porte sur la requête d'origine de la tâche, donc
/// une seule instance sert toutes les sessions.
private final class OriginGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = OriginGuard()

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let origin = task.originalRequest?.url,
              let destination = request.url,
              CRMOriginPolicy.allowsRedirection(from: origin, to: destination)
        else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

/// `URLSession.upload(for:fromFile:)` ne rend la progression que par delegate.
private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Double) -> Void

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    /// Le même garde que `OriginGuard`, parce que cette session a déjà un
    /// delegate à elle : un `URLSessionTask` n'en consulte qu'un.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let origin = task.originalRequest?.url,
              let destination = request.url,
              CRMOriginPolicy.allowsRedirection(from: origin, to: destination)
        else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        onProgress(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }
}

extension ISO8601DateFormatter {
    /// Propriétés calculées : `ISO8601DateFormatter` n'est pas `Sendable`, et
    /// une instance statique partagée serait une course en puissance. La
    /// construction est négligeable devant un appel réseau.
    static var branFractional: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    static var branPlain: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }
}
