import BranVision
import SwiftUI

/// La section « Captures » : la liste, directement, dans la vue principale.
///
/// Même forme que les dictées, et pour la même raison : copier un texte capturé
/// est le geste le plus fréquent, donc celui qui devait coûter le moins.
///
/// Une différence assumée : le texte est affiché en **chasse fixe** quand il a
/// été lu en chasse fixe. Une sortie de `ls -la` rendue en police
/// proportionnelle perd l'alignement des colonnes qu'on vient précisément de
/// prendre la peine de reconstruire.
struct SnapshotPane: View {
    @Bindable var model: AppModel
    @Binding var query: String

    private var controller: SnapshotController { model.snapshot }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(
                title: LibraryPane.snapshots.title,
                subtitle: LibraryPane.snapshots.subtitle,
                query: $query,
                searchPrompt: "Chercher dans les captures, ou par application"
            ) {
                SnapshotStatusChip(model: model)
            }

            Divider()

            notices

            content
        }
        .task { await controller.store.reload() }
    }

    @ViewBuilder
    private var notices: some View {
        VStack(spacing: 0) {
            if controller.settings.isEnabled, HotkeyMonitor.isSecureInputActive {
                NoticeRow(
                    text: "Saisie sécurisée active : macOS bloque tout raccourci global tant qu'un champ de mot de passe a le focus. Fermez-le, ou décochez « Saisie sécurisée du clavier » dans le menu Terminal.",
                    symbol: "lock.fill",
                    tint: .orange
                )
            }

            if let problem = controller.store.problem {
                NoticeRow(text: problem, symbol: "externaldrive.badge.xmark", tint: .orange)
            }

            if case .failed(let reason) = controller.phase {
                NoticeRow(text: reason.remedy, symbol: "exclamationmark.triangle.fill", tint: .red) {
                    Button("Compris") { controller.acknowledgeFailure() }
                        .controlSize(.small)
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if controller.store.entries.isEmpty {
            ContentUnavailableView {
                Label("Aucune capture", systemImage: "text.viewfinder")
            } description: {
                Text(emptyHint)
            } actions: {
                if controller.settings.isEnabled == false {
                    Button("Activer la capture de texte") { model.showsSettings = true }
                        .buttonStyle(.borderedProminent)
                }
            }
        } else if visible.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(grouped, id: \.day) { group in
                        Section {
                            ForEach(group.entries) { entry in
                                SnapshotCard(entry: entry, controller: controller)
                                    .id(entry.id)
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
            .animation(.snappy(duration: 0.25), value: controller.store.entries.count)
        }
    }

    private var emptyHint: String {
        controller.settings.isEnabled
            ? "Appuyez sur \(controller.settings.trigger.displayName), tracez un rectangle, et le texte de la zone part dans le presse-papiers."
            : "La capture est désactivée. Une fois activée, un raccourci suffit à récupérer le texte de n'importe quelle zone de l'écran."
    }

    // MARK: - Filtrage

    /// La recherche porte aussi sur l'application d'origine : trois semaines
    /// plus tard on se souvient d'où venait un bout de texte bien avant de se
    /// souvenir de ce qu'il disait.
    private var visible: [SnippetEntry] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard needle.isEmpty == false else { return controller.store.entries }
        return controller.store.entries.filter { entry in
            entry.text.localizedStandardContains(needle)
                || (entry.sourceApp?.localizedStandardContains(needle) ?? false)
        }
    }

    private struct DayGroup {
        let day: Date
        let title: String
        let entries: [SnippetEntry]
    }

    private var grouped: [DayGroup] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: visible) { calendar.startOfDay(for: $0.createdAt) }
        return groups.keys.sorted(by: >).map { day in
            DayGroup(
                day: day,
                title: Self.dayTitle(day, calendar: calendar),
                entries: (groups[day] ?? []).sorted { $0.createdAt > $1.createdAt }
            )
        }
    }

    private static func dayTitle(_ day: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(day) { return "Aujourd'hui" }
        if calendar.isDateInYesterday(day) { return "Hier" }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }
}

// MARK: - La carte

/// Une capture, avec tout ce qu'on peut en faire.
private struct SnapshotCard: View {
    let entry: SnippetEntry
    let controller: SnapshotController

    @State private var isHovering = false
    @State private var isExpanded = false
    @State private var justCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            text

            HStack(spacing: 7) {
                metadata
                Spacer(minLength: 8)
                actions
            }
        }
        .cardBackground(isHovering: isHovering)
        .onHover { isHovering = $0 }
        .onTapGesture {
            withAnimation(.snappy(duration: 0.28)) { isExpanded.toggle() }
        }
        .animation(.smooth(duration: 0.3), value: isRereading)
        .animation(.smooth(duration: 0.3), value: entry.text)
        .accessibilityElement(children: .contain)
    }

    private var isRereading: Bool { controller.isRereading(entry.id) }

    /// Chasse fixe quand la capture a été lue en chasse fixe. Sans ça, tout le
    /// travail de reconstruction des colonnes serait invisible dans la liste.
    private var font: Font {
        entry.layout == .monospaced
            ? .system(.callout, design: .monospaced)
            : .callout
    }

    @ViewBuilder
    private var text: some View {
        if isRereading {
            rereadingText
        } else if entry.text.isEmpty, let failure = entry.failure {
            Label(failure, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(entry.text)
                .font(font)
                .textSelection(.enabled)
                .lineLimit(isExpanded ? nil : 4)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity)
                .id(entry.text)
        }
    }

    /// Ce qu'on montre pendant une relecture.
    ///
    /// Même parti pris que la dictée : l'ancien texte reste en filigrane pour
    /// que la carte garde sa hauteur — sinon toute la liste sursaute — et pour
    /// qu'on sache de quelle capture il s'agit.
    private var rereadingText: some View {
        ZStack(alignment: .topLeading) {
            Text(entry.text.isEmpty ? " " : entry.text)
                .font(font)
                .lineLimit(isExpanded ? nil : 4)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(0.12)
                .accessibilityHidden(true)

            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.8)
                Text("Lecture…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .transition(.opacity)
    }

    private var metadata: some View {
        HStack(spacing: 5) {
            Text(entry.createdAt, format: .dateTime.hour().minute())

            if let app = entry.sourceApp {
                Text("·")
                Text(app)
            }

            Text("·")
            Text(entry.sizeDescription)

            if let layout = entry.layout {
                Text("·")
                Text(layout == .monospaced ? "code" : "texte")
            }

            if let repairs = entry.repairCount, repairs > 0 {
                Text("·")
                Label("\(repairs)", systemImage: "bandage")
                    .labelStyle(.titleAndIcon)
                    .help("\(repairs) caractère(s) typographique(s) corrigé(s) — relisez avant de coller dans un terminal.")
            }

            if let confidence = entry.confidence {
                Text("·")
                Text("\((confidence * 100).formatted(.number.precision(.fractionLength(0)))) %")
                    .help("Confiance moyenne du moteur sur cette capture.")
            }

            if entry.canRetry == false {
                Text("·")
                Image(systemName: "photo.badge.exclamationmark")
                    .help("Image purgée : la lecture ne peut plus être relancée.")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private var actions: some View {
        HStack(spacing: 2) {
            CardAction(
                symbol: justCopied ? "checkmark" : "doc.on.doc",
                help: "Copier le texte",
                tint: justCopied ? .green : nil
            ) {
                controller.copy(entry)
                justCopied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.4))
                    justCopied = false
                }
            }
            .disabled(entry.text.isEmpty)

            if isHovering || isRereading {
                // **La relecture qui sert vraiment** : dans l'autre mise en
                // page. Avec un moteur déterministe, rejouer à l'identique
                // rendrait exactement le même texte — alors qu'une sortie de
                // terminal lue comme de la prose a perdu ses colonnes, et c'est
                // réparable en un clic.
                CardAction(
                    symbol: otherLayout == .monospaced ? "chevron.left.forwardslash.chevron.right" : "text.alignleft",
                    help: rereadHelp,
                    tint: isRereading ? .accentColor : nil,
                    isSpinning: isRereading
                ) {
                    controller.reread(entry, layout: otherLayout)
                }
                .disabled(entry.canRetry == false || isRereading)

                CardAction(
                    symbol: "arrow.clockwise",
                    help: entry.canRetry
                        ? "Relire l'image dans le même mode"
                        : "Image purgée le \(controller.store.expiryDate(for: entry).formatted(date: .abbreviated, time: .omitted))",
                    isSpinning: false
                ) {
                    controller.reread(entry)
                }
                .disabled(entry.canRetry == false || isRereading)

                CardAction(symbol: "folder", help: "Afficher l'image dans le Finder") {
                    guard let url = controller.store.imageURL(for: entry) else { return }
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                .disabled(entry.canRetry == false)

                CardAction(symbol: "trash", help: "Supprimer", tint: .red) {
                    Task { await controller.store.delete(entry) }
                }
            }
        }
        .transition(.opacity)
        .animation(.easeOut(duration: 0.14), value: isHovering)
    }

    private var otherLayout: LayoutMode {
        (entry.layout ?? .monospaced) == .monospaced ? .prose : .monospaced
    }

    private var rereadHelp: String {
        guard entry.canRetry else {
            return "Image purgée : plus rien à relire."
        }
        return otherLayout == .monospaced
            ? "Relire en gardant l'alignement des colonnes et l'indentation"
            : "Relire comme du texte courant, sans les espaces d'alignement"
    }
}

// MARK: - L'état, dans l'en-tête

/// Dit en un coup d'œil si le raccourci est armé, et pourquoi il ne l'est pas.
///
/// **Volontairement identique à `DictationStatusChip`**, jusqu'à la police et au
/// fond en capsule. La première version portait un bouton « Activer » : un
/// bouton a une hauteur et une ligne de base différentes d'un simple texte, et
/// l'en-tête aligne le grand titre sur `.firstTextBaseline` du contenu de
/// droite. Résultat, le titre « Captures » ne tombait pas à la même hauteur que
/// « Réunions » et « Dictées ». L'invitation à activer vit dans l'état vide,
/// où il y a la place de l'expliquer.
struct SnapshotStatusChip: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.4), in: .capsule)
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch model.snapshot.phase {
        case .selecting, .preparing, .recognising: .orange
        case .failed: .orange
        default: model.snapshotSettings.isEnabled ? .green : .secondary
        }
    }

    private var label: String {
        switch model.snapshot.phase {
        case .selecting: "sélection…"
        case .preparing: "chargement du moteur…"
        case .recognising: "lecture…"
        case .failed(let reason): reason.summary
        default:
            model.snapshotSettings.isEnabled
                ? "\(model.snapshotSettings.trigger.displayName) · prête"
                : "capture désactivée"
        }
    }
}
