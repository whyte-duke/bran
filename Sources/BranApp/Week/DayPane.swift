import BranWatch
import SwiftUI

/// **Aujourd'hui.** L'écran que bran n'avait pas, et la question qu'on se pose
/// vraiment en ouvrant la fenêtre.
///
/// ```
/// ┌────────────────────────────────────────────────────────┐
/// │  4 h 08 de travail · 68 % d'une journée de 6 h         │
/// │  Dernière pause il y a 42 min · 1 de pause pour 3,6    │
/// │                                                        │
/// │  ── LA JOURNÉE ──────────────────────────────────────  │
/// │   ███████░░████████    ▒▒▒▒▒███████████░░░███████      │
/// │   9   10   11   12   13   14   15   16   17   18       │
/// │                                                        │
/// │  ── LES VOIES ───────────────────────────────────────  │
/// │  bran · main     ████████░░░░████████████    3 h 40    │
/// │  crm · feat/api    ░░░████████░░░░░░░░       1 h 50    │
/// │                                                        │
/// │  ── LES BLOCS ───────────────────────────────────────  │
/// │  09:12  bran · main            1 h 08   ⌇3            │
/// └────────────────────────────────────────────────────────┘
/// ```
///
/// **L'ordre est tout le dessin, et il n'est pas celui de Rize.**
///
/// La phrase d'abord : elle répond seule si l'on ne lit rien d'autre. La pause
/// juste après, parce que c'est la seule ligne qui appelle une action — on
/// n'agit pas sur une répartition, on agit sur « ça fait quarante-deux
/// minutes ». La journée ensuite, qui est *où*. Les voies, qui sont le
/// multitâche rendu visible : trois lignes sur le même axe, et l'entrelacement
/// se voit sans qu'on explique rien.
///
/// La répartition par catégorie — le camembert que tout le monde met en haut —
/// n'est pas ici. Elle viendra quand les catégories existeront, et elle sera en
/// dernier, parce que c'est ce qui change le moins de décisions.
struct DayPane: View {
    @Bindable var model: AppModel
    let day: DaySummary
    let summary: WeekSummary
    /// L'instant de lecture, remonté d'un cran : la vue ne lit pas l'horloge,
    /// et « il y a 42 min » doit se recalculer quand la page se rafraîchit.
    let now: Date

    var body: some View {
        LazyVStack(alignment: .leading, spacing: Space.gutter) {
            headline
            timeline
            lanes
            blocks
        }
    }

    // MARK: - 1. La réponse, en deux phrases

