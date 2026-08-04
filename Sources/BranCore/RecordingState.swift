/// États de `RecordingEngine`.
///
/// `.finalizing` n'est pas une élégance de machine à états : le spike de la
/// Phase 1 a montré que `stopCapture()` rend la main plusieurs secondes avant
/// que le `.mp4` existe. Sauter cet état, c'est déclarer terminé un
/// enregistrement qui n'est pas encore écrit.
public enum RecordingState: Equatable, Sendable {
    case idle
    case starting(MeetingRef)
    case recording(MeetingRef)

    /// Segment courant fermé, session toujours ouverte.
    ///
    /// ScreenCaptureKit n'a pas de pause : `SCStream` n'expose que
    /// `startCapture` / `stopCapture`, et `updateConfiguration` sur un flux qui
    /// enregistre l'interrompt. La pause est donc une fermeture de fichier, et
    /// la reprise l'ouverture d'un nouveau. Les morceaux sont recollés à la fin.
    case paused(MeetingRef)

    case finalizing(MeetingRef)
    case failed(reason: String)

    public var meeting: MeetingRef? {
        switch self {
        case .starting(let meeting), .recording(let meeting),
             .paused(let meeting), .finalizing(let meeting):
            meeting
        case .idle, .failed:
            nil
        }
    }

    public var isActive: Bool {
        switch self {
        case .starting, .recording, .paused, .finalizing: true
        case .idle, .failed: false
        }
    }
}
