import SwiftUI

struct RecordingDetailView: View {
    let recording: Recording
    @Bindable var model: AppModel

    private var store: RecordingStore { model.store }

    @State private var notes = ""

    var body: some View {
        VStack(spacing: 0) {
            videoPlayer

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    facts
                    crmPanel
                    notesEditor
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .navigationTitle(recording.displayTitle)
        .toolbar {
            ToolbarItem {
                Button("Afficher dans le Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([recording.url])
                }
            }
        }
        .onAppear { notes = recording.metadata.notes }
    }

    private var videoPlayer: some View {
        PlayerView(url: recording.url)
            .aspectRatio(16 / 10, contentMode: .fit)
            .frame(minHeight: 260)
            .background(.black)
            .accessibilityLabel("Lecteur vidéo — \(recording.displayTitle)")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(recording.displayTitle)
                .font(.title2.weight(.semibold))
            Text(recording.metadata.startedAt.formatted(date: .complete, time: .shortened))
                .foregroundStyle(.secondary)
        }
    }

    private var facts: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], alignment: .leading, spacing: 12) {
            FactTile(label: "Durée", value: recording.durationDescription)
            FactTile(label: "Poids", value: recording.sizeDescription)

            if let rate = recording.rateDescription {
                FactTile(label: "Débit", value: rate)
            }
            if let code = recording.metadata.meetCode {
                FactTile(label: "Code Meet", value: code)
            }
            if recording.metadata.attendees.isEmpty == false {
                FactTile(label: "Participants", value: "\(recording.metadata.attendees.count)")
            }
        }
    }

    /// Ce que le CRM a fait de cet enregistrement.
    ///
    /// Le `resume` affiché ici est **exactement** celui qui a été écrit dans
    /// `bookings.notes` : c'est ce que l'équipe lit dans le CRM.
    @ViewBuilder
    private var crmPanel: some View {
        let metadata = recording.metadata
        let upload = model.uploads.state(for: recording.id)

        if metadata.transcriptionID == nil, upload == nil {
            HStack {
                Label("Pas encore envoyé au CRM", systemImage: "arrow.up.doc")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Envoyer au CRM…") { model.requestUpload(for: recording) }
                    .disabled(model.uploads.configuration.isConfigured == false)
            }
            .font(.callout)
            .padding(12)
            .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
        } else {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text("Castral CRM").font(.headline)

                    if let company = metadata.companyName {
                        Text(company)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if let companyID = metadata.companyID,
                       let url = model.uploads.configuration.dashboardURL(companyID: companyID) {
                        Link("Ouvrir la fiche", destination: url)
                            .font(.callout)
                    }
                }

                if let upload, upload.isFinished == false {
                    if let fraction = upload.fraction {
                        ProgressView(value: fraction) { Text(upload.description) }
                    } else {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(upload.description)
                        }
                    }
                }

                if let warning = metadata.crmWarning {
                    // « ready » avec un avertissement veut dire que le transcript
                    // est là mais pas le compte-rendu. Afficher un échec serait
                    // faux : le cron reprendra le compte-rendu tout seul.
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }

                if let error = metadata.crmError {
                    HStack(alignment: .top) {
                        Label(error, systemImage: "xmark.octagon.fill")
                            .foregroundStyle(.red)
                            .font(.callout)
                        Spacer()
                        Button("Réessayer") { model.uploads.retry(recording) }
                    }
                }

                if let summary = metadata.crmSummary {
                    HStack(spacing: 10) {
                        if let issue = metadata.crmIssue {
                            Text(issue.replacing("_", with: " "))
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(.tint.opacity(0.15), in: .capsule)
                        }
                        if let temperature = metadata.crmTemperature {
                            Label("\(temperature) / 100", systemImage: "thermometer.medium")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text(summary)
                        .font(.callout)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
        }
    }

    private var notesEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Notes")
                .font(.headline)

            TextEditor(text: $notes)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 140)
                .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
                // Écriture à chaque frappe : le fichier est minuscule et local.
                // Un enregistrement automatique différé perdrait la dernière
                // phrase à la fermeture de la fenêtre.
                .onChange(of: notes) { _, newValue in
                    store.updateNotes(newValue, for: recording.id)
                }
                .accessibilityLabel("Notes de la réunion")
        }
    }
}

private struct FactTile: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body.weight(.medium))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) : \(value)")
    }
}
