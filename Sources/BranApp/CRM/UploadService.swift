import BranCore
import Foundation
import Observation

/// Orchestration de l'envoi : extraction audio → dépôt → octets → lancement →
/// suivi.
@MainActor
@Observable
final class UploadService {

    private(set) var states: [UUID: UploadState] = [:]

    let configuration = CRMConfiguration()

    private let store: RecordingStore
    private var trackers: [UUID: Task<Void, Never>] = [:]

    init(store: RecordingStore) {
        self.store = store
    }

    func state(for id: UUID) -> UploadState? { states[id] }

    private func client() -> CRMClient? { configuration.makeClient() }

    // MARK: - Choix du RDV

    /// Fenêtre de ±2 h autour du début de l'enregistrement, comme le §5.1.
    func resolveBooking(for recording: Recording) async throws -> BookingResolution {
        guard let client = client() else {
            throw CRMClient.Failure(statusCode: 0, message: "Liaison CRM non configurée.")
        }

        let start = recording.metadata.startedAt
        let bookings = try await client.targets(
            from: start.addingTimeInterval(-12 * 3600),
            to: start.addingTimeInterval(12 * 3600)
        )

        let window: TimeInterval = 2 * 3600
        let near = bookings
            .filter { abs($0.start_at.timeIntervalSince(start)) <= window }
            .sorted { abs($0.start_at.timeIntervalSince(start)) < abs($1.start_at.timeIntervalSince(start)) }

        guard let best = near.first else { return .none(bookings) }

        // Un seul candidat ET rien de déjà déposé dessus : le seul cas où
        // décider tout seul est légitime. Sinon on demande — le dernier
        // compte-rendu généré gagne sur `bookings.notes`.
        // Un RDV sans entreprise ne peut pas être retenu automatiquement : il
        // n'est pas envoyable, et le présenter comme évident serait trompeur.
        if near.count == 1, best.hasExistingTranscription == false, best.company != nil {
            return .unique(best)
        }
        return .ambiguous(near)
    }

    /// Tous les rendez-vous consultables, pour une recherche manuelle.
    ///
    /// Fenêtre de 90 jours — le maximum que le contrat autorise — et 100 RDV
    /// au plus. Au-delà, l'API tronque sans le dire : `wasTruncated` permet de
    /// le signaler plutôt que de laisser croire à une liste exhaustive.
    struct SearchResults: Sendable {
        let bookings: [CRMBooking]
        var wasTruncated: Bool { bookings.count >= 100 }
    }

    private var searchCache: (results: SearchResults, fetchedAt: Date)?

    func searchableBookings(forceRefresh: Bool = false) async -> SearchResults {
        if forceRefresh == false,
           let cache = searchCache,
           Date.now.timeIntervalSince(cache.fetchedAt) < 120 {
            return cache.results
        }

        guard let client = client() else { return SearchResults(bookings: []) }

        do {
            let bookings = try await client.targets(
                from: Date.now.addingTimeInterval(-45 * 24 * 3600),
                to: Date.now.addingTimeInterval(45 * 24 * 3600)
            )
            let results = SearchResults(bookings: bookings.sorted { $0.start_at > $1.start_at })
            searchCache = (results, .now)
            return results
        } catch {
            return SearchResults(bookings: [])
        }
    }

    // MARK: - Envoi

    /// Dernier verrou avant l'envoi.
    ///
    /// Le contrôle est ici et pas seulement dans l'interface : un envoi
    /// automatique, une reprise après redémarrage ou un futur raccourci clavier
    /// passeraient à côté d'une garde qui ne vivrait que dans une vue.
    @discardableResult
    func send(_ recording: Recording, to booking: CRMBooking, complement: String?) -> Bool {
        let eligibility = UploadEligibility.evaluate(booking: booking, isConfigured: configuration.isConfigured)
        guard eligibility.canSend else {
            states[recording.id] = .failed(eligibility.blockingReason ?? "Envoi impossible.")
            return false
        }

        guard trackers[recording.id] == nil else { return false }

        trackers[recording.id] = Task { [weak self] in
            await self?.perform(recording, booking: booking, complement: complement)
            self?.trackers[recording.id] = nil
        }
        return true
    }

    /// Réévalue l'admissibilité en rafraîchissant la vue du CRM.
    /// Sert après avoir rattaché le lead côté CRM.
    func eligibility(for recording: Recording, in directory: MeetingDirectory) async -> UploadEligibility {
        await directory.refresh()

        let booking: CRMBooking?
        if let bookingID = recording.metadata.bookingID {
            booking = directory.bookings.first { $0.booking_id == bookingID }
        } else {
            booking = (try? await resolveBooking(for: recording))?.booking
        }

        return UploadEligibility.evaluate(booking: booking, isConfigured: configuration.isConfigured)
    }

