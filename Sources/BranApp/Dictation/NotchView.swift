import SwiftUI

/// L'animation de l'encoche.
///
/// Deux exigences qui tirent dans des sens opposés :
///
/// - **elle doit être belle.** C'est la seule chose qu'on regarde en dictant, et
///   elle apparaît vingt fois par heure. Une apparition sèche fatigue en une
///   journée ; une apparition qui s'ouvre depuis le trou physique donne
///   l'impression que le matériel réagit ;
/// - **elle ne doit rien coûter.** Un `@Observable` mis à jour soixante fois par
///   seconde recalcule tout le sous-arbre soixante fois par seconde, pendant que
///   le Neural Engine travaille. On dessine donc dans un `Canvas` à l'intérieur
///   d'un `TimelineView` : le tracé se refait, l'arbre de vues non.
///
/// L'ouverture est jouée par un ressort sur la **largeur** : le panneau part de
/// la largeur exacte de l'encoche — où il est invisible, noir sur noir — et
/// s'étire vers les côtés. Sur un écran sans encoche, la pilule monte et grandit
/// depuis la barre de menus.
struct NotchView: View {

    /// Débordement de part et d'autre du trou. C'est lui qui donne l'effet
    /// « l'encoche s'ouvre » plutôt que « un rectangle apparaît ».
    static let earWidth: CGFloat = 92
    static let dropHeight: CGFloat = 30

    static let pillSize = CGSize(width: 320, height: 54)

    @Bindable var content: NotchContent
    let hasNotch: Bool
    let notchWidth: CGFloat

    /// Pilote toute l'animation d'entrée. Passé à `true` juste après
    /// l'apparition, pour que le premier rendu soit l'état fermé.
    @State private var isOpen = false

    var body: some View {
        ZStack {
            shape
                .fill(.black)
                .overlay(shape.stroke(.white.opacity(isOpen ? 0.10 : 0), lineWidth: 0.5))
                .shadow(color: .black.opacity(hasNotch ? 0 : 0.4), radius: 16, y: 6)

            HStack(spacing: 11) {
                indicator
                middle
                trailing
            }
            .padding(.horizontal, hasNotch ? 18 : 16)
            .padding(.top, hasNotch ? Self.dropHeight * 0.45 : 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: hasNotch ? .bottom : .center)
            // Le contenu arrive après le contenant : d'abord le panneau s'ouvre,
            // ensuite le texte se pose. Dans l'autre sens, on voit le texte
            // déborder du cadre pendant deux images.
            .opacity(isOpen ? 1 : 0)
            .blur(radius: isOpen ? 0 : 3)
            .scaleEffect(isOpen ? 1 : 0.92)
            .animation(.smooth(duration: 0.3).delay(isOpen ? 0.09 : 0), value: isOpen)
        }
        // Sans encoche, la pilule descend de la barre de menus au lieu
        // d'apparaître au milieu de nulle part.
        .offset(y: hasNotch ? 0 : (isOpen ? 0 : -14))
        .scaleEffect(hasNotch ? 1 : (isOpen ? 1 : 0.86), anchor: .top)
        .opacity(hasNotch ? 1 : (isOpen ? 1 : 0))
        .animation(Self.opening, value: isOpen)
        .animation(.smooth(duration: 0.32), value: content.mode)
        .onAppear { isOpen = true }
        .onChange(of: content.isExpanded) { _, expanded in isOpen = expanded }
    }

    /// Un ressort franc mais peu rebondissant : assez vivant pour se remarquer,
    /// assez sobre pour être vu vingt fois par heure.
    private static let opening = Animation.spring(response: 0.42, dampingFraction: 0.74)

