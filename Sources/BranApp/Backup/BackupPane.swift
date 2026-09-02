import AppKit
import BranBackup
import BranCore
import Foundation
import SwiftUI

// **Ce que ce fichier suppose de `BackupController`**, relu dans son fichier
// réel cette fois (il n'était qu'une supposition la première fois que ce
// commentaire a été écrit) :
//
// ```
// @MainActor @Observable
// final class BackupController {
//     private(set) var phase: BackupPhase
//     var configuration: BackupConfiguration
//     private(set) var chainVerdict: ChainVerdict?
//     private(set) var history: [BackupAttempt]
//     private(set) var repositoryStatus: RepositoryStatus?
//     private(set) var repositorySizeBytes: Int64?
//     private(set) var scheduleDecision: ScheduleDecision
//     private(set) var coverage: SourceCoverageReport?
//     private(set) var firstUploads: [FirstUploadTracking]
//
//     func backUpNow()
//     func cancel()
//     func verifyChainNow()
//     func hasStoredSecret(_ secret: BackupSecrets.Secret) -> Bool
// }
// ```
//
// **Le trou qu'aucune propriété ne comble : `coverage` et `firstUploads` ne
// sont ni des paramètres de l'initialiseur de prévisualisation, ni
// réglables depuis ce fichier — `private(set)`, et remplis seulement par
// `refreshCoverage()`, privée, appelée depuis `start()` (jamais lancé par un
// `#Preview`, qui ne doit sonder ni réseau ni disque) et depuis `record()`.**
// Un `#Preview` construit avec `BackupController(...)` a donc structurellement
// `coverage == nil`, quel que soit l'historique qu'on lui passe.
//
// La réponse choisie ici, plutôt que de contourner ce trou avec une donnée
// inventée : `coverage` et `firstUploads`, plus bas dans ce fichier, retombent
// sur le **même évaluateur pur** (`SourceCoverageEvaluator.evaluate`,
// `FirstUploadEvaluator.track`) que `BackupController.refreshCoverage()`
// appelle en interne, à partir de ce que le contrôleur expose déjà en
// lecture (`history`, `configuration`, `repositoryStatus`). Ce n'est jamais un
// deuxième avis : c'est un seul et même calcul, rejoué ici quand le
// contrôleur n'a pas encore eu l'occasion de le faire. Un contrôleur idéal
// exposerait `coverage`/`firstUploads` dans son initialiseur de test, au même
// titre que `chainVerdict` et `history` — voir le rapport de mission.

/// **La section « Sauvegarde ».**
///
/// ```
/// ┌──────────────────────────────────────────────────────────────┐
/// │  Sauvegarde                                        ● verdict │
/// ├──────────────────────────────────────────────────────────────┤
/// │  🛡  Vos fichiers ne sont pas encore protégés.                │  ← LE HÉROS
/// │     Le dépôt contient 3 snapshots, mais aucun ne couvre      │
/// │     votre dossier personnel.                                  │
/// │     Prévue demain à 08:12.        ( Sauvegarder maintenant )  │  ← action
/// ├──────────────────────────────────────────────────────────────┤
/// │  ┌ PREMIÈRE SAUVEGARDE ─────────────────────────────────┐    │
/// │  │ 612 Go montés sur le réseau, reprises comprises…      │    │
/// │  └─────────────────────────────────────────────────────┘    │
/// │  ▸ Chaîne réseau — les six maillons répondent.        (▾)    │
/// │  ┌ PREUVES ────────────────────────( Vérifier maintenant )┐  │
/// │  ▸ Historique — 12 tentatives                        (▾)    │
/// └──────────────────────────────────────────────────────────────┘
/// ```
///
/// ## Le principe structurel de cet écran
///
/// **Un seul verdict, calculé par une seule fonction — ``BackupHeroVerdict/evaluate(scheduleDecision:hasAllSecrets:phase:chainVerdict:coverage:)``
/// — lu par la puce d'en-tête et par le héros, et par eux seulement.** Avant
/// cette réécriture, trois lectures indépendantes du même état pouvaient se
/// contredire à l'écran : le propriétaire a vu simultanément un « ✅ Dernière
/// sauvegarde réussie il y a 21 min » (tiré de `lastSuccess`, qui ne regarde
/// que si *un* snapshot a réussi, pas *lequel* chemin) et un « ⛔ La chaîne
/// est cassée ». `body` calcule ce verdict **une fois**, dans une constante
/// locale, et le distribue aux deux affichages — il ne peut structurellement
/// plus exister deux avis, seulement une couleur qu'on lit à deux endroits.
///
/// ## La table de priorité — le premier qui correspond gagne
///
/// | # | Condition | Ce que ça répond |
/// |---|---|---|
/// | P0 | `scheduleDecision == .disabled` | non, délibérément ou pas encore réglé |
/// | P1 | un secret manque au Trousseau | non, bloqué techniquement |
/// | P2 | `phase.isBusy` | en train de le devenir |
/// | P3 | chaîne cassée (`canBackUp == false` et `firstFailure != nil`) | rien ne part |
/// | P4 | verdict de chaîne absent ou périmé (`connecting`/`unknown`) | pas encore su |
/// | P5 | couverture `.notCovered` ou `.partiallyCovered` | non — l'état réel de ce Mac |
/// | P6 | couverture `.fullyCovered` mais un chemin périmé | ne l'est plus depuis un moment |
/// | P7 | couverture `.fullyCovered`, tout frais | **oui** |
///
/// **P7 est la seule phrase de tout l'écran qui affirme la protection.** Elle
/// exige `coverage.verdict == .fullyCovered` — jamais qu'un `lastSuccess`
/// quelconque existe. C'est très exactement le défaut relevé en vrai sur ce
/// Mac : un snapshot de `~/Music` (51 Mo) faisait afficher « sauvegarde
/// réussie » alors que le dossier personnel configuré (~600 Go) n'avait
/// jamais été envoyé. `coverage` — jamais `lastSuccess` seul — est donc la
/// seule source qui alimente P5, P6 et P7.
struct BackupPane: View {
    let backup: BackupController

    /// Le point de repère pour la vitesse instantanée pendant un run : le
    /// dernier échantillon vu, et depuis quand.
    ///
    /// **Calculé ici, pas dans le contrôleur.** `BackupProgress` ne porte
    /// aucun débit — seulement des compteurs cumulés. Le dériver coûte un
    /// état local et deux lignes ; le remonter dans `BranBackup` en ferait
    /// une source de mesures temporelles, ce que la cible pure interdit.
    @State private var rateSample: (bytes: Int64, at: Date)?
    @State private var currentRate: Double?

    /// Le maillon dont on a demandé le diagnostic détaillé.
    @State private var openLink: ChainPopoverItem?

    /// **Le repli de la chaîne, avec un choix explicite qui l'emporte sur la
    /// règle automatique.** `nil` veut dire « suit la règle » — dépliée
    /// d'elle-même quand `canBackUp == false`, repliée sinon. Un utilisateur
    /// qui la replie quand même pendant une panne n'est pas contredit au tour
    /// suivant : c'est ce que le second niveau (`??`) empêche.
    @State private var chainExpandedOverride: Bool?

    @State private var historyExpanded = false

    var body: some View {
        // **Calculé une fois, ici, et nulle part ailleurs dans ce fichier.**
        // C'est la garantie structurelle du principe ci-dessus : la puce et
        // le héros reçoivent la même valeur, jamais deux appels séparés à
        // `BackupHeroVerdict.evaluate`.
        let verdict = BackupHeroVerdict.evaluate(
            scheduleDecision: backup.scheduleDecision,
            hasAllSecrets: hasAllSecrets,
            launchAgentStatus: backup.launchAgentStatus,
            phase: backup.phase,
            chainVerdict: backup.chainVerdict,
            coverage: coverage,
            lastIntegrityCheck: backup.lastIntegrityCheck
        )

        VStack(spacing: 0) {
            PaneHeader(title: "Sauvegarde", subtitle: "Ce que Kopia a réellement écrit dans le dépôt, jamais ce qu'il croit avoir écrit.") {
                BackupStatusChip(verdict: verdict)
            }

            Divider()

            notices

            // **Le héros et la ligne d'action, hors du `ScrollView`.**
            // Tout le reste de l'écran défile ; ces deux-là restent visibles,
            // mais sans jamais imposer de hauteur minimale — aucun `.frame`
            // fixe ici, seulement du texte qui s'enroule.
            VStack(alignment: .leading, spacing: Space.stack) {
                hero(verdict)
                actionLine
            }
            .padding(.horizontal, Space.gutter)
            .padding(.vertical, Space.stack)

            Divider()

            content
        }
        .onChange(of: progressSnapshot) { _, progress in
            guard let progress else {
                rateSample = nil
                currentRate = nil
                return
            }
            updateRate(with: progress)
        }
    }

