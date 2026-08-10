import Foundation

/// Le vocabulaire commun de l'historique du presse-papiers.
///
/// Ce fichier ne contient **que** des types partagés par plusieurs autres. Il
/// existe pour une raison précise : `ClipboardEntry`, `ClipboardMachine` et
/// `ClipboardCapture` sont écrits séparément, et sans un endroit qui tranche ce
/// qu'est une « sorte » de contenu, chacun en aurait inventé une version
/// légèrement différente. Ce qui est ici est décidé une fois.
///
/// **Toute propriété ajoutée à ces types après la première écriture sur disque
/// doit être `Optional`.** La synthèse `Codable` de Swift n'utilise pas les
/// valeurs par défaut : un champ non optionnel ajouté à un type déjà sérialisé
/// rend illisible chaque ligne déjà écrite, et les lecteurs de ce dépôt avalent
/// l'échec de décodage en silence par tolérance aux fichiers coupés. Un mois
/// d'historique disparaîtrait sans un seul message. `RecordingMetadata` et
/// `WatchEvent` documentent déjà ce piège ; c'est le troisième endroit où il
/// s'applique.

/// Ce qu'une entrée est, du point de vue de l'utilisateur qui la relit.
///
/// **Quatre sortes, pas quarante.** macOS déclare des centaines d'identifiants
/// de type sur un presse-papiers — mesurés sur un historique réel : 43 distincts
/// pour 250 entrées, dont `org.chromium.internal.source-rfh-token`, un jeton qui
/// n'a plus aucun sens dès que l'onglet source est fermé. Les stocker fidèlement
/// n'est pas de la fidélité, c'est du remplissage. Ce que la ligne du panneau a
/// besoin de savoir, c'est comment se dessiner ; ce que le collage a besoin de
/// savoir, c'est quoi remettre. Quatre réponses suffisent aux deux.
///
/// L'ordre des cas **est** l'ordre de priorité quand plusieurs formes coexistent
/// sur le même presse-papiers — et elles coexistent presque toujours : copier un
/// fichier depuis le Finder pose aussi son nom en texte, copier du web pose du
/// HTML *et* du texte brut. Le premier cas dont une forme est présente décide.
/// **Ne pas réordonner** ; un nouveau cas se place là où sa priorité l'exige, et
/// ce choix doit être argumenté dans le commit.
public enum ClipboardKind: String, Sendable, Codable, CaseIterable {

    /// Un ou plusieurs fichiers, copiés depuis le Finder ou une boîte de
    /// dialogue. Le contenu n'est **pas** repris : ce que le presse-papiers
    /// porte est une URL, et le fichier peut être déplacé ou supprimé ensuite.
    /// L'entrée devient alors morte, et le dit — même parti pris que la dictée
    /// dont l'audio a été purgé.
    case file

    /// Une image. La plus lourde des quatre : mesuré sur un historique réel,
    /// 183 lignes de PNG pesaient 158 Mo à elles seules. Toujours un blob,
    /// jamais en ligne.
    case image

    /// Du texte qui porte une mise en forme — RTF, HTML. Conservé **avec** sa
    /// version en texte brut, parce que « coller sans mise en forme » est le
    /// geste le plus demandé après « coller ».
    case richText

    /// Du texte brut. Le cas de loin le plus fréquent, et le seul qui tient
    /// souvent en ligne dans le journal plutôt qu'en fichier.
    case text
}

/// Où trouver le contenu d'une entrée trop lourde pour tenir dans le journal.
///
/// **Adressé par contenu.** Le nom du fichier est l'empreinte de ce qu'il
/// contient, ce qui rend la déduplication gratuite : deux copies identiques
/// écrivent le même fichier, et il n'y a pas de compteur de références à tenir
/// à jour. Savoir si un blob est encore vivant se réduit à demander si son
/// empreinte est encore citée par une entrée vivante — une soustraction
/// d'ensembles, pas un registre.
///
/// C'est exactement la classe de défaut qui a rendu la base de Maccy si grosse :
/// mesuré sur une installation réelle, 384 Mo de fichier pour 26 Mo de données
/// vivantes, parce que l'éviction supprimait la ligne parente sans jamais
/// toucher aux contenus. Ici, supprimer est un `rm`, et la requête qui vérifie
/// qu'il n'y a pas d'orphelin est celle qui a démasqué le problème.
public struct ClipboardBlobRef: Sendable, Codable, Equatable, Hashable {

    /// L'empreinte SHA-256 du contenu, en hexadécimal minuscule. Sert de nom de
    /// fichier.
    public let hash: String

    /// L'extension, sans le point — `png`, `txt`, `rtf`. Elle n'est pas
    /// décorative : elle permet à Quick Look d'ouvrir le fichier depuis le
    /// Finder, ce qui est la moitié de l'intérêt d'une bibliothèque qui est un
    /// simple dossier.
    public let ext: String

    /// La taille en octets, retenue pour pouvoir l'afficher sans toucher au
    /// disque, et pour dire ce qui a été perdu quand le blob a été purgé.
    public let bytes: Int

    public init(hash: String, ext: String, bytes: Int) {
        self.hash = hash
        self.ext = ext
        self.bytes = bytes
    }

    /// Le nom du fichier dans `blobs/`.
    public var fileName: String { ext.isEmpty ? hash : "\(hash).\(ext)" }
}

/// L'application d'où vient une entrée.
///
/// **Deux champs et non un.** Le nom lisible est ce qu'on affiche, mais il ne
/// survit pas à un changement de langue du système et ne permet pas de retrouver
/// l'icône. L'identifiant de paquet, lui, reste vrai et reste résolvable — y
/// compris pour une application désinstallée, où l'icône devient introuvable
/// alors que le nom stocké reste juste. Mesuré sur un historique réel :
/// deux applications sur quinze n'existaient plus.
public struct ClipboardSource: Sendable, Codable, Equatable, Hashable {

    /// `com.google.Chrome`. `nil` quand l'application au premier plan n'a pas pu
    /// être lue — ce qui arrive, et vaut mieux qu'une valeur inventée.
    public let bundleIdentifier: String?

    /// « Google Chrome ». Le nom stocké fait foi à l'affichage : il a été lu au
    /// moment de la copie, quand l'application existait encore.
    public let name: String?

    public init(bundleIdentifier: String?, name: String?) {
        self.bundleIdentifier = bundleIdentifier
        self.name = name
    }

    /// Vrai quand on ne sait rien de la source. L'interface doit alors se taire
    /// plutôt qu'écrire « Inconnu », qui occupe la même place en ne disant rien.
    public var isUnknown: Bool { bundleIdentifier == nil && name == nil }
}