    private var headline: some View {
        VStack(alignment: .leading, spacing: Space.tight) {
            Text(worked)
                .font(Type.paneLead.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)

            Text(pause)
                .font(Type.meta)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let fragmented {
                Text(fragmented)
                    .font(Type.metaFaint)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// **Le chiffre principal, et son dénominateur.**
    ///
    /// « 4 h 08 » ne veut rien dire. « 4 h 08, soit 68 % d'une journée de 6 h »
    /// veut dire quelque chose, et c'est ce que Rize fait de mieux. Le
    /// dénominateur est un réglage, parce qu'une journée de six heures et une
    /// journée de dix ne se jugent pas pareil — et parce qu'un chiffre dont on
    /// ne connaît pas la base ne se compare à rien.
    private var worked: String {
        var text = "\(WatchPane.duration(summary.workedSeconds)) de travail"

        let target = model.watch.settings.dailyTargetHours
        if target > 0, summary.workedSeconds > 0 {
            let share = summary.workedSeconds / (Double(target) * 3600) * 100
            text += ", soit \(share.formatted(.number.precision(.fractionLength(0)))) %"
            text += " d'une journée de \(target) h"
        }

        if summary.waitingSeconds > 0 {
            text += " · \(WatchPane.duration(summary.waitingSeconds)) d'attente"
        }

        return text
    }

    /// La ligne des pauses. **Trois formulations, parce que trois situations
    /// différentes**, et les confondre serait mentir dans deux cas sur trois.
    private var pause: String {
        let breaks = day.breaks

        guard let since = breaks.sinceLastBreak else {
            // Aucune pause retenue. Dire « il y a 0 min » serait faux ; dire
            // « aucune pause » sans dire depuis quand ne servirait à rien.
            guard breaks.presentSeconds > 0 else {
                return "Aucune pause mesurée pour l'instant."
            }
            return "Aucune pause depuis le début de la journée, après \(WatchPane.duration(breaks.presentSeconds)) de présence."
        }

        var text = "Dernière pause il y a \(WatchPane.duration(since))"
        if let ratio = breaks.workPerBreak {
            let value = ratio.formatted(.number.precision(.fractionLength(1)))
            text += " · 1 de pause pour \(value) de travail"
        }
        if breaks.breaks.count > 1 {
            text += " · \(breaks.breaks.count) pauses aujourd'hui"
        }
        return text
    }

    /// **Le chiffre qui fait mal, et qui manque partout ailleurs.**
    ///
    /// Pas le nombre de changements de contexte — celui-là impressionne sans
    /// rien dire — mais le temps passé dans des séjours trop courts pour entrer
    /// dans quoi que ce soit. Affiché seulement quand il y en a, parce qu'une
    /// journée sans fragmentation n'a pas besoin qu'on lui en parle.
    private var fragmented: String? {
        let switching = day.switching
        guard switching.fragmentedSeconds > 0 else { return nil }

        var text = "\(WatchPane.duration(switching.fragmentedSeconds)) passées en séjours de moins de 5 min"
        if let rate = switching.perHour, rate >= 1 {
            let value = rate.formatted(.number.precision(.fractionLength(1)))
            text += ", \(value) changements de contexte par heure"
        }
        return text + "."
    }

    // MARK: - 2. La journée

    private var timeline: some View {
        Section {
            DayTimeline(day: day, now: now)
        } header: {
            DaySectionTitle(
                "La journée",
                detail: day.blocks.isEmpty
                    ? "Rien d'observé pour l'instant."
                    : "\(day.blocks.count) bloc\(day.blocks.count > 1 ? "s" : "") de travail. Le trait vertical marque l'heure qu'il est."
            )
        }
    }

    // MARK: - 3. Les voies

    /// **Le multitâche, sans avoir à y croire.**
    ///
    /// « 1,6 voie en parallèle en moyenne » est un chiffre qu'on lit et qu'on
    /// oublie. Trois pistes entrelacées sur le même axe se voient. C'est la
    /// seule partie de cet écran qui n'existe chez personne d'autre, et c'est
    /// aussi celle que bran pouvait dessiner depuis le début — les voies étaient
    /// là, il leur manquait un axe.
    @ViewBuilder
    private var lanes: some View {
        if day.lanes.isEmpty == false {
            Section {
                VStack(alignment: .leading, spacing: Space.small) {
                    ForEach(day.lanes.prefix(DayPane.laneCeiling)) { lane in
                        LaneTrackRow(lane: lane, day: day)
                    }

                    if day.lanes.count > DayPane.laneCeiling {
                        Text("et \(day.lanes.count - DayPane.laneCeiling) autre\(day.lanes.count - DayPane.laneCeiling > 1 ? "s" : "") voie\(day.lanes.count - DayPane.laneCeiling > 1 ? "s" : "") plus courte\(day.lanes.count - DayPane.laneCeiling > 1 ? "s" : "").")
                            .font(Type.metaFaint)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                DaySectionTitle(
                    "Les voies",
                    detail: "Chacune sur le même axe que la journée. Le plein est votre travail, le pâle ce qui a avancé sans vous."
                )
            }
        }
    }

    /// Douze pistes. Au-delà, la section devient la liste de fenêtres qu'elle
    /// remplace — et le reste est dit en une ligne plutôt que tronqué en
    /// silence.
    private static let laneCeiling = 12

    // MARK: - 4. Les blocs

    @ViewBuilder
    private var blocks: some View {
        if day.blocks.isEmpty == false {
            Section {
                VStack(alignment: .leading, spacing: Space.hair) {
                    ForEach(day.blocks.reversed()) { block in
                        BlockRow(block: block)
                    }
                }
            } header: {
                DaySectionTitle(
                    "Les blocs",
                    detail: "Du plus récent au plus ancien. « ⌇ » compte les changements de contexte."
                )
            }
        }
    }
}

// MARK: - Les pièces

/// Le même en-tête que celui du journal de bord. Il vit ici en attendant que les
/// deux écrans en aient assez besoin pour justifier un fichier à eux : sortir
/// une brique partagée avant d'avoir deux appelants réels produit une
/// abstraction taillée pour un seul.
private struct DaySectionTitle: View {
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

/// Une voie et ses segments, sur l'axe de la journée.
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
        VStack(alignment: .leading, spacing: Space.hair) {
            HStack(alignment: .firstTextBaseline, spacing: Space.small) {
                Text(lane.name)
                    .font(Type.cardBody)
                    .lineLimit(1)

                Spacer(minLength: Space.small)

                // Une voie qui n'a produit aucun travail attribué garde sa
                // piste — elle a existé — mais n'affiche pas « 0 min », qui se
                // lirait comme une panne plutôt que comme « ça tournait tout
                // seul ».
                if lane.seconds > 0 {
                    Text(WatchPane.duration(lane.seconds))
                        .font(Type.meta.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    Capsule()
                        .fill(Palette.well)

                    ForEach(Array(lane.segments.enumerated()), id: \.offset) { _, segment in
                        Capsule()
                            .fill(tint(of: segment))
                            .frame(width: width(of: segment, in: proxy.size.width))
                            .offset(x: x(of: segment.from, in: proxy.size.width))
                    }
                }
            }
            .frame(height: DayMetric.trackHeight)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(lane.name)
        .accessibilityValue(
            lane.seconds > 0
                ? "\(WatchPane.duration(lane.seconds)) de votre travail"
                : "aucun travail qui vous soit attribué"
        )
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

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.small) {
            Text(block.from.formatted(date: .omitted, time: .shortened))
                .font(Type.meta.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: DayMetric.timeGutter, alignment: .leading)

            Text(block.title)
                .font(Type.cardBody)
                .lineLimit(1)

            if block.laneCount > 1 {
                Text("\(block.laneCount) voies")
                    .font(Type.metaFaint)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: Space.small)

            // Le compteur est en orange **à partir du seuil seulement**. Un « ⌇2 »
            // coloré ferait passer pour un problème deux allers-retours qui n'en
            // sont pas un, et une couleur qui crie tout le temps ne crie plus.
            if block.switches > 0 {
                Text("⌇\(block.switches)")
                    .font(Type.metaFaint.monospacedDigit())
                    .foregroundStyle(block.switches >= DayMetric.busySwitches ? Palette.attention : .secondary)
            }

            Text(WatchPane.duration(block.seconds))
                .font(Type.meta.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, Space.hair)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(block.from.formatted(date: .omitted, time: .shortened)), \(block.title), "
            + "\(WatchPane.duration(block.seconds))"
            + (block.switches > 0 ? ", \(block.switches) changements de contexte" : "")
        )
    }
}

extension DayMetric {
    /// La colonne d'heure d'un bloc, pour que les titres s'alignent d'une ligne
    /// à l'autre. Même rôle que `WeekMetric.markerGutter`.
    static let timeGutter: CGFloat = 48
}
