import Foundation
import Testing

@testable import BranCore

/// **Une copie perdue ne se remarque qu'au moment où on en a besoin.**
///
/// C'est la pièce la plus fragile de l'historique du presse-papiers, et la seule
/// dont les défauts sont invisibles : capturer un presse-papiers à moitié écrit
/// range une entrée vide sans rien dire, jeter une copie lente ne laisse aucune
/// trace, et archiver un mot de passe ne se découvre que le jour où quelqu'un
/// relit l'historique. Les trois se testent ici sans presse-papiers, sans
/// autorisation, et sans attendre une milliseconde : le temps est un paramètre.
@Suite("Le presse-papiers")
struct ClipboardMachineTests {

    // MARK: - Outillage

    private let t0 = ContinuousClock.now
    private func at(_ milliseconds: Int) -> ContinuousClock.Instant {
        t0 + .milliseconds(milliseconds)
    }

    private let text = "public.utf8-plain-text"
    private let plainText = "public.plain-text"
    private let rtf = "public.rtf"
    private let html = "public.html"
    private let png = "public.png"
    private let tiff = "public.tiff"
    private let pdf = "com.adobe.pdf"
    private let fileURL = "public.file-url"
    private let concealed = "org.nspasteboard.ConcealedType"
    private let rfhToken = "org.chromium.internal.source-rfh-token"
    private let sourceURL = "org.chromium.source-url"
    private let promise = "com.apple.pasteboard.promised-file-content-type"
    private let promiseMetadata = "com.apple.NSFilePromiseItemMetaData"

    private func sample(_ changeCount: Int, _ items: [[String]]) -> ClipboardSample {
        ClipboardSample(changeCount: changeCount, items: items)
    }

    private func delay(_ effects: [ClipboardMachine.Effect]) -> Duration? {
        for effect in effects { if case .sample(let after) = effect { return after } }
        return nil
    }

    private func plan(_ effects: [ClipboardMachine.Effect]) -> ClipboardCapturePlan? {
        for effect in effects { if case .capture(let plan) = effect { return plan } }
        return nil
    }

    private func skip(_ effects: [ClipboardMachine.Effect]) -> ClipboardSkip? {
        for effect in effects { if case .ignore(let reason) = effect { return reason } }
        return nil
    }

    // MARK: - La stabilisation

    @Test("Stable dès +40 ms, et capturé quand même pas avant +300")
    func plancherDeStabilisation() {
        var machine = ClipboardMachine()

        #expect(delay(machine.handle(.hinted(changeCount: 10, at: at(0)))) == .milliseconds(40))
        #expect(machine.phase == .settling)

        // **Un seul échantillon ne prouve rien.** Le presse-papiers est déjà
        // lisible à +40 ms, mais c'est exactement à quoi ressemble un écrivain
        // qui vient de poser sa première représentation sur cinq.
        let first = machine.handle(.sampled(sample(11, [[text]]), at: at(40)))
        #expect(plan(first) == nil)
        #expect(delay(first) == .milliseconds(80))

        // **Et deux mesures d'accord n'en prouvent pas beaucoup plus avant le
        // plancher.** Les écritures asynchrones mesurées s'étalent de 80 à
        // 200 ms : une application qui pose son PNG à +30 et son HTML à +200 est
        // exactement aussi « stable » que celle-ci à +40 et +120, et serait
        // rangée en image pour toujours.
        let second = machine.handle(.sampled(sample(11, [[text]]), at: at(120)))
        #expect(plan(second) == nil, "le plancher tient même contre deux relevés concordants")
        #expect(delay(second) == .milliseconds(180))
        #expect(machine.phase == .settling)

        let third = machine.handle(.sampled(sample(11, [[text]]), at: at(300)))
        #expect(plan(third)?.kind == .text)
        #expect(plan(third)?.changeCount == 11)
        #expect(plan(third)?.primaryType == text)
        #expect(machine.phase == .capturing)

        machine.handle(.captureFinished)
        #expect(machine.phase == .idle)
    }

