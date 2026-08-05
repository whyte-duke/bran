import BranSpeech
import SwiftUI

/// La section « Dictées » : la liste, directement, dans la vue principale.
///
/// Chaque carte porte le texte **et** ses actions. Copier une transcription
/// prend un clic, pas trois — et c'est de loin le geste le plus fréquent, donc
/// celui qui devait coûter le moins.
struct DictationPane: View {
    @Bindable var model: AppModel
    @Binding var query: String

    private var controller: DictationController { model.dictation }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(
                title: LibraryPane.dictation.title,
                subtitle: LibraryPane.dictation.subtitle,
                query: $query,
                searchPrompt: "Chercher dans les transcriptions"
            ) {
                DictationStatusChip(model: model)
            }

            Divider()

            notices

            content
        }
        .task { await controller.store.reload() }
        .animation(.snappy(duration: 0.25), value: controller.pasteFallbackNotice)
    }

    /// Les deux avertissements qu'on ne peut pas se permettre de perdre.
    ///
    /// Un texte transcrit mais non collé, et une saisie sécurisée qui bloque le
    /// raccourci : dans les deux cas l'utilisateur constate que « ça n'a pas
    /// marché » sans aucun moyen de savoir pourquoi. C'est précisément là qu'une
    /// application se fait désinstaller.
    @ViewBuilder
    private var notices: some View {
        VStack(spacing: 0) {
            if let notice = controller.pasteFallbackNotice {
                NoticeRow(
                    text: notice,
                    symbol: "doc.on.clipboard",
                    tint: .orange
                )
            }

            if controller.settings.isEnabled, HotkeyMonitor.isSecureInputActive {
                NoticeRow(
                    text: "Saisie sécurisée active : macOS bloque tout raccourci global tant qu'un champ de mot de passe a le focus. Fermez-le, ou décochez « Saisie sécurisée du clavier » dans le menu Terminal.",
                    symbol: "lock.fill",
                    tint: .orange
                )
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
                Label("Aucune dictée", systemImage: "waveform")
            } description: {
                Text(emptyHint)
            } actions: {
                if controller.settings.isEnabled == false {
                    Button("Activer la dictée") { model.showsSettings = true }
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
                                DictationCard(entry: entry, controller: controller)
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
            ? "Appuyez sur \(controller.settings.trigger.displayName) n'importe où, parlez, et le texte est collé là où était votre curseur."
            : "La dictée est désactivée. Une fois activée, un appui sur une touche suffit à dicter dans n'importe quelle application."
    }

    // MARK: - Filtrage

    private var visible: [TranscriptEntry] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard needle.isEmpty == false else { return controller.store.entries }
        return controller.store.entries.filter { $0.text.localizedStandardContains(needle) }
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

/// Un avertissement en bandeau, sous l'en-tête.
struct NoticeRow<Action: View>: View {
    let text: String
    let symbol: String
    let tint: Color
    @ViewBuilder var action: () -> Action

    init(
        text: String,
        symbol: String,
        tint: Color,
        @ViewBuilder action: @escaping () -> Action = { EmptyView() }
    ) {
        self.text = text
        self.symbol = symbol
        self.tint = tint
        self.action = action
    }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .font(.callout)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            action()
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.11))
        .transition(.move(edge: .top).combined(with: .opacity))
        .accessibilityElement(children: .combine)
    }
}

/// Une transcription, avec tout ce qu'on peut en faire.
private struct DictationCard: View {
    let entry: TranscriptEntry
    let controller: DictationController

    @State private var isHovering = false
    @State private var isExpanded = false
    @State private var justCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            text

            // Le texte brut n'apparaît qu'une fois la carte dépliée, et
            // seulement s'il diffère : le montrer toujours doublerait chaque
            // carte pour une information qu'on consulte une fois sur cinquante.
            if isExpanded, let raw = entry.rawText {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Avant dictionnaire")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.tertiary)
                    Text(raw)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

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
        .animation(.smooth(duration: 0.3), value: isRetrying)
        .animation(.smooth(duration: 0.3), value: entry.text)
        .accessibilityElement(children: .contain)
    }

    // MARK: -

    private var isRetrying: Bool { controller.isRetrying(entry.id) }

