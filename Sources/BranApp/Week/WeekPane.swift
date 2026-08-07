import BranWatch
import Charts
import SwiftUI

/// **Le journal de bord** : les quatre sources réunies, sur trois portées.
///
/// C'est la vue d'accueil, et elle porte désormais **deux écrans** sous un seul
/// sélecteur, parce qu'ils ne répondent pas à la même question.
///
/// « Aujourd'hui » dit **quand** — voir `DayPane`, qui a son propre ordre et sa
/// propre justification. « 7 jours » et « 30 jours » disent **combien**, dans
/// l'ordre d'origine : la réponse en une ligne, le rythme en sept barres, les
/// projets en barres triées, et ce qui en est sorti.
///
/// Le fil des jalons est commun aux trois : ce qui est sorti d'une journée est
/// exactement ce qui est sorti d'une semaine, en plus court.
///
/// ```
/// ┌──────────────────────────────────────────────────┐
/// │  Journal              [Auj.][7 j][30 j]          │
/// │  Cette semaine : 21 h de travail · 4 projets ·   │
/// │  47 min d'attente                                │
/// │  9 h ont avancé sans vous, et ne sont pas        │
/// │  comptées ci-dessus.                             │
/// │  ▁▃█▅▂▇█   v m m j v s d(auj.)                   │
/// │  crm      ████████████████  12 h 40              │
/// │  bran     ██████████         8 h 10              │
/// │  ── Aujourd'hui ────────────────────────────     │
/// │  🎞 ORPHEO GNB · 14:02      ⌇ « rappeler… »      │
/// └──────────────────────────────────────────────────┘
/// ```
struct WeekPane: View {

    /// L'unité de l'axe suit la grandeur mesurée, au lieu de l'imposer.
    ///
    /// La première version écrivait toujours « h » : sur une journée de neuf
    /// minutes — c'est-à-dire le premier lancement de tout le monde — les quatre
    /// graduations affichaient « 0 h », « 0 h », « 0 h », « 0 h ». Un axe qui
    /// répète le même zéro ne dit rien, et pire, il donne à croire qu'on n'a
    /// rien fait alors que les barres, elles, sont bien là.
    /// **Et la graduation ne ment plus sur elle-même.** Elle arrondissait à
    /// l'entier : sur un axe gradué toutes les 1,5 h — ce que Swift Charts
    /// choisit tout seul dès que le maximum est bas — les repères 1,5 et 2
    /// s'écrivaient tous les deux « 2 h ». Deux étiquettes identiques à des
    /// hauteurs différentes, sur le seul graphique qui porte des heures.
    ///
    /// Une décimale seulement quand elle change quelque chose : « 2 h » reste
    /// « 2 h », il n'y a aucune raison d'écrire « 2,0 h » partout pour corriger
    /// un cas sur quatre.
    static func axisLabel(hours: Double) -> String {
        if hours >= 1 {
            let whole = hours.rounded() == hours
            let digits = whole ? 0 : 1
            return "\(hours.formatted(.number.precision(.fractionLength(digits)))) h"
        }
        let minutes = (hours * 60).rounded()
        return minutes == 0 ? "0" : "\(minutes.formatted(.number.precision(.fractionLength(0)))) min"
    }
    @Bindable var model: AppModel
    @Binding var query: String

    /// **L'instant de lecture, et il vieillit.**
    ///
    /// « Dernière pause il y a 42 min » et le repère « maintenant » de la
    /// timeline sont des durées relatives à l'ouverture de la page : sans un
    /// rafraîchissement, la page laissée ouverte pendant deux heures continue
    /// d'annoncer 42 minutes et pose le trait vertical là où il était à midi.
    ///
    /// Une minute de cadence, et pas une seconde : le chiffre est affiché en
    /// minutes, donc réveiller la vue plus souvent redessinerait soixante fois
    /// la même phrase. C'est aussi pour ça que ce n'est pas un `TimelineView` —
    /// il redessinerait toute la page, blocs et pistes compris.
    @State private var readAt = Date.now