    // MARK: - La couverture, une seule fois, avec son repli de prévisualisation

    /// **La réponse à « mes fichiers sont-ils à l'abri », jamais à « un
    /// snapshot a-t-il réussi ».** Voir le commentaire de tête de fichier
    /// pour la raison du repli : le contrôleur ne remplit `coverage` que
    /// depuis `start()`, jamais lancé par un `#Preview`.
    private var coverage: SourceCoverageReport {
        if let coverage = backup.coverage { return coverage }
        return SourceCoverageEvaluator.evaluate(
            sourcePaths: backup.configuration.sourcePaths,
            proofs: backup.history.compactMap(\.proof),
            expectedHost: backup.repositoryStatus?.hostname ?? ProcessInfo.processInfo.hostName,
            expectedUser: backup.repositoryStatus?.username ?? NSUserName(),
            now: .now,
            staleAfter: backup.configuration.stalenessThreshold
        )
    }

    /// Même repli, pour la même raison, et dérivé de la même `coverage`.
    private var firstUploads: [FirstUploadTracking] {
        if backup.coverage != nil { return backup.firstUploads }
        return coverage.coverages.map {
            FirstUploadEvaluator.track(
                path: $0.path,
                coverage: $0.state,
                attempts: backup.history,
                sourcePaths: backup.configuration.sourcePaths
            )
        }
    }

    private var hasAllSecrets: Bool {
        backup.hasStoredSecret(.repositoryPassword) && backup.hasStoredSecret(.s3SecretAccessKey)
    }

    // MARK: - Avertissements

    /// **Seulement ce que le héros ne dit pas déjà.** La configuration
    /// désactivée et le secret manquant sont maintenant P0 et P1 du verdict
    /// unique — les répéter ici en bandeau referait deux avis sur la même
    /// question, exactement ce que cette réécriture existe pour fermer.
    @ViewBuilder
    private var notices: some View {
        VStack(spacing: 0) {
            if let journalNotice {
                NoticeRow(text: journalNotice, symbol: "doc.badge.exclamationmark", tint: Palette.broken)
            }
            if let fullDiskAccessNotice {
                NoticeRow(text: fullDiskAccessNotice, symbol: "lock.slash.fill", tint: Palette.attention)
            }
            if let kopiaVersionNotice {
                NoticeRow(text: kopiaVersionNotice, symbol: "shippingbox.badge.arrow.up", tint: Palette.attention)
            }
            if let interruptedNotice {
                NoticeRow(text: interruptedNotice, symbol: "pause.circle.fill", tint: Palette.machine)
            }
            if let batteryNotice {
                NoticeRow(text: batteryNotice, symbol: "battery.25percent", tint: Palette.machine)
            }
        }
        .branAnimation(Motion.enter, value: backup.phase)
    }

    /// **Le journal illisible, dit franchement.** Un journal absent est
    /// normal ; un journal présent qu'on ne sait pas lire fait disparaître
    /// tout l'historique de l'écran — donc le dernier succès, donc la
    /// couverture, donc l'alerte — sans que rien ne le signale. Rouge, parce
    /// que c'est la mémoire du dispositif qui manque, pas une sauvegarde.
    private var journalNotice: String? {
        if let failure = backup.journalReadFailure {
            return "Le journal des sauvegardes n'a pas pu être lu — l'historique affiché est "
                + "incomplet ou vide, et ce n'est pas parce que rien n'a eu lieu. \(failure)"
        }
        guard backup.unreadableJournalLines > 0 else { return nil }
        let lines = backup.unreadableJournalLines
        return "\(lines) ligne\(lines > 1 ? "s" : "") du journal \(lines > 1 ? "sont illisibles" : "est illisible") "
            + "et \(lines > 1 ? "ont" : "a") été ignorée\(lines > 1 ? "s" : "") — une extinction pendant une "
            + "écriture laisse cette trace. L'historique affiché est donc incomplet d'autant."
    }

    /// **L'Accès complet au disque, et ce que son absence cache.**
    ///
    /// Sans lui, kopia lit une fraction du dossier personnel — `~/Library/Mail`,
    /// `~/Library/Messages`, `~/Library/Safari` et les conteneurs
    /// d'applications lui sont refusés — et la politique du dépôt porte
    /// `Ignore file read errors: true` : les fichiers refusés incrémentent
    /// `ignoredErrorCount` sans changer le code de sortie. Une sauvegarde peut
    /// donc se déclarer réussie en ayant sauté ce qu'on lui avait demandé.
    /// N'apparaît que si une source contient réellement le dossier personnel :
    /// quelqu'un qui ne sauvegarde que `~/Documents` n'a rien à corriger.
    private var fullDiskAccessNotice: String? {
        guard backup.configuration.isEnabled else { return nil }
        guard backup.fullDiskAccess == .denied else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        let coversHome = backup.configuration.sourcePaths.contains { home.hasPrefix($0) || $0 == home }
        guard coversHome else { return nil }
        return """
            bran n'a pas l'Accès complet au disque : les dossiers protégés par macOS \
            (Mail, Messages, Safari, les conteneurs d'applications) seront **sautés en silence** — \
            kopia les compte comme « ignorés », pas comme des erreurs, et la sauvegarde se déclarera \
            réussie sans eux. Accordez-le dans Réglages système › Confidentialité et sécurité › \
            Accès complet au disque, puis relancez bran.
            """
    }

    /// **La version de kopia, mesurée au démarrage.** Distingue « pas la
    /// version éprouvée » (on ne sait pas) de « version connue comme
    /// incompatible » (on sait) et de « version illisible » (le binaire
    /// manque). Aucune ne bloque quoi que ce soit : elles disent seulement ce
    /// qui n'a pas été vérifié.
    private var kopiaVersionNotice: String? {
        switch backup.kopiaVersion {
        case .none, .some(.matchesExpected):
            return nil
        case .some(.unvalidated(let found, let expected)):
            return "Le binaire kopia installé annonce « \(found) », alors que bran a été éprouvé "
                + "contre \(expected). Rien ne dit qu'il est cassé — kopia garde une compatibilité de "
                + "dépôt ascendante — mais rien ne dit non plus que bran sait encore lire ses sorties."
        case .some(.incompatible(let found, let reason)):
            return "Le binaire kopia installé (« \(found) ») est connu comme incompatible avec bran : "
                + "\(reason)"
        case .some(.unreadable(let reason)):
            return "La version de kopia n'a pas pu être lue : \(reason) Aucune sauvegarde ne partira "
                + "tant que le binaire n'est pas joignable."
        }
    }

    /// **Une interruption n'est pas un échec, et ne doit pas en avoir la
    /// couleur** — même règle que `HistoryRow.tintForFailure`. Couvre les
    /// deux formes qu'elle peut prendre dans le contrat : `.interrupted`
    /// directement, ou `.failed` avec `kind == .interrupted` (la coupure
    /// volontaire par l'utilisateur, voir `BackupController.performRun`).
    private var interruptedNotice: String? {
        let failure: BackupFailure?
        switch backup.phase {
        case .interrupted(let f): failure = f
        case .failed(let f) where f.kind == .interrupted: failure = f
        default: failure = nil
        }
        guard let failure else { return nil }
        return "\(failure.summary) La sauvegarde reprendra d'où elle s'est arrêtée."
    }

    /// **La politique batterie, dite en clair.** Purement descriptive de
    /// `configuration.onBatteryPolicy` : « que se passera-t-il, en général,
    /// si je débranche ? » — question antérieure à celle du verdict, qui dit
    /// ce qui se passe *maintenant*.
    private var batteryNotice: String? {
        guard backup.configuration.isEnabled else { return nil }
        guard case .waitForPower(let forceAfterHours) = backup.configuration.onBatteryPolicy else { return nil }
        let hours = Int(forceAfterHours.rounded())
        return """
            Sur batterie, une grosse sauvegarde attend le retour du secteur — \
            mais pas indéfiniment : passé \(hours)\u{202F}heures de retard, elle se \
            lance quand même, batterie ou pas.
            """
    }

    // MARK: - Le héros

