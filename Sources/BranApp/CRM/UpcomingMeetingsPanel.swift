import SwiftUI

/// Les prochains rendez-vous, en haut de la bibliothèque.
///
/// Répond à « qu'est-ce qui m'attend » sans ouvrir le CRM, et donne le lien de
/// la visio — le seul geste qu'on fait vraiment juste avant un closing.
struct UpcomingMeetingsPanel: View {
    let directory: MeetingDirectory

    @State private var isExpanded = true

    var body: some View {
        if directory.upcoming.isEmpty == false {
            DisclosureGroup(isExpanded: $isExpanded) {
                ForEach(directory.upcoming.prefix(6)) { booking in
                    UpcomingMeetingRow(booking: booking)
                }
            } label: {
                HStack(spacing: 6) {
                    Text("À venir")
                    if let next = directory.next {
                        Text("· \(relativeStart(of: next))")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.callout.weight(.medium))
            }
        } else if let problem = directory.problem {
            Label(problem, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(2)
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
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(booking.displayName)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)

                HStack(spacing: 5) {
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
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 4)

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
