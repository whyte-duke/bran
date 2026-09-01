import BranCore
import SwiftUI

/// **Le test de débit dans le menu de bran : un bouton, et ce qu'on sait déjà.**
///
/// ```
///   Tester le débit                              ⌘T
///   ↓ 21,5 Mo/s   ·   ↑ 19,9 Mo/s
///   26 ms · 1 ms de gigue — mesuré il y a 4 min, 140 Mo
///   Suffisant jusqu'à : streaming 4k.
/// ```
///
/// **Le dernier relevé est affiché sans qu'on ait à relancer**, et c'est la
/// seule décision de ce fichier qui ait coûté une réflexion. Un compteur qui
/// n'affiche rien tant qu'on n'a pas cliqué oblige à dépenser cent mégaoctets
/// pour relire un chiffre qu'on avait déjà pris cinq minutes plus tôt — sur une
/// fonction qui coûte des octets, c'est le contraire de ce qu'il faut faire.
///
/// **L'âge du relevé est écrit à côté**, parce que sans lui le chiffre se lit
/// comme une propriété de l'abonnement. Il ne l'est pas : la ligne du poste a
/// été mesurée à 14 Mo/s puis à 30 Mo/s dans la même heure. « il y a 4 min » et
/// « il y a 3 jours » ne se lisent pas du tout pareil, et c'est exactement ce
/// qu'on veut.
struct SpeedMenu: View {
    let speed: SpeedController

    var body: some View {
        // **Pendant la mesure, un bouton qui agit plutôt qu'un libellé éteint.**
        //
        // Un test dure une dizaine de secondes et consomme des octets ; laisser
        // « Mesure en cours… » en gris obligerait à attendre la fin d'un test
        // qu'on vient de lancer par erreur, ou au mauvais moment — en partage de
        // connexion, juste avant une visio. Le reste du temps, le bouton est
        // éteint pendant le délai, selon la règle du dépôt : on n'offre pas un
        // clic qui ne produirait rien.
        if speed.phase.isRunning {
            Button("Arrêter la mesure", systemImage: "stop.circle") {
                speed.cancel()
            }
            .keyboardShortcut("t")
        } else {
            Button(action: speed.start) {
                Label(buttonTitle, systemImage: "gauge.with.dots.needle.bottom.50percent")
            }
            .keyboardShortcut("t")
            .disabled(speed.canStart == false)
        }

        if speed.phase.isRunning == false, speed.reading.isEmpty == false {
            Text(rates)
            Text(detail)
            Text(SpeedGrade.summary(
                download: speed.reading.download,
                latency: speed.reading.latency,
                jitter: speed.reading.jitter
            ))

            // **Le relevé d'avant, et seulement s'il y en a un.**
            //
            // C'est la ligne qui empêche de lire le chiffre du dessus comme une
            // propriété de l'abonnement. La ligne du poste a été mesurée à
            // 14 Mo/s puis à 30 Mo/s dans la même heure, sans que rien change de
            // visible : un débit est une météo, et deux mesures côte à côte le
            // disent mieux qu'une phrase.
            if let previous = speed.previous, previous.isEmpty == false {
                Text("Avant : ↓ \(SpeedFormat.megabytesSigned(previous.download))\(Self.age(of: previous.measuredAt).map { ", \($0)" } ?? "")")
            }
        }
    }

    /// Le libellé porte l'état, parce que le menu est le seul endroit d'où l'on
    /// puisse comprendre pourquoi le bouton est éteint.
    private var buttonTitle: String {
        if let remaining = speed.cooldownRemaining {
            // Le délai vient de bran, pas de la ligne : voir `SpeedPlan.cooldown`.
            // Le dire évite qu'on l'attribue à une connexion qui va très bien.
            return "Nouveau test dans \(remaining) s"
        }
        return speed.reading.isEmpty ? "Tester le débit" : "Tester à nouveau"
    }

    /// Les deux chiffres, avec leurs flèches. Espace cadratin entre eux : un
    /// `NSMenu` n'a pas de colonnes, et c'est le plus large écart que la police
    /// système offre sans se transformer en tabulation approximative — la même
    /// contrainte que `ResourceLines` documente.
    private var rates: String {
        let down = "↓ \(SpeedFormat.megabytesSigned(speed.reading.download))"
        let up = "↑ \(SpeedFormat.megabytesSigned(speed.reading.upload))"
        return "\(down)\u{2003}·\u{2003}\(up)"
    }

    private var detail: String {
        var parts: [String] = []
        if speed.reading.latency != nil {
            parts.append("\(SpeedFormat.milliseconds(speed.reading.latency)) · \(SpeedFormat.milliseconds(speed.reading.jitter)) de gigue")
        }
        if let age = Self.age(of: speed.reading.measuredAt) {
            parts.append(age)
        }
        if speed.reading.spentBytes > 0 {
            // Ce que le test a consommé. Affiché parce que c'est la contrepartie
            // honnête d'une fonction qui télécharge des dizaines de mégaoctets
            // sur commande — quelqu'un en partage de connexion a le droit de le
            // savoir avant de recliquer.
            parts.append(SpeedFormat.spent(speed.reading.spentBytes))
        }
        if let source = speed.reading.source {
            parts.append(source)
        }
        return parts.joined(separator: " — ")
    }

    /// « il y a 4 min ». Locale fixée au français, comme partout dans bran.
    private static func age(of date: Date?) -> String? {
        guard let date else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = SpeedFormat.locale
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: .now)
    }
}