    /// **Jamais masqué.** C'est la seule ligne de l'écran qu'on ne replie
    /// jamais et qu'on ne coupe jamais — voir la doctrine de tête de fichier.
    private func hero(_ verdict: BackupHeroVerdict) -> some View {
        HStack(alignment: .top, spacing: Space.small) {
            Image(systemName: verdict.symbol)
                .foregroundStyle(verdict.tint)
                .font(Type.cardTitle)
            // **`fixedSize(vertical:)` hors d'un `ScrollView` bloque la hauteur
            // de la fenêtre, et c'est mesuré.** Voir `NoticeRow` dans
            // `DictationPane.swift` pour le relevé complet : à largeur quasi
            // nulle — la taille que macOS propose à la vue racine pour calculer
            // le plancher de redimensionnement — un texte en hauteur idéale
            // s'enroule en centaines de lignes d'un caractère, et cette hauteur
            // remonte telle quelle jusqu'à la fenêtre (3 832 pt contre 112 pt
            // sur le bandeau le plus long de l'application). Le héros et la
            // ligne d'action vivent **hors** du `ScrollView` de cet écran : ils
            // rejouaient donc exactement ce défaut, dans le neuvième écran
            // après les sept déjà corrigés.
            //
            // `TextWidthFloor` compose le texte à 320 pt au minimum tout en ne
            // rapportant que la largeur proposée : au-dessus de 400 pt, la
            // disposition est identique au point près ; en dessous, la vue
            // rogne au lieu de recomposer — franc, et sans conséquence à une
            // largeur où la fenêtre n'est de toute façon pas utilisable.
            TextWidthFloor(floorWidth: Self.heroTextFloorWidth) {
                VStack(alignment: .leading, spacing: Space.tight) {
                    Text(verdict.title)
                        .font(Type.cardTitle)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail = verdict.detail {
                        Text(detail)
                            .font(Type.cardBody)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .clipped()
        }
        .accessibilityElement(children: .combine)
    }

    /// Le plancher de composition des textes hors `ScrollView` — même valeur
    /// que `NoticeRow`, pour la même raison et avec la même mesure derrière.
    private static let heroTextFloorWidth: CGFloat = 320

    /// **L'unique bouton primaire, toujours au même endroit.**
    ///
    /// Un seul contrôle qui change de métier plutôt que deux boutons
    /// voisins — même motif que le déclencheur de `SpeedPane`, et pour la
    /// même raison : « Sauvegarder maintenant » et « Annuler » ne sont jamais
    /// utiles en même temps, et poser les deux obligerait à en éteindre un en
    /// permanence. C'est aussi ce qui redonne un `Annuler` à l'écran : il
    /// avait disparu avec le panneau « En cours » de l'ancienne version.
    ///
    /// **Responsive** : `ViewThatFits` passe le texte d'échéance et le
    /// bouton sur deux lignes plutôt que de les comprimer l'un contre
    /// l'autre — la fenêtre « sera très rarement utilisée en pleine
    /// largeur ».
    private var actionLine: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: Space.inset) {
                scheduleText
                Spacer(minLength: Space.small)
                actionButton
            }
            VStack(alignment: .leading, spacing: Space.small) {
                scheduleText
                HStack {
                    Spacer()
                    actionButton
                }
            }
        }
    }

