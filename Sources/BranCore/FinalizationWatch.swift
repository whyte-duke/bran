import Foundation

/// Décide, à chaque coup de sonde, s'il faut continuer d'attendre la
/// finalisation d'un enregistrement — ou déclarer qu'elle est morte.
///
/// **Pourquoi ce type existe.** L'attente était une échéance sèche de soixante
/// secondes. Mesuré le 11 août 2026 sur une réunion de 36 min 32 s :
/// `stopCapture()` a rendu la main à 16:34:19 et `replayd` n'a relâché le
/// fichier qu'à **16:46:28** — douze minutes plus tard. bran avait abandonné
/// onze minutes plus tôt, marqué la réunion « interrompue », et laissé un
/// fichier de 2,56 Go parfaitement lisible que plus personne ne réclamait.
///
/// Ce n'est pas une lenteur exceptionnelle, c'est le fonctionnement normal de
/// `SCRecordingOutput` : deux travaux sont différés jusqu'à l'arrêt.
/// - Le backlog vidéo est vidé sur le disque à la fin. Le fichier faisait
///   180 Mo au moment du clic sur « Arrêter » et 2,56 Go douze minutes plus
///   tard : **93 % de l'enregistrement a été écrit après l'arrêt.**
/// - L'audio est mixé hors-ligne d'un seul tenant (`FAQ Offline Mixer` dans les
///   traces de `replayd`), à environ 3,4× le temps réel.
///
/// Le coût de finalisation est donc **proportionnel à la durée enregistrée** :
/// ici un tiers de celle-ci. Une échéance fixe de 60 s ne couvre qu'environ
/// trois minutes d'enregistrement — au-delà, tout échoue. Le spike de la
/// Phase 1 validait sur neuf secondes, ce qui passait.
///
/// **Le signal juste n'est pas l'horloge, c'est la progression.** Tant que le
/// fichier grossit, `replayd` travaille, quel que soit le temps que ça prend.
/// C'est observable depuis bran sans API privée : la taille du fichier. On
/// n'échoue donc que sur un *silence* — plus rien d'écrit depuis assez
/// longtemps pour qu'on n'attende plus rien.
public struct FinalizationWatch: Sendable {

    public enum Verdict: Equatable, Sendable {
        /// `replayd` écrit encore, ou vient tout juste de s'interrompre.
        case keepWaiting(bytesWritten: Int64, silentFor: Duration)

        /// `recordingOutputDidFinishRecording` est arrivé : le fichier est clos.
        case finished(bytesWritten: Int64)

        /// ScreenCaptureKit a rapporté une panne — flux interrompu, écriture
        /// impossible. Distinct de `.stalled` : ici on sait *pourquoi*, et il
        /// n'y a rien à attendre de plus.
        case failed(bytesWritten: Int64, reason: String)

        /// Plus rien n'a été écrit depuis `stallTimeout`. C'est le seul échec
        /// que ce type prononce, et il dit toujours combien d'octets ont été
        /// écrits — un fichier de 2 Go abandonné n'est pas un fichier perdu.
        case stalled(bytesWritten: Int64, silentFor: Duration)

        /// Le plafond absolu est atteint alors que le fichier grossit encore.
        /// Filet de sécurité, jamais atteint en pratique : il n'existe que pour
        /// qu'une attente ne dure pas jusqu'à la fin des temps.
        case exhausted(bytesWritten: Int64, after: Duration)
    }

    /// Durée de **silence** — pas d'attente — au bout de laquelle on renonce.
    ///
    /// Deux minutes parce que l'écriture se fait par blocs : entre deux vidages,
    /// la taille peut ne pas bouger pendant plusieurs dizaines de secondes sans
    /// que rien n'aille mal. Trop court, on retombe dans le défaut qu'on corrige.
    public static let defaultStallTimeout = Duration.seconds(120)

    /// Plafond absolu, dérivé de la durée enregistrée.
    ///
    /// Trois fois la durée : la finalisation mesurée coûte un tiers de la durée,
    /// ce qui laisse un facteur neuf de marge. Le plancher de dix minutes couvre
    /// les enregistrements courts, dont la finalisation a un coût fixe qui ne
    /// dépend pas d'eux.
    public static func hardLimit(forRecorded recorded: Duration) -> Duration {
        max(.seconds(600), recorded * 3)
    }

    private let stallTimeout: Duration
    private let hardLimit: Duration

