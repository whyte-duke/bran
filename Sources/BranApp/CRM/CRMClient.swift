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

    init(endpoint: URL, token: String, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.token = token
        self.session = session
    }

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
    nonisolated func upload(
        file: URL,
        to uploadURL: URL,
        mimeType: String,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "PUT"
        request.setValue(mimeType, forHTTPHeaderField: "content-type")

        let delegate = UploadProgressDelegate(onProgress: onProgress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let (data, response) = try await session.upload(for: request, fromFile: file)
        guard let http = response as? HTTPURLResponse else {
            throw Failure(statusCode: 0, message: "Réponse inattendue du stockage.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw Failure(
                statusCode: http.statusCode,
                message: "Envoi refusé par le stockage (\(http.statusCode)). \(body.prefix(200))"
            )
        }
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
        request.timeoutInterval = 30
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

    private func sendRaw(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw Failure(statusCode: 0, message: "Réponse inattendue du CRM.")
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

/// `URLSession.upload(for:fromFile:)` ne rend la progression que par delegate.
private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Double) -> Void

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
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