    /// Même plancher de largeur que le héros, et pour la même raison : cette
    /// ligne vit elle aussi hors du `ScrollView`.
    private var scheduleText: some View {
        TextWidthFloor(floorWidth: Self.heroTextFloorWidth) {
            Text(Self.scheduleText(backup.scheduleDecision))
                .font(Type.cardBody)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .clipped()
    }

    private var actionButton: some View {
        Button {
            if backup.phase.isBusy {
                backup.cancel()
            } else {
                backup.backUpNow()
            }
        } label: {
            Text(backup.phase.isBusy ? "Annuler" : "Sauvegarder maintenant")
        }
        .buttonStyle(.borderedProminent)
        .tint(backup.phase.isBusy ? Palette.broken : Color.accentColor)
        .disabled(startDisabled)
        .help(startHelp)
    }

    /// **Jamais désactivé pendant un run** : c'est alors le bouton d'annulation,
    /// et il doit rester joignable. Au repos, seule une configuration qui
    /// empêche structurellement de partir (`scheduleDecision == .disabled`)
    /// le désactive.
    private var startDisabled: Bool {
        guard backup.phase.isBusy == false else { return false }
        if case .disabled = backup.scheduleDecision { return true }
        return false
    }

    private var startHelp: String {
        if backup.phase.isBusy { return "Ce qui a déjà été transféré reste dans le dépôt : la reprise repartira de là, pas de zéro." }
        if case .disabled(let reason) = backup.scheduleDecision { return capitalizedFirstLetter(reason) }
        return "Force une tentative maintenant, quelle que soit l'échéance normale."
    }

    /// Le texte de la ligne d'action, pour chacune des six décisions que
    /// `SchedulePolicy` peut rendre. Aucune n'est devinée : chaque branche ne
    /// fait que mettre en phrase ce que la politique a déjà calculé.
    private static func scheduleText(_ decision: ScheduleDecision) -> String {
        switch decision {
        case .backUpNow:
            return "Prête à partir — en attente du prochain cycle de vérification."
        case .wait(let until, let because):
            return "Prévue \(BackupFormat.age(until)) (\(BackupFormat.absolute(until))) — \(because)."
        case .waitForNetwork(let because):
            return "En attente du réseau : \(because)"
        case .waitForPower(let forceAt, let because):
            return "\(capitalizedFirstLetter(because)). Au plus tard \(BackupFormat.age(forceAt)) (\(BackupFormat.absolute(forceAt)))."
        case .disabled(let reason):
            return "Désactivée : \(reason)."
        case .alreadyRunning:
            return "Une tentative est déjà en cours."
        }
    }

    // MARK: - Le défilement

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.stack) {
                firstUploadSection
                chainSection
                proofPanel
                historySection
            }
            .padding(.horizontal, Space.gutter)
            .padding(.vertical, Space.stack)
        }
        .popover(item: $openLink) { item in
            LinkDiagnosticView(link: item.link, result: item.result)
        }
    }

    // MARK: - La première sauvegarde

    /// **Un objet de première classe, pas une barre de progression.** N'existe
    /// que tant qu'au moins un chemin configuré n'a jamais été couvert par un
    /// snapshot prouvé — dès que `coverage` le confirme couvert, la section
    /// disparaît d'elle-même, elle n'a plus rien à montrer.
    @ViewBuilder
    private var firstUploadSection: some View {
        let pending = firstUploads.filter {
            if case .inProgress = $0.state { return true }
            return false
        }
        if pending.isEmpty == false {
            Panel(
                title: pending.count > 1 ? "Premières sauvegardes" : "Première sauvegarde",
                help: """
                    Le tout premier envoi complet d'un dossier : il se compte en \
                    dizaines d'heures, il est coupé et repris des dizaines de fois, \
                    et c'est lui qu'on vient suivre en ouvrant la fenêtre.
                    """
            ) {
                VStack(alignment: .leading, spacing: Space.stack) {
                    ForEach(Array(pending.enumerated()), id: \.offset) { index, tracking in
                        firstUploadRow(tracking)
                        if index != pending.count - 1 { Divider() }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func firstUploadRow(_ tracking: FirstUploadTracking) -> some View {
        VStack(alignment: .leading, spacing: Space.inset) {
            Text(FirstUploadEvaluator.summary(tracking))
                .font(Type.cardBody)
                .fixedSize(horizontal: false, vertical: true)

            switch backup.phase {
            case .running(let progress):
                runningRows(progress)
            case .checkingChain:
                indeterminateRow("Sondage de la chaîne réseau avant de reprendre…")
            case .verifying:
                indeterminateRow("Confirmation dans le dépôt — la seule étape qui prouve vraiment le snapshot…")
            default:
                // **Hors run actif, premier envoi non terminé.** Exactement
                // ce que le propriétaire voit le lendemain matin : le
                // panneau reste, les chiffres restent, seule la phrase
                // change selon la raison de l'arrêt.
                pausedOrStoppedRow(tracking)
            }
        }
    }

    @ViewBuilder
    private func pausedOrStoppedRow(_ tracking: FirstUploadTracking) -> some View {
        let (symbol, tint, text) = Self.pausedOrStoppedText(
            scheduleDecision: backup.scheduleDecision,
            lastAttempt: BackupJournalModel.lastAttempt(in: backup.history)
        )
        HStack(alignment: .top, spacing: Space.small) {
            Image(systemName: symbol).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: Space.tight) {
                Text(text)
                    .font(Type.cardBody)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if case .inProgress(_, let sent, _) = tracking.state,
                   let estimated = latestEstimatedBytes(for: tracking.path), estimated > 0 {
                    // **Le dénominateur qui survit à un redémarrage** — voir
                    // `BackupAttempt.estimatedBytes`. Une proportion, jamais
                    // un pourcentage affirmé : `sent` compte du trafic réseau
                    // reprises comprises, `estimated` une taille logique de
                    // source ; les deux peuvent légitimement diverger, donc
                    // la phrase le dit plutôt que de laisser un nombre seul
                    // prétendre à une précision qu'il n'a pas.
                    Text("Sur une estimation d'environ \(BackupFormat.bytes(estimated)) — le trafic réseau peut la dépasser à cause des reprises.")
                        .font(Type.metaFaint)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    ProgressView(value: min(1, Double(sent) / Double(estimated)))
                }
            }
        }
    }

    /// Les deux phrasés qu'un premier envoi non terminé peut porter hors
    /// d'un run actif : « en pause » quand la cause est le réseau, qu'on
    /// guette activement ; « arrêtée » quand la cause ne se réparera pas
    /// toute seule. Pure, sur ce que `SchedulePolicy` a déjà décidé — aucune
    /// nouvelle condition n'est inventée ici.
    private static func pausedOrStoppedText(
        scheduleDecision: ScheduleDecision,
        lastAttempt: BackupAttempt?
    ) -> (symbol: String, tint: Color, text: String) {
        switch scheduleDecision {
        case .waitForNetwork(let because):
            return (
                "pause.circle.fill", Palette.machine,
                "En pause : \(because) — elle reprendra dès que la ligne reviendra."
            )
        case .waitForPower(let forceAt, let because):
            return (
                "battery.25percent", Palette.machine,
                "\(capitalizedFirstLetter(because)). Reprend au plus tard \(BackupFormat.age(forceAt)) (\(BackupFormat.absolute(forceAt)))."
            )
        case .wait(let until, let because):
            if let failure = lastAttempt?.failure, failure.kind.deservesRetry == false {
                return ("xmark.circle.fill", Palette.broken, "Arrêtée : \(failure.summary)")
            }
            return (
                "clock.arrow.circlepath", Palette.machine,
                "En pause, reprend \(BackupFormat.age(until)) (\(BackupFormat.absolute(until))) — \(because)."
            )
        case .backUpNow:
            return ("arrow.triangle.2.circlepath", Palette.machine, "Reprise imminente — en attente du prochain cycle de vérification.")
        case .disabled(let reason):
            return ("pause.circle.fill", Palette.asleep, "Désactivée : \(reason).")
        case .alreadyRunning:
            return ("arrow.triangle.2.circlepath", Palette.machine, "Une tentative est déjà en cours.")
        }
    }

    /// **Le dénominateur qui survit à un redémarrage**, pour un chemin donné.
    ///
    /// `BackupProgress.estimatedBytes` meurt avec le processus qui l'écrit ;
    /// `BackupAttempt.estimatedBytes` est ce qui en reste dans le journal.
    /// Avec un seul chemin configuré — le cas réel du propriétaire — toute
    /// l'histoire lui appartient. Avec plusieurs, seules les tentatives dont
    /// la preuve porte explicitement ce chemin comptent — même prudence, et
    /// pour la même raison, que `FirstUploadEvaluator.track`.
    private func latestEstimatedBytes(for path: String) -> Int64? {
        let ordered = BackupJournalModel.history(in: backup.history, limit: backup.history.count)
        let relevant = backup.configuration.sourcePaths.count <= 1
            ? ordered
            : ordered.filter { $0.proof?.sourcePath == path }
        return relevant.compactMap(\.estimatedBytes).first
    }

    /// **`fraction == nil` n'est jamais 0 %.** Tant que `progress.fraction`
    /// est `nil`, Kopia n'a pas fini d'estimer le volume total : une barre à
    /// zéro qui ne bouge pas se lit comme un blocage.
    @ViewBuilder
    private func runningRows(_ progress: BackupProgress) -> some View {
        if let fraction = progress.fraction {
            ProgressView(value: fraction) {
                Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                    .font(Type.metricSmall)
                    .monospacedDigit()
            }
        } else {
            indeterminateRow("Estimation du volume en cours — Kopia n'a pas encore de total sur lequel régler la barre.")
        }

        MetricRow {
            GridRow {
                MetricTile(
                    label: "Débit",
                    value: currentRate.map(BackupFormat.rate) ?? "—",
                    detail: currentRate == nil ? "Mesure en cours" : nil
                )
                MetricTile(label: "Envoyé", value: BackupFormat.bytes(progress.uploadedBytes))
                MetricTile(
                    label: "Repris du cache",
                    value: BackupFormat.bytes(progress.cachedBytes),
                    detail: "Ce que la déduplication a évité de renvoyer"
                )
                MetricTile(
                    label: "Restant",
                    value: progress.secondsRemaining.map(BackupFormat.duration) ?? "—",
                    detail: progress.secondsRemaining == nil ? "Pas encore estimé" : nil
                )
            }
        }
    }

    private func indeterminateRow(_ text: String) -> some View {
        HStack(spacing: Space.small) {
            ProgressView().controlSize(.small)
            Text(text)
                .font(Type.cardBody)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var progressSnapshot: BackupProgress? {
        if case .running(let progress) = backup.phase { return progress }
        return nil
    }

    private func updateRate(with progress: BackupProgress) {
        let bytes = progress.uploadedBytes
        let now = Date.now
        defer { rateSample = (bytes, now) }
        guard let previous = rateSample else { return }
        let elapsed = now.timeIntervalSince(previous.at)
        guard elapsed >= BackupPaneMetric.rateSampleFloor else { return }
        currentRate = Double(max(0, bytes - previous.bytes)) / elapsed
    }

    // MARK: - La chaîne réseau, repliée par défaut

    /// **Repliée quand la chaîne est saine, dépliée d'elle-même quand elle ne
    /// l'est pas.** `chainExpandedOverride` laisse l'utilisateur avoir le
    /// dernier mot dans les deux sens.
    private var chainExpandedBinding: Binding<Bool> {
        Binding(
            get: { chainExpandedOverride ?? (backup.chainVerdict.map { $0.canBackUp == false } ?? false) },
            set: { chainExpandedOverride = $0 }
        )
    }

    private var chainSection: some View {
        CollapsibleSection(
            title: chainSummary,
            isExpanded: chainExpandedBinding
        ) {
            // Grille plutôt que défilement horizontal : les six pastilles
            // passent à la ligne en fenêtre étroite au lieu de se coucher
            // derrière un ascenseur caché dans un `ScrollView` déjà vertical.
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: BackupPaneMetric.chainPillMinWidth), spacing: Space.small)],
                alignment: .leading,
                spacing: Space.small
            ) {
                ForEach(ChainLink.allCases, id: \.self) { link in
                    ChainLightPill(
                        link: link,
                        result: backup.chainVerdict?.results.first(where: { $0.link == link }),
                        isConsequence: backup.chainVerdict.map { ChainEvaluator.isConsequence(link, of: $0) } ?? false
                    ) {
                        if let result = backup.chainVerdict?.results.first(where: { $0.link == link }) {
                            openLink = ChainPopoverItem(link: link, result: result)
                        }
                    }
                }
            }
        }
    }

    private var chainSummary: String {
        guard let verdict = backup.chainVerdict else {
            return "Chaîne réseau — jamais sondée depuis le lancement."
        }
        return "Chaîne réseau — \(verdict.headline)"
    }

    // MARK: - Les preuves

    /// **Le dernier snapshot digne de confiance, et rien qui l'imite.** Le
    /// seul bouton « Vérifier maintenant » de tout l'écran vit ici — l'ancien
    /// second exemplaire, posé sur la rangée des six maillons, appelait déjà
    /// exactement la même fonction : les fusionner ne perd rien.
    private var proofPanel: some View {
        Panel(title: "Preuves", help: "Le dernier snapshot relu dans le dépôt, pas celui que Kopia a seulement annoncé.") {
            if let attempt = BackupJournalModel.lastSuccess(in: backup.history), let proof = attempt.proof {
                VStack(alignment: .leading, spacing: Space.inset) {
                    Text(proof.id)
                        .font(Type.code)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    MetricRow {
                        GridRow {
                            MetricTile(label: "Taille de la source", value: BackupFormat.bytes(proof.totalSize))
                            MetricTile(label: "Fichiers", value: proof.fileCount.formatted(.number.locale(ResourceFormat.locale)))
                            MetricTile(
                                label: "Nouveau depuis avant",
                                value: BackupJournalModel.newBytesSinceLastAttempt(in: backup.history)
                                    .map(BackupFormat.signedBytes) ?? "—",
                                detail: "Ce qui a vraiment transité, hors reprise du cache"
                            )
                            if let repositorySizeBytes = backup.repositorySizeBytes {
                                MetricTile(label: "Taille du dépôt", value: BackupFormat.bytes(repositorySizeBytes))
                            }
                        }
                    }

                    integrityLine

                    HStack {
                        Spacer()
                        Button("Vérifier maintenant") { backup.verifyChainNow() }
                            .disabled(backup.phase.isBusy)
                            .help("Resonde les six maillons, dépôt compris — le plus cher, et le plus vrai.")
                        Button("Vérifier l'intégrité") { backup.verifyRepositoryIntegrity() }
                            .disabled(backup.phase.isBusy || backup.isVerifyingIntegrity)
                            .help("Lance « kopia snapshot verify » : relit ce que le dépôt contient "
                                + "réellement, snapshot par snapshot. C'est la commande la plus chère de "
                                + "tout l'écran — plusieurs minutes sur un dépôt fourni.")
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: Space.small) {
                    Text("Aucun snapshot vérifié pour l'instant.")
                        .font(Type.cardBody)
                        .foregroundStyle(.secondary)
                    HStack {
                        Spacer()
                        Button("Vérifier maintenant") { backup.verifyChainNow() }
                            .disabled(backup.phase.isBusy)
                    }
                }
            }
        }
    }

    /// **Ce qui distingue « le dépôt dit qu'il l'a » de « bran l'a relu ».**
    /// `KopiaDriver.verify()` existait, complet et documenté, et n'était appelé
    /// nulle part dans le dépôt : rien, sur cet écran, ne reposait sur une
    /// relecture réelle du contenu.
    @ViewBuilder
    private var integrityLine: some View {
        if backup.isVerifyingIntegrity {
            HStack(spacing: Space.small) {
                ProgressView().controlSize(.small)
                Text("Relecture du dépôt en cours — « kopia snapshot verify ».")
                    .font(Type.metaFaint)
                    .foregroundStyle(.secondary)
            }
        } else if let check = backup.lastIntegrityCheck {
            HStack(alignment: .top, spacing: Space.small) {
                Image(systemName: check.succeeded ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(check.succeeded ? Palette.done : Palette.attention)
                Text(check.succeeded
                    ? "Intégrité vérifiée \(BackupFormat.age(check.at)) (\(BackupFormat.absolute(check.at)))."
                    : "Vérification d'intégrité en échec \(BackupFormat.age(check.at)) : \(check.failure?.summary ?? "")")
                    .font(Type.metaFaint)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text("L'intégrité de ce dépôt n'a jamais été vérifiée : bran sait que le snapshot y est "
                + "référencé, pas encore que son contenu se relit.")
                .font(Type.metaFaint)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - L'historique, replié par défaut

    private var historySection: some View {
        let attempts = BackupJournalModel.history(in: backup.history, limit: BackupPaneMetric.historyLimit)
        return CollapsibleSection(
            title: "Historique",
            trailing: attempts.isEmpty ? nil : "\(attempts.count)",
            isExpanded: $historyExpanded
        ) {
            VStack(alignment: .leading, spacing: Space.inset) {
                if let failure = activeFailure {
                    activeFailureBlock(failure)
                    Divider()
                }

                if attempts.isEmpty {
                    Text("Aucune tentative consignée pour l'instant.")
                        .font(Type.cardBody)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: Space.small) {
                        ForEach(attempts) { attempt in
                            HistoryRow(attempt: attempt)
                            if attempt.id != attempts.last?.id { Divider() }
                        }
                    }
                }
            }
        }
    }

    /// **La panne active, jamais un résumé.** Hors d'un run, la dernière
    /// tentative non réussie — et pas seulement interrompue, qui a déjà sa
    /// propre notice bleue — reste affichée avec son texte brut, pour qu'on
    /// n'ait pas à ouvrir le journal pour savoir pourquoi la nuit dernière a
    /// raté.
    private var activeFailure: BackupFailure? {
        if case .failed(let failure) = backup.phase { return failure }
        let last = BackupJournalModel.lastAttempt(in: backup.history)
        guard let last, last.succeeded == false, let failure = last.failure, failure.kind != .interrupted else { return nil }
        return failure
    }

    private func activeFailureBlock(_ failure: BackupFailure) -> some View {
        VStack(alignment: .leading, spacing: Space.inset) {
            Text(failure.summary)
                .font(Type.cardBodyStrong)
                .fixedSize(horizontal: false, vertical: true)

            if let action = failure.suggestedAction {
                Text(action)
                    .font(Type.cardBody)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(failure.rawOutput)
                .font(Type.code)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(BackupPaneMetric.rawOutputLines)
                .branWell()

            HStack {
                Spacer()
                Button("Copier le diagnostic") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(
                        [failure.summary, failure.suggestedAction, failure.rawOutput]
                            .compactMap { $0 }
                            .joined(separator: "\n\n"),
                        forType: .string
                    )
                }
            }
        }
    }
}

// MARK: - Le verdict unique

/// **Ce que la puce d'en-tête et le héros affichent — et rien qu'eux ne
/// calcule séparément.** Voir la documentation de `BackupPane` pour la table
/// de priorité complète ; ce type n'en est que la forme portée.
private struct BackupHeroVerdict: Equatable {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String?

    static func evaluate(
        scheduleDecision: ScheduleDecision,
        hasAllSecrets: Bool,
        launchAgentStatus: LaunchAgentStatus,
        phase: BackupPhase,
        chainVerdict: ChainVerdict?,
        coverage: SourceCoverageReport,
        lastIntegrityCheck: BackupController.IntegrityCheck?
    ) -> BackupHeroVerdict {
        // P0 — configuration désactivée ou incomplète. `scheduleDecision`
        // porte déjà exactement cette réponse (`SchedulePolicy` vérifie
        // `isEnabled`, les chemins, les identifiants S3 et le nœud
        // Tailscale, dans cet ordre) : la relire ici plutôt que de
        // redéfinir « incomplète » évite une deuxième définition qui
        // pourrait diverger de celle qui gouverne réellement la
        // planification.
        if case .disabled(let reason) = scheduleDecision {
            return BackupHeroVerdict(
                symbol: "pause.circle.fill", tint: Palette.asleep,
                title: "Sauvegarde désactivée.",
                detail: "\(capitalizedFirstLetter(reason))."
            )
        }

        // P1 — un secret manque au Trousseau.
        guard hasAllSecrets else {
            return BackupHeroVerdict(
                symbol: "key.slash.fill", tint: Palette.attention,
                title: "Un secret manque au Trousseau.",
                detail: "La sauvegarde ne peut pas ouvrir le dépôt sans lui. Complétez-le dans les préférences."
            )
        }

        // P1bis — le job launchd n'est pas là.
        //
        // **Il était calculé et jamais montré.** `BackupController` relit
        // l'état réel auprès de `launchctl print` toutes les dix minutes et
        // range le verdict dans `launchAgentStatus` ; aucune vue ne le lisait.
        // Or c'est exactement la panne fondatrice du projet, une case plus
        // loin : une planification qui existe sur le papier et que rien
        // n'exécute. L'écran disait « activée », le job n'était pas chargé, et
        // le seul témoin était `Console.app`.
        //
        // Placé après le Trousseau et avant la couverture, parce que c'est un
        // blocage technique qu'un geste répare — pas un jugement sur les
        // fichiers. Et **avant** `phase.isBusy` : un run manuel en cours ne
        // change rien au fait que rien ne partira tout seul cette nuit.
        switch launchAgentStatus {
        case .installFailed(let reason):
            return BackupHeroVerdict(
                symbol: "calendar.badge.exclamationmark", tint: Palette.broken,
                title: "La sauvegarde planifiée n'a pas pu être installée.",
                detail: "Rien ne partira tout seul tant que ce n'est pas levé — \(reason)"
            )
        case .notLoaded:
            return BackupHeroVerdict(
                symbol: "calendar.badge.exclamationmark", tint: Palette.attention,
                title: "La sauvegarde planifiée ne tourne pas.",
                detail: "Le fichier du job est écrit, mais launchd ne le voit pas chargé : aucune "
                    + "sauvegarde ne partira d'elle-même. Désactivez puis réactivez la sauvegarde dans "
                    + "les réglages pour le réinstaller."
            )
        case .notApplicable, .running:
            break
        }

        // P2 — une tentative occupe déjà le dépôt.
        if phase.isBusy {
            return busyVerdict(phase)
        }

        // P3 / P4 — la chaîne réseau.
        if let chainVerdict {
            if chainVerdict.canBackUp == false, chainVerdict.firstFailure != nil {
                return BackupHeroVerdict(
                    symbol: "bolt.horizontal.circle.fill", tint: Palette.broken,
                    title: "La chaîne réseau est cassée.",
                    detail: chainVerdict.headline
                )
            }
            if chainVerdict.canBackUp == false {
                // Ni panne ferme ni chaîne prête : sonde en vol ou mesure
                // périmée (`connecting`/`unknown`). Bleu, jamais rouge — un
                // maillon `degraded` ne tombe pas ici, `canBackUp` reste vrai
                // pour lui, voir `ChainEvaluator`.
                return BackupHeroVerdict(
                    symbol: "questionmark.circle.fill", tint: Palette.machine,
                    title: "État du réseau pas encore su.",
                    detail: chainVerdict.headline
                )
            }
        } else {
            return BackupHeroVerdict(
                symbol: "questionmark.circle.fill", tint: Palette.machine,
                title: "État du réseau pas encore su.",
                detail: "Aucune sonde n'a encore tourné depuis le lancement de bran."
            )
        }

        // P5, P6, P7 — la couverture des sources, jamais `lastSuccess` seul.
        switch coverage.verdict {
        case .notCovered:
            return BackupHeroVerdict(
                symbol: "shield.slash.fill", tint: Palette.attention,
                title: "Vos fichiers ne sont pas protégés.",
                detail: coverage.headline
            )
        case .partiallyCovered:
            return BackupHeroVerdict(
                symbol: "shield.lefthalf.filled", tint: Palette.attention,
                title: "Vos fichiers ne sont protégés qu'en partie.",
                detail: coverage.headline
            )
        case .fullyCovered:
            let hasStale = coverage.coverages.contains {
                if case .coveredButStale = $0.state { return true }
                return false
            }
            if hasStale {
                return BackupHeroVerdict(
                    symbol: "exclamationmark.triangle.fill", tint: Palette.attention,
                    title: "Votre sauvegarde n'est plus à jour.",
                    detail: coverage.headline
                )
            }
            // **Ce que cette phrase a le droit d'affirmer, et pas un mot de
            // plus.**
            //
            // Elle disait « Vos fichiers sont à l'abri ». Ce qui est prouvé à
            // ce point, c'est que chaque dossier configuré est couvert par un
            // snapshot **relu dans le dépôt** et récent — ce qui est déjà
            // beaucoup, et bien plus qu'un `create` qui a rendu 0. Mais
            // personne n'a encore vérifié que ces octets se relisent :
            // `kopia snapshot verify` existe dans le pilote et n'était appelé
            // nulle part, et aucune restauration n'a jamais eu lieu.
            //
            // « À l'abri » est une promesse de restitution ; « sauvegardés »
            // est un constat d'envoi. Tant que l'intégrité n'a pas été
            // vérifiée, c'est le constat qu'on affiche — et le détail dit
            // exactement ce qui manque, avec le bouton qui le comble juste en
            // dessous, dans le panneau « Preuves ».
            if let check = lastIntegrityCheck, check.succeeded {
                return BackupHeroVerdict(
                    symbol: "checkmark.shield.fill", tint: Palette.done,
                    title: "Vos fichiers sont à l'abri.",
                    detail: coverage.headline
                        + " Intégrité du dépôt vérifiée \(BackupFormat.age(check.at))."
                )
            }
            if let check = lastIntegrityCheck, let failure = check.failure {
                return BackupHeroVerdict(
                    symbol: "exclamationmark.shield.fill", tint: Palette.attention,
                    title: "Le dépôt ne se relit pas entièrement.",
                    detail: "Les dossiers sont couverts, mais la vérification d'intégrité a échoué : "
                        + failure.summary
                )
            }
            return BackupHeroVerdict(
                symbol: "checkmark.shield.fill", tint: Palette.done,
                title: "Vos fichiers sont sauvegardés.",
                detail: coverage.headline
                    + " L'intégrité du dépôt n'a pas encore été vérifiée — « Vérifier l'intégrité », "
                    + "dans « Preuves », relit ce que le dépôt contient réellement."
            )
        }
    }

    private static func busyVerdict(_ phase: BackupPhase) -> BackupHeroVerdict {
        switch phase {
        case .checkingChain:
            return BackupHeroVerdict(
                symbol: "arrow.triangle.2.circlepath", tint: Palette.machine,
                title: "Vérification de la chaîne…",
                detail: "bran sonde les six maillons avant de commencer."
            )
        case .running:
            return BackupHeroVerdict(
                symbol: "arrow.up.circle.fill", tint: Palette.machine,
                title: "Sauvegarde en cours…",
                detail: "Le détail du transfert est ci-dessous."
            )
        case .verifying:
            return BackupHeroVerdict(
                symbol: "checkmark.seal.fill", tint: Palette.machine,
                title: "Confirmation dans le dépôt…",
                detail: "La seule étape qui prouve vraiment le snapshot."
            )
        case .idle, .success, .failed, .waitingForNetwork, .interrupted:
            // Structurellement inatteignable : `phase.isBusy` n'est vrai que
            // pour les trois cas ci-dessus. Un repli franc plutôt qu'un
            // `fatalError` — même doctrine que `ChainEvaluator.evaluate` : ne
            // jamais planter sur un état imprévu, le dire.
            return BackupHeroVerdict(
                symbol: "arrow.triangle.2.circlepath", tint: Palette.machine,
                title: "En cours…", detail: nil
            )
        }
    }
}

/// Met en majuscule la première lettre d'une phrase, et rien d'autre — pas
/// `.capitalized`, qui capitalise chaque mot et transformerait « le pair
/// MinIO ne répond pas » en un titre à la mode anglaise. Les diagnostics de
/// `SchedulePolicy` et de `ChainEvaluator` sont écrits en minuscules pour
/// s'enchaîner dans une phrase.
private func capitalizedFirstLetter(_ text: String) -> String {
    guard let first = text.first else { return text }
    return String(first).uppercased() + text.dropFirst()
}

// MARK: - La puce d'en-tête

/// **Lit le même verdict que le héros, jamais un second calcul.** Le texte
/// est tronqué à une ligne — la phrase complète, elle, vit dans le héros et
/// dans l'infobulle — mais la couleur et le symbole sont identiques aux deux
/// endroits par construction : ils viennent de la même valeur.
private struct BackupStatusChip: View {
    let verdict: BackupHeroVerdict

    var body: some View {
        HStack(spacing: Space.tight) {
            Image(systemName: verdict.symbol)
                .foregroundStyle(verdict.tint)
            Text(verdict.title)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(Type.meta)
        .padding(.horizontal, Space.inset)
        .padding(.vertical, Space.tight)
        .background(Palette.well, in: .capsule)
        .frame(maxWidth: BackupPaneMetric.chipMaxWidth, alignment: .leading)
        .help([verdict.title, verdict.detail].compactMap { $0 }.joined(separator: " — "))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("État de la sauvegarde : \(verdict.title)")
    }
}

// MARK: - Une section repliable

/// **Le même habillage visuel qu'un `Panel`**, mais dont le contenu ne
/// s'affiche qu'à la demande — pour que la chaîne saine et l'historique
/// n'occupent, au repos, qu'une seule ligne chacun plutôt que d'imposer leur
/// contenu entier à une fenêtre qu'on utilise rarement en pleine hauteur.
private struct CollapsibleSection<Content: View>: View {
    let title: String
    var trailing: String?
    @Binding var isExpanded: Bool
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: Space.small) {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .font(Type.metaFaint)
                        .foregroundStyle(.secondary)
                    Text(title)
                        .font(Type.panelHead)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: Space.small)
                    if let trailing {
                        Text(trailing)
                            .font(Type.meta.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, Space.inset)
                .padding(.vertical, Space.small)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.panelHead)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isHeader)
            .accessibilityValue(isExpanded ? "déplié" : "replié")

            if isExpanded {
                content
                    .padding(Space.inset)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Palette.panel, in: .rect(cornerRadius: Radius.panel))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.panel, style: .continuous)
                .strokeBorder(.separator, lineWidth: PanelMetric.edge)
        }
        .branAnimation(Motion.state, value: isExpanded)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Une pastille de maillon

private struct ChainPopoverItem: Identifiable {
    let link: ChainLink
    let result: LinkProbeResult
    var id: ChainLink { link }
}

/// **Une pastille par maillon**, avec sa latence quand on la connaît.
///
/// **Les conséquences en retrait, la cause en pleine lumière.** Quand la
/// chaîne casse au maillon 2, les maillons 3 à 6 sont rouges par
/// construction — `ChainEvaluator.isConsequence` le sait, cette pastille
/// s'en sert pour s'effacer plutôt que d'ajouter cinq alarmes qui ne disent
/// rien de plus que la première.
private struct ChainLightPill: View {
    let link: ChainLink
    let result: LinkProbeResult?
    let isConsequence: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: Space.tight) {
                indicator
                Text(Self.label(link))
                if let latency = result?.latency {
                    Text(BackupFormat.milliseconds(latency))
                        .foregroundStyle(.secondary)
                }
            }
            .font(Type.meta)
            .padding(.horizontal, Space.inset)
            .padding(.vertical, Space.tight)
            .background(Palette.well, in: .capsule)
        }
        .buttonStyle(.plain)
        .opacity(isConsequence ? BackupPaneMetric.consequenceOpacity : 1)
        .help(result?.diagnostic ?? "\(Self.label(link)) — jamais sondé depuis le lancement.")
        .accessibilityLabel("\(Self.label(link)) : \(result?.diagnostic ?? "jamais sondé")")
    }

    @ViewBuilder
    private var indicator: some View {
        switch result?.state {
        case .up:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.done)
        case .down:
            Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.broken)
        case .degraded:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Palette.attention)
        case .connecting:
            ProgressView().controlSize(.mini)
        case .unknown, .none:
            Image(systemName: "questionmark.circle").foregroundStyle(.tertiary)
        }
    }

    private static func label(_ link: ChainLink) -> String {
        switch link {
        case .tailscaleLocal: "Tailscale"
        case .minioNodeOnline: "Pair MinIO"
        case .s3Reachable: "Port S3"
        case .minioHealthy: "Santé MinIO"
        case .bucketReachable: "Seau"
        case .repositoryOpens: "Dépôt"
        }
    }
}

