import AppKit
import BranSpeech
import SwiftUI

/// Les réglages de la dictée.
///
/// L'ordre suit ce qu'on veut savoir en premier : est-ce que ça marche, avec
/// quelle touche, dans quelle langue — puis le reste.
struct DictationSettingsSection: View {
    @Bindable var model: AppModel

    @State private var isCapturingHotkey = false
    @State private var accessibilityRefused = false
    @State private var showsVocabulary = false

    private var settings: DictationSettings { model.dictationSettings }
    private var controller: DictationController { model.dictation }

    /// **Trois sections plutôt qu'une.** Empilée avec sept autres fonctions dans
    /// un formulaire unique, la dictée n'avait droit qu'à un seul titre. Seule
    /// dans son onglet, elle peut séparer ce qui se décide une fois (le geste)
    /// de ce qui s'installe une fois (le modèle) et de ce qu'on ne touche
    /// presque jamais.
    ///
    /// L'API ne bouge pas : c'est toujours `DictationSettingsSection(model:)`
    /// posée dans un `Form`.
    var body: some View {
        Section("Dictée") {
            enableRow

            if settings.isEnabled {
                triggerRow
                modeRow
                languageRow
            }
        }

        Section("Modèle de reconnaissance") {
            modelRow
        }

        if settings.isEnabled {
            Section("Réglages avancés") {
                // Toujours repliés : quatre réglages qui ont un défaut correct
                // n'ont pas à occuper l'écran de celui qui vient changer son
                // raccourci.
                DisclosureGroup("Afficher les réglages avancés") {
                    inputDeviceRow
                    retentionRow
                    behaviourRows
                    vocabularyRow
                        .sheet(isPresented: $showsVocabulary) {
                            VocabularySheet(settings: settings)
                        }
                }
            }
        }
    }

    // MARK: - Activation

