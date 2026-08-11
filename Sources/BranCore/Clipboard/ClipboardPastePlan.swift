import Foundation

/// Une représentation à reposer sur le presse-papiers : un identifiant de type,
/// des octets.
public struct ClipboardPasteRepresentation: Sendable, Equatable {

    public let type: String
    public let data: Data

    public init(type: String, data: Data) {
        self.type = type
        self.data = data
    }
}

/// Ce qu'il faut reposer sur le presse-papiers pour recoller une entrée.
///
/// **L'exact symétrique de `ClipboardCapture`, et il est écrit à part pour la
/// même raison qu'elle.** La capture traduit des octets en entrée ; celui-ci
/// traduit une entrée en octets. Les deux ont besoin de connaître les
/// identifiants de type d'Apple, aucun des deux n'a besoin de toucher au
/// presse-papiers, et les garder purs est ce qui permet de vérifier en
/// microsecondes la seule chose qui compte vraiment ici : **qu'on recolle bien
/// ce qui avait été copié.**
///
/// ## Pourquoi une liste de listes
///
/// Un presse-papiers porte des **éléments**, chacun portant des
/// **représentations**. La distinction n'est pas décorative : une copie de trois
/// fichiers depuis le Finder est trois éléments portant chacun une
/// `public.file-url`, et les aplatir en un seul élément à trois représentations
/// donnerait un presse-papiers qui ne désigne plus qu'un fichier. C'est la même
/// structure que `SavedItem` côté application, et c'est voulu — le présentateur
/// n'a qu'à traduire une forme en l'autre.
///
/// ## Ce que cette pièce ne décide pas
///
/// - **Si l'entrée est collable.** `ClipboardEntry.canPaste` le dit déjà, avec
///   sa raison, et l'interface s'en sert pour désactiver ↵ **avant** le clic
///   plutôt que d'échouer après. Ici, une entrée qui n'a rien à donner rend une
///   liste vide, et c'est tout.
/// - **Où sont les octets.** Le contenu lourd vit sur le disque et sa lecture
///   est une I/O ; elle est fournie par une fermeture, ce qui laisse cette
///   fonction pure et permet de la vérifier sans écrire un fichier.
public enum ClipboardPastePlan {

    /// Ce qu'on recolle : la forme fidèle, ou le texte nu.
    ///
    /// **Le texte nu n'est pas une dégradation, c'est le second geste le plus
    /// demandé après « coller ».** Coller du HTML copié depuis une page web dans
    /// un document apporte avec lui une police, une couleur et une taille dont
    /// personne ne voulait. C'est exactement pour ça que `ClipboardCapture` garde
    /// la forme en texte brut d'un `richText` **en ligne**, dans l'index : la
    /// servir ne doit coûter ni conversion ni accès disque.
    public enum Variant: Sendable, Equatable {

        /// Tout ce que l'entrée porte, la forme la plus riche d'abord.
        case faithful

        /// Le texte seul. Sans effet sur une image ou un fichier, qui n'en ont
        /// pas — et il vaut mieux recoller l'image que rien du tout : demander
        /// « sans mise en forme » sur une image est un geste qui n'a pas de sens,
        /// pas une demande de ne rien faire.
        case plainText
    }

    /// Les éléments à poser, dans l'ordre où la source les aurait déclarés.
    ///
    /// **L'ordre des représentations décide de ce qui sera collé.** L'application
    /// qui reçoit prend « le premier type qu'elle comprend » ; poser le texte
    /// brut avant le RTF ferait donc coller du texte nu dans un traitement de
    /// texte parfaitement capable d'afficher la mise en forme. La forme la plus
    /// riche vient toujours en tête. C'est la leçon du point 7 de `Paster`, où un
    /// `Dictionary` sans ordre garanti faisait ressortir la même copie tantôt en
    /// RTF, tantôt en texte brut.
    ///
    /// - Parameters:
    ///   - entry: l'entrée choisie dans le panneau.
    ///   - variant: la forme voulue.
    ///   - blob: comment lire un contenu lourd, ou `nil` s'il est illisible. Le
    ///     purger est un cas normal — `ClipboardEntry.blobsArePurged` le dit — et
    ///     un `nil` ici ne doit jamais faire perdre les autres représentations.
    public static func items(
        for entry: ClipboardEntry,
        variant: Variant = .faithful,
        blob: (ClipboardBlobRef) -> Data?
    ) -> [[ClipboardPasteRepresentation]] {
        // Une entrée refusée à l'écriture n'a jamais rien porté, et une entrée
        // purgée n'a plus ses fichiers. Les deux se répondent sans toucher au
        // disque, et c'est `canPaste` qui porte la règle — la redémontrer ici
        // donnerait deux verdicts pour une question.
        guard entry.canPaste else { return [] }

        switch entry.kind {
        case .file:
            return filePaths(of: entry)
        case .image:
            return images(of: entry, blob: blob)
        case .text:
            return plainText(of: entry, blob: blob).map { [[$0]] } ?? []
        case .richText:
            return richText(of: entry, variant: variant, blob: blob)
        }
    }

    // MARK: - Par sorte