/// Le diagnostic détaillé d'un maillon, à la demande — jamais affiché
/// d'office, pour que la rangée reste lisible d'un coup d'œil.
private struct LinkDiagnosticView: View {
    let link: ChainLink
    let result: LinkProbeResult

    var body: some View {
        VStack(alignment: .leading, spacing: Space.inset) {
            Text(result.diagnostic)
                .font(Type.cardBodyStrong)
                .fixedSize(horizontal: false, vertical: true)

            if let rawDetail = result.rawDetail {
                // **Le détail brut défile, et il est borné à l'affichage.**
                //
                // `rawDetail` porte ce que le serveur a répondu :
                // `ChainProbes.bodyText(_:)` y met le **corps entier** de la
                // réponse HTTP, et `probeRepository()` la sortie d'erreur de
                // kopia. Un MinIO qui rend une page d'erreur de plusieurs
                // milliers de lignes — ou n'importe quoi d'autre qui écoute sur
                // ce port — produisait un `Text` en hauteur idéale, sans
                // `ScrollView` ni plafond : le popover devenait plus haut que
                // l'écran, donc impossible à lire *et* impossible à fermer par
                // son bouton, puisque le bouton passait sous le bord.
                //
                // Deux bornes, pas une : `lineLimit` coupe ce que le moteur de
                // texte doit composer (un texte d'un million de lignes reste
                // coûteux même dans un `ScrollView`), et `maxHeight` borne ce
                // que le popover réclame à l'écran. Le texte entier reste
                // accessible par « Copier le diagnostic », qui ne tronque rien.
                ScrollView {
                    Text(rawDetail)
                        .font(Type.code)
                        .textSelection(.enabled)
                        .lineLimit(BackupPaneMetric.popoverRawLines)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: BackupPaneMetric.popoverRawMaxHeight)
                .branWell()
            }

            Text("Mesuré \(BackupFormat.age(result.measuredAt)).")
                .font(Type.metaFaint)
                .foregroundStyle(.secondary)

            if let rawDetail = result.rawDetail {
                Button("Copier le diagnostic") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(result.diagnostic + "\n\n" + rawDetail, forType: .string)
                }
            }
        }
        .padding(Space.stack)
        .frame(width: BackupPaneMetric.popoverWidth)
    }
}

