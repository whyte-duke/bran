# L'analyseur de travail

Ce que bran doit devenir : un instrument qui répond à « qu'est-ce que j'ai fait
aujourd'hui, et à quel prix ». Pas un journal de plus.

Ce document est la conception. Il tranche, il ne recense pas les options.

---

## 1. Le point de départ, honnêtement

Le propriétaire décrit l'état actuel comme « pas du tout ça, du tout du tout ».
C'est faux à moitié, et la moitié qui existe est la partie difficile.

**Ce qui est déjà là et qui est bon.**

| Brique | Où | Ce qu'elle règle |
|---|---|---|
| Identité de voie | `Sources/BranWatch/LaneIdentity.swift` | `cwd` + branche depuis les transcriptions Claude Code, précision `.exact`. Une voie survit à un redémarrage. |
| États | `Sources/BranWatch/LaneState.swift` | `working` / `waiting` / `stale` / `abandoned` / `unknown`, avec un ordre de priorité porté par `Comparable` et non par une convention. |
| Stockage | `Sources/BranWatch/WatchEvent.swift` | Intervalles fusionnés, ~75 Ko/jour, et une durée mesurée sur `SuspendingClock` — donc la veille laisse une trace au lieu de disparaître. |
| Provenance | `WatchEvent.src` et `WatchEvent.p` | Chaque intervalle sait d'où vient son verdict et ce qu'on a le droit d'en conclure. |
| Agrégat | `Sources/BranWatch/WeekSummary.swift` | Jours, projets, parallélisme (moyenne et pic), jalons. |

Un analyseur de travail se casse sur deux choses : l'identité stable de l'unité
de travail, et une mesure de durée qui ne ment pas quand la machine dort. bran a
résolu les deux. Rize a mis des années à faire l'équivalent.

**Ce qui manque vraiment**, et c'est un manque de *lecture*, pas de mesure :

1. Aucune vue **journalière**. `WeekSpan` ne connaît que 7 j et 30 j.
2. Aucune **timeline horaire**. On sait combien, jamais quand dans la journée.
3. Aucune **catégorie**. Le regroupement se fait par dossier git, ce qui répond
   « sur quel projet » et jamais « à quoi ».
4. Aucune notion de **pause**. Voir la section 3 : c'est le blocage numéro un.
5. Le **multitâche** existe comme un chiffre dans une phrase, pas comme une
   lecture.
6. Aucun capteur **média** ni **navigateur**. Spotify, YouTube, l'onglet actif :
   rien.

---

## 2. Ce que Rize fait bien, et ce qu'il ne faut pas copier

Sept écrans analysés. Voici le tri.

### À prendre

**La timeline horaire comme objet principal du jour.** Une règle d'heures de
6:00 à 21:00, des blocs pleins pour le travail, et **une bande fine sous les
blocs** qui porte la catégorie. Deux encodages superposés sur un seul axe :
l'un dit « occupé », l'autre dit « à quoi ». C'est la seule façon de voir un
changement de contexte sans lire un tableau.

**Le chrono de pause.** « Temps depuis la dernière pause : 0:42:35 » et « ratio
pause/travail : 1 / 3,6 ». C'est exactement la question posée. Un chiffre vivant,
pas un total de fin de journée.

**Un dénominateur.** « 7 h 51 travaillées » ne veut rien dire. « 98,1 % d'une
journée de 8 h » veut dire quelque chose. Rize affiche aussi 160 % un autre jour,
sans s'excuser — et c'est ce 160 % qui est l'information utile.

**Le bac « non catégorisé », avec sa pastille d'attention.** Rize assume qu'il ne
sait pas, le montre, et le rend cliquable. C'est l'inverse de deviner en silence.
bran a déjà `src` et `p` pour porter ça.

**La suggestion IA comme proposition, jamais comme fait.** Une fiche « Time Entry
Suggestion » avec un titre, une description rédigée, et trois boutons : Accepter
(⌘↩), Rejeter (⌘⌫), Modifier (⌘⇧E). Rien n'entre dans les données sans un geste.
C'est le mécanisme exact qu'il faut pour la frontière mesuré/supposé.

