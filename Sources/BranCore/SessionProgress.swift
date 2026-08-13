import Foundation

/// Ce qui se passe entre le clic sur « Arrêter » et le fichier utilisable.
///
/// **C'est la partie de bran que personne ne voyait.** L'utilisateur raccrochait,
/// la barre de pilotage disparaissait à la seconde où la machine repassait au
/// repos, et trois travaux continuaient pourtant : `replayd` refermait le
/// fichier, bran recollait puis compressait les morceaux, puis en extrayait
/// l'audio du CRM. Sur une réunion de trente-six minutes, ça fait plusieurs
/// dizaines de minutes de silence complet, pendant lesquelles la seule chose
/// visible était une bibliothèque qui n'affichait pas encore la réunion.
///
/// Le silence n'était pas seulement désagréable : il poussait à fermer bran, ce
/// qui est précisément le geste qui perd le travail en cours.
///
/// Ce type est **du calcul, pas de l'affichage** : il vit dans `BranCore` pour
/// que les libellés et les estimations soient testés sans écran, et pour que la
/// barre, la ligne de bibliothèque et le menu disent exactement la même chose au
/// même moment — trois formulations divergentes du même état étaient l'autre
/// moitié du problème.
public struct SessionProgress: Equatable, Sendable {

    /// Les trois travaux qui suivent la capture, dans l'ordre où ils arrivent.
    ///
    /// Ils sont séquentiels par nécessité et non par commodité : on ne peut pas
    /// fusionner un fichier que `replayd` écrit encore, ni extraire l'audio d'une
    /// vidéo qui n'existe pas.
    public enum Stage: Equatable, Sendable {
        /// `stopCapture()` a rendu la main, `replayd` écrit encore. Mesuré à
        /// environ un tiers de la durée enregistrée — voir `FinalizationWatch`.
        case finalizing

        /// Les morceaux sont recollés et réencodés en une seule passe.
        case merging

        /// L'audio du CRM est extrait de la vidéo, et **conservé à côté d'elle**.
        case exportingAudio
    }

    public var stage: Stage

    /// Avancement de 0 à 1, ou `nil` quand rien n'est mesurable.
    ///
    /// `nil` n'est pas « zéro » : la finalisation n'a aucune progression à
    /// offrir — `replayd` ne rapporte rien — et afficher une barre à 0 %
    /// pendant douze minutes est un signal pire que pas de barre du tout.
    public var fraction: Double?

    /// Ce qui est déjà écrit sur le disque. Pendant la finalisation, c'est le
    /// **seul** signe que quelque chose avance.
    public var bytesWritten: Int64

    /// Durée réellement enregistrée. Sert à estimer la finalisation.
    public var recorded: Duration

    /// Temps passé dans l'étape courante. Sert à estimer la compression, dont on
    /// ne connaît aucune vitesse à l'avance — elle dépend de la définition de
    /// l'écran, du codec matériel et de ce que la machine fait par ailleurs.
    public var elapsed: Duration

    public init(
        stage: Stage,
        fraction: Double? = nil,
        bytesWritten: Int64 = 0,
        recorded: Duration = .zero,
        elapsed: Duration = .zero
    ) {
        self.stage = stage
        self.fraction = fraction
        self.bytesWritten = bytesWritten
        self.recorded = recorded
        self.elapsed = elapsed
    }

    // MARK: - Ce qui s'affiche

    /// La phrase principale. Dit ce que bran **fait**, pas dans quel état il est.
    ///
    /// « Traitement en cours » ne répond pas à la question que l'utilisateur se
    /// pose, qui est toujours la même : est-ce que ça avance, et est-ce que je
    /// peux partir ?
    public var title: String {
        switch stage {
        case .finalizing: "Finalisation de l'enregistrement…"
        case .merging: "Fusion et compression de la vidéo…"
        case .exportingAudio: "Préparation de l'audio pour le CRM…"
        }
    }

