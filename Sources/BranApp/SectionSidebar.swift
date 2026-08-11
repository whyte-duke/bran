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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            VStack(spacing: Space.hair) {
                ForEach(LibraryPane.allCases) { item in
                    SidebarItem(pane: item, isSelected: pane == item, badge: badge(for: item)) {
                        // Le seul mouvement ample de l'application, et le
                        // dernier qui échappait à « Réduire les animations » :
                        // un `withAnimation` posé au point de mutation ne peut
                        // pas être atteint par un modificateur.
                        withAnimation(Motion.honouring(Motion.pane, reduceMotion: reduceMotion)) {
                            pane = item
                        }
                    }
                }
            }
            .padding(.horizontal, Space.small)

            Spacer(minLength: Space.inset)

            footer
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Haut

    /// **Le rembourrage horizontal de la colonne, et il n'y en a qu'un.**
    ///
    /// Il valait 18 en tête, 8 + 10 sur les sections, et 16 sur « Réglages » :
    /// la roue dentée était donc désalignée de deux points avec tout ce qui la
    /// surplombe. Personne ne l'aurait nommé en regardant, mais c'est exactement
    /// ce qui fait qu'une colonne paraît bâclée sans qu'on sache dire pourquoi.
    private static let inset = Space.stack

    private var header: some View {
        HStack(spacing: Space.small) {
            Image(systemName: "bird.fill")
                .font(Type.appMark)
                .foregroundStyle(.tint)
            Text("bran")
                .font(Type.appMark)
            Spacer()
        }
        .padding(.horizontal, Self.inset)
        .padding(.top, Space.tight)
        .padding(.bottom, Space.stack)
        .accessibilityAddTraits(.isHeader)
    }

    /// Le compteur à droite d'une section. Discret, mais c'est lui qui dit
    /// qu'il s'est passé quelque chose pendant qu'on regardait ailleurs.
    private func badge(for item: LibraryPane) -> String? {
        let count = switch item {
        // Aucun compteur : le journal de bord n'a pas de « nouveautés à voir »,
        // il a un contenu qui change tout le temps. Un chiffre qui bouge sans
        // arrêt est du bruit, pas une information.
        case .week: 0
        case .meetings: model.store.recordings.count
        case .dictation: model.dictation.store.entries.count
        case .snapshots: model.snapshot.store.entries.count
        // Pas le nombre de voies suivies mais celui des voies qui **attendent** :
        // un compteur qui affiche « 7 » en permanence ne dit plus rien, alors
        // qu'un « 2 » qui apparaît est exactement l'information de la section.
        case .watch: model.watch.verdict.lanes.filter(\.state.deservesAttention).count
        }
        return count > 0 ? "\(count)" : nil
    }

    // MARK: - Bas

    private var footer: some View {
        VStack(alignment: .leading, spacing: Space.small) {
            Divider()
                .padding(.horizontal, Space.inset)

            // Au-dessus de l'état, et seulement quand il est allumé : l'éveil
            // est un mode que l'utilisateur a choisi et qui ne s'arrêtera pas
            // tout seul. C'est la seule chose de cette colonne dont l'absence de
            // rappel se paierait en batterie.
            if model.awake.isOn {
                AwakeBadge(awake: model.awake)
                    .padding(.horizontal, Self.inset)
            }

            if model.hasOpenSession == false {
                CompactStatusRow(model: model)
                    .padding(.horizontal, Self.inset)
            }

            // **La porte qui ne se ferme jamais vers l'écran d'accueil.**
            //
            // Elle existe parce que l'entrée « Bienvenue » a quitté la barre de
            // menus une fois les trois capacités en place — voir
            // `MenuBarContent`. Sans cette ligne, l'écran qui explique ce que
            // bran sait faire n'aurait plus aucun chemin d'accès, et le jour où
            // macOS révoque une autorisation après une mise à jour, le seul
            // recours serait de relancer l'application.
            //
            // Le point d'exclamation n'est pas décoratif : il porte l'alerte que
            // la barre de menus ne montre plus, et il est doublé du libellé pour
            // que la couleur ne soit pas seule à la porter.
            FooterButton(
                symbol: model.isFullyReady ? "hand.raised" : "exclamationmark.triangle.fill",
                label: model.isFullyReady ? "Autorisations" : "Autorisations — il reste à faire",
                tint: model.isFullyReady ? nil : Palette.attention
            ) {
                WindowPresenter.bringToFront("permissions", using: openWindow)
            }
            .padding(.horizontal, Self.inset)

            FooterButton(symbol: "gearshape", label: "Réglages") {
                showsSettings = true
            }
            .padding(.horizontal, Self.inset)
            .padding(.bottom, Space.card)
        }
    }
}

