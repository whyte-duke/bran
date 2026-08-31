import Foundation

/// L'arithmétique qui décide à quel débit encoder l'audio d'une réunion pour
/// qu'il tienne sous le plafond du CRM.
///
/// **Ce type ne contient que du calcul, et c'est exprès.** Il vivait dans
/// `AudioExporter`, mêlé à AVFoundation et à `libmp3lame`, donc dans une cible
/// que `swift test` ne peut pas atteindre — alors que c'est précisément
/// l'endroit où une erreur ne se voit pas. La faute historique était une
/// confusion Mo/Mio : la borne était posée à 52 428 800 sous un commentaire qui
/// disait pourtant « 50 passent, 52 sont refusés », donc en plein dans la zone
/// de refus mesurée. Un fichier entre 50 et 52,4 Mo franchissait la garde
/// locale, montait en entier, et le CRM le rejetait à l'arrivée. Rien dans le
/// code ne le signalait ; seul un test pouvait.
public enum SpeechAudioBudget {

    /// Le plafond du serveur : **50 Mo, c'est-à-dire 50 000 000 octets**.
    ///
    /// Le serveur compte en méga-octets décimaux ; on compte comme lui.
    public static let maximumBytes = 50_000_000

    /// Ce que l'encodage a le droit de viser : 90 % du plafond, soit 45 Mo.
    ///
    /// La marge couvre l'écart entre le débit demandé et la taille écrite —
    /// en-tête du conteneur, trame Info, dernière trame incomplète. Elle est
    /// large parce qu'elle ne coûte rien : à 16 kHz mono, la table des débits
    /// est assez fine pour que viser 45 Mo au lieu de 50 ne change presque
    /// jamais le palier retenu.
    ///
    /// Viser le plafond exact aurait été de la fausse précision : le débit
    /// demandé n'est qu'une consigne, seule la taille écrite est un fait — d'où
    /// aussi le contrôle a posteriori en fin d'extraction.
    public static let workingBudgetBytes = maximumBytes * 9 / 10

    /// Les débits que LAME accepte en MPEG-2 LSF, c'est-à-dire à 16 kHz.
    ///
    /// **Bornée à 48 kbit/s vers le haut, et ce n'est pas une limite de
    /// l'encodeur.** C'est le réglage validé de bout en bout : le repli
    /// navigateur du CRM encode en 48 kbit/s mono 16 kHz depuis toujours, et
    /// c'est à ce profil exact qu'Azure a rendu 200 le 31/08/2026 sur un
    /// closing de 32 min. Monter à 64 ou 96 kbit/s doublerait le poids d'envoi
    /// pour une reconnaissance vocale qui n'entend rien au-dessus de 8 kHz.
    ///
    /// **Le plancher à 8 kbit/s change la nature du problème.** L'ancien
    /// encodeur AAC refusait le média entier sous 12 kbit/s, ce qui plafonnait
    /// les réunions envoyables à 8 h 20. Ici, 8 kbit/s tient 12 h 30 dans le
    /// budget : le refus pour cause de durée est devenu théorique.
    public static let bitrates = [8, 16, 24, 32, 40, 48].map { $0 * 1000 }

    public static var minimumBitrate: Int { bitrates.first ?? 8_000 }
    public static var maximumBitrate: Int { bitrates.last ?? 48_000 }

    /// Le débit à demander pour qu'une réunion de `seconds` secondes tienne dans
    /// le budget de travail.
    ///
    /// **Le palier retenu est le plus élevé qui tient**, pas le plus proche du
    /// calcul : arrondir au voisin le plus proche pourrait remonter au-dessus du
    /// budget, et c'est exactement le genre d'octets qu'on n'a pas.
    ///
    /// Ce que ça donne, avec 45 Mo de budget :
    ///
    /// - **jusqu'à 2 h 05**, on reste à 48 kbit/s — la qualité de référence, et
    ///   la quasi-totalité des closings.
    /// - **au-delà**, bran descend d'un palier au lieu de refuser l'envoi : une
    ///   réunion de 4 h part à 24 kbit/s. Moins beau, mais transcrit.
    /// - **le plancher de 8 kbit/s n'est atteint qu'à 12 h 30.**
    ///
    /// Durée inconnue (`duration` non numérique sur un fichier abîmé) : on
    /// demande le maximum et on laisse la mesure de fin trancher. Deviner bas
    /// « au cas où » aurait dégradé tous les fichiers dont on ne sait rien.
    public static func bitrate(forDurationSeconds seconds: Double) -> Int {
        guard seconds > 0, seconds.isFinite else { return maximumBitrate }

        let affordable = Double(workingBudgetBytes) * 8 / seconds
        return bitrates.last { Double($0) <= affordable } ?? minimumBitrate
    }

    /// Cette durée peut-elle tenir sous le plafond, à quelque débit que ce soit ?
    ///
    /// **La question se juge au plafond réel, pas au budget de travail.** Le
    /// budget est une marge qu'on s'accorde pour VISER ; il n'a rien à faire
    /// dans la décision de renoncer, qui doit se prendre sur ce que le serveur
    /// refuse vraiment. La version qui regardait les 45 Mo renonçait sur une
    /// bande de durées où le fichier serait pourtant passé.
    public static func fits(durationSeconds seconds: Double) -> Bool {
        guard seconds > 0, seconds.isFinite else { return true }
        return Double(maximumBytes) * 8 / seconds >= Double(minimumBitrate)
    }

    /// Le poids qu'aurait le fichier au plancher — ce qu'on annonce dans le
    /// message de refus, faute d'avoir encodé quoi que ce soit.
    public static func floorSizeBytes(durationSeconds seconds: Double) -> Int {
        Int(seconds * Double(minimumBitrate) / 8)
    }
}