    @Test("Écriture en plusieurs temps : des types apparaissent à +120 puis à +300")
    func ecritureEnPlusieursTemps() {
        var machine = ClipboardMachine()
        machine.handle(.hinted(changeCount: 10, at: at(0)))

        // Le compte a bougé au `clearContents()`, mais rien n'est encore écrit.
        #expect(delay(machine.handle(.sampled(sample(11, [[]]), at: at(40)))) == .milliseconds(80))

        // Première représentation : un PDF, qui n'est le déclencheur d'aucune
        // sorte à lui seul.
        let atOneTwenty = machine.handle(.sampled(sample(11, [[pdf]]), at: at(120)))
        #expect(plan(atOneTwenty) == nil, "un type qui vient d'apparaître n'est pas un type stabilisé")
        #expect(delay(atOneTwenty) == .milliseconds(180))

        // Le reste arrive : le TIFF et le nom en texte. Le jeu a encore bougé,
        // donc on n'écrit toujours rien.
        let atThreeHundred = machine.handle(.sampled(sample(11, [[pdf, tiff, text]]), at: at(300)))
        #expect(plan(atThreeHundred) == nil)
        #expect(delay(atThreeHundred) == .milliseconds(200))

        // Deux mesures identiques, et le plancher est loin derrière : c'est fini.
        let atFiveHundred = machine.handle(.sampled(sample(11, [[pdf, tiff, text]]), at: at(500)))
        #expect(plan(atFiveHundred)?.kind == .image)
        #expect(plan(atFiveHundred)?.primaryType == tiff)
        #expect(machine.phase == .capturing)
    }

    @Test("L'ordre de déclaration des types n'est pas un changement")
    func ordreDesTypesIndifferent() {
        var machine = ClipboardMachine()
        machine.handle(.hinted(changeCount: 10, at: at(0)))
        machine.handle(.sampled(sample(11, [[rtf, text, html]]), at: at(40)))

        // Même jeu, déclaré dans un autre ordre à chaque relevé. Le prendre pour
        // un changement ferait échantillonner jusqu'au budget à chaque copie de
        // page web.
        machine.handle(.sampled(sample(11, [[html, rtf, text]]), at: at(120)))
        let third = machine.handle(.sampled(sample(11, [[text, html, rtf]]), at: at(300)))
        #expect(plan(third)?.kind == .richText)
    }

    // MARK: - Bougé mais vide : le cas qui était faux

    @Test("Compteur bougé, types vides au budget : on attend l'écrivain lent au lieu d'abandonner")
    func ecrivainLent() {
        var machine = ClipboardMachine()
        machine.handle(.hinted(changeCount: 10, at: at(0)))

        for instant in [40, 120, 300] {
            #expect(plan(machine.handle(.sampled(sample(11, [[]]), at: at(instant)))) == nil)
        }

        // 500 ms, presse-papiers toujours vide. **On n'abandonne pas** : Excel
        // qui fabrique PDF + TIFF + PNG + HTML + texte, une grande plage
        // Numbers, un calque Photoshop — tous sont encore en train de remplir.
        let atBudget = machine.handle(.sampled(sample(11, [[]]), at: at(500)))
        #expect(skip(atBudget) == nil, "abandonner ici jetterait une copie bien réelle")
        #expect(delay(atBudget) == .milliseconds(250))
        #expect(machine.phase == .awaitingSlowWriter)

        #expect(delay(machine.handle(.sampled(sample(11, [[]]), at: at(750)))) == .milliseconds(250))

        // Le contenu finit par arriver, presque une seconde après la frappe.
        let appeared = machine.handle(.sampled(sample(11, [[pdf, tiff, text]]), at: at(1_000)))
        #expect(plan(appeared) == nil)
        #expect(delay(appeared) == .milliseconds(250))

        let settled = machine.handle(.sampled(sample(11, [[pdf, tiff, text]]), at: at(1_250)))
        #expect(plan(settled)?.kind == .image)
        #expect(machine.phase == .capturing)
    }

