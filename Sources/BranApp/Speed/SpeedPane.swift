import BranCore
import Charts
import SwiftUI

/// **La section « Débit » : le compteur en pleine page.**
///
/// ```
/// ┌──────────────────────────────────────────────────────────┐
/// │  Débit                                        ⌾ Wi-Fi    │
/// │  Ce que votre connexion tient vraiment, mesuré d'ici.    │
/// ├──────────────────────────────────────────────────────────┤
/// │   ╭────────────────────────────────────────────────────╮ │
/// │   │              ·  ·  ·  ·  ·  ·                      │ │
/// │   │           ▓▓▓▓▓▓▓▓▓     21,5                       │ │
/// │   │              ·      Mo/s     ·                     │ │
/// │   │        ✓ Latence   ◐ Descente   ○ Montée           │ │
/// │   │              ( Tester à nouveau )                  │ │
/// │   ╰────────────────────────────────────────────────────╯ │
/// │   ┌ Descente ─┬ Montée ──┬ Latence ─┬ Gigue ──┐          │
/// │   │ 21,5 Mo/s │19,9 Mo/s │  26 ms   │  1 ms   │          │
/// │   └───────────┴──────────┴──────────┴─────────┘          │
/// │   ┌ CE QUE LA LIGNE PERMET ──────────────────┐           │
/// │   │ ✓ Messagerie          ✓ Visioconférence  │           │
/// │   │ ✓ Appels audio        ✗ Jeu en ligne     │           │
/// │   └──────────────────────────────────────────┘           │
/// │   ┌ LES DERNIERS TESTS ──────────────────────┐           │
/// │   │  ▁ ▃ █ ▅ ▂ ▇ █                           │           │
/// │   └──────────────────────────────────────────┘           │
/// └──────────────────────────────────────────────────────────┘
/// ```
///
/// ## Pourquoi cette section existe alors que le menu suffisait
///
/// Le menu déroulant fait déjà tourner la même mesure et affiche les mêmes
/// quatre nombres. Il en montre le **résultat** ; il ne peut pas montrer le
/// **diagnostic**, et c'est toute la différence entre les deux écrans :
///
/// 1. **Un menu se ferme.** Il se referme au premier clic ailleurs, et un test
///    dure une dizaine de secondes — donc on le lance et on regarde un panneau
///    de deux cents points dans un coin. Ici, l'aiguille fait la taille d'une
///    soucoupe et se lit d'un mètre, ce qui est la distance réelle pendant ces
///    dix secondes.
/// 2. **Un menu n'a pas de colonnes.** `SpeedMenu` doit écrire « ↓ 21,5 Mo/s ⸱
///    ↑ 19,9 Mo/s » sur une ligne avec des espaces cadratins, et la liste des
///    sept usages n'y tient pas du tout — elle est réduite à une phrase. Or
///    cette liste est la seule partie qui répond à la question qu'on se pose
///    vraiment : « est-ce que ma visio va tenir ? »
/// 3. **Un menu n'a pas de mémoire visible.** Le fait le plus surprenant de
///    toute la mise au point est que la ligne du poste a été mesurée à 14 puis
///    à 30 Mo/s dans la même heure. Une phrase le dit ; douze barres le
///    montrent, et y ajoutent ce qu'aucune phrase ne donne : par où chaque
///    mesure est passée, donc **pourquoi** le chiffre a bougé.
///
/// ## Le panneau flottant se tait pendant ce temps
///
/// Voir `SpeedController.beginInlineViewing()` : deux cadrans qui montrent la
/// même aiguille, dont l'un se pose dans le coin par-dessus le second, serait le
/// genre de doublon qu'on ne remarque qu'une fois et qu'on ne pardonne pas.
struct SpeedPane: View {
    let speed: SpeedController

    /// L'échec du dernier test, **gardé sur place**.
    ///
    /// `SpeedController.phase` retombe à `.idle` cinq secondes après un échec —
    /// c'est ce qu'il faut pour un panneau flottant, qui doit finir par partir.
    /// Une section, elle, ne part pas : quelqu'un qui lance un test, se lève, et
    /// revient trouverait un écran vide et aucune trace de la panne. Même
    /// décision, et pour la même raison, que `WatchPane.returnProblem`.
    @State private var problem: String?

