import Foundation
import Observation
import UserNotifications

/// Propose, ne décide pas.
///
/// Une réunion détectée n'est pas une réunion à enregistrer : on attend souvent
/// plusieurs minutes qu'un client arrive, et cette conversation-là n'a rien à
/// faire dans un fichier. La détection sert donc à *proposer*, jamais à
/// déclencher.
@MainActor
@Observable
final class NotificationService: NSObject {

    // `nonisolated` : les callbacks de UNUserNotificationCenterDelegate
    // arrivent hors du main actor et doivent pouvoir comparer ces identifiants.
    nonisolated static let meetingCategory = "bran.meeting.detected"
    nonisolated static let startAction = "bran.action.start"
    nonisolated static let ignoreAction = "bran.action.ignore"

    /// Appelé quand l'utilisateur choisit « Démarrer » depuis la notification.
    @ObservationIgnored
    var onStartRequested: (@MainActor () -> Void)?

    /// **Ce que personne ne savait, et qui rendait des alertes muettes.**
    ///
    /// Le résultat de `requestAuthorization` était jeté (`_ = try? await …`) et
    /// l'état n'était relu nulle part. Une fois les notifications refusées —
    /// une seule fois, au premier lancement, souvent par réflexe — bran
    /// continuait à poster ses propositions de réunion **et ses alertes de
    /// sauvegarde** dans le vide, sans qu'aucun écran ne le dise.
    ///
    /// C'est particulièrement coûteux pour la sauvegarde : l'alerte de retard
    /// est le seul mécanisme qui doit révéler qu'un Mac n'est plus sauvegardé.
    /// Une alerte qu'on ne peut pas recevoir ne protège de rien, et son
    /// silence ressemble exactement à « tout va bien ».
    enum Authorization: Equatable, Sendable {
        case granted
        case denied
        case notDetermined
    }

    private(set) var authorization: Authorization = .notDetermined

    /// Vrai quand une notification postée a une chance d'être vue.
    var canDeliver: Bool { authorization == .granted }

    @ObservationIgnored
    private let center = UNUserNotificationCenter.current()

    func configure() {
        center.delegate = self

        let start = UNNotificationAction(
            identifier: Self.startAction,
            title: "Démarrer l'enregistrement",
            options: [.foreground]
        )
        let ignore = UNNotificationAction(
            identifier: Self.ignoreAction,
            title: "Pas cette fois",
            options: [.destructive]
        )
        let category = UNNotificationCategory(
            identifier: Self.meetingCategory,
            actions: [start, ignore],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])

        // **On ne demande plus l'autorisation au lancement.**
        //
        // Elle était réclamée dès le démarrage, avant que quoi que ce soit ne
        // la justifie : une fenêtre système sans contexte, à laquelle on
        // répond non par réflexe, et qu'aucun écran ne permettait ensuite de
        // reprendre. macOS ne repose jamais la question.
        //
        // Elle est maintenant demandée au premier moment où elle sert
        // réellement — voir `requestIfNeeded()` — c'est-à-dire quand une
        // réunion est proposée ou qu'une alerte de sauvegarde part. À ce
        // moment-là, la question a une réponse évidente.
        Task { await refresh() }
    }

    /// Relit l'état réel auprès du système.
    ///
    /// À appeler au retour au premier plan : l'utilisateur peut avoir changé
    /// d'avis dans les Réglages système, et un état mis en cache pour toujours
    /// est exactement le défaut qu'on corrige ici.
    func refresh() async {
        let settings = await center.notificationSettings()
        authorization = switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: .granted
        case .denied: .denied
        case .notDetermined: .notDetermined
        @unknown default: .notDetermined
        }
    }

    /// Demande l'autorisation si — et seulement si — la question n'a jamais
    /// été posée. Rend `true` quand une notification peut désormais partir.
    ///
    /// Après un refus, macOS ne réaffiche rien : il n'y a plus qu'à ouvrir les
    /// Réglages système, ce que l'écran des autorisations doit proposer. Ce
    /// n'est pas fait ici, parce qu'ouvrir une fenêtre de Réglages au moment
    /// où une réunion démarre serait pire que le silence.
    @discardableResult
    func requestIfNeeded() async -> Bool {
        await refresh()
        guard authorization == .notDetermined else { return authorization == .granted }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
        await refresh()
        return authorization == .granted
    }

    func proposeRecording(title: String?) {
        Task { await proposeRecordingAsync(title: title) }
    }

    private func proposeRecordingAsync(title: String?) async {
        // La première proposition est le moment où la notification devient
        // utile : c'est là qu'on demande, pas au lancement.
        guard await requestIfNeeded() else {
            // Le silence ne doit pas être silencieux pour nous : sans cette
            // trace, « bran ne m'a rien proposé » est indiscernable de « bran
            // n'a pas vu la réunion ».
            FeatureLog.record(
                "proposition de réunion non remise — notifications \(authorization == .denied ? "refusées" : "indisponibles")"
            )
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "Réunion Meet détectée"
        content.body = title.map { "« \($0) » — enregistrer ?" } ?? "Enregistrer cette réunion ?"
        content.categoryIdentifier = Self.meetingCategory
        content.sound = .default

        // Pas de déclencheur : la notification part immédiatement.
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        try? await center.add(request)
    }

    func withdrawProposals() {
        center.removeAllDeliveredNotifications()
    }
}

extension NotificationService: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == Self.startAction else { return }
        await onStartRequested?()
    }

    /// Sans ça, une notification émise pendant que bran est au premier plan est
    /// avalée silencieusement.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
