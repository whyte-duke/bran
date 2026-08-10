import Foundation

/// La marque que bran pose sur les événements clavier qu'il fabrique lui-même,
/// pour que son propre guet les reconnaisse et les ignore.
///
/// ## Le défaut que ça ferme
///
/// bran synthétise un ⌘V pour coller la dictée, et il le poste **au niveau du
/// pilote** (`.cghidEventTap`) parce que c'est le seul endroit où toutes les
/// applications le voient. Son propre `CGEventTap` est un tap de session posé en
/// `.headInsertEventTap` — et un tap de session **voit les événements postés au
/// niveau pilote**. Mesuré : un événement posté sur `.cghidEventTap` ressort
/// intégralement dans le callback du tap de session, `flags` compris.
///
/// Aujourd'hui c'est sans conséquence pour une seule raison, et elle est
/// fortuite : personne n'a lié de fonction à la touche V, donc le filtre
/// `watchedKeys` écarte le faux ⌘V avant qu'il n'atteigne `classify`. Le jour où
/// quelqu'un règle un raccourci sur ⌘V — et rien ne l'en empêche,
/// `HotkeyBinding.forbiddenAlone` ne couvre que les touches **nues** —, bran
/// déclencherait sa propre fonction à chaque collage de dictée. Pire, le faux
/// événement porterait `maskCommand` **sans bit périphérique** dans `lastFlags`,
/// c'est-à-dire très exactement l'effacement de modificateur que
/// `TriggerTable.resyncedFlags` existe pour contenir — mais par un chemin que
/// cette garde-là ne couvre pas, puisqu'elle ne protège que la remise à l'heure.
///
/// ## Pourquoi une marque sur l'événement
///
/// `CGEvent` transporte un champ de 64 bits libre, `eventSourceUserData`, prévu
/// pour ça. Mesuré sur macOS 26.5 (Apple Silicon) avec une sonde jetable, en
/// posant la valeur sur l'événement puis en la relisant dans un tap de session :
///
/// - `0x6272_616E_0000_0001` posté sur `.cghidEventTap` ressort
///   `0x6272_616E_0000_0001`. **Les 64 bits survivent** : `0xFFFF_FFFF_FFFF_FFFF`
///   ressort tel quel, il n'y a pas de troncature à 32 bits ;
/// - le même événement posté sur `.cgSessionEventTap` ressort identique : le
///   niveau d'injection ne change rien à la marque ;
/// - un événement synthétique **non marqué** ressort à `0x0`, et les événements
///   qui ne viennent pas de nous aussi. La valeur au repos est donc zéro, ce qui
///   fait de « non nul et égal à la nôtre » un test sûr dans les deux sens.
///
/// ## Les trois autres façons de faire, et pourquoi non
///
/// - **filtrer sur le code de touche** (« ignorer V pendant un collage ») : c'est
///   refuser à l'utilisateur une touche parfaitement légitime, et ça ne
///   protégerait que le ⌘V — la première autre synthèse d'événement rouvrirait
///   le trou sans que rien ne le signale ;
/// - **se rendre sourd pendant N millisecondes après un collage** : ça avale les
///   vraies frappes de l'utilisateur pendant la fenêtre, et cette fenêtre n'est
///   pas bornée — l'écriture du presse-papiers peut attendre des secondes
///   derrière une lecture bloquée (`Paster`, point 8) ;
/// - **comparer le processus source**, `eventSourceUnixProcessID` : ça marche,
///   c'est mesuré — notre événement porte notre `pid`, les autres portent `0`.
///   Écarté quand même, parce que la question posée n'est pas « qui a émis ? »
///   mais « est-ce que c'est un événement que bran s'envoie à lui-même ? ». Le
///   jour où bran postera un événement pour le compte d'un geste de
///   l'utilisateur — une correction de texte, une macro —, le filtre par
///   processus l'avalerait aussi, en silence. La marque, elle, désigne une
///   intention, pas un émetteur ;
/// - **`eventSourceStateID`** : inutilisable. Mesuré à `1` sur notre événement
///   comme sur tous les autres.
///
/// ## Pourquoi cette valeur vit dans une bibliothèque
///
/// Les deux côtés — celui qui marque (`Paster`) et celui qui filtre
/// (`HotkeyMonitor`) — sont dans `BranApp`, qui n'a pas de cible de test. La
/// constante y serait vérifiée par personne, et c'est précisément le genre de
/// valeur dont la **stabilité** est le contrat : la changer d'un côté seulement,
/// ou la laisser tomber à zéro, rend bran sourd à ses propres événements sans
/// qu'aucune ligne ne casse.
public enum SyntheticEventTag {

    /// « bran » en ASCII, suivi d'un numéro de format.
    ///
    /// Le numéro n'est pas décoratif : le jour où la marque devra transporter
    /// autre chose que sa seule présence — quelle fonction a posté, par exemple
    /// —, les 32 bits de poids faible sont disponibles et le préfixe permet de
    /// reconnaître les deux formats. **Ne pas changer les 32 bits de poids
    /// fort** : ce sont eux qui font la signature.
    public static let value: Int64 = 0x6272_616E_0000_0001

    /// L'événement porte-t-il notre marque ?
    ///
    /// - Parameter userData: le champ `eventSourceUserData` lu sur l'événement.
    ///   `0` pour tout ce que bran n'a pas fabriqué — mesuré, voir plus haut.
    public static func isOurs(_ userData: Int64) -> Bool {
        userData == value
    }
}
