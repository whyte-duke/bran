import BranCore
import SwiftUI

struct LibraryView: View {
    @Bindable var model: AppModel
    @State private var selection: UUID?
    @State private var showsSettings = false

    /// Deux usages dans une seule fenêtre, plutôt que deux applications à
    /// installer, deux icônes dans la barre de menus et deux endroits où
    /// chercher. Le sélecteur est en tête de colonne, là où l'œil arrive.
    @State private var pane: Pane = .meetings
    @State private var dictationSelection: UUID?
    @State private var dictationQuery = ""

    /// Surtout pas `Section` : ce nom masquerait celui de SwiftUI dans toute la
    /// vue, et chaque `Section { … }` de la colonne se mettrait à désigner cet
    /// énuméré. Le compilateur le signale mal, et on cherche longtemps.
    enum Pane: String, CaseIterable, Identifiable {
        case meetings
        case dictation

        var id: String { rawValue }

        var label: String {
            switch self {
            case .meetings: "Réunions"
            case .dictation: "Dictées"
            }
        }

        var symbol: String {
            switch self {
            case .meetings: "film.stack"
            case .dictation: "waveform"
            }
        }
    }

    /// `pendingUpload` du modèle, présenté comme un `Identifiable` pour `.sheet`.
    private var uploadTarget: Binding<UploadTarget?> {
        Binding(
            get: { model.pendingUpload.map { UploadTarget(recording: $0.recording, candidates: $0.candidates) } },
            set: { if $0 == nil { model.pendingUpload = nil } }
        )
    }

