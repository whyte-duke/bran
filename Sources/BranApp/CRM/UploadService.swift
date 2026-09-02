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

    /// Le travail en cours pour un enregistrement, et **son jeton**.
    ///
    /// Le jeton corrige une panne qui se voyait à l'écran : `retry` annulait la
    /// tâche A puis rangeait B sous la même clé, mais A finissait toujours par
    /// exécuter son effacement — `trackers[id] = nil` — après l'installation de
    /// B. Un troisième clic lançait donc C alors que B tournait encore, et les
    /// deux publiaient états et métadonnées dans un ordre indéterminé. A
    /// affichait en prime son erreur d'annulation comme un échec, sur un envoi
    /// qui venait de repartir.
    ///
    /// Rien n'est publié ni effacé sans que le jeton soit encore celui du
    /// travail courant.
    private struct Job {
        let token: UUID
        let task: Task<Void, Never>
    }

    private var jobs: [UUID: Job] = [:]

    /// Le dernier rendez-vous visé pour cet enregistrement, dans cette session.
    ///
    /// C'est ce qui rend « Réessayer » utile quand l'échec précède la création
    /// côté CRM : sans identifiant de transcription, il n'y avait rien à
    /// reprendre et le bouton ne faisait **rien du tout** — DNS tombé pendant
    /// `createTranscription`, l'utilisateur voit l'erreur, clique, et rien ne se
    /// passe. Le rendez-vous choisi, lui, est toujours connu : il vient d'être
    /// choisi.
    private var lastAttempt: [UUID: (booking: CRMBooking, complement: String?)] = [:]

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

        // Un seul candidat, et un candidat que bran a le droit de viser tout
        // seul : le seul cas où décider sans demander est légitime. Sinon on
        // demande — le dernier compte-rendu généré gagne sur `bookings.notes`.
        //
        // La condition n'est plus écrite ici : c'est `MeetingUploadPolicy` qui
        // la tient, la même que celle du dernier verrou avant l'envoi. Les deux
        // avaient divergé, et un rendez-vous annulé passait pour « évident ».
        let admissible = MeetingUploadPolicy.refusal(
            target: best.uploadTarget,
            isConfigured: true,
            intent: .automatic
        ) == nil
        if near.count == 1, admissible {
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

        /// **Ce qui a empêché la recherche d'aboutir**, ou `nil` quand la liste
        /// est celle du CRM.
        ///
        /// Sans ce champ, toute panne — réseau coupé, jeton refusé, réponse
        /// illisible — était convertie en succès vide, et la feuille affichait
        /// « Aucun rendez-vous proche ». L'utilisateur en concluait que son
        /// rendez-vous n'existait pas et remettait l'envoi à plus tard, pour un
        /// CRM qui était simplement injoignable.
        var problem: String?

        var wasTruncated: Bool { bookings.count >= 100 }

        init(bookings: [CRMBooking], problem: String? = nil) {
            self.bookings = bookings
            self.problem = problem
        }
    }

    private var searchCache: (results: SearchResults, fetchedAt: Date)?

    func searchableBookings(forceRefresh: Bool = false) async -> SearchResults {
        if forceRefresh == false,
           let cache = searchCache,
           Date.now.timeIntervalSince(cache.fetchedAt) < 120 {
            return cache.results
        }

        guard let client = client() else {
            return SearchResults(bookings: [], problem: "Liaison CRM non configurée — voir les Réglages.")
        }

        do {
            let bookings = try await client.targets(
                from: Date.now.addingTimeInterval(-45 * 24 * 3600),
                to: Date.now.addingTimeInterval(45 * 24 * 3600)
            )
            let results = SearchResults(bookings: bookings.sorted { $0.start_at > $1.start_at })
            searchCache = (results, .now)
            return results
        } catch {
            // La liste précédente est conservée : périmée vaut mieux que vide,
            // à condition de dire qu'elle est périmée. Le cache n'est pas
            // rafraîchi, donc la prochaine ouverture réessaiera.
            return SearchResults(
                bookings: searchCache?.results.bookings ?? [],
                problem: "CRM injoignable : \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Envoi

    /// Dernier verrou avant l'envoi.
    ///
    /// Le contrôle est ici et pas seulement dans l'interface : un envoi
    /// automatique, une reprise après redémarrage ou un futur raccourci clavier
    /// passeraient à côté d'une garde qui ne vivrait que dans une vue.
    ///
    /// - Parameter intent: `.automatic` par défaut, c'est-à-dire le régime le
    ///   plus strict. Un appelant qui oublie de se déclarer se voit appliquer
    ///   les gardes de l'envoi automatique — rendez-vous clos, compte-rendu déjà
    ///   déposé — et non l'inverse. Seule la feuille de choix, où quelqu'un a lu
    ///   l'avertissement et cliqué, passe `.manual`.
    @discardableResult
    func send(
        _ recording: Recording,
        to booking: CRMBooking,
        complement: String?,
        intent: UploadIntent = .automatic
    ) -> Bool {
        let eligibility = UploadEligibility.evaluate(
            booking: booking,
            isConfigured: configuration.isConfigured,
            intent: intent
        )
        guard eligibility.canSend else {
            states[recording.id] = .failed(eligibility.blockingReason ?? "Envoi impossible.")
            return false
        }

        guard jobs[recording.id] == nil else { return false }

        lastAttempt[recording.id] = (booking, complement)
        start(for: recording.id) { [weak self] token in
            await self?.perform(recording, booking: booking, complement: complement, token: token)
        }
        return true
    }

    /// Range un travail sous le jeton qui lui appartient, et ne l'efface à la
    /// sortie que si personne n'a pris sa place entre-temps.
    private func start(
        for id: UUID,
        cancellingCurrent: Bool = false,
        _ work: @escaping @MainActor (UUID) async -> Void
    ) {
        if let existing = jobs[id] {
            guard cancellingCurrent else { return }
            existing.task.cancel()
        }

        let token = UUID()
        let task = Task { @MainActor [weak self] in
            await work(token)
            if self?.jobs[id]?.token == token { self?.jobs[id] = nil }
        }
        jobs[id] = Job(token: token, task: task)
    }

    /// Publie un état **si le travail qui le publie est encore celui en cours**.
    private func publish(_ state: UploadState, for id: UUID, token: UUID) {
        guard jobs[id]?.token == token else { return }
        states[id] = state
    }

    /// Une annulation n'est pas un échec, et elle arrive sous **deux** formes.
    ///
    /// `CancellationError` quand la tâche est annulée entre deux appels, mais
    /// `URLError.cancelled` quand elle l'est pendant une requête — c'est
    /// `URLSession` qui répond, pas Swift Concurrency. Ne traiter que la
    /// première laissait un « Échec : annulé » s'afficher par-dessus l'envoi qui
    /// venait justement de repartir.
    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        return (error as? URLError)?.code == .cancelled
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

        // `.manual` : ce chemin est le bouton « Revérifier » du détail d'un
        // enregistrement, et il mène à la feuille de choix, pas à un envoi
        // automatique. Répondre `.automatic` afficherait « impossible » sur un
        // rendez-vous que l'utilisateur a parfaitement le droit de viser.
        return UploadEligibility.evaluate(
            booking: booking,
            isConfigured: configuration.isConfigured,
            intent: .manual
        )
    }

    private func perform(
        _ recording: Recording,
        booking: CRMBooking,
        complement: String?,
        token: UUID
    ) async {
        guard let client = client() else {
            publish(.failed("Liaison CRM non configurée."), for: recording.id, token: token)
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
            publish(.extractingAudio, for: recording.id, token: token)
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

            // **C'est ici que l'audio d'un client pouvait partir n'importe où.**
            //
            // `created.upload.url` vient de la réponse du CRM, et le seul garde
            // était `URL(string:)` — qui accepte `http://100.64.3.7/upload`
            // aussi volontiers qu'une URL signée Supabase. La ligne suivante
            // était un `PUT` du MP3 entier vers cette adresse. Un CRM mal
            // configuré, une réponse falsifiée en chemin, et le closing complet
            // se retrouvait en clair sur une machine choisie par la réponse,
            // avec la même barre de progression que d'habitude.
            //
            // La règle — HTTPS, hôte approuvé, pas d'identifiant, pas de
            // redirection hors origine — vit dans `CRMOriginPolicy`, avec ses
            // tests. `CRMClient.upload` la repose de son côté : deux portes, une
            // seule décision.
            let destination = CRMOriginPolicy.uploadDestination(
                created.upload.url,
                crmHost: configuration.endpoint?.host()
            )
            guard let uploadURL = destination.url else {
                throw CRMClient.Failure(
                    statusCode: 0,
                    message: "Adresse d'envoi refusée par bran — "
                        + (destination.refusal?.message ?? "origine non autorisée.")
                )
            }

            publish(.uploading(0), for: recording.id, token: token)
            try await client.upload(
                file: audio.url,
                to: uploadURL,
                mimeType: audio.mimeType
            ) { fraction in
                Task { @MainActor [weak self] in
                    self?.publish(.uploading(fraction), for: recording.id, token: token)
                }
            }

            publish(.starting, for: recording.id, token: token)
            try await client.start(created.id)

            // À partir d'ici, bran n'a plus aucune obligation : tout l'état vit
            // en base. Fermer l'app ne change rien au traitement.
            await track(recording.id, transcriptionID: created.id, client: client, token: token)
        } catch {
            // Une reprise a pris la place : ce n'est pas un échec, et l'afficher
            // comme tel effacerait l'état de l'envoi qui vient de repartir.
            guard Self.isCancellation(error) == false else { return }
            guard jobs[recording.id]?.token == token else { return }
            let message = error.localizedDescription
            publish(.failed(message), for: recording.id, token: token)
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
    ///    l'enregistrement décrivent la vidéo, pas ce `.mp3`, et le CRM compare
    ///    ce qu'on lui annonce à ce qu'il reçoit.
    /// 2. **L'enregistrement a un dossier** : on extrait vers
    ///    `audioDestination` et on **garde** le fichier. C'est ce que
    ///    l'utilisateur a demandé : l'audio du rendez-vous à côté de sa vidéo,
    ///    disponible sans repasser par bran. Le prochain envoi tombera alors
    ///    dans le cas 1.
    /// 3. **Ancien enregistrement à plat** (`audioDestination == nil`) : il n'y
    ///    a pas de dossier où déposer quoi que ce soit, et semer des `.mp3`
    ///    dans la racine de la bibliothèque à côté des vidéos serait un gain
    ///    douteux payé par du désordre permanent. On repasse par le dossier
    ///    temporaire et on efface en sortant, exactement comme avant.
    private func prepareAudio(
        for recording: Recording
    ) async throws -> (audio: AudioExporter.Result, temporary: URL?) {
        // **La réutilisation exige le chemin que bran écrirait aujourd'hui**, et
        // pas seulement « un audio trouvé dans le dossier ».
        //
        // Le balayage rend aussi les audios hérités — les `.m4a` d'avant le
        // 31/08/2026, que le CRM refuse désormais de décoder. Comparer à
        // `audioDestination` les écarte par construction : ils ne sont pas à ce
        // chemin, donc jamais candidats, et l'envoi ré-extrait en MP3. Filtrer
        // sur l'extension aurait marché aussi, mais aurait demandé d'y repenser
        // au prochain changement de format ; ici la règle est « ce que
        // l'extraction produirait », qui reste vraie sans qu'on y touche.
        if let existing = recording.audioURL,
           existing == recording.audioDestination,
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
            .appending(path: "\(recording.id.uuidString).\(MeetingFolder.audioExtension)")
        let audio = try await extract(to: scratch)
        return (audio, scratch)
    }

    /// L'audio conservé décrit-il encore la vidéo qui est sur le disque ?
    ///
    /// **Réutiliser sans vérifier enverrait au CRM un audio périmé**, et c'est
    /// un scénario réel, pas théorique : la vidéo finale est réécrite après
    /// coup — recollage des morceaux puis passe de compression — et une session
    /// interrompue peut être reprise et refusionnée bien après qu'un premier
    /// envoi a préparé son audio. Le compte-rendu porterait alors sur une
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

    /// `Closing_2026-08-04_orpheo.mp3` — lisible dans le CRM sans avoir à
    /// décoder un UUID.
    ///
    /// L'extension vient de `MeetingFolder` et n'est pas écrite en dur : le CRM
    /// range le fichier sous ce nom-là dans son stockage, et un nom qui mentirait
    /// sur le format rendrait indéchiffrable, six mois plus tard, la question
    /// « qu'est-ce qu'Azure a réellement reçu ce jour-là ».
    private func fileName(for recording: Recording, booking: CRMBooking) -> String {
        let day = recording.metadata.startedAt.formatted(
            Date.ISO8601FormatStyle(timeZone: .current).year().month().day()
        )
        let who = (booking.company?.domain ?? booking.detected_domain ?? booking.attendee_name ?? "closing")
            .replacing(" ", with: "-")
        return "Closing_\(day)_\(who).\(MeetingFolder.audioExtension)"
    }

    // MARK: - Suivi

    /// Cadence de 4 s, comme le §5.5 le conseille. Ne jamais descendre sous 2 s.
    ///
    /// **Mais pas 4 s pour toujours.** La boucle n'avait ni durée maximale, ni
    /// nombre d'interrogations, ni recul : un traitement bloqué sur `queued` —
    /// Azure en panne, worker mort — produisait 21 600 requêtes par jour et par
    /// Mac, sans qu'une seule ligne le dise à qui que ce soit. La cadence
    /// s'écarte donc avec le temps, et le suivi s'arrête en le disant.
    ///
    /// Les paliers viennent de ce qu'on sait du traitement : les premières
    /// minutes sont celles où l'étape change vraiment (dépôt → file → Azure),
    /// après quoi le rythme utile est celui d'un humain qui regarde de temps en
    /// temps.
    private static func pollDelay(afterElapsed elapsed: Duration) -> Duration {
        switch elapsed {
        case ..<(.seconds(120)): .seconds(4)
        case ..<(.seconds(600)): .seconds(10)
        default: .seconds(30)
        }
    }

    /// Combien de temps bran suit un traitement avant de rendre la main.
    ///
    /// Deux heures en mode asynchrone : au-delà de 70 min d'audio, le CRM passe
    /// sur `azure_batch`, où rester des minutes sur `transcribing` est normal.
    /// Trente minutes sinon — un closing d'une demi-heure revient en une à deux
    /// minutes, et vingt fois cette durée est déjà une anomalie.
    private static func trackingBudget(batch: Bool) -> Duration {
        batch ? .seconds(7200) : .seconds(1800)
    }

    /// Le nombre d'échecs de transport consécutifs tolérés avant d'abandonner.
    ///
    /// **Un seul suffisait à faire disparaître le suivi**, et c'est la panne la
    /// plus discrète des trois : une bascule Wi-Fi pendant un `/status`, le
    /// `catch` posait un état `.failed` — que la vue considère comme terminé,
    /// donc masque — sans jamais écrire `crmError`, donc sans bouton
    /// « Réessayer ». Le panneau devenait silencieux pendant que le traitement
    /// continuait côté serveur.
    private static let transportFailureBudget = 5

    private func track(_ id: UUID, transcriptionID: String, client: CRMClient, token: UUID) async {
        let startedAt = ContinuousClock.now
        var budget = Self.trackingBudget(batch: false)
        var consecutiveFailures = 0

        while Task.isCancelled == false {
            let elapsed = ContinuousClock.now - startedAt

            do {
                let status = try await client.status(transcriptionID)
                guard jobs[id]?.token == token else { return }
                consecutiveFailures = 0
                budget = Self.trackingBudget(batch: status.isBatchEngine)
                apply(status, to: id, token: token)

                if status.stage.isTerminal { return }
            } catch {
                guard Self.isCancellation(error) == false else { return }
                guard Task.isCancelled == false, jobs[id]?.token == token else { return }

                consecutiveFailures += 1
                FeatureLog.record(
                    "✗ CRM — suivi \(transcriptionID) : \(error.localizedDescription) "
                    + "(\(consecutiveFailures)/\(Self.transportFailureBudget))"
                )

                // Une coupure passagère ne condamne pas le suivi ; un jeton
                // refusé, si. Le code HTTP fait la différence : les 4xx ne
                // s'arrangeront pas d'eux-mêmes, sauf 408 et 429 qui disent
                // explicitement « réessayez ».
                let permanent = (error as? CRMClient.Failure).map(Self.isPermanent) ?? false
                if permanent || consecutiveFailures >= Self.transportFailureBudget {
                    let message = "Suivi interrompu : \(error.localizedDescription)"
                    publish(.failed(message), for: id, token: token)
                    await store.mutate(id) { $0.crmError = message }
                    return
                }
            }

            guard elapsed < budget else {
                let minutes = Int(budget.components.seconds / 60)
                let message = """
                    Le CRM n'a pas terminé après \(minutes) min et n'a rien signalé. \
                    Le traitement continue peut-être de son côté : « Réessayer » relance le suivi.
                    """
                publish(.failed(message), for: id, token: token)
                await store.mutate(id) { $0.crmError = message }
                return
            }

            try? await Task.sleep(for: Self.pollDelay(afterElapsed: elapsed))
        }
    }

    /// Une panne de transport qui ne s'arrangera pas en réessayant.
    private static func isPermanent(_ failure: CRMClient.Failure) -> Bool {
        guard (400..<500).contains(failure.statusCode) else { return false }
        return failure.statusCode != 408 && failure.statusCode != 429
    }

    private func apply(_ status: CRMStatus, to id: UUID, token: UUID) {
        switch status.stage {
        case .ready:
            publish(.ready(summary: status.summary?.resume), for: id, token: token)
        case .failed:
            publish(.failed(status.error ?? "Transcription impossible."), for: id, token: token)
        case .upload, .queued, .transcribing, .summarizing:
            publish(
                .processing(
                    stage: status.stage,
                    // `boundedProgress` et non `progress` : le CRM a le droit
                    // d'annoncer 250, l'interface n'a pas le droit de l'afficher.
                    progress: status.boundedProgress ?? 0,
                    label: status.label
                ),
                for: id,
                token: token
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
                  jobs[recording.id] == nil,
                  states[recording.id]?.isFinished != true
            else { return false }

            let stage = recording.metadata.crmStage.flatMap(CRMStage.init(rawValue:))
            return stage?.isTerminal != true
        }

        guard pending.isEmpty == false, let client = client() else { return }

        for recording in pending {
            guard let transcriptionID = recording.metadata.transcriptionID else { continue }
            start(for: recording.id) { [weak self] token in
                await self?.track(
                    recording.id,
                    transcriptionID: transcriptionID,
                    client: client,
                    token: token
                )
            }
        }
    }

    /// « Réessayer », et il y a **deux** choses à reprendre.
    ///
    /// Le bouton n'en connaissait qu'une : il appelait `/retry`, c'est-à-dire
    /// « relance le traitement serveur », puis remettait le suivi en marche.
    /// C'est le bon geste quand Azure a échoué sur un audio qui est bien arrivé.
    /// Ce ne l'est pas du tout dans les deux cas où l'envoi s'est cassé plus
    /// tôt, et ce sont eux qui laissaient l'utilisateur devant un bouton inerte
    /// ou trompeur :
    ///
    /// - **Le Wi-Fi tombe à 40 % du `PUT`.** L'identifiant et l'étape `upload`
    ///   sont déjà en base, l'objet Supabase est absent ou incomplet — et aucun
    ///   chemin ne rappelait `upload(file:to:)`. « Réessayer » relançait un
    ///   traitement serveur sur un fichier qui n'existait pas.
    /// - **Le DNS tombe pendant `createTranscription`.** Il n'y a pas encore
    ///   d'identifiant, donc le `guard` sortait sans rien faire : l'écran
    ///   affichait « Réessayer », le clic ne produisait rien, pas même une
    ///   erreur.
    ///
    /// Ce qui décide est l'étape atteinte : tant que le CRM n'a pas confirmé
    /// avoir reçu les octets, il faut refaire l'envoi complet ; après, il faut
    /// laisser le serveur reprendre son travail.
    func retry(_ recording: Recording) {
        let stage = recording.metadata.crmStage.flatMap(CRMStage.init(rawValue:))
        let bytesLanded = recording.metadata.transcriptionID != nil && stage != nil && stage != .upload

        guard bytesLanded, let transcriptionID = recording.metadata.transcriptionID else {
            start(for: recording.id, cancellingCurrent: true) { [weak self] token in
                await self?.resend(recording, token: token)
            }
            return
        }

        guard let client = client() else {
            states[recording.id] = .failed("Liaison CRM non configurée.")
            return
        }

        start(for: recording.id, cancellingCurrent: true) { [weak self] token in
            do {
                try await client.retry(transcriptionID)
                await self?.track(
                    recording.id,
                    transcriptionID: transcriptionID,
                    client: client,
                    token: token
                )
            } catch {
                guard Self.isCancellation(error) == false else { return }
                self?.publish(.failed(error.localizedDescription), for: recording.id, token: token)
            }
        }
    }

    /// Refait l'envoi depuis le début : audio, dépôt, octets, lancement.
    ///
    /// **Le rendez-vous se retrouve dans cet ordre**, du plus sûr au plus
    /// coûteux : celui qui vient d'être choisi dans cette session, puis celui
    /// qui est écrit dans les métadonnées — qu'il faut alors relire au CRM,
    /// parce que son entreprise a pu être rattachée depuis, et que c'est
    /// précisément le geste de réparation qu'on conseille à l'utilisateur.
    ///
    /// Faute des deux, on ne devine pas : envoyer un audio « au rendez-vous le
    /// plus proche » est exactement ce que le contrat interdit.
    private func resend(_ recording: Recording, token: UUID) async {
        guard let client = client() else {
            publish(.failed("Liaison CRM non configurée."), for: recording.id, token: token)
            return
        }

        let complement = lastAttempt[recording.id]?.complement

        do {
            var booking = lastAttempt[recording.id]?.booking

            if let bookingID = recording.metadata.bookingID {
                let start = recording.metadata.startedAt
                let known = try await client.targets(
                    from: start.addingTimeInterval(-12 * 3600),
                    to: start.addingTimeInterval(12 * 3600)
                )
                booking = known.first { $0.booking_id == bookingID } ?? booking
            }

            guard let booking else {
                publish(
                    .failed(
                        "Impossible de savoir à quel rendez-vous rattacher cet envoi. "
                        + "Relancez-le depuis la bibliothèque en choisissant le rendez-vous."
                    ),
                    for: recording.id,
                    token: token
                )
                return
            }

            // Le rendez-vous a pu changer entre-temps — lead rattaché, ou au
            // contraire rendez-vous annulé. `.manual` : c'est un clic.
            let eligibility = UploadEligibility.evaluate(
                booking: booking,
                isConfigured: configuration.isConfigured,
                intent: .manual
            )
            guard eligibility.canSend else {
                publish(
                    .failed(eligibility.blockingReason ?? "Envoi impossible."),
                    for: recording.id,
                    token: token
                )
                return
            }

            // Le dépôt précédent est incomplet : le CRM n'autorise sa
            // suppression que pour `uploading` et `failed`, ce qui est
            // exactement le cas ici — et un refus n'empêche rien, la création
            // suivante rend une URL signée neuve de toute façon.
            if let previous = recording.metadata.transcriptionID {
                try? await client.deleteFailedUpload(previous)
            }

            await perform(recording, booking: booking, complement: complement, token: token)
        } catch {
            guard Self.isCancellation(error) == false else { return }
            publish(
                .failed("Reprise impossible : \(error.localizedDescription)"),
                for: recording.id,
                token: token
            )
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