    /// La ligne de détail : ce qui est fait, ce qui reste, et la seule consigne.
    ///
    /// Chaque morceau n'apparaît que s'il a quelque chose à dire. Une ligne qui
    /// afficherait « 0 % · 0 octet · environ 0 min » aurait l'air d'un blocage
    /// alors qu'elle décrirait un démarrage normal.
    public var detail: String {
        var parts: [String] = []

        if let percent = percentDescription { parts.append(percent) }
        if bytesWritten > 0 { parts.append("\(bytesWritten.formatted(.byteCount(style: .file))) écrits") }
        if let remaining = remainingDescription { parts.append(remaining) }

        // Toujours en dernier, et toujours présente : c'est la seule action que
        // l'utilisateur peut prendre, et c'est une action négative. `replayd`
        // survit à la fermeture de bran, mais bran ne saurait plus quoi faire du
        // fichier ; la fusion et l'extraction, elles, meurent avec le processus.
        parts.append("ne quittez pas bran")

        return parts.joined(separator: " · ")
    }

    /// Le seuil sous lequel on ne dit rien plutôt que de dire « 0 % ».
    ///
    /// L'arrondi de l'affichage est à l'unité : tout ce qui est sous un
    /// demi-pour-cent s'écrit « 0 % ». Un simple garde `fraction > 0` laissait
    /// donc passer exactement ce qu'il prétendait interdire, et les premiers
    /// rapports d'avancement d'un encodage tombent précisément dans cette
    /// plage — la barre s'ouvrait sur « 0 % », c'est-à-dire sur le signal d'un
    /// travail qui ne démarre pas.
    private static let visibleFloor = 0.005

    private var percentDescription: String? {
        guard let fraction, fraction >= Self.visibleFloor else { return nil }
        let clamped = min(fraction, 1)
        return "\((clamped * 100).formatted(.number.precision(.fractionLength(0)))) %"
    }

    /// Le temps restant, **estimé de deux façons différentes** parce qu'on ne
    /// sait pas la même chose des deux étapes.
    ///
    /// La finalisation n'offre aucune progression : l'estimation vient d'une
    /// mesure faite une fois — le 11 août 2026, 2 191 s enregistrées ont demandé
    /// 729 s de finalisation, soit un tiers — et de rien d'autre. La compression,
    /// elle, rapporte sa fraction : son reste s'extrapole depuis le temps déjà
    /// passé, ce qui vaut mieux qu'une constante puisque la vitesse dépend de la
    /// machine.
    ///
    /// `nil` quand on ne sait pas, et c'est le cas le plus fréquent au démarrage
    /// d'une étape. Une estimation faite sur 2 % d'avancement se trompe d'un
    /// facteur dix ; l'annoncer puis la voir tripler est pire que ne rien
    /// annoncer.
    public var remaining: Duration? {
        switch stage {
        case .finalizing:
            let recordedSeconds = recorded.components.seconds
            guard recordedSeconds > 30 else { return nil }
            let total = recordedSeconds / 3
            let left = total - elapsed.components.seconds
            return left > 0 ? .seconds(left) : nil

        case .merging:
            guard let fraction, fraction >= 0.03 else { return nil }
            let spent = Double(elapsed.components.seconds)
            guard spent >= 2 else { return nil }
            let left = spent * (1 - fraction) / fraction
            return left >= 1 ? .seconds(Int64(left.rounded())) : nil

        case .exportingAudio:
            // Quelques secondes, y compris sur une réunion de trois heures :
            // c'est de la transcodage audio pure. Estimer aurait plus de chances
            // de se tromper que d'aider.
            return nil
        }
    }

    /// **Arrondi à la minute la plus proche, et non tronqué.**
    ///
    /// La troncature annonçait « environ 1 min » pour 119 s restantes, et
    /// « environ 59 min » pour une heure. Elle sous-estimait donc
    /// systématiquement, jusqu'à cinquante-neuf secondes — dans le mauvais sens
    /// pour une phrase qui se termine par « ne quittez pas bran » : celui qui
    /// s'organise sur l'estimation part une minute trop tôt.
    private var remainingDescription: String? {
        guard let remaining else { return nil }
        let seconds = remaining.components.seconds
        guard seconds >= 60 else { return "moins d'une minute" }
        return "environ \((seconds + 30) / 60) min"
    }

    /// La phrase compacte du menu, où il n'y a de place que pour une ligne.
    public var summary: String {
        var text = title
        if text.hasSuffix("…") { text.removeLast() }
        if let percent = percentDescription { return "\(text) — \(percent)" }
        if bytesWritten > 0 { return "\(text) — \(bytesWritten.formatted(.byteCount(style: .file))) écrits" }
        return text
    }
}
