import Foundation

// Répond à une seule question, que rien d'autre dans `BranBackup` ne pose :
// est-ce que ce que l'utilisateur a demandé de sauvegarder (`sourcePaths`)
// est réellement couvert par un snapshot **prouvé**, ou est-ce qu'on affiche
// « sauvegardé » parce qu'un snapshot existe quelque part, sans vérifier
// lequel ?
//
// **Le cas vécu, mesuré sur ce Mac.** La configuration demande de sauvegarder
// tout le dossier personnel — de l'ordre de 600 Go, jamais envoyé une seule
// fois. Le dépôt, lui, contient un snapshot de `~/Music` (51 Mo), réussi et
// confirmé. `BackupJournalModel.lastSuccess` renvoie cette tentative sans
// mentir : elle a réellement réussi, pour le chemin qu'elle a réellement
// sauvegardé. Le mensonge n'est pas dans `BackupAttempt.succeeded`, il est
// dans l'écran qui affiche « dernière sauvegarde réussie » sans jamais se
// demander *quoi* a été sauvegardé. Ce fichier ferme ce trou-là.
//
// **Logique pure.** Aucun accès disque, aucun `Process`, aucune horloge lue
// en cachette : `now` et les seuils de fraîcheur sont des paramètres, comme
// dans `ChainEvaluator`. L'appelant fournit `sourcePaths`, les
// `SnapshotProof` relus du dépôt, et l'identité de la machine — cette
// dernière parce que `RepositoryStatus` la connaît déjà (`hostname`,
// `username`), pas parce que ce fichier irait la lire lui-même.
//
// **Par quels chemins ce fichier pourrait dire « couvert » à tort — et
// comment chacun est fermé ci-dessous :**
//
// 1. Prendre `origin == .reportedByCreate` pour une preuve. → On n'utilise
//    que `proof.isTrustworthy`, la même et unique définition que
//    `BackupAttempt.succeeded` et `BackupPhase.success`. Un snapshot
//    incomplet ou non relu dans le dépôt ne couvre rien, même s'il porte le
//    bon chemin.
// 2. Confondre « le snapshot est un sous-dossier de la source » avec
//    « le snapshot couvre la source ». → `covers` est strictement dans un
//    sens : l'ancêtre couvre le descendant, jamais l'inverse.
// 3. Le piège du préfixe de chaîne : `/Users/xavier` vu comme couvrant
//    `/Users/x` parce que `"...xavier".hasPrefix("...x")`. → La comparaison
//    se fait sur des **composants de chemin** (`split(separator: "/")`),
//    jamais sur des chaînes brutes.
// 4. La barre oblique finale traitée comme un dossier différent. →
//    `omittingEmptySubsequences: true` efface un composant vide de fin (ou de
//    début, ou de milieu), donc `/Users/x/` et `/Users/x` produisent les
//    mêmes composants.
// 5. Ignorer que le dépôt peut contenir des snapshots d'un autre Mac, ou du
//    frère du propriétaire sur la même machine. → Tout proof est filtré sur
//    `sourceHost` **et** `sourceUser` avant même de regarder le chemin.
// 6. Sommer `uploadedBytes` de toutes les tentatives et l'appeler « octets
//    sauvegardés ». → Voir `FirstUploadEvaluator` : le chiffre est nommé pour
//    ce qu'il est, « monté sur le réseau, reprises comprises », jamais plus.
// 7. Traiter un `uploadedBytes` absent comme zéro pour pouvoir sommer sans
//    interruption. → Les tentatives sans volume connu sont comptées à part
//    (`attemptsWithUnknownBytes`), jamais fondues silencieusement dans le
//    total.
// 8. Rester muet sur `sourcePaths` vide plutôt que de le traiter. → Un
//    verdict explicite, `notCovered`, avec une phrase qui le dit — jamais un
//    tableau vide qu'un appelant lirait comme « rien à signaler ».

// MARK: - La couverture d'un chemin

