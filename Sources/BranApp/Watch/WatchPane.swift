import AppKit
import BranWatch
import SwiftUI

/// La section « Veille » : les voies, leur état, et depuis combien de temps.
///
/// Même forme que les dictées et les captures — en-tête, avertissements, liste —
/// parce qu'on sait déjà où regarder. Une différence assumée : **la liste n'est
/// pas un historique**. Les autres sections montrent ce qui s'est passé ; ici on
/// montre ce qui se passe. Le journal du jour est résumé en une ligne, la dette
/// d'attente, et c'est le seul chiffre qui dise si l'outil sert à quelque chose.
struct WatchPane: View {
    @Bindable var model: AppModel
    @Binding var query: String

    /// Ce que le dernier geste de retour n'a pas su faire.
    ///
    /// L'état est local et non dans `AppModel.lastFailure` : ici, contrairement
    /// au panneau flottant, on sait exactement où l'écrire — juste au-dessus de
    /// la liste où l'on vient de cliquer — et l'avertissement disparaît au
    /// prochain retour réussi, sans que l'utilisateur ait à le congédier.
    @State private var returnProblem: String?

    private var controller: WatchController { model.watch }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(
                title: LibraryPane.watch.title,
                subtitle: LibraryPane.watch.subtitle,
                query: $query,
                searchPrompt: "Chercher une voie par son nom"
            ) {
                WatchStatusChip(model: model)
            }

            Divider()

            notices

