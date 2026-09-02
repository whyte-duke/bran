import AppKit
import AVFoundation
import CoreGraphics
import EventKit
import Foundation
import Observation

/// Préflight TCC des trois autorisations.
///
/// Deux sont obligatoires (écran, micro), la troisième enrichit seulement
/// (calendrier). L'app doit pouvoir enregistrer sans le calendrier.
@MainActor
@Observable
public final class PermissionsService {

    public enum Access: Equatable, Sendable {
        case granted
        case denied
        case notDetermined
    }

    public private(set) var screenRecording: Access = .notDetermined
    public private(set) var microphone: Access = .notDetermined
    public private(set) var calendar: Access = .notDetermined

    /// Ce que le prochain clic va réellement produire.
    ///
    /// L'écran a besoin de le savoir, parce que les deux cas ne se ressemblent
    /// pas du tout pour la personne devant : dans un cas macOS pose une
    /// question et l'application peut attendre la réponse, dans l'autre il ne
    /// se passera **rien** dans cette application et il faut aller aux
    /// Réglages système, puis relancer bran.
    public enum NextStep: Equatable, Sendable {
        /// macOS n'a jamais posé la question : il la posera.
        case systemDialog
        /// macOS l'a déjà posée et la réponse était non. Il ne la reposera
        /// jamais : le seul chemin restant passe par les Réglages système.
        case systemSettings
        /// Rien à demander.
        case nothingToDo
    }

    public func nextStep(forScreenRecording _: Void = ()) -> NextStep {
        if screenRecording == .granted { return .nothingToDo }
        return hasAskedForScreenRecording ? .systemSettings : .systemDialog
    }

    public func nextStep(forMicrophone _: Void = ()) -> NextStep {
        switch microphone {
        case .granted: .nothingToDo
        case .denied: .systemSettings
        case .notDetermined: .systemDialog
        }
    }

    public func nextStep(forCalendar _: Void = ()) -> NextStep {
        switch calendar {
        case .granted: .nothingToDo
        case .denied: .systemSettings
        case .notDetermined: .systemDialog
        }
    }

    /// **Le seul moyen de distinguer « refusé » de « jamais demandé » pour
    /// l'écran.**
    ///
    /// `CGPreflightScreenCaptureAccess()` rend un booléen : accordé, ou pas.
    /// Il ne dit pas si la question a été posée. Or `CGRequestScreenCaptureAccess()`
    /// n'affiche sa fenêtre qu'**une seule fois dans la vie de
    /// l'application** — après un refus, il rend `false` immédiatement et sans
    /// rien montrer. L'écran d'accueil affichait donc un bouton qui, à partir
    /// du second clic, ne faisait littéralement rien, et un bandeau conseillant
    /// de redémarrer, ce qui ne changeait rien non plus.
    ///
    /// On mémorise donc nous-mêmes que la question a été posée. C'est une
    /// approximation — l'utilisateur peut avoir accordé puis retiré
    /// l'autorisation depuis les Réglages sans repasser par ici — mais elle se
    /// trompe du bon côté : dans le doute elle propose les Réglages système,
    /// qui marchent toujours, plutôt qu'un bouton mort.
    @ObservationIgnored
    private var hasAskedForScreenRecording: Bool {
        get { UserDefaults.standard.bool(forKey: Self.askedKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.askedKey) }
    }

    private static let askedKey = "permissions.screenRecording.asked"

    private let eventStore = EKEventStore()

    public init() {
        refresh()
    }

    /// Les deux autorisations sans lesquelles un enregistrement serait vide ou
    /// muet. Le calendrier n'en fait pas partie : il ne fait que nommer.
    public var canRecord: Bool {
        screenRecording == .granted && microphone == .granted
    }

    public func refresh() {
        // `CGPreflight` ne distingue pas « refusée » de « jamais demandée », et
        // la nuance **a** une conséquence : voir `hasAskedForScreenRecording`.
        // Une autorisation accordée efface la mémoire de la demande, pour que
        // le jour où elle est retirée depuis les Réglages reparte d'un état
        // propre.
        if CGPreflightScreenCaptureAccess() {
            screenRecording = .granted
            hasAskedForScreenRecording = false
        } else {
            screenRecording = hasAskedForScreenRecording ? .denied : .notDetermined
        }

        microphone = switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .denied, .restricted: .denied
        case .notDetermined: .notDetermined
        @unknown default: .notDetermined
        }

        calendar = switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .granted
        case .denied, .restricted, .writeOnly: .denied
        case .notDetermined: .notDetermined
        @unknown default: .notDetermined
        }
    }

    // MARK: - Demander
    //
    // **Les trois passaient directement par l'API de demande, et c'est ce qui
    // les rendait morts.**
    //
    // `CGRequestScreenCaptureAccess`, `AVCaptureDevice.requestAccess` et
    // `requestFullAccessToEvents` n'affichent leur fenêtre qu'une seule fois
    // dans la vie de l'application. Après un refus, elles rendent `false`
    // immédiatement, sans rien montrer. Un bouton « Autoriser » qui les appelle
    // bêtement ne fait donc plus rien du tout à partir du second clic, et
    // l'accueil ressemble à une application cassée.
    //
    // `SystemSettings` porte l'arbitrage correct depuis toujours — regarder
    // l'état, poser la question si elle n'a jamais été posée, ouvrir le bon
    // panneau des Réglages sinon — et il n'était appelé de nulle part ici.

    /// Déclenche la fenêtre système, ou ouvre les Réglages si macOS ne la
    /// posera plus. macOS n'accorde l'autorisation d'écran qu'au prochain
    /// démarrage du processus — d'où le redémarrage explicite proposé dans
    /// l'interface plutôt qu'une attente qui ne viendra jamais.
    public func requestScreenRecording() {
        hasAskedForScreenRecording = true
        _ = SystemSettings.reRequestScreenRecording()
        refresh()
    }

    public func requestMicrophone() async {
        _ = await SystemSettings.reRequestMicrophone()
        refresh()
    }

    /// Le calendrier n'a pas de `reRequest` dans `SystemSettings` — il n'y
    /// servait à personne jusqu'ici. Même logique, écrite là où elle est
    /// utilisée, plutôt qu'une quatrième variante d'un motif à trois cas.
    public func requestCalendar() async {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined:
            // Un agent sans icône du Dock ne passe pas devant tout seul, et une
            // fenêtre d'autorisation ouverte derrière les autres ressemble
            // exactement à une application qui ne répond plus. Même raison
            // qu'à `SystemSettings.reRequestMicrophone`.
            NSApp.activate(ignoringOtherApps: true)
            _ = try? await eventStore.requestFullAccessToEvents()
        default:
            SystemSettings.open(.calendar)
        }
        refresh()
    }
}
