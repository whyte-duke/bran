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

    /// La largeur de la **fenêtre**, la même pour tous les écrans et tous les
    /// contenus. Voir `NotchOverlay.geometry(of:)` : c'est ce qui permet de ne
    /// plus jamais redimensionner le panneau, donc de ne plus jamais remplacer
    /// sa `rootView`. Large de quoi loger l'encoche la plus large d'un MacBook
    /// avec ses deux oreilles, et n'importe quel contenu à venir.
    static let maximumWidth: CGFloat = 460

    /// De la place sous le contenu, pour que l'ombre de la pilule ne soit pas
    /// coupée par le bord de la fenêtre.
    static let verticalSlack: CGFloat = 24

    @Bindable var content: NotchContent
    let hasNotch: Bool
    let notchWidth: CGFloat
    let notchHeight: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// La taille du **contenu**, qui n'est pas celle de la fenêtre.
    private var contentSize: CGSize {
        hasNotch
            ? CGSize(width: notchWidth + 2 * Self.earWidth, height: notchHeight + Self.dropHeight)
            : Self.pillSize
    }

    /// Pilote toute l'animation d'entrée. Passé à `true` juste après
    /// l'apparition, pour que le premier rendu soit l'état fermé.
    @State private var isOpen = false

    var body: some View {
        ZStack {
            shape
                .fill(.black)
                .overlay(shape.stroke(isOpen ? NotchInk.edge : .clear, lineWidth: 0.5))
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
            .branAnimation(
                Motion.notchContent.delay(isOpen ? Motion.notchContentDelay : 0),
                value: isOpen
            )
        }
        // Le contenu a sa taille propre, calée en haut d'une fenêtre plus
        // grande et fixe. C'est ce découplage qui permet à la fenêtre de ne
        // jamais bouger pendant qu'un contenu plus large s'anime dedans.
        .frame(width: contentSize.width, height: contentSize.height)
        // Sans encoche, la pilule descend de la barre de menus au lieu
        // d'apparaître au milieu de nulle part.
        .offset(y: hasNotch ? 0 : (isOpen ? 0 : -14))
        .scaleEffect(hasNotch ? 1 : (isOpen ? 1 : 0.86), anchor: .top)
        .opacity(hasNotch ? 1 : (isOpen ? 1 : 0))
        .branAnimation(Motion.notch, value: isOpen)
        .branAnimation(Motion.state, value: content.mode)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { isOpen = true }
        .onChange(of: content.isExpanded) { _, expanded in isOpen = expanded }
    }

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
        case .idle:
            // Rien : le panneau ne devrait pas être visible dans cet état, et
            // s'il l'est, mieux vaut un panneau muet qu'une dictée inventée.
            EmptyView()
        case .listening:
            PulsingDot()
        case .transcribing, .pasting, .copying:
            // Le même rouet pour les trois : ce que l'utilisateur doit lire,
            // c'est « ça travaille, ne touche à rien ». Le texte à côté dit
            // laquelle des trois.
            ProgressView()
                .controlSize(.small)
                .tint(.white)
                .scaleEffect(0.8)
        case .done, .captured:
            Image(systemName: "checkmark")
                .font(Type.notch.weight(.bold))
                .foregroundStyle(Palette.done)
                .transition(.scale.combined(with: .opacity))
        case .preparing:
            Image(systemName: "cpu")
                .font(Type.notch.weight(.semibold))
                .foregroundStyle(NotchInk.symbolFaint)
                // `.symbolEffect(.pulse, options: .repeating)` est une boucle
                // perpétuelle de plus, et celle-là est jouée par SwiftUI, pas
                // par nous : `branLoop` ne l'atteint pas. On la conditionne donc
                // à la main, comme les deux autres.
                .symbolEffect(.pulse, options: .repeating, isActive: reduceMotion == false)
        case .reading:
            Image(systemName: "text.viewfinder")
                .font(Type.notch.weight(.semibold))
                .foregroundStyle(NotchInk.symbol)
        case .handedOver:
            // Pas la coche : rien n'est collé. Le presse-papiers, et une
            // couleur qui demande qu'on s'en occupe — l'utilisateur a un geste
            // à faire, et s'il ne le fait pas le texte partira avec la dictée
            // suivante.
            Image(systemName: "doc.on.clipboard")
                .font(Type.notch.weight(.semibold))
                .foregroundStyle(Palette.attention)
        case .empty:
            Image(systemName: content.source == .snapshot ? "text.badge.xmark" : "waveform.slash")
                .font(Type.notch.weight(.semibold))
                .foregroundStyle(NotchInk.symbolMuted)
        case .cancelled:
            Image(systemName: "xmark")
                .font(Type.notch.weight(.bold))
                .foregroundStyle(NotchInk.symbolMuted)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(Type.notch.weight(.bold))
                .foregroundStyle(Palette.attention)
        }
    }

    @ViewBuilder
    private var middle: some View {
        if case .listening = content.mode {
            // `content.levels` est lu **ici**, dans le corps de la vue, et passé
            // comme simple tableau. Voir `AnimatedStripe` pour pourquoi.
            AnimatedStripe(levels: content.levels, kind: .waveform)
                .frame(width: hasNotch ? 92 : 130, height: 22)
        } else if case .reading = content.mode {
            AnimatedStripe(levels: [], kind: .scan)
                .frame(width: hasNotch ? 92 : 130, height: 22)
        } else if case .preparing(let fraction) = content.mode {
            LoadingBar(fraction: fraction)
                .frame(width: hasNotch ? 92 : 130, height: 22)
        } else {
            Text(label)
                .font(Type.notch)
                .foregroundStyle(NotchInk.text)
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
                .font(Type.notch)
                .monospacedDigit()
                .foregroundStyle(NotchInk.value)
                .contentTransition(.numericText())
        } else if case .preparing(let fraction) = content.mode, let fraction {
            Text("\(Int(fraction * 100)) %")
                .font(Type.notch)
                .monospacedDigit()
                .foregroundStyle(NotchInk.value)
                .contentTransition(.numericText())
        }
    }

    private var label: String {
        switch content.mode {
        case .idle: ""
        case .listening: ""
        case .transcribing: "Transcription…"
        // Les points de suspension font tout le travail : ils disent que c'est
        // en train de se faire, là où « Dictée collée » disait que c'était fait.
        case .pasting: "Collage…"
        case .done(let text): text
        case .preparing: ""
        case .reading: ""
        case .copying: "Copie…"
        case .captured(let text): text
        // Court, parce que l'encoche fait cent vingt points de large et qu'une
        // instruction tronquée n'est plus une instruction. La phrase entière est
        // dans le panneau de la fonction — voir `Paster.fallbackNotice` — et
        // dans l'annonce VoiceOver.
        case .handedOver: "⌘V pour coller"
        case .empty: content.source == .snapshot ? "Aucun texte trouvé" : "Rien entendu"
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

/// La bande animée de l'encoche : la vague de la dictée, ou le balayage de
/// lecture.
///
/// **Pourquoi l'horloge est ici et pas dans un `TimelineView`.** C'est la
/// correction d'un plantage systématique, pas une préférence de style. La
/// version précédente dessinait dans un `TimelineView(.animation)`, ce qui est
/// pourtant la façon recommandée. Elle tombait à chaque appui sur le raccourci
/// de dictée :
///
/// ```
///   libswiftCore          swift_getObjectType          ← EXC_BAD_ACCESS
///   libswift_Concurrency  swift_task_isMainExecutorImpl
///   libswift_Concurrency  swift_task_isCurrentExecutorWithFlags
///   bran                  closure #1 in AnimatedStripe.body.getter
///   SwiftUI               TimelineView.init(_:content:)
/// ```
///
/// La closure de contenu d'un `TimelineView` est déclarée `@MainActor
/// @preconcurrency` : le compilateur pose une **vérification d'isolation à
/// l'exécution** à son entrée, exécutée à chaque image. Quand l'encoche était
/// posée depuis le callback du `CGEventTap` — donc hors de toute tâche — cette
/// vérification prenait le chemin lent du runtime et déréférençait un exécuteur
/// invalide.
///
/// **La vraie correction est dans `HotkeyMonitor.receive`**, qui ne pose plus
/// l'encoche depuis le callback. Ce qui est fait ici est une ceinture, pas la
/// bretelle : la closure de `Canvas` porte exactement la même vérification —
/// vérifié dans le binaire — et n'a donc pas disparu. Ce qui disparaît, c'est
/// le chemin précis où le processus est tombé quatre fois de suite,
/// `Attribute.syncMainIfReferences` → `TimelineView`, distinct de celui du
/// rendu.
///
/// Ce qu'on y perd : `TimelineView` se cale sur le rafraîchissement de l'écran,
/// pas nous. À 40 Hz sur une bande de 92 points, la différence ne se voit pas.
private struct AnimatedStripe: View {
    enum Kind { case waveform, scan }

    let levels: [Float]
    let kind: Kind

    /// L'âge de l'animation, en secondes. Les deux tracés s'en servent comme
    /// d'une phase : la vague pour respirer au silence, le balayage pour savoir
    /// où en est son cycle.
    @State private var phase: TimeInterval = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let interval: Duration = .milliseconds(25)

    /// La phase figée du balayage, sous « Réduire les animations ».
    ///
    /// La moitié d'un cycle, pas zéro. À zéro la bande claire est collée au bord
    /// gauche et la vue se lit « bloqué au début » ; au milieu, elle se lit comme
    /// une illustration voulue.
    private static let stillScanPhase: TimeInterval = 0.7

    var body: some View {
        Canvas { context, size in
            switch kind {
            case .waveform:
                WaveformDrawing.draw(levels, phase: phase, in: context, size: size)
            case .scan:
                ScanDrawing.draw(
                    phase: reduceMotion ? Self.stillScanPhase : phase,
                    in: context,
                    size: size
                )
            }
        }
        // **L'horloge ne démarre pas du tout sous « Réduire les animations ».**
        // Couper l'animation n'aurait rien coûté de moins : cette boucle pousse
        // une phase quarante fois par seconde, et le `Canvas` se redessine à
        // chaque fois. Le réglage demande d'arrêter le mouvement, or ici le
        // mouvement *est* la boucle — la supprimer rend les deux, l'immobilité
        // et le processeur.
        //
        // La vague continue de suivre `levels`, et c'est voulu : elle répond à
        // ce que dit l'utilisateur, ce n'est pas de la décoration. Ce que la
        // phase pilote — la respiration au silence, le balayage — l'est.
        //
        // `.task` s'annule tout seul quand la vue disparaît : l'horloge ne
        // survit pas à l'encoche qu'elle anime.
        .task(id: reduceMotion) {
            guard reduceMotion == false else {
                phase = 0
                return
            }
            let started = ContinuousClock.now
            while Task.isCancelled == false {
                try? await Task.sleep(for: Self.interval)
                guard Task.isCancelled == false else { return }
                // Mesuré, pas accumulé : `Task.sleep` garantit un minimum, pas
                // une période. Additionner 25 ms à chaque tour ferait dériver
                // le balayage dès que la machine est chargée.
                phase = (ContinuousClock.now - started).seconds
            }
        }
    }
}

private extension Duration {
    /// La durée en secondes flottantes. `components` donne des entiers et des
    /// attosecondes ; on veut juste un nombre à mettre dans un sinus.
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) * 1e-18
    }
}