    /// Un élément par fichier, chacun portant son URL.
    ///
    /// Le contenu du fichier n'est jamais repris — ni à la capture, ni ici. Ce
    /// que le presse-papiers portait était une URL ; c'est une URL qu'on repose,
    /// et coller dans le Finder recopie le fichier comme si l'utilisateur venait
    /// de le copier lui-même.
    ///
    /// Un chemin nu — ce que `NSFilenamesPboardType` transporte — est converti en
    /// URL de fichier ici, parce que `public.file-url` est ce que macOS moderne
    /// comprend partout. `ClipboardEntry.fileURLs` documente exprès qu'il porte
    /// des **chaînes** que le site d'appel convertit, et qu'il peut les voir
    /// échouer sans rien perdre : c'est ce site d'appel-ci.
    private static func filePaths(of entry: ClipboardEntry) -> [[ClipboardPasteRepresentation]] {
        (entry.fileURLs ?? []).compactMap { path in
            let url = path.hasPrefix("file:") ? URL(string: path) : URL(fileURLWithPath: path)
            guard let text = url?.absoluteString, text.isEmpty == false else { return nil }
            return [ClipboardPasteRepresentation(type: fileURLType, data: Data(text.utf8))]
        }
    }

    /// Une image par blob. Plusieurs quand la copie en portait plusieurs.
    private static func images(
        of entry: ClipboardEntry, blob: (ClipboardBlobRef) -> Data?
    ) -> [[ClipboardPasteRepresentation]] {
        (entry.blobs ?? []).compactMap { reference in
            guard let data = blob(reference), data.isEmpty == false else { return nil }
            return [ClipboardPasteRepresentation(type: type(for: reference.ext), data: data)]
        }
    }

    /// Le texte brut, en ligne quand il y tient, dans son blob sinon.
    ///
    /// **L'ordre des deux sources compte, et il est l'inverse de l'intuition.**
    /// `plainText` est lu en premier parce qu'il vit dans l'index, que la
    /// rétention ne purge **jamais** : un texte de la semaine dernière reste
    /// collable indéfiniment. Le blob n'existe que pour le texte qui dépassait
    /// 512 Kio, et lui peut avoir été purgé.
    private static func plainText(
        of entry: ClipboardEntry, blob: (ClipboardBlobRef) -> Data?
    ) -> ClipboardPasteRepresentation? {
        if let text = entry.plainText {
            return ClipboardPasteRepresentation(type: utf8TextType, data: Data(text.utf8))
        }
        // Le blob de débordement d'un texte est écrit en UTF-8 par la capture,
        // quel que soit l'encodage d'origine : il se repose tel quel.
        let overflow = (entry.blobs ?? []).first { $0.ext == plainTextExtension }
        guard let overflow, let data = blob(overflow), data.isEmpty == false else { return nil }
        return ClipboardPasteRepresentation(type: utf8TextType, data: data)
    }

    /// La forme enrichie, son texte brut, et rien d'autre.
    ///
    /// **Le rendu matriciel n'est pas reposé, alors qu'il est conservé.** La
    /// capture garde le PNG ou le TIFF d'un `richText` pour qu'un futur « coller
    /// comme image » n'ait rien à recapturer ; le reposer *ici* ferait tout autre
    /// chose : une application qui préfère les images à tout le reste — et il y
    /// en a — collerait une capture d'écran du tableau au lieu du tableau. La
    /// variante image sera un geste explicite, pas un effet de bord de l'ordre
    /// des représentations.
    private static func richText(
        of entry: ClipboardEntry, variant: Variant, blob: (ClipboardBlobRef) -> Data?
    ) -> [[ClipboardPasteRepresentation]] {
        let plain = plainText(of: entry, blob: blob)
        guard variant == .faithful else { return plain.map { [[$0]] } ?? [] }

        var representations: [ClipboardPasteRepresentation] = []
        // La forme la plus riche d'abord : c'est elle qui doit être choisie par
        // qui sait la lire.
        for reference in entry.blobs ?? [] where richTextExtensions.contains(reference.ext) {
            guard let data = blob(reference), data.isEmpty == false else { continue }
            representations.append(
                ClipboardPasteRepresentation(type: type(for: reference.ext), data: data)
            )
        }
        if let plain { representations.append(plain) }
        return representations.isEmpty ? [] : [representations]
    }

    // MARK: - Les identifiants

    public static let utf8TextType = "public.utf8-plain-text"
    public static let fileURLType = "public.file-url"
    static let plainTextExtension = "txt"

    /// Les extensions qui portent une forme enrichie, dans l'ordre de préférence
    /// de `ClipboardTypePolicy.richTextTypes` : RTF avant HTML, parce que
    /// recoller du HTML dans un champ riche donne un résultat différent dans
    /// chaque application là où le RTF se comporte partout pareil.
    static let richTextExtensions = ["rtf", "rtfd", "html"]

    /// L'identifiant de type d'une extension de blob.
    ///
    /// **La table inverse de `ClipboardCapture.blobExtensions`, et elle est
    /// écrite à la main plutôt que dérivée.** L'inversion automatique serait
    /// fausse : quatre identifiants de texte s'écrivent tous en `txt`, et deux
    /// formes de RTFD partagent `rtfd`. Une table inversée mécaniquement en
    /// rendrait un au hasard, selon l'ordre d'itération d'un dictionnaire — ce
    /// qui est précisément le défaut du point 7 de `Paster`, où la même copie
    /// ressortait tantôt en RTF tantôt en texte brut.
    ///
    /// Le repli est `public.data` : un type que toute application reconnaît comme
    /// « des octets », donc un collage maladroit plutôt qu'un collage impossible.
    static func type(for ext: String) -> String {
        switch ext {
        case "png": "public.png"
        case "tiff": "public.tiff"
        case "jpeg", "jpg": "public.jpeg"
        case "heic": "public.heic"
        case "heif": "public.heif"
        case "gif": "com.compuserve.gif"
        case "bmp": "com.microsoft.bmp"
        case "rtf": "public.rtf"
        case "rtfd": "com.apple.flat-rtfd"
        case "html": "public.html"
        case plainTextExtension: utf8TextType
        default: "public.data"
        }
    }
}
