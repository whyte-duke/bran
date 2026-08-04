/// La seule chose que `SessionResolver` a le droit de produire, et la seule
/// chose que `RecordingEngine` a le droit de recevoir.
///
/// C'est ce goulot qui interdit le double enregistrement : aucun détecteur ne
/// peut appeler `start` directement.
public enum Intent: Equatable, Sendable {
    case start(MeetingRef)
    case stop
    case noop
}
