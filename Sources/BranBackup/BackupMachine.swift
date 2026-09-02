import Foundation

// La machine à états de la sauvegarde. Pure : aucun `Process`, aucune horloge
// murale consultée ici — chaque transition ne réagit qu'à l'événement qu'on
// lui donne.
//
// **Ce fichier a une seule responsabilité, et elle est déjà écrite dans le
// contrat : ne jamais laisser `phase` devenir `.success` sans une preuve
// relue dans le dépôt.** `BackupPhase.success` exige un `SnapshotProof` par
// construction, mais rien dans le type n'empêche mécaniquement quelqu'un
// d'écrire `phase = .success(uneProuveQuiVientDeCreate)`. C'est cette
// discipline-là — jamais un raccourci de `createReturned` vers `.success` —
// que la machine impose, pas le compilateur.

/// Où en est une tentative, événement par événement.
///
/// **`phase` seul ne suffit pas à décider quand `.success` est légitime** :
/// entre le manifeste rendu par `create` et sa confirmation par
/// `snapshot list`, il faut se souvenir de *quel* identifiant on attend. Ce
/// souvenir vit dans `pendingProof`, en dehors de `phase`, parce que
/// `BackupPhase.verifying` ne porte volontairement aucune valeur associée —
/// ce n'est pas quelque chose que l'interface a besoin d'afficher, seule la
/// machine en a besoin pour comparer.
public struct BackupMachine: Sendable {
    public private(set) var phase: BackupPhase

    /// La preuve rendue par `create`, conservée le temps de la relire dans le
    /// dépôt. Effacée dès qu'elle a servi — succès ou échec, elle ne doit
    /// jamais survivre à la tentative qui l'a produite.
    private var pendingProof: SnapshotProof?

    /// `phase` est un paramètre et pas seulement `.idle` par défaut parce
    /// qu'un `BackupMachine` doit aussi pouvoir être reconstruit à partir
    /// d'une phase persistée (l'interface se relance en plein milieu d'une
    /// vérification), et parce que les tests de `canDisplaySaved` ont besoin
    /// de construire délibérément une phase invalide pour vérifier que la
    /// propriété se défend toute seule — voir sa documentation plus bas.
    public init(phase: BackupPhase = .idle) {
        self.phase = phase
        self.pendingProof = nil
    }

    /// Vrai quand quelque chose occupe le dépôt. Simple relais de
    /// `BackupPhase.isBusy` : la machine ne connaît qu'une seule définition
    /// de « occupé », et c'est celle du contrat.
    public var isBusy: Bool { phase.isBusy }

    /// **La seule question qui compte pour l'écran : a-t-il le droit
    /// d'écrire « sauvegardé » ?**
    ///
    /// Elle ne se contente pas de vérifier `phase == .success` : elle
    /// re-vérifie `proof.isTrustworthy` sur la preuve embarquée. La
    /// différence n'est pas cosmétique. `init(phase:)` est public — pour les
    /// raisons ci-dessus — donc rien n'empêche *structurellement* de
    /// construire `BackupMachine(phase: .success(uneProuveNonConfirmée))` en
    /// contournant toutes les transitions de ce fichier. Si cette propriété
    /// se contentait de lire la forme du cas, ce contournement mentirait à
    /// l'écran. En relisant la preuve elle-même, la garantie tient même
    /// quand la phase a été falsifiée à la main.
    public var canDisplaySaved: Bool {
        guard case .success(let proof) = phase else { return false }
        return proof.isTrustworthy
    }

    // MARK: - Démarrer une tentative

    /// Une nouvelle tentative commence : les six sondes se lancent.
    ///
    /// Ignoré si une tentative est déjà en cours — on ne relance pas une
    /// vérification de chaîne par-dessus un `kopia snapshot create` en vol.
    public mutating func chainCheckStarted() {
        guard !phase.isBusy else { return }
        pendingProof = nil
        phase = .checkingChain
    }

