import Foundation

// Lit une liste de `LinkProbeResult` déjà mesurés et rend un `ChainVerdict`.
// Ne sonde rien : la panne fondatrice — un conteneur MinIO arrêté 35 jours
// pendant qu'un réglage local disait « prêt » — n'était pas un défaut de
// sonde, c'était l'absence de quelqu'un pour lire les six résultats ensemble
// et refuser d'en présumer un septième. C'est tout le rôle de ce fichier.
public enum ChainEvaluator {

    /// Le verdict sur la chaîne, à l'instant `now`.
    ///
    /// `results` peut être incomplet, en désordre, dupliqué ou périmé — les
    /// six sondes ne se déclenchent pas forcément ensemble, et l'interface ne
    /// doit jamais reconstruire cette hygiène elle-même. Cette fonction la
    /// fait une fois, ici.
    public static func evaluate(
        _ results: [LinkProbeResult],
        now: Date,
        freshness: TimeInterval
    ) -> ChainVerdict {
        let chain = completeChain(results, now: now, freshness: freshness)

        // Le premier `down`, où qu'il tombe dans la liste, est la cause :
        // c'est la seule mesure qui affirme un fait plutôt qu'une absence de
        // fait. Un maillon plus proche mais seulement `unknown` ou
        // `connecting` ne doit pas lui voler l'accusation, sans quoi le
        // bandeau redeviendrait aussi vague que l'ancien « pas prêt ».
        if let culprit = chain.first(where: { $0.state == .down }) {
            return ChainVerdict(
                results: chain,
                firstFailure: culprit.link,
                headline: culprit.diagnostic,
                canBackUp: false
            )
        }

        // Ici, plus aucun `down` : ce qui reste de non vert est mou par
        // nature (en cours, inconnu, dégradé), donc c'est l'ordre de la
        // chaîne — et lui seul — qui choisit lequel commenter.
        //
        // **Mais tous les états mous ne donnent pas le même droit.** `degraded`
        // autorise la sauvegarde, `unknown` et `connecting` l'interdisent. Se
        // contenter du premier non-vert faisait donc dépendre ce droit de
        // l'ordre d'apparition : sur la chaîne
        //
        //     tailscale up · pair up · port up · santé MinIO **degraded**
        //     · seau up · dépôt Kopia **unknown**
        //
        // le `switch` tombait sur `degraded` en quatrième position, rendait
        // `canBackUp: true`, et personne ne regardait jamais le sixième
        // maillon — celui qui n'a jamais été sondé, ou dont la mesure est
        // périmée. C'est la panne des 35 jours reconstruite *à l'intérieur*
        // du verdict écrit pour la fermer : une ligne lente en amont suffisait
        // à faire passer une ignorance en aval pour un feu vert.
        //
        // On cherche donc d'abord un bloquant dans **toute** la chaîne, et
        // seulement ensuite un dégradé. L'ordre de la chaîne continue de
        // choisir lequel commenter, mais à l'intérieur des seuls bloquants.
        if let blocking = chain.first(where: { $0.state == .unknown || $0.state == .connecting }) {
            switch blocking.state {
            case .connecting:
                // Une ouverture de dépôt depuis l'Indonésie peut légitimement
                // prendre plusieurs dizaines de secondes : coller le mot
                // « échec » dessus apprendrait à ignorer le rouge le jour où
                // il est vrai.
                return ChainVerdict(
                    results: chain,
                    firstFailure: nil,
                    headline: "Connexion en cours — \(blocking.diagnostic)",
                    canBackUp: false
                )
            case .unknown:
                // Le diagnostic porte déjà la raison exacte : « jamais
                // sondé » pour un maillon absent de la liste, « mesure
                // périmée » pour un résultat trop vieux. On ne le reformule
                // pas, sans quoi une des deux raisons finirait par se
                // confondre avec l'autre dans le texte affiché.
                return ChainVerdict(
                    results: chain,
                    firstFailure: nil,
                    headline: blocking.diagnostic,
                    canBackUp: false
                )
            case .up, .down, .degraded:
                // Inatteignable : le filtre juste au-dessus ne retient que
                // `unknown` et `connecting`. Voir plus bas pour la raison
                // pour laquelle ces branches-là ne plantent pas.
                return unexpectedState(blocking, chain: chain)
            }
        }

        // Plus aucun bloquant : un maillon dégradé est le seul cas qui
        // autorise `canBackUp` sans que tout soit vert. Une ligne lente
        // sauvegarde quand même, elle met plus de temps. Le bandeau le dit
        // pour que « dégradé » ne se lise pas comme « en panne ».
        if let degraded = chain.first(where: { $0.state == .degraded }) {
            return ChainVerdict(
                results: chain,
                firstFailure: nil,
                headline: "Ligne dégradée — \(degraded.diagnostic)",
                canBackUp: true
            )
        }

        // Inatteignable aujourd'hui : les cinq états de `LinkState` sont tous
        // traités au-dessus. Cette ligne existe pour le jour où un sixième
        // s'ajoute sans passer par ici.
        if let unexpected = chain.first(where: { $0.state != .up }) {
            return unexpectedState(unexpected, chain: chain)
        }

        // Aucun maillon non vert : les six sont mesurés, frais, et bons.
        return ChainVerdict(
            results: chain,
            firstFailure: nil,
            headline: "La chaîne est verte : les six maillons répondent.",
            canBackUp: true
        )
    }

