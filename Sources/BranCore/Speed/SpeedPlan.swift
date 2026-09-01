import Foundation

/// **Où l'on mesure, et jusqu'où l'on va.** Aucun réseau ici : ce fichier ne
/// contient que les décisions, pour qu'elles soient lisibles au même endroit et
/// vérifiables sans connexion.
///
/// ## Le choix du service, et il a été mesuré
///
/// Quatre candidats ont été chronométrés depuis le poste le 31/08/2026, même
/// méthode pour tous — médiane de tranches de 250 ms, rampe d'une seconde
/// écartée :
///
/// | Source | 1 connexion | 4 connexions | Verdict |
/// |---|---|---|---|
/// | `proof.ovh.net` (Roubaix) | **15,2 Mo/s** | 14,9 Mo/s | retenu |
/// | `ash-speed.hetzner.com` | 13,1 Mo/s | 14,4 Mo/s | repli |
/// | `speed.cloudflare.com/__down` | 6,1 Mo/s | 10,2 Mo/s | **écarté** |
/// | `speed.hetzner.de` | injoignable | — | écarté |
///
/// **Cloudflare a été écarté pour la descente, et c'est le résultat qui a
/// renversé la conception.** Le plan d'origine était le sien — anycast, pas de
/// clé, endpoint de montée fourni — et il prévoyait quatre connexions
/// parallèles parce qu'une seule plafonnait à 6 Mo/s. La mesure a montré que ce
/// plafond n'était pas celui de la ligne mais celui d'une connexion Cloudflare :
/// une seule connexion vers un hôte bien raccordé sature les mêmes 15 Mo/s. Le
/// parallélisme ne compensait pas la ligne, il compensait le bridage — et
/// quatre connexions coûtent quatre poignées de main TLS, quatre montées en
/// régime TCP, et une complexité de mesure entière, pour rien.
///
/// Deux autres faits l'ont achevé, et aucun n'était devinable :
///
/// - **Il limite le débit de requêtes sur le volume cumulé, pas sur le nombre.**
///   Après une série d'essais, `bytes=5000000` passait encore quand
///   `bytes=10000000` rendait `429 Too Many Requests` — et l'accès aux grosses
///   requêtes est resté fermé plus de vingt minutes. Un bouton qu'on peut
///   recliquer aurait heurté ce mur devant l'utilisateur.
/// - **Il filtre par `User-Agent`.** `Python-urllib/3.14` reçoit un `403`
///   là où `curl/8.7.1`, `bran/0.1.4` et l'absence totale d'en-tête reçoivent
///   un `200`. D'où `userAgent` ci-dessous, explicite et honnête : bran dit son
///   nom, ne se déguise pas en navigateur, et ne dépend pas de ce que URLSession
///   met par défaut.
///
/// **Cloudflare reste pour la montée**, parce qu'il est le seul à l'accepter :
/// `proof.ovh.net` rend `413 Payload Too Large` sur un POST, et
/// `ash-speed.hetzner.com` refuse la connexion. C'est une dépendance assumée à
/// un service qui peut dire non, et c'est la raison pour laquelle
/// `SpeedReading.upload` est optionnel indépendamment du reste : une montée
/// refusée ne doit pas emporter une descente réussie.
public enum SpeedPlan {

    /// Ce que bran annonce. **Son nom et sa version, rien d'autre.**
    ///
    /// Se faire passer pour un navigateur passerait tous les filtres et serait
    /// un mensonge adressé à un service qu'on utilise gratuitement. Le nom
    /// propre passe — c'est mesuré — et il a l'avantage d'être ce qu'un
    /// administrateur verra dans ses journaux s'il se demande qui tire ses
    /// fichiers.
    public static func userAgent(version: String) -> String { "bran/\(version)" }

    /// Une source de descente : un fichier statique, gros, chez un hôte bien
    /// raccordé.
    ///
    /// **Un fichier statique et pas un générateur.** Le `__down` de Cloudflare
    /// fabrique sa charge à la volée, ce qui se paie en délai avant le premier
    /// octet — mesuré jusqu'à **0,9 s**, et variant de 0,2 à 0,9 sans rapport
    /// avec la taille demandée. Un fichier posé sur un disque commence à sortir
    /// tout de suite. Le délai n'entre de toute façon pas dans le chiffre — la
    /// mesure part du premier octet — mais il entre dans le temps que
    /// l'utilisateur passe devant une animation qui ne bouge pas.
    public struct Source: Equatable, Sendable {
        /// Ce qui s'affiche sous le chiffre. Le lieu compte autant que le nom :
        /// un débit se compare à la distance qu'il a parcourue.
        public var name: String
        public var url: URL

        public init(name: String, url: URL) {
            self.name = name
            self.url = url
        }
    }

