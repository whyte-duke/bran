import Foundation

/// Une fonction que l'on déclenche par un raccourci global.
///
/// **Pourquoi cette énumération vit ici et pas dans `HotkeyMonitor`.** Elle y a
/// vécu, et c'est ce qui a produit le défaut qu'on corrige : la seule liste des
/// déclencheurs était enfermée dans une cible exécutable, `@MainActor`, adossée
/// à un `CGEventTap`. Rien de tout ça n'est testable, donc rien ne vérifiait la
/// détection de conflits — et l'interface s'en est passée, en comparant à la
/// main la capture de texte à la dictée. Ajouter une troisième fonction aurait
/// laissé deux raccourcis se recouvrir **sans un mot**.
///
/// Ici, dans une bibliothèque, la table et son arbitrage se testent en
/// millisecondes et sans autorisation. `HotkeyMonitor.Action` en est désormais
/// un simple alias.
///
/// **L'ordre de `allCases` fixe la priorité** quand deux fonctions partagent la
/// même touche. L'interface empêche ce cas — c'est tout l'objet de
/// `TriggerTable.conflicts(for:excluding:)` — mais un fichier de réglages écrit
/// à la main, ou une installation antérieure à cette vérification, peut encore
/// le produire. `HotkeyMonitor.classify` parcourt `allCases` dans l'ordre et
/// s'arrête au premier trouvé : deux fonctions sur la même touche ne se
/// déclenchent donc pas dans un ordre qui change d'un lancement à l'autre.
/// **Ne pas réordonner les cas existants** ; un nouveau se met à la fin.
public enum GlobalTrigger: String, CaseIterable, Sendable, Codable {
    case dictation
    case snapshot

    /// Le panneau d'historique du presse-papiers.
    ///
    /// **En dernier, et c'est la règle qui décide.** L'ordre de `allCases` est
    /// l'ordre de l'arbitrage, et la doctrine de `ShortcutRouter` est qu'une
    /// fonction occupée l'emporte : ouvrir le panneau pendant une dictée ne doit
    /// rien faire. Placer le presse-papiers en tête ne l'aurait pas rendu
    /// prioritaire au sens où l'on croit — l'arbitrage « qui est occupé »
    /// n'utilise pas cet ordre-là —, mais aurait changé qui gagne quand deux
    /// fonctions partagent une touche, c'est-à-dire un état que seul un fichier
    /// de réglages écrit à la main produit. Rien à y gagner, une règle stable à
    /// y perdre.
    case clipboard

    /// Le nom seul, pour un titre ou une colonne. « Dictée ».
    public var label: String {
        switch self {
        case .dictation: "Dictée"
        case .snapshot: "Capture de texte"
        case .clipboard: "Presse-papiers"
        }
    }

    /// Le nom avec son article défini, pour l'insérer dans une phrase :
    /// « Échanger avec **la dictée** ».
    public var definiteName: String {
        switch self {
        case .dictation: "la dictée"
        case .snapshot: "la capture de texte"
        case .clipboard: "le presse-papiers"
        }
    }

    /// Le nom au complément du nom : « le raccourci **de la dictée** ».
    ///
    /// Écrit et non dérivé de `definiteName` : la contraction « de le » → « du »
    /// ne se déduit pas d'une chaîne sans faire de la grammaire, et le jour où
    /// un déclencheur masculin arriverait — « du presse-papiers » — la forme
    /// dérivée serait fausse. Trois chaînes par cas, une seule fois.
    ///
    /// **Ce jour est arrivé, et la prévision était juste** : `clipboard` rend
    /// « du presse-papiers » quand la dérivation aurait écrit « de le
    /// presse-papiers ». La phrase de `GlobalTriggerRow` — « est déjà le
    /// raccourci du presse-papiers » — se lit donc sans retouche, et c'est la
    /// seule chose que cette prévision avait à garantir.
    public var possessiveName: String {
        switch self {
        case .dictation: "de la dictée"
        case .snapshot: "de la capture de texte"
        case .clipboard: "du presse-papiers"
        }
    }
}