    @Test("Un presse-papiers qui reste vide deux secondes finit quand même par être lâché")
    func jamaisStabilise() {
        var machine = ClipboardMachine()
        machine.handle(.hinted(changeCount: 10, at: at(0)))

        var last: [ClipboardMachine.Effect] = []
        for instant in [40, 120, 300, 500, 750, 1_000, 1_250, 1_500, 1_750, 2_000] {
            last = machine.handle(.sampled(sample(11, [[]]), at: at(instant)))
        }

        #expect(skip(last) == .neverSettled)
        #expect(delay(last) == nil, "le budget total est de deux secondes, pas d'une boucle sans fin")
        #expect(machine.phase == .idle)
        #expect(ClipboardSkip.neverSettled.isNoteworthy, "celui-là dit quelque chose sur bran")
    }

    @Test("La cadence lente ne dépasse pas non plus son budget")
    func cadenceLenteBornee() {
        var machine = ClipboardMachine()
        machine.handle(.hinted(changeCount: 10, at: at(0)))
        for instant in [40, 120, 300, 500] {
            machine.handle(.sampled(sample(11, [[]]), at: at(instant)))
        }
        #expect(machine.phase == .awaitingSlowWriter)

        // Un échantillon très en retard : le rendez-vous suivant est raboté pour
        // tomber pile sur les deux secondes, pas 250 ms après.
        let late = machine.handle(.sampled(sample(11, [[]]), at: at(1_900)))
        #expect(delay(late) == .milliseconds(100))
    }

    // MARK: - Le compteur n'a pas bougé

    @Test("⌘C dans un champ vide : rien n'a été copié, et ce n'est pas un échec")
    func compteurImmobile() {
        var machine = ClipboardMachine()

        var total = Duration.zero
        var effects = machine.handle(.hinted(changeCount: 10, at: at(0)))
        total += delay(effects) ?? .zero

        // Le presse-papiers porte toujours la copie précédente, parfaitement
        // lisible. Ce n'est pas ce qu'on cherche : la déduplication se fait sur
        // le compteur, et lui n'a pas bougé.
        for instant in [40, 120, 300] {
            effects = machine.handle(.sampled(sample(10, [[text]]), at: at(instant)))
            #expect(plan(effects) == nil)
            total += delay(effects) ?? .zero
        }

        effects = machine.handle(.sampled(sample(10, [[text]]), at: at(500)))
        #expect(skip(effects) == .noCopy)
        #expect(ClipboardSkip.noCopy.isNoteworthy == false, "un champ vide ne mérite pas une alerte")
        #expect(machine.phase == .idle)

        // Les rendez-vous tombent à +40, +120, +300 et +500 : le budget est tenu
        // exactement, pas dépassé par accumulation.
        #expect(total == .milliseconds(500))
    }

    @Test("Le budget est une échéance dure : à 500 ms on tranche, même sans confirmation")
    func budgetDur() {
        var machine = ClipboardMachine()
        machine.handle(.hinted(changeCount: 10, at: at(0)))

        // Un seul échantillon, arrivé en retard (le réveil d'une tâche endormie
        // n'est jamais à la milliseconde près). On n'a aucune preuve de
        // stabilité — mais capturer un presse-papiers non confirmé vaut mieux
        // que perdre la copie.
        let late = machine.handle(.sampled(sample(11, [[text]]), at: at(500)))
        #expect(plan(late)?.kind == .text)
        #expect(delay(late) == nil, "aucun rendez-vous au-delà du budget")
    }

