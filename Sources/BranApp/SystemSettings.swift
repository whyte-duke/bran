import AppKit
import AVFoundation
import Foundation

/// Redemander une autorisation, de la seule façon qui marche vraiment.
///
/// **Le piège que ce type existe pour éviter.** `AVCaptureDevice.requestAccess`
/// n'affiche une fenêtre qu'une seule fois dans la vie de l'application. Une
/// fois l'autorisation refusée — ou périmée parce que la signature du binaire a
/// changé — le même appel renvoie `false` immédiatement, **sans rien afficher**.
/// Un bouton « Redemander » qui appelle bêtement `requestAccess` ne fait donc
/// rien du tout, et donne l'impression d'une application cassée.
///
/// La seule réparation possible dans ce cas est d'ouvrir le panneau exact des
/// Réglages système. D'où `reRequest`, qui regarde l'état avant de choisir :
///
/// ```
///   jamais demandé  →  requestAccess   (macOS affiche la fenêtre)
///   refusé          →  ouvrir le panneau, à la bonne page
/// ```
enum SystemSettings {

    /// Les pages qui nous concernent. Les identifiants sont ceux que macOS
    /// attend derrière `x-apple.systempreferences:`.
    enum Pane: String {
        case microphone = "Privacy_Microphone"
        case screenRecording = "Privacy_ScreenCapture"
        case accessibility = "Privacy_Accessibility"
        case calendar = "Privacy_Calendars"

        var label: String {
            switch self {
            case .microphone: "Microphone"
            case .screenRecording: "Enregistrement de l'écran"
            case .accessibility: "Accessibilité"
            case .calendar: "Calendriers"
            }
        }
    }

    /// Ouvre la page voulue. Si l'URL profonde échoue — elles changent d'une
    /// version de macOS à l'autre — on ouvre au moins Réglages système plutôt
    /// que de ne rien faire.
    @MainActor
    static func open(_ pane: Pane) {
        let deepLink = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)")
        if let deepLink, NSWorkspace.shared.open(deepLink) { return }
        if let fallback = URL(string: "x-apple.systempreferences:") {
            NSWorkspace.shared.open(fallback)
        }
    }

    /// Redemande le microphone.
    ///
    /// Rend `true` si l'autorisation est acquise à la sortie. Rend `false` après
    /// avoir ouvert les Réglages, parce qu'il n'y a alors plus rien à attendre
    /// dans cette application : macOS n'applique le changement qu'au prochain
    /// lancement du processus.
    @MainActor
    static func reRequestMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            // Un agent sans icône du Dock ne passe pas devant tout seul, et une
            // fenêtre d'autorisation ouverte derrière les autres ressemble
            // exactement à une application qui ne répond plus.
            NSApp.activate(ignoringOtherApps: true)
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            open(.microphone)
            return false
        @unknown default:
            open(.microphone)
            return false
        }
    }

    /// Redemande l'enregistrement de l'écran.
    ///
    /// `CGRequestScreenCaptureAccess` a la même limite : il n'affiche la fenêtre
    /// qu'à la première demande.
    @MainActor
    static func reRequestScreenRecording() -> Bool {
        guard CGPreflightScreenCaptureAccess() == false else { return true }
        NSApp.activate(ignoringOtherApps: true)
        guard CGRequestScreenCaptureAccess() else {
            open(.screenRecording)
            return false
        }
        return true
    }

    /// Redemande l'Accessibilité.
    ///
    /// Elle n'a pas d'API de demande : `AXIsProcessTrustedWithOptions` ouvre une
    /// fenêtre qui renvoie vers les Réglages, et c'est tout ce qu'on peut faire.
    @MainActor
    static func reRequestAccessibility() -> Bool {
        guard HotkeyMonitor.isTrusted == false else { return true }
        NSApp.activate(ignoringOtherApps: true)
        HotkeyMonitor.requestTrust()
        open(.accessibility)
        return false
    }
}