// MARK: - Une ligne d'historique

private struct HistoryRow: View {
    let attempt: BackupAttempt

    var body: some View {
        HStack(alignment: .top, spacing: Space.small) {
            Image(systemName: attempt.succeeded ? "checkmark.circle.fill" : symbolForFailure)
                .foregroundStyle(attempt.succeeded ? AnyShapeStyle(Palette.done) : AnyShapeStyle(tintForFailure))

            VStack(alignment: .leading, spacing: Space.hair) {
                Text(BackupFormat.absolute(attempt.startedAt))
                    .font(Type.cardBody)
                Text(subtitle)
                    .font(Type.metaFaint)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: Space.small)

            if let bytes = attempt.uploadedBytes {
                Text(BackupFormat.bytes(bytes))
                    .font(Type.meta)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        var parts = [Self.triggerLabel(attempt.trigger)]
        if let failure = attempt.failure, attempt.succeeded == false {
            parts.append(failure.summary)
        } else if attempt.succeeded {
            parts.append("réussie")
        }
        return parts.joined(separator: " · ")
    }

    /// **Interrompue n'est pas rouge**, ici non plus — même règle que
    /// `BackupPane.interruptedNotice`.
    private var tintForFailure: Color {
        attempt.failure?.kind == .interrupted ? Palette.machine : Palette.broken
    }

    private var symbolForFailure: String {
        attempt.failure?.kind == .interrupted ? "pause.circle.fill" : "xmark.circle.fill"
    }

    private static func triggerLabel(_ trigger: BackupTrigger) -> String {
        switch trigger {
        case .manual: "manuelle"
        case .scheduled: "planifiée"
        case .catchUp: "rattrapage"
        case .networkReturned: "réseau revenu"
        case .resume: "reprise"
        }
    }
}

// MARK: - Le formatage

/// **Les octets et les durées, en français, alignés sur ce que Kopia
/// affiche.**
///
/// `.byteCount(style: .file)` compte en puissances de 1000 — comme Kopia et
/// comme le Finder depuis Snow Leopard — jamais en puissances de 1024 :
/// afficher un chiffre différent de celui que `kopia` écrit sur la même
/// donnée serait une deuxième source de vérité, exactement ce que ce projet
/// existe pour éliminer.
enum BackupFormat {
    static func bytes(_ value: Int64) -> String {
        value.formatted(.byteCount(style: .file).locale(ResourceFormat.locale))
    }

    /// Le même chiffre, signé — pour un delta qui peut être négatif sans que
    /// ce soit une anomalie (voir `BackupJournalModel.newBytes`).
    static func signedBytes(_ value: Int64) -> String {
        let sign = value >= 0 ? "+" : "−"
        return "\(sign)\(bytes(abs(value)))"
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        let value = bytesPerSecond / 1_000_000
        return "\(value.formatted(.number.precision(.fractionLength(1)).locale(ResourceFormat.locale)))\u{202F}Mo/s"
    }

    static func milliseconds(_ seconds: TimeInterval) -> String {
        "\(Int((seconds * 1000).rounded()))\u{202F}ms"
    }

    /// « il y a 3 h » / « dans 2 j ».
    static func age(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = ResourceFormat.locale
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: .now)
    }

    /// « 2 sept. 08:12 ». Toujours accompagnée d'``age(_:)`` : le contrat de
    /// ce fichier avec ses appelants est de ne jamais afficher l'une sans
    /// l'autre.
    static func absolute(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(ResourceFormat.locale))
    }