    @Test("Le compteur bouge deux fois pendant la fenêtre : c'est la dernière copie qui compte")
    func compteurBougeDeuxFois() {
        var machine = ClipboardMachine()
        machine.handle(.hinted(changeCount: 10, at: at(0)))

        #expect(plan(machine.handle(.sampled(sample(11, [[text]]), at: at(40)))) == nil)

        // Une seconde copie, 80 ms après la première. Le jeu de types est le
        // même : sans la comparaison du compteur, on aurait cru à une stabilité.
        let moved = machine.handle(.sampled(sample(12, [[text]]), at: at(120)))
        #expect(plan(moved) == nil)
        #expect(delay(moved) == .milliseconds(180))

        #expect(plan(machine.handle(.sampled(sample(12, [[text]]), at: at(300))))?.changeCount == 12)
    }

    // MARK: - Les écritures de bran

    @Test("Un compte causé par bran est ignoré, sans marqueur ajouté au contenu")
    func ecritureDeBran() {
        var machine = ClipboardMachine()

        // bran vient de recoller une entrée : `clearContents()` lui a rendu 11.
        machine.handle(.selfWrote(changeCount: 11))
        machine.handle(.hinted(changeCount: 10, at: at(0)))

        let effects = machine.handle(.sampled(sample(11, [[text]]), at: at(40)))
        #expect(skip(effects) == .ownWrite)
        #expect(delay(effects) == nil, "inutile de continuer à sonder sa propre écriture")
        #expect(machine.phase == .idle)
    }

    @Test("Une vraie copie qui suit une écriture de bran est bien archivée")
    func vraieCopieApresEcritureDeBran() {
        var machine = ClipboardMachine()
        machine.handle(.selfWrote(changeCount: 11))
        machine.handle(.hinted(changeCount: 11, at: at(0)))
        machine.handle(.sampled(sample(12, [[text]]), at: at(40)))
        machine.handle(.sampled(sample(12, [[text]]), at: at(120)))
        #expect(plan(machine.handle(.sampled(sample(12, [[text]]), at: at(300))))?.changeCount == 12)
    }

    @Test("La mémoire des écritures de bran est bornée")
    func memoireDesEcrituresBornee() {
        var machine = ClipboardMachine()
        for count in 1...(ClipboardMachine.ownWriteMemory + 1) {
            machine.handle(.selfWrote(changeCount: count))
        }

        // Le plus ancien est oublié : bran n'écrit que quand l'utilisateur
        // recolle, une poignée de fois, jamais en rafale — et une liste qui
        // grandit sans fin est une fuite.
        machine.handle(.hinted(changeCount: 0, at: at(0)))
        machine.handle(.sampled(sample(1, [[text]]), at: at(40)))
        machine.handle(.sampled(sample(1, [[text]]), at: at(120)))
        #expect(plan(machine.handle(.sampled(sample(1, [[text]]), at: at(300)))) != nil)
    }

    @Test("La même copie vue deux fois n'est rangée qu'une fois")
    func dejaCapture() {
        var machine = ClipboardMachine()
        machine.handle(.hinted(changeCount: 10, at: at(0)))
        for instant in [40, 120] { machine.handle(.sampled(sample(11, [[text]]), at: at(instant))) }
        #expect(plan(machine.handle(.sampled(sample(11, [[text]]), at: at(300)))) != nil)
        machine.handle(.captureFinished)

        // Le raccourci et le sondeur ont vu la même copie.
        machine.handle(.hinted(changeCount: 10, at: at(400)))
        #expect(skip(machine.handle(.sampled(sample(11, [[text]]), at: at(440)))) == .alreadyCaptured)
    }

    // MARK: - Confidentialité

    @Test(
        "Un marqueur sur un seul élément rejette toute l'entrée",
        arguments: [
            "org.nspasteboard.ConcealedType",
            "org.nspasteboard.TransientType",
            "org.nspasteboard.AutoGeneratedType",
        ]
    )
    func marqueurDeConfidentialite(marker: String) {
        var machine = ClipboardMachine()
        machine.handle(.hinted(changeCount: 10, at: at(0)))

        // Deux éléments, un seul marqué : 1Password écrit le mot de passe et son
        // libellé. Ne rejeter que l'élément marqué archiverait le mot de passe.
        let effects = machine.handle(
            .sampled(sample(11, [[text], [text, marker]]), at: at(40))
        )
        #expect(skip(effects) == .markedPrivate)
        #expect(delay(effects) == nil, "on ne sonde pas un mot de passe pendant 500 ms")
        #expect(machine.phase == .idle)
    }