/// Ce qu'on sait de la couverture d'un seul chemin configuré.
public struct SourceCoverage: Sendable, Hashable {
    public enum State: Sendable, Hashable {
        /// Aucun snapshot prouvé, sur cette machine et pour cet utilisateur,
        /// ne couvre ce chemin. C'est l'état du dossier personnel du
        /// propriétaire au moment où ce fichier a été écrit.
        case neverBackedUp
        /// Couvert, mais le dernier snapshot qui le prouve date de plus que
        /// le seuil de fraîcheur transmis à l'évaluateur.
        case coveredButStale(since: Date)
        /// Couvert par un snapshot prouvé et récent.
        case covered(at: Date)
    }

    public var path: String
    public var state: State
    /// Le snapshot le plus récent qui justifie `state` — `nil` seulement pour
    /// `.neverBackedUp`, par construction : il n'y a rien à montrer.
    public var lastProof: SnapshotProof?

    public init(path: String, state: State, lastProof: SnapshotProof? = nil) {
        self.path = path
        self.state = state
        self.lastProof = lastProof
    }

    /// Faux seulement pour `.neverBackedUp`. Le point d'entrée que le reste
    /// du fichier utilise pour ne pas répéter le `switch` à chaque endroit.
    public var isCovered: Bool {
        if case .neverBackedUp = state { return false }
        return true
    }
}

/// Le verdict sur l'ensemble des `sourcePaths` d'une configuration.
public enum SourceCoverageVerdict: String, Sendable, Hashable {
    /// Chaque chemin configuré a au moins un snapshot prouvé qui le couvre —
    /// frais ou non.
    case fullyCovered
    /// Certains chemins sont couverts, d'autres jamais envoyés.
    case partiallyCovered
    /// Aucun chemin configuré n'a jamais été couvert.
    case notCovered
}

/// Le rapport complet, prêt à être affiché.
public struct SourceCoverageReport: Sendable, Hashable {
    public var coverages: [SourceCoverage]
    public var verdict: SourceCoverageVerdict
    /// Une phrase française, vraie, qui résume `coverages` en une ligne.
    public var headline: String

    public init(coverages: [SourceCoverage], verdict: SourceCoverageVerdict, headline: String) {
        self.coverages = coverages
        self.verdict = verdict
        self.headline = headline
    }
}

/// Évalue la couverture des `sourcePaths` d'une configuration à partir des
/// `SnapshotProof` relus dans le dépôt. Ne fait que des comparaisons ; ne lit
/// ni le disque ni l'horloge.
public enum SourceCoverageEvaluator {

    /// - Parameters:
    ///   - sourcePaths: `BackupConfiguration.sourcePaths`, tel quel — avec ou
    ///     sans barre oblique finale, peu importe.
    ///   - proofs: Tous les `SnapshotProof` relus dans le dépôt, de toutes
    ///     provenances. Ce fichier fait lui-même le tri par machine,
    ///     utilisateur, chemin et confiance ; ne pré-filtrer que ferait
    ///     doubler la logique à un endroit qui n'est pas testé ici.
    ///   - expectedHost: `RepositoryStatus.hostname` — la machine actuelle,
    ///     telle que Kopia la connaît.
    ///   - expectedUser: `RepositoryStatus.username`.
    ///   - now: L'instant de l'évaluation. Un paramètre, jamais `Date()` lu
    ///     ici, pour que ce fichier reste rejouable sur un relevé figé.
    ///   - staleAfter: Le délai au-delà duquel un snapshot par ailleurs
    ///     valide est déclaré périmé. Décidé par l'appelant — probablement à
    ///     partir de `BackupConfiguration.intervalHours` — jamais choisi ici,
    ///     pour la même raison que `ChainEvaluator.evaluate` prend
    ///     `freshness` en paramètre plutôt que de le connaître.
    public static func evaluate(
        sourcePaths: [String],
        proofs: [SnapshotProof],
        expectedHost: String,
        expectedUser: String,
        now: Date,
        staleAfter: TimeInterval
    ) -> SourceCoverageReport {
        guard !sourcePaths.isEmpty else {
            // Une configuration sans aucun chemin n'est pas un cas à ignorer
            // en silence : un tableau `coverages` vide se lirait, en aval,
            // comme « rien à signaler » plutôt que comme « rien n'est
            // configuré ». Les deux sont très différents pour l'utilisateur.
            return SourceCoverageReport(
                coverages: [],
                verdict: .notCovered,
                headline: "Aucun dossier n'est configuré pour la sauvegarde."
            )
        }

        let relevant = proofs.filter { $0.sourceHost == expectedHost && $0.sourceUser == expectedUser }

        let coverages = sourcePaths.map { sourcePath in
            coverage(of: sourcePath, in: relevant, now: now, staleAfter: staleAfter)
        }

        let verdict: SourceCoverageVerdict
        if coverages.allSatisfy(\.isCovered) {
            verdict = .fullyCovered
        } else if coverages.contains(where: \.isCovered) {
            verdict = .partiallyCovered
        } else {
            verdict = .notCovered
        }

        return SourceCoverageReport(
            coverages: coverages,
            verdict: verdict,
            headline: headline(coverages: coverages, verdict: verdict, totalProofCount: proofs.count)
        )
    }