    /// Par où l'on passe **maintenant**, et pas au moment du dernier test.
    ///
    /// La distinction compte : la puce d'en-tête répond à « je suis sur quoi
    /// là ? », question qu'on se pose avant de cliquer, tandis que les relevés
    /// portent chacun le lien de leur propre mesure. Confondre les deux ferait
    /// annoncer « Wi-Fi » sur un Mac qu'on vient de brancher au câble.
    @State private var live: SpeedLinkProbe.Reading?

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: LibraryPane.speed.title, subtitle: LibraryPane.speed.subtitle) {
                if let live {
                    LinkChip(link: live.link, isExpensive: live.isExpensive)
                }
            }

            Divider()

            notices

            content
        }
        // Le panneau flottant se tait tant que cette section est à l'écran.
        .onAppear { speed.beginInlineViewing() }
        .onDisappear { speed.endInlineViewing() }
        .task { live = await SpeedLinkProbe.current() }
        .onChange(of: speed.phase) { _, phase in
            if case .failed(let reason) = phase { problem = reason }
        }
    }

    // MARK: - Avertissements

    @ViewBuilder
    private var notices: some View {
        VStack(spacing: 0) {
            // **Avant de cliquer, pas après.** `spentBytes` dit ce qu'un test a
            // coûté une fois qu'il est payé ; cette ligne-ci se lit pendant
            // qu'on vise le bouton, ce qui est le seul moment où l'information
            // sert encore à quelque chose.
            if live?.isExpensive == true {
                NoticeRow(
                    text: SpeedLink.expensiveWarning,
                    symbol: "exclamationmark.triangle.fill",
                    tint: Palette.attention
                )
            }

            if let problem {
                NoticeRow(text: problem, symbol: "wifi.exclamationmark", tint: Palette.broken) {
                    Button("Masquer") { self.problem = nil }
                        .controlSize(.small)
                }
            }
        }
        .branAnimation(Motion.enter, value: problem)
    }

    // MARK: - Contenu

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.stack) {
                stage

                if speed.reading.isEmpty {
                    invitation
                } else {
                    tiles
                    verdict
                    if speed.history.count >= SpeedPaneMetric.chartFloor { chart }
                    provenance
                }
            }
            .padding(.horizontal, Space.gutter)
            .padding(.vertical, Space.stack)
            .branAnimation(Motion.enter, value: speed.reading)
        }
    }

    // MARK: - Le cadran et son bouton

    private var stage: some View {
        VStack(spacing: Space.stack) {
            SpeedDial(
                needle: speed.needle,
                caption: dialCaption,
                unit: "Mo/s",
                tint: tint,
                isMeasuring: speed.phase.isRunning,
                diameter: SpeedDial.Metric.heroDiameter,
                captionFont: Type.dial,
                unitFont: Type.dialUnit
            )

            SpeedStageTrack(phase: speed.phase)

            trigger
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Space.section)
        .padding(.horizontal, Space.inset)
        .background { backdrop }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(spokenState)
    }

    /// Le fond du cadran : une surface de panneau, et une lueur qui s'allume
    /// **pendant** la mesure.
    ///
    /// La lueur n'est pas un ornement, c'est le seul repère qui dise « ça
    /// tourne » quand on revient à la fenêtre de loin. Elle est faible au repos
    /// plutôt qu'absente : une surface qui s'allume d'un coup attire l'œil, une
    /// surface qui s'éclaire un peu le laisse tranquille.
    private var backdrop: some View {
        RoundedRectangle(cornerRadius: Radius.panel, style: .continuous)
            .fill(Palette.panel)
            .overlay {
                RadialGradient(
                    colors: [tint.opacity(SpeedPaneMetric.glow), .clear],
                    center: .center,
                    startRadius: 0,
                    endRadius: SpeedPaneMetric.glowRadius
                )
                .opacity(speed.phase.isRunning ? 1 : SpeedPaneMetric.restingGlow)
                .branAnimation(Motion.state, value: speed.phase)
            }
            .clipShape(RoundedRectangle(cornerRadius: Radius.panel, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.panel, style: .continuous)
                    .strokeBorder(.separator, lineWidth: PanelMetric.edge)
            }
    }

    /// **Un seul bouton, qui change de métier plutôt que de voisin.**
    ///
    /// Poser « Lancer » et « Arrêter » côte à côte donnerait deux cibles dont
    /// une seule est jamais utile, et obligerait à en éteindre une en
    /// permanence. Le menu déroulant avait déjà tranché ainsi, pour la même
    /// raison : un test qu'on vient de lancer au mauvais moment — juste avant
    /// une visio, en partage de connexion — doit s'arrêter là où on a cliqué.
    private var trigger: some View {
        Button {
            if speed.phase.isRunning {
                speed.cancel()
            } else {
                problem = nil
                speed.start()
            }
        } label: {
            HStack(spacing: Space.small) {
                Image(systemName: speed.phase.isRunning ? "stop.fill" : "play.fill")
                Text(triggerTitle)
            }
            .font(Type.cardTitle)
            .padding(.horizontal, Space.inset)
            .padding(.vertical, Space.tight)
            .frame(minWidth: SpeedPaneMetric.triggerWidth)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .tint(speed.phase.isRunning ? Palette.broken : Color.accentColor)
        // Aucun `.disabled` : `SpeedController.canStart` ne refuse que pendant
        // une mesure, cas où ce bouton porte déjà l'autre geste. Il y avait ici
        // un délai de trente secondes, et c'est lui qui justifiait un bouton
        // éteint ; voir `SpeedPlan` pour ce qu'il coûtait à l'usage qui compte —
        // traquer une coupure intermittente, ce qui se fait en rafale.
        .help(
            speed.phase.isRunning
                ? "Arrêter la mesure — ce qui a déjà été mesuré est jeté."
                : "Latence, descente puis montée. Une dizaine de secondes, environ 140 Mo."
        )
    }

    private var triggerTitle: String {
        if speed.phase.isRunning { return "Arrêter la mesure" }
        return speed.reading.isEmpty ? "Lancer le test" : "Tester à nouveau"
    }

    // MARK: - Le premier lancement

    /// Ce qu'on voit tant que rien n'a été mesuré.
    ///
    /// **Le prix est annoncé avant le premier clic**, pas après. Une fonction
    /// qui télécharge cent quarante mégaoctets sur commande doit le dire à
    /// quelqu'un qui ne sait pas encore ce que le bouton va faire — après, il
    /// est trop tard pour que l'information serve.
    private var invitation: some View {
        VStack(alignment: .leading, spacing: Space.small) {
            Text("Aucune mesure pour l'instant.")
                .font(Type.cardBodyStrong)
            Text(
                """
                Le test sonde d'abord la latence sur une ligne au repos, puis \
                tire un gros fichier, puis en pousse un. Une dizaine de secondes, \
                environ 140 Mo consommés — et rien n'est envoyé nulle part : bran \
                mesure, il ne rapporte pas.
                """
            )
            .font(Type.cardBody)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .branWell()
    }

    // MARK: - Les quatre nombres

    /// **Quatre tuiles, et la même `GridRow` que les trois autres sections.**
    ///
    /// Les précisions sous chaque chiffre sont courtes — deux lignes, pas plus —
    /// parce que `MetricTile` les rogne au-delà. Ce qui demande une phrase
    /// entière — l'écart avec le test d'avant, une montée refusée — descend
    /// juste en dessous, où il y a la largeur de la fenêtre au lieu de celle
    /// d'un quart.
    private var tiles: some View {
        VStack(alignment: .leading, spacing: Space.small) {
            MetricRow {
                GridRow {
                    MetricTile(
                        label: "Descente",
                        // Avec son unité, contrairement au cadran : celui-ci
                        // écrit « Mo/s » sous le chiffre, une tuile n'a que son
                        // libellé, et « 21,5 » posé à côté de « 26 ms » ne dit
                        // pas de quoi il parle.
                        value: SpeedFormat.megabytesSigned(speed.reading.download),
                        // L'unité du fournisseur d'accès, **à côté** et jamais à
                        // la place : c'est elle qui évite la conversion mentale
                        // par huit, source d'à peu près toutes les disputes avec
                        // un opérateur.
                        detail: SpeedFormat.megabits(speed.reading.download)
                    )
                    MetricTile(
                        label: "Montée",
                        value: SpeedFormat.megabytesSigned(speed.reading.upload),
                        detail: speed.reading.uploadMiss == nil
                            ? SpeedFormat.megabits(speed.reading.upload)
                            : "Non mesurée",
                        tint: speed.reading.uploadMiss == nil ? nil : Palette.attention
                    )
                    MetricTile(
                        label: "Latence",
                        value: SpeedFormat.milliseconds(speed.reading.latency),
                        detail: "Aller-retour, ligne au repos"
                    )
                    MetricTile(
                        label: "Gigue",
                        value: SpeedFormat.milliseconds(speed.reading.jitter),
                        detail: "Écart entre ces allers-retours"
                    )
                }
            }

            remarks
        }
    }

    /// Ce qui demande une phrase : l'écart avec le test précédent, et la raison
    /// d'une montée manquante.
    ///
    /// **L'écart est la ligne qui empêche de lire le chiffre du dessus comme une
    /// propriété de l'abonnement.** La ligne du poste a été mesurée à 14 puis à
    /// 30 Mo/s dans la même heure : sans comparaison affichée, chaque test se
    /// lit comme un verdict définitif sur ce qu'on paie.
    ///
    /// **La montée manquante dit à qui la faute**, et c'est tout l'objet de
    /// `SpeedMiss` : un « — » muet, sur un compteur qu'on peut relancer en
    /// rafale, fait accuser la connexion à la place du serveur de mesure.
    @ViewBuilder
    private var remarks: some View {
        VStack(alignment: .leading, spacing: Space.tight) {
            if let delta = Self.delta(from: speed.previous?.download, to: speed.reading.download) {
                Text(delta)
            }
            if let miss = speed.reading.uploadMiss {
                Text(miss.summary)
            }
        }
        .font(Type.metaFaint)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// « +8,2 Mo/s depuis le test précédent ». `nil` quand il n'y a rien à
    /// comparer, et **quand l'écart est trop petit pour signifier quelque
    /// chose** : la ligne a été relevée entre 11,3 et 15,5 Mo/s dans le même
    /// quart d'heure, donc annoncer « +0,2 » serait présenter du bruit comme une
    /// évolution.
    private static func delta(from before: Double?, to now: Double?) -> String? {
        guard let before, let now, before > 0 else { return nil }
        let change = (now - before) / SpeedFormat.bytesPerMegabyte
        guard abs(change) >= SpeedPaneMetric.deltaFloor else { return nil }
        let sign = change > 0 ? "+" : "−"
        let size = abs(change).formatted(
            .number.precision(.fractionLength(1)).locale(SpeedFormat.locale)
        )
        return "\(sign)\(size)\u{202F}Mo/s depuis le test précédent"
    }

    // MARK: - Ce que la ligne permet

    private var verdict: some View {
        Panel(
            title: "Ce que la ligne permet",
            help: """
                Ce sont les besoins publiés par les services eux-mêmes, pas des \
                mesures de bran, et ils sont pris dans le sens prudent. Le jeu en \
                ligne ne se juge pas au débit : il consomme quelques dizaines de \
                kilobits et dépend entièrement de la latence et de la régularité.
                """
        ) {
            VStack(alignment: .leading, spacing: Space.inset) {
                Text(
                    SpeedGrade.summary(
                        download: speed.reading.download,
                        latency: speed.reading.latency,
                        jitter: speed.reading.jitter
                    )
                )
                .font(Type.cardBodyStrong)
                .fixedSize(horizontal: false, vertical: true)

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: SpeedPaneMetric.useColumn), spacing: Space.small)],
                    alignment: .leading,
                    spacing: Space.small
                ) {
                    ForEach(SpeedGrade.uses) { use in
                        UseRow(use: use, reading: speed.reading)
                    }
                }
            }
        }
    }

    // MARK: - Les derniers tests

    private var chart: some View {
        Panel(title: "Les derniers tests", trailing: "\(speed.history.count)") {
            VStack(alignment: .leading, spacing: Space.inset) {
                SpeedHistoryChart(history: speed.history)

                HStack(spacing: Space.small) {
                    Text(Self.span(of: speed.history))
                        .font(Type.metaFaint)
                        .foregroundStyle(.secondary)

                    Spacer(minLength: Space.small)

                    Button("Oublier l'historique") { speed.forgetHistory() }
                        .buttonStyle(.plain)
                        .font(Type.metaFaint)
                        .foregroundStyle(.secondary)
                        .help("Efface les relevés passés. Le dernier chiffre reste affiché.")
                }
            }
        }
    }

    /// « du 28 août au 1er septembre ». Sur des relevés pris le même jour, la
    /// date seule se répéterait : c'est alors l'heure qui distingue.
    private static func span(of history: [SpeedReading]) -> String {
        let dates = history.compactMap(\.measuredAt).sorted()
        guard let first = dates.first, let last = dates.last else {
            return "Un point par test, du plus ancien au plus récent."
        }
        let sameDay = Calendar.current.isDate(first, inSameDayAs: last)
        let style: Date.FormatStyle = sameDay
            ? .dateTime.hour().minute().locale(SpeedFormat.locale)
            : .dateTime.day().month(.abbreviated).locale(SpeedFormat.locale)
        return "De \(first.formatted(style)) à \(last.formatted(style))."
    }

    // MARK: - D'où vient le chiffre

    /// La provenance, en une ligne de bas de page : quand, contre quoi, par où,
    /// et pour combien d'octets.
    ///
    /// **En bas et en petit**, parce que c'est la ligne qu'on ne lit qu'une
    /// fois — mais qu'il faut pouvoir lire : un débit sans son point de mesure
    /// ne se compare à rien, et la première question devant un chiffre décevant
    /// est « contre quoi ? ».
    @ViewBuilder
    private var provenance: some View {
        let parts = [
            Self.age(of: speed.reading.measuredAt).map { "Mesuré \($0)" },
            speed.reading.source.map { "depuis \($0)" },
            speed.reading.link.map { "par \($0.title)" },
            speed.reading.spentBytes > 0 ? "\(SpeedFormat.spent(speed.reading.spentBytes)) consommés" : nil,
        ].compactMap { $0 }

        if parts.isEmpty == false {
            Text(parts.joined(separator: " · "))
                .font(Type.metaFaint)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// « il y a 4 min ». Locale fixée au français, comme partout dans bran.
    private static func age(of date: Date?) -> String? {
        guard let date else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = SpeedFormat.locale
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: .now)
    }

    // MARK: - Ce que le cadran écrit

    /// **L'aiguille pendant la mesure, le verdict après.** Même règle que le
    /// panneau flottant, et pour la même raison : un résultat médian affiché
    /// pendant la mesure ne bougerait presque pas, et un compteur immobile
    /// ressemble à un compteur en panne.
    private var dialCaption: String {
        speed.phase.isRunning
            ? SpeedFormat.megabytes(speed.live)
            : SpeedFormat.megabytes(speed.reading.download)
    }

    private var tint: Color {
        switch speed.phase {
        case .failed: Palette.broken
        case .done: Palette.done
        default: .accentColor
        }
    }

    private var spokenState: String {
        switch speed.phase {
        case .failed(let reason): "Test de débit — \(reason)"
        case .sounding, .downloading, .uploading:
            "Test de débit en cours — \(SpeedFormat.megabytesSigned(speed.live))"
        case .idle, .done:
            "Débit — \(SpeedFormat.megabytesSigned(speed.reading.download)) en descente"
        }
    }
}