    private func perform(_ recording: Recording, booking: CRMBooking, complement: String?) async {
        guard let client = client() else {
            states[recording.id] = .failed("Liaison CRM non configurée.")
            return
        }

        // **Le piège de cette méthode.** Avant, l'audio partait toujours dans le
        // dossier temporaire et un `defer` inconditionnel l'effaçait en
        // sortant. Maintenant qu'il a le droit de rester à côté de la vidéo,
        // un `defer` inconditionnel effacerait le fichier que l'utilisateur
        // vient justement de demander à garder — et il l'effacerait aussi sur
        // le chemin de réutilisation, c'est-à-dire un fichier que cette méthode
        // n'a même pas produit.
        //
        // D'où cette variable : elle ne vaut quelque chose que dans le cas où
        // bran a écrit dans son propre dossier temporaire, et le `defer` la lit
        // à la sortie, donc après que `prepareAudio` a tranché.
        var temporaryFile: URL?
        defer {
            if let temporaryFile { try? FileManager.default.removeItem(at: temporaryFile) }
        }

        do {
            // Le même état pour les deux chemins : que l'audio soit extrait ou
            // relu, ce que l'utilisateur voit est « bran prépare le fichier ».
            // Sur le chemin de réutilisation il ne dure que le temps d'un
            // `AVURLAsset`, et inventer un état de plus pour ça n'aurait servi
            // qu'à faire clignoter l'interface.
            states[recording.id] = .extractingAudio
            let prepared = try await prepareAudio(for: recording)
            temporaryFile = prepared.temporary
            let audio = prepared.audio

            let created = try await client.createTranscription(
                CRMCreateRequest(
                    source_type: "booking",
                    booking_id: booking.booking_id,
                    filename: fileName(for: recording, booking: booking),
                    mime_type: audio.mimeType,
                    size_bytes: audio.sizeBytes,
                    audio_duration_ms: audio.durationMilliseconds,
                    max_speakers: configuration.maxSpeakers,
                    created_by: configuration.author.rawValue,
                    summary_complement: complement?.isEmpty == false ? complement : nil
                )
            )

            await store.mutate(recording.id) { metadata in
                metadata.transcriptionID = created.id
                metadata.bookingID = booking.booking_id
                metadata.companyID = booking.company?.id
                metadata.companyName = booking.company?.nom
                metadata.crmStage = CRMStage.upload.rawValue
                metadata.crmError = nil
                metadata.uploadedAt = .now
            }

            guard let uploadURL = URL(string: created.upload.url) else {
                throw CRMClient.Failure(statusCode: 0, message: "URL d'envoi invalide.")
            }

            states[recording.id] = .uploading(0)
            try await client.upload(
                file: audio.url,
                to: uploadURL,
                mimeType: audio.mimeType
            ) { fraction in
                Task { @MainActor [weak self] in
                    self?.states[recording.id] = .uploading(fraction)
                }
            }

            states[recording.id] = .starting
            try await client.start(created.id)

            // À partir d'ici, bran n'a plus aucune obligation : tout l'état vit
            // en base. Fermer l'app ne change rien au traitement.
            await track(recording.id, transcriptionID: created.id, client: client)
        } catch {
            let message = error.localizedDescription
            states[recording.id] = .failed(message)
            await store.mutate(recording.id) { $0.crmError = message }
        }
    }