    /// La sortie de secours quand un maillon porte un état que ce fichier ne
    /// sait pas classer.
    ///
    /// **On ne plante pas.** Un `fatalError` était ici, au motif honorable
    /// qu'un `default:` silencieux serait pire. Sauf que cette fonction tourne
    /// aussi dans le job launchd, sans personne devant l'écran : un plantage y
    /// devient une sauvegarde qui ne s'est jamais lancée, sans trace et sans
    /// message. On aurait remplacé un mensonge par un silence, ce qui est le
    /// même défaut sous un autre nom.
    ///
    /// La sortie sûre n'a donc qu'une seule contrainte : elle ne doit pas
    /// pouvoir mentir. Refuser de sauvegarder et le dire franchement satisfait
    /// ça — le jour où un état s'ajoute à `LinkState` sans passer par ici,
    /// l'utilisateur voit une phrase étrange plutôt qu'un écran vide, et nous
    /// un rapport.
    private static func unexpectedState(
        _ result: LinkProbeResult,
        chain: [LinkProbeResult]
    ) -> ChainVerdict {
        ChainVerdict(
            results: chain,
            firstFailure: nil,
            headline: """
                État de maillon imprévu (\(result.state.rawValue)) \
                sur « \(result.link.rawValue) » — par précaution, \
                aucune sauvegarde n'est lancée.
                """,
            canBackUp: false
        )
    }

    /// Vrai quand `link` est en aval du maillon accusé par `verdict`, donc
    /// qu'il ne fait que répéter la même panne.
    ///
    /// Sert à l'affichage : le maillon 6 rouge parce que le maillon 2 est
    /// arrêté n'est pas une deuxième information, c'est un écho. L'interface
    /// s'en sert pour le poser en retrait plutôt qu'en alarme de plus. Sans
    /// accusation posée (`firstFailure == nil` — pas de `down`, ou chaîne
    /// verte), rien n'est la conséquence de rien.
    public static func isConsequence(_ link: ChainLink, of verdict: ChainVerdict) -> Bool {
        guard let firstFailure = verdict.firstFailure else { return false }
        return link > firstFailure
    }

    /// Réduit `results` aux six maillons de `ChainLink`, un par un, dans
    /// l'ordre de la chaîne : doublons résolus au plus récent, absents
    /// complétés en `unknown`, et périmés dégradés en `unknown` avant que
    /// quoi que ce soit d'autre ne les regarde.
    private static func completeChain(
        _ results: [LinkProbeResult],
        now: Date,
        freshness: TimeInterval
    ) -> [LinkProbeResult] {
        var latest: [ChainLink: LinkProbeResult] = [:]
        for result in results {
            if let existing = latest[result.link], existing.measuredAt >= result.measuredAt {
                continue
            }
            latest[result.link] = result
        }

        return ChainLink.allCases.map { link in
            guard let result = latest[link] else {
                return neverProbed(link, now: now)
            }
            let age = now.timeIntervalSince(result.measuredAt)
            guard age <= freshness else {
                return expired(result, age: age)
            }
            return result
        }
    }

    /// Un maillon qui n'apparaît pas dans `results` reste un maillon du
    /// verdict — jamais une case simplement omise, sans quoi une interface
    /// qui compterait les entrées de la liste plutôt que les six cas fixes
    /// verrait une chaîne « complète » avec un trou dedans.
    private static func neverProbed(_ link: ChainLink, now: Date) -> LinkProbeResult {
        LinkProbeResult(
            link: link,
            state: .unknown,
            diagnostic: "\(frenchName(link)) — jamais sondé depuis le lancement.",
            measuredAt: now
        )
    }

    /// La panne des 35 jours en une ligne : un résultat trop vieux ne porte
    /// plus l'état qu'il a mesuré, il porte le fait qu'on ne sait plus. Le
    /// texte le dit explicitement pour qu'un bandeau qui rejouerait l'ancien
    /// diagnostic — « MinIO répond » — ne puisse pas se glisser plus loin
    /// dans la chaîne d'appels par erreur de recopie.
    private static func expired(_ result: LinkProbeResult, age: TimeInterval) -> LinkProbeResult {
        LinkProbeResult(
            link: result.link,
            state: .unknown,
            diagnostic: "\(frenchName(result.link)) — dernière mesure périmée "
                + "(il y a \(Int(age)) s), écartée plutôt que réaffichée.",
            rawDetail: result.rawDetail,
            measuredAt: result.measuredAt
        )
    }

    /// Un nom lisible pour les diagnostics synthétisés ci-dessus. N'existe
    /// que pour ça : les diagnostics mesurés par les sondes portent déjà leur
    /// propre texte et n'y passent jamais.
    private static func frenchName(_ link: ChainLink) -> String {
        switch link {
        case .tailscaleLocal: "Tailscale"
        case .minioNodeOnline: "Le pair MinIO"
        case .s3Reachable: "Le port S3"
        case .minioHealthy: "La santé de MinIO"
        case .bucketReachable: "Le seau"
        case .repositoryOpens: "Le dépôt Kopia"
        }
    }
}