// MARK: - La puce de liaison

/// **Par où l'on passe, en haut à droite.**
///
/// Elle répond à la question qu'on se pose en ouvrant la section — « je suis sur
/// quoi, là ? » — avant même d'avoir cliqué. C'est aussi ce qui donne son sens à
/// la comparaison d'en dessous : un test à 14 Mo/s et un test à 30 Mo/s ne
/// disent pas la même chose selon qu'ils sont passés par la même liaison ou non.
private struct LinkChip: View {
    let link: SpeedLink
    let isExpensive: Bool

    var body: some View {
        HStack(spacing: Space.tight) {
            Image(systemName: link.symbol)
                .foregroundStyle(isExpensive ? AnyShapeStyle(Palette.attention) : AnyShapeStyle(.tint))
            Text(link.title)
        }
        .font(Type.meta)
        .padding(.horizontal, Space.inset)
        .padding(.vertical, Space.tight)
        .background(Palette.well, in: .capsule)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Liaison courante : \(link.title)")
        .help(
            isExpensive
                ? "\(link.title) — \(SpeedLink.expensiveWarning)"
                : "La liaison que le système utilise en ce moment."
        )
    }
}

// MARK: - Les trois étapes

/// **Ce que le test est en train de faire**, en trois pastilles.
///
/// ```
///   ✓ Latence    ◐ Descente    ○ Montée
/// ```
///
/// **Pourquoi une piste et pas une barre de progression.** Une barre promet une
/// durée, et celle-ci n'est pas connue : la descente s'arrête à un budget
/// d'octets *ou* à une échéance, selon ce qui vient en premier, donc sur une
/// ligne lente elle dure le double. Une barre qui n'avance plus se lit comme une
/// panne. Trois étapes nommées ne promettent rien d'autre que leur ordre, qui
/// est vrai.
///
/// **Et elles restent visibles au repos**, en gris. C'est alors une légende :
/// elle dit ce que le bouton va faire avant qu'on clique, ce qui est exactement
/// ce qu'on veut savoir devant une fonction qui consomme cent quarante
/// mégaoctets.
private struct SpeedStageTrack: View {
    let phase: SpeedController.Phase

