import Foundation
import Testing
@testable import BranCore

/// **Le panneau colle ce qui est sélectionné, et rien ne rattrape un mauvais
/// collage** : le texte est déjà parti dans l'autre application.
///
/// D'où la forme de cette suite. Elle ne vérifie pas que le filtre « marche »,
/// elle vérifie les instants où la liste change sous les doigts — une frappe
/// dans le filtre, une suppression, une liste plus courte que le raccourci
/// qu'on vient d'appuyer — parce que ce sont les seuls où la ligne surlignée et
/// la ligne collée peuvent cesser d'être la même.
///
/// **`@MainActor` sur la suite entière** : `ClipboardFilter.matches` renvoie
/// vers `ClipboardStore.matches`, qui est isolée parce que sa classe l'est. Voir
/// la documentation de `ClipboardFilter.matches`, qui explique le renvoi et
/// pourquoi l'isolation disparaîtra le jour où le corps de la règle déménagera.
@Suite("Le filtre du panneau de presse-papiers")
@MainActor
struct ClipboardFilterTests {

    // MARK: - Fabriques

    /// Une entrée de texte, datée pour que l'ordre des listes soit lisible dans
    /// les tests.
    private func entry(
        _ preview: String,
        from source: String? = nil,
        minute: Double = 0
    ) -> ClipboardEntry {
        ClipboardEntry(
            copiedAt: Date(timeIntervalSince1970: minute * 60),
            kind: .text,
            preview: preview,
            source: source.map { ClipboardSource(bundleIdentifier: nil, name: $0) }
        )
    }

    private func list(_ previews: [String]) -> [ClipboardEntry] {
        previews.enumerated().map { entry($0.element, minute: Double($0.offset)) }
    }

    // MARK: - Filtrer

    @Test("Une requête vide rend toute la liste")
    func requeteVide() {
        let entries = list(["un", "deux", "trois"])
        #expect(ClipboardFilter.visible(entries, matching: "") == entries)
    }

    @Test("Une requête réduite à des espaces rend toute la liste")
    func requeteBlanche() {
        // Le cas arrive tout seul : on colle un mot dans le champ, on l'efface
        // avec ⌥⌫, il reste l'espace. Traiter ça comme une recherche donnerait
        // un panneau vide sans raison visible.
        let entries = list(["un", "deux"])
        #expect(ClipboardFilter.visible(entries, matching: "   \n ") == entries)
    }

    @Test("Chercher « resume » trouve « résumé »")
    func insensibleAuxDiacritiques() {
        // La règle qui justifie tout le renvoi vers `ClipboardStore.matches` :
        // une recherche qui punit de taper vite n'est pas utilisée deux fois.
        let entries = [entry("Résumé de la réunion")]
        #expect(ClipboardFilter.visible(entries, matching: "resume").count == 1)
    }

    @Test("Chercher en majuscules trouve le nom de l'application source")
    func insensibleALaCasseEtPorteSurLaSource() {
        // Mesuré dans `ClipboardEntry.source` : on se souvient d'où venait un
        // bout de texte bien avant de se souvenir de ce qu'il disait.
        let entries = [entry("xyz", from: "Safari"), entry("abc", from: "Terminal")]
        let found = ClipboardFilter.visible(entries, matching: "SAFARI")
        #expect(found.count == 1)
        #expect(found.first?.preview == "xyz")
    }

    @Test("Une requête sans correspondance rend une liste vide")
    func aucunResultat() {
        // Distinct d'un historique vide, et c'est une branche séparée dans la
        // vue : `ContentUnavailableView.search(text:)` d'un côté, l'invitation
        // à copier quelque chose de l'autre.
        #expect(ClipboardFilter.visible(list(["un", "deux"]), matching: "zzz").isEmpty)
    }