**La comparaison à la période précédente.** Sur le mois : « Focus 56 %, mois
dernier 62 %, évolution ↓ 6 % ». Un pourcentage sans point de comparaison ne
change aucune décision.

**Les colonnes parallèles sur un axe d'heures commun** (Activité, Saisies,
Tâches, Projets, Clients, Sessions, Agenda). C'est la vue du multitâche, et bran
a déjà des voies : chaque voie est une colonne.

### À ne pas prendre

**Toute la facturation.** €8 573,61, taux horaire, facturable / non facturable,
approuvé / en attente. bran n'est pas un outil d'agence.

**Les tableaux d'équipe.** Rize agrège cinq personnes sur une grille jour ×
membre. Hors sujet, même en partageant l'app à un frère : deux utilisateurs
séparés, pas une équipe.

**Le violet.** Le dégradé lavande sur fond noir est une signature de marque. bran
est une application macOS native qui respecte le thème système et la couleur
d'accent choisie par l'utilisateur. `Palette` reste la source.

**Les scores non explicables.** Rize affiche « 97,3 » à côté d'un bloc de
travail, sans dire ce que c'est. Un nombre qu'on ne sait pas expliquer finit
ignoré, et `WatchEvent.why` existe précisément parce que ce projet a déjà tranché
l'inverse.

**Le journal d'activité brut** (« 18:04:33 Chrome https://twitter.com/home »).
C'est de la matière première affichée telle quelle. Utile pour déboguer, jamais
pour décider. Il ira derrière un dépliage, pas sur la page.

---

## 3. La décision qui commande tout : la pause contre la panne

**Aujourd'hui, un trou dans le journal devient `unknown`, libellé « pas
observable ».** Ce libellé est honnête sur l'ignorance de la machine et
catastrophique pour l'utilisateur : il met dans le même sac

- l'utilisateur était en pause déjeuner,
- l'écran était verrouillé,
- le Mac dormait,
- le veilleur était éteint,
- le capteur est mort sans le dire.

Tant que ces cinq cas partagent une couleur, la question « quand ai-je pris ma
dernière pause » n'a pas de réponse, et **aucune des autres fonctions demandées
ne tient** : pas de ratio pause/travail, pas de moyenne journalière honnête, pas
de détection de fin de journée.

### La règle

macOS donne gratuitement de quoi séparer les cinq. On ne devine rien, on lit :

| Signal | Source | Verdict |
|---|---|---|
| Session verrouillée | `com.apple.screenIsLocked` (`DistributedNotificationCenter`) | `away` — absent, certain |
| Écran endormi / veille | `NSWorkspace.willSleepNotification`, et l'écart `to - from ≠ d` déjà mesuré | `away` — absent, certain |
| Humain inactif > seuil, machine éveillée | `HumanFocus` mesure déjà l'inactivité clavier-souris | `idle` — pause probable |
| Veilleur éteint par l'utilisateur | `WatchSettings.isEnabled` | `off` — non mesuré, et c'est un choix |
| Rien de tout ça, et pourtant pas d'échantillon | échec du capteur | `unknown` — le seul vrai trou |

`unknown` cesse d'être un fourre-tout et redevient ce que son commentaire
d'origine promettait : **un échec de capteur, visible**.

### Ce que ça coûte

Deux cas nouveaux dans `LaneState`, ou — meilleur choix — **un type séparé**.
Une pause n'est pas l'état d'une voie de travail, c'est l'état de l'humain. Les
mettre dans la même énumération forcerait à répondre « quelle voie est en
pause », qui n'a pas de sens.

```swift
/// L'état de l'humain devant la machine, distinct de l'état d'une voie.
public enum Presence: String, Sendable, Codable, CaseIterable {
    case present    // actif, ou récemment actif
    case idle       // machine éveillée, personne aux commandes
    case away       // session verrouillée ou machine endormie : certain
    case off        // le veilleur est éteint : non mesuré, assumé
}
```