    private enum Step: Int, CaseIterable, Identifiable {
        case latency, download, upload

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .latency: "Latence"
            case .download: "Descente"
            case .upload: "Montée"
            }
        }

        var symbol: String {
            switch self {
            case .latency: "dot.radiowaves.left.and.right"
            case .download: "arrow.down"
            case .upload: "arrow.up"
            }
        }
    }

    private enum State {
        case pending, active, done
    }

    var body: some View {
        HStack(spacing: Space.small) {
            ForEach(Step.allCases) { step in
                pill(step, state: state(of: step))
            }
        }
        .branAnimation(Motion.state, value: phase)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(phase.title)
    }

    private func pill(_ step: Step, state: State) -> some View {
        HStack(spacing: Space.tight) {
            switch state {
            case .active:
                // Le seul indicateur indéterminé de l'écran, et il est à sa
                // place : cette étape-ci a bien une durée inconnue.
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(SpeedPaneMetric.spinner)
                    .frame(width: SpeedPaneMetric.stepGlyph)
            case .done:
                Image(systemName: "checkmark")
                    .frame(width: SpeedPaneMetric.stepGlyph)
            case .pending:
                Image(systemName: step.symbol)
                    .frame(width: SpeedPaneMetric.stepGlyph)
            }

            Text(step.title)
        }
        .font(Type.meta)
        .foregroundStyle(ink(for: state))
        .padding(.horizontal, Space.inset)
        .padding(.vertical, Space.tight)
        .background(fill(for: state), in: .capsule)
    }

    private func ink(for state: State) -> AnyShapeStyle {
        switch state {
        // Pas de blanc en dur : l'accent système peut être jaune, et du blanc
        // dessus tombe à 1,4:1 de contraste. C'est la faute exacte que
        // `Palette` existe pour fermer.
        case .active: AnyShapeStyle(.tint)
        case .done: AnyShapeStyle(.secondary)
        case .pending: AnyShapeStyle(.tertiary)
        }
    }

    private func fill(for state: State) -> AnyShapeStyle {
        switch state {
        case .active: AnyShapeStyle(.quaternary)
        case .done, .pending: AnyShapeStyle(Palette.well)
        }
    }

    private func state(of step: Step) -> State {
        switch phase {
        case .sounding:
            step == .latency ? .active : .pending
        case .downloading:
            switch step {
            case .latency: .done
            case .download: .active
            case .upload: .pending
            }
        case .uploading:
            step == .upload ? .active : .done
        case .done:
            .done
        // Un échec ne prétend pas savoir où il s'est produit : la phrase de
        // l'avertissement le dit mieux qu'une pastille rouge posée au hasard.
        case .idle, .failed:
            .pending
        }
    }
}

