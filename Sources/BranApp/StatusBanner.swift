import SwiftUI

/// Le bandeau de la bibliothèque.
///
/// **Il n'est instancié que dans deux situations** — une réunion proposée, ou un
/// échec à lire — et pendant un enregistrement ni l'une ni l'autre n'est vraie.
/// Les trois quarts du bandeau décrivaient donc des états qu'il n'a jamais vus :
/// un bouton « Arrêter », des intitulés « Enregistrement · … », « En pause »,
/// « Démarrage… », « Finalisation ». Tout cela est parti ; ce qui reste est
/// exactement ce qui s'affiche.
struct StatusBanner: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: Space.small) {
            Circle()
                .fill(indicatorColor)
                .frame(width: 9, height: 9)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Space.line) {
                Text(headline)
                    .font(Type.groupHead)
                Text(subline)
                    .font(Type.meta)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: Space.small)

            action
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(headline). \(subline)")
    }

    @ViewBuilder
    private var action: some View {
        if model.pendingMeeting != nil {
            Button("Enregistrer") { model.startPendingRecording() }
                .buttonStyle(.borderedProminent)
        } else {
            Button("Démarrer") { model.startManualRecording() }
                .disabled(model.permissions.canRecord == false)
        }
    }

    private var headline: String {
        model.pendingMeeting != nil ? "Réunion détectée" : "Échec"
    }

    /// **Une réunion détectée passe devant un échec passé.**
    ///
    /// L'échec était testé en premier et sortait aussitôt. Or `lastFailure` est
    /// rémanent : un problème réseau à 10 h masquait à 14 h la seule chose qu'on
    /// veut lire avant d'appuyer sur « Enregistrer » — à quel rendez-vous du CRM
    /// cette réunion est rattachée. Le titre disait « Réunion détectée » et la
    /// ligne du dessous parlait d'autre chose, ce que personne ne relit deux
    /// fois avant de cliquer.
    ///
    /// L'échec n'est pas perdu : sans réunion détectée, le bandeau est
    /// justement là pour lui, et le titre le dit.
    private var subline: String {
        if model.pendingMeeting == nil, let failure = model.lastFailure { return failure }

        if let booking = model.linkedBooking {
            return "Rattaché à « \(booking.displayName) » — rien n'est enregistré tant que vous ne l'avez pas demandé."
        }
        return "Réunion non reconnue par le CRM. Rien n'est enregistré tant que vous ne l'avez pas demandé."
    }

    /// Une proposition n'est pas un état de la machine : elle porte l'accent
    /// système, comme tout ce qui attend une décision.
    private var indicatorColor: Color {
        model.pendingMeeting != nil ? .accentColor : Palette.attention
    }
}