    struct UploadTarget: Identifiable {
        let recording: Recording
        let candidates: [CRMBooking]
        var id: UUID { recording.id }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 380)
        } detail: {
            detail
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // Pendant l'enregistrement, la fenêtre entière devient un poste de
            // pilotage : la barre couvre les deux colonnes, quel que soit
            // l'élément sélectionné.
            if model.hasOpenSession {
                RecordingBar(model: model)
                    .transition(.move(edge: .bottom))
            }
        }
        .animation(.snappy(duration: 0.25), value: model.hasOpenSession)
        .task {
            await model.store.reload()
            // Le CRM n'envoie aucune notification : c'est à bran de redemander
            // l'état des jobs laissés en plan par une fermeture de l'app.
            model.uploads.resumeTracking(model.store.recordings)
            await model.directory.refresh()
        }
        .sheet(item: uploadTarget) { target in
            BookingPickerSheet(
                recording: target.recording,
                candidates: target.candidates,
                model: model,
                onSend: { booking, complement in
                    model.confirmUpload(target.recording, booking: booking, complement: complement)
                },
                onCancel: { model.pendingUpload = nil }
            )
        }
    }

    // MARK: - Colonne

    @ViewBuilder
    private var sidebar: some View {
        switch pane {
        case .meetings: meetingsSidebar
        case .dictation: dictationSidebar
        }
    }

    /// Le sélecteur de section, en tête de colonne.
    private var panePicker: some View {
        Picker("Section", selection: $pane) {
            ForEach(Pane.allCases) { pane in
                Label(pane.label, systemImage: pane.symbol).tag(pane)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    @ToolbarContentBuilder
    private var sharedToolbar: some ToolbarContent {
        ToolbarItem {
            Button("Réglages", systemImage: "gearshape") { showsSettings = true }
        }
    }

    // MARK: - Colonne « Dictées »

    private var dictationSidebar: some View {
        List(selection: $dictationSelection) {
            DictationHistoryList(controller: model.dictation, query: $dictationQuery)
        }
        .listStyle(.sidebar)
        .searchable(text: $dictationQuery, placement: .sidebar, prompt: "Chercher dans les dictées")
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                panePicker
                DictationBanner(model: model)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }
            .background(.bar)
        }
        .toolbar {
            sharedToolbar
            ToolbarItem {
                Button("Actualiser", systemImage: "arrow.clockwise") {
                    Task { await model.dictation.store.reload() }
                }
            }
        }
        .sheet(isPresented: $showsSettings) { SettingsPane(model: model) }
        .task { await model.dictation.store.reload() }
    }

    // MARK: - Colonne « Réunions »

    private var meetingsSidebar: some View {
        List(selection: $selection) {
            if model.store.recordings.isEmpty {
                ContentUnavailableView(
                    "Aucun enregistrement",
                    systemImage: "film.stack",
                    description: Text("Rejoignez une réunion Meet : bran vous proposera de l'enregistrer.")
                )
                .listRowSeparator(.hidden)
            }

            if model.uploads.configuration.isConfigured {
                Section {
                    UpcomingMeetingsPanel(directory: model.directory)
                }
            }

            ForEach(groupedByDay, id: \.day) { group in
                Section(group.title) {
                    ForEach(group.recordings) { recording in
                        RecordingRow(
                            recording: recording,
                            progress: model.processingProgress[recording.id],
                            upload: model.uploads.state(for: recording.id)
                        )
                            .tag(recording.id)
                            .contextMenu {
                                Button("Afficher dans le Finder") {
                                    NSWorkspace.shared.activateFileViewerSelecting([recording.url])
                                }
                                Button("Envoyer au CRM…", systemImage: "arrow.up.doc") {
                                    model.requestUpload(for: recording)
                                }
                                .disabled(recording.existsOnDisk == false)

                                Divider()

                                Button("Supprimer…", role: .destructive) {
                                    Task { await model.store.delete(recording) }
                                }
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                panePicker
                statusBanner
            }
            .background(.bar)
        }
        .toolbar {
            sharedToolbar
            ToolbarItem {
                Button("Actualiser", systemImage: "arrow.clockwise") {
                    Task { await model.store.reload() }
                }
            }
        }
        .sheet(isPresented: $showsSettings) {
            SettingsPane(model: model)
        }
    }

    /// L'état du moteur en haut de la colonne : c'est la réponse à « est-ce que
    /// ça tourne, et depuis combien de temps » sans avoir à viser une icône de
    /// 16 points dans la barre de menus.
    ///
    /// Masqué pendant l'enregistrement : la barre du bas dit déjà tout, et
    /// afficher deux fois la même durée avec deux boutons « Arrêter » fait
    /// hésiter au lieu d'informer.
    @ViewBuilder
    private var statusBanner: some View {
        if model.hasOpenSession == false {
            StatusBanner(model: model)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
        }
    }

    // MARK: - Détail

    @ViewBuilder
    private var detail: some View {
        switch pane {
        case .meetings: meetingsDetail
        case .dictation: dictationDetail
        }
    }

    @ViewBuilder
    private var dictationDetail: some View {
        if let entry = model.dictation.store.entries.first(where: { $0.id == dictationSelection }) {
            DictationDetailView(entry: entry, controller: model.dictation)
                .id(entry.id)
        } else {
            ContentUnavailableView(
                "Sélectionnez une dictée",
                systemImage: "waveform",
                description: Text(model.dictation.settings.isEnabled
                    ? "Appuyez sur \(model.dictation.settings.trigger.displayName) n'importe où, parlez, le texte est collé là où était votre curseur."
                    : "La dictée est désactivée. Activez-la dans les réglages.")
            )
        }
    }

    @ViewBuilder
    private var meetingsDetail: some View {
        if let recording = model.store.recordings.first(where: { $0.id == selection }) {
            RecordingDetailView(recording: recording, model: model)
                .id(recording.id)
        } else {
            ContentUnavailableView(
                "Sélectionnez un enregistrement",
                systemImage: "play.rectangle",
                description: Text("La liste est construite en lisant \(model.storage.root.path(percentEncoded: false)).")
            )
        }
    }

    // MARK: - Groupement

    private struct DayGroup {
        let day: Date
        let title: String
        let recordings: [Recording]
    }

    private var groupedByDay: [DayGroup] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: model.store.recordings) {
            calendar.startOfDay(for: $0.metadata.startedAt)
        }

        return groups.keys.sorted(by: >).map { day in
            DayGroup(
                day: day,
                title: day.formatted(.dateTime.weekday(.wide).day().month(.wide)),
                recordings: groups[day] ?? []
            )
        }
    }
}
