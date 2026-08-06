import AppKit
import Foundation

/// Est-ce que bran a une icône dans le Dock.
///
/// **Pourquoi ce réglage existe.** `Info.plist` déclarait `LSUIElement` à
/// `true` — un agent de barre de menus, sans Dock — pendant que `BranApp.swift`
/// posait `.defaultLaunchBehavior(.presented)` sur la fenêtre principale. Les
/// deux ensemble donnaient l'état le plus inconfortable possible : une vraie
/// fenêtre, ouverte au lancement, appartenant à une application qui n'existe
/// nulle part. Un ⌘W et le seul chemin de retour était un élément de barre de
/// menus que rien n'annonce.
///
/// Le défaut s'inverse donc : bran est une application normale, et celui qui
/// préfère l'agent de barre de menus le décoche. Un défaut qu'un clic corrige
/// vaut mieux qu'un défaut sans interface.
///
/// ```
///   Info.plist LSUIElement = false     ← macOS lance en .regular
///            │
///            ▼
///   DockPresence.apply()               ← au démarrage, puis à chaque
///            │                            changement du réglage
///     ┌──────┴───────┐
///     ▼              ▼
///  .regular      .accessory
///  icône Dock    barre de menus seule
///  ⌘Tab          ni Dock, ni ⌘Tab
/// ```
@MainActor
enum DockPresence {

    private static let key = "bran.showsDockIcon"

    /// Le défaut est `true` : c'est ce que `LSUIElement = false` promet, et un
    /// réglage qui contredirait le `Info.plist` au premier lancement ferait
    /// clignoter l'icône une fois pour rien.
    static var isEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: key) as? Bool ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: key)
            apply()
        }
    }

    /// Pose la politique d'activation qui correspond au réglage.
    ///
    /// **Trois précautions, toutes payées par des comportements observés de
    /// macOS.**
    ///
    /// 1. On ne repose pas une politique déjà en place. `setActivationPolicy`
    ///    n'est pas neutre quand elle ne change rien : elle peut réordonner les
    ///    fenêtres et faire perdre le focus à celle du premier plan.
    /// 2. Passer de `.accessory` à `.regular` ne suffit pas à rendre
    ///    l'application activable — il faut l'activer explicitement, sinon
    ///    l'icône apparaît dans le Dock mais la fenêtre reste derrière tout le
    ///    reste et le menu de l'application ne se pose pas.
    /// 3. Rien de tout ça n'est fait hors du fil principal : la politique
    ///    d'activation touche au serveur de fenêtres.
    static func apply() {
        let wanted: NSApplication.ActivationPolicy = isEnabled ? .regular : .accessory
        let application = NSApplication.shared

        guard application.activationPolicy() != wanted else { return }
        application.setActivationPolicy(wanted)

        if wanted == .regular {
            application.activate()
        }
    }

    /// Ce que les réglages affichent sous l'interrupteur.
    ///
    /// Il dit la conséquence, pas le mécanisme : personne n'a besoin de savoir
    /// ce qu'est une politique d'activation, tout le monde a besoin de savoir
    /// par où revenir dans l'application.
    static let explanation = """
        Sans icône dans le Dock, bran reste accessible par son élément de barre \
        de menus — et par lui seul. L'application disparaît aussi de ⌘Tab.
        """
}
