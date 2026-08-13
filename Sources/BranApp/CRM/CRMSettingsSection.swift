import AppKit
import SwiftUI

struct CRMSettingsSection: View {
    @Bindable var configuration: CRMConfiguration
    let uploads: UploadService

    @State private var testResult: String?
    @State private var isTesting = false

    var body: some View {
        Section("Castral CRM") {
            TextField("Adresse du CRM", text: $configuration.baseURL, prompt: Text("https://crm.castral.fr"))
                .textContentType(.URL)
                // **C'est ici que le Trousseau s'ouvre, et nulle part ailleurs
                // au lancement.** Le champ ci-dessous affiche le jeton : il faut
                // donc le lire, et une alerte système qui arrive pendant qu'on
                // regarde l'écran « Castral CRM » se comprend toute seule. Voir
                // `CRMConfiguration.loadToken()` pour ce que ça évite.
                .onAppear { configuration.loadToken() }

            SecureField("Jeton d'enregistrement", text: $configuration.token, prompt: Text("rec_…"))
                .textContentType(.password)

            Text("Le jeton est conservé dans le Trousseau, jamais dans les préférences ni dans le dépôt. Il ne peut faire que six appels : lister les RDV, déposer un audio, lancer et suivre son traitement. Il ne peut pas effacer un closing déjà transcrit.")
                .font(Type.meta)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Importer depuis un fichier .env…") { importFromEnvironmentFile() }

                Button(isTesting ? "Vérification…" : "Tester la connexion") { test() }
                    .disabled(isTesting || configuration.isConfigured == false)
            }

            // Le refus du Trousseau passe **avant** le résultat du test, et
            // s'affiche avec lui plutôt qu'à sa place : les deux sont vrais en
            // même temps. La connexion peut très bien réussir — elle utilise le
            // jeton en mémoire — pendant que le Trousseau, lui, n'en a pas
            // voulu. Un « Connexion établie » vert tout seul enverrait
            // l'utilisateur quitter bran avec un jeton qui n'existe plus.
            if let problem = configuration.tokenProblem {
                Text(problem)
                    .font(Type.cardBody)
                    .foregroundStyle(Palette.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let testResult {
                Text(testResult)
                    .font(Type.cardBody)
                    .foregroundStyle(testResult.hasPrefix("Connexion établie") ? Palette.done : Palette.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Picker("Déposé par", selection: $configuration.author) {
                ForEach(CRMConfiguration.Author.allCases) { author in
                    Text(author.rawValue).tag(author)
                }
            }

            Stepper(
                "Locuteurs attendus : \(configuration.maxSpeakers)",
                value: $configuration.maxSpeakers,
                in: 2...6
            )
            Text("3 pour un closing standard : commercial et technique Castral, plus le prospect. Monter si le prospect vient avec son prestataire.")
                .font(Type.meta)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Envoyer automatiquement quand le rattachement est certain", isOn: $configuration.autoUpload)
            Text("N'envoie tout seul que si un unique rendez-vous tombe dans les deux heures autour de l'enregistrement, et qu'aucun audio n'y a déjà été déposé. Dans tous les autres cas, bran demande — un audio rattaché au mauvais lead écrase le compte-rendu de quelqu'un d'autre.")
                .font(Type.meta)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func test() {
        isTesting = true
        Task {
            testResult = await uploads.testConnection()
            isTesting = false
        }
    }

    /// Évite de retaper un jeton de 36 caractères — et surtout, permet de
    /// supprimer le fichier ensuite : une fois dans le Trousseau, le `.env` n'a
    /// plus de raison d'exister sur la machine.
    private func importFromEnvironmentFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.message = "Choisissez le fichier .env contenant CASTRAL_RECORDER_TOKEN."

        guard panel.runModal() == .OK,
              let url = panel.url,
              let contents = try? String(contentsOf: url, encoding: .utf8)
        else { return }

        let token = contents
            .split(separator: "\n")
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("CASTRAL_RECORDER_TOKEN=") else { return nil }
                return trimmed
                    .replacing("CASTRAL_RECORDER_TOKEN=", with: "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            }
            .first

        guard let token, token.hasPrefix("rec_") else {
            testResult = "Aucune ligne CASTRAL_RECORDER_TOKEN=rec_… trouvée dans ce fichier."
            return
        }

        configuration.token = token

        // « Vous pouvez supprimer le fichier .env » est le pire conseil possible
        // si le Trousseau vient de refuser l'écriture : ce fichier serait alors
        // la dernière copie du jeton. On ne le donne donc que quand l'écriture
        // est confirmée ; sinon le motif du refus s'affiche déjà au-dessus.
        testResult = configuration.tokenProblem == nil
            ? "Jeton importé dans le Trousseau. Vous pouvez supprimer le fichier .env."
            : nil
    }
}
