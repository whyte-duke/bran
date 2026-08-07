import BranWatch
import SwiftUI

/// **La journée sur un axe d'heures.** La pièce qui manquait à bran, et la seule
/// façon de voir un changement de contexte sans lire un tableau.
///
/// ```
///   9    10   11   12   13   14   15   16   17   18
///  ─┬────┬────┬────┬────┬────┬────┬────┬────┬────┬─
///   ███████░░███████     ▒▒▒▒▒██████████░░░███████
///   ├─ bran ──────────────────────┤
///   │      ├─ crm ─┤    ├─ hub ─┤
/// ```
///
/// **Un seul axe, partagé par tout ce qui se pose dessus.** Les blocs, les
/// pistes de voies et les pauses se lisent à la même abscisse : c'est ce qui
/// permet de voir qu'une pause tombe *entre* deux voies, ou qu'une session
/// tourne *pendant* qu'on est ailleurs. Deux axes côte à côte, même identiques,
/// obligeraient l'œil à faire la correspondance lui-même — et c'est exactement
/// le travail qu'une timeline existe pour supprimer.
struct DayTimeline: View {
    let day: DaySummary
    /// L'instant courant, pour le repère « maintenant ». Fourni plutôt que lu :
    /// la vue ne doit pas avoir sa propre idée de l'heure.
    let now: Date

    private var span: TimeInterval {
        max(1, Double(day.lastHour - day.firstHour) * 3600)
    }

    private var origin: Date {
        day.start.addingTimeInterval(Double(day.firstHour) * 3600)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.tight) {
            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    grid(across: proxy.size.width)
                    presence(across: proxy.size.width)
                    blocks(across: proxy.size.width)
                    marker(across: proxy.size.width)
                }
            }
            .frame(height: DayMetric.bandHeight)

            ruler
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("La journée, heure par heure")
        .accessibilityValue(spoken)
    }

    // MARK: - Les couches

    /// Un trait par heure, très pâle. Sans lui, un bloc flotte : on voit qu'il
    /// est large, jamais où il commence.
    private func grid(across total: CGFloat) -> some View {
        ForEach(day.firstHour...day.lastHour, id: \.self) { hour in
            Rectangle()
                .fill(.separator)
                .frame(width: DayMetric.hairline)
                .offset(x: x(ofHour: hour, in: total))
        }
    }

    /// La bande de présence, **sous** les blocs : elle dit quand quelqu'un était
    /// là, et son absence est ce qui rend une pause visible.
    private func presence(across total: CGFloat) -> some View {
        ForEach(day.breaks.breaks) { pause in
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .fill(Palette.well)
                .overlay(alignment: .center) {
                    // Les hachures disent « rien ici », par la texture et pas
                    // seulement par la couleur : une pause et une plage vide
                    // sont deux choses différentes, et un daltonien doit
                    // pouvoir les distinguer.
                    Image(systemName: "pause.fill")
                        .font(Type.metaFaint)
                        .foregroundStyle(.tertiary)
                        .opacity(width(of: pause.seconds, in: total) > DayMetric.iconFloor ? 1 : 0)
                }
                .frame(width: width(of: pause.seconds, in: total))
                .offset(x: x(of: pause.at, in: total))
        }
        .frame(height: DayMetric.bandHeight, alignment: .top)
    }

    /// Les blocs de travail. Pleins, opaques, et c'est le seul élément de la
    /// bande qui ait le droit de l'être.
    private func blocks(across total: CGFloat) -> some View {
        ForEach(day.blocks) { block in
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .fill(Palette.done.opacity(DayMetric.blockFill))
                .overlay(alignment: .topTrailing) {
                    // Le compteur de changements de contexte, posé sur le bloc
                    // qui les a subis. Un bloc d'une heure à onze changements
                    // n'est pas une heure de travail profond, et c'est le seul
                    // endroit de l'application qui le dit.
                    if block.switches >= DayMetric.busySwitches,
                       width(of: block.seconds, in: total) > DayMetric.iconFloor {
                        Text("⌇\(block.switches)")
                            .font(Type.metaFaint.monospacedDigit())
                            .foregroundStyle(Palette.attention)
                            .padding(Space.hair)
                    }
                }
                .frame(width: width(of: block.seconds, in: total))
                .offset(x: x(of: block.from, in: total))
                .help(help(for: block))
        }
        .frame(height: DayMetric.bandHeight, alignment: .top)
    }

    /// Où on en est. Le repère ne s'affiche que si l'instant tombe dans l'axe —
    /// une journée d'hier n'a pas de « maintenant ».
    @ViewBuilder
    private func marker(across total: CGFloat) -> some View {
        let offset = x(of: now, in: total)
        if now >= origin, now <= origin.addingTimeInterval(span) {
            Rectangle()
                .fill(Color.accentColor)
                .frame(width: DayMetric.marker)
                .offset(x: offset)
                .accessibilityHidden(true)
        }
    }

    /// Les graduations. Une heure sur deux quand l'amplitude est large : douze
    /// étiquettes de « 14 » collées les unes aux autres ne se lisent pas.
    private var ruler: some View {
        GeometryReader { proxy in
            ForEach(day.firstHour...day.lastHour, id: \.self) { hour in
                if hour % step == 0 {
                    Text("\(hour)")
                        .font(Type.metaFaint.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .offset(x: x(ofHour: hour, in: proxy.size.width) - DayMetric.labelNudge)
                }
            }
        }
        .frame(height: DayMetric.rulerHeight)
        .accessibilityHidden(true)
    }

    private var step: Int {
        day.lastHour - day.firstHour > 12 ? 3 : (day.lastHour - day.firstHour > 8 ? 2 : 1)
    }

    // MARK: - Géométrie

    private func x(of instant: Date, in total: CGFloat) -> CGFloat {
        let ratio = instant.timeIntervalSince(origin) / span
        return total * CGFloat(min(max(ratio, 0), 1))
    }

    private func x(ofHour hour: Int, in total: CGFloat) -> CGFloat {
        x(of: day.start.addingTimeInterval(Double(hour) * 3600), in: total)
    }

    /// La largeur d'une durée, **avec un plancher**. Sans lui, une pause de six
    /// minutes sur un axe de douze heures fait moins d'un pixel : elle
    /// disparaîtrait, et une pause invisible est pire qu'une pause absente
    /// puisqu'on croit alors ne pas en avoir pris.
    private func width(of seconds: TimeInterval, in total: CGFloat) -> CGFloat {
        max(total * CGFloat(seconds / span), DayMetric.minimumWidth)
    }

    private func help(for block: DaySummary.Block) -> String {
        let from = block.from.formatted(date: .omitted, time: .shortened)
        let to = block.to.formatted(date: .omitted, time: .shortened)
        var text = "\(from) – \(to) · \(block.title) · \(WatchPane.duration(block.seconds))"
        if block.laneCount > 1 { text += " · \(block.laneCount) voies" }
        if block.switches > 0 { text += " · \(block.switches) changements de contexte" }
        return text
    }

    /// Un graphique est muet pour VoiceOver, et celui-ci porte l'information
    /// principale de l'écran. Sa version lue énumère les blocs et les pauses
    /// dans l'ordre, avec leurs heures — c'est-à-dire ce que l'œil y prend.
    private var spoken: String {
        guard day.blocks.isEmpty == false || day.breaks.breaks.isEmpty == false else {
            return "Rien d'observé pour l'instant."
        }

        let blocks = day.blocks.map { block in
            "\(block.from.formatted(date: .omitted, time: .shortened)), \(block.title), \(WatchPane.duration(block.seconds))"
        }
        let pauses = day.breaks.breaks.map { pause in
            "pause à \(pause.at.formatted(date: .omitted, time: .shortened)), \(WatchPane.duration(pause.seconds))"
        }

        return (blocks + pauses).joined(separator: ". ")
    }
}

