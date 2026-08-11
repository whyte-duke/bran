import Foundation

/// Le découpage par jour d'une bibliothèque, partagé par les écrans qui en ont
/// une.
///
/// **Pourquoi ce fichier existe.** Les captures et les dictées portaient
/// chacune leur `DayGroup`, leur `grouped` et leur `dayTitle` — vingt-trois
/// lignes rigoureusement identiques à un nom de type près, recopiées d'un écran
/// à l'autre. L'historique du presse-papiers arrive et en aurait fait la
/// troisième copie. Trois copies d'une même règle de calendrier, c'est deux
/// copies qui dériveront : la première divergence n'aurait été ni un plantage ni
/// un test rouge, mais un écran qui dit « Hier » pendant que le voisin écrit la
/// date, et personne ne remarque ça avant des mois.
///
/// **Ce qui n'est délibérément PAS ici, et c'est le vrai sujet.** Une revue de
/// conception a comparé les deux écrans ligne à ligne : le regroupement par jour
/// est l'un des deux seuls morceaux qui méritent d'être communs. La **ligne** et
/// la **carte**, elles, restent chez elles. Elles se ressemblent en photo et
/// divergent honnêtement dès qu'on les lit : une capture se replie sur quatre
/// lignes et peut s'afficher en chasse fixe, une dictée se replie sur trois et
/// n'a pas de mise en page à choisir ; l'une propose de relire dans l'autre mode,
/// l'autre de réappliquer un dictionnaire ; leurs métadonnées n'ont ni le même
/// nombre ni la même nature. Les réunir demanderait de paramétrer `branCard`
/// — police, nombre de lignes, jeu d'actions, jeu de métadonnées, libellés
/// d'aide, symbole de purge… — c'est-à-dire de produire exactement le composant
/// à huit paramètres que `Design.swift` existe pour empêcher : un point d'entrée
/// unique qui, à force d'accepter tous les cas, ne décrit plus aucune intention.
/// Ce qui se partage ici est une **décision de calendrier**, pas une apparence.
///
/// L'en-tête de section n'est pas partagé non plus, et pour une raison plus
/// terre à terre : ce sont trois modificateurs sur un `Text`, dans un
/// `LazyVStack` dont chaque écran règle l'espacement. Une fonction pour ça
/// coûterait plus à lire qu'elle n'économise.

/// Un jour de la bibliothèque, et ce qu'il contient.
///
/// `id` est **minuit dans le calendrier de l'utilisateur**, pas la date de la
/// première entrée du jour : deux jours distincts ont ainsi deux identités
/// distinctes et stables, et `ForEach` ne recompose pas une section entière
/// parce que l'entrée la plus récente du jour a changé.
struct DayGroup<Item: Identifiable>: Identifiable {
    /// Minuit, dans le calendrier de l'utilisateur.
    let id: Date
    /// « Aujourd'hui », « Hier », ou la date écrite en toutes lettres.
    let title: String
    /// Les entrées de ce jour, dans l'ordre où l'appelant les a fournies.
    let items: [Item]
}

/// Le regroupement lui-même. Une énumération sans cas : un espace de noms, pas
/// une valeur qu'on instancie.
enum DayGrouping {