    /// Les sources de descente, **dans l'ordre d'essai**.
    ///
    /// OVH d'abord parce qu'il est en France, donc le plus proche d'ici, et
    /// parce qu'il a rendu le meilleur chiffre des quatre candidats. Hetzner
    /// ensuite : il a rendu un chiffre équivalent, il est ailleurs — un autre
    /// pays, un autre opérateur de transit —, ce qui est exactement ce qu'on
    /// veut d'un repli. Si les deux tombent, c'est presque sûrement la ligne
    /// qui est tombée, et c'est une réponse en soi.
    public static let downloadSources: [Source] = [
        Source(
            name: "OVH — Roubaix",
            // 1 Gio : assez grand pour qu'aucune ligne testable ne le finisse
            // avant l'échéance. La taille du fichier n'est pas la taille du
            // téléchargement — on coupe à l'échéance ou au plafond, voir
            // `Budget` — mais un fichier qui se termine tout seul terminerait le
            // test sur une tranche partielle et un débit qui s'effondre.
            url: URL(string: "https://proof.ovh.net/files/1Gb.dat")!
        ),
        Source(
            name: "Hetzner — Ashburn",
            url: URL(string: "https://ash-speed.hetzner.com/1GB.bin")!
        ),
    ]

    /// L'unique source de montée. Voir l'en-tête : c'est la seule qui accepte un
    /// POST.
    public static let uploadSource = Source(
        name: "Cloudflare",
        url: URL(string: "https://speed.cloudflare.com/__up")!
    )

    /// Où l'on sonde la latence.
    ///
    /// **Le même hôte que la descente**, et c'est ce qui rend le panneau
    /// cohérent : une latence mesurée vers un serveur et un débit mesuré vers un
    /// autre ne décrivent pas le même trajet, et le couple « 15 Mo/s, 12 ms »
    /// serait un assemblage de deux vérités qui ne se sont jamais rencontrées.
    /// La requête est une plage d'un octet — voir `SpeedLatency` pour ce que ça
    /// mesure exactement, et pour ce que ça ne mesure pas.
    public static func latencyProbe(for source: Source) -> URL { source.url }

    /// **Ce qu'un test s'autorise à consommer, et pendant combien de temps.**
    ///
    /// Les deux limites existent parce qu'aucune ne suffit seule, et c'est
    /// arithmétique :
    ///
    /// - Une limite en **octets** seule fait durer le test en proportion inverse
    ///   de la ligne. 60 Mo passent en quatre secondes ici et en dix minutes sur
    ///   un partage de connexion en bord de réseau — c'est-à-dire exactement là
    ///   où l'on tient le moins à télécharger 60 Mo.
    /// - Une limite en **temps** seule fait consommer en proportion de la ligne.
    ///   Quatre secondes coûtent 60 Mo ici, et 500 Mo sur une fibre à 1 Gbit/s.
    ///
    /// On prend donc la première des deux qui tombe. La conséquence voulue :
    /// **une ligne lente coûte peu d'octets, une ligne rapide coûte peu de
    /// temps**, et personne ne paie les deux.
    public struct Budget: Equatable, Sendable {
        public var duration: TimeInterval
        public var byteCap: Int

        public init(duration: TimeInterval, byteCap: Int) {
            self.duration = duration
            self.byteCap = byteCap
        }

        /// **Le plancher : la durée en dessous de laquelle il n'y a rien à
        /// lire.**
        ///
        /// Il est *dérivé* de `SpeedTally` et non recopié, parce que les deux
        /// doivent bouger ensemble : la rampe écartée, le plateau minimal, et la
        /// tranche ouverte qu'on ne compte jamais. Aujourd'hui 2,25 s.
        ///
        /// **Ce plancher a été ajouté après un échec observé.** Le plafond
        /// d'octets de la montée — 24 Mo à l'époque — était atteint en 1,08 s sur
        /// une ligne qui montait à 32 Mo/s. Il ne restait que trois tranches
        /// closes, moins que la rampe, et le panneau affichait « — » : un test
        /// qui avait envoyé vingt-quatre mégaoctets sans rien pouvoir en dire.
        /// Un plafond qui coupe avant la conclusion ne protège personne, il
        /// dépense pour rien.
        public static let floor =
            Double(SpeedTally.rampWindows + SpeedTally.minimumWindows + 1) * SpeedTally.window

        /// Le test rapide, celui du bouton.
        ///
        /// **4 s**, parce que la mesure en réclame déjà 2,25 (`floor`) et qu'une
        /// marge est ce qui donne à la médiane de quoi ignorer un creux. Sur la
        /// ligne du poste, quatre secondes ont livré douze à seize tranches, avec
        /// des valeurs allant de 5,2 à 40,2 Mo/s : c'est exactement le genre de
        /// dispersion qu'une médiane sur quatre tranches n'absorberait pas.
        ///
        /// **120 Mo**, parce que c'est ce que quatre secondes coûtent sur une
        /// ligne à 240 Mbit/s. Au-delà, le plafond mord et le test se termine
        /// plus tôt — mais jamais avant `floor`.
        public static let quick = Budget(duration: 4, byteCap: 120_000_000)

