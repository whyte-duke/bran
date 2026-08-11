import BranCore
import BranSpeech
import Foundation
import Observation

/// Les réglages de l'historique du presse-papiers, persistés dans
/// `UserDefaults`.
///
/// Rien de secret ici non plus : pas de jeton, pas de clé. Le trousseau serait
/// du zèle. Ce qui est sensible, ce sont les *contenus* copiés — et ils ne sont
/// pas dans les réglages, ils sont dans la bibliothèque, dont l'emplacement se
/// choisit dans « Général ».
///
/// **Ce fichier est celui que `GlobalTriggerRegistry` annonçait.** La fonction
/// est arrivée dans l'ordre inverse de ses aînées — le raccourci d'abord,
/// l'écran ensuite — et sa liaison a donc vécu quelque temps dans un
/// `StandaloneTriggerBinding` posé à côté de la table des déclencheurs. Cet
/// objet-ci le remplace, et il **reprend sa clé au caractère près** :
/// `"bran.clipboard.trigger"`. Ce n'est pas de l'élégance, c'est la seule chose
/// qui empêche le raccourci déjà réglé par l'utilisateur de disparaître au
/// prochain lancement — un `UserDefaults` ne migre rien tout seul, une clé
/// renommée est une valeur perdue en silence.
///
/// **Trois réglages seulement, et chacun ferme un trou constaté.** La rétention
/// des contenus lourds, parce que ce sont eux qui pèsent — 158 Mo de PNG pour
/// 250 entrées sur l'installation du propriétaire, soit plus de 99 % du volume
/// pour moins de 10 % des lignes. Le respect des marqueurs de confidentialité,
/// parce que la convention `org.nspasteboard.*` est le seul signal qu'Apple nous
/// laisse et qu'il est parfois faux. Et l'interrupteur de capture, parce que
/// « zéro jour » de rétention veut dire « effacé à minuit », **pas** « jamais
/// écrit », et qu'il n'existait aucun moyen de dire le second.
@MainActor
@Observable
final class ClipboardSettings {

    private enum Key {
        /// **Héritée telle quelle de `StandaloneTriggerBinding`.** Voir le
        /// commentaire de classe : la renommer effacerait le raccourci de tous
        /// ceux qui l'ont déjà changé.
        static let trigger = "bran.clipboard.trigger"
        static let capturesCopies = "bran.clipboard.capturesCopies"
        static let blobDays = "bran.clipboard.blobDays"
        static let honoursPrivacyMarkers = "bran.clipboard.honoursPrivacyMarkers"
    }

    /// Le raccourci qui ouvre le panneau d'historique.
    ///
    /// C'est cette propriété — et elle seule — qui fait de cet objet un
    /// `GlobalTriggerSettings`. La conformance est déclarée dans
    /// `GlobalTriggerRegistry`, avec celles de ses deux aînés, pour que la liste
    /// des fonctions réglables se lise en un seul endroit.
    var trigger: HotkeyBinding { didSet { store(trigger, forKey: Key.trigger) } }

    /// Écrire, ou ne rien écrire du tout.
    ///
    /// **Ce n'est pas `isEnabled`, et la nuance est tout le sujet.** Éteindre la
    /// capture ne doit ni fermer le panneau, ni délier le raccourci, ni
    /// supprimer une seule ligne de ce qui est déjà rangé : ce qu'on demande en
    /// baissant cet interrupteur, c'est « n'écris plus », jamais « oublie ce que
    /// tu sais ». Un réglage nommé `isEnabled` aurait fatalement fini par
    /// désarmer la fonction entière — et rendre l'historique déjà écrit
    /// inaccessible depuis le seul geste qui l'ouvre serait une perte de données
    /// du point de vue de l'utilisateur, même si le disque, lui, garde tout.
    ///
    /// **Pourquoi ce réglage manquait, et pourquoi zéro jour ne le remplaçait
    /// pas.** `ClipboardRetention.dayFoldersToPurge` ne touche jamais le dossier
    /// du jour en cours — c'est une décision de mécanique, pas de politique :
    /// c'est le dossier dans lequel la capture écrit à cet instant, et supprimer
    /// sous les pieds de l'écrivain est une course, pas une purge. « 0 jour »
    /// signifie donc « effacé à minuit », ce qui laisse une journée entière de
    /// contenus sur le disque. Pour qui prépare une démonstration, partage son
    /// écran ou travaille une heure sur des secrets, c'est exactement une
    /// journée de trop.
    ///
    /// Vrai par défaut : un historique qu'il faut d'abord penser à allumer est
    /// un historique vide le jour où l'on en a besoin — et ce jour-là est
    /// toujours rétrospectif.
    var capturesCopies: Bool { didSet { defaults.set(capturesCopies, forKey: Key.capturesCopies) } }