/// Les dimensions propres à la timeline. Même raisonnement que `WeekMetric` dans
/// `WeekPane` : `Design.swift` porte une échelle d'espacement, pas des hauteurs
/// de bande — mais les inventer au fil de la vue est ce que le système de design
/// a supprimé. Elles sont donc nommées ici, et comparables entre elles.
enum DayMetric {
    /// La hauteur de la bande. Assez pour qu'un bloc de quinze minutes se voie,
    /// assez courte pour que les voies restent au-dessus du pli.
    static let bandHeight: CGFloat = 44
    /// La hauteur d'une piste de voie, sous la bande principale.
    static let trackHeight: CGFloat = 10
    static let rulerHeight: CGFloat = 14
    static let hairline: CGFloat = 1
    /// Le repère « maintenant ». Deux points : un seul disparaît sur un écran
    /// non-Retina, trois ressemblent à un bloc.
    static let marker: CGFloat = 2
    /// La largeur minimale d'un segment. En dessous, il n'existe pas à l'écran.
    static let minimumWidth: CGFloat = 3
    /// La largeur en dessous de laquelle une icône ou un compteur posé sur un
    /// bloc déborderait au lieu de l'annoter.
    static let iconFloor: CGFloat = 34
    /// À partir de combien de changements de contexte un bloc mérite d'être
    /// signalé. Deux allers-retours dans une heure sont normaux ; cinq disent
    /// quelque chose.
    static let busySwitches = 5
    static let blockFill: Double = 0.55
    /// Le décalage d'une étiquette d'heure pour qu'elle soit centrée sur son
    /// trait plutôt que posée à sa droite.
    static let labelNudge: CGFloat = 5
}