/// Une action du bas de colonne. Deux existent, et elles s'alignaient déjà sur
/// la même gouttière d'icône que les sections : ce type ne fait que cesser de
/// l'écrire deux fois.
private struct FooterButton: View {
    let symbol: String
    let label: String
    var tint: Color?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: SidebarItem.gap) {
                Image(systemName: symbol)
                    .frame(width: SidebarItem.iconWidth)
                    .foregroundStyle(tint ?? .primary)
                Text(label)
                Spacer()
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// Une ligne de navigation.
///
/// **Plus `private`, et pour une seule raison** : `AwakeBadge` s'aligne sur la
/// gouttière du symbole ci-dessous. La recopier vaudrait deux points d'écart le
/// jour où l'une des deux bouge — exactement le défaut que le commentaire sur
/// `inset` décrit plus haut.
struct SidebarItem: View {
    /// Entre le symbole et son libellé. Partagé avec « Réglages » en pied de
    /// colonne, qui doit s'aligner sur les sections au pixel près.
    static let gap = Space.small
    /// La gouttière du symbole. Fixe, pour que les libellés s'alignent quelle
    /// que soit la largeur du glyphe.
    static let iconWidth: CGFloat = 17

    let pane: LibraryPane
    let isSelected: Bool
    let badge: String?
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Self.gap) {
                Image(systemName: pane.symbol)
                    .frame(width: Self.iconWidth)
                    // L'accent porte la sélection **ici**, sur un glyphe, et pas
                    // en fond : un symbole coloré sur un fond neutre garde son
                    // contraste quel que soit l'accent choisi, alors qu'un fond
                    // coloré impose sa couleur au texte posé dessus.
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                Text(pane.label)
                    .fontWeight(isSelected ? .medium : .regular)
                Spacer(minLength: Space.tight)
                if let badge {
                    Text(badge)
                        .font(Type.meta.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, Space.small)
            .padding(.vertical, Space.tight + 3)
            .background {
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .fill(background)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .branAnimation(Motion.hover, value: isHovering)
    }

    /// **Aucune couleur d'accent en fond, et c'est le fond du sujet.**
    ///
    /// Trois versions de ce code se sont succédé, et les deux premières avaient
    /// le même défaut sous des formes différentes.
    ///
    /// 1. Fond `.tint`, texte blanc en dur. Dès que l'accent système est jaune
    ///    ou vert — deux des huit choix qu'offre macOS — le contraste tombe à
    ///    ~1,4:1, très loin du seuil lisible de 4,5:1.
    /// 2. Fond `.selection`, texte `.primary`. Le problème s'inverse au lieu de
    ///    disparaître : `.selection` rend l'accent saturé, et `.primary` est
    ///    **noir** en thème clair. Accent bleu, thème clair — c'est-à-dire la
    ///    configuration macOS **par défaut** — donnait du noir sur du bleu
    ///    foncé. Pire que le point de départ, et sur le cas le plus courant.
    ///
    /// La leçon est qu'aucune couleur de texte fixe ne peut être correcte sur un
    /// fond que l'utilisateur choisit. Donc on ne met pas l'accent en fond. Le
    /// fond reste un matériau neutre, dont le contraste avec `.primary` est
    /// garanti dans les deux thèmes, et **l'accent passe sur le symbole**, où il
    /// n'a personne à porter. La graisse du libellé fait le reste : la sélection
    /// se voit sans dépendre d'une seule couleur, ce qui la rend aussi lisible
    /// en vision daltonienne.
    private var background: AnyShapeStyle {
        Palette.row(hover: isHovering, selected: isSelected)
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
        HStack(spacing: Space.small) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)

            VStack(alignment: .leading, spacing: 0) {
                Text(headline)
                    .font(Type.meta.weight(.medium))
                    .monospacedDigit()
                Text(subline)
                    .font(Type.metaFaint)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch model.dictation.phase {
        case .capturing: return Palette.live
        case .transcribing: return Palette.held
        default: break
        }
        return model.pendingMeeting != nil ? Palette.attention : Palette.done
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
    /// **En premier, et c'est la vue par défaut.** Les quatre autres sections
    /// répondent chacune à « qu'est-ce que j'ai dans cette boîte ». Celle-ci
    /// répond à « qu'est-ce que j'ai fait », qui est la question qu'on se pose
    /// en ouvrant la fenêtre — et à laquelle il fallait jusqu'ici répondre en
    /// visitant les quatre autres.
    case week
    case meetings
    case dictation
    case snapshots
    case watch

    var id: String { rawValue }

    var label: String {
        switch self {
        case .week: "Journal"
        case .meetings: "Réunions"
        case .dictation: "Dictées"
        case .snapshots: "Captures"
        case .watch: "Veille"
        }
    }

    var symbol: String {
        switch self {
        case .week: "chart.bar.xaxis"
        case .meetings: "film.stack"
        case .dictation: "waveform"
        case .snapshots: "text.viewfinder"
        case .watch: "binoculars"
        }
    }

    var title: String { label }

    var subtitle: String {
        switch self {
        // Ni « sept jours » ni « cette semaine » : la portée est un
        // sélecteur, et le sous-titre mentait déjà en portée 30 jours.
        case .week: "Où en est votre journée, et ce que la semaine a été."
        case .meetings: "Vos enregistrements de réunions, stockés sur ce Mac."
        case .dictation: "Vos transcriptions, calculées et gardées sur ce Mac."
        case .snapshots: "Le texte lu à l'écran, sans rien envoyer nulle part."
        case .watch: "Laquelle de vos sessions parallèles vous attend, et depuis quand."
        }
    }
}