// MARK: - Le balayage de lecture

/// Le tracé pendant la reconnaissance de texte.
///
/// L'équivalent de la vague pour la dictée, et construit sur le même principe :
/// dessiné dans un `Canvas`, donc aucune reconstruction de l'arbre de vues.
///
/// Ce qu'il montre : quelques lignes de texte stylisées, et une bande claire qui
/// les traverse de gauche à droite. C'est la métaphore du scanner, et elle dit
/// deux choses d'un coup — « je lis une image » et « je travaille encore ».
///
/// ```
///   ▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁         ← lignes ternes
///   ▁▁▁▁▁▁▁███▁▁▁▁▁▁▁         ← la bande éclaire ce qu'elle traverse
///   ▁▁▁▁▁▁▁███▁▁▁▁▁
///   ▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁
///           →→→
/// ```
///
/// Une durée de cycle volontairement longue — 1,4 s — alors que la lecture
/// prend 200 à 350 ms : le balayage n'est presque jamais vu en entier, et c'est
/// voulu. Un cycle rapide donnerait une impression de fébrilité pour une
/// opération qui, elle, est immédiate.
enum ScanDrawing {

    /// Largeurs relatives des lignes, pour que ça ressemble à du texte et non à
    /// un code-barres.
    private static let lineWidths: [Double] = [0.95, 0.72, 0.88, 0.55]