    /// Les six sondes ont rendu leur verdict.
    ///
    /// Le contrat n'a pas de phase « chaîne confirmée, prête à lancer » — en
    /// ajouter une rien que pour cette machine aurait dupliqué un concept
    /// pour un seul appelant. Quand la chaîne est bonne, on reste donc en
    /// `.checkingChain` (toujours occupé, toujours vrai) jusqu'à ce que
    /// `runStarted()` bascule réellement vers `.running`.
    public mutating func chainEvaluated(_ verdict: ChainVerdict) {
        guard case .checkingChain = phase else { return }

        if verdict.canBackUp {
            return
        }

        guard let firstFailure = verdict.firstFailure else {
            // `canBackUp` est faux sans qu'aucun maillon ne soit désigné
            // coupable : une sortie que la chaîne ne devrait jamais produire.
            // On ne devine pas de coupable à sa place.
            phase = .failed(BackupFailure(
                kind: .unparseable,
                summary: "La chaîne réseau est jugée mauvaise sans qu'aucun maillon ne soit désigné.",
                rawOutput: verdict.headline
            ))
            return
        }

        if firstFailure == .repositoryOpens {
            // Le maillon le plus cher — voir sa documentation dans le
            // contrat — a une vraie chance de dire une panne du dépôt lui-
            // même (mot de passe, format), pas un aléa réseau. On ne le
            // range pas avec les cinq autres, transitoires par nature.
            let detail = verdict.results.first(where: { $0.link == firstFailure })?.rawDetail
            phase = .failed(BackupFailure(
                kind: .repository,
                summary: verdict.headline,
                rawOutput: detail ?? verdict.headline,
                link: firstFailure
            ))
        } else {
            phase = .waitingForNetwork(verdict)
        }
    }

    // MARK: - Le run

    /// `kopia snapshot create` vient d'être lancé.
    ///
    /// Valide uniquement depuis `.checkingChain` : la chaîne n'ayant quitté
    /// cette phase que si elle est rouge (`chainEvaluated` l'aurait alors
    /// fait sortir vers `.waitingForNetwork` ou `.failed`), recevoir cet
    /// événement ailleurs signifierait démarrer un run sans chaîne verte —
    /// exactement ce que cette garde interdit.
    public mutating func runStarted() {
        guard case .checkingChain = phase else { return }
        phase = .running(BackupProgress())
    }

    /// Une nouvelle ligne de progression est arrivée.
    ///
    /// Une ligne de progression est la plus bavarde des sorties de Kopia —
    /// plusieurs par seconde — et donc la plus susceptible d'arriver en
    /// retard après qu'un échec ou une annulation aient déjà refermé la
    /// tentative. La laisser réanimer un run fantôme serait pire que de la
    /// perdre : hors de `.running`, elle est ignorée, sans planter et sans
    /// rien inventer. Cette cible est de la logique pure — pas de journal ni
    /// de `Logger` disponible pour la signaler autrement.
    public mutating func progressed(_ progress: BackupProgress) {
        guard case .running = phase else { return }
        phase = .running(progress)
    }

    /// `kopia snapshot create` a rendu un manifeste.
    ///
    /// **La ligne la plus surveillée de ce fichier : elle ne peut mener qu'à
    /// `.verifying`, jamais à `.success`.** Ce manifeste dit ce que le
    /// processus croit avoir écrit, pas ce que le dépôt contient — c'est
    /// exactement la distinction que `ProofOrigin` porte, et la relire ici
    /// serait recréer, à l'identique, la panne qui a coûté 143,1 Go de blocs
    /// sans un seul snapshot restaurable.
    public mutating func createReturned(_ proof: SnapshotProof) {
        guard case .running = phase else { return }
        pendingProof = proof
        phase = .verifying
    }

