import Foundation

/// **Ce qu'un titre de fenêtre raconte en plus du travail.**
///
/// La clé d'une voie de fenêtre est son titre nettoyé (`LaneIdentity.window`).
/// Tout ce qui bouge dans le titre sans que le travail ait bougé fabrique donc
/// une voie neuve — et l'ancienne, immobile, part en `waiting` puis en `stale`.
/// C'est exactement le générateur de fausses alertes que le correctif de
/// vivacité a déjà fermé une fois, par un autre chemin.
///
/// **Le cas mesuré qui a rouvert le trou** :
/// `bran - root@kvm4: ~ - ssh castral-azure - 244x67`. Le `244x67` est la taille
/// de la fenêtre en colonnes × lignes. Redimensionner la fenêtre — ou seulement
/// changer la taille de la police — change ce nombre, donc la clé, donc la voie.
/// Une voie fantôme reste alors dans le verdict, immobile, et bascule en
/// `waiting` puis en `stale` sans que rien ne se soit passé.
///
/// **Pourquoi une liste de règles nommées, et pas une expression régulière.**
/// Chaque émulateur salit un titre à sa façon, et elles ne se ressemblent pas :
/// préfixe entre crochets pour tmux, suffixe après un tiret pour Terminal.app,
/// drapeau collé au nom de fenêtre ici, séparateur cadratin là. Une regex unique
/// serait illisible au troisième cas et, surtout, plus personne ne pourrait dire
/// *pourquoi* un morceau est retiré. Ici chaque règle nomme son émulateur,
/// justifie la volatilité qu'elle vise, et se lit — ou se retire — seule.
enum TitleNoise {

    // MARK: - La chaîne

    /// L'état qui traverse la chaîne de règles.
    ///
    /// `looksLikeTmux` existe pour une raison précise : les drapeaux d'activité
    /// de tmux (`*` `-` `#` `!` `~`) sont des caractères parfaitement ordinaires.
    /// Les retirer d'un titre quelconque coûterait le `#` de « Visual Studio C# »
    /// et le point d'exclamation de « Terminé ! ». On ne les retire donc que d'un
    /// titre qui a déjà avoué venir de tmux.
    struct Cleanup {
        var title: String
        var looksLikeTmux = false
    }

    /// Une règle porte son nom pour qu'un test puisse la citer, et sa raison
    /// pour qu'on n'ait pas à la deviner en lisant son corps.
    struct Rule: Sendable {
        let name: String
        let apply: @Sendable (Cleanup) -> Cleanup
    }

    /// **L'ordre n'est pas décoratif : il suit l'ordre de dépose.**
    ///
    /// Un titre est écrit par plusieurs couches qui s'empilent de l'intérieur
    /// vers l'extérieur — tmux nomme sa fenêtre, l'émulateur ajoute la
    /// géométrie autour, l'application de document ajoute « — Edited » par
    /// dessus tout. On retire donc dans l'ordre inverse, du plus externe au plus
    /// interne : c'est ce qui permet une passe unique plutôt qu'un point fixe,
    /// et une passe unique est ce qui empêche deux règles de se composer en
    /// mangeant un titre légitime.
    static let rules: [Rule] = [
        headCounter,
        iTerm2WindowNumber,
        tmuxWindowIndex,
        documentEditedMarker,
        terminalGeometry,
        tmuxActivityFlags,
        spinnerGlyphs,
    ]

