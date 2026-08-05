import SwiftUI

/// Choix du RDV auquel rattacher un enregistrement.
///
/// Cet écran existe parce que le contrat interdit de deviner : un audio
/// rattaché au mauvais lead écrase le compte-rendu de quelqu'un d'autre.
struct BookingPickerSheet: View {
    let recording: Recording
    let candidates: [CRMBooking]
    let onSend: (CRMBooking, String?) -> Void
    let onCancel: () -> Void

    @State private var selection: CRMBooking?
    @State private var complement = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            if candidates.isEmpty {
                ContentUnavailableView(
                    "Aucun rendez-vous trouvé",
                    systemImage: "calendar.badge.exclamationmark",
                    description: Text("Aucun RDV cal.com dans les 12 heures autour de cet enregistrement.")
                )
                .frame(maxHeight: .infinity)
            } else {
                List(candidates, selection: $selection) { booking in
                    BookingRow(booking: booking, recordingStart: recording.metadata.startedAt)
                        .tag(booking)
                }
                .listStyle(.inset)
            }

            if shouldOfferComplement {
                Divider()
                complementField
            }

            Divider()
            footer
        }
        .frame(width: 620, height: 560)
        .onAppear { selection = candidates.first }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Rattacher au CRM")
                .font(.title2.weight(.semibold))
            Text("\(recording.displayTitle) · \(recording.durationDescription) · enregistré à \(recording.metadata.startedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(20)
    }

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
                Text(booking.displayName)
                    .font(.body.weight(.medium))

                HStack(spacing: 6) {
                    // Le contrat le rappelle : l'API est en UTC, le métier se
                    // raisonne en heure de Paris. Conversion à l'affichage.
                    Text(booking.start_at, format: .dateTime.weekday(.abbreviated).day().month().hour().minute())
                    Text("·")
                    Text(gapDescription)
                    if let attendee = booking.attendee_name {
                        Text("·")
                        Text(attendee)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if booking.hasExistingTranscription {
                Image(systemName: "doc.badge.clock")
                    .foregroundStyle(.orange)
                    .help("Une transcription a déjà été déposée sur ce RDV.")
            }
            if booking.isOrphan {
                Label("sans entreprise", systemImage: "xmark.octagon.fill")
                    .labelStyle(.iconOnly)
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
        return gap < 0 ? "\(minutes) min avant" : "\(minutes) min après"
    }
}