    @ViewBuilder
    private var text: some View {
        if isRetrying {
            retryingText
        } else if entry.text.isEmpty, let failure = entry.failure {
            Label(failure, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(entry.text)
                .font(.callout)
                .textSelection(.enabled)
                // Replié : trois lignes, assez pour reconnaître la dictée.
                // Déplié : tout, sans changer de page.
                .lineLimit(isExpanded ? nil : 3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Le texte arrivé par une relance se substitue à l'ancien en
                // fondu, plutôt que d'apparaître d'un coup — c'est la seule
                // façon de voir que quelque chose a changé.
                .transition(.opacity)
                .id(entry.text)
        }
    }

    /// Ce qu'on montre pendant une relance.
    ///
    /// L'ancien texte reste en filigrane, à 12 %. Deux raisons : la carte garde
    /// exactement la même hauteur — sinon toute la liste sursaute à chaque
    /// relance — et on continue de savoir de quelle dictée il s'agit.
    private var retryingText: some View {
        ZStack(alignment: .topLeading) {
            Text(entry.text.isEmpty ? " " : entry.text)
                .font(.callout)
                .lineLimit(isExpanded ? nil : 3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(0.12)
                .accessibilityHidden(true)

            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.8)
                Text("Transcription…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .transition(.opacity)
    }

    private var metadata: some View {
        HStack(spacing: 5) {
            Text(entry.createdAt, format: .dateTime.hour().minute())
            Text("·")
            Text(entry.durationDescription)
            Text("·")
            Text("\(entry.wordCount) mots")

            if let confidence = entry.confidence {
                Text("·")
                Text("\((confidence * 100).formatted(.number.precision(.fractionLength(0)))) %")
                    .help("Confiance du modèle sur cette transcription.")
            }

            if let processing = entry.processingTime, processing > 0, entry.duration > 0 {
                Text("·")
                Text("\((entry.duration / processing).formatted(.number.precision(.fractionLength(0))))×")
                    .help("Vitesse par rapport au temps réel.")
            }

            if entry.canRetry == false {
                Text("·")
                Image(systemName: "externaldrive.badge.xmark")
                    .help("Audio purgé : la transcription ne peut plus être relancée.")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    /// Les actions n'apparaissent qu'au survol.
    ///
    /// Une liste de cinquante cartes portant chacune quatre boutons devient un
    /// mur d'icônes où plus rien ne ressort. Au survol, seule la carte visée les
    /// montre — et le premier bouton, « copier », reste toujours visible parce
    /// que c'est celui qu'on cherche neuf fois sur dix.
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

            // La flèche reste visible pendant la relance, même si le curseur
            // est parti ailleurs : c'est le seul repère qui dit quelle carte
            // travaille quand on en a relancé plusieurs.
            if isHovering || isRetrying {
                CardAction(
                    symbol: "arrow.clockwise",
                    help: retryHelp,
                    tint: isRetrying ? .accentColor : nil,
                    isSpinning: isRetrying
                ) {
                    controller.retry(entry)
                }
                .disabled(entry.canRetry == false || isRetrying)

                CardAction(symbol: "folder", help: "Afficher l'audio dans le Finder") {
                    guard let url = controller.store.audioURL(for: entry) else { return }
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                .disabled(entry.canRetry == false)

                CardAction(symbol: "character.book.closed", help: "Réappliquer le dictionnaire de corrections") {
                    controller.reapplyVocabulary(to: entry)
                }

                CardAction(symbol: "trash", help: "Supprimer", tint: .red) {
                    Task { await controller.store.delete(entry) }
                }
            }
        }
        .transition(.opacity)
        .animation(.easeOut(duration: 0.14), value: isHovering)
    }

    private var retryHelp: String {
        entry.canRetry
            ? "Relancer la transcription à partir de l'audio conservé"
            : "L'audio a été purgé le \(controller.store.expiryDate(for: entry).formatted(date: .abbreviated, time: .omitted)) : plus rien à retranscrire"
    }
}

/// Un bouton d'action de carte, discret jusqu'au survol.
struct CardAction: View {
    let symbol: String
    let help: String
    var tint: Color?
    /// Fait tourner l'icône en continu. Une flèche de rechargement qui tourne
    /// dit « c'est en cours » sans avoir à écrire un mot.
    var isSpinning = false
    let action: () -> Void

    @State private var isHovering = false
    @State private var angle: Double = 0

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .medium))
                .rotationEffect(.degrees(angle))
                // À l'arrêt, durée nulle : sans ça l'icône déroule les 360°
                // à l'envers pendant une demi-seconde, ce qui se lit comme une
                // erreur plutôt que comme une fin.
                .animation(
                    isSpinning
                        ? .linear(duration: 0.9).repeatForever(autoreverses: false)
                        : .linear(duration: 0),
                    value: angle
                )
                .frame(width: 24, height: 22)
                .background {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isHovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint ?? .secondary)
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(help)
        .onChange(of: isSpinning) { _, spinning in
            // Remettre l'angle à zéro à l'arrêt : sinon l'icône garde
            // l'inclinaison où la rotation s'est interrompue.
            angle = spinning ? 360 : 0
        }
        .onAppear { if isSpinning { angle = 360 } }
    }
}

/// L'état de la dictée, en pastille, en haut à droite de la section.
private struct DictationStatusChip: View {
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
        switch model.dictation.phase {
        case .capturing: .red
        case .transcribing: .orange
        case .failed: .orange
        default: model.dictationSettings.isEnabled ? .green : .secondary
        }
    }

    private var label: String {
        switch model.dictation.phase {
        case .capturing: "à l'écoute"
        case .transcribing: "transcription…"
        case .failed(let reason): reason.summary
        default:
            model.dictationSettings.isEnabled
                ? "\(model.dictationSettings.trigger.displayName) · prête"
                : "désactivée"
        }
    }
}