    @Test("Le filtre ne retrie jamais la liste")
    func ordrePreserve() {
        // L'ordre est décidé une fois par `ClipboardStore.ordered(_:)`. Une
        // liste qui se réordonne quand on tape dans le filtre est un symptôme
        // qui ne se relie à rien.
        let entries = list(["alpha", "bravo", "alto", "charlie"])
        let found = ClipboardFilter.visible(entries, matching: "al")
        // Une fermeture et non `\.preview` : la macro `#expect` ne compile pas
        // avec un chemin de clé passé à une fonction `rethrows` comme `map`.
        #expect(found.map { $0.preview } == ["alpha", "alto"])
    }

    // MARK: - Déplacer la sélection

    @Test("Sur une liste vide, aucun déplacement ne sélectionne quoi que ce soit")
    func listeVide() {
        for move in ClipboardFilter.Move.allCases {
            #expect(ClipboardFilter.moved(nil, by: move, in: []) == nil)
        }
    }

    @Test("Avec un seul élément, haut et bas le gardent")
    func unSeulElement() {
        let entries = list(["seule"])
        let only = entries[0].id
        #expect(ClipboardFilter.moved(only, by: .up, in: entries) == only)
        #expect(ClipboardFilter.moved(only, by: .down, in: entries) == only)
    }

    @Test("↓ sur la dernière ligne ne boucle pas")
    func borneBasse() {
        // Décision argumentée dans `moved(_:by:in:)` : une flèche maintenue sur
        // une liste bouclante tourne indéfiniment et supprime le seul retour
        // qu'une liste au clavier sache donner.
        let entries = list(["a", "b", "c"])
        let last = entries[2].id
        #expect(ClipboardFilter.moved(last, by: .down, in: entries) == last)
    }

    @Test("↑ sur la première ligne ne boucle pas")
    func borneHaute() {
        let entries = list(["a", "b", "c"])
        let first = entries[0].id
        #expect(ClipboardFilter.moved(first, by: .up, in: entries) == first)
    }

    @Test("↓ puis ↑ ramène exactement où l'on était")
    func allerRetour() {
        let entries = list(["a", "b", "c"])
        let start = entries[0].id
        let down = ClipboardFilter.moved(start, by: .down, in: entries)
        #expect(down == entries[1].id)
        #expect(ClipboardFilter.moved(down, by: .up, in: entries) == start)
    }

    @Test("Début et fin atteignent les bouts quelle que soit la position")
    func debutEtFin() {
        let entries = list(["a", "b", "c", "d"])
        let middle = entries[2].id
        #expect(ClipboardFilter.moved(middle, by: .first, in: entries) == entries[0].id)
        #expect(ClipboardFilter.moved(middle, by: .last, in: entries) == entries[3].id)
        #expect(ClipboardFilter.moved(nil, by: .first, in: entries) == entries[0].id)
        #expect(ClipboardFilter.moved(nil, by: .last, in: entries) == entries[3].id)
    }

    @Test("Sans sélection, ↓ prend la première ligne et ↑ la dernière")
    func sansSelection() {
        let entries = list(["a", "b", "c"])
        #expect(ClipboardFilter.moved(nil, by: .down, in: entries) == entries[0].id)
        #expect(ClipboardFilter.moved(nil, by: .up, in: entries) == entries[2].id)
    }

    @Test("Une sélection tombée hors de la liste se comporte comme une absence")
    func selectionDisparueDeplacee() {
        // Le cas réel : on avait sélectionné la ligne 40, on tape trois lettres
        // dans le filtre, il reste deux lignes. La flèche ne doit pas rester
        // sans effet.
        let entries = list(["a", "b"])
        let ghost = UUID()
        #expect(ClipboardFilter.moved(ghost, by: .down, in: entries) == entries[0].id)
        #expect(ClipboardFilter.moved(ghost, by: .up, in: entries) == entries[1].id)
    }

    // MARK: - Réconcilier après un changement de liste

    @Test("Une sélection qui survit au filtrage est conservée")
    func selectionConservee() {
        // Filtrer plus finement autour de ce qu'on visait déjà ne doit pas faire
        // perdre ce qu'on visait.
        let entries = list(["alpha", "alto"])
        let target = entries[1].id
        #expect(ClipboardFilter.reconciled(target, in: entries) == target)
    }