            content
        }
        .task { await controller.store.reload() }
    }

    // MARK: - Avertissements

    @ViewBuilder
    private var notices: some View {
        VStack(spacing: 0) {
            if let problem = controller.screenProblem {
                NoticeRow(text: problem, symbol: "rectangle.on.rectangle.slash", tint: .orange) {
                    Button("Ouvrir les Réglages") { SystemSettings.open(.screenRecording) }
                        .controlSize(.small)
                }
            }

            if let problem = controller.store.problem {
                NoticeRow(text: problem, symbol: "externaldrive.badge.xmark", tint: .orange)
            }

            if let problem = returnProblem {
                NoticeRow(text: problem, symbol: "arrow.uturn.backward.circle", tint: .orange) {
                    // La seule réparation possible quand c'est l'Accessibilité
                    // qui manque. Elle est déjà accordée dans le cas nominal —
                    // la dictée ne marcherait pas sans — donc ce bouton ne
                    // s'affiche qu'après une révocation.
                    if HotkeyMonitor.isTrusted == false {
                        Button("Ouvrir les Réglages") { _ = SystemSettings.reRequestAccessibility() }
                            .controlSize(.small)
                    }
                }
            }

            if case .unavailable(let reason) = controller.human {
                // CR-1 rendu visible. Sans ce bandeau, le veilleur se
                // contenterait de ne plus jamais rien signaler, et on
                // chercherait pendant une heure pourquoi.
                NoticeRow(
                    text: "Présence humaine inconnue — \(reason). Les voies restent visibles, mais bran ne conclura pas au silence partagé.",
                    symbol: "person.fill.questionmark",
                    tint: .orange
                )
            }
        }
    }

    // MARK: - Contenu

    @ViewBuilder
    private var content: some View {
        if let pause = controller.pause {
            paused(pause)
        } else if controller.lastTickAt == nil {
            // L'état de chargement mérite d'être distingué du vide : au premier
            // lancement, « aucune voie » et « pas encore regardé » se
            // ressemblent, et l'un des deux est faux.
            ContentUnavailableView {
                Label("Premier balayage…", systemImage: "binoculars")
            } description: {
                Text("bran lit les transcriptions des agents et, si vous l'avez activé, observe les fenêtres.")
            }
        } else if controller.verdict.lanes.isEmpty {
            ContentUnavailableView {
                Label("Aucune voie en cours", systemImage: "binoculars")
            } description: {
                Text(emptyHint)
            } actions: {
                if controller.settings.watchesWindows == false {
                    Button("Observer aussi les fenêtres") { model.showsSettings = true }
                        .buttonStyle(.borderedProminent)
                }
            }
        } else if visible.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    summary

                    ForEach(visible, id: \.identity.key) { lane in
                        LaneCard(
                            lane: lane,
                            isNext: lane.identity == controller.verdict.next?.identity,
                            onReturn: { goBack(to: lane) }
                        )
                    }
                }
                .padding(.horizontal, 26)
                .padding(.vertical, 18)
            }
            .animation(.snappy(duration: 0.25), value: controller.verdict.lanes.count)
        }
    }

    /// **Le critère de succès du produit** : « revenir sur une voie qui attend
    /// coûte une seule action ». C'est ce clic-là.
    ///
    /// Le succès ne dit rien — la fenêtre visée est devant, on l'a sous les yeux
    /// et l'application n'est même plus au premier plan. Seuls les deux échecs
    /// parlent, parce qu'eux ne se voient pas.
    private func goBack(to lane: Lane) {
        switch LaneReturn.go(to: lane.identity) {
        case .raised:
            returnProblem = nil
        case .appOnly(let reason), .notFound(let reason):
            returnProblem = reason
        }
    }

    private func paused(_ pause: WatchController.Pause) -> some View {
        ContentUnavailableView {
            Label(pause.label.capitalized, systemImage: symbol(for: pause))
        } description: {
            Text(explanation(for: pause))
        } actions: {
            if pause == .disabled {
                Button("Activer la veille") { controller.setEnabled(true) }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func symbol(for pause: WatchController.Pause) -> String {
        switch pause {
        case .disabled: "binoculars"
        case .muted: "eye.slash"
        case .lowPower: "battery.25"
        case .displayAsleep: "moon.zzz"
        }
    }

    private func explanation(for pause: WatchController.Pause) -> String {
        switch pause {
        case .disabled:
            "bran n'observe rien. Une fois activée, la veille dit lesquelles de vos sessions parallèles vous attendent."
        case .muted:
            "Une réunion est en cours ou détectée. Le veilleur se tait entièrement : pendant un partage d'écran, il afficherait le nom de vos clients à vos clients."
        case .lowPower:
            "Le mode économie d'énergie est actif. La veille reprendra dès qu'il sera coupé."
        case .displayAsleep:
            "L'écran est éteint : personne ne regarde, et le système ne rendrait que des images figées."
        }
    }

    private var emptyHint: String {
        controller.settings.watchesWindows
            ? "Aucune session d'agent lisible et aucune fenêtre suivie pour l'instant. Une session Claude Code apparaît ici dès son premier tour."
            : "Seules les sessions d'agents sont suivies pour l'instant — c'est gratuit et certain. Observer les fenêtres ajoute les onglets et les terminaux, au prix d'une capture d'écran régulière."
    }

    // MARK: - Résumé du jour

    private var summary: some View {
        HStack(spacing: 14) {
            // **Deux mesures, pas une.** Le journal donne le cumul du jour — ce
            // qui a déjà été attendu, et qui ne retombe jamais à zéro — et le
            // résolveur donne ce qui court à cet instant. Les additionner ici
            // est le seul endroit où « la dette d'attente d'aujourd'hui » a un
            // sens complet.
            metric(
                value: Self.duration(controller.store.waitSecondsToday + controller.verdict.waitingNow),
                label: "d'attente aujourd'hui",
                symbol: "hourglass"
            )

            metric(
                value: "\(controller.verdict.lanes.filter(\.state.deservesAttention).count)",
                label: "voie(s) qui vous attendent",
                symbol: "bell.badge"
            )

            if controller.verdict.sharedSilence == true {
                metric(value: "oui", label: "silence partagé", symbol: "moon.stars")
            }

            Spacer(minLength: 0)
        }
        .padding(.bottom, 4)
    }

    private func metric(value: String, label: String, symbol: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text(value)
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// « 1 h 12 » plutôt que « 4 320 s ». Une dette d'attente se lit en minutes
    /// vécues, pas en secondes comptées.
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        if total < 60 { return "\(total) s" }
        let minutes = total / 60
        guard minutes >= 60 else { return "\(minutes) min" }
        return "\(minutes / 60) h \(String(format: "%02d", minutes % 60))"
    }

    // MARK: - Filtrage

    private var visible: [Lane] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard needle.isEmpty == false else { return controller.verdict.lanes }
        return controller.verdict.lanes.filter {
            $0.identity.displayName.localizedStandardContains(needle)
        }
    }
}

// MARK: - La carte d'une voie

/// Une voie, son état, et **pourquoi**.
///
/// La raison n'est pas un ornement : une alerte dont on ne peut pas expliquer
/// l'origine finit par être ignorée, et un veilleur ignoré ne sert à rien.
///
/// **La carte entière est le bouton de retour.** Une liste qui dit qui vous
/// attend sans savoir vous y ramener est une liste qu'on lit puis qu'on quitte
/// pour aller chercher la fenêtre à la main — soit exactement le coût que le
/// produit prétend supprimer. Il n'y a donc pas de petit bouton dans un coin :
/// la ligne qu'on regarde est la ligne qu'on clique.
private struct LaneCard: View {
    let lane: Lane
    /// Vrai pour la voie que le routeur désigne. Une seule à la fois.
    let isNext: Bool
    let onReturn: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: lane.state.symbol)
                .font(.system(size: 14))
                .foregroundStyle(tint)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(lane.identity.displayName)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)

                    if isNext {
                        Text("à reprendre")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.orange.opacity(0.18), in: .capsule)
                    }

                    if lane.identity.precision == .fragile {
                        // Dire ce qu'on ne sait pas : une voie identifiée par un
                        // titre de fenêtre change de nom quand on change
                        // d'onglet, et l'utilisateur doit pouvoir en tenir compte.
                        Image(systemName: "questionmark.circle")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .help("Voie identifiée par le titre de sa fenêtre : elle peut changer d'identité si le titre change.")
                    }
                }

                Text(lane.because)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                Text(lane.state.label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(tint)
                if lane.waitingFor > 0 {
                    Text("depuis \(WatchPane.duration(lane.waitingFor))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .cardBackground(isHovering: isHovering)
        // `cardBackground` pose déjà `contentShape(.rect)` : la zone cliquable
        // est le rectangle plein de la carte, y compris ses blancs, et pas
        // seulement le texte.
        .onTapGesture(perform: onReturn)
        .onHover { hovering in
            isHovering = hovering
            setCursor(hovering)
        }
        // Une carte peut disparaître sous le curseur — un verdict qui change
        // suffit — et `onHover(false)` n'arrive alors jamais. Sans ce rappel, la
        // main resterait sur la pile des curseurs.
        .onDisappear { setCursor(false) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Revient sur cette voie")
        .accessibilityAction(.default, onReturn)
    }

    private func setCursor(_ pointing: Bool) {
        guard pointing != isPointing else { return }
        isPointing = pointing
        if pointing { NSCursor.pointingHand.push() } else { NSCursor.pop() }
    }

    /// L'état réel de la pile de curseurs, distinct de `isHovering` qui pilote
    /// le dessin : les deux se désynchronisent au démontage de la vue, et
    /// dépiler un curseur qu'on n'a pas empilé change le pointeur de toute
    /// l'application.
    @State private var isPointing = false

    private var tint: Color {
        switch lane.state {
        case .waiting: .orange
        case .working: .green
        case .stale: .secondary
        case .abandoned: .secondary
        case .unknown: .yellow
        }
    }
}

// MARK: - L'état, dans l'en-tête

/// Volontairement identique à `DictationStatusChip` et `SnapshotStatusChip`,
/// jusqu'à la police et au fond en capsule : l'en-tête aligne le grand titre sur
/// la ligne de base du contenu de droite, et un contrôle d'une autre hauteur
/// ferait tomber « Veille » plus bas que « Réunions ».
struct WatchStatusChip: View {
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
        if model.watch.pause != nil { return .secondary }
        if model.watch.verdict.lanes.contains(where: \.state.deservesAttention) { return .orange }
        return .green
    }

    private var label: String {
        if let pause = model.watch.pause { return pause.label }
        let waiting = model.watch.verdict.lanes.filter(\.state.deservesAttention).count
        guard waiting > 0 else {
            return "\(model.watch.verdict.lanes.count) voie(s) suivie(s)"
        }
        return "\(waiting) en attente"
    }
}