// MARK: - Un usage et son verdict

private struct UseRow: View {
    let use: SpeedUse
    let reading: SpeedReading

    private var verdict: Bool? {
        use.verdict(download: reading.download, latency: reading.latency, jitter: reading.jitter)
    }

    /// La régularité est-elle la seule chose qui manque ? Quand c'est le cas, la
    /// croix ne doit pas laisser accuser le débit — c'est le diagnostic le plus
    /// utile de tout l'écran, et celui qu'un simple ✗ ferait manquer.
    private var jitterOnly: Bool {
        use.limitedByJitter(download: reading.download, latency: reading.latency, jitter: reading.jitter)
    }

    var body: some View {
        HStack(spacing: Space.small) {
            Image(systemName: use.symbol)
                .frame(width: SpeedPaneMetric.useGlyph)
                .foregroundStyle(.secondary)

            Text(use.title)
                .font(Type.cardBody)
                .foregroundStyle(verdict == true ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .lineLimit(1)

            Spacer(minLength: Space.tight)

            Image(systemName: mark)
                .foregroundStyle(tint)
                .symbolRenderingMode(.hierarchical)
        }
        .padding(.horizontal, Space.small)
        .padding(.vertical, Space.tight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(use.title)
        .accessibilityValue(spoken)
        .help(help)
    }

    private var mark: String {
        switch verdict {
        case true: "checkmark.circle.fill"
        case false: jitterOnly ? "waveform.path.badge.minus" : "xmark.circle.fill"
        // Ni oui ni non : le nombre dont dépend cet usage n'a pas été mesuré, et
        // répondre quand même serait la seule ligne de l'écran à affirmer
        // quelque chose qu'on n'a pas regardé.
        case nil: "questionmark.circle"
        }
    }

    private var tint: AnyShapeStyle {
        switch verdict {
        case true: AnyShapeStyle(Palette.done)
        case false: AnyShapeStyle(Palette.attention)
        case nil: AnyShapeStyle(.tertiary)
        }
    }

    private var spoken: String {
        switch verdict {
        case true: "tenu"
        case false: jitterOnly ? "gêné par la gigue" : "hors de portée"
        case nil: "non mesuré"
        }
    }

    private var help: String {
        if jitterOnly {
            return "Le débit suffit ; c'est l'irrégularité de la ligne qui gêne cet usage."
        }
        var needs: [String] = []
        if let megabits = use.megabits {
            let text = megabits.formatted(
                .number.precision(.fractionLength(megabits < 1 ? 2 : 0)).locale(SpeedFormat.locale)
            )
            needs.append("\(text)\u{202F}Mbit/s")
        }
        if let latency = use.latencyCeiling {
            needs.append("moins de \(SpeedFormat.milliseconds(latency)) de latence")
        }
        if let jitter = use.jitterCeiling {
            needs.append("moins de \(SpeedFormat.milliseconds(jitter)) de gigue")
        }
        return needs.isEmpty ? use.title : "Demande \(needs.joined(separator: ", "))."
    }
}

// MARK: - L'historique

/// **Douze barres, et la liaison de chacune.**
///
/// C'est le seul endroit de bran où l'on voit qu'un débit est une météo plutôt
/// qu'une propriété de l'abonnement — et, depuis que chaque relevé porte son
/// lien, le seul où l'on voit *pourquoi* : une barre à 14 en Wi-Fi et la
/// suivante à 30 en Ethernet ne racontent plus une ligne capricieuse, elles
/// racontent un câble qu'on a branché.
///
/// **La légende est écrite à la main**, et pas confiée à `chartLegend`. Il n'y a
/// jamais plus de quatre liaisons possibles, leurs couleurs doivent rester les
/// mêmes d'un relevé à l'autre — sans quoi la comparaison qu'on vient de gagner
/// se perd — et une légende automatique les réattribue selon ce qui est présent
/// dans l'échantillon.
private struct SpeedHistoryChart: View {
    let history: [SpeedReading]

    private struct Sample: Identifiable {
        let id: Int
        let megabytes: Double
        let link: SpeedLink?
    }

    private var samples: [Sample] {
        history.enumerated().map { index, reading in
            Sample(
                id: index,
                megabytes: (reading.download ?? 0) / SpeedFormat.bytesPerMegabyte,
                link: reading.link
            )
        }
    }

    /// Les liaisons présentes, dans l'ordre de l'énumération plutôt que dans
    /// celui de l'historique : une légende dont les entrées changent de place à
    /// chaque test se relit à chaque fois.
    private var legend: [SpeedLink?] {
        let present = Set(history.map(\.link?.rawValue))
        let known: [SpeedLink?] = [.wifi, .wired, .cellular, .other]
        return (known + [nil]).filter { present.contains($0?.rawValue) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.small) {
            Chart(samples) { sample in
                BarMark(
                    x: .value("Test", sample.id),
                    y: .value("Descente", sample.megabytes)
                )
                .foregroundStyle(Self.colour(of: sample.link).gradient)
                .cornerRadius(SpeedPaneMetric.barCorner)
            }
            // L'axe des tests ne porte aucune information : les relevés ne sont
            // pas régulièrement espacés dans le temps, donc une graduation
            // laisserait croire à une cadence qui n'existe pas. L'étendue est
            // écrite en toutes lettres sous le graphique.
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let megabytes = value.as(Double.self) {
                            Text(Self.axisLabel(megabytes))
                        }
                    }
                }
            }
            .frame(height: SpeedPaneMetric.chartHeight)

            if legend.count > 1 || legend.first.map({ $0 != nil }) == true {
                HStack(spacing: Space.inset) {
                    ForEach(legend, id: \.self?.rawValue) { link in
                        HStack(spacing: Space.tight) {
                            Circle()
                                .fill(Self.colour(of: link))
                                .frame(width: SpeedPaneMetric.legendDot, height: SpeedPaneMetric.legendDot)
                            Text(link?.title ?? "Liaison inconnue")
                        }
                    }
                }
                .font(Type.metaFaint)
                .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Les \(history.count) derniers tests")
        .accessibilityValue(
            samples.map { SpeedFormat.megabytes($0.megabytes * SpeedFormat.bytesPerMegabyte) }
                .joined(separator: ", ") + " mégaoctets par seconde"
        )
    }

    /// **Les couleurs des barres vivent ici et non dans `Palette`.**
    ///
    /// `Palette` porte des rôles d'interface — ce qui enregistre, ce qui a
    /// échoué, ce qui dort — et ces rôles sont partagés par toute
    /// l'application. Ceux-ci sont des couleurs de **série** : elles ne veulent
    /// rien dire hors de ce graphique, elles n'ont qu'à se distinguer les unes
    /// des autres. Les ranger avec les autres ferait croire à une sémantique
    /// qu'elles n'ont pas, et lierait `Design.swift` au vocabulaire du réseau.
    private static func colour(of link: SpeedLink?) -> Color {
        switch link {
        case .wifi: .accentColor
        case .wired: .teal
        case .cellular: .orange
        case .other: .purple
        case nil: .secondary
        }
    }

    /// La graduation. Entière au-dessus de 1 Mo/s, une décimale en dessous —
    /// même règle que `WeekPane.axisLabel`, et pour la même raison : un axe qui
    /// répète « 0 » à quatre hauteurs différentes ne dit rien.
    private static func axisLabel(_ megabytes: Double) -> String {
        let digits = megabytes >= 1 || megabytes == 0 ? 0 : 1
        return megabytes.formatted(
            .number.precision(.fractionLength(digits)).locale(SpeedFormat.locale)
        )
    }
}

// MARK: - Géométrie

/// Ce que la section pose comme nombres. Même règle que `RingMetric` et
/// `PanelMetric` : ils sont ici, où ils se comparent, et pas dans une vue.
enum SpeedPaneMetric {
    /// La largeur minimale du bouton, pour que « Lancer le test » et « Arrêter
    /// la mesure » ne fassent pas sauter la mise en page l'un après l'autre.
    static let triggerWidth: CGFloat = 180