Écrit dans son propre journal d'intervalles, avec la même règle de fusion que
`WatchLedger`. Une ligne par changement de présence, quelques dizaines par jour.
Le coût de stockage est nul à l'échelle des ~75 Ko/jour existants.

**Une pause est alors un intervalle `idle` ou `away` d'au moins N minutes.** N
est un réglage, valeur par défaut 5 minutes : en dessous, c'est aller chercher un
café, pas une pause. Le seuil doit être visible dans les réglages, parce que le
ratio pause/travail en dépend directement et qu'un ratio dont on ne connaît pas
la définition ne se compare à rien.

---

## 4. Les catégories

### La règle avant la liste

**Une catégorie n'existe que si elle change une décision.** « Divers » n'en est
pas une, c'est l'aveu qu'on n'a pas su. Il est donc gardé, mais nommé « non
catégorisé » et affiché avec une pastille, comme chez Rize.

### La taxonomie

Sept, fermée. Une taxonomie ouverte se transforme en dix-neuf catégories dont
douze pèsent moins d'un pour cent, ce qu'on voit exactement sur la capture
« Work Categories » de Rize.

| Catégorie | Ce qui y tombe | La décision qu'elle sert |
|---|---|---|
| **Code** | session d'agent, éditeur, terminal, sur un dossier git connu | Est-ce que j'ai vraiment codé, ou est-ce que j'ai passé la journée autour du code ? |
| **Réunion** | un enregistrement bran en cours, Meet, Zoom | Combien la journée a-t-elle été mangée par autre chose que le travail profond ? |
| **Écriture** | dictée, éditeur de texte, documents | Le travail de rédaction est invisible sinon : il ressemble à du navigateur. |
| **Lecture** | navigateur sur documentation, PDF, transcription | Distinguer se former de se disperser. |
| **Communication** | messagerie, mail, chat | Le fractionneur numéro un d'une journée. |
| **Admin** | réglages, CRM, facturation, gestion | Le temps qu'on croit ne pas passer. |
| **Non catégorisé** | le reste, avec sa pastille | Ce qu'il faut aller corriger. |

Pas de « Personnel » : bran mesure le travail. Ce qui n'est pas du travail est
une pause (section 3), et une pause n'a pas besoin de catégorie.

### Combien de règles suffisent, avant de sortir l'IA

Il serait absurde d'appeler un modèle pour ce qu'un `switch` résout. La matière
première existe déjà dans `WatchEvent` :

- `cwd` non nul et pointant sur un dépôt git → **Code**. Cela couvre toutes les
  voies de précision `.exact` (les sessions Claude Code) et une partie des
  `.stable`.
- Un enregistrement bran ouvert sur le créneau → **Réunion**. `RecordingStore` a
  déjà les bornes exactes.
- Une entrée de dictée sur le créneau → **Écriture**. `DictationStore` aussi.
- Identifiant de paquet dans une table connue (Mail, Messages, Slack, Discord)
  → **Communication**.

**Estimation de couverture par règles seules : 60 à 75 %** d'une journée type du
propriétaire, qui passe l'essentiel de son temps dans des sessions d'agent sur
des dossiers git. Le reste est du navigateur, et c'est précisément là que le
titre de fenêtre ne suffit pas.

### Ce que l'IA fait, et ce qu'elle n'a pas le droit de faire

Elle catégorise **le résidu**, et elle rédige **le résumé quotidien**. Rien
d'autre.

Contrainte dure : **les titres de fenêtre du propriétaire contiennent des noms de
clients réels.** Il travaille sur des closings. Envoyer « ORPHEO GNB — closing »
à une API tierce est inacceptable et le resterait même si personne ne le
remarquait.

Trois conséquences, non négociables :