    private static func coverage(
        of sourcePath: String,
        in relevantProofs: [SnapshotProof],
        now: Date,
        staleAfter: TimeInterval
    ) -> SourceCoverage {
        // Seuls les proofs `isTrustworthy` comptent : relus dans le dépôt,
        // et sans fichier manquant. Un `reportedByCreate`, ou un snapshot
        // incomplet, n'a pas plus de droit à couvrir une source ici qu'il
        // n'en a à faire réussir une `BackupAttempt` — c'est la même barre,
        // volontairement, pour qu'il n'existe qu'une définition du succès
        // dans tout ce module.
        let covering = relevantProofs
            .filter { $0.isTrustworthy && path($0.sourcePath, covers: sourcePath) }
            .max { $0.endTime < $1.endTime }

        guard let covering else {
            return SourceCoverage(path: sourcePath, state: .neverBackedUp)
        }

        let age = now.timeIntervalSince(covering.endTime)
        let state: SourceCoverage.State = age > staleAfter
            ? .coveredButStale(since: covering.endTime)
            : .covered(at: covering.endTime)
        return SourceCoverage(path: sourcePath, state: state, lastProof: covering)
    }

    private static func headline(
        coverages: [SourceCoverage],
        verdict: SourceCoverageVerdict,
        totalProofCount: Int
    ) -> String {
        switch verdict {
        case .fullyCovered:
            let stale = coverages.compactMap { coverage -> String? in
                guard case .coveredButStale = coverage.state else { return nil }
                return coverage.path
            }
            guard stale.isEmpty else {
                let word = stale.count > 1 ? "datent" : "date"
                return "Toutes vos sources ont déjà été sauvegardées, mais celle-ci \(word) : \(stale.joined(separator: ", "))."
            }
            return "Toutes vos sources ont déjà été sauvegardées."

        case .partiallyCovered:
            let missing = coverages.filter { !$0.isCovered }.map(\.path)
            let verb = missing.count > 1 ? "Jamais envoyés" : "Jamais envoyé"
            return "\(coverages.count - missing.count) sur \(coverages.count) dossiers sauvegardés. "
                + "\(verb) : \(missing.joined(separator: ", "))."

        case .notCovered:
            let names = coverages.map(\.path).joined(separator: ", ")
            guard totalProofCount > 0 else {
                return "Aucune sauvegarde de \(names). Le dépôt ne contient encore aucun snapshot."
            }
            // Reproduit littéralement l'exemple du cas vécu : un dépôt qui
            // n'est pas vide, mais dont rien ne couvre la source demandée.
            let plural = totalProofCount > 1
            let subject = plural ? "Les \(totalProofCount) snapshots" : "L'unique snapshot"
            let verb = plural ? "portent" : "porte"
            return "Aucune sauvegarde de \(names). \(subject) du dépôt \(verb) sur d'autres dossiers."
        }
    }
}

// MARK: - Le premier gros envoi

