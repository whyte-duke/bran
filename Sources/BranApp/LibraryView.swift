import BranCore
import SwiftUI

/// La fenêtre.
///
/// Elle n'affiche plus rien elle-même : elle assemble une colonne de navigation
/// et une vue principale, et laisse chaque section se débrouiller. C'est ce qui
/// rend l'ajout d'une troisième section trivial — un cas dans `LibraryPane`, une
/// vue, rien d'autre à toucher ici.
///
/// ```
/// ┌────────────┬────────────────────────────────────┐
/// │  bran      │  Réunions                          │
/// │            │  Vos enregistrements…              │
/// │ ▸ Réunions │  🔍 Chercher…                      │
/// │   Dictées  │ ─────────────────────────────────  │
/// │            │  Aujourd'hui                       │
/// │            │  ┌──────────────────────────┐      │
/// │            │  │ ORPHEO GNB      ⧉ 📁 🗑 › │      │  clic → détail poussé
/// │  ⚙ Réglages│  └──────────────────────────┘      │
/// └────────────┴────────────────────────────────────┘
/// │  ⏺ 00:14:22        ‖ pause    ■ arrêter         │  pendant un enregistrement
/// └──────────────────────────────────────────────────┘
/// ```
struct LibraryView: View {
    @Bindable var model: AppModel

    @State private var pane: LibraryPane = .meetings
    @State private var meetingsPath: [UUID] = []
    @State private var meetingsQuery = ""
    @State private var dictationQuery = ""
    @State private var snapshotQuery = ""

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
            SectionSidebar(model: model, pane: $pane, showsSettings: $model.showsSettings)
                .navigationSplitViewColumnWidth(min: 200, ideal: 224, max: 280)
        } detail: {
            detail
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // Pendant l'enregistrement, la fenêtre entière devient un poste de
            // pilotage : la barre couvre les deux colonnes, quelle que soit la
            // section affichée.
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
        .sheet(isPresented: $model.showsSettings) {
            SettingsPane(model: model)
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

    @ViewBuilder
    private var detail: some View {
        switch pane {
        case .meetings:
            NavigationStack(path: $meetingsPath) {
                MeetingsPane(model: model, query: $meetingsQuery)
                    .navigationDestination(for: UUID.self) { id in
                        if let recording = model.store.recordings.first(where: { $0.id == id }) {
                            RecordingDetailView(recording: recording, model: model)
                        } else {
                            // Le fichier a pu disparaître pendant qu'on le
                            // regardait — supprimé dans le Finder, dossier
                            // débranché. Mieux vaut le dire que montrer un vide.
                            ContentUnavailableView(
                                "Enregistrement introuvable",
                                systemImage: "questionmark.folder",
                                description: Text("Il a été supprimé ou déplacé depuis le dernier balayage du dossier.")
                            )
                        }
                    }
            }
            .transition(.opacity)

        case .dictation:
            DictationPane(model: model, query: $dictationQuery)
                .transition(.opacity)

        case .snapshots:
            SnapshotPane(model: model, query: $snapshotQuery)
                .transition(.opacity)
        }
    }
}
