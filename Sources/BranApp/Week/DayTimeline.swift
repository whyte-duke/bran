import BranWatch
import SwiftUI

/// **La journée sur un axe d'heures.** La pièce qui manquait à bran, et la seule
/// façon de voir un changement de contexte sans lire un tableau.
///
/// ```
///  ┌────┬────┬────┬────┬────┬────┬────┬────┬────┐  ← cellules d'une heure
///  │  ██████░░████│    │▒▒▒▒│█████████░░░│█████│  ← blocs, creux = pauses
///  └────┴────┴────┴────┴────┴────┴────┴────┴────┘
///    9   10   11   12   13   14   15   16   17     ← graduations centrées
///                          ▲
///                    maintenant
/// ```
///
/// **Un seul axe, partagé par tout ce qui se pose dessus.** Les blocs, les
/// pistes de voies et les pauses se lisent à la même abscisse : c'est ce qui
/// permet de voir qu'une pause tombe *entre* deux voies, ou qu'une session
/// tourne *pendant* qu'on est ailleurs. Deux axes côte à côte, même identiques,
/// obligeraient l'œil à faire la correspondance lui-même — et c'est exactement
/// le travail qu'une timeline existe pour supprimer.
///
/// **Les heures sont des cellules, pas des traits.** Un trait par heure dit où
/// commence l'heure ; une cellule dit *quelle* heure, parce que la graduation
/// est centrée dedans. La différence se voit dès qu'on cherche « qu'est-ce que
/// je faisais à 14 h » : avec des traits, il faut décider si le bloc est à
/// gauche ou à droite du repère.
struct DayTimeline: View {
    let day: DaySummary
    /// L'instant courant, pour le repère « maintenant ». Fourni plutôt que lu :
    /// la vue ne doit pas avoir sa propre idée de l'heure.
    let now: Date

    @State private var hovered: Date?