    @Test("Une sélection tombée hors de la liste retombe sur la première ligne")
    func selectionRetombee() {
        let entries = list(["a", "b"])
        #expect(ClipboardFilter.reconciled(UUID(), in: entries) == entries[0].id)
    }

    @Test("Une liste non vide a toujours une ligne sélectionnée")
    func toujoursUneSelection() {
        // C'est ce qui rend ↵ toujours signifiant : ouvrir le panneau et coller
        // ne doit pas coûter une flèche vers le bas.
        let entries = list(["a", "b"])
        #expect(ClipboardFilter.reconciled(nil, in: entries) == entries[0].id)
    }

    @Test("Une liste vide n'a aucune sélection")
    func aucuneSelectionSansListe() {
        #expect(ClipboardFilter.reconciled(UUID(), in: []) == nil)
    }

    @Test("Le tout en un appel : liste filtrée et sélection réconciliée")
    func vueDensemble() {
        let entries = list(["alpha", "bravo", "alto"])
        let shown = ClipboardFilter.shown(entries, query: "al", selection: entries[1].id)
        #expect(shown.entries.map { $0.preview } == ["alpha", "alto"])
        // « bravo » a disparu du filtre : la sélection retombe en tête.
        #expect(shown.selection == entries[0].id)
        #expect(shown.selected?.preview == "alpha")
        #expect(shown.isEmpty == false)
    }

    // MARK: - Supprimer sous les doigts

    @Test("Supprimer une ligne donne le clavier à la suivante")
    func suppressionAuMilieu() {
        // ⌘⌫ répété doit descendre la liste : c'est le geste réel.
        let entries = list(["a", "b", "c"])
        let next = ClipboardFilter.selectionAfterRemoving(entries[1].id, from: entries)
        #expect(next == entries[2].id)
    }

    @Test("Supprimer la dernière ligne donne le clavier à la précédente")
    func suppressionEnBas() {
        let entries = list(["a", "b", "c"])
        let next = ClipboardFilter.selectionAfterRemoving(entries[2].id, from: entries)
        #expect(next == entries[1].id)
    }

    @Test("Supprimer la seule ligne ne laisse aucune sélection")
    func suppressionDeLaSeule() {
        let entries = list(["a"])
        #expect(ClipboardFilter.selectionAfterRemoving(entries[0].id, from: entries) == nil)
    }

    @Test("Supprimer une ligne déjà absente retombe sur la première")
    func suppressionDuneAbsente() {
        // Arrive pour de vrai : la purge ou une seconde fenêtre peut retirer une
        // entrée entre l'affichage et la frappe.
        let entries = list(["a", "b"])
        #expect(ClipboardFilter.selectionAfterRemoving(UUID(), from: entries) == entries[0].id)
    }

    // MARK: - Les raccourcis chiffrés

    @Test("⌘N désigne la Nième ligne visible, pas la Nième de l'historique")
    func raccourciSurLaListeVisible() {
        // Le défaut que ce couple de fonctions existe pour rendre impossible :
        // l'historique porte « bravo » en deuxième position, le filtre ne le
        // montre pas, et ⌘2 doit désigner « alto ».
        let entries = list(["alpha", "bravo", "alto", "album"])
        let shown = ClipboardFilter.shown(entries, query: "al", selection: nil)
        #expect(ClipboardFilter.entry(forShortcut: 1, in: shown.entries)?.preview == "alpha")
        #expect(ClipboardFilter.entry(forShortcut: 2, in: shown.entries)?.preview == "alto")
        #expect(ClipboardFilter.entry(forShortcut: 3, in: shown.entries)?.preview == "album")
        #expect(ClipboardFilter.entry(forShortcut: 4, in: shown.entries) == nil)
    }

    @Test("Un chiffre au-delà de la liste ne désigne rien")
    func raccourciHorsListe() {
        // Surtout pas la dernière ligne par défaut : coller la mauvaise chose
        // est la seule erreur qu'un historique ne rattrape pas.
        let entries = list(["a", "b", "c"])
        #expect(ClipboardFilter.entry(forShortcut: 7, in: entries) == nil)
        #expect(ClipboardFilter.entry(forShortcut: 9, in: entries) == nil)
    }