1. La catégorisation du résidu se fait **en local**. bran héberge déjà un modèle
   local pour la dictée (`Dictation/SpeechModelHost.swift`) : l'infrastructure de
   téléchargement, de cache et d'échec gracieux existe.
2. Le résumé quotidien rédigé est **désactivé par défaut**. S'il est activé, un
   écran dit exactement ce qui sortira de la machine, et propose l'anonymisation
   des noms propres avant envoi.
3. Aucune donnée ne part sans que l'utilisateur ait vu la charge utile une fois.

### Mesuré contre supposé, à l'écran

`WatchEvent` porte déjà `src` (`certain` / `pixels` / `aucun`) et `p` (précision
0/1/2). Ces deux champs existent pour ça.

**La règle d'affichage :**

- Une catégorie **déduite d'une règle** (dossier git, enregistrement, dictée)
  s'affiche pleine, sans marque.
- Une catégorie **proposée par le modèle** s'affiche avec un liseré interrompu et
  reste dans le bac « à confirmer ».
- Elle devient pleine dès que l'utilisateur l'accepte, et la correction est
  mémorisée par clé de voie : corriger une fois `hub.castral.fr` doit suffire
  pour toujours.

Si les deux se ressemblent, l'utilisateur cesse de faire confiance aux deux. Ce
n'est pas de la prudence, c'est la seule chose qui rend l'IA utilisable ici.

---

## 5. Le multitâche

`WeekSummary.Parallelism` calcule déjà une moyenne et un pic de voies simultanées
et l'affiche : « 1,6 voie en parallèle en moyenne, 4 au maximum ».

**Ce chiffre ne mesure pas le multitâche.** Trois sessions d'agent qui compilent
pendant que l'humain lit une documentation, ce n'est pas du multitâche : c'est du
parallélisme, et c'est exactement ce qu'on veut. Le coût cognitif est nul.

**Le multitâche est un fait humain, pas machine.** La bonne définition :

> Un **changement de contexte** est un passage de l'attention humaine d'une voie
> à une autre. Le multitâche d'une période est le nombre de changements de
> contexte par heure d'activité, et son coût est le temps passé dans des séjours
> plus courts que le seuil de reprise.

`HumanFocus` sait déjà quelle voie l'humain vient de toucher, à chaque tic. La
suite de ces valeurs *est* la suite des changements de contexte. Rien à mesurer
de neuf : il faut la conserver, ce qu'on ne fait pas aujourd'hui.

Deux chiffres à l'écran, et seulement deux :

- **Changements de contexte** : 47 aujourd'hui, soit 6,2 par heure.
- **Temps fragmenté** : 1 h 12 passées dans des séjours de moins de 5 minutes,
  c'est-à-dire du temps où l'on n'est jamais resté assez longtemps pour entrer
  dans le travail.

Le second est celui qui fait mal, et c'est celui qui manque partout ailleurs, y
compris chez Rize.

---

## 6. Les écrans

Trois portées : **Aujourd'hui**, **Semaine**, **Mois**. Le sélecteur existe déjà
(`WeekSpan`), il gagne deux valeurs.

### Aujourd'hui

C'est l'écran neuf, et c'est celui qui manque. L'ordre est tout le dessin.