    private var hours: [Int] { Array(day.firstHour..<day.lastHour) }

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
                    cells(across: proxy.size.width)
                    pauses(across: proxy.size.width)
                    blocks(across: proxy.size.width)
                    marker(across: proxy.size.width)
                }
                .clipShape(.rect(cornerRadius: Radius.field))
            }
            .frame(height: DayMetric.bandHeight)

            ruler
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("La journée, heure par heure")
        .accessibilityValue(spoken)
    }

    // MARK: - Les couches

    /// Le fond : une cellule par heure, séparées d'un cheveu. C'est lui qui fait
    /// qu'un bloc a une position et pas seulement une largeur.
    private func cells(across total: CGFloat) -> some View {
        HStack(spacing: DayMetric.hairline) {
            ForEach(hours, id: \.self) { hour in
                Rectangle()
                    .fill(Palette.trough)
                    // L'heure de midi et celle de dix-huit heures très
                    // légèrement marquées : ce sont les deux repères qu'on
                    // cherche en premier dans une journée, et les nommer coûte
                    // moins qu'une étiquette de plus.
                    .opacity(hour == 12 || hour == 18 ? DayMetric.anchorInk : 1)
            }
        }
        .accessibilityHidden(true)
    }

    /// Les pauses, **en creux**. Elles ne se peignent pas par-dessus les blocs :
    /// elles n'en croisent jamais, par construction — une pause est justement
    /// une absence de travail.
    private func pauses(across total: CGFloat) -> some View {
        ForEach(day.breaks.breaks) { pause in
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .fill(Palette.panelHead)
                .overlay {
                    Image(systemName: "cup.and.saucer")
                        .font(Type.metaFaint)
                        .foregroundStyle(.tertiary)
                        .opacity(width(of: pause.seconds, in: total) > DayMetric.iconFloor ? 1 : 0)
                }
                .frame(width: width(of: pause.seconds, in: total))
                .offset(x: x(of: pause.at, in: total))
                .help("Pause de \(WatchPane.duration(pause.seconds)), à partir de \(pause.at.formatted(date: .omitted, time: .shortened))")
        }
        .frame(height: DayMetric.bandHeight, alignment: .top)
    }

    /// Les blocs de travail. Pleins, opaques, et c'est le seul élément de la
    /// bande qui ait le droit de l'être.
    private func blocks(across total: CGFloat) -> some View {
        ForEach(day.blocks) { block in
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .fill(Palette.done.opacity(hovered == block.from ? DayMetric.blockHover : DayMetric.blockFill))
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
                .onHover { hovered = $0 ? block.from : nil }
        }
        .frame(height: DayMetric.bandHeight, alignment: .top)
        .branAnimation(Motion.hover, value: hovered)
    }

    /// Où on en est : un trait, coiffé d'une pastille pour qu'il se lise comme
    /// un repère et non comme un bloc d'une minute.
    ///
    /// Il ne s'affiche que si l'instant tombe dans l'axe — une journée d'hier
    /// n'a pas de « maintenant ».
    @ViewBuilder
    private func marker(across total: CGFloat) -> some View {
        if now >= origin, now <= origin.addingTimeInterval(span) {
            VStack(spacing: 0) {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: DayMetric.markerCap, height: DayMetric.markerCap)
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: DayMetric.marker)
            }
            .frame(height: DayMetric.bandHeight)
            .offset(x: x(of: now, in: total) - DayMetric.markerCap / 2)
            .help("Maintenant — \(now.formatted(date: .omitted, time: .shortened))")
            .accessibilityHidden(true)
        }
    }

    /// Les graduations, **centrées dans leur cellule**. Une sur deux ou sur
    /// trois quand l'amplitude est large : douze étiquettes collées les unes aux
    /// autres ne se lisent pas.
    private var ruler: some View {
        HStack(spacing: DayMetric.hairline) {
            ForEach(hours, id: \.self) { hour in
                Text(hour % step == 0 ? "\(hour)" : "")
                    .font(Type.metaFaint.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .accessibilityHidden(true)
    }

    private var step: Int {
        let width = day.lastHour - day.firstHour
        return width > 14 ? 3 : (width > 9 ? 2 : 1)
    }

    // MARK: - Géométrie

    private func x(of instant: Date, in total: CGFloat) -> CGFloat {
        let ratio = instant.timeIntervalSince(origin) / span
        return total * CGFloat(min(max(ratio, 0), 1))
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
    /// **dans l'ordre chronologique**, avec leurs heures — c'est-à-dire ce que
    /// l'œil y prend.
    private var spoken: String {
        guard day.blocks.isEmpty == false || day.breaks.breaks.isEmpty == false else {
            return "Rien d'observé pour l'instant."
        }

        let entries: [(at: Date, text: String)] =
            day.blocks.map { block in
                (block.from, "\(block.from.formatted(date: .omitted, time: .shortened)), \(block.title), \(WatchPane.duration(block.seconds))")
            }
            + day.breaks.breaks.map { pause in
                (pause.at, "\(pause.at.formatted(date: .omitted, time: .shortened)), pause de \(WatchPane.duration(pause.seconds))")
            }

        return entries.sorted { $0.at < $1.at }.map(\.text).joined(separator: ". ")
    }
}

/// Les dimensions propres à la timeline. Même raisonnement que `WeekMetric` dans
/// `WeekPane` : `Design.swift` porte une échelle d'espacement, pas des hauteurs
/// de bande — mais les inventer au fil de la vue est ce que le système de design
/// a supprimé. Elles sont donc nommées ici, et comparables entre elles.
enum DayMetric {
    /// La hauteur de la bande. Assez pour qu'un bloc de quinze minutes se voie
    /// et porte son compteur, assez courte pour que les voies restent au-dessus
    /// du pli.
    static let bandHeight: CGFloat = 56
    static let hairline: CGFloat = 1
    /// Le repère « maintenant » et sa pastille.
    static let marker: CGFloat = 2
    static let markerCap: CGFloat = 7
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
    static let blockHover: Double = 0.75
    /// L'atténuation des cellules de midi et de dix-huit heures.
    static let anchorInk: Double = 0.55
}