    /// « 4 jours », « 3 heures » — une durée nue, sans « il y a ». Distincte
    /// d'``age(_:)`` : celle-ci sert la phrase « depuis … », qui porte déjà
    /// son propre verbe.
    static func duration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.calendar?.locale = ResourceFormat.locale
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 1
        formatter.allowedUnits = [.day, .hour, .minute]
        return formatter.string(from: max(0, seconds)) ?? "quelques instants"
    }
}

enum BackupPaneMetric {
    /// En dessous, deux tics de progression sont trop rapprochés pour donner
    /// un débit stable — la première ligne de Kopia arrive parfois moins
    /// d'une seconde après la précédente.
    static let rateSampleFloor: TimeInterval = 2

    static let consequenceOpacity: Double = 0.45
    static let popoverWidth: CGFloat = 320

    /// Ce qu'un détail brut a le droit d'occuper dans un popover : de quoi
    /// lire une erreur réelle sans que le popover puisse dépasser la hauteur
    /// d'un écran de portable. Le texte complet reste accessible par
    /// « Copier le diagnostic ».
    static let popoverRawMaxHeight: CGFloat = 260
    /// Le plafond de composition, distinct du plafond d'affichage : un texte
    /// d'un million de lignes coûte cher au moteur de disposition même quand
    /// il défile.
    static let popoverRawLines = 200
    static let historyLimit = 12
    static let rawOutputLines = 6

    /// La largeur maximale de la puce d'en-tête avant troncature. Assez pour
    /// « Vos fichiers ne sont pas protégés. » en entier ; au-delà, une
    /// ellipse — la phrase complète reste dans le héros et dans l'infobulle.
    static let chipMaxWidth: CGFloat = 240

    /// La largeur minimale d'une pastille de maillon dans la grille
    /// adaptative — assez pour « Santé MinIO 42 ms » sans rogner.
    static let chainPillMinWidth: CGFloat = 150
}

// MARK: - Fixtures de prévisualisation

/// Des états fabriqués, pour relire cette vue sans lancer l'application ni
/// une seule vraie sauvegarde.
private enum BackupPreviewFixture {
    static func configuration(sourcePaths: [String]) -> BackupConfiguration {
        BackupConfiguration(
            s3Endpoint: "minio-backup.tail-net.ts.net:9000",
            s3Bucket: "bran-backup",
            s3Region: "us-east-1",
            disableTLS: false,
            s3AccessKeyID: "AKIAEXEMPLE",
            sourcePaths: sourcePaths,
            ignoreRules: ["*.tmp", "node_modules/"],
            intervalHours: 24,
            tailscaleMinioNodeName: "minio-backup",
            minioTailscaleIP: "100.x.x.x",
            onBatteryPolicy: .waitForPower(forceAfterHours: 48),
            probeTimeout: 5,
            repositoryTimeout: 30,
            isEnabled: true
        )
    }

