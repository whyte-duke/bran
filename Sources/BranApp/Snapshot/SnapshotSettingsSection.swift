import BranSpeech
import BranVision
import SwiftUI

/// Les réglages de la capture de texte.
///
/// Volontairement court. La fonction n'a qu'une décision réellement structurante
/// — le mode de lecture par défaut — et tout le reste a un défaut qui marche.
struct SnapshotSettingsSection: View {
    @Bindable var model: AppModel

    private var settings: SnapshotSettings { model.snapshotSettings }

    @State private var isCapturingHotkey = false
    /// Le raccourci qu'on vient de refuser parce qu'il est déjà pris.
    @State private var refused: HotkeyBinding?

    var body: some View {
        Section("Capture de texte") {
            Toggle("Capturer du texte à l'écran", isOn: Binding(
                get: { settings.isEnabled },
                set: { enable($0) }
            ))

            Text("Un raccourci ouvre le viseur de macOS — celui de ⌘⇧4. Vous tracez un rectangle, et le texte de la zone part dans le presse-papiers. Tout est calculé sur ce Mac : aucune image, aucun texte n'est envoyé nulle part.")
                .font(Type.meta)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if settings.isEnabled, HotkeyMonitor.isTrusted == false {
                accessibilityWarning
            }

            VStack(alignment: .leading, spacing: Space.small) {
                HStack {
                    Text("Raccourci")
                    Spacer()
                    HotkeyField(
                        binding: Binding(
                            get: { settings.trigger },
                            set: { assign($0) }
                        ),
                        isCapturing: $isCapturingHotkey
                    )
                }

                // **Le conflit est refusé, pas seulement signalé.** L'ancienne
                // version affichait l'avertissement et enregistrait quand même :
                // les deux fonctions se retrouvaient sur la même touche, et
                // `ShortcutRouter` en arbitrait une en silence. L'utilisateur
                // voyait la dictée « ne plus marcher » sans rien pour l'expliquer.
                if let refused {
                    VStack(alignment: .leading, spacing: Space.small) {
                        Label(
                            "\(refused.displayName) est déjà le raccourci de la dictée. Les deux fonctions ne peuvent pas le partager : le système n'en préviendrait qu'une seule, toujours la même.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(Type.meta)
                        .foregroundStyle(Palette.attention)
                        .fixedSize(horizontal: false, vertical: true)

                        HStack {
                            Button("Échanger avec la dictée") { exchange(with: refused) }
                            Button("Garder \(settings.trigger.displayName)") { self.refused = nil }
                        }
                        .controlSize(.small)
                    }
                } else if let conflict = conflictLabel {
                    Label(conflict, systemImage: "exclamationmark.triangle.fill")
                        .font(Type.meta)
                        .foregroundStyle(Palette.attention)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Picker("Lecture par défaut", selection: Binding(
                get: { settings.defaultLayout },
                set: { settings.defaultLayout = $0 }
            )) {
                ForEach(LayoutMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.radioGroup)

            Text(layoutHint)
                .font(Type.meta)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Langue", selection: Binding(
                get: { settings.language },
                set: { settings.language = $0 }
            )) {
                ForEach(OCRLanguage.allCases, id: \.self) { language in
                    Text(language.label).tag(language)
                }
            }
            .disabled(settings.defaultLayout == .monospaced)

            if settings.defaultLayout == .monospaced {
                Text("En mode « Code et terminal », la langue est forcée à l'anglais et le correcteur linguistique est coupé. Ce n'est pas un goût : avec le correcteur actif sur la même image, `awk '{print` devient `awk 'fprint`.")
                    .font(Type.meta)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle("Coller aussitôt, en plus de copier", isOn: Binding(
                get: { settings.pastesAutomatically },
                set: { settings.pastesAutomatically = $0 }
            ))

            Text("Désactivé par défaut : on capture souvent du texte **depuis** l'application où l'on est en train d'écrire, et un collage automatique tomberait au mauvais endroit.")
                .font(Type.meta)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Un son discret quand le texte est prêt", isOn: Binding(
                get: { settings.playsSound },
                set: { settings.playsSound = $0 }
            ))

            Picker("Conserver les images", selection: Binding(
                get: { settings.retentionDays },
                set: {
                    settings.retentionDays = $0
                    model.snapshot.applySettings()
                }
            )) {
                ForEach(SnapshotRetention.offeredDays, id: \.self) { days in
                    Text(SnapshotRetention.days(days).label).tag(days)
                }
            }

            Text(retentionHint)
                .font(Type.meta)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: -

    private func enable(_ on: Bool) {
        guard model.enableSnapshot(on) == false else { return }
        // L'activation a échoué : l'Accessibilité manque. L'interrupteur est
        // déjà revenu à « non » — l'avertissement ci-dessous dira pourquoi.
        HotkeyMonitor.requestTrust()
    }

    /// Enregistre le raccourci, ou le refuse s'il est déjà pris.
    private func assign(_ newValue: HotkeyBinding) {
        guard newValue != model.dictationSettings.trigger else {
            refused = newValue
            return
        }
        refused = nil
        settings.trigger = newValue
        if settings.isEnabled { enable(true) }
    }

    /// L'échange, parce que c'est presque toujours ce qu'on voulait.
    ///
    /// Vouloir ⌘⇧2 pour la capture alors que la dictée l'occupe veut dire qu'on
    /// préfère l'autre touche pour la dictée — pas qu'on renonce.
    private func exchange(with wanted: HotkeyBinding) {
        let previous = settings.trigger
        model.dictationSettings.trigger = previous
        settings.trigger = wanted
        refused = nil
        model.dictation.applySettings()
        if settings.isEnabled { enable(true) }
    }

    /// Le conflit qui n'est pas passé par cet écran : les deux réglages sont
    /// persistés séparément, et une ancienne installation peut les avoir déjà
    /// alignés sur la même touche.
    private var conflictLabel: String? {
        guard settings.trigger == model.dictationSettings.trigger else { return nil }
        return "Cette touche est déjà celle de la dictée. Les deux fonctions ne peuvent pas partager un raccourci."
    }

    private var layoutHint: String {
        switch settings.defaultLayout {
        case .monospaced:
            "Reconstruit l'indentation et l'alignement des colonnes à partir de la position de chaque mot dans l'image. C'est ce qui rend un `ls -la` ou un bloc de code collable tel quel."
        case .prose:
            "Recolle les mots avec un espace simple. À préférer pour un article, un courriel ou une page web, où les écarts horizontaux ne sont que de la justification."
        }
    }

    private var retentionHint: String {
        let bytes = model.snapshot.store.imageBytes
        let size = ByteCountFormatStyle(style: .file).format(bytes)
        guard settings.retentionDays > 0 else {
            return "Aucune image n'est écrite sur le disque. Le texte est conservé, mais une capture ne pourra plus être relue dans l'autre mode."
        }
        return "Les images occupent \(size). Le texte, lui, n'est jamais supprimé automatiquement. Garder l'image permet de relire la même zone dans l'autre mode de lecture."
    }

    private var accessibilityWarning: some View {
        HStack(alignment: .top, spacing: Space.small) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Palette.attention)
            VStack(alignment: .leading, spacing: Space.tight) {
                Text("bran n'a pas l'autorisation d'Accessibilité : le raccourci ne peut pas être lu.")
                    .font(Type.cardBody)
                Text("Réglages système › Confidentialité et sécurité › Accessibilité, puis relancez bran.")
                    .font(Type.meta)
                    .foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
