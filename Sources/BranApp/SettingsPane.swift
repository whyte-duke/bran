import SwiftUI

/// Les réglages, séparés au lieu d'être empilés.
///
/// **Le problème mesuré.** Un seul `Form` portait huit sections — qualité,
/// démarrage, quinze contrôles de dictée, douze de capture, veille, CRM,
/// autorisations, dossier — dans une feuille figée à 560 × 620. Changer le
/// raccourci de la capture demandait de défiler devant tout le reste, et rien
/// dans l'écran ne disait où s'arrêtait une fonction et où commençait la
/// suivante : les titres de section étaient le seul séparateur, et ils défilent.
///
/// ```
/// ┌───────────────┬──────────────────────────────┐
/// │ ⚙ Général     │  Dictée                      │
/// │ ▤ Réunions    │  ┌────────────────────────┐  │
/// │ ∿ Dictée   ◀  │  │ Raccourci        ⌘ dr. │  │
/// │ ⧉ Capture     │  │ Modèle          ✓ prêt │  │
/// │ ◉ Veille      │  └────────────────────────┘  │
/// │ ⛓ Connexions  │                              │
/// │ 🔒 Autoris.   │                              │
/// └───────────────┴──────────────────────────────┘
/// ```
///
/// **Pourquoi une colonne et pas des onglets en barre.** Sept entrées, dont
/// deux à deux mots (« Autorisations », « Connexions ») : en barre segmentée
/// elles se tronquent ou forcent une feuille de 700 points de large pour une
/// rangée d'icônes. Surtout, la fenêtre principale range déjà ses écrans dans
/// une colonne latérale — l'utilisateur a demandé « comme la vue ». Deux
/// métaphores de navigation dans la même application, c'est une de trop.
/// `TabView` + `.sidebarAdaptable` donne la colonne sans réimplémenter la
/// sélection, la restauration et l'accessibilité d'un `NavigationSplitView`.
struct SettingsPane: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    /// L'onglet ouvert survit à la fermeture. Quelqu'un qui règle sa dictée
    /// rouvre les réglages trois fois de suite : le renvoyer sur « Général » à
    /// chaque fois lui fait refaire le trajet à chaque fois.
    @AppStorage("settings.selectedTab") private var selection: SettingsTab = .general

    var body: some View {
        // Pas de titre posé à la main : la feuille en a déjà un, et les deux se
        // superposaient. Le titre de l'onglet sélectionné suffit à situer.
        TabView(selection: $selection) {
            ForEach(SettingsTab.allCases) { tab in
                Tab(tab.title, systemImage: tab.symbol, value: tab) {
                    pane(for: tab)
                }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        // **Plus de taille figée.** Un plancher qui garantit qu'aucun contrôle
        // n'est coupé, une taille idéale confortable, et aucun plafond : la
        // feuille suit le contenu de l'onglet et reste redimensionnable au lieu
        // de forcer un défilement dans 620 points quoi qu'il arrive.
        //
        // Les quatre nombres restants sont des dimensions de fenêtre : `Design`
        // n'a pas d'échelle pour ça — ce n'est ni un espacement, ni un rayon —
        // et en inventer une pour un seul appel la rendrait fausse ailleurs.
        .frame(minWidth: 620, idealWidth: 720, minHeight: 460, idealHeight: 640)
    }

    @ViewBuilder
    private func pane(for tab: SettingsTab) -> some View {
        Form {
            switch tab {
            case .general:
                GeneralSettingsSection(model: model)
            case .meetings:
                MeetingSettingsSection(model: model)
            case .dictation:
                DictationSettingsSection(model: model)
            case .snapshot:
                SnapshotSettingsSection(model: model)
            case .clipboard:
                ClipboardSettingsSection(model: model)
            case .watch:
                WatchSettingsSection(model: model)
            case .connections:
                CRMSettingsSection(configuration: model.uploads.configuration, uploads: model.uploads)
            case .permissions:
                PermissionsSettingsSection(model: model)
            }
        }
        .formStyle(.grouped)
        // La sortie est ancrée au contenu, pas à la feuille entière : posée sous
        // le `TabView`, elle barrait aussi la colonne, ce qui donnait un bouton
        // « Terminé » flottant sous la liste des onglets.
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button("Terminé") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(Space.stack)
            .background(.bar)
        }
    }
}

/// Les sept écrans de réglages.
///
/// Le découpage suit les fonctions de l'application, pas la mécanique : un
/// utilisateur cherche « la dictée », jamais « les préférences du moteur de
/// reconnaissance ». Chaque cas correspond à une section existante, déplacée
/// telle quelle — aucune n'a été réécrite pour l'occasion.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case meetings
    case dictation
    case snapshot
    case clipboard
    case watch
    case connections
    case permissions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "Général"
        case .meetings: "Réunions"
        case .dictation: "Dictée"
        case .snapshot: "Capture"
        case .clipboard: "Presse-papiers"
        case .watch: "Veille"
        case .connections: "Connexions"
        case .permissions: "Autorisations"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .meetings: "film.stack"
        case .dictation: "waveform"
        case .snapshot: "text.viewfinder"
        case .clipboard: "doc.on.clipboard"
        case .watch: "binoculars"
        case .connections: "link"
        case .permissions: "lock.shield"
        }
    }
}

#Preview("Réglages") {
    SettingsPane(model: AppModel())
}
