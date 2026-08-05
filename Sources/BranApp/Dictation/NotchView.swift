import SwiftUI

/// L'animation de l'encoche.
///
/// Contrainte de performance, pas de goût : la forme d'onde ne doit **pas**
/// repasser par l'arbre de vues SwiftUI à chaque image. Un `@Observable` mis à
/// jour soixante fois par seconde recalcule tout le sous-arbre soixante fois par
/// seconde, pendant que le Neural Engine a autre chose à faire. On dessine donc
/// dans un `Canvas`, à l'intérieur d'un `TimelineView` : le dessin se refait,
/// l'arbre de vues non.
struct NotchView: View {

    /// Débordement de part et d'autre du trou. C'est lui qui donne l'effet
    /// « l'encoche s'ouvre » plutôt que « un rectangle apparaît ».
    static let earWidth: CGFloat = 74
    static let dropHeight: CGFloat = 22

    @Bindable var content: NotchContent
    let hasNotch: Bool
    let notchWidth: CGFloat

    var body: some View {
        ZStack {
            shape
                .fill(.black)
                .overlay(shape.stroke(.white.opacity(0.09), lineWidth: 0.5))
                .shadow(color: .black.opacity(hasNotch ? 0 : 0.35), radius: 12, y: 4)

            HStack(spacing: 10) {
                indicator
                waveform
                trailing
            }
            .padding(.horizontal, hasNotch ? 14 : 12)
            // Avec encoche, le contenu vit dans la partie basse : le haut est
            // occupé par le trou physique.
            .padding(.top, hasNotch ? Self.dropHeight * 0.4 : 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: hasNotch ? .bottom : .center)
        }
        .animation(.smooth(duration: 0.28), value: content.mode)
    }

    private var shape: some Shape {
        hasNotch
            ? AnyShape(NotchShape(notchWidth: notchWidth, dropHeight: Self.dropHeight))
            : AnyShape(RoundedRectangle(cornerRadius: 21, style: .continuous))
    }

    // MARK: - Pièces

    @ViewBuilder
    private var indicator: some View {
        switch content.mode {
        case .listening:
            Circle()
                .fill(.red)
                .frame(width: 7, height: 7)
                .modifier(BreathingDot())
        case .transcribing:
            ProgressView()
                .controlSize(.mini)
                .tint(.white)
        case .done:
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.green)
        case .empty:
            Image(systemName: "waveform.slash")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
        case .cancelled:
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var waveform: some View {
        if case .listening = content.mode {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
                Canvas { context, size in
                    Self.drawBars(content.levels, in: context, size: size)
                }
            }
            .frame(width: hasNotch ? 68 : 96, height: 16)
        } else {
            Text(label)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: hasNotch ? 92 : 140, alignment: .leading)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if case .listening = content.mode {
            Text(Self.clock(content.elapsed))
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.75))
        }
    }

    private var label: String {
        switch content.mode {
        case .listening: ""
        case .transcribing: "Transcription…"
        case .done(let text): text
        case .empty: "Rien entendu"
        case .cancelled: "Annulé"
        case .failed(let reason): reason
        }
    }

    // MARK: - Dessin

    /// Barres symétriques autour de l'axe, les plus récentes à droite.
    ///
    /// Racine carrée du niveau plutôt que le niveau brut : la voix parlée occupe
    /// le bas de l'échelle, et sans cette correction la forme d'onde reste
    /// plate tant qu'on ne crie pas.
    private static func drawBars(_ levels: [Float], in context: GraphicsContext, size: CGSize) {
        guard levels.isEmpty == false else { return }

        let count = min(levels.count, 28)
        let recent = Array(levels.suffix(count))
        let slot = size.width / CGFloat(count)
        let barWidth = max(1.5, slot * 0.55)

        for (index, level) in recent.enumerated() {
            let boosted = CGFloat(min(1, (level * 9).squareRoot()))
            let height = max(2, boosted * size.height)
            let x = CGFloat(index) * slot + (slot - barWidth) / 2
            let rect = CGRect(x: x, y: (size.height - height) / 2, width: barWidth, height: height)

            // Les barres les plus anciennes s'effacent : le regard va vers le
            // présent sans qu'on ait à animer quoi que ce soit.
            let freshness = 0.35 + 0.65 * (Double(index) / Double(max(1, count - 1)))
            context.fill(
                Path(roundedRect: rect, cornerRadius: barWidth / 2),
                with: .color(.white.opacity(freshness))
            )
        }
    }

    private static func clock(_ interval: TimeInterval) -> String {
        let seconds = Int(interval)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// Le contour qui prolonge l'encoche : deux oreilles concaves à gauche et à
/// droite du trou, puis un bandeau arrondi qui descend. C'est la concavité qui
/// fait croire que le matériel s'étire ; sans elle on voit un rectangle collé
/// sous une encoche.
private struct NotchShape: Shape {
    let notchWidth: CGFloat
    let dropHeight: CGFloat

    func path(in rect: CGRect) -> Path {
        let radius: CGFloat = 12
        let ear = (rect.width - notchWidth) / 2
        var path = Path()

        path.move(to: CGPoint(x: 0, y: 0))

        // Oreille gauche : concave vers l'intérieur.
        path.addQuadCurve(
            to: CGPoint(x: ear, y: radius),
            control: CGPoint(x: ear, y: 0)
        )

        path.addLine(to: CGPoint(x: ear, y: rect.height - radius))
        path.addQuadCurve(
            to: CGPoint(x: ear + radius, y: rect.height),
            control: CGPoint(x: ear, y: rect.height)
        )

        path.addLine(to: CGPoint(x: rect.width - ear - radius, y: rect.height))
        path.addQuadCurve(
            to: CGPoint(x: rect.width - ear, y: rect.height - radius),
            control: CGPoint(x: rect.width - ear, y: rect.height)
        )

        path.addLine(to: CGPoint(x: rect.width - ear, y: radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.width, y: 0),
            control: CGPoint(x: rect.width - ear, y: 0)
        )

        path.closeSubpath()
        return path
    }
}

/// Le point rouge qui respire. Une seule animation, portée par la vue elle-même
/// plutôt que pilotée depuis le contrôleur.
private struct BreathingDot: ViewModifier {
    @State private var isDim = false

    func body(content: Content) -> some View {
        content
            .opacity(isDim ? 0.35 : 1)
            .animation(.easeInOut(duration: 0.75).repeatForever(autoreverses: true), value: isDim)
            .onAppear { isDim = true }
    }
}
