import BranCore
import SwiftUI

/// Les réglages de l'historique du presse-papiers.
///
/// **Trois interrupteurs et un délai, et chacun a sa phrase.** C'est l'écran le
/// plus bavard des quatre, et c'est délibéré : aucun de ces réglages ne se
/// comprend par son libellé seul.
///
/// - « 30 jours » se lit spontanément comme « j'oublie tout au bout de 30 jours »,
///   c'est-à-dire comme le défaut que la fonctionnalité existe pour corriger. La
///   phrase qui dit que le texte reste pour toujours n'est donc pas un
///   commentaire d'aide : sans elle, le réglage ment.
/// - « Ignorer les copies confidentielles » ne veut rien dire tant qu'on ne sait
///   pas *qui* pose ce marqueur ni que macOS efface déjà ces contenus tout seul.
/// - « Conserver l'historique » a besoin de dire ce qu'il ne fait pas — il
///   n'efface rien de ce qui est déjà rangé.
///
/// Le coût disque est affiché avec le délai, et non dans un coin : une rétention
/// se règle en regardant ce qu'elle coûte, sinon on la choisit au hasard.
struct ClipboardSettingsSection: View {
    @Bindable var model: AppModel

    private var settings: ClipboardSettings { model.clipboardSettings }
    private var store: ClipboardStore { model.clipboard.store }

    var body: some View {
        Section("Presse-papiers") {
            Text("Tout ce que vous copiez est rangé sur ce Mac, et un raccourci rouvre la liste. Rien ne part ailleurs : la bibliothèque est un dossier de fichiers, à côté des enregistrements.")
                .font(Type.meta)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            GlobalTriggerRow(model: model, trigger: .clipboard)

            Toggle("Conserver ce que je copie", isOn: Binding(
                get: { settings.capturesCopies },
                set: {
                    settings.capturesCopies = $0
                    model.clipboard.applySettings()
                }
            ))

            Text(captureHint)
                .font(Type.meta)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // **Le délai ne gouverne que les contenus lourds**, et la ligne qui
            // l'annonce le dit avant qu'on ne lise le nombre. Le texte, lui, n'a
            // aucun réglage parce qu'il n'a aucune échéance — c'est la promesse
            // de la fonctionnalité, pas une valeur par défaut.
            LabeledContent("Texte copié") {
                Text(ClipboardRetention.textLabel)
                    .foregroundStyle(.secondary)
            }

            Picker("Conserver les contenus lourds", selection: Binding(
                get: { settings.blobDays },
                set: {
                    settings.blobDays = $0
                    model.clipboard.applySettings()
                }
            )) {
                ForEach(ClipboardRetention.offeredDays, id: \.self) { days in
                    Text(ClipboardRetention.days(days).label).tag(days)
                }
            }

            Text(retentionHint)
                .font(Type.meta)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Ignorer les copies marquées confidentielles", isOn: Binding(
                get: { settings.honoursPrivacyMarkers },
                set: {
                    settings.honoursPrivacyMarkers = $0
                    model.clipboard.applySettings()
                }
            ))

            Text(privacyHint)
                .font(Type.meta)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Le même bandeau que les trois autres bibliothèques, et au même
            // endroit : ce qui empêche d'écrire ou de relire se dit là où l'on
            // règle le rangement, parce que c'est là qu'on va le réparer.
            if let problem = store.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Palette.attention)
                    .font(Type.cardBody)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: -

    /// Ce que l'interrupteur de capture fait, et surtout ce qu'il ne fait pas.
    ///
    /// La deuxième phrase est celle qui compte : baisser un interrupteur nommé
    /// « conserver » laisse craindre que ce qui est déjà conservé s'en aille.
    private var captureHint: String {
        if settings.capturesCopies {
            return "Les copies faites au clavier arrivent tout de suite, celles faites à la souris ou au menu jusqu'à deux secondes plus tard."
        }
        return "Plus rien n'est écrit à partir de maintenant. Ce qui est déjà rangé reste en place et le raccourci ouvre toujours la liste — c'est l'écriture qui s'arrête, pas l'historique qui s'efface."
    }

    /// Le délai, ce qu'il emporte, et ce qu'il coûte aujourd'hui.
    ///
    /// **Le chiffre vient de `ClipboardStore.blobBytes`**, qui existe pour ça :
    /// il est relevé au chargement et après chaque purge, pas à chaque copie —
    /// c'est un chiffre de réglages, pas un compteur temps réel. Même forme que
    /// `SnapshotSettingsSection.retentionHint`, avec la même unité de mesure.
    private var retentionHint: String {
        let size = ByteCountFormatStyle(style: .file).format(store.blobBytes)
        guard settings.blobDays > 0 else {
            return "Les images, fichiers et textes enrichis copiés aujourd'hui partent à minuit ; ils occupent \(size) en attendant. L'entrée, elle, reste dans la liste avec son texte et dit ce qu'elle portait."
        }
        return "Les images, fichiers et textes enrichis occupent \(size). Passé le délai, seul le fichier s'en va : l'entrée reste dans la liste, garde son texte, et dit ce qu'elle montrait et quand elle l'a perdu."
    }

    /// Qui pose le marqueur, et ce que macOS en fait sans nous.
    ///
    /// Les quatre applications sont nommées parce que « marquées
    /// confidentielles » ne désigne rien de vérifiable : personne ne peut savoir
    /// si le réglage le concerne sans savoir quels outils posent ce marqueur.
    /// Les quatre-vingt-dix secondes de macOS sont là pour la même raison — elles
    /// disent que le contenu visé est déjà éphémère par ailleurs, ce qui est
    /// exactement l'argument du défaut.
    private var privacyHint: String {
        if settings.honoursPrivacyMarkers {
            return "1Password, Bitwarden, KeePassXC et iTerm signalent ainsi leurs copies sensibles, et macOS les efface de lui-même au bout d'environ 90 secondes. bran ne les écrit pas du tout."
        }
        return "Les copies de 1Password, Bitwarden, KeePassXC et iTerm seront rangées comme les autres, alors que macOS les efface de lui-même au bout d'environ 90 secondes. Un mot de passe copié se retrouvera donc en clair dans la bibliothèque, pour toujours."
    }
}
