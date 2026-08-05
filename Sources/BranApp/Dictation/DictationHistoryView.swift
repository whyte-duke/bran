import BranSpeech
import SwiftUI

/// L'historique des dictées : la liste, et le détail.
///
/// Trié par date décroissante, recherche incluse. La recherche coûtait quinze
/// lignes — le même filtre que `BookingPickerSheet` — et sans elle un historique
/// devient inutilisable au bout de deux semaines.
struct DictationHistoryList: View {
    @Bindable var controller: DictationController
    @Binding var query: String

    var body: some View {
        Group {
            if controller.store.entries.isEmpty {
                ContentUnavailableView(
                    "Aucune dictée",
                    systemImage: "waveform",
                    description: Text(emptyHint)
                )
                .listRowSeparator(.hidden)
            } else if visible.isEmpty {
                ContentUnavailableView.search(text: query)
                    .listRowSeparator(.hidden)
            } else {
                ForEach(grouped, id: \.day) { group in
                    Section(group.title) {
                        ForEach(group.entries) { entry in
                            DictationRow(entry: entry)
                                .tag(entry.id)
                                .contextMenu { menu(for: entry) }
                        }
                    }
                }
            }
        }
    }

    private var emptyHint: String {
        controller.settings.isEnabled
            ? "Appuyez sur \(controller.settings.trigger.displayName), parlez, appuyez à nouveau."
            : "Activez la dictée dans les réglages pour commencer."
    }

    @ViewBuilder
    private func menu(for entry: TranscriptEntry) -> some View {
        Button("Copier le texte", systemImage: "doc.on.doc") {
            controller.copy(entry)
        }
        .disabled(entry.text.isEmpty)

        Button("Réessayer la transcription", systemImage: "arrow.clockwise") {
            controller.retry(entry)
        }
        .disabled(entry.canRetry == false)

        Button("Réappliquer le dictionnaire", systemImage: "character.book.closed") {
            controller.reapplyVocabulary(to: entry)
        }

        Divider()

        Button("Supprimer", systemImage: "trash", role: .destructive) {
            Task { await controller.store.delete(entry) }
        }
    }

    // MARK: - Filtrage

    private var visible: [TranscriptEntry] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard needle.isEmpty == false else { return controller.store.entries }
        return controller.store.entries.filter {
            $0.text.localizedStandardContains(needle)
        }
    }

    private struct DayGroup {
        let day: Date
        let title: String
        let entries: [TranscriptEntry]
    }

    private var grouped: [DayGroup] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: visible) { calendar.startOfDay(for: $0.createdAt) }
        return groups.keys.sorted(by: >).map { day in
            DayGroup(
                day: day,
                title: day.formatted(.dateTime.weekday(.wide).day().month(.wide)),
                entries: (groups[day] ?? []).sorted { $0.createdAt > $1.createdAt }
            )
        }
    }
}

private struct DictationRow: View {
    let entry: TranscriptEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(entry.previewText.isEmpty ? "—" : entry.previewText)
                .font(.callout)
                .lineLimit(2)
                .foregroundStyle(entry.isFailed ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary))

            HStack(spacing: 5) {
                Text(entry.createdAt, format: .dateTime.hour().minute())
                Text("·")
                Text(entry.durationDescription)

                if entry.canRetry == false {
                    Text("·")
                    Image(systemName: "externaldrive.badge.xmark")
                        .help("Audio purgé : la transcription ne peut plus être relancée.")
                }
                if entry.isFailed {
                    Text("·")
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

/// Le détail d'une dictée.
struct DictationDetailView: View {
    let entry: TranscriptEntry
    @Bindable var controller: DictationController

    @State private var justCopied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                transcript
                facts

                if let raw = entry.rawText {
                    rawSection(raw)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(entry.createdAt.formatted(date: .abbreviated, time: .shortened))
        .toolbar {
            ToolbarItem {
                Button(justCopied ? "Copié" : "Copier", systemImage: justCopied ? "checkmark" : "doc.on.doc") {
                    controller.copy(entry)
                    justCopied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.4))
                        justCopied = false
                    }
                }
                .disabled(entry.text.isEmpty)
            }
            ToolbarItem {
                Button("Réessayer", systemImage: "arrow.clockwise") {
                    controller.retry(entry)
                }
                .disabled(entry.canRetry == false)
                .help(entry.canRetry
                    ? "Relancer la transcription à partir de l'audio conservé."
                    : "L'audio a été purgé : la transcription ne peut plus être relancée.")
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.createdAt.formatted(date: .complete, time: .shortened))
                .font(.title3.weight(.semibold))

            HStack(spacing: 6) {
                Text(entry.durationDescription)
                Text("·")
                Text("\(entry.wordCount) mots")
                if let language = entry.language {
                    Text("·")
                    Text(language.uppercased())
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var transcript: some View {
        if entry.text.isEmpty, let failure = entry.failure {
            VStack(alignment: .leading, spacing: 8) {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
                if entry.canRetry {
                    Text("L'audio a été conservé : vous pouvez relancer la transcription.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
        } else {
            Text(entry.text)
                .font(.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
        }
    }

    private var facts: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], alignment: .leading, spacing: 12) {
            if let processing = entry.processingTime {
                DictationFact(
                    label: "Transcription",
                    value: "\(processing.formatted(.number.precision(.fractionLength(1)))) s",
                    hint: speedHint(processing)
                )
            }
            if let confidence = entry.confidence {
                DictationFact(
                    label: "Confiance",
                    value: "\((confidence * 100).formatted(.number.precision(.fractionLength(0)))) %"
                )
            }
            DictationFact(
                label: "Audio",
                value: entry.canRetry ? "conservé" : "purgé",
                hint: entry.canRetry
                    ? "Jusqu'au \(controller.store.expiryDate(for: entry).formatted(date: .abbreviated, time: .omitted))"
                    : nil
            )
            if let model = entry.modelVersion {
                DictationFact(label: "Modèle", value: model)
            }
        }
    }

    /// Le rapport au temps réel : le chiffre qui dit si la machine tient.
    private func speedHint(_ processing: TimeInterval) -> String? {
        guard processing > 0, entry.duration > 0 else { return nil }
        let ratio = entry.duration / processing
        return "\(ratio.formatted(.number.precision(.fractionLength(0))))× le temps réel"
    }

    private func rawSection(_ raw: String) -> some View {
        DisclosureGroup("Texte brut du modèle, avant dictionnaire") {
            Text(raw)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
        }
        .font(.callout)
    }
}

private struct DictationFact: View {
    let label: String
    let value: String
    var hint: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body.weight(.medium))
                .monospacedDigit()
            if let hint {
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) : \(value)")
    }
}
