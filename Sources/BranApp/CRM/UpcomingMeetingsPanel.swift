import SwiftUI

/// Les prochains rendez-vous, en haut de la bibliothèque.
///
/// Répond à « qu'est-ce qui m'attend » sans ouvrir le CRM, et donne le lien de
/// la visio — le seul geste qu'on fait vraiment juste avant un closing.
struct UpcomingMeetingsPanel: View {
    let directory: MeetingDirectory

    @State private var isExpanded = true

    /// Le panneau porte lui-même son encadré : sans rendez-vous **ni** panne à
    /// signaler, il ne doit rien dessiner du tout — pas un cadre vide.
    var body: some View {
        if directory.upcoming.isEmpty == false {
            DisclosureGroup(isExpanded: $isExpanded) {
                ForEach(directory.upcoming.prefix(6)) { booking in
                    UpcomingMeetingRow(booking: booking)
                }
            } label: {
                HStack(spacing: Space.small) {
                    Text("À venir")
                    if let next = directory.next {
                        Text("· \(relativeStart(of: next))")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(Type.cardBody.weight(.medium))
            }
            .branWell()
        } else if let problem = directory.problem {
            Label(problem, systemImage: "exclamationmark.triangle")
                .font(Type.meta)
                .foregroundStyle(Palette.attention)
                .lineLimit(2)
                .branWell()
        }
    }

    private func relativeStart(of booking: CRMBooking) -> String {
        let minutes = Int(booking.start_at.timeIntervalSinceNow / 60)

        return switch minutes {
        case ..<0: "en cours"
        case 0..<60: "dans \(minutes) min"
        default: booking.start_at.formatted(.dateTime.hour().minute())
        }
    }
}

private struct UpcomingMeetingRow: View {
    let booking: CRMBooking

    var body: some View {
        HStack(alignment: .top, spacing: Space.small) {
            VStack(alignment: .leading, spacing: Space.line) {
                Text(booking.displayName)
                    .font(Type.cardBody.weight(.medium))
                    .lineLimit(1)

                HStack(spacing: Space.tight) {
                    // Toutes les dates de l'API sont en UTC ; le métier se
                    // raisonne en heure locale. Conversion à l'affichage.
                    Text(booking.start_at, format: .dateTime.weekday(.abbreviated).hour().minute())

                    if let attendee = booking.attendee_name {
                        Text("· \(attendee)")
                    }
                    if booking.isOrphan {
                        Image(systemName: "questionmark.circle")
                            .help("Aucun lead rattaché : l'email du prospect n'a pas de domaine connu.")
                    }
                }
                .font(Type.meta)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: Space.tight)

            if let link = booking.meeting_url, let url = URL(string: link) {
                Link(destination: url) {
                    Image(systemName: "video.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .help("Rejoindre la visio")
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(booking.displayName), \(booking.start_at.formatted(date: .abbreviated, time: .shortened))")
    }
}