/// Le geste « je viens de copier », qui n'est pas un déclencheur.
///
/// **Pourquoi ce n'est pas un `GlobalTrigger`, et pourquoi la distinction est
/// tout le sujet.** ⌘⇧C ouvre le panneau : c'est une fonction, elle se règle,
/// elle s'arbitre, une dictée en cours la fait taire. ⌘C, lui, n'est *pas* une
/// fonction de bran — c'est une frappe adressée à l'application de devant, qu'on
/// se contente d'observer pour savoir qu'il faudra relever le presse-papiers.
///
/// Le faire passer par `Signal.triggerDown` l'aurait soumis à l'arbitrage, et
/// l'arbitrage l'aurait perdu : copier pendant une dictée est très exactement le
/// cas où l'on veut que la copie soit gardée — c'est ce qu'on collera après.
/// Une fonction occupée fait taire *les autres fonctions*, pas l'observation du
/// clavier.
///
/// La logique vit ici, dans la bibliothèque, pour la même raison que le reste de
/// ce fichier : enfermée dans le callback du tap, elle n'aurait été testable par
/// rien.
public enum CopyGesture {

    /// Les codes des touches à observer : C et X.
    ///
    /// X et pas seulement C : couper *est* une copie du point de vue du
    /// presse-papiers, et l'oublier perdrait une entrée sur deux dans un
    /// éditeur de texte.
    ///
    /// Pas ⌘⇧C ni ⌘V : coller ne change pas le presse-papiers. Pas non plus les
    /// copies faites au menu ou à la souris — elles existent, elles ne
    /// produisent aucune frappe, et c'est le sondeur du presse-papiers qui les
    /// rattrape. L'indice clavier est l'accélérateur, pas la seule source.
    public static let keyCodes: Set<UInt16> = [
        8,  // C
        7,  // X
    ]

    /// Le bit de Commande dans un masque `CGEventFlags`.
    private static let command: UInt64 = 0x10_0000

    /// Cette frappe ressemble-t-elle à une copie ?
    ///
    /// **Le test est « contient Commande », pas « égale Commande ».** ⌘⌥C copie
    /// le chemin dans le Finder, ⌘⇧C copie le nom du fichier, ⌘⌥⇧C existe aussi,
    /// et une application quelconque est libre d'en inventer une autre. Toutes
    /// écrivent dans le presse-papiers. Exiger l'égalité stricte — ce que fait
    /// `HotkeyMonitor.matches` pour un raccourci, à raison, parce qu'un
    /// raccourci doit être exact — laisserait passer ces copies-là sans indice,
    /// et l'entrée n'arriverait qu'au sondage suivant, ou pas du tout.
    ///
    /// Le faux positif que ça autorise est sans conséquence : un ⌘⌥C qui ne
    /// copie rien produit un indice, la machine relève un compteur qui n'a pas
    /// bougé et conclut « rien n'a été copié ». Le faux négatif, lui, perd une
    /// copie pour de bon.
    ///
    /// - Parameters:
    ///   - keyCode: le code de la touche frappée.
    ///   - flags: le masque brut de `CGEventFlags`.
    public static func matches(keyCode: UInt16, flags: UInt64) -> Bool {
        keyCodes.contains(keyCode) && flags & command != 0
    }
}

/// Qui tient quelle touche.
///
/// Une valeur, pas un service : elle ne connaît ni les réglages persistés ni le
/// `CGEventTap`. Elle répond à une seule question — *ce raccourci est-il déjà
/// pris, et par qui ?* — et sait proposer l'échange qui en découle.
///
/// Deux appelants s'en servent, et c'est le but :
///
/// - `HotkeyMonitor` la tient à jour avec les fonctions **effectivement
///   surveillées**, pour router les frappes ;
/// - `GlobalTriggerRegistry`, côté application, la reconstruit à partir des
///   **réglages persistés**, pour l'interface.
///
/// Les deux ne coïncident pas toujours, et c'est voulu : une fonction
/// désactivée n'est pas surveillée mais son raccourci reste écrit sur le
/// disque. L'interface doit refuser un conflit avec elle, sinon réactiver la
/// fonction plus tard ferait ressurgir le recouvrement sans que personne n'ait
/// rien changé entre-temps.
public struct TriggerTable: Equatable, Sendable {

    private var bindings: [GlobalTrigger: HotkeyBinding]

    public init(_ bindings: [GlobalTrigger: HotkeyBinding] = [:]) {
        self.bindings = bindings
    }

    /// La touche d'une fonction, ou `nil` si elle n'en a pas. Affecter `nil`
    /// retire la ligne.
    public subscript(trigger: GlobalTrigger) -> HotkeyBinding? {
        get { bindings[trigger] }
        set { bindings[trigger] = newValue }
    }

    public var isEmpty: Bool { bindings.isEmpty }