    /// Le fichier audio à envoyer, et — s'il y en a un — celui qu'il faudra
    /// effacer en sortant.
    ///
    /// Trois chemins, dans cet ordre.
    ///
    /// 1. **L'audio est déjà là et il est bon** : on le réutilise tel quel.
    ///    Ré-encoder trente-six minutes d'audio qu'on possède déjà, c'est
    ///    plusieurs minutes prises à l'utilisateur pour produire un fichier
    ///    identique à celui qui est sous ses yeux. Sa taille et sa durée sont
    ///    relues sur le disque (`inspectPreparedAudio`) : les métadonnées de
    ///    l'enregistrement décrivent la vidéo, pas ce `.m4a`, et le CRM compare
    ///    ce qu'on lui annonce à ce qu'il reçoit.
    /// 2. **L'enregistrement a un dossier** : on extrait vers
    ///    `audioDestination` et on **garde** le fichier. C'est ce que
    ///    l'utilisateur a demandé : l'audio du rendez-vous à côté de sa vidéo,
    ///    disponible sans repasser par bran. Le prochain envoi tombera alors
    ///    dans le cas 1.
    /// 3. **Ancien enregistrement à plat** (`audioDestination == nil`) : il n'y
    ///    a pas de dossier où déposer quoi que ce soit, et semer des `.m4a`
    ///    dans la racine de la bibliothèque à côté des vidéos serait un gain
    ///    douteux payé par du désordre permanent. On repasse par le dossier
    ///    temporaire et on efface en sortant, exactement comme avant.
    private func prepareAudio(
        for recording: Recording
    ) async throws -> (audio: AudioExporter.Result, temporary: URL?) {
        if let existing = recording.audioURL,
           isAudioStillCurrent(existing, for: recording),
           let reused = await AudioExporter.inspectPreparedAudio(at: existing) {
            return (reused, nil)
        }

        // **Rien à nettoyer ici, et surtout rien à effacer.**
        //
        // Cette fonction effaçait la destination quand l'extraction échouait,
        // pour qu'un fichier à moitié écrit ne devienne pas l'`audioURL` du
        // prochain envoi — plus récent que la vidéo, d'une durée parfaitement
        // lisible, donc réutilisé sans que rien ne paraisse anormal, et le CRM
        // aurait transcrit la moitié de la réunion.
        //
        // Le problème est réglé une couche plus bas, et mieux :
        // `extractSpeechAudio` encode désormais dans un brouillon posé à côté et
        // ne le met en place qu'une fois mesuré. La destination n'est donc
        // jamais à moitié écrite — et l'effacer ici ferait exactement le dégât
        // qu'on cherchait à éviter, puisqu'elle contient l'audio VALABLE de
        // l'envoi précédent, celui qu'on vient de décider de ne pas réutiliser.
        func extract(to destination: URL) async throws -> AudioExporter.Result {
            try await AudioExporter.extractSpeechAudio(from: recording.url, to: destination)
        }

        if let destination = recording.audioDestination {
            let audio = try await extract(to: destination)
            return (audio, nil)
        }

        let scratch = FileManager.default.temporaryDirectory
            .appending(path: "\(recording.id.uuidString).m4a")
        let audio = try await extract(to: scratch)
        return (audio, scratch)
    }

    /// L'audio conservé décrit-il encore la vidéo qui est sur le disque ?
    ///
    /// **Réutiliser sans vérifier enverrait au CRM un audio périmé**, et c'est
    /// un scénario réel, pas théorique : la vidéo finale est réécrite après
    /// coup — recollage des morceaux puis passe de compression — et une session
    /// interrompue peut être reprise et refusionnée bien après qu'un premier
    /// envoi a préparé son `.m4a`. Le compte-rendu porterait alors sur une
    /// version de la réunion qui n'existe plus, sans que rien ne le signale :
    /// la taille et la durée seraient cohérentes, simplement fausses.
    ///
    /// La comparaison porte sur les dates de modification, avec une seconde de
    /// tolérance pour la granularité du système de fichiers. Comparer les
    /// durées était l'autre piste : plus intuitif, mais un recollage change
    /// rarement la durée totale de plus d'une image — il aurait laissé passer
    /// précisément le cas qu'on cherche à attraper.
    ///
    /// Vidéo illisible (fichier déplacé, disque externe débranché) : on garde
    /// l'audio. C'est alors la seule trace de la réunion, et refuser de
    /// l'envoyer au nom d'une comparaison impossible n'aiderait personne.
    private func isAudioStillCurrent(_ audioURL: URL, for recording: Recording) -> Bool {
        func modificationDate(of url: URL) -> Date? {
            let attributes = try? FileManager.default
                .attributesOfItem(atPath: url.path(percentEncoded: false))
            return attributes?[.modificationDate] as? Date
        }

        guard let audioDate = modificationDate(of: audioURL) else { return false }
        guard let videoDate = modificationDate(of: recording.url) else { return true }

        return audioDate >= videoDate.addingTimeInterval(-1)
    }

    /// `Closing_2026-08-04_orpheo.m4a` — lisible dans le CRM sans avoir à
    /// décoder un UUID.
    private func fileName(for recording: Recording, booking: CRMBooking) -> String {
        let day = recording.metadata.startedAt.formatted(
            Date.ISO8601FormatStyle(timeZone: .current).year().month().day()
        )
        let who = (booking.company?.domain ?? booking.detected_domain ?? booking.attendee_name ?? "closing")
            .replacing(" ", with: "-")
        return "Closing_\(day)_\(who).m4a"
    }

