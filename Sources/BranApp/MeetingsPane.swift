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
                    .padding(.horizontal, Space.gutter)
                    .padding(.vertical, Space.inset)
                    .background(Palette.well)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            content
        }
        .branAnimation(Motion.enter, value: model.pendingMeeting?.id)
    }

    /// La liste, et les trois façons dont elle peut ne pas en être une.
    ///
    /// L'ordre compte : le balayage du dossier passe **avant** l'état vide.
    /// Pendant `reload()`, `recordings` est vide sans que la bibliothèque le
    /// soit, et l'écran « Aucun enregistrement » clignotait donc à chaque
    /// lancement sur une bibliothèque pleine.
    @ViewBuilder
    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Space.stack) {
                // Hors des branches : les prochains rendez-vous disparaissaient
                // quand la recherche ne renvoyait rien et au premier lancement —
                // c'est-à-dire exactement quand ils servent le plus. Leur code
                // d'erreur CRM était inatteignable pour la même raison.
                if model.uploads.configuration.isConfigured {
                    UpcomingMeetingsPanel(directory: model.directory)
                }

                if isLoadingLibrary {
                    skeleton
                } else if let problem = model.store.problem {
                    // **Avant le vide, et c'est tout le correctif.** Un dossier
                    // illisible affichait « Aucun enregistrement » : quarante
                    // réunions intactes sur le disque, et un écran qui ressemble
                    // à une perte de données. On dit ce qui bloque, et on offre
                    // de réessayer — un volume qu'on remonte doit suffire.
                    ContentUnavailableView {
                        Label("Enregistrements introuvables", systemImage: "externaldrive.badge.xmark")
                    } description: {
                        Text(problem)
                    } actions: {
                        Button("Réessayer") { Task { await model.store.reload() } }
                            .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, minHeight: 320)
                } else if model.store.recordings.isEmpty {
                    ContentUnavailableView(
                        "Aucun enregistrement",
                        systemImage: "film.stack",
                        description: Text("Rejoignez une réunion Meet : bran vous proposera de l'enregistrer, sans jamais démarrer tout seul.")
                    )
                    // Le vide est désormais dans le défilement, avec le panneau
                    // des prochains RDV au-dessus : sans hauteur imposée il se
                    // tasserait contre lui.
                    .frame(maxWidth: .infinity, minHeight: 320)
                } else if visible.isEmpty {
                    ContentUnavailableView.search(text: query)
                        .frame(maxWidth: .infinity, minHeight: 320)
                } else {
                    ForEach(grouped, id: \.day) { group in
                        Section {
                            ForEach(group.recordings) { recording in
                                RecordingCard(recording: recording, model: model)
                                    .id(recording.id)
                            }
                        } header: {
                            Text(group.title)
                                .font(Type.groupHead)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, Space.tight)
                        }
                    }
                }
            }
            .padding(.horizontal, Space.gutter)
            .padding(.vertical, Space.stack)
        }
    }

    /// Le dossier est en cours de lecture et n'a encore rien rendu.
    private var isLoadingLibrary: Bool {
        model.store.isScanning && model.store.recordings.isEmpty
    }

    /// Trois cartes en attente. Elles disent « ça arrive » à l'endroit exact où
    /// le contenu apparaîtra, là où un état vide disait le contraire.
    private var skeleton: some View {
        VStack(alignment: .leading, spacing: Space.stack) {
            ForEach(0..<3, id: \.self) { _ in
                RecordingRow(recording: .preview)
                    .branCard(isHovering: false)
            }
        }
        .redacted(reason: .placeholder)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Lecture du dossier des enregistrements…")
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
    @State private var isConfirmingDeletion = false

    var body: some View {
        NavigationLink(value: recording.id) {
            HStack(alignment: .top, spacing: Space.inset) {
                RecordingRow(
                    recording: recording,
                    progress: model.processingProgress[recording.id],
                    upload: model.uploads.state(for: recording.id)
                )

                Spacer(minLength: Space.small)

                // Toujours dans l'arbre, seulement peintes au survol.
                // Insérées sous condition, ces trois actions n'existaient ni
                // pour le clavier ni pour VoiceOver : une vue à opacité nulle
                // reste focalisable et lisible, une vue absente non.
                HStack(spacing: Space.hair) {
                    CardAction(symbol: "arrow.up.doc", help: "Envoyer au CRM…") {
                        model.requestUpload(for: recording)
                    }
                    .disabled(recording.existsOnDisk == false)

                    CardAction(symbol: "folder", help: "Afficher dans le Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([recording.url])
                    }

                    CardAction(symbol: "trash", help: "Mettre à la corbeille", tint: Palette.broken) {
                        isConfirmingDeletion = true
                    }
                }
                .opacity(isHovering ? 1 : 0)

                Image(systemName: "chevron.right")
                    .font(Type.metaFaint.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 3)
            }
            .branCard(isHovering: isHovering)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .branAnimation(Motion.hover, value: isHovering)
        // Les mêmes gestes sans souris et sans viser : le projet n'avait aucun
        // menu contextuel, alors que c'est le premier endroit où on clique
        // droit sur une liste de fichiers.
        .contextMenu {
            Button("Envoyer au CRM…", systemImage: "arrow.up.doc") {
                model.requestUpload(for: recording)
            }
            .disabled(recording.existsOnDisk == false)

            Button("Afficher dans le Finder", systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([recording.url])
            }

            Divider()

            Button("Mettre à la corbeille", systemImage: "trash", role: .destructive) {
                isConfirmingDeletion = true
            }
        }
        .confirmationDialog(
            "Mettre « \(recording.displayTitle) » à la corbeille ?",
            isPresented: $isConfirmingDeletion,
            titleVisibility: .visible
        ) {
            Button("Mettre à la corbeille", role: .destructive) {
                Task { await model.store.delete(recording) }
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("La vidéo et ses métadonnées partent à la corbeille. Vous pouvez les en ressortir tant qu'elle n'est pas vidée.")
        }
    }
}