    private var enableRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Dicter avec un raccourci clavier", isOn: Binding(
                get: { settings.isEnabled },
                set: { wanted in
                    accessibilityRefused = (model.enableDictation(wanted) == false)
                }
            ))

            if accessibilityRefused {
                VStack(alignment: .leading, spacing: 6) {
                    Label(
                        "bran n'a pas l'autorisation d'Accessibilité.",
                        systemImage: "xmark.octagon.fill"
                    )
                    .foregroundStyle(.red)
                    .font(.callout)

                    Text("""
                    Sans elle, macOS refuse à la fois de lire le raccourci et de \
                    coller le texte. Accordez-la, puis relancez bran : le système \
                    ne l'applique qu'au prochain démarrage.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                    HStack {
                        Button("Ouvrir les Réglages système") {
                            HotkeyMonitor.requestTrust()
                            NSWorkspace.shared.open(URL(
                                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
                            )!)
                        }
                        Button("Relancer bran") { Self.relaunch() }
                    }
                    .font(.callout)
                }
            } else if settings.isEnabled {
                Text("Tout se passe sur votre Mac. Aucun son, aucun texte ne part sur Internet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Raccourci

    private var triggerRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Raccourci")
                Spacer()
                HotkeyField(
                    binding: Binding(
                        get: { settings.trigger },
                        set: { settings.trigger = $0; controller.applySettings() }
                    ),
                    isCapturing: $isCapturingHotkey
                )
            }

            HStack {
                Text("Annuler")
                Spacer()
                Text(settings.cancelKey.displayName)
                    .font(.callout.monospaced())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 5))
            }
        }
    }

    private var modeRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Déclenchement", selection: Binding(
                get: { settings.triggerMode },
                set: { settings.triggerMode = $0; controller.applySettings() }
            )) {
                ForEach(DictationMachine.Trigger.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.radioGroup)

            Text("""
            Le maintien est plus rapide sur une phrase courte, et l'annulation \
            devient évidente : on relâche sans avoir parlé.
            """)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var languageRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Langue", selection: Binding(
                get: { settings.language },
                set: { settings.language = $0 }
            )) {
                ForEach(SpeechLanguage.allCases) { language in
                    Text(language.label).tag(language)
                }
            }

            Text(SpeechLanguage.guidance)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Modèle

    private var modelRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                Text(controller.host.availability.description)
                Spacer()

                switch controller.host.availability {
                case .absent, .failed:
                    Button("Télécharger") { Task { try? await controller.host.load() } }
                case .downloading(let fraction):
                    ProgressView(value: fraction).frame(width: 90)
                default:
                    EmptyView()
                }
            }
            .font(.callout)

            Text(modelExplanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let load = controller.host.lastLoadDuration {
                Text("Dernier chargement : \(load.formatted(.number.precision(.fractionLength(1)))) s")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .task { controller.host.refreshAvailability() }
    }

    private var symbol: String {
        switch controller.host.availability {
        case .ready: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .absent: "arrow.down.circle"
        default: "circle.dashed"
        }
    }

    private var tint: Color {
        switch controller.host.availability {
        case .ready: .green
        case .failed: .red
        default: .secondary
        }
    }

    private var modelExplanation: String {
        if case .absent = controller.host.availability {
            return """
            \(SpeechModelHost.modelName) — environ 500 Mo, téléchargés une seule \
            fois puis conservés. Ne le lancez pas cinq minutes avant un \
            rendez-vous : selon la connexion, comptez plusieurs minutes.
            """
        }
        let common = """
        \(SpeechModelHost.modelName), exécuté sur le Neural Engine. Il se charge \
        dès que vous appuyez sur le raccourci, pendant que vous parlez, donc \
        l'attente est invisible.
        """
        guard let measured = measuredSpeed else {
            return common + " Comptez environ 67× le temps réel, soit ~4 s pour 4 minutes de parole."
        }
        return common + " " + measured
    }

    /// La vitesse de la **dernière** dictée, datée.
    ///
    /// L'ancienne version annonçait « mesuré sur ce Mac » à partir de
    /// `store.entries.first`, sans jamais regarder de quand cette entrée datait
    /// ni si elle correspondait au dernier chargement : le chiffre affiché
    /// pouvait venir d'une dictée d'il y a trois semaines, faite dans une autre
    /// langue et sur un autre modèle. Une mesure sans date n'est pas
    /// vérifiable ; on la date, ou on ne l'affirme pas.
    private var measuredSpeed: String? {
        guard let entry = controller.store.entries.max(by: { $0.createdAt < $1.createdAt }),
              let processing = entry.processingTime,
              processing > 0, entry.duration > 0
        else { return nil }
        let ratio = entry.duration / processing
        let when = entry.createdAt.formatted(.relative(presentation: .named))
        return "Dernière dictée (\(when)) : \(ratio.formatted(.number.precision(.fractionLength(0))))× le temps réel."
    }

    // MARK: - Avancé

    private var inputDeviceRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Micro", selection: Binding(
                get: { settings.inputDeviceUID ?? "" },
                set: { settings.inputDeviceUID = $0.isEmpty ? nil : $0 }
            )) {
                Text("Périphérique système").tag("")
                ForEach(AudioInputDevice.all) { device in
                    Text(device.isBuiltIn ? "\(device.name) (intégré)" : device.name)
                        .tag(device.uid)
                }
            }

            Text("""
            Le micro intégré est recommandé, même avec un casque. Sur macOS, \
            activer le micro d'AirPods bascule le lien Bluetooth et fait retomber \
            toute la lecture à 16 kHz jusqu'au relâchement : votre musique ou \
            votre appel serait haché à chaque dictée. Le réseau de micros du Mac \
            est en prime meilleur pour la reconnaissance.
            """)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var retentionRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Conserver l'audio", selection: Binding(
                get: { settings.retentionDays },
                set: { settings.retentionDays = $0; controller.applySettings() }
            )) {
                ForEach(RetentionPolicy.offeredDays, id: \.self) { count in
                    Text(RetentionPolicy.days(count).label).tag(count)
                }
            }

            Text("""
            Le texte est gardé pour toujours ; seul l'audio est purgé. Une fois \
            purgé, la transcription ne peut plus être relancée — c'est indiqué \
            sur chaque dictée. Actuellement \(Self.bytes(controller.store.audioBytes)) d'audio.
            """)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var behaviourRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Restaurer le presse-papiers après le collage", isOn: Binding(
                get: { settings.restoresClipboard },
                set: { settings.restoresClipboard = $0; controller.applySettings() }
            ))

            Toggle("Jouer un son au début et à la fin", isOn: Binding(
                get: { settings.playsSound },
                set: { settings.playsSound = $0 }
            ))

            Stepper(
                "Décharger le modèle après \(settings.idleUnloadMinutes) min",
                value: Binding(
                    get: { settings.idleUnloadMinutes },
                    set: { settings.idleUnloadMinutes = $0; controller.applySettings() }
                ),
                in: 1...60
            )
        }
    }

    private var vocabularyRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Dictionnaire de corrections")
                Text("\(settings.vocabulary.rules.count) termes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Modifier…") { showsVocabulary = true }
        }
    }

    // MARK: -

    private static func bytes(_ count: Int64) -> String {
        ByteCountFormatStyle(style: .file).format(count)
    }

    /// L'Accessibilité n'est prise en compte qu'au démarrage du processus.
    /// Proposer le relancement évite l'attente d'un effet qui ne viendra pas —
    /// exactement le même piège que l'Enregistrement d'écran.
    private static func relaunch() {
        let url = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in
            Task { @MainActor in NSApplication.shared.terminate(nil) }
        }
    }
}

/// Champ de capture d'un raccourci.
///
/// Écoute localement les `flagsChanged` et les `keyDown` : pas besoin de tap ni
/// d'autorisation pour lire ce qui arrive à notre propre fenêtre.
/// Le champ de saisie d'un raccourci global.
///
/// Partagé par la dictée et la capture de texte : deux implémentations
/// divergeraient sur les touches refusées, et l'une des deux finirait par
/// laisser passer Entrée.
struct HotkeyField: View {
    @Binding var binding: HotkeyBinding
    @Binding var isCapturing: Bool

    @State private var monitor: Any?

    var body: some View {
        Button {
            isCapturing.toggle()
            isCapturing ? startListening() : stopListening()
        } label: {
            Text(isCapturing ? "Appuyez sur une touche…" : binding.displayName)
                .font(.callout.monospaced())
                .frame(minWidth: 130)
        }
        .buttonStyle(.bordered)
        .tint(isCapturing ? .accentColor : nil)
        .onDisappear(perform: stopListening)
    }

    private func startListening() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            let captured = Self.interpret(event)
            guard let captured, captured.isAcceptableAsTrigger else { return nil }
            binding = captured
            isCapturing = false
            stopListening()
            return nil
        }
    }

    private func stopListening() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private static func interpret(_ event: NSEvent) -> HotkeyBinding? {
        if event.type == .flagsChanged {
            // Un `flagsChanged` où plus aucun modificateur n'est actif est un
            // relâchement : on l'ignore, sinon relâcher la touche l'écraserait
            // par elle-même.
            guard event.modifierFlags.rawValue & Self.significant != 0 else { return nil }
            return HotkeyBinding(keyCode: event.keyCode, isModifierOnly: true)
        }

        return HotkeyBinding(
            keyCode: event.keyCode,
            modifiers: UInt64(event.modifierFlags.rawValue) & Self.significantCG,
            isModifierOnly: false
        )
    }

    private static let significant = NSEvent.ModifierFlags([.command, .option, .control, .shift]).rawValue
    private static let significantCG: UInt64 = 0x1E_0000
}

/// L'éditeur du dictionnaire.
private struct VocabularySheet: View {
    @Bindable var settings: DictationSettings
    @Environment(\.dismiss) private var dismiss

    @State private var heard = ""
    @State private var written = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Dictionnaire de corrections")
                    .font(.title3.weight(.semibold))
                Text("""
                Parakeet n'a jamais entendu le nom de votre entreprise ni celui de \
                vos clients. Chaque terme ajouté ici est corrigé après la \
                transcription, sur les mots entiers uniquement.
                """)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)

            Divider()

            // **Un état vide, plutôt qu'une liste vide.** Une zone blanche entre
            // deux séparateurs ne dit pas si le dictionnaire est vide ou si
            // l'écran n'a pas fini de charger — et surtout, elle n'explique pas
            // ce qu'on est censé y mettre.
            if settings.vocabulary.rules.isEmpty {
                ContentUnavailableView {
                    Label("Aucune correction", systemImage: "character.book.closed")
                } description: {
                    Text("Ajoutez ci-dessous les termes que la dictée écorche : noms de clients, de produits, sigles du métier.")
                } actions: {
                    Button("Partir des termes courants") {
                        settings.vocabulary = .starter
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach($settings.vocabulary.rules) { $rule in
                        HStack(spacing: 10) {
                            TextField("entendu", text: $rule.heard)
                                .textFieldStyle(.roundedBorder)
                            Image(systemName: "arrow.right")
                                .foregroundStyle(.tertiary)
                            TextField("écrit", text: $rule.written)
                                .textFieldStyle(.roundedBorder)

                            // Les champs de la liste sont modifiables : un
                            // doublon peut naître ici aussi, et c'est la
                            // dernière règle saisie qui n'aura jamais d'effet.
                            if duplicates.contains(Self.key(rule.heard)) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                    .help("Ce terme apparaît plusieurs fois : seule la première ligne est appliquée.")
                            }

                            Button("Supprimer", systemImage: "minus.circle.fill") {
                                settings.vocabulary.rules.removeAll { $0.id == rule.id }
                            }
                            .buttonStyle(.plain)
                            .labelStyle(.iconOnly)
                            .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .listStyle(.inset)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    TextField("castral", text: $heard)
                        .textFieldStyle(.roundedBorder)
                    Image(systemName: "arrow.right")
                        .foregroundStyle(.tertiary)
                    TextField("Castral", text: $written)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(add)
                    Button("Ajouter", action: add)
                        .disabled(isAddable == false)
                }

                // **On refuse le doublon au lieu de l'ajouter.** Les règles sont
                // appliquées dans l'ordre : une seconde règle sur le même terme
                // entendu ne s'appliquerait jamais, et l'utilisateur croirait
                // avoir corrigé quelque chose.
                if let existing = conflicting {
                    Label(
                        "« \(existing.heard) » est déjà corrigé en « \(existing.written) ». Modifiez la ligne existante plutôt que d'en ajouter une seconde, qui ne serait jamais appliquée.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)

            Divider()

            HStack {
                Spacer()
                Button("Terminé") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 560, height: 480)
    }

    // MARK: - Doublons

    /// La clé de comparaison : `VocabularyFixer` cherche sans distinguer la
    /// casse, deux règles qui n'en diffèrent que sont donc bien un doublon.
    private static func key(_ term: String) -> String {
        term.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// La règle existante que la saisie en cours viendrait doubler.
    private var conflicting: VocabularyFixer.Rule? {
        let candidate = Self.key(heard)
        guard candidate.isEmpty == false else { return nil }
        return settings.vocabulary.rules.first { Self.key($0.heard) == candidate }
    }

    /// Les termes présents plus d'une fois dans la liste.
    private var duplicates: Set<String> {
        var seen: Set<String> = []
        var repeated: Set<String> = []
        for rule in settings.vocabulary.rules {
            let key = Self.key(rule.heard)
            guard key.isEmpty == false else { continue }
            if seen.insert(key).inserted == false { repeated.insert(key) }
        }
        return repeated
    }

    private var isAddable: Bool {
        Self.key(heard).isEmpty == false
            && written.trimmingCharacters(in: .whitespaces).isEmpty == false
            && conflicting == nil
    }

    private func add() {
        guard isAddable else { return }
        settings.vocabulary.rules.append(.init(
            heard: heard.trimmingCharacters(in: .whitespaces),
            written: written.trimmingCharacters(in: .whitespaces)
        ))
        heard = ""
        written = ""
    }
}
