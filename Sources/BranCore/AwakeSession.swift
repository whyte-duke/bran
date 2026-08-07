import Foundation

/// **L'éveil : empêcher le Mac de s'endormir, et le dire.**
///
/// ```
///   un clic ──▶ AwakeState.begin(durée) ──▶ .indefinite
///                                       └─▶ .until(date) ──▶ compte à rebours
///                                                        └─▶ expiré ──▶ .off
/// ```
///
/// Tout ce qui décide vit ici, sur des dates et des nombres : ce qui reste dans
/// `BranApp` est l'assertion système, qu'aucun test ne peut observer. C'est la
/// même coupure que `ResourceReading` / `ResourceProbe` — le calcul d'un côté,
/// les deux appels au noyau de l'autre.

// MARK: - Les durées

/// Les durées proposées, et rien d'autre.
///
/// **`Int` en valeur brute, et ce sont des secondes** : le réglage se persiste
/// dans `UserDefaults` sans table de correspondance, et un jour où la liste
/// change, une valeur inconnue retombe proprement sur le défaut.
///
/// « Sans limite » vaut zéro seconde plutôt qu'un cas à part : c'est la valeur
/// par défaut de bran, parce que la demande était « un clic = tout le temps ».
public enum AwakeDuration: Int, CaseIterable, Sendable, Identifiable {
    case fiveMinutes = 300
    case fifteenMinutes = 900
    case thirtyMinutes = 1800
    case oneHour = 3600
    case twoHours = 7200
    case fiveHours = 18_000
    case indefinite = 0

    public var id: Int { rawValue }

    public var seconds: TimeInterval { TimeInterval(rawValue) }

    public var isIndefinite: Bool { self == .indefinite }

    public var label: String {
        switch self {
        case .fiveMinutes: "5 minutes"
        case .fifteenMinutes: "15 minutes"
        case .thirtyMinutes: "30 minutes"
        case .oneHour: "1 heure"
        case .twoHours: "2 heures"
        case .fiveHours: "5 heures"
        case .indefinite: "Sans limite"
        }
    }
}

// MARK: - L'état

/// Trois états, et le troisième porte sa propre échéance.
///
/// **Une date, pas un compteur qui décrémente.** Un compteur suppose que
/// personne ne saute : la mise en veille manuelle, la fermeture du capot, une
/// horloge qui se recale sur le réseau feraient tous mentir un décompte tenu à
/// la main. Une échéance absolue est juste au réveil sans que rien ne la
/// rattrape — c'est la leçon déjà payée par `WatchClock` (CR-2), appliquée ici
/// avant plutôt qu'après.
public enum AwakeState: Equatable, Sendable {
    case off
    case indefinite
    case until(Date)

    public var isOn: Bool { self != .off }

    /// Ce qu'il reste, ou `nil` s'il n'y a rien à décompter — éteint, ou sans
    /// limite. Les deux se distinguent par `isOn`, pas par ce que rend celle-ci.
    public func remaining(at now: Date) -> TimeInterval? {
        guard case .until(let deadline) = self else { return nil }
        return max(0, deadline.timeIntervalSince(now))
    }

    /// L'échéance est-elle passée ? Faux pour « sans limite », qui n'en a pas.
    public func hasExpired(at now: Date) -> Bool {
        guard case .until(let deadline) = self else { return false }
        return now >= deadline
    }

    /// Démarre une session. Une durée nulle donne « sans limite » : c'est la même
    /// décision qu'à l'entrée du menu, prise une seule fois, ici.
    public static func begin(_ duration: AwakeDuration, at now: Date) -> AwakeState {
        duration.isIndefinite ? .indefinite : .until(now.addingTimeInterval(duration.seconds))
    }
}

// MARK: - Ce qui s'affiche

/// Les libellés de l'éveil. Français en dur, comme tout le reste de bran.
public enum AwakeFormat {

    /// Le signe de « sans limite ». **Un caractère**, parce qu'il vit dans une
    /// barre de menus derrière un chrono qui prend déjà la place.
    public static let forever = "∞"

    /// Le temps restant, arrondi **vers le haut**.
    ///
    /// L'arrondi n'est pas cosmétique : arrondi au plus proche, une session de
    /// cinq minutes afficherait « 4 min » pendant ses trente premières secondes,
    /// et une session sur le point de finir afficherait « 0 min » alors qu'elle
    /// tient encore le Mac éveillé. Vers le haut, le nombre affiché est toujours
    /// une promesse tenue.
    ///
    /// Le passage aux heures se fait sur les **minutes déjà arrondies** : sans
    /// ça, 3 599 s donnerait « 60 min ».
    public static func countdown(_ remaining: TimeInterval) -> String {
        guard remaining > 0 else { return "0 s" }

        if remaining < 60 {
            return "\(Int(remaining.rounded(.up))) s"
        }

        let minutes = Int((remaining / 60).rounded(.up))
        if minutes < 60 {
            return "\(minutes) min"
        }

        // « 1 h 05 » et pas « 1 h 5 » : dans la barre de menus, le libellé
        // change de largeur à chaque passage sous dix minutes, et tout ce qui
        // est à sa gauche se décale avec lui.
        return "\(minutes / 60) h \(String(format: "%02d", minutes % 60))"
    }

    /// Ce que la barre de menus ajoute, ou `nil` quand l'éveil est éteint.
    /// « ∞ » sans limite, le décompte sinon.
    public static func menuBar(_ state: AwakeState, at now: Date) -> String? {
        switch state {
        case .off: nil
        case .indefinite: forever
        case .until: countdown(state.remaining(at: now) ?? 0)
        }
    }

    /// La ligne du menu déroulant, celle qui a la place d'une phrase.
    public static func summary(_ state: AwakeState, at now: Date) -> String {
        switch state {
        case .off: "Le Mac s'endort normalement."
        case .indefinite: "Éveillé — sans limite."
        case .until: timed(countdown(state.remaining(at: now) ?? 0))
        }
    }

    /// La même phrase, à partir d'un décompte **déjà calculé**.
    ///
    /// Elle existe pour une raison précise : dans un menu resté ouvert, la vue
    /// doit lire le décompte publié par la boucle pour s'abonner à ses
    /// battements. Recalculer sur `Date.now` la figerait à l'instant de
    /// l'ouverture. Une seule phrase, deux entrées.
    public static func timed(_ countdown: String) -> String {
        "Éveillé — encore \(countdown)."
    }
}
