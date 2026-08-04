import AppKit
import Observation

/// Où bran écrit ses fichiers.
///
/// Le chemin est stocké en clair dans les préférences, pas en signet sécurisé :
/// bran n'est pas en bac à sable, il n'a donc pas besoin de rétablir un accès
/// entre deux lancements. Un chemin lisible est aussi réparable à la main si le
/// disque change de nom.
@MainActor
@Observable
final class StorageLocation {
    private static let key = "bran.storageRoot"

    static var `default`: URL {
        URL.moviesDirectory.appending(path: "bran", directoryHint: .isDirectory)
    }

    private(set) var root: URL

    /// Dernière erreur d'écriture — un dossier sur un disque externe débranché,
    /// par exemple. Une destination inaccessible doit se voir avant la réunion,
    /// pas après.
    private(set) var problem: String?

    init() {
        let stored = UserDefaults.standard.string(forKey: Self.key)
        root = stored.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? Self.default
        validate()
    }

    var isDefault: Bool {
        root.standardizedFileURL == Self.default.standardizedFileURL
    }

    /// Ouvre le sélecteur de dossier. Retourne `true` si la destination a changé.
    @discardableResult
    func chooseFolder() -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = root
        panel.prompt = "Choisir"
        panel.message = "Dossier où bran enregistrera les réunions."

        guard panel.runModal() == .OK, let chosen = panel.url else { return false }
        return setRoot(chosen)
    }

    @discardableResult
    func resetToDefault() -> Bool {
        setRoot(Self.default)
    }

    @discardableResult
    private func setRoot(_ url: URL) -> Bool {
        guard url.standardizedFileURL != root.standardizedFileURL else { return false }
        root = url.standardizedFileURL
        UserDefaults.standard.set(root.path(percentEncoded: false), forKey: Self.key)
        validate()
        return true
    }

    func validate() {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            problem = FileManager.default.isWritableFile(atPath: root.path(percentEncoded: false))
                ? nil
                : "Dossier en lecture seule."
        } catch {
            problem = "Dossier inaccessible : \(error.localizedDescription)"
        }
    }
}