    /// Les codes de touche à surveiller. `HotkeyMonitor` s'en sert pour écarter
    /// en une comparaison les quatre-vingts frappes par minute qui ne le
    /// concernent pas.
    public var keyCodes: Set<UInt16> { Set(bindings.values.map(\.keyCode)) }

    /// Une fonction revendique-t-elle cette touche ? Sert à l'annulation : régler
    /// une fonction sur Échap doit désarmer Échap comme geste d'abandon, sinon
    /// les deux deviennent indiscernables.
    public func isTaken(_ binding: HotkeyBinding) -> Bool {
        bindings.values.contains(binding)
    }

    /// Une fonction et la touche qui la déclenche.
    public typealias Assignment = (trigger: GlobalTrigger, binding: HotkeyBinding)

    /// Les fonctions inscrites, dans l'ordre de priorité de `allCases`.
    ///
    /// Un dictionnaire n'a pas d'ordre : itérer dessus donnerait un arbitrage
    /// différent d'un lancement à l'autre, exactement le défaut que l'ordre des
    /// cas existe pour empêcher.
    public var assigned: [Assignment] {
        GlobalTrigger.allCases.compactMap { (trigger: GlobalTrigger) -> Assignment? in
            guard let binding = bindings[trigger] else { return nil }
            return (trigger: trigger, binding: binding)
        }
    }

    // MARK: - Conflits

    /// Les fonctions — autres qu'`trigger` — qui tiennent déjà cette touche.
    ///
    /// C'est **la** question que pose l'interface avant d'enregistrer un
    /// réglage. Elle ne demande pas « est-ce que la dictée l'a ? » : elle
    /// demande à la table, qui répond pour toutes les fonctions, y compris
    /// celles qui n'existaient pas quand cet écran a été écrit.
    public func conflicts(for binding: HotkeyBinding, excluding trigger: GlobalTrigger) -> [GlobalTrigger] {
        assigned.filter { $0.trigger != trigger && $0.binding == binding }.map(\.trigger)
    }

    /// La première fonction qui tient cette touche, dans l'ordre de priorité.
    ///
    /// L'interface n'a de place que pour un nom et un bouton d'échange. Quand
    /// plusieurs fonctions se recouvrent — un état que seule une modification
    /// manuelle des réglages peut produire — on nomme celle qui gagnerait
    /// l'arbitrage, parce que c'est celle dont l'utilisateur constate l'effet.
    public func holder(of binding: HotkeyBinding, excluding trigger: GlobalTrigger) -> GlobalTrigger? {
        conflicts(for: binding, excluding: trigger).first
    }

    // MARK: - Ce qu'un changement de table libère

    /// Parmi les fonctions `held` — celles dont la touche est physiquement
    /// enfoncée —, celles dont la touche n'est plus celle qu'elles avaient dans
    /// `previous`.
    ///
    /// **Le défaut que ça existe pour empêcher.** Le guet ne voit un
    /// relâchement que sur une touche qu'il surveille encore. Reliez la dictée à
    /// une autre touche pendant que l'ancienne est tenue, et le `keyUp` de
    /// l'ancienne est écarté avant même d'être classé : le relâchement n'arrive
    /// jamais, et une dictée en mode « maintenir » reste en capture jusqu'à ce
    /// qu'autre chose l'interrompe. Changer de touche est donc, pour qui la
    /// tenait, l'équivalent d'un relâchement — et c'est à l'appelant de le lui
    /// dire.
    ///
    /// Trois choix, tous délibérés :
    ///
    /// - **la disparition n'est qu'un cas particulier.** Ne traiter que le
    ///   passage à `nil` — ce que faisait `HotkeyMonitor.bind` — laisse passer
    ///   le vrai cas d'usage, qui est de *changer* de raccourci ;
    /// - **on compare la liaison entière, pas le seul code de touche.** Quand
    ///   seuls les modificateurs changent (⌘⇧2 → ⌃⇧2), le `keyUp` arriverait
    ///   encore et le relâchement serait vu : la fonction est quand même
    ///   déclarée libérée. Un relâchement en avance de quelques millisecondes
    ///   ne coûte rien — l'appelant retire la fonction de `held`, donc le
    ///   `keyUp` qui suit ne redouble pas —, alors qu'une capture qui ne
    ///   s'arrête plus coûte une dictée entière ;
    /// - **l'ordre est celui de `allCases`**, comme partout ailleurs ici : deux
    ///   fonctions libérées d'un coup doivent l'être dans un ordre qui ne change
    ///   pas d'un lancement à l'autre.
    ///
    /// Une fonction que le changement ne concerne pas — tenue, mais dont la
    /// touche est intacte — n'apparaît pas : rebrancher la capture de texte
    /// pendant qu'on dicte ne doit pas couper la dictée.
    public func triggersLosingTheirKey(
        since previous: TriggerTable,
        among held: Set<GlobalTrigger>
    ) -> [GlobalTrigger] {
        GlobalTrigger.allCases.filter { held.contains($0) && self[$0] != previous[$0] }
    }