    private var loader: WeekLoader { model.week }
    private var summary: WeekSummary { loader.summary }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(
                title: LibraryPane.week.title,
                subtitle: LibraryPane.week.subtitle,
                query: $query,
                searchPrompt: "Chercher un projet, une réunion, une dictée"
            ) {
                HStack(spacing: Space.small) {
                    spanPicker

                    Button("Actualiser", systemImage: "arrow.clockwise") { reload() }
                        .buttonStyle(.plain)
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.secondary)
                        .help("Relire le journal du veilleur")
                }
            }

            Divider()

            notices

            content
        }
        // La clé englobe la portée et les trois autres sources : ajouter une
        // dictée doit faire apparaître son jalon sans qu'on ait à cliquer.
        // Le journal du veilleur, lui, n'est pas suivi ligne à ligne — il
        // s'écrit toutes les quatre secondes, et relire sept fichiers à chaque
        // battement pour déplacer une barre d'un pixel serait absurde.
        .task(id: reloadKey) { await load() }
        // Le battement des durées relatives. Il vit ici plutôt que dans
        // `DayPane` pour une raison qui compte : la tâche est annulée quand la
        // section disparaît, donc rien ne bat pendant qu'on lit ses dictées.
        .task {
            while Task.isCancelled == false {
                try? await Task.sleep(for: .seconds(60))
                guard Task.isCancelled == false else { return }
                readAt = .now
                // Minuit : la page ne parle plus de la bonne journée, et le
                // journal a changé de fichier. C'est le seul moment où le
                // battement doit faire plus que rafraîchir une phrase.
                if loader.span == .day, Calendar.current.isDateInToday(loader.today.start) == false {
                    await load()
                }
            }
        }
    }

    private var reloadKey: String {
        [
            loader.span.rawValue,
            "\(model.store.recordings.count)",
            "\(model.dictation.store.entries.count)",
            "\(model.snapshot.store.entries.count)",
        ].joined(separator: "·")
    }

    private func load() async {
        await loader.load(
            markers: WeekLoader.markers(
                recordings: model.store.recordings,
                dictations: model.dictation.store.entries,
                snippets: model.snapshot.store.entries
            )
        )
    }

    private func reload() {
        Task { await load() }
    }

    private var spanPicker: some View {
        Picker("Portée", selection: Binding(
            get: { loader.span },
            set: { loader.span = $0 }
        )) {
            ForEach(WeekSpan.allCases) { span in
                Text(span.label).tag(span)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("La fenêtre observée, glissante, qui se termine aujourd'hui")
    }

    // MARK: - Avertissements

    @ViewBuilder
    private var notices: some View {
        VStack(spacing: 0) {
            if case .failed(let problem) = loader.phase {
                NoticeRow(text: problem, symbol: "externaldrive.badge.xmark", tint: Palette.attention) {
                    Button("Réessayer") { reload() }
                        .controlSize(.small)
                }
            }

            // Le veilleur éteint ne vide pas la page : les réunions, les
            // dictées et les captures restent. Mais il faut dire pourquoi les
            // heures manquent, sinon la page se lit « je n'ai rien fait ».
            if model.watch.settings.isEnabled == false, summary.trackedSeconds == 0 {
                NoticeRow(
                    text: "Le veilleur est éteint : aucun temps n'est mesuré. Les réunions, dictées et captures apparaissent quand même ci-dessous.",
                    symbol: "binoculars",
                    tint: Palette.attention
                ) {
                    Button("Activer la veille") { model.watch.setEnabled(true) }
                        .controlSize(.small)
                }
            }
        }
    }

    // MARK: - Contenu

    @ViewBuilder
    private var content: some View {
        if loader.phase == .loading, summary.isEmpty {
            skeleton
        } else if summary.isEmpty {
            ContentUnavailableView {
                Label("Rien à raconter pour l'instant", systemImage: "calendar.day.timeline.left")
            } description: {
                Text(emptyHint)
            } actions: {
                if model.watch.settings.isEnabled == false {
                    Button("Activer la veille") { model.watch.setEnabled(true) }
                        .buttonStyle(.borderedProminent)
                }
            }
        } else if isFiltered, visibleProjects.isEmpty, visibleTimeline.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            ScrollView {
                // **Deux écrans sous un seul sélecteur de portée.** « Aujourd'hui »
                // ne répond pas à la même question que « 7 jours » : l'un dit
                // *quand*, l'autre dit *combien*, et empiler un histogramme
                // d'une seule barre au-dessus d'une liste de projets aurait
                // donné une semaine amputée plutôt qu'une journée.
                //
                // Le fil des jalons est commun aux deux : ce qui est sorti de la
                // journée est exactement ce qui est sorti de la semaine, en plus
                // court.
                LazyVStack(alignment: .leading, spacing: Space.stack) {
                    if loader.span == .day {
                        DayPane(model: model, day: loader.today, summary: summary, now: readAt)
                    } else {
                        headline
                        histogram
                        projects
                    }
                    timeline
                }
                .padding(.horizontal, Space.gutter)
                .padding(.vertical, Space.stack)
            }
            .branAnimation(Motion.state, value: summary.days.count)
        }
    }

    private var emptyHint: String {
        model.watch.settings.isEnabled
            ? "Aucun temps mesuré et aucun jalon sur la période. Le journal se remplit tout seul dès qu'une session d'agent tourne ou qu'une réunion est enregistrée."
            : "Le veilleur est éteint, et rien n'a été enregistré, dicté ni capturé sur la période."
    }

    /// Le squelette dit « ça arrive » là où le contenu apparaîtra. Un état vide
    /// affiché pendant la lecture dirait le contraire — et il le dirait à
    /// chaque lancement, sur une bibliothèque pleine.
    private var skeleton: some View {
        VStack(alignment: .leading, spacing: Space.stack) {
            Panel(title: loader.span.headline) {
                VStack(alignment: .leading, spacing: Space.inset) {
                    HeroMetric(label: "Travail attribué", value: "4 h 08")
                    MetricRow {
                        GridRow {
                            MetricTile(label: "Sans vous", value: "1 h 20")
                            MetricTile(label: "En attente", value: "18 min")
                            MetricTile(label: "En parallèle", value: "1,6")
                        }
                    }
                }
            }

            Panel(title: loader.span == .day ? "La journée" : "Le rythme") {
                RoundedRectangle(cornerRadius: Radius.field, style: .continuous)
                    .fill(Palette.well)
                    .frame(height: loader.span == .day ? DayMetric.bandHeight : WeekMetric.chartHeight)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.gutter)
        .padding(.vertical, Space.stack)
        .redacted(reason: .placeholder)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Lecture du journal de la semaine…")
    }

    // MARK: - 1. La ligne chiffrée

    /// **La réponse, en un chiffre.** Elle était une phrase, et c'était le
    /// défaut de forme de cet écran : une phrase se lit, un tableau de bord se
    /// scanne. Le total en grand, le reste en tuiles autour.
    private var headline: some View {
        Panel(title: summary.span.headline, trailing: periodLabel) {
            VStack(alignment: .leading, spacing: Space.inset) {
                HeroMetric(
                    label: "Travail attribué",
                    value: WatchPane.duration(summary.workedSeconds),
                    detail: averageDetail
                )

                MetricRow {
                    GridRow {
                        MetricTile(
                            label: "Sans vous",
                            value: WatchPane.duration(summary.machineSeconds),
                            detail: "n'entre pas dans le total"
                        )
                        MetricTile(
                            label: "En attente",
                            value: WatchPane.duration(summary.waitingSeconds),
                            detail: "à ne rien faire pendant qu'une voie vous attendait",
                            tint: summary.waitingSeconds > 0 ? Palette.attention : nil
                        )
                        MetricTile(
                            label: "En parallèle",
                            value: summary.parallelism.busySeconds > 0
                                ? summary.parallelism.average.formatted(.number.precision(.fractionLength(1)))
                                : "—",
                            detail: summary.parallelism.busySeconds > 0
                                ? "voies en moyenne, \(summary.parallelism.peak) au maximum"
                                : "aucun avancement mesuré"
                        )
                    }
                }

                if summary.unknownSeconds > 0 {
                    // Le trou est dit, pas gommé : un capteur muet doit se voir.
                    Label(
                        "\(WatchPane.duration(summary.unknownSeconds)) non observées sur la période.",
                        systemImage: "eye.slash"
                    )
                    .font(Type.metaFaint)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// La moyenne par jour, qui est ce que la semaine apporte et que la journée
    /// ne peut pas donner. Sur les jours **où il s'est passé quelque chose** :
    /// diviser par sept un travail fait en quatre jours répond à une question
    /// que personne ne se pose.
    private var averageDetail: String? {
        let active = summary.days.filter { $0.worked > 0 }
        guard active.isEmpty == false else { return nil }
        let average = summary.workedSeconds / Double(active.count)
        return "\(WatchPane.duration(average)) par jour travaillé, sur \(active.count) jour\(active.count > 1 ? "s" : "")"
    }

    private var periodLabel: String {
        let from = summary.start.formatted(.dateTime.day().month(.abbreviated))
        let to = summary.end.addingTimeInterval(-1).formatted(.dateTime.day().month(.abbreviated))
        return "\(from) – \(to)"
    }

    // MARK: - 2. L'histogramme

    private var histogram: some View {
        Panel(
            title: "Le rythme",
            help: "Une barre par jour, toujours — les jours vides y sont, à zéro. Un histogramme dont les jours sans rien disparaissent ment sur le rythme. Le repère marque aujourd'hui."
        ) {
            Chart {
                ForEach(summary.days) { day in
                    // Déclarée avant les barres : les marques se peignent dans
                    // l'ordre, et un repère par-dessus la barre du jour la
                    // rendrait illisible.
                    if day.isToday {
                        RuleMark(x: .value("Jour", day.date, unit: .day))
                            .foregroundStyle(Color.accentColor.opacity(WeekMetric.todayVeil))
                            .lineStyle(StrokeStyle(lineWidth: WeekMetric.todayBand))
                    }

                    BarMark(
                        x: .value("Jour", day.date, unit: .day),
                        y: .value("Heures", day.worked / 3600)
                    )
                    .foregroundStyle(by: .value("État", Legend.worked))

                    // Empilée juste au-dessus du travail, et distincte de lui :
                    // c'est la seule façon de voir d'un coup d'œil une journée
                    // où les machines ont beaucoup tourné et vous peu.
                    BarMark(
                        x: .value("Jour", day.date, unit: .day),
                        y: .value("Heures", day.machine / 3600)
                    )
                    .foregroundStyle(by: .value("État", Legend.machine))

                    BarMark(
                        x: .value("Jour", day.date, unit: .day),
                        y: .value("Heures", day.waiting / 3600)
                    )
                    .foregroundStyle(by: .value("État", Legend.waiting))

                    BarMark(
                        x: .value("Jour", day.date, unit: .day),
                        y: .value("Heures", day.unknown / 3600)
                    )
                    .foregroundStyle(by: .value("État", Legend.unknown))
                }
            }
            .chartForegroundStyleScale([
                Legend.worked: Palette.done,
                Legend.machine: Palette.machine,
                Legend.waiting: Palette.attention,
                Legend.unknown: Palette.asleep,
            ])
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { _ in
                    AxisValueLabel(format: .dateTime.weekday(.narrow))
                }
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let hours = value.as(Double.self) {
                            Text(Self.axisLabel(hours: hours))
                        }
                    }
                }
            }
            .chartLegend(position: .bottom, spacing: Space.small)
            .frame(height: WeekMetric.chartHeight)
            .accessibilityLabel("Temps par jour")
            .accessibilityValue(histogramSummary)
        }
    }

    /// Un graphique est muet pour VoiceOver. Cette phrase est sa version lue.
    private var histogramSummary: String {
        summary.days
            .map { "\($0.date.formatted(.dateTime.weekday(.wide))) \(WatchPane.duration($0.total))" }
            .joined(separator: ", ")
    }

    // MARK: - 3. Le temps par projet

    @ViewBuilder
    private var projects: some View {
        if visibleProjects.isEmpty == false {
            Panel(
                title: "Sur quoi",
                trailing: "\(visibleProjects.count)",
                help: "Le dossier de travail, toutes branches confondues. À défaut de dossier, l'application. La barre compare au plus long de la période, pas au total."
            ) {
                VStack(alignment: .leading, spacing: Space.tight) {
                    ForEach(visibleProjects) { project in
                        ShareRow(
                            name: project.name,
                            segments: [
                                .init(seconds: project.worked, tint: Palette.done, label: "de votre travail"),
                                .init(seconds: project.machine, tint: Palette.machine, label: "sans vous"),
                                .init(seconds: project.waiting, tint: Palette.attention, label: "d'attente"),
                            ],
                            value: WatchPane.duration(project.tracked),
                            longest: longestProject,
                            share: project.tracked / projectTotal,
                            note: project.laneCount > 1 ? "\(project.laneCount) voies" : nil
                        )
                    }
                }
            }
        }
    }

    private var longestProject: TimeInterval {
        max(summary.projects.first?.tracked ?? 0, 1)
    }

    /// Le dénominateur du pourcentage : le total **visible**, pour que les parts
    /// affichées somment à cent une fois la recherche appliquée. Rapporter au
    /// total de la période donnerait des lignes filtrées qui font 3 % chacune,
    /// sans que rien n'explique où sont passés les 91 restants.
    private var projectTotal: TimeInterval {
        max(visibleProjects.reduce(0) { $0 + $1.tracked }, 1)
    }

    // MARK: - 4. Le fil des jalons

    @ViewBuilder
    private var timeline: some View {
        if visibleTimeline.isEmpty == false {
            Panel(
                title: "Ce qui en est sorti",
                help: "Réunions, dictées et captures, sur la même horloge que le reste."
            ) {
                VStack(alignment: .leading, spacing: Space.stack) {
                    ForEach(visibleTimeline) { day in
                        VStack(alignment: .leading, spacing: Space.small) {
                            Text(Self.dayTitle(day.date))
                                .font(Type.groupHead)
                                .foregroundStyle(.secondary)

                            ForEach(day.markers) { marker in
                                MilestoneRow(marker: marker)
                            }
                        }
                    }
                }
            }
        }
    }

    private static func dayTitle(_ day: Date, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(day) { return "Aujourd'hui" }
        if calendar.isDateInYesterday(day) { return "Hier" }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    // MARK: - Filtrage

    private var isFiltered: Bool {
        query.trimmingCharacters(in: .whitespaces).isEmpty == false
    }

    private var visibleProjects: [WeekSummary.ProjectRow] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard needle.isEmpty == false else { return summary.projects }
        return summary.projects.filter { $0.name.localizedStandardContains(needle) }
    }

    private var visibleTimeline: [WeekSummary.MilestoneDay] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard needle.isEmpty == false else { return summary.timeline }
        return summary.timeline.compactMap { day in
            let kept = day.markers.filter { $0.title.localizedStandardContains(needle) }
            guard kept.isEmpty == false else { return nil }
            return WeekSummary.MilestoneDay(key: day.key, date: day.date, markers: kept)
        }
    }

    private enum Legend {
        static let worked = "votre travail"
        /// « sans vous » et non « machine » : le libellé doit dire ce que ça
        /// change pour la personne qui lit, pas d'où vient la mesure.
        static let machine = "sans vous"
        static let waiting = "en attente"
        static let unknown = "non observé"
    }
}

// MARK: - Les dimensions propres à cette section

/// `Design.swift` porte une échelle d'espacement, pas des hauteurs de
/// graphique : celles-ci n'ont de sens qu'ici, et les inventer au fil des vues
/// est justement ce que le système de design a supprimé. Elles sont donc
/// nommées et rassemblées, comme là-bas.
private enum WeekMetric {
    /// La hauteur du graphique. Assez pour qu'un écart de vingt minutes se
    /// voie, assez court pour que les projets restent au-dessus du pli.
    static let chartHeight: CGFloat = 168
    /// La hauteur d'une ligne du squelette de chargement.
    static let rowHeight: CGFloat = 44
    /// Le voile qui marque aujourd'hui, et sa largeur en points.
    static let todayVeil: Double = 0.14
    static let todayBand: CGFloat = 26
    /// La largeur de la colonne d'icône d'un jalon, pour que les titres
    /// s'alignent d'une ligne à l'autre.
    static let markerGutter: CGFloat = 18
}

// MARK: - Les pièces

/// Un jalon : ce qui a été produit, et quand.
private struct MilestoneRow: View {
    let marker: WeekMarker

    @State private var isHovering = false

    private var spokenValue: String {
        var parts = [marker.at.formatted(date: .omitted, time: .shortened)]
        if let duration = marker.duration, duration > 0 {
            parts.append(WatchPane.duration(duration))
        }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.small) {
            Image(systemName: marker.kind.symbol)
                .font(Type.meta)
                .foregroundStyle(.secondary)
                .frame(width: WeekMetric.markerGutter, alignment: .leading)
                .accessibilityHidden(true)

            Text(marker.title)
                .font(Type.cardBody)
                .lineLimit(1)

            Spacer(minLength: Space.small)

            if let duration = marker.duration, duration > 0 {
                Text(WatchPane.duration(duration))
                    .font(Type.metaFaint.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }

            Text(marker.at.formatted(date: .omitted, time: .shortened))
                .font(Type.meta.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .branCard(isHovering: isHovering)
        .onHover { isHovering = $0 }
        // **L'étiquette explicite écrasait l'heure et la durée.**
        // `children: .combine` rassemble les quatre textes, puis un
        // `accessibilityLabel` remplace le tout : VoiceOver lisait « dictée :
        // rappeler le client » sans jamais dire quand ni combien de temps. Or le
        // fil des jalons est chronologique — l'heure est la moitié de ce qu'il
        // raconte. Le libellé nomme, la valeur chiffre.
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(marker.kind.label) : \(marker.title)")
        .accessibilityValue(spokenValue)
    }
}