    private var shape: some Shape {
        hasNotch
            ? AnyShape(NotchShape(
                notchWidth: notchWidth,
                dropHeight: Self.dropHeight,
                openness: isOpen ? 1 : 0
            ))
            : AnyShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    // MARK: - Pièces

    @ViewBuilder
    private var indicator: some View {
        switch content.mode {
        case .listening:
            PulsingDot()
        case .transcribing:
            ProgressView()
                .controlSize(.small)
                .tint(.white)
                .scaleEffect(0.8)
        case .done:
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.green)
                .transition(.scale.combined(with: .opacity))
        case .empty:
            Image(systemName: "waveform.slash")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
        case .cancelled:
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.5))
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var middle: some View {
        if case .listening = content.mode {
            TimelineView(.animation(minimumInterval: 1.0 / 40)) { timeline in
                Canvas { context, size in
                    WaveformDrawing.draw(
                        content.levels,
                        phase: timeline.date.timeIntervalSinceReferenceDate,
                        in: context,
                        size: size
                    )
                }
            }
            .frame(width: hasNotch ? 92 : 130, height: 22)
        } else {
            Text(label)
                .font(.system(size: 11.5, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.93))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: hasNotch ? 120 : 180, alignment: .leading)
                .transition(.opacity.combined(with: .offset(y: 3)))
                .id(label)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if case .listening = content.mode {
            Text(Self.clock(content.elapsed))
                .font(.system(size: 11.5, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.6))
                .contentTransition(.numericText())
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

    private static func clock(_ interval: TimeInterval) -> String {
        let seconds = Int(interval)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

// MARK: - La vague

/// Le tracé de la forme d'onde.
///
/// Une **vague pleine et symétrique**, pas des barres. Les barres sautent d'une
/// image à l'autre parce que chaque valeur est indépendante de sa voisine ; une
/// courbe lissée sur ses voisines glisse au lieu de clignoter, et c'est
/// exactement la différence entre « ça marche » et « c'est joli ».
///
/// ```
///        ╭─╮   ╭──╮
///   ╭────╯ ╰───╯  ╰──╮        ← enveloppe haute (voix)
///   ──────────────────        ← axe
///   ╰────╮ ╭───╮  ╭──╯        ← miroir exact
///        ╰─╯   ╰──╯
/// ```
enum WaveformDrawing {

    /// Nombre de points tracés. Moins que les 56 emplacements capturés : on
    /// dessine les deux dernières secondes, pas la séance.
    private static let points = 30

    static func draw(_ levels: [Float], phase: TimeInterval, in context: GraphicsContext, size: CGSize) {
        let amplitudes = envelope(from: levels, phase: phase)
        guard amplitudes.count > 1 else { return }

        let step = size.width / CGFloat(amplitudes.count - 1)
        let middle = size.height / 2
        let maxAmplitude = size.height / 2 - 1

        var path = Path()

        // Bord supérieur, en courbes passant par les milieux : c'est ce qui
        // supprime les angles sans avoir à calculer de vraies splines.
        path.move(to: CGPoint(x: 0, y: middle - CGFloat(amplitudes[0]) * maxAmplitude))
        for index in 1..<amplitudes.count {
            let previous = CGPoint(
                x: CGFloat(index - 1) * step,
                y: middle - CGFloat(amplitudes[index - 1]) * maxAmplitude
            )
            let current = CGPoint(
                x: CGFloat(index) * step,
                y: middle - CGFloat(amplitudes[index]) * maxAmplitude
            )
            let midpoint = CGPoint(x: (previous.x + current.x) / 2, y: (previous.y + current.y) / 2)
            path.addQuadCurve(to: midpoint, control: previous)
            if index == amplitudes.count - 1 { path.addLine(to: current) }
        }

        // Bord inférieur : le miroir, parcouru à l'envers.
        for index in stride(from: amplitudes.count - 1, through: 0, by: -1) {
            let current = CGPoint(
                x: CGFloat(index) * step,
                y: middle + CGFloat(amplitudes[index]) * maxAmplitude
            )
            if index == amplitudes.count - 1 {
                path.addLine(to: current)
                continue
            }
            let next = CGPoint(
                x: CGFloat(index + 1) * step,
                y: middle + CGFloat(amplitudes[index + 1]) * maxAmplitude
            )
            let midpoint = CGPoint(x: (next.x + current.x) / 2, y: (next.y + current.y) / 2)
            path.addQuadCurve(to: midpoint, control: next)
        }
        path.closeSubpath()

        // Dégradé horizontal : le passé s'efface, le présent est net. Le regard
        // va vers la droite sans qu'on ait à animer quoi que ce soit.
        context.fill(
            path,
            with: .linearGradient(
                Gradient(colors: [.white.opacity(0.22), .white.opacity(0.55), .white.opacity(0.95)]),
                startPoint: .zero,
                endPoint: CGPoint(x: size.width, y: 0)
            )
        )
    }

    /// Transforme les niveaux bruts en une enveloppe lissée, de 0 à 1.
    ///
    /// Trois corrections, chacune pour une raison observable :
    /// - **racine carrée** : la voix parlée occupe le bas de l'échelle, et sans
    ///   ça la vague reste plate tant qu'on ne crie pas ;
    /// - **lissage sur trois voisins** : supprime le tremblement image par image ;
    /// - **plancher qui respire** : au silence, une vague parfaitement plate a
    ///   l'air d'un plantage. Une ondulation lente dit « j'écoute, tu ne parles
    ///   simplement pas ».
    private static func envelope(from levels: [Float], phase: TimeInterval) -> [Float] {
        guard levels.isEmpty == false else { return [] }

        let recent = Array(levels.suffix(points))
        guard recent.count > 2 else { return recent }

        var boosted = recent.map { min(1, ($0 * 11).squareRoot()) }

        var smoothed = boosted
        for index in 1..<(boosted.count - 1) {
            smoothed[index] = boosted[index - 1] * 0.25 + boosted[index] * 0.5 + boosted[index + 1] * 0.25
        }
        boosted = smoothed

        return boosted.enumerated().map { index, value in
            // Atténuation aux extrémités : la vague s'affine au lieu d'être
            // coupée net par le bord du cadre.
            let position = Double(index) / Double(max(1, boosted.count - 1))
            let taper = Float(sin(position * .pi).squareRoot())

            let breathing = Float(0.055 + 0.035 * sin(phase * 2.1 + Double(index) * 0.42))
            return max(value, breathing) * taper
        }
    }
}

// MARK: - Formes

/// Le contour qui prolonge l'encoche.
///
/// `openness` va de 0 — le tracé épouse exactement le trou physique, donc
/// invisible, noir sur noir — à 1, où les oreilles sont sorties de chaque côté.
/// Animer ce nombre suffit à donner l'impression que l'encoche s'ouvre, sans
/// jamais redimensionner la fenêtre, ce qui saccaderait.
private struct NotchShape: Shape {
    let notchWidth: CGFloat
    let dropHeight: CGFloat
    var openness: CGFloat

    /// Rend `openness` interpolable : sans ça, SwiftUI passerait de 0 à 1 d'un
    /// coup et toute l'animation d'ouverture disparaîtrait.
    var animatableData: CGFloat {
        get { openness }
        set { openness = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let fullEar = (rect.width - notchWidth) / 2
        let ear = fullEar * (1 - openness)
        let height = rect.height * (0.55 + 0.45 * openness)
        let radius = 14 * openness + 2

        var path = Path()
        path.move(to: CGPoint(x: ear, y: 0))

        // Oreille gauche, concave : c'est cette courbe rentrante qui raccorde
        // le panneau au trou. Sans elle, on voit un rectangle collé dessous.
        path.addQuadCurve(
            to: CGPoint(x: ear + fullEar * openness, y: radius),
            control: CGPoint(x: ear + fullEar * openness, y: 0)
        )

        path.addLine(to: CGPoint(x: ear + fullEar * openness, y: height - radius))
        path.addQuadCurve(
            to: CGPoint(x: ear + fullEar * openness + radius, y: height),
            control: CGPoint(x: ear + fullEar * openness, y: height)
        )

        path.addLine(to: CGPoint(x: rect.width - ear - fullEar * openness - radius, y: height))
        path.addQuadCurve(
            to: CGPoint(x: rect.width - ear - fullEar * openness, y: height - radius),
            control: CGPoint(x: rect.width - ear - fullEar * openness, y: height)
        )

        path.addLine(to: CGPoint(x: rect.width - ear - fullEar * openness, y: radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.width - ear, y: 0),
            control: CGPoint(x: rect.width - ear - fullEar * openness, y: 0)
        )

        path.closeSubpath()
        return path
    }
}

/// Le point rouge qui respire.
///
/// Portée par la vue elle-même plutôt que pilotée depuis le contrôleur : une
/// animation en boucle n'a aucune raison de traverser trois couches.
private struct PulsingDot: View {
    @State private var isPulsing = false

    var body: some View {
        ZStack {
            Circle()
                .fill(.red.opacity(0.35))
                .frame(width: 16, height: 16)
                .scaleEffect(isPulsing ? 1 : 0.45)
                .opacity(isPulsing ? 0 : 0.9)

            Circle()
                .fill(.red)
                .frame(width: 7, height: 7)
        }
        .animation(.easeOut(duration: 1.25).repeatForever(autoreverses: false), value: isPulsing)
        .onAppear { isPulsing = true }
        .frame(width: 16, height: 16)
    }
}