    // MARK: - Remise à l'heure du masque de modificateurs

    /// Le masque de modificateurs à retenir, à partir de celui que le système
    /// rapporte, **sans jamais déclarer relâchée une fonction qu'on tient**.
    ///
    /// L'appelant — `HotkeyMonitor.resyncFlags` — lit l'état réel du clavier
    /// pour ne plus déduire ce qu'il peut constater. Cette fonction-ci décide de
    /// ce qu'il faut en garder, et c'est le seul morceau de l'affaire qui ne
    /// soit pas un appel système : d'où sa place ici, où il se teste.
    ///
    /// **Le défaut qu'elle empêche, et il est mesuré.** bran synthétise lui-même
    /// un ⌘V pour coller sa dictée, au niveau du pilote. Pendant les quelques
    /// centaines de millisecondes qui suivent — jusqu'au prochain événement,
    /// quel qu'il soit —, l'état rapporté par le système est le masque de ce
    /// faux événement : `maskCommand` **et aucun bit gauche/droite**. Le bit de
    /// ⌘ droite disparaît donc de l'état alors que le doigt, lui, n'a pas bougé.
    /// Reprendre cet état tel quel pendant une dictée en mode « maintenir »
    /// noterait ⌘ droite comme relâchée ; le vrai relâchement, ensuite, ne
    /// changerait plus rien — `isDown == wasDown` — et la capture ne
    /// s'arrêterait jamais. C'est exactement le relâchement perdu que la remise
    /// à l'heure existe pour corriger, réintroduit par l'autre bout.
    ///
    /// La règle tient en une phrase : **le système peut ajouter un appui, il ne
    /// peut pas retirer celui qu'on tient déjà.** Ajouter est sûr — c'est le cas
    /// du modificateur tenu pendant qu'on règle ses raccourcis, et le pire qu'il
    /// produise est un `.triggerUp` au relâchement suivant. Retirer ne l'est
    /// pas : ça perd un relâchement pour de bon.
    ///
    /// Seules les fonctions à **modificateur seul** sont concernées : ce sont
    /// les seules dont `HotkeyMonitor` déduit l'état par comparaison de masques.
    /// Une touche normale arrive avec son `keyUp`, qui ne se perd pas.
    ///
    /// - Parameters:
    ///   - systemFlags: le masque brut rendu par le système.
    ///   - held: les fonctions que l'appelant tient pour enfoncées.
    /// - Returns: `systemFlags`, augmenté des bits « périphérique » des
    ///   fonctions tenues.
    public func resyncedFlags(from systemFlags: UInt64, held: Set<GlobalTrigger>) -> UInt64 {
        var flags = systemFlags
        for (trigger, binding) in assigned where held.contains(trigger) {
            guard binding.isModifierOnly else { continue }
            flags |= binding.deviceModifierBit
        }
        return flags
    }

    // MARK: - Échange

    /// La table telle qu'elle serait après avoir donné `binding` à `trigger`,
    /// en rendant à son détenteur précédent la touche que `trigger` libère.
    ///
    /// **Pourquoi l'échange et pas le refus sec.** Vouloir ⌘⇧2 pour la capture
    /// alors que la dictée l'occupe veut dire qu'on préfère l'autre touche pour
    /// la dictée — pas qu'on renonce. Le refus sec oblige à aller décrocher le
    /// raccourci dans l'autre écran, puis à revenir.
    ///
    /// Si `trigger` n'avait pas de touche, l'ancien détenteur n'en reçoit
    /// aucune : lui laisser la sienne recréerait le conflit qu'on vient de
    /// résoudre.
    public func exchanging(_ trigger: GlobalTrigger, to binding: HotkeyBinding) -> TriggerTable {
        var next = self
        let released = bindings[trigger]
        for holder in conflicts(for: binding, excluding: trigger) {
            next[holder] = released
        }
        next[trigger] = binding
        return next
    }
}
