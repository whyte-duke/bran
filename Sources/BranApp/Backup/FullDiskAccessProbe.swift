import Foundation

/// Est-ce que ce processus a l'**Accès complet au disque** ?
///
/// ## Pourquoi la sauvegarde a besoin de le savoir
///
/// `BackupConfigurationStore.defaultConfiguration()` met le dossier personnel
/// entier en source. Or macOS protège, à l'intérieur même de ce dossier, des
/// sous-arbres qu'aucun processus ne lit sans cette autorisation :
/// `~/Library/Mail`, `~/Library/Messages`, `~/Library/Safari`,
/// `~/Library/Application Support/com.apple.TCC`, `~/Library/Containers` d'un
/// certain nombre d'applications.
///
/// **Et le refus ne se voit nulle part.** La politique du dépôt kopia porte
/// `Ignore file read errors: true` : chaque fichier refusé incrémente
/// `ignoredErrorCount` du manifeste, mais le code de sortie reste 0 et le
/// snapshot est écrit. Autrement dit, sans cette autorisation, une sauvegarde
/// se déclare **réussie** en ayant sauté ce qu'elle ne pouvait pas lire — et
/// c'est précisément ce que ce projet existe pour ne pas laisser passer.
/// `SnapshotProof.isTrustworthy` rattrape le cas quand `errorCount` compte les
/// refus, mais un « ignoré » n'est pas une « erreur » pour kopia.
///
/// ## Pourquoi une vraie lecture, et pas `isReadableFile`
///
/// Mesuré le 02/09/2026 sur ce Mac :
///
/// ```
///   $ ls -l ~/Library/Application Support/com.apple.TCC/TCC.db
///   -rw-r--r--  1 whyteduke  staff  151552
///   $ head -c 16 …/TCC.db   →  refusé
/// ```
///
/// Les bits de permission POSIX disent « lisible » ; c'est TCC, une couche au
/// dessus, qui refuse à l'`open()`. `FileManager.isReadableFile(atPath:)` ne
/// consulte que les premiers et répondrait donc `true` sur un Mac sans
/// autorisation. Seule une lecture réellement tentée tranche.
///
/// ## Trois réponses, jamais deux
///
/// `unknown` existe parce qu'un Mac peut légitimement n'avoir aucun des
/// témoins (compte tout neuf, `~/Library/Application Support/com.apple.TCC`
/// absent). Répondre « refusé » dans ce cas ferait afficher un avertissement à
/// quelqu'un qui n'a rien à corriger — le bruit qui apprend à ignorer les
/// avertissements suivants.
enum FullDiskAccessProbe {

    enum Standing: Sendable, Equatable {
        /// Une lecture d'un fichier protégé par TCC a réussi.
        case granted
        /// Le fichier existe et la lecture a été refusée : c'est bien
        /// l'autorisation qui manque.
        case denied
        /// Aucun témoin exploitable sur ce Mac — on ne conclut pas.
        case unknown
    }

    /// Les fichiers-témoins, dans l'ordre où on les essaie. Tous sont
    /// protégés par TCC et présents sur un Mac ordinaire ; aucun n'est
    /// modifié, ni même lu au-delà de son premier octet.
    private static let witnesses = [
        "Library/Application Support/com.apple.TCC/TCC.db",
        "Library/Safari/Bookmarks.plist",
        "Library/Mail",
    ]

    /// Une seule lecture d'un octet par témoin, jusqu'au premier verdict.
    ///
    /// **À ne pas appeler depuis un corps de vue.** C'est un accès disque,
    /// comme la lecture du Trousseau documentée dans
    /// `BackupController.hasStoredSecret(_:)` : la réponse doit être une
    /// valeur déjà connue, jamais une opération refaite à chaque redessin.
    static func measure() -> Standing {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var sawWitness = false
        for witness in witnesses {
            let url = home.appending(path: witness)
            guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { continue }
            sawWitness = true
            // `FileHandle` plutôt que `Data(contentsOf:)` : on ne veut pas
            // charger 150 Ko de base TCC pour savoir si l'`open()` passe.
            if let handle = try? FileHandle(forReadingFrom: url) {
                try? handle.close()
                return .granted
            }
            // Un dossier ne s'ouvre pas en lecture : pour lui, la question est
            // « peut-on l'énumérer ».
            if (try? FileManager.default.contentsOfDirectory(atPath: url.path(percentEncoded: false))) != nil {
                return .granted
            }
        }
        return sawWitness ? .denied : .unknown
    }
}
