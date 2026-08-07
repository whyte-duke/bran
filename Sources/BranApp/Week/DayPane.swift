import BranWatch
import SwiftUI

/// **Aujourd'hui.** L'écran que bran n'avait pas, et la question qu'on se pose
/// vraiment en ouvrant la fenêtre.
///
/// ```
/// ┌─────────────────────────────────────────┐┌──────────────────┐
/// │ Travail aujourd'hui        ╭────╮       ││ VOTRE JOURNÉE    │
/// │ 4 h 08                    │ 68% │       ││ ╭──╮ travail 68% │
/// │ 68 % d'une journée de 6 h  ╰────╯       ││ ╰──╯ sans vous   │
/// │ ┌──────────┐┌──────────┐┌────────────┐  ││      attente     │
/// │ │Pause     ││Fragmenté ││Changements │  │├──────────────────┤
/// │ │42 min    ││1 h 12    ││47          │  ││ LA RÉPARTITION   │
/// │ └──────────┘└──────────┘└────────────┘  ││ 62% crm  ▬▬▬  2h │
/// ├─────────────────────────────────────────┤│ 21% bran ▬    50m│
/// │ LA JOURNÉE                              │└──────────────────┘
/// │  ███████░░████████   ▒▒▒▒▒███████████   │
/// │  9   10   11   12   13   14   15   16   │
/// ├─────────────────────────────────────────┤
/// │ LES VOIES                               │
/// │ 62% crm · feat/api  ████░░░░░   2 h 46  │
/// └─────────────────────────────────────────┘
/// ```
///
/// **L'ordre est tout le dessin, et il n'est pas celui de Rize.**
///
/// Le chiffre d'abord, en grand, avec son anneau : c'est la réponse, et elle
/// doit se prendre en une fixation. Les trois tuiles juste dessous portent ce
/// qui appelle une action — la dernière pause, le temps fragmenté, les
/// changements de contexte — parce qu'on n'agit pas sur une répartition, on agit
/// sur « ça fait quarante-deux minutes ». La journée ensuite, qui est *où*. Les
/// voies, qui sont le multitâche rendu visible.
///
/// La répartition part dans la colonne de droite. Le camembert que tout le monde
/// met en haut est ici en second rang, et c'est délibéré : il décrit, il ne
/// déclenche rien.
///
/// **Deux colonnes quand il y a la place, une seule sinon.** La colonne de
/// droite n'est pas une décoration de largeur : elle porte ce qu'on lit *en
/// plus*, jamais ce qu'on lit *d'abord*. Repliée sous la première dans une
/// fenêtre étroite, l'écran garde exactement le même ordre de lecture.
struct DayPane: View {
    @Bindable var model: AppModel
    let day: DaySummary
    let summary: WeekSummary
    /// L'instant de lecture, remonté d'un cran : la vue ne lit pas l'horloge,
    /// et « il y a 42 min » doit se recalculer quand la page se rafraîchit.
    let now: Date

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: Space.stack) {
                main
                rail.frame(width: DayLayout.railWidth)
            }
            VStack(alignment: .leading, spacing: Space.stack) {
                main
                rail
            }
        }
    }

    private var main: some View {
        VStack(alignment: .leading, spacing: Space.stack) {
            hero
            timeline
            lanes
            blocks
        }
    }

    private var rail: some View {
        VStack(alignment: .leading, spacing: Space.stack) {
            breakdown
            waiting
        }
    }

    // MARK: - 1. La réponse

    private var hero: some View {
        Panel(title: "Aujourd'hui", trailing: dayLabel) {
            VStack(alignment: .leading, spacing: Space.inset) {
                HeroMetric(
                    label: "Travail attribué",
                    value: WatchPane.duration(summary.workedSeconds),
                    detail: targetDetail
                ) {
                    if let share = targetShare {
                        Ring(
                            share: share,
                            caption: "\((share * 100).formatted(.number.precision(.fractionLength(0)))) %",
                            thickness: RingMetric.heroThickness
                        )
                        .frame(width: RingMetric.heroDiameter, height: RingMetric.heroDiameter)
                    }
                }

                MetricRow {
                    GridRow {
                        pauseTile
                        fragmentTile
                        switchTile
                    }
                }
            }
        }
    }

    private var dayLabel: String {
        now.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    /// L'objectif est **une part, pas un plafond**. Une journée à 140 % est
    /// l'information la plus intéressante de la semaine, et l'anneau la montre
    /// en faisant un second tour — voir `Ring`.
    private var targetShare: Double? {
        let target = model.watch.settings.dailyTargetHours
        guard target > 0 else { return nil }
        return summary.workedSeconds / (Double(target) * 3600)
    }

    private var targetDetail: String? {
        let target = model.watch.settings.dailyTargetHours
        guard target > 0 else { return nil }
        return "d'une journée de \(target) h"
    }

    /// **La tuile qui appelle une action**, et la seule de l'écran.
    ///
    /// Trois formulations pour trois situations, parce que les confondre serait
    /// mentir dans deux cas sur trois : on a pris une pause, on n'en a pris
    /// aucune mais on travaille depuis un moment, ou rien n'a encore été mesuré.
    private var pauseTile: some View {
        let breaks = day.breaks

        if let since = breaks.sinceLastBreak {
            return MetricTile(
                label: "Dernière pause",
                value: "il y a \(WatchPane.duration(since))",
                detail: breaks.workPerBreak.map { ratio in
                    "1 de pause pour \(ratio.formatted(.number.precision(.fractionLength(1)))) de travail"
                        + (breaks.breaks.count > 1 ? " · \(breaks.breaks.count) pauses" : "")
                },
                // L'orange à partir du seuil seulement. Une tuile qui crie tout
                // le temps ne crie plus.
                tint: since >= DayLayout.longWithoutBreak ? Palette.attention : nil
            )
        }

        if breaks.presentSeconds > 0 {
            return MetricTile(
                label: "Dernière pause",
                value: "aucune",
                detail: "après \(WatchPane.duration(breaks.presentSeconds)) de présence",
                tint: breaks.presentSeconds >= DayLayout.longWithoutBreak ? Palette.attention : nil
            )
        }

        return MetricTile(label: "Dernière pause", value: "—", detail: "rien de mesuré")
    }

    /// **Le chiffre qui fait mal, et qui manque partout ailleurs.**
    ///
    /// Pas le nombre de changements de contexte — celui-là impressionne sans
    /// rien dire — mais le temps passé dans des séjours trop courts pour entrer
    /// dans quoi que ce soit.
    private var fragmentTile: some View {
        MetricTile(
            label: "Temps fragmenté",
            value: day.switching.fragmentedSeconds > 0
                ? WatchPane.duration(day.switching.fragmentedSeconds)
                : "aucun",
            detail: "en séjours de moins de 5 min",
            tint: day.switching.fragmentedSeconds >= DayLayout.heavyFragmentation ? Palette.attention : nil
        )
    }

    private var switchTile: some View {
        MetricTile(
            label: "Changements de contexte",
            value: "\(day.switching.count)",
            detail: day.switching.perHour.map { rate in
                "\(rate.formatted(.number.precision(.fractionLength(1)))) par heure de travail"
            } ?? "aucun travail mesuré"
        )
    }

    // MARK: - 2. La journée

    private var timeline: some View {
        Panel(
            title: "La journée",
            trailing: day.blocks.isEmpty ? nil : "\(day.blocks.count) bloc\(day.blocks.count > 1 ? "s" : "")",
            help: "Chaque bloc est une période continue de travail, toutes voies confondues. Les creux gris sont les pauses. Le trait vertical marque l'heure qu'il est."
        ) {
            DayTimeline(day: day, now: now)
        }
    }

    // MARK: - 3. Les voies

    /// **Le multitâche, sans avoir à y croire.**
    ///
    /// « 1,6 voie en parallèle en moyenne » est un chiffre qu'on lit et qu'on
    /// oublie. Des pistes entrelacées sur le même axe se voient. C'est la seule
    /// partie de cet écran qui n'existe chez personne d'autre, et c'est aussi
    /// celle que bran pouvait dessiner depuis le début — les voies étaient là,
    /// il leur manquait un axe.
    @ViewBuilder
    private var lanes: some View {
        if day.lanes.isEmpty == false {
            Panel(
                title: "Les voies",
                trailing: "\(day.lanes.count)",
                help: "Chaque voie sur le même axe que la journée. Le plein est votre travail, le pâle ce qui a avancé sans vous, l'orange une attente."
            ) {
                VStack(alignment: .leading, spacing: Space.small) {
                    ForEach(day.lanes.prefix(DayLayout.laneCeiling)) { lane in
                        LaneTrackRow(lane: lane, day: day)
                    }

                    if day.lanes.count > DayLayout.laneCeiling {
                        let rest = day.lanes.count - DayLayout.laneCeiling
                        Text("et \(rest) voie\(rest > 1 ? "s" : "") plus courte\(rest > 1 ? "s" : "").")
                            .font(Type.metaFaint)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - 4. Les blocs

    @ViewBuilder
    private var blocks: some View {
        if day.blocks.isEmpty == false {
            Panel(title: "Les blocs", help: "Du plus récent au plus ancien. « ⌇ » compte les changements de contexte pendant le bloc.") {
                VStack(alignment: .leading, spacing: Space.hair) {
                    ForEach(day.blocks.reversed()) { block in
                        BlockRow(block: block)
                    }
                }
            }
        }
    }

    // MARK: - 5. La colonne de droite

    /// La répartition de la journée entre ce qui est le vôtre, ce qui a tourné
    /// sans vous, et ce que vous avez attendu. Un anneau, parce que la question
    /// est « par rapport au tout ».
    private var breakdown: some View {
        let worked = summary.workedSeconds
        let machine = summary.machineSeconds
        let waiting = summary.waitingSeconds
        let total = max(worked + machine + waiting, 1)

        return Panel(title: "Votre journée", help: "Les trois natures de temps mesuré. Elles ne s'additionnent pas dans le chiffre principal : seul votre travail y entre.") {
            HStack(alignment: .center, spacing: Space.inset) {
                Ring(
                    share: worked / total,
                    caption: "\((worked / total * 100).formatted(.number.precision(.fractionLength(0)))) %",
                    tint: Palette.done
                )
                .frame(width: RingMetric.diameter, height: RingMetric.diameter)

                VStack(alignment: .leading, spacing: Space.tight) {
                    LegendRow(tint: Palette.done, label: "votre travail", value: WatchPane.duration(worked))
                    LegendRow(tint: Palette.machine, label: "sans vous", value: WatchPane.duration(machine))
                    LegendRow(tint: Palette.attention, label: "en attente", value: WatchPane.duration(waiting))
                    if summary.unknownSeconds > 0 {
                        LegendRow(
                            tint: Palette.asleep,
                            label: "non observé",
                            value: WatchPane.duration(summary.unknownSeconds)
                        )
                    }
                }
            }
        }
    }

    /// Les projets du jour, dans le motif de ligne commun à tout le tableau de
    /// bord. Ils sont ici et non dans la colonne principale parce qu'ils
    /// décrivent : « sur quoi » est une question qu'on se pose après « où en
    /// suis-je ».
    @ViewBuilder
    private var waiting: some View {
        if summary.projects.isEmpty == false {
            let longest = max(summary.projects.first?.tracked ?? 0, 1)
            let total = max(summary.projects.reduce(0) { $0 + $1.tracked }, 1)

            Panel(title: "Sur quoi", help: "Le dossier de travail, toutes branches confondues. À défaut de dossier, l'application.") {
                VStack(alignment: .leading, spacing: Space.tight) {
                    ForEach(summary.projects.prefix(DayLayout.projectCeiling)) { project in
                        ShareRow(
                            name: project.name,
                            segments: [
                                .init(seconds: project.worked, tint: Palette.done, label: "de votre travail"),
                                .init(seconds: project.machine, tint: Palette.machine, label: "sans vous"),
                                .init(seconds: project.waiting, tint: Palette.attention, label: "d'attente"),
                            ],
                            value: WatchPane.duration(project.tracked),
                            longest: longest,
                            share: project.tracked / total,
                            note: project.laneCount > 1 ? "\(project.laneCount) voies" : nil
                        )
                    }
                }
            }
        }
    }
}

// MARK: - Les pièces

/// Une entrée de légende : une pastille, un nom, une valeur.
///
/// La pastille **et** le nom : la couleur ne porte jamais l'information seule,
/// sinon la légende ne dit rien à qui ne distingue pas le vert de l'orange —
/// c'est-à-dire à une personne sur douze.
private struct LegendRow: View {
    let tint: Color
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: Space.small) {
            Circle()
                .fill(tint)
                .frame(width: DayLayout.dot, height: DayLayout.dot)
                .accessibilityHidden(true)

            Text(label)
                .font(Type.meta)
                .lineLimit(1)

            Spacer(minLength: Space.tight)

            Text(value)
                .font(Type.meta.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }
}

/// Une voie et ses segments, sur l'axe de la journée.
///
/// La ligne reprend les gouttières de `ShareRow` — part, nom, barre, valeur —
/// pour que les deux listes de l'écran s'alignent. La différence est que la
/// barre n'est pas ici une proportion mais **une position** : les segments sont
/// posés à l'heure où ils ont eu lieu, ce qui est toute la valeur de la piste.
private struct LaneTrackRow: View {
    let lane: DaySummary.LaneTrack
    let day: DaySummary

    private var span: TimeInterval {
        max(1, Double(day.lastHour - day.firstHour) * 3600)
    }

    private var origin: Date {
        day.start.addingTimeInterval(Double(day.firstHour) * 3600)
    }

    var body: some View {
        HStack(alignment: .center, spacing: Space.small) {
            Text(lane.name)
                .font(Type.cardBody)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(lane.name)
                .frame(width: ShareMetric.nameGutter, alignment: .leading)

            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    Capsule().fill(Palette.trough)

                    ForEach(Array(lane.segments.enumerated()), id: \.offset) { _, segment in
                        Capsule()
                            .fill(tint(of: segment))
                            .frame(width: width(of: segment, in: proxy.size.width))
                            .offset(x: x(of: segment.from, in: proxy.size.width))
                    }
                }
            }
            .frame(height: ShareMetric.barHeight)

            // Une voie sans travail attribué garde sa piste — elle a existé —
            // mais n'affiche pas « 0 min », qui se lirait comme une panne
            // plutôt que comme « ça tournait tout seul ».
            Text(lane.seconds > 0 ? WatchPane.duration(lane.seconds) : "—")
                .font(Type.meta.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: ShareMetric.valueGutter, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(lane.name)
        .accessibilityValue(spoken)
    }

    private var spoken: String {
        guard lane.seconds > 0 else { return "aucun travail qui vous soit attribué" }
        let first = lane.segments.first?.from.formatted(date: .omitted, time: .shortened) ?? ""
        return "\(WatchPane.duration(lane.seconds)) de votre travail, "
            + "\(lane.segments.count) segment\(lane.segments.count > 1 ? "s" : "") à partir de \(first)"
    }

    /// Trois teintes, et la troisième est la raison d'être de la piste : voir
    /// d'un coup qu'une voie a passé sa journée à attendre.
    private func tint(of segment: DaySummary.Segment) -> Color {
        if segment.waiting { return Palette.attention }
        return segment.yours ? Palette.done : Palette.machine.opacity(DayMetric.blockFill)
    }

    private func x(of instant: Date, in total: CGFloat) -> CGFloat {
        let ratio = instant.timeIntervalSince(origin) / span
        return total * CGFloat(min(max(ratio, 0), 1))
    }

    private func width(of segment: DaySummary.Segment, in total: CGFloat) -> CGFloat {
        let seconds = segment.to.timeIntervalSince(segment.from)
        return max(total * CGFloat(seconds / span), DayMetric.minimumWidth)
    }
}

/// Un bloc de travail, en une ligne.
private struct BlockRow: View {
    let block: DaySummary.Block

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.small) {
            Text(block.from.formatted(date: .omitted, time: .shortened))
                .font(Type.meta.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: DayLayout.timeGutter, alignment: .leading)

            Text(block.title)
                .font(Type.cardBody)
                .lineLimit(1)
                .truncationMode(.middle)

            if block.laneCount > 1 {
                Text("\(block.laneCount) voies")
                    .font(Type.metaFaint)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: Space.small)

            // Le compteur est en orange **à partir du seuil seulement**. Un
            // « ⌇2 » coloré ferait passer pour un problème deux allers-retours
            // qui n'en sont pas un.
            if block.switches > 0 {
                Text("⌇\(block.switches)")
                    .font(Type.metaFaint.monospacedDigit())
                    .foregroundStyle(
                        block.switches >= DayMetric.busySwitches
                            ? AnyShapeStyle(Palette.attention)
                            : AnyShapeStyle(.tertiary)
                    )
            }

            Text(WatchPane.duration(block.seconds))
                .font(Type.meta.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: ShareMetric.valueGutter, alignment: .trailing)
        }
        .padding(.horizontal, Space.small)
        .padding(.vertical, Space.tight)
        .background(
            isHovering ? Palette.card(hover: true) : AnyShapeStyle(.clear),
            in: .rect(cornerRadius: Radius.control)
        )
        .onHover { isHovering = $0 }
        .branAnimation(Motion.hover, value: isHovering)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(block.from.formatted(date: .omitted, time: .shortened)), \(block.title), "
            + "\(WatchPane.duration(block.seconds))"
            + (block.switches > 0 ? ", \(block.switches) changements de contexte" : "")
        )
    }
}

enum DayLayout {
    /// La colonne de droite. Assez large pour « 12 h 40 » à côté d'un nom de
    /// projet, assez étroite pour laisser la timeline respirer — c'est elle qui
    /// a besoin de la largeur, pas la légende.
    static let railWidth: CGFloat = 300
    /// La colonne d'heure d'un bloc, pour que les titres s'alignent d'une ligne
    /// à l'autre.
    static let timeGutter: CGFloat = 48
    static let dot: CGFloat = 8
    /// Douze pistes. Au-delà, la section redevient la liste de fenêtres qu'elle
    /// remplace — et le reste est dit en une ligne plutôt que tronqué en
    /// silence.
    static let laneCeiling = 12
    static let projectCeiling = 8
    /// Deux heures sans pause. Le seuil d'alerte de la tuile, et il est
    /// délibérément haut : rappeler quelqu'un à l'ordre au bout de quarante
    /// minutes fait fermer l'application.
    static let longWithoutBreak: TimeInterval = 7200
    /// Une heure de séjours trop courts sur une journée. En dessous, c'est le
    /// bruit normal d'un travail qui a des interruptions.
    static let heavyFragmentation: TimeInterval = 3600
}
