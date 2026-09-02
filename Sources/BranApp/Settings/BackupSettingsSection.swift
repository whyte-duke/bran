import AppKit
import BranBackup
import SwiftUI

/// Les réglages de la sauvegarde chiffrée : toute la `BackupConfiguration`,
/// et les deux secrets qui n'y vivent pas.
///
/// **Ce fichier suppose la même forme de `BackupController` que
/// `Backup/BackupPane.swift`** — voir le commentaire en tête de ce fichier
/// pour la liste complète. Il ajoute une seule attente : que
/// `BackupController.configuration` reste assignable directement (`var`, pas
/// `private(set)`), puisque cette section l'édite sur place via `@Bindable`,
/// exactement comme `ClipboardSettingsSection` édite `ClipboardSettings` à
/// travers `model.clipboardSettings`.
///
/// ## Ce qui distingue cet écran de `CRMSettingsSection`
///
/// `CRMSettingsSection` relie un `SecureField` directement au jeton en
/// mémoire (`$configuration.token`) : le jeton s'affiche à l'écran, en
/// pointillés mais présent, et repart au clic. **Ce n'est pas ce que ce
/// briefing demande pour la sauvegarde.** La clé secrète S3 et le mot de
/// passe de dépôt — qui est aussi la clé de chiffrement de bout en bout —
/// n'ont pas de champ qui les affiche : seulement un état (« enregistré dans
/// le Trousseau ») et un champ vierge pour en saisir un *nouveau*. Une fois
/// enregistré, l'ancien secret ne repasse plus jamais par la mémoire de cette
/// vue.
struct BackupSettingsSection: View {
    @Bindable var model: AppModel

    @State private var newS3Secret = ""
    @State private var newRepositoryPassword = ""
    @State private var ignoreRulesText: String?
    @State private var addFolderProblem: String?

    private var backup: BackupController { model.backup }