    /// Combien de jours les contenus lourds — images, fichiers, textes enrichis
    /// — restent sur le disque.
    ///
    /// **Le texte n'est pas concerné, et ce n'est pas un oubli : c'est le
    /// contrat.** `ClipboardRetention` ne purge que les blobs, jamais les
    /// entrées ni leur texte, et toute la fonctionnalité repose là-dessus :
    /// mesuré sur l'installation du propriétaire, l'historique de Maccy ne
    /// remontait pas au-delà de 4,7 jours. Un outil qui oublie au bout d'une
    /// semaine ne remplace pas la mémoire, il la simule. Le prix de ne rien
    /// oublier est connu — ~53 entrées par jour, quelques centaines d'octets
    /// chacune, quelques mégaoctets par an — et il n'y a rien à arbitrer à ce
    /// prix-là.
    ///
    /// Nommé `blobDays` comme dans `ClipboardRetention`, et pour la même raison
    /// qu'elle donne : un futur lecteur des réglages ne doit pas pouvoir croire
    /// une seconde que ce nombre gouverne l'historique entier. L'écran, lui, a
    /// une phrase entière pour le dire — voir `ClipboardRetention.textLabel`.
    var blobDays: Int { didSet { defaults.set(blobDays, forKey: Key.blobDays) } }

    /// Rejeter ce qu'une application marque comme confidentiel.
    ///
    /// **Vrai par défaut, et cette valeur a été discutée.** Le propriétaire a
    /// tranché que masquer les mots de passe *à l'affichage* ne l'intéressait
    /// pas — un historique qui met des points à la place de ce qu'on cherche ne
    /// sert à rien. Ne pas **écrire** ce que macOS efface lui-même au bout d'une
    /// minute et demie est une autre question, et elle se décide dans l'autre
    /// sens : le contenu marqué est celui dont l'application source déclare
    /// qu'il ne doit pas survivre, et le graver dans un fichier qui, lui, dure
    /// pour toujours va contre la seule intention explicite qu'on ait.
    ///
    /// **Mais c'est une convention, pas une garantie**, et c'est pourquoi
    /// l'interrupteur existe. `org.nspasteboard.ConcealedType` et ses deux
    /// voisins sont posés par 1Password, Bitwarden, KeePassXC et iTerm ; rien
    /// n'oblige une application à les poser, et rien ne l'empêche d'en abuser.
    /// Le jour où un outil marque tout ce qu'il copie, l'historique se met à
    /// perdre des entrées parfaitement ordinaires sans que rien ne le dise — et
    /// ce jour-là, le seul remède est de pouvoir désactiver le respect du
    /// marqueur.
    ///
    /// Éteindre ce réglage ne fait **pas** entrer les marqueurs dans les données
    /// rangées : `ClipboardTypePolicy` les écarte du plan de lecture dans les
    /// deux cas. Seule la mise au rebut de l'entrée entière disparaît.
    var honoursPrivacyMarkers: Bool {
        didSet { defaults.set(honoursPrivacyMarkers, forKey: Key.honoursPrivacyMarkers) }
    }

    private let defaults = UserDefaults.standard

    init() {
        trigger = Self.read(HotkeyBinding.self, forKey: Key.trigger) ?? .clipboardPanel

        // **`object(forKey:) as? Bool ?? true` et jamais `bool(forKey:)`.** Le
        // second rend `false` pour une clé absente : il transformerait ces deux
        // défauts « activé » en « désactivé » au tout premier lancement, sans
        // qu'aucun utilisateur n'ait rien décidé, et l'interrupteur afficherait
        // fidèlement un choix que personne n'a fait. Même précaution pour
        // `blobDays`, où `integer(forKey:)` rendrait 0 — c'est-à-dire « aucun
        // contenu lourd conservé », le contraire du défaut voulu.
        capturesCopies = defaults.object(forKey: Key.capturesCopies) as? Bool ?? true
        blobDays = defaults.object(forKey: Key.blobDays) as? Int
            ?? ClipboardRetention.default.blobDays
        honoursPrivacyMarkers = defaults.object(forKey: Key.honoursPrivacyMarkers) as? Bool ?? true
    }

    // MARK: - Ce que les autres attendent

    /// La politique de rangement, telle que `ClipboardStore` la veut.
    ///
    /// Construite à la demande plutôt que stockée : `ClipboardRetention` est une
    /// valeur, et deux copies d'une même valeur — celle des réglages et celle du
    /// magasin — sont deux choses qui peuvent diverger. Ici il n'y en a qu'une
    /// seule vérité, `blobDays`, et tout le reste en découle. Même forme que
    /// `SnapshotSettings.retention` et `WatchSettings.retention`.
    var retention: ClipboardRetention { .days(blobDays) }

    /// La matrice des types, telle que `ClipboardMachine` la veut.
    ///
    /// Même raisonnement que `retention` : la politique se recalcule, elle ne se
    /// range pas. Elle ne porte aujourd'hui qu'un seul réglage exposé ; les
    /// autres décisions de la matrice — ce qu'on garde, ce qu'on jette, les
    /// promesses de fichier — sont des faits sur les formats du presse-papiers,
    /// pas des goûts, et n'ont rien à faire dans un écran de réglages.
    var typePolicy: ClipboardTypePolicy {
        ClipboardTypePolicy(honoursPrivacyMarkers: honoursPrivacyMarkers)
    }

    // MARK: -

    private func store<T: Encodable>(_ value: T, forKey key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    private static func read<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
