import Foundation
import UserNotifications

/// Propose, ne décide pas.
///
/// Une réunion détectée n'est pas une réunion à enregistrer : on attend souvent
/// plusieurs minutes qu'un client arrive, et cette conversation-là n'a rien à
/// faire dans un fichier. La détection sert donc à *proposer*, jamais à
/// déclencher.
@MainActor
final class NotificationService: NSObject {

    // `nonisolated` : les callbacks de UNUserNotificationCenterDelegate
    // arrivent hors du main actor et doivent pouvoir comparer ces identifiants.
    nonisolated static let meetingCategory = "bran.meeting.detected"
    nonisolated static let startAction = "bran.action.start"
    nonisolated static let ignoreAction = "bran.action.ignore"

    /// Appelé quand l'utilisateur choisit « Démarrer » depuis la notification.
    var onStartRequested: (@MainActor () -> Void)?

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

        Task {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
    }

    func proposeRecording(title: String?) {
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
        center.add(request)
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