    /// Regroupe par jour local, du plus récent au plus ancien, en gardant
    /// l'ordre d'origine à l'intérieur d'un jour.
    ///
    /// **Le calendrier de l'utilisateur, jamais UTC.** La journée de quelqu'un
    /// se termine à minuit chez lui ; découper en UTC ferait basculer une dictée
    /// de 23 h dans le « lendemain » pour un lecteur parisien, et l'entrée qu'il
    /// vient de faire ne serait plus sous « Aujourd'hui ». C'est le même
    /// raisonnement, et le même piège, que `ClipboardRetention.dayKey(for:)`,
    /// dont le commentaire insiste là-dessus parce qu'il gouverne ce qui est
    /// **effacé** ; ici il ne gouverne que ce qui est **montré**, mais un
    /// historique dont les deux ne s'accordent pas est pire que les deux.
    ///
    /// **Pourquoi aucun tri à l'intérieur d'un jour.** Les deux panes triaient
    /// chaque paquet par `createdAt` décroissant. Ce tri était redondant :
    /// `Dictionary(grouping:by:)` conserve l'ordre de la séquence source dans
    /// chaque paquet, `ContentStore` maintient `entries` du plus récent au plus
    /// ancien — au rechargement par un `sorted`, à l'écriture par
    /// `insertionIndex(for:)`, dont la doc explique pourquoi insérer en tête
    /// serait faux — et le filtrage de la recherche n'est qu'un `filter`, qui
    /// préserve l'ordre. Retrier revenait donc à retrier du déjà trié, à ceci
    /// près qu'à égalité de date le tri pouvait **échanger** deux entrées
    /// arrivées dans la même seconde, alors que l'ordre source, lui, dit
    /// laquelle est arrivée en dernier — et `insertionIndex` s'est donné du mal
    /// pour le dire. Respecter l'ordre reçu est à la fois moins de code et plus
    /// juste. Le corollaire est le contrat de cette fonction, et il est dans son
    /// titre : un appelant dont la source n'est pas déjà ordonnée doit la
    /// trier **avant**, ce qui est de toute façon la seule façon d'obtenir un
    /// écran ordonné entre les jours autant qu'à l'intérieur.
    ///
    /// - Parameters:
    ///   - date: où lire l'instant d'un élément. Une fonction et non un
    ///     `KeyPath` contraint : les trois écrans ne nomment pas ce champ pareil
    ///     (`createdAt`, `copiedAt`, `metadata.startedAt`), et un protocole
    ///     « a une date » imposé à trois types de trois modules différents
    ///     coûterait trois conformances pour économiser un `\.` par appel.
    ///   - calendar: le calendrier à employer. Injecté, avec le calendrier
    ///     courant par défaut, pour la même raison que `now` — voir
    ///     `title(for:now:)`.
    ///   - now: l'instant de référence des titres.
    static func groups<Item: Identifiable>(
        _ items: [Item],
        by date: (Item) -> Date,
        calendar: Calendar = .current,
        now: Date = .now
    ) -> [DayGroup<Item>] {
        let buckets = Dictionary(grouping: items) { calendar.startOfDay(for: date($0)) }
        // Les clés d'un dictionnaire n'ont pas d'ordre : le tri décroissant
        // n'est pas une préférence d'affichage qu'on pourrait oublier, c'est ce
        // qui empêche les sections de changer de place d'un rendu à l'autre.
        return buckets.keys.sorted(by: >).map { day in
            DayGroup(
                id: day,
                title: title(for: day, now: now, calendar: calendar),
                items: buckets[day] ?? []
            )
        }
    }

    /// « Aujourd'hui », « Hier », ou la date écrite.
    ///
    /// **`now` est un paramètre, et c'est tout l'intérêt.** Les quatre copies de
    /// cette fonction appelaient `Calendar.isDateInToday(_:)`, qui lit l'horloge
    /// de la machine : aucun test ne pouvait vérifier qu'« Aujourd'hui » tombe
    /// sur le bon jour, ni qu'« Hier » survit à un changement d'heure. C'est
    /// précisément le genre de fonction qui se met à mentir à minuit — ou le
    /// dernier dimanche d'octobre — sans que rien ne le signale. Avec un
    /// instant de référence explicite, les deux cas se posent en trois lignes ;
    /// le défaut `.now` fait que les appelants n'en savent rien.
    ///
    /// **Un écart en jours, pas deux comparaisons.** `isDateInToday` /
    /// `isDateInYesterday` auraient marché aussi, mais seulement contre
    /// l'horloge réelle : rejouées contre un `now` injecté elles répondraient à
    /// une autre question que celle qu'on pose. `dateComponents([.day],…)` entre
    /// deux minuits donne la réponse du calendrier — donc 1 jour entre deux
    /// minuits séparés de 23 ou 25 heures, ce qu'une soustraction de secondes ne
    /// dirait pas.
    static func title(for day: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        let elapsed = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: day),
            to: calendar.startOfDay(for: now)
        ).day

        switch elapsed {
        case 0: return "Aujourd'hui"
        case 1: return "Hier"
        default:
            // Le jour de la semaine d'abord : dans une bibliothèque qu'on
            // parcourt sur quelques semaines, « lundi » situe mieux que « 4 ».
            // Aucun format explicite, aucune langue codée en dur — c'est la
            // locale du système qui ordonne les composants.
            return day.formatted(.dateTime.weekday(.wide).day().month(.wide))
        }
    }
}