    /// `kopia snapshot list` a été relu après coup. `readBack` est
    /// exactement ce que le dépôt a rendu — la machine y cherche
    /// l'identifiant que `create` a annoncé, elle ne le suppose jamais
    /// présent.
    public mutating func repositoryConfirmed(_ readBack: [SnapshotProof]) {
        guard case .verifying = phase, let expected = pendingProof else { return }
        pendingProof = nil

        guard let found = readBack.first(where: { $0.id == expected.id }) else {
            // Le cas prioritaire de tout ce fichier : le dépôt relu ne
            // contient pas ce que `create` a dit avoir écrit. Ce n'est pas
            // un détail à absorber, c'est la panne mesurée le 02/09/2026.
            phase = .failed(BackupFailure(
                kind: .unparseable,
                summary: "le dépôt ne contient pas le snapshot que Kopia dit avoir écrit.",
                rawOutput: "id attendu \(expected.id) ; ids relus dans le dépôt : "
                    + (readBack.isEmpty ? "aucun" : readBack.map(\.id).joined(separator: ", "))
            ))
            return
        }

        if !found.isComplete {
            // Confirmé dans le dépôt n'est pas complet. On passe par
            // `isComplete`, jamais par une relecture manuelle de
            // `errorCount` : c'est la leçon d'`ignoredErrorCount` lui-même —
            // « Ignore file read errors: true » fait qu'un fichier verrouillé
            // n'incrémente que ce second compteur, sort avec le code 0, et un
            // contrôle qui n'en lirait qu'un des deux verrait un vert faux.
            // Le jour où un troisième compteur apparaît dans le contrat,
            // cette ligne n'a rien à changer.
            phase = .failed(BackupFailure(
                kind: .partialSnapshot,
                summary: partialSnapshotSummary(for: found),
                rawOutput: "id \(found.id), errorCount \(found.errorCount), "
                    + "ignoredErrorCount \(found.ignoredErrorCount), fileCount \(found.fileCount)"
            ))
            return
        }

        guard found.origin == .confirmedInRepository else {
            // Se protège d'un appelant qui, par erreur, repasserait la
            // preuve de `create` telle quelle en guise de confirmation, au
            // lieu du résultat d'une vraie relecture du dépôt. Sans ce
            // garde, un pilote paresseux ferait passer `.reportedByCreate`
            // pour une preuve — le mensonge que ce fichier existe pour
            // fermer, glissé une case plus loin.
            phase = .failed(BackupFailure(
                kind: .unparseable,
                summary: "la preuve reçue en confirmation ne vient pas d'une relecture du dépôt.",
                rawOutput: "id \(found.id), origin \(found.origin.rawValue)"
            ))
            return
        }

        // `found.isTrustworthy` est nécessairement vrai ici : errorCount == 0
        // vient d'être vérifié, origin == .confirmedInRepository aussi. On
        // le passe quand même par la propriété du contrat plutôt que par les
        // deux conditions déjà testées, pour qu'il n'existe qu'une lecture
        // de « digne de confiance » dans tout le projet.
        assert(found.isTrustworthy)
        phase = .success(found)
    }

    // MARK: - Fin anormale

    /// Un échec définitif — authentification, dépôt, stockage, snapshot
    /// partiel confirmé, sortie illisible. Ignoré hors d'une tentative en
    /// cours : un échec qui arrive en retard après qu'une annulation ou un
    /// autre échec aient déjà refermé l'état ne doit pas réécrire par-
    /// dessus une conclusion déjà actée.
    public mutating func failed(_ failure: BackupFailure) {
        guard phase.isBusy else { return }
        pendingProof = nil
        phase = .failed(failure)
    }

    /// Le run a été coupé — veille, extinction, choix de l'utilisateur. Rien
    /// n'est cassé : c'est `.interrupted`, jamais `.failed`. La distinction
    /// vient du contrat (`FailureKind.interrupted`) et conditionne si un
    /// rattrapage a un sens ; ne pas la respecter ferait échouer, dans le
    /// journal, des runs qui n'ont fait qu'attendre.
    public mutating func cancelled(reason: String = "La sauvegarde a été interrompue.") {
        guard phase.isBusy else { return }
        pendingProof = nil
        phase = .interrupted(BackupFailure(kind: .interrupted, summary: reason, rawOutput: ""))
    }

    // MARK: - Le message d'un snapshot partiel

    /// Le texte affiché quand un snapshot confirmé n'est pas complet.
    ///
    /// **Distingue les deux causes plutôt que de les additionner en
    /// silence.** « 352 erreurs » ne dit pas s'il faut s'inquiéter (des
    /// fichiers réellement illisibles) ou juste le savoir (des fichiers que
    /// la politique du dépôt a délibérément choisi d'ignorer). Un seul
    /// nombre fusionnerait ces deux gestes très différents en un seul.
    private func partialSnapshotSummary(for proof: SnapshotProof) -> String {
        var causes: [String] = []
        if proof.errorCount > 0 {
            let plural = proof.errorCount > 1 ? "s" : ""
            causes.append("\(proof.errorCount) fichier\(plural) illisible\(plural)")
        }
        if proof.ignoredErrorCount > 0 {
            let plural = proof.ignoredErrorCount > 1 ? "s" : ""
            causes.append("\(proof.ignoredErrorCount) ignoré\(plural) par la politique")
        }
        let count = proof.missingFileCount
        let plural = count > 1 ? "s" : ""
        let verb = count > 1 ? "manquent" : "manque"
        return "Le snapshot existe mais \(count) fichier\(plural) \(verb) : \(causes.joined(separator: ", "))."
    }
}
