import SwiftUI

struct RecordingDetailView: View {
    let recording: Recording
    @Bindable var model: AppModel

    private var store: RecordingStore { model.store }

    @State private var notes = ""
    @State private var eligibility: UploadEligibility?
    @State private var isChecking = false

    var body: some View {
        VStack(spacing: 0) {
            videoPlayer

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: Space.gutter) {
                    header
                    facts
                    crmPanel
                    notesEditor
                }
                .padding(Space.gutter)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .navigationTitle(recording.displayTitle)
        .toolbar {
            ToolbarItem {
                // « Ouvrir » plutôt que « Afficher » quand il y a un dossier de
                // rendez-vous : ce qu'on veut voir, c'est son contenu — la vidéo,
                // l'audio du CRM et la fiche côte à côte —, pas une icône
                // sélectionnée dans une liste de cent autres.
                if recording.isFlat == false {
                    Button("Ouvrir le dossier", systemImage: "folder") {
                        NSWorkspace.shared.open(recording.folderURL)
                    }
                } else {
                    Button("Afficher dans le Finder", systemImage: "folder") {
                        NSWorkspace.shared.activateFileViewerSelecting(recording.revealTargets)
                    }
                }
            }
        }
        .onAppear { notes = recording.metadata.notes }
    }

    private var videoPlayer: some View {
        VStack(spacing: 0) {
            // `playbackURL` et pas `url` : après une session mal terminée, le
            // fichier final n'existe pas et le lecteur restait noir alors que
            // la réunion entière était sur le disque, sous son nom de morceau.
            PlayerView(url: recording.playbackURL ?? recording.url)
                .aspectRatio(16 / 10, contentMode: .fit)
                .frame(minHeight: 260)
                // Le noir n'est le bon fond que derrière une image. Derrière un
                // message d'absence, il ne fait que rendre le message illisible.
                .background(recording.hasPlayableFile ? AnyShapeStyle(.black) : Palette.well)
                .accessibilityLabel("Lecteur vidéo — \(recording.displayTitle)")

            if let notice = recording.segmentNotice {
                Label(notice, systemImage: "scissors")
                    .font(Type.meta)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Space.gutter)
                    .padding(.vertical, Space.small)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.tight) {
            Text(recording.displayTitle)
                .font(Type.sheetTitle)
            Text(recording.metadata.startedAt.formatted(date: .complete, time: .shortened))
                .foregroundStyle(.secondary)
        }
    }

