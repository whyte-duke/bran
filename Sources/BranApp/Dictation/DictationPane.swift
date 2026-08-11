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

    /// L'état de la saisie sécurisée, **recopié dans un état de vue**.
    /// Voir `watchesSecureInput(_:)` pour pourquoi il ne peut pas être lu
    /// directement dans le `body`.
    @State private var isSecureInputActive = false

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
        .watchesSecureInput($isSecureInputActive)
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

            if controller.settings.isEnabled, isSecureInputActive {
                NoticeRow(
                    text: "Saisie sécurisée active : macOS bloque tout raccourci global tant qu'un champ de mot de passe a le focus. Fermez-le, ou décochez « Saisie sécurisée du clavier » dans le menu Terminal.",
                    symbol: "lock.fill",
                    tint: .orange
                )
            }

            // Un disque plein ou un dossier illisible se disait déjà côté
            // captures et **restait muet ici** : la dictée semblait marcher,
            // puis l'historique était vide au redémarrage sans un mot.
            if let problem = controller.store.problem {
                NoticeRow(text: problem, symbol: "externaldrive.badge.xmark", tint: .orange)
            }

            if case .failed(let reason) = controller.phase {
                NoticeRow(text: reason.remedy, symbol: "exclamationmark.triangle.fill", tint: .red) {
                    HStack(spacing: Space.small) {
                        // Le bouton de réparation d'abord : c'est ce qu'on veut
                        // faire, pas acquitter un message.
                        if let repair = repair(for: reason) {
                            Button(repair.title) {
                                Task {
                                    await repair.action()
                                    controller.acknowledgeFailure()
                                }
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
        // passe sinon par-dessus l'en-tête pendant toute la transition.
        .clipped()
        // Une seule animation qui couvre les **quatre** bandeaux. La précédente
        // ne surveillait que le collage manqué : les `.transition` déclarées par
        // `NoticeRow` ne se déclenchaient jamais pour les trois autres, et un
        // échec de dictée faisait sauter toute la liste d'un cran.
        .branAnimation(Motion.enter, value: noticeSignature)
    }

    /// Ce qui doit relancer l'animation des bandeaux.
    ///
    /// Une chaîne plutôt que quatre `.animation` : SwiftUI n'anime une insertion
    /// que si la valeur surveillée change **au même instant** que l'insertion.
    private var noticeSignature: String {
        var parts: [String] = []
        if let notice = controller.pasteFallbackNotice { parts.append(notice) }
        if controller.settings.isEnabled, isSecureInputActive { parts.append("saisie sécurisée") }
        if let problem = controller.store.problem { parts.append(problem) }
        if case .failed(let reason) = controller.phase { parts.append(reason.summary) }
        return parts.joined(separator: "|")
    }

    /// Ce qu'on peut réellement faire pour réparer, selon l'échec.
    ///
    /// Rien pour ceux qui ne se réparent pas d'un clic — une saisie sécurisée se
    /// referme, un disque plein se vide. Proposer un bouton qui ne changerait
    /// rien serait un faux espoir de plus.
    private func repair(for failure: DictationFailure) -> (title: String, action: () async -> Void)? {
        switch failure {
        case .microphoneDenied, .microphoneSilent:
            ("Redemander le micro", { _ = await SystemSettings.reRequestMicrophone() })
        case .accessibilityDenied:
            ("Redemander l'Accessibilité", { _ = SystemSettings.reRequestAccessibility() })
        case .modelUnavailable:
            ("Retélécharger le modèle", { controller.host.warmUp() })
        case .secureInputActive, .captureFailed, .transcriptionFailed, .diskFull:
            nil
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
                LazyVStack(alignment: .leading, spacing: Space.stack) {
                    ForEach(grouped) { group in
                        Section {
                            ForEach(group.items) { entry in
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
            .branAnimation(Motion.enter, value: controller.store.entries.count)
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

    /// Les dictées, par jour. Même découpage que les captures, et c'est
    /// désormais littéralement le même code : voir `DayGroup.swift`, qui dit
    /// aussi ce qui n'a **pas** été mis en commun — la carte, la ligne — et
    /// pourquoi les réunir coûterait plus qu'elles ne se ressemblent.
    ///
    /// Aucun tri ici : `visible` filtre `store.entries`, que `ContentStore`
    /// garde du plus récent au plus ancien, et `DayGrouping` conserve cet ordre
    /// à l'intérieur de chaque jour.
    private var grouped: [DayGroup<TranscriptEntry>] {
        DayGrouping.groups(visible, by: \.createdAt)
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

// MARK: - Saisie sécurisée

extension View {

    /// Tient `isActive` à jour avec l'état de la saisie sécurisée du système.
    ///
    /// **Pourquoi ce détour.** `HotkeyMonitor.isSecureInputActive` appelle
    /// `IsSecureEventInputEnabled()`, une fonction C : rien ne la publie, donc
    /// une vue qui la lit dans son `body` garde éternellement la valeur du
    /// premier rendu. Le bandeau qui en dépend apparaissait ou disparaissait au
    /// hasard des redessins provoqués par autre chose — un affichage dont la
    /// valeur pouvait être fausse, ce qui est pire que pas d'affichage du tout.
    func watchesSecureInput(_ isActive: Binding<Bool>) -> some View {
        modifier(SecureInputWatch(isActive: isActive))
    }
}

private struct SecureInputWatch: ViewModifier {
    @Binding var isActive: Bool

    func body(content: Content) -> some View {
        content.task {
            // Le sondage meurt avec la vue : `.task` s'annule à la disparition.
            // Deux secondes suffisent — un champ de mot de passe n'apparaît pas
            // à l'insu de l'utilisateur, il faut juste que le bandeau le suive.
            while Task.isCancelled == false {
                let now = HotkeyMonitor.isSecureInputActive
                if now != isActive { isActive = now }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

// MARK: - Dépliage

/// Le chevron qui plie et déplie une carte.
///
/// **Il remplace un `onTapGesture` posé sur la carte entière.** Le texte des
/// cartes est sélectionnable : cliquer pour y poser un curseur repliait la
/// carte, donc sélectionner une portion de transcription était impossible. Et
/// un geste n'a aucun équivalent clavier. Un bouton, si.
struct DisclosureChevron: View {
    @Binding var isExpanded: Bool

    var body: some View {
        Button {
            isExpanded.toggle()
        } label: {
            Image(systemName: "chevron.down")
                .font(Type.metaFaint.weight(.semibold))
                .rotationEffect(.degrees(isExpanded ? 0 : -90))
                .frame(width: 14, height: 14)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tertiary)
        .branAnimation(Motion.state, value: isExpanded)
        .help(isExpanded ? "Replier" : "Déplier")
        .accessibilityLabel(isExpanded ? "Replier" : "Déplier")
    }
}

/// Une transcription, avec tout ce qu'on peut en faire.
private struct DictationCard: View {
    let entry: TranscriptEntry
    let controller: DictationController

    @State private var isHovering = false
    @State private var isExpanded = false
    @State private var justCopied = false
    /// Un jeton qui change à **chaque** copie.
    ///
    /// Un simple booléen ne suffit pas : deux copies rapprochées partageaient le
    /// même minuteur, et celui de la première éteignait la coche de la seconde
    /// au bout du temps qu'il lui restait. Le jeton relance `.task(id:)`, qui
    /// annule le minuteur précédent.
    @State private var copyTicket = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            text

            // Le texte brut n'apparaît qu'une fois la carte dépliée, et
            // seulement s'il diffère : le montrer toujours doublerait chaque
            // carte pour une information qu'on consulte une fois sur cinquante.
            if isExpanded, let raw = entry.rawText {
                VStack(alignment: .leading, spacing: Space.tight) {
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
                DisclosureChevron(isExpanded: $isExpanded)
                metadata
                Spacer(minLength: 8)
                actions
            }
        }
        .cardBackground(isHovering: isHovering)
        // Sans ça, le texte déborde du cadre pendant que la carte se
        // redimensionne au dépliage.
        .geometryGroup()
        .onHover { isHovering = $0 }
        .branAnimation(Motion.state, value: isExpanded)
        .branAnimation(Motion.state, value: isRetrying)
        .branAnimation(Motion.state, value: entry.text)
        .contextMenu { menu }
        .accessibilityElement(children: .contain)
        // Le dépliage sans souris ni Tab : VoiceOver l'annonce comme une action
        // de la carte elle-même.
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

            HStack(spacing: Space.small) {
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

    /// Les actions s'estompent hors survol — mais restent dans l'arbre.
    ///
    /// Une liste de cinquante cartes portant chacune quatre boutons devient un
    /// mur d'icônes où plus rien ne ressort. Au survol, seule la carte visée les
    /// montre — et le premier bouton, « copier », reste toujours visible parce
    /// que c'est celui qu'on cherche neuf fois sur dix.
    ///
    /// **Ce qui a changé : `.opacity(0)` et non plus un `if`.** Insérées sous
    /// condition, ces actions n'existaient tout simplement pas pour le clavier
    /// ni pour VoiceOver. Relancer une transcription — la raison d'être de la
    /// carte — était impossible sans souris. Le menu contextuel les redonne une
    /// seconde fois, avec des libellés en toutes lettres.
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
                CardAction(
                    symbol: "arrow.clockwise",
                    help: retryHelp,
                    tint: isRetrying ? .accentColor : nil,
                    isSpinning: isRetrying
                ) {
                    controller.retry(entry)
                }
                .disabled(entry.canRetry == false || isRetrying)

                CardAction(symbol: "folder", help: "Afficher l'audio dans le Finder", action: reveal)
                    .disabled(entry.canRetry == false)

                CardAction(symbol: "character.book.closed", help: "Réappliquer le dictionnaire de corrections") {
                    controller.reapplyVocabulary(to: entry)
                }

                CardAction(symbol: "trash", help: "Supprimer", tint: .red, action: delete)
            }
            // La flèche reste visible pendant la relance, même si le curseur est
            // parti ailleurs : c'est le seul repère qui dit quelle carte
            // travaille quand on en a relancé plusieurs.
            .opacity(isHovering || isRetrying ? 1 : 0)
        }
        .branAnimation(Motion.hover, value: isHovering || isRetrying)
    }

    /// Les mêmes actions, nommées, au clic droit.
    ///
    /// Il n'y avait aucun menu contextuel dans l'application. C'est pourtant le
    /// seul endroit où une action de carte porte un nom plutôt qu'un
    /// pictogramme, et le seul qui reste atteignable quand on ne survole pas.
    @ViewBuilder
    private var menu: some View {
        Button("Copier le texte", action: copy)
            .disabled(entry.text.isEmpty)
        Button(isExpanded ? "Replier" : "Déplier") { isExpanded.toggle() }
        Divider()
        Button("Relancer la transcription") { controller.retry(entry) }
            .disabled(entry.canRetry == false || isRetrying)
        Button("Réappliquer le dictionnaire de corrections") {
            controller.reapplyVocabulary(to: entry)
        }
        Button("Afficher l'audio dans le Finder", action: reveal)
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
        guard let url = controller.store.audioURL(for: entry) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func delete() {
        Task { await controller.store.delete(entry) }
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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(Type.notch.weight(.medium))
                .rotationEffect(.degrees(angle))
                // À l'arrêt, durée nulle : sans ça l'icône déroule les 360°
                // à l'envers pendant une demi-seconde, ce qui se lit comme une
                // erreur plutôt que comme une fin.
                //
                // **Et sous « Réduire les animations », elle ne tourne pas du
                // tout.** C'était la quatrième boucle perpétuelle de
                // l'application à ignorer le réglage. `nil`, pas une durée
                // raccourcie : une rotation accélérée est un mouvement de plus,
                // pas un de moins. Le bouton reste utilisable et l'état « en
                // cours » se lit ailleurs — la carte affiche déjà le texte en
                // train d'être remplacé.
                .animation(spin, value: angle)
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
            angle = spinning && reduceMotion == false ? 360 : 0
        }
        // **Le réglage doit faire bouger `angle`, sinon il ne fait rien.**
        // `.animation(nil, value:)` supprime l'animation des changements *à
        // venir* de cette valeur ; il n'annule pas une boucle déjà lancée. Sans
        // ce `onChange`, activer « Réduire les animations » pendant qu'une
        // reprise tourne laissait la flèche tourner jusqu'à la fin de la reprise.
        .onChange(of: reduceMotion) { _, _ in
            angle = isSpinning && reduceMotion == false ? 360 : 0
        }
        .onAppear { if isSpinning, reduceMotion == false { angle = 360 } }
    }

    /// L'animation de la rotation. `nil` quand le mouvement est refusé, une
    /// durée nulle à l'arrêt, la boucle sinon.
    private var spin: Animation? {
        guard isSpinning else { return .linear(duration: 0) }
        guard reduceMotion == false else { return nil }
        return .linear(duration: 0.9).repeatForever(autoreverses: false)
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
