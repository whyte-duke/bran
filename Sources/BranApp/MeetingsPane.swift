import BranCore
import SwiftUI

/// La section « Réunions » : la liste directement dans la vue principale, et le
/// détail poussé par-dessus quand on clique.
///
/// Le détail arrive par une `NavigationStack` : on obtient la transition
/// latérale du système, avec le bouton retour et le geste de balayage, sans rien
/// écrire. Une animation faite maison ferait moins bien et coûterait plus cher.
struct MeetingsPane: View {
    @Bindable var model: AppModel
    @Binding var query: String

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(
                title: LibraryPane.meetings.title,
                subtitle: LibraryPane.meetings.subtitle,
                query: $query,
                searchPrompt: "Chercher une réunion, une entreprise, un code Meet"
            ) {
                Button("Actualiser", systemImage: "arrow.clockwise") {
                    Task { await model.store.reload() }
                }
                .buttonStyle(.plain)
                .labelStyle(.iconOnly)
                .foregroundStyle(.secondary)
                .help("Relire le dossier des enregistrements")
            }

            Divider()

            // Le bandeau ne s'affiche que quand il a quelque chose à dire :
            // une réunion proposée, un échec à lire. En veille, il répéterait
            // ce que la colonne indique déjà.
            if model.pendingMeeting != nil || model.lastFailure != nil {
                StatusBanner(model: model)
                    .padding(.horizontal, 26)
                    .padding(.vertical, 12)
                    .background(.quaternary.opacity(0.25))
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            content
        }
        .animation(.snappy(duration: 0.25), value: model.pendingMeeting?.id)
    }

    @ViewBuilder
    private var content: some View {
        if model.store.recordings.isEmpty {
            ContentUnavailableView(
                "Aucun enregistrement",
                systemImage: "film.stack",
                description: Text("Rejoignez une réunion Meet : bran vous proposera de l'enregistrer, sans jamais démarrer tout seul.")
            )
        } else if visible.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if model.uploads.configuration.isConfigured, model.directory.upcoming.isEmpty == false {
                        UpcomingMeetingsPanel(directory: model.directory)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary.opacity(0.32), in: .rect(cornerRadius: 10))
                    }

                    ForEach(grouped, id: \.day) { group in
                        Section {
                            ForEach(group.recordings) { recording in
                                RecordingCard(recording: recording, model: model)
                                    .id(recording.id)
                            }
                        } header: {
                            Text(group.title)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 4)
                        }
                    }
                }
                .padding(.horizontal, 26)
                .padding(.vertical, 18)
            }
        }
    }

    // MARK: - Filtrage

    private var visible: [Recording] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard needle.isEmpty == false else { return model.store.recordings }
        return model.store.recordings.filter { recording in
            [
                recording.displayTitle,
                recording.metadata.meetCode,
                recording.metadata.companyName,
                recording.metadata.notes,
            ]
            .compactMap(\.self)
            .contains { $0.localizedStandardContains(needle) }
        }
    }

    private struct DayGroup {
        let day: Date
        let title: String
        let recordings: [Recording]
    }

    private var grouped: [DayGroup] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: visible) { calendar.startOfDay(for: $0.metadata.startedAt) }
        return groups.keys.sorted(by: >).map { day in
            DayGroup(
                day: day,
                title: Self.dayTitle(day, calendar: calendar),
                recordings: (groups[day] ?? []).sorted { $0.metadata.startedAt > $1.metadata.startedAt }
            )
        }
    }

    private static func dayTitle(_ day: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(day) { return "Aujourd'hui" }
        if calendar.isDateInYesterday(day) { return "Hier" }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }
}

/// Un enregistrement, cliquable, avec ses actions au survol.
private struct RecordingCard: View {
    let recording: Recording
    @Bindable var model: AppModel

    @State private var isHovering = false

    var body: some View {
        NavigationLink(value: recording.id) {
            HStack(alignment: .top, spacing: 12) {
                RecordingRow(
                    recording: recording,
                    progress: model.processingProgress[recording.id],
                    upload: model.uploads.state(for: recording.id)
                )

                Spacer(minLength: 8)

                if isHovering {
                    HStack(spacing: 2) {
                        CardAction(symbol: "arrow.up.doc", help: "Envoyer au CRM…") {
                            model.requestUpload(for: recording)
                        }
                        .disabled(recording.existsOnDisk == false)

                        CardAction(symbol: "folder", help: "Afficher dans le Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([recording.url])
                        }

                        CardAction(symbol: "trash", help: "Supprimer", tint: .red) {
                            Task { await model.store.delete(recording) }
                        }
                    }
                    .transition(.opacity)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 3)
            }
            .cardBackground(isHovering: isHovering)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.14), value: isHovering)
    }
}