    static func strip(_ title: String) -> String {
        var state = Cleanup(title: title.trimmingCharacters(in: .whitespacesAndNewlines))
        for rule in rules { state = rule.apply(state) }
        return state.title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Les règles, une par volatilité

    /// **Navigateurs et clients de messagerie.** « (3) Boîte de réception »
    /// devient « (7) Boîte de réception » à chaque message reçu : le compteur
    /// est la chose la plus volatile d'un titre, et la seule que tout le monde
    /// pose au même endroit.
    ///
    /// La règle accepte n'importe quoi entre les parenthèses, et pas seulement
    /// des chiffres : c'était déjà le cas avant que ce fichier existe, et
    /// restreindre aux chiffres changerait le comportement de voies déjà en
    /// place sans qu'aucune mesure ne le demande.
    static let headCounter = Rule(name: "compteurEnTête") { state in
        var state = state
        guard state.title.hasPrefix("("), let close = state.title.firstIndex(of: ")") else {
            return state
        }
        state.title = String(state.title[state.title.index(after: close)...])
            .trimmingCharacters(in: .whitespaces)
        return state
    }

    /// **iTerm2**, réglage « Show window number in title bar » : le titre
    /// commence par « 3. ». Le numéro est celui du raccourci ⌘3, donc il change
    /// dès qu'on ferme une autre fenêtre ou qu'on en réordonne deux. Aucune
    /// action de l'utilisateur *dans* la session ne le fait bouger, et pourtant
    /// il bouge — c'est la définition de ce qu'il faut retirer.
    ///
    /// Deux gardes contre les faux positifs : au plus deux chiffres, et une
    /// espace obligatoire après le point. Sans la seconde, « 1.5 GHz » perdrait
    /// sa partie entière. Il reste un risque assumé — un document nommé
    /// « 10. Introduction » perdrait son numéro de chapitre — mais un titre de
    /// fenêtre qui commence par un rang suivi d'un point est, en pratique, un
    /// numéro de fenêtre iTerm2.
    static let iTerm2WindowNumber = Rule(name: "numéroDeFenêtreITerm2") { state in
        var state = state
        let title = state.title
        guard let dot = title.firstIndex(of: "."), dot > title.startIndex else { return state }

        let number = title[..<dot]
        guard number.count <= 2, number.allSatisfy({ $0.isASCII && $0.isNumber }) else { return state }

        let afterDot = title.index(after: dot)
        guard afterDot < title.endIndex, title[afterDot] == " " else { return state }

        let rest = title[afterDot...].trimmingCharacters(in: .whitespaces)
        guard rest.isEmpty == false else { return state }
        state.title = rest
        return state
    }

    /// **tmux et GNU screen** : « [0] root@kvm4: ~ ». L'index est la position de
    /// la fenêtre dans la session ; il se décale dès qu'on ferme une fenêtre
    /// d'un rang inférieur, sans que la session visée ait rien fait.
    ///
    /// Seuls des chiffres et des deux-points sont acceptés entre les crochets :
    /// c'est ce qui distingue « [0] » et « [2:3] » d'un « [WIP] » écrit par un
    /// humain, qui, lui, appartient au titre.
    ///
    /// Cette règle est aussi le principal témoin de tmux : elle lève
    /// `looksLikeTmux`, sans quoi la règle des drapeaux n'a pas le droit d'agir.
    static let tmuxWindowIndex = Rule(name: "indexDeFenêtreTmux") { state in
        var state = state
        let title = state.title
        guard title.hasPrefix("["), let close = title.firstIndex(of: "]") else { return state }

        let inner = title[title.index(after: title.startIndex)..<close]
        guard inner.isEmpty == false,
              inner.allSatisfy({ ($0.isASCII && $0.isNumber) || $0 == ":" })
        else { return state }

        state.title = String(title[title.index(after: close)...])
            .trimmingCharacters(in: .whitespaces)
        state.looksLikeTmux = true
        return state
    }

    /// **Les applications de document AppKit** ajoutent « — Edited » (« —
    /// Modifié » en français) dès la première frappe non enregistrée, et le
    /// retirent à l'enregistrement. Un aller-retour ⌘S produit donc deux clés
    /// pour un seul travail.
    ///
    /// La pastille des éditeurs de code (`•`, `●`) est traitée ailleurs : elle
    /// tombe déjà dans le jeu de glyphes d'animation, qui la retire où qu'elle
    /// soit.
    static let documentEditedMarker = Rule(name: "marqueurDeModification") { state in
        var state = state
        guard let split = lastSeparatedSegment(of: state.title), split.head.isEmpty == false else {
            return state
        }
        let marks: Set<String> = ["edited", "modified", "modifié", "modifiée"]
        guard marks.contains(split.tail.lowercased()) else { return state }
        state.title = split.head
        return state
    }

    /// **Terminal.app et iTerm2**, quand ils affichent la taille de la fenêtre :
    /// « … - 244x67 » ou « … — 244×67 ». C'est le bogue mesuré : redimensionner
    /// la fenêtre, ou seulement changer la police, réécrit ce nombre et fabrique
    /// une voie fantôme.
    ///
    /// La règle n'agit **qu'en position de suffixe**, et seulement pour des
    /// valeurs qu'un terminal peut réellement avoir — voir `columns` et `rows`.
    static let terminalGeometry = Rule(name: "géométrieDuTerminal") { state in
        var state = state
        guard let split = lastSeparatedSegment(of: state.title),
              split.head.isEmpty == false,
              cellGeometry(split.tail) != nil
        else { return state }
        state.title = split.head
        return state
    }

    /// **tmux**, drapeaux d'activité : « zsh* » (fenêtre courante), « zsh- »
    /// (précédente), « zsh# » (activité), « zsh! » (cloche), « zsh~ » (silence),
    /// « zshZ » (panneau agrandi). Ils changent à chaque fois qu'on regarde
    /// *une autre* fenêtre — donc précisément quand la voie visée ne fait rien.
    ///
    /// **La garde qui sauve un titre réel.** Un drapeau tmux est collé au nom de
    /// la fenêtre : le format est `#W#F`, sans séparateur. Un caractère précédé
    /// d'une espace, d'une barre oblique ou d'un deux-points appartient donc au
    /// titre. C'est ce qui préserve le `~` de « root@kvm4: ~ », qui est le
    /// dossier personnel et non le drapeau « silence » — sans cette garde,
    /// nettoyer « [0] root@kvm4: ~* » donnerait « root@kvm4: », un titre que
    /// personne n'a jamais vu.
    ///
    /// `M` (panneau marqué) n'est volontairement pas de la liste : une fenêtre
    /// légitimement nommée « IBM » ou « CRM » est plus probable qu'un panneau
    /// marqué, et le drapeau ne change presque jamais tout seul.
    static let tmuxActivityFlags = Rule(name: "drapeauxDActivitéTmux") { state in
        var state = state
        guard state.looksLikeTmux || hasTmuxTitleShape(state.title) else { return state }

        let flags: Set<Character> = ["*", "-", "#", "!", "~", "Z"]
        var title = Substring(state.title)

        while let last = title.last, flags.contains(last) {
            let flag = title.index(before: title.endIndex)
            guard flag > title.startIndex else { break }
            let previous = title[title.index(before: flag)]
            guard previous.isWhitespace == false, previous != "/", previous != ":" else { break }
            title = title[..<flag]
        }

        state.title = String(title)
        return state
    }

    /// Les caractères d'animation d'un indicateur de progression. Sans cette
    /// règle, un titre qui passe de « ⠂ Compilation » à « ⠄ Compilation » crée
    /// une voie neuve à chaque tic et la file se remplit de fantômes.
    ///
    /// Retirés **partout** et pas seulement en tête : les uns précèdent le
    /// titre, les autres le suivent, et l'ensemble ne veut rien dire à un
    /// humain de toute façon.
    static let spinnerGlyphs = Rule(name: "glyphesDAnimation") { state in
        var state = state
        let noise = CharacterSet(charactersIn: "⠁⠂⠄⡀⢀⠠⠐⠈⣾⣽⣻⢿⡿⣟⣯⣷•●○◐◓◑◒")
        state.title = state.title.unicodeScalars
            .filter { noise.contains($0) == false }
            .reduce(into: "") { $0.unicodeScalars.append($1) }
        return state
    }

    // MARK: - Outils communs

    /// Les séparateurs qu'une couche pose entre le titre et ce qu'elle y ajoute.
    /// Terminal.app écrit « - », iTerm2 et AppKit écrivent le cadratin « — ».
    /// Tous sont entourés d'espaces : c'est ce qui les distingue du tiret d'un
    /// nom de branche (`feat/ocr-2`), qui, lui, ne l'est jamais.
    private static let separators = [" - ", " -- ", " – ", " — "]

    /// Le dernier segment séparé du titre, et ce qui le précède.
    ///
    /// « le dernier » et pas « le premier » : les suffixes s'empilent à droite,
    /// et `bran - root@kvm4: ~ - ssh castral-azure - 244x67` ne doit rendre que
    /// `244x67`.
    private static func lastSeparatedSegment(of title: String) -> (head: String, tail: String)? {
        var best: Range<String.Index>?
        for separator in separators {
            guard let range = title.range(of: separator, options: .backwards) else { continue }
            if best == nil || range.lowerBound > best!.lowerBound { best = range }
        }
        guard let best else { return nil }
        return (
            head: String(title[..<best.lowerBound]).trimmingCharacters(in: .whitespaces),
            tail: String(title[best.upperBound...]).trimmingCharacters(in: .whitespaces)
        )
    }

    /// Les colonnes qu'un terminal peut réellement avoir.
    ///
    /// Le plus grand écran Apple fait 6016 points de large, et la plus petite
    /// chasse encore lisible avance d'environ 5 points par colonne : au-delà de
    /// ~1200 colonnes, il n'y a plus de terminal, il y a un autre nombre.
    private static let columns = 10...1200

    /// Les lignes qu'un terminal peut réellement avoir. Même raisonnement :
    /// 3384 points de haut, ~8 points par ligne, soit ~420 lignes au maximum.
    private static let rows = 4...400

    /// « 244x67 » → (244, 67). « 1920x1080 » → `nil`.
    ///
    /// **C'est la garde qui sauve une résolution d'écran.** Un titre peut
    /// légitimement finir par une résolution — une capture ouverte dans un
    /// éditeur d'images, « Aperçu — 1920x1080 ». Deux barrières le protègent, et
    /// il faut franchir les deux pour être pris pour une géométrie de terminal :
    ///
    /// 1. **La position.** La règle n'agit qu'en fin de titre, après un
    ///    séparateur. « Capture 1920x1080.png — Aperçu » n'est donc jamais
    ///    touché, et c'est la forme de très loin la plus fréquente : un nom de
    ///    fichier est suivi du nom de l'application.
    /// 2. **La plausibilité.** Une résolution franchit les deux bornes à la
    ///    fois — 1920 dépasse 1200 colonnes, 1080 dépasse 400 lignes — là où une
    ///    géométrie de terminal ne franchit ni l'une ni l'autre. Les tailles
    ///    d'écran courantes tombent toutes du bon côté : 1080, 1440, 1600, 2160
    ///    et jusqu'à 480 lignes sont hors bornes.
    ///
    /// **Le résidu, dit honnêtement** : un titre qui se terminerait exactement
    /// par « - 320x240 » serait pris pour une géométrie. C'est assumé — un
    /// terminal de 240 lignes existe sur un écran 5K, un titre de fenêtre qui se
    /// termine par une résolution QVGA n'existe pas.
    static func cellGeometry(_ token: String) -> (columns: Int, rows: Int)? {
        let isMark: (Character) -> Bool = { $0 == "x" || $0 == "X" || $0 == "×" }
        guard token.allSatisfy({ ($0.isASCII && $0.isNumber) || isMark($0) }),
              token.filter(isMark).count == 1,
              token.first.map({ $0.isNumber }) == true,
              token.last.map({ $0.isNumber }) == true
        else { return nil }

        let parts = token.split(whereSeparator: isMark)
        guard parts.count == 2,
              let width = Int(parts[0]), let height = Int(parts[1]),
              columns.contains(width), rows.contains(height)
        else { return nil }
        return (width, height)
    }

    /// Le format par défaut de `set-titles-string` de tmux est `#S:#I:#W` —
    /// « castral:0:zsh ». L'index numérique au milieu est ce qui trahit tmux
    /// quand le titre n'a pas de crochets, et c'est la seule autre autorisation
    /// que la règle des drapeaux accepte.
    private static func hasTmuxTitleShape(_ title: String) -> Bool {
        let parts = title.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return false }
        return parts[1].isEmpty == false && parts[1].allSatisfy { $0.isASCII && $0.isNumber }
    }
}