    static func draw(phase: TimeInterval, in context: GraphicsContext, size: CGSize) {
        let cycle = 1.4
        let progress = (phase.truncatingRemainder(dividingBy: cycle)) / cycle
        let sweepX = size.width * progress
        let sweepWidth = size.width * 0.22

        let lineHeight = 2.0
        let spacing = (size.height - Double(lineWidths.count) * lineHeight) / Double(lineWidths.count + 1)

        for (index, width) in lineWidths.enumerated() {
            let y = spacing + Double(index) * (lineHeight + spacing)
            let rect = CGRect(x: 0, y: y, width: size.width * width, height: lineHeight)
            let line = Path(roundedRect: rect, cornerRadius: lineHeight / 2)

            context.fill(line, with: .color(.white.opacity(0.20)))

            // La portion éclairée : on découpe la bande dans le tracé de la
            // ligne plutôt que de dessiner un rectangle par-dessus, sinon la
            // lumière déborderait des lignes courtes.
            var illuminated = context
            illuminated.clip(to: line)
            illuminated.fill(
                Path(CGRect(x: sweepX - sweepWidth / 2, y: y - 1, width: sweepWidth, height: lineHeight + 2)),
                with: .linearGradient(
                    Gradient(colors: [.white.opacity(0), .white.opacity(0.95), .white.opacity(0)]),
                    startPoint: CGPoint(x: sweepX - sweepWidth / 2, y: 0),
                    endPoint: CGPoint(x: sweepX + sweepWidth / 2, y: 0)
                )
            )
        }
    }
}