    var body: some View {
        @Bindable var backup = model.backup

        Section("Activation") {
            Toggle("Activer la sauvegarde", isOn: $backup.configuration.isEnabled)
            Text("Tant que c'est éteint, rien ne part jamais vers le QNAP — ni sonde, ni transfert. C'est aussi ce que la machine à états impose déjà : une configuration désactivée ne peut pas entrer en `.running`.")
                .font(Type.meta)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        Section("Ce qui est sauvegardé") {
            sourcePathsList
            Button("Ajouter un dossier…") { addSourcePath() }
            if let addFolderProblem {
                Text(addFolderProblem)
                    .font(Type.meta)
                    .foregroundStyle(Palette.attention)
            }

            Text("Règles d'exclusion")
                .font(Type.groupHead)
                .foregroundStyle(.secondary)
            TextEditor(text: ignoreRulesBinding)
                .font(Type.code)
                .frame(minHeight: BackupSettingsMetric.ignoreEditorHeight)
                .branWell()
                .accessibilityLabel("Règles d'exclusion")
            Text("Une règle par ligne, syntaxe .gitignore de Kopia — par exemple « *.tmp » ou « node_modules/ ». Vide, rien n'est exclu.")
                .font(Type.meta)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        Section("Fréquence") {
            Stepper(
                "Toutes les \(Int(backup.configuration.intervalHours)) heures",
                value: $backup.configuration.intervalHours,
                in: 1...168,
                step: 1
            )
            Text("L'intervalle voulu entre deux sauvegardes réussies — pas entre deux tentatives. Un Mac éteint au moment prévu rattrape au réveil, il ne saute pas son tour.")
                .font(Type.meta)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        Section("Sur batterie") {
            Picker("Sur batterie", selection: batteryChoiceBinding) {
                Text("Sauvegarder quand même").tag(BatteryChoice.always)
                Text("Attendre le secteur").tag(BatteryChoice.waitForPower)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            if case .waitForPower(let forceAfterHours) = backup.configuration.onBatteryPolicy {
                Stepper(
                    "Sauvegarder quand même après \(Int(forceAfterHours)) heures d'attente",
                    value: forceAfterHoursBinding,
                    in: 1...240,
                    step: 1
                )
            }

            Text("Un report sans borne est l'absence de sauvegarde : c'est la panne qui a coûté 143,1 Go de blocs sans un seul snapshot restaurable. La date limite garantit qu'une grosse sauvegarde finit par partir, batterie ou pas.")
                .font(Type.meta)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        Section("Dépôt") {
            TextField("Point d'accès S3", text: $backup.configuration.s3Endpoint, prompt: Text("minio-backup.tail-net.ts.net:9000"))
                .textContentType(.URL)
            TextField("Seau", text: $backup.configuration.s3Bucket, prompt: Text("bran-backup"))
            TextField("Région", text: $backup.configuration.s3Region, prompt: Text("us-east-1"))
            Toggle("Désactiver TLS", isOn: $backup.configuration.disableTLS)
            Text("À laisser éteint sauf si MinIO n'est joint qu'en clair à l'intérieur du tailnet — c'est un tunnel chiffré, mais un deuxième chiffrement en amont ne coûte rien.")
                .font(Type.meta)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Identifiant de clé S3", text: $backup.configuration.s3AccessKeyID, prompt: Text("AKIA…"))
                .font(Type.code)
            Text("L'identifiant seul, pas la clé secrète : il n'ouvre rien tout seul et peut s'afficher sans risque. La clé secrète se règle plus bas, dans « Secrets ».")
                .font(Type.meta)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        Section("Nœud Tailscale") {
            TextField("Nom du pair", text: $backup.configuration.tailscaleMinioNodeName, prompt: Text("minio-backup"))
            TextField("Adresse Tailscale", text: $backup.configuration.minioTailscaleIP, prompt: Text("100.x.x.x"))
            Text("Le nom sert à sonder le maillon 2 (« le pair répond-il dans le tailnet ? »), l'adresse aux maillons 3 à 5 (le port, la santé, le seau).")
                .font(Type.meta)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        Section("Secrets") {
            SecretRenewalRow(
                title: "Clé secrète S3",
                isStored: backup.hasStoredSecret(.s3SecretAccessKey),
                value: $newS3Secret
            ) {
                let saved = backup.renewSecret(.s3SecretAccessKey, to: newS3Secret)
                if saved { newS3Secret = "" }
                return saved
            }

            SecretRenewalRow(
                title: "Mot de passe du dépôt",
                isStored: backup.hasStoredSecret(.repositoryPassword),
                value: $newRepositoryPassword
            ) {
                let saved = backup.renewSecret(.repositoryPassword, to: newRepositoryPassword)
                if saved { newRepositoryPassword = "" }
                return saved
            }

            // **La phrase la plus importante de cet écran.** Un dépôt Kopia a un
            // mot de passe par Mac, qui est la clé de chiffrement de bout en
            // bout : ce n'est écrit nulle part ailleurs que dans le Trousseau de
            // *cette* machine, personne côté Castral ni côté Kopia ne peut le
            // retrouver, et le perdre rend le dépôt entier illisible — pas
            // seulement le prochain snapshot, tous les précédents aussi.
            Text("Le mot de passe du dépôt est la clé de chiffrement : il est propre à ce Mac, il n'est jamais envoyé nulle part, et personne — ni Castral, ni Kopia, ni vous depuis un autre Mac — ne peut le réinitialiser s'il est perdu. Sans lui, tout ce qui a été sauvegardé jusqu'ici devient illisible, définitivement.")
                .font(Type.meta)
                .foregroundStyle(Palette.attention)
                .fixedSize(horizontal: false, vertical: true)
        }

        Section("Délais des sondes") {
            Stepper(
                "Maillons réseau : \(Int(backup.configuration.probeTimeout)) s",
                value: $backup.configuration.probeTimeout,
                in: 1...60,
                step: 1
            )
            Text("Le délai au-delà duquel un maillon réseau (Tailscale, le port S3, la santé de MinIO) est déclaré mort. Serré : ces sondes sont censées répondre en quelques centaines de millisecondes.")
                .font(Type.meta)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Stepper(
                "Ouverture du dépôt : \(Int(backup.configuration.repositoryTimeout)) s",
                value: $backup.configuration.repositoryTimeout,
                in: 5...300,
                step: 5
            )
            Text("Généreux, contrairement au précédent : ouvrir le dépôt Kopia depuis loin — l'Indonésie, un tailnet chargé — peut légitimement prendre plusieurs dizaines de secondes sans que rien ne soit cassé.")
                .font(Type.meta)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        Section("Vérification") {
            HStack(spacing: Space.small) {
                Button("Tester la chaîne") { backup.verifyChainNow() }
                    .disabled(backup.phase.isBusy)
                if case .checkingChain = backup.phase {
                    ProgressView().controlSize(.small)
                }
            }

            if let verdict = backup.chainVerdict {
                Text(verdict.headline)
                    .font(Type.cardBody)
                    .foregroundStyle(verdict.canBackUp ? Palette.done : Palette.attention)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("La chaîne n'a jamais été sondée depuis le lancement.")
                    .font(Type.meta)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Les dossiers sources

    private var sourcePathsList: some View {
        ForEach(backup.configuration.sourcePaths, id: \.self) { path in
            HStack(spacing: Space.small) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                Text(path)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(path)
                Spacer(minLength: Space.small)
                Button(role: .destructive) {
                    backup.configuration.sourcePaths.removeAll { $0 == path }
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.plain)
                .disabled(backup.phase.isBusy)
                .help("Retirer ce dossier de la sauvegarde. Rien n'est supprimé sur le disque ni dans le dépôt.")
            }
        }
    }

    /// **`NSOpenPanel`, synchrone, comme `GeneralSettingsSection` pour le
    /// dossier des enregistrements.** Un choix de dossier local ne traverse
    /// jamais le réseau : ce n'est pas le genre d'attente que la règle « la
    /// fenêtre ne doit jamais geler » vise.
    private func addSourcePath() {
        addFolderProblem = nil
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choisissez un dossier à inclure dans la sauvegarde."

        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.path(percentEncoded: false)

        guard backup.configuration.sourcePaths.contains(path) == false else {
            addFolderProblem = "Ce dossier est déjà dans la liste."
            return
        }
        backup.configuration.sourcePaths.append(path)
    }

    // MARK: - Les règles d'exclusion

    /// **Une ligne par règle, jamais une liste tokenisée.** La syntaxe
    /// `.gitignore` de Kopia peut porter des espaces et des motifs — les
    /// découper sur autre chose qu'un retour à la ligne les mutilerait. Vide
    /// après nettoyage, une ligne ne devient pas une règle vide accidentelle.
    ///
    /// **`ignoreRulesText` mémorise le texte brut tapé**, pas seulement le
    /// tableau nettoyé : sans lui, chaque frappe repasserait par
    /// `configuration.ignoreRules` (filtré, sans lignes vides) et une ligne
    /// vide en cours de frappe — le temps de taper la règle suivante —
    /// disparaîtrait sous les doigts de qui l'écrit.
    private var ignoreRulesBinding: Binding<String> {
        Binding(
            get: { ignoreRulesText ?? backup.configuration.ignoreRules.joined(separator: "\n") },
            set: { newText in
                ignoreRulesText = newText
                backup.configuration.ignoreRules = newText
                    .split(separator: "\n", omittingEmptySubsequences: true)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { $0.isEmpty == false }
            }
        )
    }

    // MARK: - La batterie

    private enum BatteryChoice: Hashable {
        case always
        case waitForPower
    }

    private var batteryChoiceBinding: Binding<BatteryChoice> {
        Binding(
            get: {
                if case .always = backup.configuration.onBatteryPolicy { return .always }
                return .waitForPower
            },
            set: { choice in
                switch choice {
                case .always:
                    backup.configuration.onBatteryPolicy = .always
                case .waitForPower:
                    let hours = Self.currentForceAfterHours(backup.configuration.onBatteryPolicy) ?? 48
                    backup.configuration.onBatteryPolicy = .waitForPower(forceAfterHours: hours)
                }
            }
        )
    }

    private var forceAfterHoursBinding: Binding<Double> {
        Binding(
            get: { Self.currentForceAfterHours(backup.configuration.onBatteryPolicy) ?? 48 },
            set: { backup.configuration.onBatteryPolicy = .waitForPower(forceAfterHours: $0) }
        )
    }

    private static func currentForceAfterHours(_ policy: BatteryPolicy) -> Double? {
        guard case .waitForPower(let hours) = policy else { return nil }
        return hours
    }
}

// MARK: - Une ligne de renouvellement de secret

/// **Jamais le secret existant à l'écran — pas même masqué.**
///
/// Trois états, et un seul champ éditable :
/// 1. Rien à saisir, un secret existe déjà → « Enregistré dans le Trousseau »
///    et un bouton « Remplacer… ».
/// 2. Le bouton a été cliqué (ou rien n'est enregistré) → un `SecureField`
///    vide, jamais pré-rempli, et un bouton « Enregistrer ».
/// 3. L'écriture réussit → retour à l'état 1, avec le nouveau statut.
///
/// Le contenu du `SecureField` ne quitte cette vue que par
/// `BackupController.renewSecret`, qui écrit au Trousseau — jamais par
/// `configuration`, qui est sérialisée en clair sur le disque.
private struct SecretRenewalRow: View {
    let title: String
    let isStored: Bool
    @Binding var value: String
    let save: () -> Bool

    @State private var isEditing = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.tight) {
            if isEditing {
                HStack(spacing: Space.small) {
                    SecureField(title, text: $value, prompt: Text("Nouvelle valeur"))
                        .textContentType(.password)
                    Button("Enregistrer") {
                        guard save() else {
                            problem = "Le Trousseau a refusé l'écriture. Réessayez, ou vérifiez qu'il n'est pas verrouillé."
                            return
                        }
                        problem = nil
                        isEditing = false
                    }
                    .disabled(value.isEmpty)
                    Button("Annuler") {
                        value = ""
                        problem = nil
                        isEditing = false
                    }
                    .buttonStyle(.plain)
                }
            } else {
                HStack(spacing: Space.small) {
                    Image(systemName: isStored ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(isStored ? Palette.done : Palette.attention)
                    Text(title)
                    Spacer(minLength: Space.small)
                    Text(isStored ? "Enregistré dans le Trousseau" : "Non enregistré")
                        .foregroundStyle(.secondary)
                    Button(isStored ? "Remplacer…" : "Enregistrer…") { isEditing = true }
                }
            }

            if let problem {
                Text(problem)
                    .font(Type.meta)
                    .foregroundStyle(Palette.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(Type.cardBody)
    }
}

enum BackupSettingsMetric {
    /// Assez de hauteur pour une demi-douzaine de règles sans défiler —
    /// au-delà, `TextEditor` fait le travail tout seul.
    static let ignoreEditorHeight: CGFloat = 80
}

#Preview("Sauvegarde") {
    // Même convention que `SettingsPane` : un `AppModel()` réel plutôt qu'un
    // double fabriqué — cet écran n'a pas de raison de s'en écarter.
    Form {
        BackupSettingsSection(model: AppModel())
    }
    .formStyle(.grouped)
    .frame(width: 640, height: 760)
}