```
┌──────────────────────────────────────────────────────────────────────┐
│  Vendredi 7 août                       [Aujourd'hui][Semaine][Mois]  │
│                                                                      │
│  6 h 12 de travail · 68 % d'une journée de 9 h                      │
│  Dernière pause il y a 42 min · 1 pause pour 3,6 de travail          │
│                                                                      │
│  ── LA JOURNÉE ──────────────────────────────────────────────────    │
│   6   7   8   9  10  11  12  13  14  15  16  17  18  19  20  21     │
│  ─┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬─     │
│           ███████░░████████    ▒▒▒▒▒███████████░░░███████            │
│           ▔▔▔▔▔▔▔ ▔▔▔▔▔▔▔▔    ▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔   ▔▔▔▔▔▔▔            │
│           code    code         réunion  code      écriture           │
│                                                                      │
│  ── LES VOIES ───────────────────────────────────────────────────    │
│  bran · main        ████████░░░░████████████        3 h 40           │
│  crm · feat/api     ░░░████████░░░░░░░░░░░░         1 h 50           │
│  hub.castral.fr           ██░░░░░░██                  42 min         │
│                                                                      │
│  ── LES BLOCS ───────────────────────────────────────────────────    │
│  09:12  bran · main                    Code       1 h 08   ⌇ 3       │
│  10:24  Pause                                        18 min          │
│  10:42  crm · feat/api                 Code          54 min ⌇ 11 ⚠︎  │
│  ...                                                                 │
│                                                                      │
│  ── LA RÉPARTITION ──────────────────────────────────────────────    │
│  Code       ████████████████  4 h 10   67 %                          │
│  Réunion    ████              55 min   15 %                          │
│  À confirmer ██               32 min    8 %   ●                      │
└──────────────────────────────────────────────────────────────────────┘
```

**Pourquoi cet ordre.** La phrase d'abord : elle répond seule si on ne lit rien
d'autre. La pause juste après, parce que c'est la question qui a un caractère
d'urgence — on n'agit pas sur une répartition, on agit sur « ça fait 42 minutes ».
La journée ensuite, qui est *où*. Les voies, qui sont *le multitâche* rendu
visible : trois lignes sur le même axe, et l'entrelacement se voit sans qu'on
explique rien. Les blocs enfin, qui sont le détail, avec le compteur de
changements de contexte (`⌇ 11`) et l'alerte quand le bloc est fragmenté.

La répartition est en dernier **exprès**. C'est le camembert que tout le monde
met en haut, et c'est ce qui change le moins de décisions.

### Semaine

`WeekPane` existe et sa structure est bonne. Trois ajouts, pas une réécriture :

1. L'histogramme empile désormais **les catégories**, pas les états. `worked` /
   `waiting` / `unknown` est une lecture de machine ; Code / Réunion / Écriture
   est une lecture d'humain. L'attente reste, en gris, sous la pile.
2. Une bande de **pauses** sous l'histogramme, qui montre le rythme des journées.
3. Une ligne **moyenne** : « 6 h 48 par jour ouvré, 34 h sur la semaine ».

### Mois

Nouvelle portée, structure de la semaine, plus **la comparaison à la période
précédente**, qui est la seule chose que le mois apporte et que la semaine ne
peut pas donner. Sans le « mois dernier : 62 %, évolution ↓ 6 % », la vue mois
est une vue semaine avec plus de barres.

---

## 7. Les capteurs à ajouter

Par ordre de rapport valeur / coût.

**1. Présence** (verrouillage, veille, inactivité). `DistributedNotificationCenter`
et `NSWorkspace`, aucune autorisation. C'est la section 3, et c'est le
prérequis de tout le reste.

**2. Jalons git.** `WatchEvent` porte déjà `cwd` et `branch`. Surveiller
`.git/logs/HEAD` avec un `DispatchSource` sur les dossiers **déjà connus du
journal** donne les commits et les push sans hook installé, sans interrogation
périodique, et sans jamais scanner le disque. C'est le meilleur rapport de la
liste : quelques dizaines de lignes pour poser des repères réels sur la timeline.

**3. Domaine de l'onglet actif.** Le titre de fenêtre ne donne pas le domaine, et
c'est ce qui bloque la catégorisation du navigateur. bran a **déjà** l'autorisation
Accessibilité (elle est indispensable à la dictée, voir
`Dictation/HotkeyMonitor.swift`), donc lire la barre d'adresse via `AXUIElement`
ne coûte **aucune nouvelle autorisation TCC**. L'alternative AppleScript
demanderait l'autorisation Automation, avec sa boîte de dialogue. Le choix est
tranché : AXUIElement.

