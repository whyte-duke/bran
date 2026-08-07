import BranCore
import SwiftUI

struct MenuBarContent: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // Affiché **aussi** pendant un enregistrement, c'est-à-dire pendant la
        // réunion : le lien de la visio disparaissait exactement au moment où
        // on en a besoin — pour rejoindre à nouveau après une déconnexion.
        if let next = model.directory.next {
            Text("Prochain RDV — \(next.displayName)")
            if let link = next.meeting_url, let url = URL(string: link) {
                Link("Rejoindre la visio", destination: url)
            }
            Divider()
        }

        Button("Ouvrir bran…", systemImage: "macwindow") {
            WindowPresenter.bringToFront("library", using: openWindow)
        }
        .keyboardShortcut("o")
        // **Le seul endroit où l'état des autorisations est rafraîchi à
        // l'ouverture du menu**, et c'est ce qui rend le masquage de
        // « Bienvenue » plus bas honnête.
        //
        // `HotkeyMonitor.isTrusted` interroge le système à chaque lecture, mais
        // `permissions.canRecord` lit trois valeurs mémorisées : sans ce
        // rappel, une autorisation révoquée pendant que l'app tourne laisserait
        // l'entrée cachée alors qu'elle vient de redevenir nécessaire. Les trois
        // requêtes de `refresh()` sont des préflights TCC, sans boîte de
        // dialogue et sans coût mesurable.
        .onAppear { model.permissions.refresh() }

        Divider()

        AwakeMenu(awake: model.awake)

        Divider()

        dictationItems

        Text(model.statusSummary)

        if let failure = model.lastFailure {
            Text("⚠︎ \(failure)")
            Button("Ignorer cet avertissement") { model.lastFailure = nil }
        }

        Divider()

        if model.hasOpenSession {
            Button(model.isPaused ? "Reprendre l'enregistrement" : "Mettre en pause") {
                model.togglePause()
            }
            .keyboardShortcut("p")

            Button("Arrêter et enregistrer le fichier") {
                model.stopRecording()
            }
            .keyboardShortcut("s")
        } else if let meeting = model.pendingMeeting {
            Button("Démarrer — \(meeting.title ?? "réunion non reconnue")") {
                model.startPendingRecording()
            }
            .keyboardShortcut("r")

            Button("Pas cette fois") {
                model.dismissProposal()
            }
        } else {
            Button("Démarrer un enregistrement") {
                model.startManualRecording()
            }
            .keyboardShortcut("r")
            .disabled(model.permissions.canRecord == false)
        }

        Divider()

        // La consommation, **ici et plus dans un second élément de barre de
        // menus**. Voir `ResourceLines` pour ce que ce déménagement coûte et
        // pourquoi il a quand même été fait.
        if model.meter.showsInMenuBar {
            ResourceLines(meter: model.meter)
            Divider()
        }

        // **Présent tant qu'il reste quelque chose à faire, et absent sinon.**
        //
        // Les deux versions précédentes se sont trompées en sens inverse. La
        // première ne le montrait que si l'enregistrement était impossible :
        // quelqu'un dont l'enregistrement marchait n'avait aucun moyen de
        // découvrir la dictée ni la capture de texte. La seconde l'a rendu
        // permanent, ce qui règle la découverte mais laisse à vie, dans une
        // barre de menus déjà chargée, une ligne qui ne sert plus à rien une
        // fois l'accueil lu.
        //
        // Ce qui débloque le retrait, c'est que l'écran ait maintenant **une
        // porte qui ne se ferme jamais** : « Autorisations » vit désormais au
        // bas de la colonne, à côté de « Réglages ». L'entrée de menu redevient
        // ce qu'elle aurait toujours dû être — une alerte, pas un raccourci —
        // et elle réapparaît d'elle-même si macOS révoque une autorisation,
        // grâce au rafraîchissement posé sur « Ouvrir bran… ».
        if model.isFullyReady == false {
            Button("Bienvenue — il reste à faire…") {
                WindowPresenter.bringToFront("permissions", using: openWindow)
            }

            Divider()
        }

        Button("Quitter bran") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    /// La dictée dans le menu : **rien** tant que tout va bien.
    ///
    /// Démarrer, arrêter et annuler se font à la touche, dans cent pour cent des
    /// cas. Un menu qu'on n'ouvre jamais pour ces trois gestes n'a aucune raison
    /// de les proposer, et chaque ligne inutile éloigne celles qui comptent.
    ///
    /// Il ne reste donc que les deux situations où la touche, justement, ne
    /// répond pas : la dictée est désactivée, ou elle a échoué.
    @ViewBuilder
    private var dictationItems: some View {
        if model.dictationSettings.isEnabled == false {
            Button("Activer la dictée…") {
                WindowPresenter.bringToFront("library", using: openWindow)
            }
            Divider()
        } else if case .failed(let reason) = model.dictation.phase {
            Text("⚠︎ \(reason.summary)")
            Button("Compris") { model.dictation.acknowledgeFailure() }
            Divider()
        }
    }
}