    @Test("Le rejet est un paramètre : désactivé, l'entrée est gardée, le marqueur non")
    func rejetDesactivable() {
        var machine = ClipboardMachine(policy: ClipboardTypePolicy(honoursPrivacyMarkers: false))
        machine.handle(.hinted(changeCount: 10, at: at(0)))

        let first = machine.handle(.sampled(sample(11, [[text, concealed]]), at: at(40)))
        #expect(skip(first) == nil)

        machine.handle(.sampled(sample(11, [[text, concealed]]), at: at(120)))
        let captured = plan(machine.handle(.sampled(sample(11, [[text, concealed]]), at: at(300))))
        #expect(captured?.kind == .text)
        #expect(captured?.types.contains(concealed) == false, "le marqueur n'est pas un contenu")
    }

    // MARK: - La matrice des types

    @Test("Fichier bat image, image bat texte enrichi, texte enrichi bat texte")
    func ordreDePriorite() {
        let policy = ClipboardTypePolicy()

        // Copier un fichier depuis le Finder pose aussi son nom en texte, et le
        // Finder pose une vignette : les quatre formes coexistent.
        #expect(policy.plan(for: sample(1, [[fileURL, png, rtf, text]]))?.kind == .file)
        #expect(policy.plan(for: sample(1, [[png, text]]))?.kind == .image)
        #expect(policy.plan(for: sample(1, [[rtf, text]]))?.kind == .richText)
        #expect(policy.plan(for: sample(1, [[text]]))?.kind == .text)

        // Et la priorité vaut aussi entre éléments distincts, pas seulement à
        // l'intérieur d'un élément.
        #expect(policy.plan(for: sample(1, [[text], [fileURL]]))?.kind == .file)
    }

    @Test("Un texte enrichi garde sa forme en texte brut, et rien d'autre")
    func compagnonDuTexteEnrichi() {
        let policy = ClipboardTypePolicy()

        let web = policy.plan(for: sample(1, [[html, rtf, text, rfhToken]]))
        #expect(web?.kind == .richText)
        #expect(web?.primaryType == rtf, "le RTF se recolle de la même façon partout, pas le HTML")
        #expect(web?.companionTypes == [text])
        #expect(web?.types == [rtf, text])

        // Sans texte brut sur le presse-papiers, il n'y a rien à garder en plus.
        #expect(policy.plan(for: sample(1, [[html]]))?.companionTypes == [])
        #expect(policy.plan(for: sample(1, [[html]]))?.primaryType == html)

        // Une image ne garde pas de compagnon : ses dimensions viennent de ses
        // octets, pas d'un autre type.
        let image = policy.plan(for: sample(1, [[png, text]]))
        #expect(image?.companionTypes == [])
        #expect(image?.measuresDimensions == true)
        #expect(policy.plan(for: sample(1, [[text]]))?.measuresDimensions == false)
    }