**4. Média en cours.** Le framework privé `MediaRemote` est verrouillé sur les
macOS récents : ce chemin est mort, ne pas l'essayer. Reste AppleScript vers
Spotify et Musique, qui demande l'autorisation Automation. **Donc : optionnel,
désactivé par défaut, avec un écran qui explique ce que ça coûte.** La valeur est
réelle mais secondaire — savoir qu'on écoutait de la musique ne change pas une
décision, savoir qu'une vidéo YouTube tournait pendant une session de code, si.

**5. Réunions comme blocs.** bran détecte déjà Meet et enregistre. Il manque
seulement de poser l'enregistrement comme un **intervalle** sur la timeline au
lieu d'un point sur le fil des jalons. `RecordingStore` a les bornes. Coût
quasi nul, effet immédiat sur la catégorie Réunion.

---

## 8. Ce qu'on ne fait pas

- **Facturation, taux horaires, clients.** Hors périmètre. Si ça revient un jour,
  ce sera par-dessus les catégories, pas à leur place.
- **Objectifs et séries.** « 7 jours d'affilée » transforme un instrument de
  mesure en jeu, et un instrument de mesure auquel on veut plaire ment.
- **Un score de productivité unique.** Rize en affiche un sans le définir. Un
  nombre qu'on ne sait pas expliquer finit ignoré ou, pire, optimisé.
- **La synchronisation dans le nuage.** La bibliothèque est un dossier. Elle le
  reste.

---

## 9. L'ordre de bataille

Chaque étape est utilisable seule. Aucune ne dépend d'une étape qui la suit.

| # | Quoi | Fichiers | Effort |
|---|---|---|---|
| 1 | **Présence** : `Presence`, son journal, les notifications de verrouillage et de veille | `BranWatch/Presence.swift` (neuf), `Watch/WatchController.swift`, `Watch/WatchStore.swift` | M |
| 2 | **Pauses** : dériver les pauses de la présence, chrono depuis la dernière, ratio | `BranWatch/BreakSummary.swift` (neuf) | S |
| 3 | **Portée du jour** : `WeekSpan.day`, agrégat horaire | `BranWatch/WeekSummary.swift`, `WeekSpan` | S |
| 4 | **Timeline horaire** : la bande de la journée avec sa règle d'heures | `Week/DayTimeline.swift` (neuf) | M |
| 5 | **Catégories par règles** : la taxonomie, les quatre règles, le champ dans `WatchEvent` (v2) | `BranWatch/Category.swift` (neuf), `WatchEvent.swift` | M |
| 6 | **Écran Aujourd'hui** : l'assemblage des quatre blocs | `Week/DayPane.swift` (neuf) | L |
| 7 | **Changements de contexte** : conserver la suite de `HumanFocus`, les deux chiffres | `Watch/HumanFocus.swift`, `BranWatch/ContextSwitches.swift` (neuf) | M |
| 8 | **Jalons git** : `DispatchSource` sur `.git/logs/HEAD` des dossiers connus | `Watch/GitMilestones.swift` (neuf) | M |
| 9 | **Domaine de l'onglet** via `AXUIElement` | `BranWindows/`, `Watch/WindowSampler.swift` | M |
| 10 | **Mois** + comparaison à la période précédente | `WeekSummary.swift`, `Week/WeekPane.swift` | M |
| 11 | **Catégorisation du résidu en local** + bac à confirmer | `BranWatch/`, réutilise `SpeechModelHost` | L |
| 12 | **Résumé quotidien rédigé**, désactivé par défaut | — | L |

La migration du journal est portée par `WatchEvent.v`, qui existe déjà pour ça :
la lecture accepte `v: 1` (sans catégorie) et `v: 2` (avec). Un journal de six
mois reste lisible, ce que le commentaire du champ promettait.

---

## 10. Ce que ça donne, en une phrase

Aujourd'hui bran dit **combien**. Après, il dit **quand, à quoi, avec quelle
attention, et ce que ça a coûté de sauter d'une chose à l'autre**.