    /// La lueur derrière le cadran, et ce qu'il en reste au repos.
    static let glow: Double = 0.14
    static let restingGlow: Double = 0.35
    static let glowRadius: CGFloat = 260

    /// La gouttière des symboles d'usage et celle des pastilles d'étape. Fixes,
    /// pour que les libellés s'alignent quelle que soit la largeur du glyphe.
    static let useGlyph: CGFloat = 18
    static let stepGlyph: CGFloat = 14

    /// `ProgressView` en `.small` reste plus haut qu'un glyphe de `Type.meta`,
    /// et faisait grandir la pastille active de trois points — donc sauter les
    /// deux autres à chaque changement d'étape.
    static let spinner: CGFloat = 0.6

    /// La largeur minimale d'une colonne d'usages. « Musique en streaming »
    /// tient sur une ligne à cette largeur ; en dessous, il se rogne.
    static let useColumn: CGFloat = 210

    /// En dessous de deux relevés, il n'y a pas d'historique, il y a un chiffre.
    static let chartFloor = 2

    static let chartHeight: CGFloat = 132
    static let barCorner: CGFloat = 3
    static let legendDot: CGFloat = 7

    /// L'écart en deçà duquel on ne parle pas d'évolution. La ligne a été
    /// relevée entre 11,3 et 15,5 Mo/s dans le même quart d'heure : un demi
    /// mégaoctet par seconde est du bruit, pas une nouvelle.
    static let deltaFloor: Double = 0.5
}

#Preview("Débit") {
    SpeedPane(speed: SpeedController(version: "0.1.7"))
        .frame(width: 760, height: 720)
}