/// L'état du tout premier envoi complet d'un chemin, suivi **entre** les
/// exécutions — pas seulement pendant une tentative en cours, qui disparaît
/// dès que l'application quitte.
public struct FirstUploadTracking: Sendable, Hashable {
    public enum State: Sendable, Hashable {
        case neverStarted
        /// `attemptCount` : le nombre de tentatives attribuées à ce chemin,
        /// réussies ou non — chacune est une reprise du même premier envoi.
        ///
        /// `networkBytesSent` : la somme des `uploadedBytes` connus de ces
        /// tentatives. **Ce n'est pas « octets sauvegardés ».** C'est ce qui
        /// est réellement passé sur le réseau, reprises comprises — et une
        /// reprise peut réenvoyer des blocs déjà comptés dans une tentative
        /// précédente si celle-ci a été coupée avant que Kopia n'ait fini
        /// d'écrire son paquet en cours : ces octets-là existaient sur le fil
        /// mais pas encore dans le dépôt, donc la tentative suivante les
        /// envoie une seconde fois. Le nombre est donc un plancher honnête du
        /// trafic réseau, pas une mesure de progression vers les 600 Go — et
        /// c'est délibérément ce que son nom dit, ni plus ni moins.
        ///
        /// `attemptsWithUnknownBytes` : parmi les tentatives comptées dans
        /// `attemptCount`, combien n'ont pas de `uploadedBytes` connu. Elles
        /// ne contribuent rien à `networkBytesSent` — jamais un zéro silencieux
        /// mélangé au total, un compte à part.
        case inProgress(attemptCount: Int, networkBytesSent: Int64, attemptsWithUnknownBytes: Int)
        case completed(confirmedAt: Date)
    }

    public var path: String
    public var state: State

    public init(path: String, state: State) {
        self.path = path
        self.state = state
    }
}

/// Construit un `FirstUploadTracking` à partir de l'historique des
/// `BackupAttempt` et du verdict de couverture déjà calculé pour ce chemin.
public enum FirstUploadEvaluator {

    /// - Parameters:
    ///   - coverage: Le `SourceCoverage.State` déjà calculé pour ce chemin
    ///     par `SourceCoverageEvaluator`. Un chemin couvert — frais ou périmé
    ///     — a par définition un premier envoi terminé ; ce n'est pas
    ///     recalculé ici, pour ne garder qu'une seule définition de
    ///     « couvert » dans tout le fichier.
    ///   - attempts: L'historique complet du journal, dans n'importe quel
    ///     ordre.
    ///   - sourcePaths: `BackupConfiguration.sourcePaths` en entier — sert
    ///     uniquement à savoir si `path` est le seul chemin configuré.
    ///
    /// **La limite qu'il faut connaître.** `BackupAttempt` ne porte pas le
    /// chemin qu'elle a tenté de sauvegarder — seul `attempt.proof`, quand il
    /// existe, le porte via `proof.sourcePath`. Une tentative qui a échoué
    /// avant de produire le moindre manifeste ne dit donc jamais, par
    /// elle-même, quelle source elle visait. Avec un seul chemin configuré —
    /// le cas réel du propriétaire — l'ambiguïté n'existe pas : toute
    /// tentative du journal vise forcément ce chemin-là, et c'est
    /// l'hypothèse que cette fonction fait alors. Avec plusieurs chemins
    /// configurés, elle refuse de deviner et ne retient que les tentatives
    /// dont le proof, même non prouvé, porte explicitement ce chemin — au
    /// prix de sous-compter les tentatives échouées sans manifeste, plutôt
    /// que de risquer de les attribuer au mauvais dossier.
    public static func track(
        path: String,
        coverage: SourceCoverage.State,
        attempts: [BackupAttempt],
        sourcePaths: [String]
    ) -> FirstUploadTracking {
        switch coverage {
        case .covered(let at), .coveredButStale(let at):
            return FirstUploadTracking(path: path, state: .completed(confirmedAt: at))

        case .neverBackedUp:
            let relevant = sourcePaths.count <= 1
                ? attempts
                : attempts.filter { attempt in
                    guard let proof = attempt.proof else { return false }
                    return sameDirectory(proof.sourcePath, path)
                }

            guard !relevant.isEmpty else {
                return FirstUploadTracking(path: path, state: .neverStarted)
            }

            var totalBytes: Int64 = 0
            var unknown = 0
            for attempt in relevant {
                if let bytes = attempt.uploadedBytes {
                    totalBytes += bytes
                } else {
                    unknown += 1
                }
            }

            return FirstUploadTracking(
                path: path,
                state: .inProgress(
                    attemptCount: relevant.count,
                    networkBytesSent: totalBytes,
                    attemptsWithUnknownBytes: unknown
                )
            )
        }
    }