/// La barre de chargement du moteur.
///
/// Deux comportements dans une seule vue, et la distinction compte : quand la
/// progression est connue on la montre, quand elle ne l'est pas on montre une
/// navette. Afficher une barre à zéro pendant qu'on ignore où on en est
/// donnerait l'impression que rien ne se passe.
private struct LoadingBar: View {
    let fraction: Double?

    @State private var shuttle = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(NotchInk.trough)

                if let fraction {
                    Capsule()
                        .fill(NotchInk.fill)
                        .frame(width: max(4, geometry.size.width * fraction))
                        .branAnimation(Motion.state, value: fraction)
                } else if reduceMotion {
                    // **Rien ne bouge, et il faut quand même dire qu'on
                    // travaille.** Une navette figée à gauche se lit comme une
                    // barre bloquée à 30 %, c'est-à-dire comme un plantage. Une
                    // barre pleine et atténuée dit « en cours, durée inconnue »
                    // sans prétendre connaître une progression.
                    Capsule()
                        .fill(NotchInk.trough)
                        .overlay(Capsule().fill(NotchInk.fill).opacity(0.45))
                } else {
                    Capsule()
                        .fill(NotchInk.fill)
                        .frame(width: geometry.size.width * 0.32)
                        .offset(x: shuttle ? geometry.size.width * 0.68 : 0)
                        .branLoop(Motion.shuttle, value: shuttle)
                }
            }
            .frame(height: 4)
            .frame(maxHeight: .infinity)
        }
        // Même correctif que `PulsingDot` : `onAppear` est à un coup et laissait
        // la navette immobile à gauche — précisément l'état que le commentaire
        // ci-dessus dit qu'il faut éviter — quand on désactivait le réglage sans
        // fermer l'encoche.
        .onChange(of: reduceMotion, initial: true) { _, reduced in
            shuttle = reduced == false
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
///
/// **Sous « Réduire les animations », le halo ne part pas.** Il reste posé,
/// discret, et la pastille pleine suffit à dire « ça écoute ». C'est la
/// différence entre supprimer un mouvement et supprimer une information : ici
/// l'information est la couleur rouge, pas la pulsation.
private struct PulsingDot: View {
    @State private var isPulsing = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .fill(Palette.live.opacity(0.35))
                .frame(width: 16, height: 16)
                .scaleEffect(pulses && isPulsing ? 1 : 0.45)
                .opacity(pulses ? (isPulsing ? 0 : 0.9) : 0.35)

            Circle()
                .fill(Palette.live)
                .frame(width: 7, height: 7)
        }
        .branLoop(Motion.pulse, value: isPulsing)
        // **`onChange(initial:)` et pas `onAppear`.** Le réglage d'accessibilité
        // peut basculer pendant que cette vue est vivante, et `onAppear` est à un
        // coup : la pulsation ne repartait jamais après qu'on ait désactivé
        // « Réduire les animations », parce que la valeur observée ne changeait
        // plus. `initial: true` couvre l'apparition, le reste couvre le vol.
        //
        // Dans le sens inverse, remettre `isPulsing` à faux passe par `branLoop`,
        // qui rend `nil` sous le réglage : la valeur change donc sans animation,
        // ce qui interrompt la boucle en cours au lieu de la laisser tourner.
        .onChange(of: pulses, initial: true) { _, allowed in
            isPulsing = allowed
        }
        .frame(width: 16, height: 16)
    }

    private var pulses: Bool { reduceMotion == false }
}