    private var facts: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: Space.inset)], alignment: .leading, spacing: Space.inset) {
            FactTile(label: "Durée", value: recording.durationDescription)
            FactTile(label: "Poids", value: recording.sizeDescription)

            // **Ce que le CRM recevra, et qu'on peut désormais écouter.**
            // L'audio était fabriqué dans le dossier temporaire au moment de
            // l'envoi puis effacé aussitôt : impossible de vérifier ce qui était
            // réellement parti, impossible de le renvoyer à la main le jour où le
            // CRM le refusait. Il vit maintenant dans le dossier du rendez-vous,
            // et son poids se lit ici — c'est le chiffre qu'on cherche quand un
            // envoi est refusé pour cause de fichier trop lourd.
            if let audio = recording.audioSizeDescription {
                FactTile(label: "Audio du CRM", value: audio)
            }

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
            notSentPanel
        } else {
            VStack(alignment: .leading, spacing: Space.inset) {
                HStack(spacing: Space.small) {
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
                        HStack(spacing: Space.small) {
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
                        .foregroundStyle(Palette.attention)
                        .font(Type.cardBody)
                }

                if let error = metadata.crmError {
                    HStack(alignment: .top) {
                        Label(error, systemImage: "xmark.octagon.fill")
                            .foregroundStyle(Palette.broken)
                            .font(Type.cardBody)
                        Spacer()
                        Button("Réessayer") { model.uploads.retry(recording) }
                    }
                }

                if let summary = metadata.crmSummary {
                    HStack(spacing: Space.small) {
                        if let issue = metadata.crmIssue {
                            Text(issue.replacing("_", with: " "))
                                .font(Type.meta.weight(.medium))
                                .padding(.horizontal, Space.small)
                                .padding(.vertical, Space.tight)
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
            .branWell()
        }
    }

    /// Enregistrement pas encore envoyé.
    ///
    /// Rien ne part tant que le rendez-vous n'est pas rattaché à une entreprise
    /// dans le CRM : un compte-rendu produit sur un RDV orphelin est facturé,
    /// puis n'apparaît sur aucune fiche. Le bouton reste donc désactivé, avec la
    /// raison et la marche à suivre — pas un refus muet.
    @ViewBuilder
    private var notSentPanel: some View {
        if model.uploads.configuration.isConfigured == false {
            unconfiguredPanel
        } else {
            sendPanel
        }
    }

    /// CRM non renseigné.
    ///
    /// L'écran montrait deux boutons désactivés et rien d'autre : le refus
    /// était muet, et la seule action possible — ouvrir les réglages — n'était
    /// proposée nulle part.
    private var unconfiguredPanel: some View {
        VStack(alignment: .leading, spacing: Space.small) {
            Label("Aucun CRM configuré", systemImage: "link.badge.plus")
                .font(Type.cardTitle)

            Text("bran ne sait pas encore à quelle instance Castral envoyer cet enregistrement. Renseignez l'adresse et la clé dans les réglages : l'envoi et le rattachement au bon rendez-vous deviendront possibles.")
                .font(Type.cardBody)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("Ouvrir les réglages…") { model.showsSettings = true }
        }
        .branWell()
    }

    private var sendPanel: some View {
        VStack(alignment: .leading, spacing: Space.small) {
            HStack {
                Label("Pas encore envoyé au CRM", systemImage: "arrow.up.doc")
                    .foregroundStyle(.secondary)

                Spacer()

                if isChecking {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Vérifier le rattachement") { check() }
                }

                Button("Envoyer au CRM…") { model.requestUpload(for: recording) }
                    .buttonStyle(.borderedProminent)
                    .disabled(canSend == false)
            }
            .font(.callout)

            if let eligibility, let reason = eligibility.blockingReason {
                VStack(alignment: .leading, spacing: Space.tight) {
                    Label(reason, systemImage: "xmark.octagon.fill")
                        .font(Type.cardBody.weight(.medium))
                        .foregroundStyle(Palette.broken)

                    if let remedy = eligibility.remedy {
                        Text(remedy)
                            .font(Type.meta)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: Space.inset) {
                        // Un blocage doit toujours laisser une sortie : le RDV
                        // rapproché n'est peut-être simplement pas le bon.
                        Button("Choisir un autre rendez-vous…") {
                            model.requestUpload(for: recording)
                        }
                        .font(.caption)

                        if let booking = eligibility.booking,
                           let link = booking.meeting_url,
                           let url = URL(string: link) {
                            Link("Ouvrir la visio", destination: url)
                                .font(.caption)
                        }
                    }
                }
            } else if let eligibility, let booking = eligibility.booking {
                Label("Rattaché à « \(booking.displayName) »", systemImage: "checkmark.seal.fill")
                    .font(Type.cardBody)
                    .foregroundStyle(Palette.done)
            }
        }
        .branWell()
        .task { check() }
    }

    /// Tant que la vérification n'a pas eu lieu, on n'autorise rien : on ne sait
    /// pas encore si l'envoi est légitime.
    private var canSend: Bool {
        model.uploads.configuration.isConfigured && eligibility?.canSend == true
    }

    private func check() {
        guard model.uploads.configuration.isConfigured, isChecking == false else { return }
        isChecking = true
        Task {
            eligibility = await model.recheckEligibility(for: recording)
            isChecking = false
        }
    }

    private var notesEditor: some View {
        VStack(alignment: .leading, spacing: Space.small) {
            Text("Notes")
                .font(.headline)

            TextEditor(text: $notes)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(Space.small)
                .frame(minHeight: 140)
                .background(Palette.well, in: .rect(cornerRadius: Radius.field))
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
        VStack(alignment: .leading, spacing: Space.hair) {
            Text(label)
                .font(Type.meta)
                .foregroundStyle(.secondary)
            Text(value)
                .font(Type.cardTitle)
                .monospacedDigit()
        }
        .branWell()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) : \(value)")
    }
}