    /// Une phrase française sur l'état d'un premier envoi. Nomme
    /// explicitement ce que compte `networkBytesSent` — jamais « sauvegardé »,
    /// pour la raison décrite sur `FirstUploadTracking.State.inProgress`.
    public static func summary(_ tracking: FirstUploadTracking) -> String {
        switch tracking.state {
        case .neverStarted:
            return "Premier envoi de \(tracking.path) : jamais commencé."

        case .inProgress(let attemptCount, let bytes, let unknown):
            let attemptWord = attemptCount > 1 ? "tentatives" : "tentative"
            var text = "Premier envoi de \(tracking.path) en cours depuis \(attemptCount) \(attemptWord) : "
                + "\(gigaoctets(bytes)) montés sur le réseau, reprises comprises."
            if unknown > 0 {
                let word = unknown > 1 ? "tentatives" : "tentative"
                text += " \(unknown) \(word) sans volume connu, non comptée\(unknown > 1 ? "s" : "") dans ce total."
            }
            return text

        case .completed(let confirmedAt):
            return "Premier envoi de \(tracking.path) terminé le \(frenchDate(confirmedAt))."
        }
    }
}

// MARK: - Chemins : comparaison par composants, jamais par chaîne

/// Découpe un chemin en composants, en ignorant les composants vides. C'est
/// ce qui rend `/Users/x/` et `/Users/x` identiques sans code spécial pour la
/// barre oblique finale, en tête ou au milieu.
private func pathComponents(_ path: String) -> [String] {
    path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
}

/// Vrai quand `candidate` couvre `target` : `target` est `candidate` lui-même
/// ou un de ses descendants. Jamais l'inverse — un snapshot de `~/Music` ne
/// couvre pas `~`, même si `~/Music` est listé en second dans `sourcePaths`.
///
/// **La casse : décision délibérée.** APFS est insensible à la casse par
/// défaut mais la préserve — un volume formaté autrement, sensible à la
/// casse, existe mais reste rare et se choisit explicitement à
/// l'initialisation. Comparer en ignorant la casse ferait courir le risque
/// inverse : sur ce volume rare, deux dossiers réellement distincts
/// pourraient se déclarer mutuellement couverts. Comparer en respectant la
/// casse ne fait, dans le pire cas — un volume insensible à la casse où deux
/// chemins ne diffèrent que par elle — que rater une couverture réelle : le
/// chemin reste affiché `neverBackedUp` alors qu'il est en fait sauvegardé.
/// Entre sur-déclarer et sous-déclarer une couverture, ce fichier existe pour
/// ne jamais prendre le premier risque. D'où la comparaison sensible à la
/// casse, dans les deux fonctions ci-dessous.
private func path(_ candidate: String, covers target: String) -> Bool {
    let candidateComponents = pathComponents(candidate)
    let targetComponents = pathComponents(target)
    guard candidateComponents.count <= targetComponents.count else { return false }
    return zip(candidateComponents, targetComponents).allSatisfy { $0 == $1 }
}

/// Vrai quand deux chemins désignent le même dossier — la relation
/// symétrique dont `FirstUploadEvaluator` a besoin pour attribuer une
/// tentative à un chemin configuré, distincte de `covers` qui est
/// délibérément asymétrique.
private func sameDirectory(_ lhs: String, _ rhs: String) -> Bool {
    pathComponents(lhs) == pathComponents(rhs)
}

// MARK: - Mise en forme

private func gigaoctets(_ bytes: Int64) -> String {
    guard bytes > 0 else { return "0 Go" }
    let go = Double(bytes) / 1_000_000_000
    guard go >= 0.1 else { return "moins de 0,1 Go" }
    let rounded = (go * 10).rounded() / 10
    return String(format: "%.1f", rounded).replacingOccurrences(of: ".", with: ",") + " Go"
}

private func frenchDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    // Locale et fuseau fixés en dur : ce texte est affiché en français quel
    // que soit le réglage régional du Mac, comme le reste de bran, et il doit
    // rester le même dans un test qu'il tourne à Roubaix ou en Indonésie.
    formatter.locale = Locale(identifier: "fr_FR")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "dd/MM/yyyy"
    return formatter.string(from: date)
}
