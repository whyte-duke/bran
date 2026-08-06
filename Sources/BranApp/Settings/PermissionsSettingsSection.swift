import AppKit
import Combine
import SwiftUI

/// Les autorisations, avec de quoi les accorder.
///
/// **Ce que l'ancienne version ne faisait pas.** Les réglages réduisaient trois
/// états à deux — « accordée » ou « manquante » — et n'offraient aucun bouton :
/// on apprenait qu'il manquait quelque chose sans pouvoir y remédier, alors que
/// l'accueil savait le faire depuis toujours. Cet onglet réutilise la même
/// `CapabilityCard` que l'accueil, avec le même vocabulaire d'états.
///
/// La distinction qui compte est entre « pas encore demandée » et « refusée » :
/// dans le premier cas macOS affichera sa fenêtre, dans le second il ne dira
/// plus rien et le seul recours est le panneau des Réglages système. C'est
/// exactement l'arbitrage que `SystemSettings.reRequest…` fait pour nous.
struct PermissionsSettingsSection: View {
    @Bindable var model: AppModel

    private var permissions: PermissionsService { model.permissions }

    /// L'Accessibilité n'a pas d'observateur : elle se coche dans les Réglages
    /// système, sans que l'application en soit informée. On la relit au retour
    /// dans l'app, sinon l'écran continue de réclamer ce qui vient d'être donné.
    @State private var isAccessibilityTrusted = HotkeyMonitor.isTrusted
    /// L'écran déclaré accordé peut ne rien voir — autorisation liée à une
    /// signature périmée. Sonder coûte un appel système : on ne le fait qu'aux
    /// moments où l'état a pu changer.
    @State private var seesScreen = ScreenAccess.isUsable

    var body: some View {
        Section("Autorisations") {
            VStack(spacing: Space.small) {
                screen
                microphone
                accessibility
                calendar
            }
            .padding(.vertical, Space.tight)

            if permissions.screenRecording != .granted {
                Label(
                    "L'autorisation d'enregistrement d'écran n'est prise en compte qu'au prochain démarrage. Quittez et relancez bran après l'avoir accordée.",
                    systemImage: "arrow.clockwise"
                )
                .font(Type.meta)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Text("Rien ne quitte cette machine. Aucun compte, aucun envoi.")
                    .font(Type.meta)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Revérifier", action: refresh)
            }
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
    }

    private func refresh() {
        permissions.refresh()
        isAccessibilityTrusted = HotkeyMonitor.isTrusted
        seesScreen = ScreenAccess.isUsable
    }

    // MARK: - Les quatre cases du système

    private var screen: some View {
        CapabilityCard(
            index: 0,
            symbol: "rectangle.inset.filled.and.person.filled",
            title: "Enregistrement de l'écran",
            gesture: "Enregistrer une réunion, capturer du texte à l'écran, repérer une fenêtre qui vous attend.",
            state: screenState
        ) {
            if screenState.isReady == false {
                Button("Autoriser") {
                    _ = SystemSettings.reRequestScreenRecording()
                    refresh()
                }
            }
        }
    }

    /// Trois états, dont un que `PermissionsService` ne connaît pas : cochée
    /// mais aveugle. `ScreenAccess` est la seule sonde qui le voit.
    private var screenState: CapabilityState {
        guard permissions.screenRecording == .granted else {
            return permissions.screenRecording == .denied
                ? .refused("Refusée — à cocher dans les Réglages système")
                : .todo("Pas encore demandée")
        }
        guard seesScreen else {
            return .refused("Cochée, mais accordée à une version antérieure de bran")
        }
        return .ready("Accordée")
    }

    private var microphone: some View {
        CapabilityCard(
            index: 1,
            symbol: "mic",
            title: "Microphone",
            gesture: "Votre voix : dans une réunion enregistrée, et pour la dictée.",
            state: state(permissions.microphone)
        ) {
            if permissions.microphone != .granted {
                Button("Autoriser") {
                    Task {
                        _ = await SystemSettings.reRequestMicrophone()
                        refresh()
                    }
                }
            }
        }
    }

    private var accessibility: some View {
        CapabilityCard(
            index: 2,
            symbol: "keyboard",
            title: "Accessibilité",
            gesture: "Écouter les raccourcis globaux et coller le texte dicté là où était le curseur.",
            // Elle n'a pas d'état « refusée » observable : le système ne dit que
            // oui ou non, jamais pourquoi. Le bouton mène au bon panneau dans
            // les deux cas, ce qui rend la nuance sans conséquence.
            state: isAccessibilityTrusted
                ? .ready("Accordée")
                : .todo("À cocher dans les Réglages système")
        ) {
            if isAccessibilityTrusted == false {
                Button("Autoriser") {
                    _ = SystemSettings.reRequestAccessibility()
                    refresh()
                }
            }
        }
    }

    private var calendar: some View {
        CapabilityCard(
            index: 3,
            symbol: "calendar",
            title: "Calendrier",
            gesture: "Facultatif : donne son nom à l'enregistrement plutôt qu'une date.",
            state: state(permissions.calendar)
        ) {
            switch permissions.calendar {
            case .granted:
                EmptyView()
            case .denied:
                Button("Ouvrir les Réglages") { SystemSettings.open(.calendar) }
                    .controlSize(.small)
            case .notDetermined:
                Button("Autoriser") {
                    Task {
                        await permissions.requestCalendar()
                        refresh()
                    }
                }
                .controlSize(.small)
            }
        }
    }

    private func state(_ access: PermissionsService.Access) -> CapabilityState {
        switch access {
        case .granted: .ready("Accordée")
        case .denied: .refused("Refusée — à rouvrir dans les Réglages système")
        case .notDetermined: .todo("Pas encore demandée")
        }
    }
}
