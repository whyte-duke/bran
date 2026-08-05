import SwiftUI

/// Choix du rendez-vous auquel rattacher un enregistrement.
///
/// Deux usages, et le second compte autant que le premier :
/// - confirmer un rapprochement proposé par bran ;
/// - **chercher** le bon rendez-vous quand aucun ne tombe dans la fenêtre —
///   closing déplacé, réunion improvisée, lien personnel. Sans recherche,
///   ces cas-là n'auraient aucune issue.
struct BookingPickerSheet: View {
    let recording: Recording
    let candidates: [CRMBooking]
    let model: AppModel
    let onSend: (CRMBooking, String?) -> Void
    let onCancel: () -> Void

    @State private var selection: CRMBooking?
    @State private var complement = ""
    @State private var query = ""
    @State private var allBookings: [CRMBooking] = []
    @State private var wasTruncated = false
    @State private var isSearching = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            searchField

            Divider()

            list

            if shouldOfferComplement {
                Divider()
                complementField
            }

            Divider()
            footer
        }
        .frame(width: 680, height: 620)
        .onAppear { selection = candidates.first { $0.company != nil } ?? candidates.first }
        .task { await loadAll(force: false) }
    }

    // MARK: - En-tête et recherche

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Rattacher au CRM")
                .font(.title2.weight(.semibold))
            Text("\(recording.displayTitle) · \(recording.durationDescription) · enregistré le \(recording.metadata.startedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(20)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField("Chercher une entreprise, un participant, un domaine…", text: $query)
                .textFieldStyle(.plain)
                .accessibilityLabel("Rechercher un rendez-vous")

            if query.isEmpty == false {
                Button("Effacer", systemImage: "xmark.circle.fill") { query = "" }
                    .buttonStyle(.plain)
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
            }

            if isSearching {
                ProgressView().controlSize(.small)
            } else {
                Button("Actualiser", systemImage: "arrow.clockwise") {
                    Task { await loadAll(force: true) }
                }
                .buttonStyle(.plain)
                .labelStyle(.iconOnly)
                .foregroundStyle(.secondary)
                .help("Recharger la liste des rendez-vous depuis le CRM")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    // MARK: - Liste

    @ViewBuilder
    private var list: some View {
        if visibleBookings.isEmpty {
            ContentUnavailableView(
                query.isEmpty ? "Aucun rendez-vous proche" : "Aucun résultat",
                systemImage: "calendar.badge.exclamationmark",
                description: Text(
                    query.isEmpty
                        ? "Aucun RDV dans les 12 heures autour de l'enregistrement. Utilisez la recherche pour en trouver un autre."
                        : "Aucun rendez-vous ne correspond à « \(query) » sur les 90 derniers et prochains jours."
                )
            )
            .frame(maxHeight: .infinity)
        } else {
            List(selection: $selection) {
                Section(sectionTitle) {
                    ForEach(visibleBookings) { booking in
                        BookingRow(booking: booking, recordingStart: recording.metadata.startedAt)
                            .tag(booking)
                    }
                }

                if wasTruncated, query.isEmpty == false {
                    Text("Le CRM ne renvoie que 100 rendez-vous : affinez la recherche si le vôtre n'apparaît pas.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.inset)
        }
    }

    private var sectionTitle: String {
        query.isEmpty ? "Autour de l'enregistrement" : "Résultats"
    }

    /// Sans recherche, on montre les candidats proches — c'est presque toujours
    /// le bon. Dès qu'on tape, on cherche dans les 90 jours.
    private var visibleBookings: [CRMBooking] {
        guard query.isEmpty == false else { return candidates }

        let needle = query.trimmingCharacters(in: .whitespaces)
        return allBookings.filter { booking in
            [
                booking.company?.nom,
                booking.company?.domain,
                booking.attendee_name,
                booking.attendee_email,
                booking.detected_domain,
            ]
            .compactMap(\.self)
            .contains { $0.localizedStandardContains(needle) }
        }
    }

    private func loadAll(force: Bool) async {
        isSearching = true
        let results = await model.searchableBookings(forceRefresh: force)
        allBookings = results.bookings
        wasTruncated = results.wasTruncated
        isSearching = false
    }

    // MARK: - Complément

    /// §7 du contrat : si l'enregistrement est nettement plus court que le RDV,
    /// la fin manque — et c'est souvent là que se trouve le prix.
    private var shouldOfferComplement: Bool {
        guard let selection, let planned = selection.plannedDuration, let recorded = recording.duration else {
            return false
        }
        return recorded < planned * 0.75
    }

    private var complementField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("L'enregistrement semble plus court que le rendez-vous", systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(.orange)

            Text("Décrivez ce qui n'a pas été capté — prix annoncé, échéance, décision. Ce texte est donné au modèle en plus de la transcription, et n'est jamais cité en verbatim.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $complement)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 70)
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 6))
                .accessibilityLabel("Ce qui n'a pas été enregistré")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Pied

    private var eligibility: UploadEligibility {
        .evaluate(booking: selection, isConfigured: true)
    }

    private var footer: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                if let reason = eligibility.blockingReason {
                    Label(reason, systemImage: "xmark.octagon.fill")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.red)
                    if let remedy = eligibility.remedy {
                        Text(remedy)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if let selection, selection.hasExistingTranscription {
                    Label("Ce RDV porte déjà une transcription — le nouveau compte-rendu remplacera l'ancien.", systemImage: "exclamationmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }
            .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 12)

            Button("Annuler", role: .cancel) { onCancel() }

            Button("Envoyer") {
                guard let booking = eligibility.booking, eligibility.canSend else { return }
                onSend(booking, complement.isEmpty ? nil : complement)
            }
            .buttonStyle(.borderedProminent)
            .disabled(eligibility.canSend == false)
            .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }
}

private struct BookingRow: View {
    let booking: CRMBooking
    let recordingStart: Date

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(booking.company?.nom ?? booking.displayName)
                        .font(.body.weight(.medium))

                    if let owner = booking.company?.owner_sdr {
                        Text(owner)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.quaternary.opacity(0.6), in: .capsule)
                    }
                }

                HStack(spacing: 6) {
                    // Le contrat le rappelle : l'API est en UTC, le métier se
                    // raisonne en heure locale. Conversion à l'affichage.
                    Text(booking.start_at, format: .dateTime.weekday(.abbreviated).day().month().hour().minute())
                    Text("·")
                    Text(gapDescription)
                    if let attendee = booking.attendee_name {
                        Text("·")
                        Text(attendee)
                    }
                    if let domain = booking.detected_domain {
                        Text("·")
                        Text(domain)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 8)

            if booking.hasExistingTranscription {
                Image(systemName: "doc.badge.clock")
                    .foregroundStyle(.orange)
                    .help("Une transcription a déjà été déposée sur ce RDV.")
            }
            if booking.isOrphan {
                Image(systemName: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .help("Aucun lead rattaché : envoi impossible tant que le RDV n'est pas relié à une entreprise dans le CRM.")
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var gapDescription: String {
        let gap = booking.start_at.timeIntervalSince(recordingStart)
        let minutes = Int(abs(gap) / 60)

        if minutes < 3 { return "au moment de l'enregistrement" }
        if minutes < 120 { return gap < 0 ? "\(minutes) min avant" : "\(minutes) min après" }

        let days = Int(abs(gap) / 86400)
        if days >= 1 { return gap < 0 ? "il y a \(days) j" : "dans \(days) j" }
        return gap < 0 ? "\(minutes / 60) h avant" : "\(minutes / 60) h après"
    }
}
