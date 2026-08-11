import BranSpeech
import Foundation
import Observation

/// L'objet de réglages qui détient la liaison d'un déclencheur global.
///
/// Les deux — `DictationSettings`, `SnapshotSettings` — exposaient déjà
/// `var trigger: HotkeyBinding` : la conformance ne coûte pas une ligne de
/// code, seulement la déclaration qu'ils jouent le même rôle. C'est ce qui
/// permet à la table de lire et d'écrire une liaison sans savoir de quelle
/// fonction il s'agit.
@MainActor
protocol GlobalTriggerSettings: AnyObject {
    var trigger: HotkeyBinding { get set }
}

extension DictationSettings: GlobalTriggerSettings {}
extension SnapshotSettings: GlobalTriggerSettings {}
extension ClipboardSettings: GlobalTriggerSettings {}

/// Le seul endroit où l'on déclare qu'une fonction a un raccourci global.
///
/// **Le défaut qu'il corrige.** La détection de conflits était écrite à la main,
/// une fois, dans l'écran de la capture de texte : « si la nouvelle touche
/// égale `dictationSettings.trigger`, refuser ». Trois conséquences, toutes
/// constatées :
///
/// - l'écran de la dictée, lui, ne vérifiait **rien** — on pouvait y poser ⌘⇧2
///   par-dessus la capture de texte sans un mot, et se retrouver avec deux
///   fonctions armées sur la même frappe ;
/// - une troisième fonction n'aurait été comparée à personne. Pas un
///   avertissement, pas une ligne de journal : le recouvrement silencieux ;
/// - le bouton « Échanger avec la dictée » nommait la dictée en dur, donc il
///   aurait menti dès qu'un autre déclencheur aurait tenu la touche.
///
/// **Ce que la table garantit.** `entry(for:in:)` est un `switch` exhaustif sur
/// `GlobalTrigger`. Ajouter un cas à l'énumération ne casse **que** ce fichier :
/// le compilateur exige la ligne ici, et rien d'autre dans l'interface ne bouge
/// — `GlobalTriggerRow` interroge la table et ne connaît aucune fonction par son
/// nom.
///
/// **Pour ajouter le presse-papiers**, le jour venu : un `case clipboard` dans
/// `GlobalTrigger` avec ses trois libellés, une ligne dans le `switch`
/// ci-dessous, un `case` dans le routage de `ShortcutRouter` — que le
/// compilateur réclamera aussi. L'écran de réglages, la détection de conflits
/// et l'échange suivront sans être touchés.
///
/// ## Ce que l'ajout a réellement coûté
///
/// La recette ci-dessus a été suivie, et sa deuxième moitié est vraie : la
/// détection de conflits, l'échange, `GlobalTriggerRow` et `TriggerTable` n'ont
/// pas bougé d'une ligne, et le compilateur a bien réclamé les deux `switch`
/// annoncés — ici et dans `ShortcutRouter`. Trois choses manquaient à
/// l'énoncé, toutes découvertes en le faisant :
///
/// - **le quatrième morceau, depuis retiré**. `Entry` exige un
///   `any GlobalTriggerSettings` ; une fonction sans écran n'avait pas d'objet
///   de réglages, donc rien à donner, et il a fallu un `StandaloneTriggerBinding`
///   de vingt lignes pour tenir la liaison en attendant. `ClipboardSettings` est
///   né avec son écran, a repris la clé `"bran.clipboard.trigger"` au caractère
///   près — sans quoi le raccourci déjà réglé aurait été perdu au lancement
///   suivant — et ce type a disparu comme annoncé. La recette valait bien pour
///   une fonction *déjà réglable*, pas pour une fonction nouvelle ;
/// - **la liaison par défaut**. Elle ne se déduit de rien et se choisit contre
///   le système d'exploitation — voir `HotkeyBinding.clipboardPanel`, où ⌘⇧C
///   est écarté parce que le Finder le tient. Elle vit dans `BranSpeech` avec
///   ses deux sœurs, et non ici : c'est une valeur, et une valeur posée dans une
///   cible exécutable n'est vérifiable par rien ;
/// - **`HotkeyBinding.displayName` ne savait pas nommer une lettre.** Sa table
///   de noms couvrait les modificateurs, les fonctions et les chiffres ; ⌘⇧V s'y
///   affichait « ⌘⇧Touche 9 ». Aucun raccourci par défaut n'était sur une lettre
///   jusqu'ici, donc le trou ne s'était jamais vu. Corrigé dans `BranSpeech` en
///   interrogeant la disposition clavier installée — un code de touche est une
///   position, pas une lettre, et le code 12 est « Q » en QWERTY et « A » en
///   AZERTY.
///
/// Et un piège qui n'est **pas** dans le registre mais qu'un quatrième
/// déclencheur retrouvera : rien n'inscrit une liaison dans
/// `HotkeyMonitor.bindings`. Chaque fonction le fait dans son propre
/// contrôleur, à la main. `apply` réarme, il n'enregistre pas.
///
/// **Pourquoi des méthodes statiques et pas un objet.** La table n'a pas d'état
/// à elle : tout ce qu'elle sait est déjà dans les réglages persistés. Un
/// singleton n'ajouterait qu'une deuxième copie à tenir à jour — et la
/// désynchronisation entre deux copies est exactement la classe de défaut qu'on
/// est en train de supprimer.
@MainActor
enum GlobalTriggerRegistry {

