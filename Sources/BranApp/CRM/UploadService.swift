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

        let audioURL = FileManager.default.temporaryDirectory
            .appending(path: "\(recording.id.uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: audioURL) }

        do {
            states[recording.id] = .extractingAudio
            let audio = try await AudioExporter.extractSpeechAudio(from: recording.url, to: audioURL)

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
        guard let client = client() else { return }

        for recording in recordings {
            guard let transcriptionID = recording.metadata.transcriptionID,
                  trackers[recording.id] == nil,
                  states[recording.id]?.isFinished != true
            else { continue }

            let stage = recording.metadata.crmStage.flatMap(CRMStage.init(rawValue:))
            guard stage?.isTerminal != true else { continue }

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