        /// La montée. Même durée, plafond deux fois plus bas : la plupart des
        /// lignes françaises montent trois à cinq fois moins vite qu'elles ne
        /// descendent, et sur celles-là le plafond ne sera jamais atteint.
        public static let upload = Budget(duration: 4, byteCap: 60_000_000)

        /// Faut-il s'arrêter ? Une seule question, posée au même endroit par la
        /// descente et par la montée.
        ///
        /// **L'échéance peut couper à tout moment, le plafond non.** La
        /// dissymétrie est le correctif décrit dans `floor` : arriver au bout du
        /// temps imparti est une fin normale, quel que soit ce qu'on a pu
        /// mesurer ; avoir dépensé ses octets avant d'avoir de quoi répondre est
        /// une dépense pure, et il vaut mieux en dépenser un peu plus que de
        /// n'avoir rien à montrer.
        ///
        /// **Ce que ça coûte sur une ligne très rapide, et c'est assumé.** Sur
        /// une fibre à 1 Gbit/s, le plancher impose 2,25 s de transfert, soit
        /// près de 300 Mo — bien au-delà du plafond. Il n'y a pas d'échappatoire :
        /// la montée en régime de TCP dure une seconde quelle que soit la
        /// vitesse, parce qu'elle est gouvernée par les allers-retours et non par
        /// le débit. Mesurer moins longtemps reviendrait à publier la rampe.
        /// L'alternative honnête n'est pas de tricher sur le chiffre, c'est de
        /// dire ce qu'on a consommé — ce que fait `SpeedReading.spentBytes`.
        public func isSpent(elapsed: TimeInterval, bytes: Int) -> Bool {
            if elapsed >= duration { return true }
            return bytes >= byteCap && elapsed >= Self.floor
        }
    }

    // MARK: - Le délai qui n'existe plus
    //
    // **Il y avait ici un `cooldown` de trente secondes, et `SpeedGate` pour le
    // faire respecter. Les deux ont été retirés.**
    //
    // L'argument tenait, et il est toujours vrai : Cloudflare limite sur le
    // volume cumulé et a fermé la porte plus de vingt minutes après une rafale
    // (voir l'en-tête). Un bouton qu'on mitraille finit par afficher une panne
    // que bran a lui-même provoquée.
    //
    // Ce qu'il ne pesait pas, c'est **à quoi sert ce compteur**. Il était écrit
    // pour la curiosité — « combien fait ma ligne » — et son commentaire le
    // disait : « personne ne mesure sa ligne deux fois dans la même demi-minute
    // pour une autre raison que l'impatience ». C'est faux dès qu'on s'en sert
    // pour ce à quoi il est réellement le plus utile : **diagnostiquer une panne
    // intermittente**. Une coupure d'une seconde toutes les dix minutes ne se
    // trouve qu'en tirant des mesures quand on la soupçonne, en rafale, sans
    // qu'un minuteur décide à votre place que vous êtes impatient. Le
    // propriétaire du poste a exactement cette panne, et le délai le gênait
    // pendant qu'il la cherchait.
    //
    // **Ce qui remplace le délai, et pourquoi c'est suffisant.** Le risque n'a
    // jamais été symétrique :
    //
    // - La **descente** tire sur `proof.ovh.net`, un fichier statique qui n'a
    //   jamais limité quoi que ce soit, même sous rafale d'essais. C'est le
    //   chiffre qu'on vient chercher, et il est désormais relançable sans aucune
    //   retenue.
    // - La **montée** tire sur Cloudflare, le seul à l'accepter, et c'était lui
    //   le risque. Il s'avère plus petit qu'on ne le craignait : la limite
    //   mesurée portait sur `__down?bytes=`, et `__up` a encaissé sans broncher
    //   **240 Mo en huit POST simultanés de 30 Mo** (01/09/2026), tous en `200`.
    //   Six POST de 20 Mo à la suite, également tous en `200`. Le mur des vingt
    //   minutes gardait la porte de descente, pas celle de montée — et bran
    //   n'utilise plus la première.
    //
    //   Ça ne prouve pas qu'aucune limite n'existe, et le filet reste : si un
    //   `429` arrive, il ne fait pas échouer le test — il ne le faisait déjà pas
    //   — mais il est désormais **nommé**, voir `SpeedMiss`. Le relevé disait
    //   « ↑ — » sans rien expliquer, ce qui, sur un compteur qu'on relance en
    //   boucle, aurait fini par faire accuser la ligne à la place de bran.
    //   C'était le vrai danger de retirer le délai, et c'est celui-là qu'on
    //   ferme — en nommant le coupable plutôt qu'en interdisant le geste.
}
