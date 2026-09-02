import Foundation

/// **Par où les octets sont passés**, attaché au relevé plutôt qu'affiché à côté.
///
/// ```
///   ↓ 14,2 Mo/s   Wi-Fi        11 h 04
///   ↓ 30,1 Mo/s   Ethernet     11 h 52   ← ce n'est pas la ligne qui a doublé
/// ```
///
/// **Pourquoi ce champ existe.** La ligne du poste a été mesurée à 14 Mo/s puis
/// à 30 Mo/s dans la même heure, sans que rien change de visible — c'est le fait
/// qui a fait garder un relevé précédent, et le seul auquel `SpeedController`
/// n'avait toujours pas de réponse. Deux chiffres côte à côte disent qu'un débit
/// est une météo ; ils ne disent pas **pourquoi** il a changé, et la réponse la
/// plus fréquente est la plus bête : on a branché le câble, ou on s'est éloigné
/// de la borne.
///
/// Un relevé qui ne porte pas son lien fait donc accuser l'abonnement pour un
/// écart qui vient du salon. C'est exactement le mauvais coupable — le même
/// genre d'erreur que `SpeedMiss` ferme du côté du serveur de mesure.
///
/// **Ce n'est pas mesuré, c'est demandé au système.** `NWPath` répond en
/// quelques millisecondes, sans autorisation et sans trafic ; voir
/// `SpeedLinkProbe`, qui vit dans `BranApp` parce que `BranCore` ne connaît
/// aucun framework système. Ici, il n'y a que le vocabulaire.
public enum SpeedLink: String, Codable, Sendable, Equatable {

    case wifi
    case wired
    case cellular

    /// Tout le reste : un tunnel VPN, un pont, une interface que le système
    /// n'annonce pas. Nommé « autre » plutôt que deviné — prétendre reconnaître
    /// une liaison qu'on ne reconnaît pas coûterait plus cher que se taire.
    case other

    public var title: String {
        switch self {
        case .wifi: "Wi-Fi"
        case .wired: "Ethernet"
        case .cellular: "Cellulaire"
        case .other: "Autre liaison"
        }
    }

    public var symbol: String {
        switch self {
        case .wifi: "wifi"
        case .wired: "cable.connector"
        case .cellular: "antenna.radiowaves.left.and.right"
        case .other: "network"
        }
    }

    /// Ce qui s'écrit quand macOS annonce une liaison **facturée au volume** —
    /// un partage de connexion, typiquement.
    ///
    /// C'est la contrepartie de `SpeedReading.spentBytes`, et elle arrive au bon
    /// moment : le nombre d'octets dépensés se lit après coup, cet avertissement
    /// se lit **avant** de recliquer. Un test coûte plus de cent mégaoctets ;
    /// quelqu'un qui partage la connexion de son téléphone a le droit de
    /// l'apprendre autrement qu'en relevant sa facture.
    public static let expensiveWarning =
        "Liaison facturée au volume — un test coûte plus de cent mégaoctets."
}