/// **Un seul élément de barre de menus, donc deux emplacements à arbitrer.**
///
/// Cinq états veulent s'y montrer — dictée, enregistrement, réunion proposée,
/// éveil, consommation — et il y a une icône et un texte. La règle est écrite
/// une fois, ici, et elle tient en trois lignes :
///
/// 1. **L'icône porte l'état le plus urgent** : un événement court d'abord (la
///    dictée dure dix secondes, l'enregistrement une heure), une proposition
///    ensuite, un mode permanent en dernier.
/// 2. **Le texte porte une seule chose**, dans le même ordre, et retombe sur la
///    consommation au repos — l'endroit d'où elle vient.
/// 3. **Un mode permanent que l'icône ne montre pas est dit en toutes lettres**
///    par le texte. C'est ce qui empêche l'éveil de devenir invisible pendant un
///    enregistrement, c'est-à-dire exactement quand on l'a allumé.
extension AppModel {

    /// Le symbole de l'éveil, nommé parce que le libellé a besoin de savoir si
    /// c'est **lui** qui est affiché : si oui, le répéter dans le texte serait
    /// dire deux fois la même chose dans quinze points de large.
    static let awakeSymbol = "cup.and.saucer.fill"

    /// L'icône doit dire d'un coup d'œil si on enregistre — et, depuis l'éveil,
    /// si le Mac est tenu réveillé.
    var menuBarSymbol: String {
        // La dictée passe devant : elle dure quelques secondes, l'enregistrement
        // dure une heure. C'est l'événement court qui a besoin d'un retour
        // immédiat — surtout sur un écran sans encoche, où le panneau tombe en
        // pilule flottante qu'on peut manquer.
        switch dictation.phase {
        case .capturing: return "waveform.circle.fill"
        case .transcribing: return "hourglass"
        case .idle, .pasting, .failed: break
        }

        switch engine.state {
        case .recording, .finalizing: return "record.circle.fill"
        case .paused: return "pause.circle.fill"
        case .starting: return "record.circle"
        case .failed: return "exclamationmark.triangle.fill"
        case .idle: break
        }

        // La cloche avant la tasse : une proposition attend une décision et
        // s'éteindra toute seule, l'éveil est un mode qu'on a choisi et qui ne
        // bougera pas. Ce qui demande quelque chose passe devant ce qui dure.
        if pendingMeeting != nil { return "bell.badge" }
        return awake.isOn ? Self.awakeSymbol : "eye"
    }

    /// Court, mais présent : c'est ce qui rend l'élément repérable dans une
    /// barre de menus chargée — et pendant l'enregistrement, la durée est
    /// l'information qu'on cherche.
    var menuBarTitle: String {
        let base = primaryMenuBarTitle

        // L'éveil est allumé mais l'icône montre autre chose : on l'écrit.
        // « ∞ » sans limite, le décompte quand il y en a un.
        guard let mark = awake.menuBarMark, menuBarSymbol != Self.awakeSymbol else {
            return base
        }
        return "\(base) · \(mark)"
    }

    /// Ce que le texte dit quand il n'a qu'une chose à dire.
    private var primaryMenuBarTitle: String {
        switch dictation.phase {
        case .capturing: return "à l'écoute"
        case .transcribing: return "…"
        case .idle, .pasting, .failed: break
        }

        switch engine.state {
        case .recording: return elapsedDescription
        case .paused: return "‖ \(elapsedDescription)"
        case .starting, .finalizing: return "…"
        case .failed: return "bran ⚠︎"
        case .idle: break
        }

        if pendingMeeting != nil { return "Meet ?" }

        // Un décompte d'éveil passe devant la consommation : il finit, elle non.
        if let countdown = awake.countdown { return countdown }

        // Au repos, la place revient au chiffre — c'est ce que la fusion des
        // deux éléments a coûté et rendu : il n'est plus permanent, mais il est
        // là chaque fois que rien d'autre ne se passe. Éteint, on retombe sur
        // le nom, qui rend l'élément repérable.
        return meter.showsInMenuBar ? meter.label : "bran"
    }
}
