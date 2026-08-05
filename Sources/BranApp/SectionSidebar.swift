import SwiftUI

/// La colonne de gauche : de la **navigation**, pas du contenu.
///
/// C'est le changement de forme le plus important de l'application. Avant, la
/// colonne listait les enregistrements et il fallait cliquer à gauche pour voir
/// à droite — deux clics pour lire une transcription de quinze mots. Désormais
/// la colonne ne porte que les sections, et la liste vit dans la vue principale,
/// où il y a la place de tout montrer d'un coup.
///
/// ```
/// ┌──────────────────┐┌────────────────────────────────────┐
/// │  bran            ││  Dictées                           │
/// │                  ││  Vos transcriptions, sur ce Mac.   │
/// │ ▸ Réunions       ││  ┌──────────────────────────────┐  │
/// │   Dictées        ││  │ « Bonjour, je vous appelle…  │  │
/// │                  ││  │ il y a 3 min · 24 mots  ⧉ ↻ ⌕│  │
/// │                  ││  └──────────────────────────────┘  │
/// │  ⌘ droite · prête││  ┌──────────────────────────────┐  │
/// │  ⚙ Réglages      ││  │ …                            │  │
/// └──────────────────┘└────────────────────────────────────┘
/// ```
struct SectionSidebar: View {
    @Bindable var model: AppModel
    @Binding var pane: LibraryPane
    @Binding var showsSettings: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            VStack(spacing: 2) {
                ForEach(LibraryPane.allCases) { item in
                    SidebarItem(pane: item, isSelected: pane == item, badge: badge(for: item)) {
                        // Un ressort court : on veut que le changement se
                        // remarque sans avoir à l'attendre.
                        withAnimation(.snappy(duration: 0.22)) { pane = item }
                    }
                }
            }
            .padding(.horizontal, 8)

            Spacer(minLength: 12)

            footer
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Haut

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "bird.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.tint)
            Text("bran")
                .font(.title3.weight(.semibold))
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.top, 6)
        .padding(.bottom, 18)
        .accessibilityAddTraits(.isHeader)
    }

    /// Le compteur à droite d'une section. Discret, mais c'est lui qui dit
    /// qu'il s'est passé quelque chose pendant qu'on regardait ailleurs.
    private func badge(for item: LibraryPane) -> String? {
        let count = switch item {
        case .meetings: model.store.recordings.count
        case .dictation: model.dictation.store.entries.count
        }
        return count > 0 ? "\(count)" : nil
    }

    // MARK: - Bas

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
                .padding(.horizontal, 12)

            if model.hasOpenSession == false {
                CompactStatusRow(model: model)
                    .padding(.horizontal, 16)
            }

            Button {
                showsSettings = true
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "gearshape")
                        .frame(width: 17)
                    Text("Réglages")
                    Spacer()
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
        }
    }
}

/// Une ligne de navigation.
private struct SidebarItem: View {
    let pane: LibraryPane
    let isSelected: Bool
    let badge: String?
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: pane.symbol)
                    .font(.system(size: 13))
                    .frame(width: 17)
                Text(pane.label)
                    .font(.body)
                Spacer(minLength: 4)
                if let badge {
                    Text(badge)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(isSelected ? .white.opacity(0.75) : .secondary)
                }
            }
            .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(background)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovering)
    }

    private var background: AnyShapeStyle {
        if isSelected { return AnyShapeStyle(.tint) }
        if isHovering { return AnyShapeStyle(.quaternary.opacity(0.5)) }
        return AnyShapeStyle(.clear)
    }
}

/// L'état, en deux lignes, en bas de la colonne.
///
/// Remplace le gros bandeau d'avant : la question « est-ce que ça tourne » se
/// pose en un coup d'œil, elle n'a pas besoin d'un encadré de quatre-vingts
/// pixels en haut de l'écran.
private struct CompactStatusRow: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)

            VStack(alignment: .leading, spacing: 0) {
                Text(headline)
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                Text(subline)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch model.dictation.phase {
        case .capturing: return .red
        case .transcribing: return .orange
        default: break
        }
        return model.pendingMeeting != nil ? .orange : .green
    }

    private var headline: String {
        switch model.dictation.phase {
        case .capturing: "Dictée en cours"
        case .transcribing: "Transcription…"
        default: model.pendingMeeting != nil ? "Réunion détectée" : "En veille"
        }
    }

    private var subline: String {
        guard model.dictationSettings.isEnabled else { return "Dictée désactivée" }
        return "\(model.dictationSettings.trigger.displayName) pour dicter"
    }
}

/// Les sections de la fenêtre. D'autres viendront s'ajouter ici.
enum LibraryPane: String, CaseIterable, Identifiable {
    case meetings
    case dictation

    var id: String { rawValue }

    var label: String {
        switch self {
        case .meetings: "Réunions"
        case .dictation: "Dictées"
        }
    }

    var symbol: String {
        switch self {
        case .meetings: "film.stack"
        case .dictation: "waveform"
        }
    }

    var title: String { label }

    var subtitle: String {
        switch self {
        case .meetings: "Vos enregistrements de réunions, stockés sur ce Mac."
        case .dictation: "Vos transcriptions, calculées et gardées sur ce Mac."
        }
    }
}