    // MARK: - Suivi

    /// Cadence de 4 s, comme le §5.5 le conseille. Ne jamais descendre sous 2 s.
    private func track(_ id: UUID, transcriptionID: String, client: CRMClient) async {
        while Task.isCancelled == false {
            do {
                let status = try await client.status(transcriptionID)
                apply(status, to: id)

                if status.stage.isTerminal { return }
            } catch {
                states[id] = .failed(error.localizedDescription)
                return
            }

            try? await Task.sleep(for: .seconds(4))
        }
    }

    private func apply(_ status: CRMStatus, to id: UUID) {
        switch status.stage {
        case .ready:
            states[id] = .ready(summary: status.summary?.resume)
        case .failed:
            states[id] = .failed(status.error ?? "Transcription impossible.")
        case .upload, .queued, .transcribing, .summarizing:
            states[id] = .processing(
                stage: status.stage,
                progress: status.progress ?? 0,
                label: status.label
            )
        }

        Task { [store] in
            await store.mutate(id) { metadata in
                metadata.crmStage = status.stage.rawValue
                metadata.crmError = status.error
                metadata.crmWarning = status.warning
                metadata.companyID = status.company?.id ?? metadata.companyID
                metadata.companyName = status.company?.nom ?? metadata.companyName
                if let summary = status.summary {
                    metadata.crmSummary = summary.resume
                    metadata.crmIssue = summary.issue_rdv
                    metadata.crmTemperature = summary.temperature_lead
                }
            }
        }
    }

    /// Reprend le suivi des jobs laissés en plan par une fermeture de l'app.
    ///
    /// Le CRM n'envoie aucune notification : c'est à bran de redemander. L'état
    /// complet étant en base, il suffit de réinterroger `/status`.
    func resumeTracking(_ recordings: [Recording]) {
        // **Ce qu'il y a à reprendre est décidé avant qu'un client existe**, et
        // l'ordre inverse était un défaut qui se voyait au démarrage :
        // `client()` lit le jeton dans le Trousseau, donc ouvre l'alerte système
        // « bran veut accéder à la clé … » — et il le faisait même quand aucun
        // enregistrement n'était en cours de traitement, c'est-à-dire dans
        // l'immense majorité des lancements. Cette méthode est appelée à
        // l'ouverture de la fenêtre, que macOS restaure tout seul à l'ouverture
        // de session : l'alerte arrivait donc à chaque démarrage du Mac, pour un
        // travail qui n'existait pas.
        //
        // Filtrer d'abord ne coûte rien — c'est de la lecture de métadonnées
        // déjà en mémoire — et ne change rien au comportement quand il y a
        // vraiment un suivi à reprendre.
        let pending = recordings.filter { recording in
            guard recording.metadata.transcriptionID != nil,
                  trackers[recording.id] == nil,
                  states[recording.id]?.isFinished != true
            else { return false }

            let stage = recording.metadata.crmStage.flatMap(CRMStage.init(rawValue:))
            return stage?.isTerminal != true
        }

        guard pending.isEmpty == false, let client = client() else { return }

        for recording in pending {
            guard let transcriptionID = recording.metadata.transcriptionID else { continue }
            trackers[recording.id] = Task { [weak self] in
                await self?.track(recording.id, transcriptionID: transcriptionID, client: client)
                self?.trackers[recording.id] = nil
            }
        }
    }

    func retry(_ recording: Recording) {
        guard let client = client(), let transcriptionID = recording.metadata.transcriptionID else { return }

        trackers[recording.id]?.cancel()
        trackers[recording.id] = Task { [weak self] in
            do {
                try await client.retry(transcriptionID)
                await self?.track(recording.id, transcriptionID: transcriptionID, client: client)
            } catch {
                self?.states[recording.id] = .failed(error.localizedDescription)
            }
            self?.trackers[recording.id] = nil
        }
    }

    /// Vérifie que le jeton est accepté, sans rien envoyer.
    func testConnection() async -> String {
        guard let client = client() else {
            return "Renseignez l'adresse du CRM et un jeton commençant par « rec_ »."
        }
        do {
            let bookings = try await client.targets()
            return "Connexion établie — \(bookings.count) rendez-vous dans la fenêtre par défaut."
        } catch let failure as CRMClient.Failure where failure.isAuthenticationFailure {
            return "Jeton refusé. Vérifiez qu'il est bien défini côté serveur, et que le CRM a été redéployé depuis."
        } catch {
            return error.localizedDescription
        }
    }
}