    private var startedAt: Duration?
    private var lastBytes: Int64 = -1
    private var lastGrowthAt: Duration = .zero

    public init(
        stallTimeout: Duration = FinalizationWatch.defaultStallTimeout,
        hardLimit: Duration
    ) {
        self.stallTimeout = stallTimeout
        self.hardLimit = hardLimit
    }

    public init(recorded: Duration, stallTimeout: Duration = FinalizationWatch.defaultStallTimeout) {
        self.init(stallTimeout: stallTimeout, hardLimit: Self.hardLimit(forRecorded: recorded))
    }

    /// - Parameters:
    ///   - bytesWritten: taille du fichier en cours d'écriture, en octets.
    ///   - didFinish: le callback de fin est-il arrivé.
    ///   - failure: panne rapportée par ScreenCaptureKit, s'il y en a une.
    ///   - now: horloge monotone de l'appelant. Passée en paramètre pour que la
    ///     politique se teste sans dormir.
    ///
    /// **Une taille qui n'a jamais été relevée n'est pas un silence.** Le
    /// premier appel arme la montre au lieu de démarrer un compte à rebours
    /// depuis zéro : sinon un premier relevé tardif consommerait d'emblée une
    /// partie du délai.
    public mutating func observe(
        bytesWritten: Int64,
        didFinish: Bool,
        failure: String? = nil,
        at now: Duration
    ) -> Verdict {
        if startedAt == nil {
            startedAt = now
            lastGrowthAt = now
        }

        // Avant `didFinish` : le delegate coche les deux d'un coup quand il
        // rapporte une panne — c'est ce qui débloque l'attente — et lire la fin
        // en premier ferait passer une panne pour un fichier bien clos.
        if let failure { return .failed(bytesWritten: bytesWritten, reason: failure) }

        // La fin déclarée l'emporte sur tout le reste, y compris sur un
        // plafond dépassé dans le même coup de sonde : le fichier est clos, il
        // n'y a plus rien à arbitrer.
        if didFinish { return .finished(bytesWritten: bytesWritten) }

        if bytesWritten > lastBytes {
            lastBytes = bytesWritten
            lastGrowthAt = now
        }

        let silence = now - lastGrowthAt
        if silence >= stallTimeout {
            return .stalled(bytesWritten: bytesWritten, silentFor: silence)
        }

        let elapsed = now - (startedAt ?? now)
        if elapsed >= hardLimit {
            return .exhausted(bytesWritten: bytesWritten, after: elapsed)
        }

        return .keepWaiting(bytesWritten: bytesWritten, silentFor: silence)
    }
}

extension FinalizationWatch.Verdict {

    /// L'attente est terminée, bien ou mal.
    public var isSettled: Bool {
        switch self {
        case .keepWaiting: false
        case .finished, .failed, .stalled, .exhausted: true
        }
    }

    /// Ce qui a été écrit, quel que soit le verdict. Toujours à dire :
    /// l'utilisateur qui lit « finalisation abandonnée » veut savoir dans la
    /// même phrase s'il reste 2 Go sur le disque ou rien du tout.
    public var bytesWritten: Int64 {
        switch self {
        case .keepWaiting(let bytes, _), .finished(let bytes), .failed(let bytes, _),
             .stalled(let bytes, _), .exhausted(let bytes, _):
            bytes
        }
    }

    /// Ce qu'on écrit dans la fiche et dans le bandeau. `nil` sur un succès.
    ///
    /// **Chaque motif dit le poids écrit.** C'est la différence entre « la
    /// finalisation a échoué » — qui laisse croire à une perte sèche — et
    /// « 2,4 Go ont été écrits avant l'abandon », qui dit à l'utilisateur qu'il
    /// a un fichier à récupérer et où regarder.
    public func failureReason(formattedBytes: (Int64) -> String) -> String? {
        switch self {
        case .keepWaiting, .finished:
            nil
        case .failed(let bytes, let reason):
            "\(reason) — \(formattedBytes(bytes)) écrits."
        case .stalled(let bytes, let silence):
            "plus rien n'a été écrit depuis \(Int(silence.components.seconds)) s "
            + "— \(formattedBytes(bytes)) sont sur le disque, le fichier est probablement lisible."
        case .exhausted(let bytes, let elapsed):
            "la finalisation dure depuis \(Int(elapsed.components.seconds / 60)) min et n'aboutit pas "
            + "— \(formattedBytes(bytes)) sont sur le disque, le fichier est probablement lisible."
        }
    }
}