    /// Ce qu'il faut savoir d'un déclencheur pour l'afficher et le régler.
    ///
    /// **`@MainActor` explicitement**, alors que le registre qui la contient
    /// l'est déjà : en Swift 6 un type imbriqué n'hérite pas de l'isolation
    /// d'acteur global de son parent. Sans cette annotation, `binding` est
    /// `nonisolated` et ne peut pas lire `settings.trigger`, qui l'est.
    @MainActor
    struct Entry {
        let trigger: GlobalTrigger

        /// Où la liaison est réellement rangée — lecture **et** écriture, donc
        /// persistance : l'écriture passe par le `didSet` de l'objet de
        /// réglages.
        let settings: any GlobalTriggerSettings

        /// Ce qu'il faut relancer pour que le changement prenne effet à chaud.
        ///
        /// Chaque fonction réarme le tap à sa façon — la dictée par son
        /// contrôleur, la capture par `enableSnapshot`, qui sait en plus
        /// réclamer l'Accessibilité si elle manque. Une fermeture par ligne
        /// plutôt qu'un protocole commun : ce sont deux appels d'une ligne, et
        /// un protocole les rendrait plus difficiles à lire, pas moins.
        let apply: @MainActor () -> Void

        /// La liaison courante. Les noms d'affichage, eux, sont portés par
        /// `GlobalTrigger` — `label`, `definiteName`, `possessiveName` — parce
        /// qu'ils n'ont rien à voir avec l'application : ils décrivent la
        /// fonction, pas l'endroit où son réglage est rangé.
        var binding: HotkeyBinding { settings.trigger }
    }

    /// La table. Un `switch`, donc exhaustif, donc impossible à oublier.
    static func entry(for trigger: GlobalTrigger, in model: AppModel) -> Entry {
        switch trigger {
        case .dictation:
            Entry(
                trigger: .dictation,
                settings: model.dictationSettings,
                apply: { model.dictation.applySettings() }
            )
        case .snapshot:
            Entry(
                trigger: .snapshot,
                settings: model.snapshotSettings,
                apply: {
                    guard model.snapshotSettings.isEnabled else { return }
                    // L'activation échoue quand l'Accessibilité manque ;
                    // l'interrupteur est alors déjà retombé, et la fenêtre
                    // système explique pourquoi mieux qu'un libellé.
                    if model.enableSnapshot(true) == false { HotkeyMonitor.requestTrust() }
                }
            )
        case .clipboard:
            Entry(
                trigger: .clipboard,
                settings: model.clipboardSettings,
                // Le contrôleur est arrivé, et la fermeture vide avec lui :
                // c'est lui qui inscrit la liaison dans `HotkeyMonitor.bindings`,
                // parce que rien ne le fait tout seul — `apply` réarme, il
                // n'enregistre pas. Sans cet appel, changer le raccourci dans les
                // réglages l'écrirait bien sur le disque et ne changerait rien au
                // clavier jusqu'au lancement suivant.
                apply: { model.clipboard.applySettings() }
            )
        }
    }

    static func all(in model: AppModel) -> [Entry] {
        GlobalTrigger.allCases.map { entry(for: $0, in: model) }
    }

    // MARK: - Lecture

    static func binding(_ trigger: GlobalTrigger, in model: AppModel) -> HotkeyBinding {
        entry(for: trigger, in: model).binding
    }

    /// L'état persisté de tous les déclencheurs, fonctions désactivées
    /// comprises.
    ///
    /// **Et pas `HotkeyMonitor.bindings`**, qui ne contient que les fonctions
    /// actives. Autoriser un raccourci parce que son détenteur est éteint
    /// ferait ressurgir le conflit au rallumage, sans que personne n'ait rien
    /// changé entre-temps — un défaut qui n'apparaît que trois semaines plus
    /// tard, dans un état que l'utilisateur ne saura pas décrire.
    static func table(in model: AppModel) -> TriggerTable {
        var table = TriggerTable()
        for entry in all(in: model) { table[entry.trigger] = entry.binding }
        return table
    }

    /// La fonction qui tient déjà cette touche, s'il y en a une.
    static func holder(
        of binding: HotkeyBinding,
        excluding trigger: GlobalTrigger,
        in model: AppModel
    ) -> GlobalTrigger? {
        table(in: model).holder(of: binding, excluding: trigger)
    }

    // MARK: - Écriture

    /// Écrit la liaison et réarme la fonction. Ne vérifie rien : l'appelant a
    /// déjà interrogé `holder(of:excluding:in:)`.
    static func assign(_ binding: HotkeyBinding, to trigger: GlobalTrigger, in model: AppModel) {
        let entry = entry(for: trigger, in: model)
        // Réappliquer une liaison inchangée réinstallerait le tap pour rien —
        // et, côté capture, pourrait rouvrir la fenêtre d'Accessibilité.
        guard entry.binding != binding else { return }
        entry.settings.trigger = binding
        entry.apply()
    }

    /// Donne `binding` à `trigger` et rend à son détenteur la touche libérée.
    ///
    /// Le plan vient de `TriggerTable.exchanging` — la même logique que celle
    /// que les tests couvrent — et on n'écrit que ce qui change.
    static func exchange(_ trigger: GlobalTrigger, to binding: HotkeyBinding, in model: AppModel) {
        let plan = table(in: model).exchanging(trigger, to: binding)
        for target in GlobalTrigger.allCases {
            guard let wanted = plan[target] else { continue }
            assign(wanted, to: target, in: model)
        }
    }
}
