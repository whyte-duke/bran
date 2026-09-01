import Foundation

/// **Ce que la ligne permet de faire**, dit en usages plutôt qu'en mégabits.
///
/// ```
///   14,3 Mo/s · 71 ms ─▶ ✓ Messagerie      ✓ Visioconférence
///                        ✓ Appels audio    ✓ Streaming HD
///                        ✓ Musique         ✓ Streaming 4K
///                        ✓ Jeu en ligne
/// ```
///
/// **Pourquoi cette liste existe.** « 115 Mbit/s » ne répond pas à la question
/// qu'on se pose en lançant un test de débit ; on la lance parce que la visio
/// vient de sauter, ou parce qu'on hésite à lancer un film. Un nombre nu oblige
/// chacun à refaire, de tête et mal, la conversion vers son usage.
///
/// ## D'où viennent ces seuils, et ce qu'ils ne sont pas
///
/// **Ce sont les besoins publiés par les services eux-mêmes, pas des mesures de
/// bran.** bran n'a jamais chronométré un film Netflix ni une réunion Zoom, et
/// ce fichier ne prétend pas le contraire. Ce sont des repères de l'ordre de
/// grandeur, choisis dans le sens prudent : le seuil du streaming 4K est à
/// 15 Mbit/s parce que c'est le débit recommandé, pas le débit minimal auquel
/// une image finit par apparaître.
///
/// **Un seul de ces usages ne dépend pas du débit.** Le jeu en ligne consomme
/// très peu — quelques dizaines de kilobits — et se juge entièrement à la
/// latence et à la gigue. Le ranger sur la même échelle que le streaming, comme
/// le font la plupart des compteurs, donne un ✓ à une ligne de fibre dont les
/// 200 ms rendent le jeu injouable. Il a donc son propre critère, et c'est
/// exactement pourquoi `SpeedUse` porte deux exigences au lieu d'une.
public struct SpeedUse: Identifiable, Equatable, Sendable {

    public var id: String { title }
    public var title: String

    /// Le débit descendant nécessaire, en mégabits par seconde. `nil` quand
    /// l'usage ne se joue pas là — c'est le cas du jeu en ligne.
    public var megabits: Double?

    /// L'aller-retour au-delà duquel l'usage devient pénible, en secondes.
    /// `nil` quand la latence n'est pas le facteur limitant, ce qui est le cas de
    /// tout ce qui se met en mémoire tampon.
    public var latencyCeiling: TimeInterval?

    /// L'irrégularité au-delà de laquelle l'usage devient pénible, en secondes.
    ///
    /// **Ce plafond manquait, et son absence rendait le verdict faux.** La gigue
    /// était mesurée, affichée dans le menu, et jamais consultée. Sur une ligne
    /// réelle — 1,6 Mbit/s, 40 ms de latence, **153 ms de gigue** — bran
    /// annonçait « suffisant jusqu'à : jeu en ligne », donc aussi la
    /// visioconférence. Les deux sont impraticables à cette gigue-là : un
    /// tampon de réception vide et se remplit, la voix se hache, l'image gèle.
    ///
    /// C'est le pire genre d'erreur pour ce panneau : il donnait son feu vert
    /// exactement aux deux usages que la ligne ne tenait pas, et il le donnait
    /// en s'appuyant sur un nombre qu'il affichait deux lignes plus haut.
    ///
    /// `nil` pour tout ce qui se met en mémoire tampon : un film encaisse une
    /// seconde d'irrégularité sans que personne ne le voie.
    public var jitterCeiling: TimeInterval?

    /// Le symbole de la ligne. Un usage se reconnaît à son icône avant de se
    /// lire.
    public var symbol: String

    public init(
        title: String,
        megabits: Double? = nil,
        latencyCeiling: TimeInterval? = nil,
        jitterCeiling: TimeInterval? = nil,
        symbol: String
    ) {
        self.title = title
        self.megabits = megabits
        self.latencyCeiling = latencyCeiling
        self.jitterCeiling = jitterCeiling
        self.symbol = symbol
    }

    /// La ligne tient-elle cet usage ?
    ///
    /// **Les exigences sont conjonctives** : il faut le débit **et** la latence
    /// **et** la régularité. Une seule qui manque suffit à rendre l'usage
    /// pénible, et c'est bien ce qu'on observe — une fibre à 200 Mbit/s dont la
    /// gigue monte à 150 ms ne permet pas de tenir une visio.
    ///
    /// **`nil` veut dire « on ne sait pas », et se propage.** Un usage jugé sur
    /// la latence alors qu'aucune latence n'a été mesurée ne doit pas répondre
    /// « oui » : ce serait la seule ligne du panneau à affirmer quelque chose
    /// qu'on n'a pas regardé.
    public func verdict(download: Double?, latency: TimeInterval?, jitter: TimeInterval?) -> Bool? {
        var answer: Bool?

        if let megabits {
            guard let download else { return nil }
            answer = (download * 8 / SpeedFormat.bytesPerMegabyte) >= megabits
        }

        if let latencyCeiling {
            guard let latency else { return nil }
            answer = (answer ?? true) && latency <= latencyCeiling
        }

        if let jitterCeiling {
            guard let jitter else { return nil }
            answer = (answer ?? true) && jitter <= jitterCeiling
        }

        return answer
    }