    @Test("Zéro et dix ne sont pas des raccourcis")
    func raccourcisHorsPlage() {
        let entries = list((1...12).map(String.init))
        #expect(ClipboardFilter.entry(forShortcut: 0, in: entries) == nil)
        #expect(ClipboardFilter.entry(forShortcut: 10, in: entries) == nil)
        #expect(ClipboardFilter.entry(forShortcut: -1, in: entries) == nil)
        #expect(ClipboardFilter.entry(forShortcut: 9, in: entries)?.preview == "9")
    }

    @Test("Seules les neuf premières lignes portent un chiffre")
    func numerotationDesLignes() {
        #expect(ClipboardFilter.shortcutNumber(forRowAt: 0) == 1)
        #expect(ClipboardFilter.shortcutNumber(forRowAt: 8) == 9)
        #expect(ClipboardFilter.shortcutNumber(forRowAt: 9) == nil)
        #expect(ClipboardFilter.shortcutNumber(forRowAt: -1) == nil)
    }

    @Test("La pastille et la touche désignent la même entrée")
    func pastilleEtToucheDaccord() {
        // Le seul test qui relie les deux fonctions. Une pastille « ⌘3 » posée
        // sur une ligne que ⌘3 n'atteint pas serait un mensonge visuel, et il
        // ne se verrait qu'au collage.
        let entries = list(["a", "b", "c", "d", "e"])
        for (index, entry) in entries.enumerated() {
            guard let number = ClipboardFilter.shortcutNumber(forRowAt: index) else { continue }
            #expect(ClipboardFilter.entry(forShortcut: number, in: entries)?.id == entry.id)
        }
    }

    // MARK: - Ce que la ligne affiche

    @Test("Un aperçu de 2 Mio est borné avant d'atteindre la vue")
    func apercuEnorme() {
        // `lineLimit(1)` ne protège de rien : SwiftUI met le texte en page pour
        // savoir où couper. La seule troncature qui coûte quelque chose est
        // celle qui a lieu avant la construction de la vue.
        let huge = String(repeating: "a", count: 2 * 1024 * 1024)
        let row = ClipboardFilter.rowText(for: entry(huge))
        #expect(row.text.count == ClipboardEntry.previewLimit)
        #expect(row.isClipped)
    }

    @Test("Un aperçu court passe intact et sans ellipse")
    func apercuCourt() {
        let row = ClipboardFilter.rowText(for: entry("bonjour tout le monde"))
        #expect(row.text == "bonjour tout le monde")
        #expect(row.isClipped == false)
    }

    @Test("Un aperçu multiligne ne rend que sa première ligne, et le dit")
    func apercuMultiligne() {
        let row = ClipboardFilter.rowText(for: entry("première ligne\nseconde ligne"))
        #expect(row.text == "première ligne")
        #expect(row.isClipped)
    }

    @Test("Une entrée dont le texte dépasse l'aperçu stocké se déclare rognée")
    func apercuDejaRogneParLeMagasin() {
        // Le cas normal du magasin : `preview` est le début, `fullTextLength`
        // dit qu'il en manque. C'est `ClipboardEntry.isPreviewTruncated` qui
        // tranche, et la ligne n'a le droit de poser une ellipse que là.
        var stored = entry("le début du texte")
        stored.fullTextLength = 4312
        let row = ClipboardFilter.rowText(for: stored)
        #expect(row.text == "le début du texte")
        #expect(row.isClipped)
    }

    @Test("L'indentation de tête disparaît de la ligne compacte")
    func indentationRetiree() {
        // Sur une ligne de hauteur fixe, huit espaces de tête ne montrent rien
        // et volent la moitié de la largeur. C'est `ClipboardEntry.rowTitle` qui
        // décide, et `rowText` ne fait que le lui appliquer après bornage.
        let row = ClipboardFilter.rowText(for: entry("        let x = 1"))
        #expect(row.text == "let x = 1")
    }
}