    @Test("La forme éditable l'emporte sur son propre rendu, au sein d'un même élément")
    func formeEditableContreSonRendu() {
        let policy = ClipboardTypePolicy()

        // **Le cas Excel.** Une plage de cellules arrive en PDF + TIFF + HTML +
        // texte. Le bitmap est un *rendu* du tableau, pas le tableau : collée
        // dans Notes, la plage doit redonner un tableau, pas une photo de
        // tableau. Le rendu est gardé en compagnon — un futur « coller comme
        // image » ne recapturera rien.
        let excel = policy.plan(for: sample(1, [[pdf, tiff, html, text]]))
        #expect(excel?.kind == .richText)
        #expect(excel?.primaryType == html)
        #expect(excel?.companionTypes == [text, tiff])

        // Sans rendu matriciel à conserver, il n'y a qu'un compagnon.
        #expect(policy.plan(for: sample(1, [[pdf, html, text]]))?.kind == .richText)
        #expect(policy.plan(for: sample(1, [[pdf, html, text]]))?.companionTypes == [text])

        // **L'autre côté de la règle.** Une diapo Keynote, une capture d'Aperçu,
        // une image de Figma : PDF et TIFF sans une once de texte enrichi. Rien
        // à préférer au bitmap, ce sont des images.
        let keynote = policy.plan(for: sample(1, [[pdf, tiff]]))
        #expect(keynote?.kind == .image)
        #expect(keynote?.primaryType == tiff)

        // Le texte brut n'est pas une source éditable : le nom de fichier posé à
        // côté d'une capture d'écran ne la déclasse pas.
        #expect(policy.plan(for: sample(1, [[png, text]]))?.kind == .image)

        // **La règle se juge par élément.** Une image dans un élément et du HTML
        // dans un autre sont deux objets, pas deux vues du même.
        #expect(policy.plan(for: sample(1, [[png], [html, text]]))?.kind == .image)
    }

    @Test("Plusieurs fichiers font plusieurs éléments, et le plan le dit")
    func plusieursFichiers() {
        let policy = ClipboardTypePolicy()
        let three = policy.plan(for: sample(1, [[fileURL], [fileURL], [fileURL, text]]))
        #expect(three?.kind == .file)
        #expect(three?.itemCount == 3)
        #expect(policy.plan(for: sample(1, [[text]]))?.itemCount == 1)
    }

    @Test("Les identifiants privés ou éphémères sont jetés")
    func typesPrivesJetes() {
        let policy = ClipboardTypePolicy()

        // 5 515 lignes de `source-rfh-token` dans un historique réel de 250
        // entrées, et pas une qui ait encore un sens.
        #expect(ClipboardTypePolicy.isDiscarded(rfhToken))
        #expect(ClipboardTypePolicy.isDiscarded(sourceURL))
        #expect(ClipboardTypePolicy.isDiscarded("dyn.ah62d4rv4gu8yc6durvwwaznwmuuha2pxsvw0e55bsmwca7d3s"))
        #expect(ClipboardTypePolicy.isDiscarded("org.nspasteboard.source"))
        #expect(ClipboardTypePolicy.isDiscarded(concealed))
        #expect(ClipboardTypePolicy.isDiscarded(text) == false)
        #expect(ClipboardTypePolicy.isDiscarded(fileURL) == false)

        let chrome = policy.plan(for: sample(1, [[text, rfhToken, sourceURL, "org.chromium.web-custom-data"]]))
        #expect(chrome?.kind == .text)
        #expect(chrome?.types == [text])

        // Un presse-papiers qui n'a *que* des types privés n'a rien à ranger.
        #expect(policy.plan(for: sample(1, [[rfhToken, sourceURL]])) == nil)
    }

    @Test("Un presse-papiers illisible finit par être lâché, en le disant")
    func rienDExploitable() {
        var machine = ClipboardMachine()
        machine.handle(.hinted(changeCount: 10, at: at(0)))

        var last: [ClipboardMachine.Effect] = []
        for instant in [40, 120, 300, 500, 750, 1_000, 1_250, 1_500, 1_750, 2_000] {
            last = machine.handle(.sampled(sample(11, [["com.acme.private-blob"]]), at: at(instant)))
        }
        #expect(skip(last) == .nothingUsable)
        #expect(ClipboardSkip.nothingUsable.isNoteworthy)
    }

    // MARK: - Les promesses de fichier