    static func proof(path: String, id: String, minutesAgo: Double, errorCount: Int = 0) -> SnapshotProof {
        let end = Date.now.addingTimeInterval(-minutesAgo * 60)
        return SnapshotProof(
            id: id,
            rootObjectID: "k348b268a5c" + id.suffix(8),
            sourcePath: path,
            sourceHost: "bran-mac",
            sourceUser: NSUserName(),
            startTime: end.addingTimeInterval(-1800),
            endTime: end,
            totalSize: 428_000_000_000,
            fileCount: 214_512,
            dirCount: 8_204,
            errorCount: errorCount,
            ignoredErrorCount: 0,
            origin: .confirmedInRepository
        )
    }

    static func succeededAttempt(path: String, id: String, hoursAgo: Double, uploadedBytes: Int64) -> BackupAttempt {
        let end = Date.now.addingTimeInterval(-hoursAgo * 3600)
        return BackupAttempt(
            id: UUID(),
            startedAt: end.addingTimeInterval(-1800),
            finishedAt: end,
            trigger: .scheduled,
            proof: proof(path: path, id: id, minutesAgo: hoursAgo * 60),
            failure: nil,
            uploadedBytes: uploadedBytes
        )
    }

    /// Une reprise du premier envoi : ni preuve, ni confirmation — seulement
    /// du trafic réseau et, parfois, une raison d'arrêt.
    static func firstUploadAttempt(
        hoursAgo: Double,
        uploadedBytes: Int64,
        estimatedBytes: Int64?,
        failure: BackupFailure?
    ) -> BackupAttempt {
        let end = Date.now.addingTimeInterval(-hoursAgo * 3600)
        return BackupAttempt(
            id: UUID(),
            startedAt: end.addingTimeInterval(-3600),
            finishedAt: end,
            trigger: .scheduled,
            proof: nil,
            failure: failure,
            uploadedBytes: uploadedBytes,
            estimatedBytes: estimatedBytes
        )
    }

    static func linkResult(_ link: ChainLink, state: LinkState, latency: TimeInterval? = nil) -> LinkProbeResult {
        LinkProbeResult(
            link: link,
            state: state,
            diagnostic: state == .up
                ? "\(link.rawValue) répond."
                : "\(link.rawValue) — le pair MinIO ne répond pas dans le tailnet ; vérifiez qu'il est allumé.",
            rawDetail: state == .up ? nil : "tailscale ping minio-backup : aucune réponse après 5000 ms",
            latency: latency,
            measuredAt: .now
        )
    }

    static var greenChain: ChainVerdict {
        let results = ChainLink.allCases.map { linkResult($0, state: .up, latency: 0.02) }
        return ChainVerdict(results: results, firstFailure: nil, headline: "La chaîne est verte : les six maillons répondent.", canBackUp: true)
    }

    static var brokenAtLink2: ChainVerdict {
        var results: [LinkProbeResult] = []
        results.append(linkResult(.tailscaleLocal, state: .up, latency: 0.01))
        results.append(linkResult(.minioNodeOnline, state: .down))
        for link in [ChainLink.s3Reachable, .minioHealthy, .bucketReachable, .repositoryOpens] {
            results.append(linkResult(link, state: .down))
        }
        return ChainVerdict(
            results: results,
            firstFailure: .minioNodeOnline,
            headline: "minioNodeOnline — le pair MinIO ne répond pas dans le tailnet ; vérifiez qu'il est allumé.",
            canBackUp: false
        )
    }
}

extension BackupController {
    /// Un contrôleur fabriqué pour la prévisualisation — jamais utilisé par
    /// l'application réelle. `start()` n'est jamais appelé : `coverage` et
    /// `firstUploads` restent `nil`/`[]` sur ce contrôleur, et c'est
    /// exactement pour ça que `BackupPane.coverage`/`firstUploads` savent
    /// les recalculer eux-mêmes depuis `history` — voir le commentaire de
    /// tête de fichier.
    fileprivate static func preview(
        phase: BackupPhase = .idle,
        sourcePaths: [String],
        chainVerdict: ChainVerdict? = BackupPreviewFixture.greenChain,
        history: [BackupAttempt] = [],
        scheduleDecision: ScheduleDecision = .wait(until: .now.addingTimeInterval(3600 * 20), because: "prochaine sauvegarde à l'échéance normale")
    ) -> BackupController {
        BackupController(
            phase: phase,
            configuration: BackupPreviewFixture.configuration(sourcePaths: sourcePaths),
            chainVerdict: chainVerdict,
            history: history,
            scheduleDecision: scheduleDecision
        )
    }
}

#Preview("Jamais sauvegardé") {
    BackupPane(backup: .preview(
        sourcePaths: [NSHomeDirectory()],
        history: [],
        scheduleDecision: .backUpNow(.catchUp)
    ))
    .frame(width: 760)
}

#Preview("Premier envoi en cours") {
    BackupPane(backup: .preview(
        phase: .running(BackupProgress(
            hashingFiles: 3,
            hashedFiles: 118_204,
            hashedBytes: 268_000_000_000,
            cachedBytes: 12_000_000_000,
            uploadedBytes: 118_000_000_000,
            estimatedBytes: 428_000_000_000,
            secondsRemaining: 5_400
        )),
        sourcePaths: [NSHomeDirectory()],
        history: [
            BackupPreviewFixture.firstUploadAttempt(hoursAgo: 14, uploadedBytes: 210_000_000_000, estimatedBytes: 428_000_000_000, failure: nil),
            BackupPreviewFixture.firstUploadAttempt(
                hoursAgo: 6, uploadedBytes: 180_000_000_000, estimatedBytes: 428_000_000_000,
                failure: BackupFailure(kind: .interrupted, summary: "Veille pendant le transfert.", rawOutput: "SIGTERM")),
        ],
        scheduleDecision: .alreadyRunning
    ))
    .frame(width: 760)
}

#Preview("Premier envoi en pause") {
    BackupPane(backup: .preview(
        sourcePaths: [NSHomeDirectory()],
        history: [
            BackupPreviewFixture.firstUploadAttempt(hoursAgo: 30, uploadedBytes: 210_000_000_000, estimatedBytes: 428_000_000_000, failure: nil),
            BackupPreviewFixture.firstUploadAttempt(
                hoursAgo: 15, uploadedBytes: 180_000_000_000, estimatedBytes: 428_000_000_000,
                failure: BackupFailure(kind: .network, summary: "Le pair MinIO ne répond plus.", rawOutput: "tailscale ping : timeout")),
            BackupPreviewFixture.firstUploadAttempt(
                hoursAgo: 2, uploadedBytes: 0, estimatedBytes: 428_000_000_000,
                failure: BackupFailure(kind: .storage, summary: "Disque plein sur le dépôt.", suggestedAction: "Libérez de l'espace sur le NAS avant de relancer.", rawOutput: "no space left on device")),
        ],
        scheduleDecision: .wait(
            until: .now.addingTimeInterval(3600 * 22),
            because: "le dernier échec (storage) ne se répare pas tout seul"
        )
    ))
    .frame(width: 760)
}

#Preview("Chaîne cassée au maillon 2") {
    BackupPane(backup: .preview(
        phase: .waitingForNetwork(BackupPreviewFixture.brokenAtLink2),
        sourcePaths: [NSHomeDirectory() + "/Documents"],
        chainVerdict: BackupPreviewFixture.brokenAtLink2,
        history: [
            BackupPreviewFixture.succeededAttempt(path: NSHomeDirectory() + "/Documents", id: "6145671624282e64839f6e3a98678614", hoursAgo: 96, uploadedBytes: 118_000_000_000),
        ],
        scheduleDecision: .waitForNetwork("minioNodeOnline — le pair MinIO ne répond pas dans le tailnet ; vérifiez qu'il est allumé.")
    ))
    .frame(width: 760)
}

#Preview("Tout à jour") {
    BackupPane(backup: .preview(
        sourcePaths: [NSHomeDirectory() + "/Documents"],
        history: [
            BackupPreviewFixture.succeededAttempt(path: NSHomeDirectory() + "/Documents", id: "8145671624282e64839f6e3a98678616", hoursAgo: 3, uploadedBytes: 2_100_000_000),
            BackupPreviewFixture.succeededAttempt(path: NSHomeDirectory() + "/Documents", id: "7145671624282e64839f6e3a98678615", hoursAgo: 27, uploadedBytes: 118_000_000_000),
        ]
    ))
    .frame(width: 760)
}
