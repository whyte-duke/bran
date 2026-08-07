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
    static func axisLabel(hours: Double) -> String {
        if hours >= 1 {
            return "\(hours.formatted(.number.precision(.fractionLength(0)))) h"
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
                LazyVStack(alignment: .leading, spacing: Space.gutter) {
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
        VStack(alignment: .leading, spacing: Space.gutter) {
            Text("Aujourd'hui : 4 h 08 de travail · 3 projets")
                .font(Type.cardTitle)
            RoundedRectangle(cornerRadius: Radius.field, style: .continuous)
                .fill(Palette.well)
                .frame(height: WeekMetric.chartHeight)
            ForEach(0..<3, id: \.self) { _ in
                RoundedRectangle(cornerRadius: Radius.field, style: .continuous)
                    .fill(Palette.well)
                    .frame(height: WeekMetric.rowHeight)
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

    /// La réponse, en une phrase. Tout le reste de la page la détaille.
    private var headline: some View {
        VStack(alignment: .leading, spacing: Space.tight) {
            Text(headlineText)
                .font(Type.paneLead.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)

            if let parallelismText {
                Text(parallelismText)
                    .font(Type.meta)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// **Le premier chiffre est le vôtre, et il ne l'était pas.**
    ///
    /// La ligne annonçait `trackedSeconds`, qui additionne tout ce qui a bougé à
    /// l'écran. Sur deux jours de journal réel, cela faisait 12 h dont 7,6 h de
    /// fenêtres que personne ne regardait. Elle annonce désormais le travail
    /// attribué — voir `WeekSummary.isYours` — et ce qui a tourné sans vous est
    /// dit à part, dans la phrase du dessous. Deux chiffres qui ne s'ajoutent
    /// pas, plutôt qu'un seul qui les mélange.
    private var headlineText: String {
        var parts = ["\(WatchPane.duration(summary.workedSeconds)) de travail"]

        if summary.projects.isEmpty == false {
            parts.append("\(summary.projects.count) projet\(summary.projects.count > 1 ? "s" : "")")
        }
        if summary.waitingSeconds > 0 {
            parts.append("\(WatchPane.duration(summary.waitingSeconds)) d'attente")
        }
        if summary.unknownSeconds > 0 {
            // Le trou est dit, pas gommé : un capteur muet doit se voir.
            parts.append("\(WatchPane.duration(summary.unknownSeconds)) non observées")
        }

        return "\(summary.span.headline) : " + parts.joined(separator: " · ")
    }

    /// Le chiffre qui casse une illusion : on croit faire tourner quatre
    /// sessions de front, on en fait tourner beaucoup moins. Affiché seulement
    /// quand il y a de quoi le calculer — une moyenne sur rien ne vaut rien.
    ///
    /// Le temps machine le précède depuis qu'il a quitté le total : sans cette
    /// phrase, il aurait simplement disparu de la page, et une heure qu'on ne
    /// voit plus nulle part passe pour une heure perdue.
    private var parallelismText: String? {
        var sentences: [String] = []

        if summary.machineSeconds > 0 {
            sentences.append(
                "\(WatchPane.duration(summary.machineSeconds)) ont avancé sans vous, et ne sont pas comptées ci-dessus."
            )
        }

        let parallelism = summary.parallelism
        if parallelism.busySeconds > 0 {
            let average = parallelism.average.formatted(.number.precision(.fractionLength(1)))
            sentences.append(
                "\(average) voie en parallèle en moyenne, \(parallelism.peak) au maximum, sur \(WatchPane.duration(parallelism.busySeconds)) d'avancement réel."
            )
        }

        return sentences.isEmpty ? nil : sentences.joined(separator: " ")
    }

    // MARK: - 2. L'histogramme

    private var histogram: some View {
        Section {
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
        } header: {
            SectionTitle("Le rythme", detail: "Le repère marque aujourd'hui.")
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
            Section {
                VStack(alignment: .leading, spacing: Space.inset) {
                    ForEach(visibleProjects) { project in
                        ProjectBar(project: project, longest: longestProject)
                    }
                }
            } header: {
                SectionTitle("Sur quoi", detail: "Le dossier de travail, toutes branches confondues.")
            }
        }
    }

    private var longestProject: TimeInterval {
        max(summary.projects.first?.tracked ?? 0, 1)
    }

    // MARK: - 4. Le fil des jalons

    @ViewBuilder
    private var timeline: some View {
        if visibleTimeline.isEmpty == false {
            Section {
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
            } header: {
                SectionTitle("Ce qui en est sorti", detail: "Réunions, dictées et captures, sur la même horloge.")
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
    /// L'épaisseur d'une barre de projet.
    static let barHeight: CGFloat = 10
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

/// Le titre d'un bloc, avec sa phrase d'explication. Elle n'est pas
/// décorative : « 1,6 voie en parallèle » ne veut rien dire sans savoir sur
/// quoi la moyenne est prise.
private struct SectionTitle: View {
    let title: String
    let detail: String

    init(_ title: String, detail: String) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.hair) {
            Text(title)
                .font(Type.groupHead)
            Text(detail)
                .font(Type.metaFaint)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, Space.small)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Un projet, sa barre et sa durée.
///
/// Le libellé est **au-dessus** de la barre et non à côté : une colonne de noms
/// de largeur fixe tronque « castral-crm-backend » ou laisse un trou de deux
/// cents points quand tous les projets s'appellent « bran ».
private struct ProjectBar: View {
    let project: WeekSummary.ProjectRow
    /// Le plus long de la semaine — c'est lui qui fait le 100 %.
    let longest: TimeInterval

    var body: some View {
        VStack(alignment: .leading, spacing: Space.tight) {
            HStack(alignment: .firstTextBaseline, spacing: Space.small) {
                Text(project.name)
                    .font(Type.cardTitle)
                    .lineLimit(1)

                if project.laneCount > 1 {
                    Text("\(project.laneCount) voies")
                        .font(Type.metaFaint)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: Space.small)

                Text(WatchPane.duration(project.tracked))
                    .font(Type.cardBody.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            GeometryReader { proxy in
                HStack(spacing: 0) {
                    // Deux segments dans une seule barre : ce qui a avancé et
                    // ce qui a attendu. Deux barres séparées obligeraient à
                    // comparer deux longueurs pour un seul projet.
                    Capsule()
                        .fill(Palette.done)
                        .frame(width: width(project.worked, in: proxy.size.width))
                    Capsule()
                        .fill(Palette.machine)
                        .frame(width: width(project.machine, in: proxy.size.width))
                    Capsule()
                        .fill(Palette.attention)
                        .frame(width: width(project.waiting, in: proxy.size.width))
                    Spacer(minLength: 0)
                }
            }
            .frame(height: WeekMetric.barHeight)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(project.name)
        .accessibilityValue(
            "\(WatchPane.duration(project.worked)) de votre travail, "
            + "\(WatchPane.duration(project.machine)) sans vous, "
            + "\(WatchPane.duration(project.waiting)) d'attente"
        )
    }

    private func width(_ seconds: TimeInterval, in available: CGFloat) -> CGFloat {
        guard longest > 0, seconds > 0 else { return 0 }
        return max(available * CGFloat(seconds / longest), Space.tight)
    }
}

/// Un jalon : ce qui a été produit, et quand.
private struct MilestoneRow: View {
    let marker: WeekMarker

    @State private var isHovering = false

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
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(marker.kind.label) : \(marker.title)")
    }
}
