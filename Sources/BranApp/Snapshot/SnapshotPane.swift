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

    /// Voir `watchesSecureInput(_:)` : la valeur ne peut pas être lue
    /// directement dans le `body`, rien ne la publie.
    @State private var isSecureInputActive = false

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
        .watchesSecureInput($isSecureInputActive)
    }

    @ViewBuilder
    private var notices: some View {
        VStack(spacing: 0) {
            if controller.settings.isEnabled, isSecureInputActive {
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
                    HStack(spacing: 8) {
                        if let repair = repair(for: reason) {
                            Button(repair.title) {
                                repair.action()
                                controller.acknowledgeFailure()
                            }
                            .controlSize(.small)
                            .buttonStyle(.borderedProminent)
                        }
                        Button("Compris") { controller.acknowledgeFailure() }
                            .controlSize(.small)
                    }
                }
            }
        }
        // **`.clipped()` avant l'animation.** Un bandeau qui entre par le haut
        // passerait sinon par-dessus l'en-tête pendant toute la transition.
        .clipped()
        // Il n'y avait **aucune** animation ici : les `.transition` déclarées
        // par `NoticeRow` ne se déclenchaient donc jamais, et l'apparition d'un
        // bandeau faisait sauter toute la liste d'un cran.
        .branAnimation(Motion.enter, value: noticeSignature)
    }

    /// Ce qui doit relancer l'animation des bandeaux. Voir `DictationPane`.
    private var noticeSignature: String {
        var parts: [String] = []
        if controller.settings.isEnabled, isSecureInputActive { parts.append("saisie sécurisée") }
        if let problem = controller.store.problem { parts.append(problem) }
        if case .failed(let reason) = controller.phase { parts.append(reason.summary) }
        return parts.joined(separator: "|")
    }

    private func repair(for failure: SnapshotFailure) -> (title: String, action: () -> Void)? {
        switch failure {
        case .screenRecordingDenied:
            ("Redemander l'accès à l'écran", { _ = SystemSettings.reRequestScreenRecording() })
        case .screenRecordingBlind:
            // Une autorisation périmée ne se redemande pas : macOS la croit
            // accordée. Il faut retirer bran de la liste et l'y remettre, donc
            // ouvrir la page plutôt que rappeler une API qui répondra « oui ».
            ("Ouvrir les Réglages", { SystemSettings.open(.screenRecording) })
        case .accessibilityDenied:
            ("Redemander l'Accessibilité", { _ = SystemSettings.reRequestAccessibility() })
        case .selectionFailed, .engineUnavailable, .recognitionFailed, .diskFull:
            nil
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
            .branAnimation(Motion.enter, value: controller.store.entries.count)
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
    /// Voir `DictationCard` : un booléen seul laisse la première copie éteindre
    /// le retour de la seconde.
    @State private var copyTicket = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            text

            // **Déplier montrait le texte, et rien d'autre.** Sur une capture
            // courte — le cas courant — la carte ne bougeait pas d'un pixel, et
            // le chevron avait l'air cassé. Le texte tel que le moteur l'a rendu,
            // avant que `CharacterFixer` ne remplace ses guillemets et ses tirets,
            // est précisément ce qu'on vient vérifier avant de coller dans un
            // terminal.
            if isExpanded, let raw = entry.rawText, raw != entry.text {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Avant corrections typographiques")
                        .font(Type.metaFaint.weight(.medium))
                        .foregroundStyle(.tertiary)
                    Text(raw)
                        .font(entry.layout == .monospaced ? Type.meta.monospaced() : Type.meta)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            HStack(spacing: 7) {
                DisclosureChevron(isExpanded: $isExpanded)
                metadata
                Spacer(minLength: 8)
                actions
            }
        }
        .cardBackground(isHovering: isHovering)
        // Sans ça, le texte déborde du cadre pendant le redimensionnement.
        .geometryGroup()
        .onHover { isHovering = $0 }
        .branAnimation(Motion.state, value: isExpanded)
        .branAnimation(Motion.state, value: isRereading)
        .branAnimation(Motion.state, value: entry.text)
        .contextMenu { menu }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: isExpanded ? "Replier" : "Déplier") {
            isExpanded.toggle()
        }
        .task(id: copyTicket) {
            guard copyTicket > 0 else { return }
            try? await Task.sleep(for: .seconds(1.4))
            guard Task.isCancelled == false else { return }
            justCopied = false
        }
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

    /// Voir `DictationCard.actions` : toujours dans l'arbre, seulement
    /// transparentes, sinon rien de tout ça n'existe au clavier.
    private var actions: some View {
        HStack(spacing: Space.hair) {
            CardAction(
                symbol: justCopied ? "checkmark" : "doc.on.doc",
                help: "Copier le texte",
                tint: justCopied ? .green : nil,
                action: copy
            )
            .disabled(entry.text.isEmpty)

            Group {
                // **La seule relecture qui mérite un bouton** : dans l'autre
                // mise en page. Avec un moteur déterministe, rejouer à
                // l'identique rendrait exactement le même texte — alors qu'une
                // sortie de terminal lue comme de la prose a perdu ses colonnes,
                // et c'est réparable en un clic. Le second bouton, qui relisait
                // dans le *même* mode, était le voisin quasi identique d'une
                // action utile : il est passé dans le menu contextuel, où il ne
                // dispute plus la place à celle qu'on cherche.
                CardAction(
                    symbol: otherLayout == .monospaced ? "chevron.left.forwardslash.chevron.right" : "text.alignleft",
                    help: rereadHelp,
                    tint: isRereading ? .accentColor : nil,
                    isSpinning: isRereading
                ) {
                    controller.reread(entry, layout: otherLayout)
                }
                .disabled(entry.canRetry == false || isRereading)

                CardAction(symbol: "folder", help: "Afficher l'image dans le Finder", action: reveal)
                    .disabled(entry.canRetry == false)

                CardAction(symbol: "trash", help: "Supprimer", tint: .red, action: delete)
            }
            .opacity(isHovering || isRereading ? 1 : 0)
        }
        .branAnimation(Motion.hover, value: isHovering || isRereading)
    }

    /// Les mêmes actions, nommées, au clic droit — plus celles qui n'ont pas
    /// mérité un bouton.
    @ViewBuilder
    private var menu: some View {
        Button("Copier le texte", action: copy)
            .disabled(entry.text.isEmpty)
        Button(isExpanded ? "Replier" : "Déplier") { isExpanded.toggle() }
        Divider()
        Button(otherLayout == .monospaced ? "Relire comme du code" : "Relire comme du texte courant") {
            controller.reread(entry, layout: otherLayout)
        }
        .disabled(entry.canRetry == false || isRereading)
        Button("Relire dans le même mode") { controller.reread(entry) }
            .disabled(entry.canRetry == false || isRereading)
        Button("Afficher l'image dans le Finder", action: reveal)
            .disabled(entry.canRetry == false)
        Divider()
        Button("Supprimer", role: .destructive, action: delete)
    }

    private func copy() {
        controller.copy(entry)
        justCopied = true
        copyTicket += 1
    }

    private func reveal() {
        guard let url = controller.store.imageURL(for: entry) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func delete() {
        Task { await controller.store.delete(entry) }
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