    /// **La régularité est-elle la seule chose qui manque ?**
    ///
    /// C'est la question qui fait la différence entre un diagnostic utile et un
    /// verdict décourageant. Une ligne rapide et irrégulière — un Wi-Fi qui
    /// partage son canal avec le voisin, par exemple — passe tous les seuils de
    /// débit et échoue sur les seuls usages en temps réel. Dire « votre ligne
    /// suffit jusqu'au streaming 4K » sans ajouter « mais pas pour les appels »
    /// serait exact et trompeur : c'est précisément l'usage pour lequel on a
    /// lancé le test.
    public func limitedByJitter(download: Double?, latency: TimeInterval?, jitter: TimeInterval?) -> Bool {
        guard jitterCeiling != nil else { return false }
        // Le verdict complet dit non…
        guard verdict(download: download, latency: latency, jitter: jitter) == false else { return false }
        // …alors que sans la régularité, il aurait dit oui.
        var withoutJitter = self
        withoutJitter.jitterCeiling = nil
        return withoutJitter.verdict(download: download, latency: latency, jitter: jitter) == true
    }
}

public enum SpeedGrade {

    /// La liste, **du moins exigeant au plus exigeant**.
    ///
    /// L'ordre n'est pas cosmétique : il fait que la colonne des coches se
    /// remplit par le haut et se vide par le bas, donc que la première ligne
    /// sans coche est la frontière de la ligne. Une liste mélangée obligerait à
    /// lire les sept lignes pour trouver cette frontière.
    ///
    /// Le jeu en ligne est **rangé selon sa latence** et non selon un débit
    /// qu'il n'a pas : il vient juste après la visioconférence, parce que 60 ms
    /// est à peu près aussi difficile à tenir que 1,5 Mbit/s sur les lignes où
    /// l'un des deux manque.
    ///
    /// **L'ordre a été corrigé par son propre test.** La première version
    /// plaçait la musique en streaming (0,32 Mbit/s) après les appels audio
    /// (0,5), simplement parce que la musique paraît plus lourde qu'un appel.
    /// Sur une ligne à 0,4 Mbit/s la colonne affichait donc une coche, une
    /// croix, puis une coche — et la frontière que cet ordre existe pour montrer
    /// n'était plus lisible. `SpeedGradeTests.listIsOrdered` vérifie maintenant
    /// que les exigences de débit sont croissantes, ce qu'aucune relecture
    /// n'avait attrapé.
    public static let uses: [SpeedUse] = [
        SpeedUse(title: "Messagerie", megabits: 0.05, symbol: "message"),
        SpeedUse(title: "Appels audio", megabits: 0.1, jitterCeiling: 0.05, symbol: "phone"),
        SpeedUse(title: "Musique en streaming", megabits: 0.32, symbol: "music.note"),
        SpeedUse(
            title: "Visioconférence",
            megabits: 1.5, latencyCeiling: 0.15, jitterCeiling: 0.05,
            symbol: "video"
        ),
        SpeedUse(
            title: "Jeu en ligne",
            latencyCeiling: 0.06, jitterCeiling: 0.03,
            symbol: "gamecontroller"
        ),
        SpeedUse(title: "Streaming HD", megabits: 5, symbol: "play.rectangle"),
        SpeedUse(title: "Streaming 4K", megabits: 15, symbol: "4k.tv"),
    ]

    /// **D'où viennent les plafonds de régularité.**
    ///
    /// De la même source que les seuils de débit — les recommandations
    /// publiées — et pas de mesures de bran : personne ici n'a chronométré une
    /// partie en ligne. L'usage constant dans la téléphonie sur IP place la
    /// bonne qualité sous 30 ms de gigue, l'acceptable jusqu'à 50, et le
    /// pénible au-delà ; le jeu, qui n'a aucun tampon à opposer, tient le seuil
    /// le plus serré. D'où 50 ms pour les appels et la visio, 30 ms pour le jeu.
    ///
    /// Les valeurs sont choisies dans le sens prudent, comme les débits : elles
    /// décrivent le seuil au-delà duquel l'usage **devient pénible**, pas celui
    /// où il cesse de fonctionner.

    /// La phrase du résumé. Elle nomme **le plus exigeant des usages tenus**,
    /// parce que c'est la seule information que la liste ne donne pas d'un coup
    /// d'œil — et parce que le menu déroulant n'a pas la place de la liste.
    ///
    /// **Et elle dit ce que la régularité coûte, quand c'est elle qui coupe.**
    /// Sans cette seconde phrase, une ligne rapide et irrégulière s'annoncerait
    /// « suffisante jusqu'au streaming 4K » alors que les appels ne passent pas :
    /// exact, et trompeur au point d'être inutile — parce que c'est justement
    /// quand la visio saute qu'on lance un test de débit.
    ///
    /// Le repli n'est pas « aucun usage » mais une phrase qui dit ce qui a été
    /// mesuré : une ligne trop lente pour la messagerie est presque toujours une
    /// ligne en train de tomber, pas une ligne lente, et annoncer « rien ne
    /// passe » serait plus alarmant que juste.
    public static func summary(
        download: Double?,
        latency: TimeInterval?,
        jitter: TimeInterval?
    ) -> String {
        guard download != nil || latency != nil else { return "Rien n'a pu être mesuré." }

        let held = uses.filter { $0.verdict(download: download, latency: latency, jitter: jitter) == true }
        let base = held.last.map { "Suffisant jusqu'à : \($0.title.lowercased())." }
            ?? "Trop juste pour un usage courant."

        let broken = uses.filter { $0.limitedByJitter(download: download, latency: latency, jitter: jitter) }
        guard broken.isEmpty == false else { return base }

        let names = broken.map { $0.title.lowercased() }.joined(separator: ", ")
        return "\(base) La gigue de \(SpeedFormat.milliseconds(jitter)) gêne : \(names)."
    }
}
