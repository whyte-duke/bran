import Foundation

/// Les blocs facultatifs du menu de la barre des menus.
///
/// Les alertes et les commandes d'une opération en cours ne consultent jamais
/// ces préférences : masquer « Enregistrement » au repos ne doit pas faire
/// disparaître le bouton d'arrêt une fois une capture lancée.
enum MenuBarPreferences {
    static let showsHistoryKey = "bran.menu.showsHistory"
    static let showsUpcomingMeetingKey = "bran.menu.showsUpcomingMeeting"
    static let showsAwakeKey = "bran.menu.showsAwake"
    static let showsSpeedKey = "bran.menu.showsSpeed"
    static let showsRecordingKey = "bran.menu.showsRecording"
    static let showsUpdatesKey = "bran.menu.showsUpdates"
}