    @Test("Une promesse de fichier est reconnue, et refusée en la nommant")
    func promesseRefusee() {
        #expect(ClipboardTypePolicy.isFilePromise(promise))
        #expect(ClipboardTypePolicy.isFilePromise(promiseMetadata))
        // Reconnue, donc pas silencieusement mise au rebut : c'est ce qui permet
        // de la refuser avec un motif plutôt qu'avec un « rien d'exploitable ».
        #expect(ClipboardTypePolicy.isDiscarded(promise) == false)

        let policy = ClipboardTypePolicy()
        #expect(policy.plan(for: sample(1, [[promise, promiseMetadata]])) == nil)

        var machine = ClipboardMachine()
        machine.handle(.hinted(changeCount: 10, at: at(0)))
        for instant in [40, 120, 300] {
            machine.handle(.sampled(sample(11, [[promise, promiseMetadata]]), at: at(instant)))
        }

        // Une promesse rend un UTI, pas un contenu, et l'honorer voudrait dire un
        // aller-retour réseau. Ce n'est pas un écrivain lent : on tranche au
        // budget plutôt que d'attendre deux secondes pour rien.
        let atBudget = machine.handle(.sampled(sample(11, [[promise, promiseMetadata]]), at: at(500)))
        #expect(skip(atBudget) == .filePromise)
        #expect(machine.phase == .idle)
    }

    @Test("Une promesse posée à côté d'un vrai contenu ne bloque pas la capture")
    func promesseAvecContenu() {
        let policy = ClipboardTypePolicy()
        let mail = policy.plan(for: sample(1, [[promise, text]]))
        #expect(mail?.kind == .text)
        #expect(mail?.types == [text], "la promesse n'est ni honorée ni conservée")
    }

    // MARK: - Cas dégénérés et hors état

    @Test("Une liste de types vide n'est pas une sorte")
    func listeDeTypesVide() {
        let policy = ClipboardTypePolicy()

        #expect(sample(1, []).isEmpty)
        #expect(sample(1, [[]]).isEmpty)
        #expect(sample(1, [[], []]).isEmpty)
        #expect(sample(1, [[text]]).isEmpty == false)

        #expect(policy.plan(for: sample(1, [])) == nil)
        #expect(policy.plan(for: sample(1, [[]])) == nil)
    }

    @Test("Un second indice relance la cadence sans perdre la référence d'origine")
    func secondIndicePendantLaFenetre() {
        var machine = ClipboardMachine()
        machine.handle(.hinted(changeCount: 10, at: at(0)))
        machine.handle(.sampled(sample(11, [[text]]), at: at(40)))

        // Un second ⌘C à 100 ms. La référence annoncée est délibérément absurde :
        // si la machine l'adoptait, elle conclurait « rien n'a été copié ».
        #expect(delay(machine.handle(.hinted(changeCount: 9_999, at: at(100)))) == .milliseconds(40))

        // La preuve de stabilité accumulée avant le nouveau geste ne vaut plus
        // rien : ce relevé est identique au premier, et ne capture pourtant pas.
        let first = machine.handle(.sampled(sample(11, [[text]]), at: at(140)))
        #expect(plan(first) == nil)
        #expect(delay(first) == .milliseconds(80))

        // Le plancher se compte depuis le nouvel indice, pas depuis le premier :
        // à 220 ms d'horloge il ne s'est écoulé que 120 ms de fenêtre.
        #expect(plan(machine.handle(.sampled(sample(11, [[text]]), at: at(220)))) == nil)
        #expect(plan(machine.handle(.sampled(sample(11, [[text]]), at: at(400))))?.changeCount == 11)
    }

    @Test("Un événement qui n'a pas de sens dans l'état courant ne fait rien")
    func evenementsHorsEtat() {
        var machine = ClipboardMachine()

        // Un relevé sans indice : personne n'attend de réponse.
        #expect(machine.handle(.sampled(sample(11, [[text]]), at: at(40))).isEmpty)
        #expect(machine.phase == .idle)

        machine.handle(.hinted(changeCount: 10, at: at(0)))
        #expect(machine.handle(.captureFinished).isEmpty)
        #expect(machine.phase == .settling, "une lecture fantôme ne doit pas fermer la fenêtre en cours")

        machine.handle(.cancelRequested)
        #expect(machine.phase == .idle)
        #expect(machine.handle(.sampled(sample(11, [[text]]), at: at(40))).isEmpty)
    }
}
