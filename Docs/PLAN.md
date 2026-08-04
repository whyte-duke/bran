> **Note (public repo).** Ce document est le plan d'origine, rédigé *avant* la
> première ligne de code. Il est conservé tel quel comme archive de la
> démarche — plusieurs de ses hypothèses ont été démenties par la mesure :
> `SCRecordingOutput` a remplacé `AVAssetWriter`, le stockage est un sidecar
> JSON et non SwiftData, et le déclenchement est devenu une proposition plutôt
> qu'un démarrage automatique. Le `README.md` décrit ce qui existe réellement.

# bran — enregistreur automatique de réunions Google Meet (macOS)

> Plan d'implémentation. Rédigé le 2026-08-04.
> Statut: prêt pour `/plan-eng-review`.

---

## 1. Problème

Tella fait déjà le travail et fonctionne. Le vrai manque n'est donc pas « enregistrer », c'est:

1. **L'automatisation** — l'enregistrement doit démarrer seul quand une réunion commence. Aujourd'hui il faut y penser, et on oublie.
2. **La possession locale** — les fichiers restent sur le Mac, sans compte, sans abonnement, sans upload.
3. **La bibliothèque** — retrouver une réunion, la relire, y attacher des notes.

Le moteur de capture est un problème résolu par le système. La valeur du projet est dans le **déclencheur** et la **bibliothèque**.

### Utilisateur

Une seule personne: le propriétaire du Mac. Pas de distribution, pas d'App Store, pas de multi-utilisateur. Cela autorise des raccourcis légitimes (signature auto-signée, pas de notarisation) et en interdit d'autres (une panne silencieuse n'est pas rattrapable par un support).

### Définition de « ça marche »

Une réunion Meet se tient. Personne ne touche à rien. À la fin, un `.mp4` lisible existe, avec l'écran, la voix des participants **et** la voix de l'utilisateur, synchronisés, et une ligne dans la bibliothèque avec le bon titre.

---

## 2. Environnement vérifié

Tout a été contrôlé sur la machine cible le 2026-08-04.

| Élément | État | Note |
|---|---|---|
| macOS | 26.5 (build 25F71) | ✅ |
| Xcode | 26.3, `/Applications/Xcode.app` | ✅ installé |
| Swift | 6.3.3 | ✅ |
| git | 2.50.1 | ✅ |
| SDK macOS | 26.5 | ✅ |
| `ScreenCaptureKit.framework` | présent dans le SDK | ✅ |
| `EventKit.framework` | présent dans le SDK | ✅ |
| `xcode-select` | pointe sur `CommandLineTools` | ⚠️ **à corriger** |

### Action préalable unique

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -license accept
xcodebuild -version   # doit afficher Xcode 26.3
```

Sans ça: pas de `#Preview`, pas de canvas, pas de build `.app`.

### API confirmées dans le SDK installé

Relevé direct dans les en-têtes de `ScreenCaptureKit.framework`:

```
SCStreamOutputTypeScreen         ← vidéo
SCStreamOutputTypeAudio          ← audio système (les participants)
SCStreamOutputTypeMicrophone     ← micro (soi-même)

SCStreamConfiguration:
  capturesAudio
  captureMicrophone
  microphoneCaptureDeviceID
  excludesCurrentProcessAudio    ← évite le larsen de sa propre app
```

**Conséquence majeure sur l'architecture:** les trois flux sortent d'**un seul `SCStream`**, horodatés par la **même horloge**. Pas d'`AVAudioEngine` séparé, pas de périphérique audio virtuel (BlackHole), pas de resynchronisation manuelle. Le risque technique n°1 du projet est éliminé par l'API elle-même.

---

## 3. Décisions déjà arrêtées

Ces points ont été tranchés lors de la revue de faisabilité. Ils ne sont pas rouverts.

| Décision | Choix | Motif |
|---|---|---|
| Stack | **SwiftUI + AppKit ponctuel** | Un langage, un binaire, TCC natif. |
| Vercel Native SDK | **écarté** | Aucune API de capture écran/audio (vérifié dans le repo, v0.8.0). `package.zig` n'émet aucune clé `NS*UsageDescription`, donc les permissions macOS sont inatteignables. |
| Détection de réunion | **titres de fenêtres** | `kCGWindowName` n'est exposé qu'avec l'autorisation Enregistrement de l'écran, déjà obligatoire. Évite la permission Automation et le code par navigateur. |
| Signal secondaire | **EventKit** | Fournit titre et participants. Enrichit, ne déclenche pas. |
| Audio | **ScreenCaptureKit seul** | Les trois flux, une horloge. BlackHole inutile. |
| Bibliothèque UI | **`NavigationSplitView`** | La sidebar macOS standard. |
| Bibliothèque de composants tierce | **aucune** | Il n'existe pas d'équivalent shadcn pour macOS et SwiftUI est déjà la couche de composants. |

---

## 4. Architecture

### Vue d'ensemble

```
┌──────────────── DÉTECTEURS (rapportent, ne décident jamais) ────────────┐
│                                                                          │
│  WindowTitleDetector            CalendarWatcher                          │
│  CGWindowListCopyWindowInfo     EventKit                                 │
│  poll 5s                        événement en cours                       │
│  → MeetWindowSignal?            → CalendarSignal?                        │
└────────────────┬─────────────────────────┬───────────────────────────────┘
                 │                         │
                 └───────────┬─────────────┘
                             ▼
                  ┌─────────────────────┐
                  │   SessionResolver   │  ◄── SEUL point de décision
                  │                     │
                  │  fenêtre + event → record (titre = event)
                  │  fenêtre seule   → record (titre = horodaté)
                  │  event seul      → RIEN (pas d'écran à filmer)
                  │  ni l'un ni l'autre → stop
                  └──────────┬──────────┘
                             │ Intent (.start(MeetingRef) | .stop | .noop)
                             ▼
                  ┌─────────────────────┐
                  │   RecordingEngine   │
                  │  machine à états    │
                  │                     │
                  │  .idle              │
                  │   └→ .starting      │
                  │       └→ .recording │
                  │           └→ .finalizing
                  │               └→ .idle
                  │  (.failed depuis n'importe où)
                  └──┬───────────────┬──┘
                     │               │
          ┌──────────┘               └──────────┐
          ▼                                     ▼
┌───────────────────┐                ┌────────────────────┐
│  OverlayWindow    │                │   CaptureSession   │
│  NSWindow         │                │   SCStream         │
│  transparent      │                │    ├ screen        │
│  ignoresMouse     │                │    ├ audio système │
│  .screenSaver lvl │                │    └ micro         │
│  bordure animée   │                │   → AVAssetWriter  │
└───────────────────┘                └─────────┬──────────┘
                                                │
                                                ▼
                                    ┌───────────────────────┐
                                    │    RecordingStore     │
                                    │  SwiftData / SQLite   │
                                    │  + sentinelle .lock   │
                                    └───────────┬───────────┘
                                                ▼
                                    ┌───────────────────────┐
                                    │      LibraryView      │
                                    │  NavigationSplitView  │
                                    └───────────────────────┘
```

### Règle d'or

Les détecteurs **rapportent des faits**. `SessionResolver` **décide**. `RecordingEngine` **exécute**.
Aucun `if meetDetected { startRecording() }` ailleurs que dans `SessionResolver`. C'est la protection contre le double enregistrement.

### Machine à états

```
                    ┌──────────────────────────────┐
                    │                              │
                    ▼                              │
                 ┌──────┐                          │
      ┌─────────►│ idle │                          │
      │          └───┬──┘                          │
      │              │ .start(ref)                 │
      │              ▼                             │
      │        ┌──────────┐                        │
      │        │ starting │──── échec ────┐        │
      │        └────┬─────┘               │        │
      │             │ stream OK           │        │
      │             ▼                     ▼        │
      │       ┌───────────┐          ┌────────┐    │
      │       │ recording │─ erreur ►│ failed │    │
      │       └─────┬─────┘          └───┬────┘    │
      │             │ .stop | veille     │         │
      │             ▼                    │         │
      │      ┌────────────┐              │         │
      └──────│ finalizing │              └─────────┘
             └────────────┘

Invariants:
  - .start reçu pendant .starting ou .recording  →  IGNORÉ (pas de doublon)
  - .stop  reçu pendant .idle                     →  IGNORÉ
  - toute sortie de .recording passe OBLIGATOIREMENT par .finalizing
  - .finalizing appelle finishWriting() puis supprime la sentinelle
```

---

## 5. Modules

| Module | Responsabilité | Testable sans écran | Dépendances système |
|---|---|---|---|
| `MeetTitleMatcher` | `String → Bool` | ✅ 100 % | aucune |
| `WindowTitleDetector` | énumère les fenêtres, filtre | partiel | CoreGraphics |
| `CalendarWatcher` | événement en cours | partiel | EventKit |
| `SessionResolver` | fusionne les signaux → `Intent` | ✅ 100 % | aucune |
| `RecordingEngine` | machine à états | ✅ 100 % (capture injectée) | aucune |
| `CaptureSession` | `SCStream` → `AVAssetWriter` | ❌ manuel | ScreenCaptureKit, AVFoundation |
| `OverlayWindow` | bordure clic-traversant | ❌ visuel | AppKit |
| `RecordingStore` | persistance + sentinelles | ✅ 90 % | SwiftData |
| `RecoveryService` | répare les fichiers orphelins | ✅ 80 % | AVFoundation |
| `LibraryView` | UI sidebar + détail + notes | `#Preview` | SwiftUI |
| `PermissionsService` | préflight TCC | partiel | CoreGraphics, EventKit |

**Cible: ~65 % de la logique testable en `swift test`, sans écran ni permission.**

Le découpage est piloté par la testabilité: `CaptureSession` est isolé derrière un protocole (`CaptureBackend`) pour que `RecordingEngine` soit testable avec un double, sans jamais toucher ScreenCaptureKit.

---

## 6. Modèle de données

```swift
@Model final class Recording {
    var id: UUID
    var fileName: String        // relatif à la racine, JAMAIS de chemin absolu
    var startedAt: Date
    var endedAt: Date?
    var durationSeconds: Double?
    var title: String           // depuis Calendar, sinon horodaté
    var meetCode: String?       // "abc-defg-hij" si extractible du titre
    var calendarEventID: String?
    var attendees: [String]
    var notes: String           // markdown libre
    var fileSizeBytes: Int64?
    var state: RecordingState   // .recording | .complete | .repaired | .corrupt | .missing
}
```

**Racine de stockage:** `~/Movies/bran/`. Un seul répertoire, configurable une fois.
Les chemins absolus ne sont jamais persistés — déplacer le dossier ne doit rien casser.

**Sentinelle:** pendant l'enregistrement, `~/Movies/bran/<id>.lock` existe. Sa présence au démarrage signifie « arrêt non propre » et déclenche `RecoveryService`.

---

## 7. Permissions et TCC

### Permissions requises — exactement deux

| Permission | Clé Info.plist | Pourquoi |
|---|---|---|
| Enregistrement de l'écran | *(aucune clé, TCC pur)* | capture + titres de fenêtres |
| Microphone | `NSMicrophoneUsageDescription` | sa propre voix |
| Calendrier | `NSCalendarsFullAccessUsageDescription` | titre et participants (facultatif) |

Pas de `NSAppleEventsUsageDescription`: l'approche par titres de fenêtres l'a éliminée.

### Le piège de la signature

L'autorisation Enregistrement de l'écran est attachée à la **signature de code**. Avec une signature adhoc, chaque rebuild change la signature et **révoque l'autorisation**.

**À faire avant la première ligne de code:**
1. Trousseau d'accès → Assistant de certification → créer un certificat auto-signé, type « Signature de code », nom `bran-dev`.
2. Dans Xcode: Signing → Team « None », Signing Certificate → `bran-dev`.
3. Bundle ID fixe: `com.opahventures.bran`. Ne jamais le changer.

### Cycle de test des permissions

```bash
tccutil reset ScreenCapture com.opahventures.bran
tccutil reset Microphone    com.opahventures.bran
tccutil reset Calendar      com.opahventures.bran
```

Remet l'état « première ouverture » en une seconde. C'est le seul moyen de tester correctement le chemin « refus », qui est un des deux gaps critiques.

### Préflight obligatoire

`CGPreflightScreenCaptureAccess()` est appelé **avant chaque démarrage**, pas seulement au lancement. Une autorisation révoquée par une mise à jour système doit produire une notification visible, jamais un enregistrement vide.

---

## 8. Phases

### Phase 0 — Préparation (~15 min, manuel)

- `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`
- Certificat `bran-dev` dans le Trousseau
- `git init` dans ce dossier

### Phase 1 — Spike capture ⚠️ **le seul vrai risque**

Un exécutable minimal: 30 secondes d'écran + audio système + micro → un `.mp4`.

**Critère de réussite, à vérifier à l'œil et à l'oreille:**
- le fichier s'ouvre dans QuickTime
- l'image est nette et fluide
- on entend les participants
- on s'entend soi-même
- **aucune dérive de synchronisation sur 30 s**

**Si cette phase échoue, tout le reste est sans objet.** Rien d'autre ne commence avant qu'elle passe.

### Phase 2 — Logique pure + tests (parallélisable)

`MeetTitleMatcher`, `SessionResolver`, `RecordingEngine`. Suite Swift Testing complète.
Aucune permission, aucun écran, `swift test` en moins d'une seconde.

### Phase 3 — Coquille app + permissions

Cible `.app`, Info.plist, `PermissionsService`, écran d'accueil des autorisations, agent en barre de menus.

### Phase 4 — Câblage détection → enregistrement

Branchement des détecteurs réels sur `SessionResolver`. Premier test en conditions réelles sur une vraie réunion.

### Phase 5 — Overlay

`NSWindow` transparente, clic-traversant, niveau `.screenSaver`, sur tous les Spaces.

### Phase 6 — Bibliothèque

`NavigationSplitView`, groupes par date, lecteur `AVKit`, notes persistées.

### Phase 7 — Robustesse ⚠️ **non négociable**

`RecoveryService`, gestion du disque plein, veille/réveil, budget de rétention.

### Dépendances

```
Phase 0
  └─► Phase 1 (spike)  ◄── barrière: rien ne continue si elle échoue
        │
        ├─► Phase 3 ─► Phase 4 ─┐
        ├─► Phase 5 ────────────┼─► Phase 7
        └─► Phase 6 ────────────┘
Phase 2 ──────────────────────────┘   (indépendante, dès le départ)
```

Phases 2, 5 et 6 ne partagent aucun module → parallélisables.
Phase 7 dépend de tout.

---

## 9. Stratégie de test

### Quatre boucles

| Boucle | Vitesse | Outil | Portée |
|---|---|---|---|
| 1 | ~1 s | `swift test` (Swift Testing) | logique pure |
| 2 | ~3 s | `#Preview` | états de vues |
| 3 | ~15 s | Cmd+R | permissions, capture réelle |
| 4 | ~2 min | scénario manuel | vraie réunion |

Règle: pousser un maximum de logique vers la boucle 1.

### Couverture visée

```
[+] MeetTitleMatcher                         → 100 %, table-driven
  ├── "Meet - abc-defg-hij"          → true
  ├── "Réunion équipe - Google Meet" → true
  ├── "Slack | #meeting"             → false   (faux positif classique)
  ├── "Google Meet" (page d'accueil) → false   (pas encore en réunion)
  ├── ""                             → false   (TCC refusée)
  └── extraction du code réunion

[+] SessionResolver                          → 100 %
  ├── fenêtre + event      → .start, titre = event
  ├── fenêtre seule        → .start, titre horodaté
  ├── event seul           → .noop
  ├── rien                 → .stop
  └── 2 fenêtres Meet      → 1 seul .start

[+] RecordingEngine                          → 100 %, backend simulé
  ├── cycle nominal complet
  ├── .start pendant .starting   → ignoré
  ├── .start pendant .recording  → ignoré
  ├── .stop pendant .idle        → ignoré
  ├── échec du stream            → .failed
  └── toute sortie passe par .finalizing

[+] RecoveryService                          → 80 %
  ├── sentinelle orpheline → réparation tentée
  ├── mp4 réparable        → .repaired
  └── mp4 irrécupérable    → .corrupt, jamais un crash

MANUEL (boucle 4) — checklist, pas d'automatisation:
  ├── audio des participants audible
  ├── audio du micro audible
  ├── synchro tenue sur 60 min
  ├── bordure clic-traversante
  └── veille/réveil pendant enregistrement
```

---

## 10. Modes de défaillance

| Défaillance | Gravité | Parade |
|---|---|---|
| Crash/veille → mp4 non finalisé | **CRITIQUE** | sentinelle `.lock` + `RecoveryService` au démarrage |
| Permission écran révoquée → enregistre du vide | **CRITIQUE** | `CGPreflightScreenCaptureAccess()` avant chaque démarrage + notification |
| Disque plein en cours | haute | contrôle d'espace avant démarrage, arrêt propre sous seuil |
| Double démarrage | haute | machine à états (invariant testé) |
| Titre persiste après la réunion | moyenne | N tics consécutifs sans signal avant l'arrêt |
| Fichier supprimé dans le Finder | basse | état `.missing`, jamais un crash |

Les deux critiques partagent la même nature: **une panne silencieuse laisse croire qu'on enregistre alors que non.** C'est le pire mode d'échec possible ici, parce qu'on ne le découvre qu'en cherchant l'enregistrement d'une réunion importante. Toute défaillance doit être bruyante.

---

## 11. Performance

| Sujet | Décision |
|---|---|
| Résolution | **1920×1080 ou 2560×1440, pas Retina natif.** Le natif 2× produit ~4 Go/h pour rien. |
| Fréquence | 30 fps. 60 est inutile pour une réunion et double le fichier. |
| Encodage | H.264 ou HEVC via VideoToolbox (matériel), ~5 % CPU. Jamais logiciel. |
| Débit cible | **~1 Go/h** |
| Poll de détection | 5 s. `CGWindowListCopyWindowInfo` coûte ~1 ms. Ne pas descendre sous 2 s. |
| Rétention | avertissement à 50 Go, ou purge au-delà de 30 jours. À trancher. |

---

## 12. Hors périmètre

| Écarté | Motif |
|---|---|
| Transcription / résumé IA | Phase ultérieure. S'ajoutera sur les fichiers, sans toucher au moteur. |
| Upload serveur | Tout reste local, par choix. |
| Windows / Linux | ScreenCaptureKit et EventKit sont macOS-only. |
| Vercel Native SDK | Aucune API de capture. Vérifié. |
| BlackHole / périphérique virtuel | ScreenCaptureKit fournit l'audio système nativement. |
| Permission Automation | Éliminée par la détection via titres de fenêtres. |
| Notarisation / App Store | Usage personnel. Signature auto-signée stable suffit. |
| Enregistrement d'une fenêtre seule | On veut tout l'écran. `SCContentFilter` le permettra plus tard sans refonte. |
| Multi-compte, multi-utilisateur | Une seule personne. |
| Zoom / Teams | Meet d'abord. `MeetTitleMatcher` est conçu extensible. |

---

## 13. Questions ouvertes

1. **Rétention** — purge automatique après N jours, ou simple alerte de volume ?
2. **Réunion sans événement calendrier** — enregistrer quand même (position actuelle du plan) ou ignorer ?
3. **Contrôle manuel** — un raccourci global pause/stop est-il nécessaire au MVP ? (`KeyboardShortcuts`, 2687 ★, activement maintenu)
4. **Démarrage au login** — `SMAppService` dès le MVP, ou lancement manuel au début ?
5. **Bordure** — statique ou pulsante ? Quelle couleur, quelle épaisseur ?

---

## 14. Dépendances externes

**Aucune pour le MVP.** Tout est Apple: SwiftUI, ScreenCaptureKit, AVFoundation, EventKit, SwiftData, AppKit.

Candidates ultérieures, toutes vérifiées actives au 2026-08:

| Package | ★ | Dernier push | Usage |
|---|---|---|---|
| `sindresorhus/KeyboardShortcuts` | 2687 | 2026-06-17 | raccourci global pause/stop |
| `sindresorhus/Defaults` | 2487 | 2026-06-23 | préférences typées |
| `pointfreeco/swift-snapshot-testing` | 4307 | 2026-07-31 | tests de rendu |
| `krzysztofzablocki/Inject` | 3469 | 2026-04-29 | hot reload |

Il n'existe pas d'équivalent shadcn pour macOS et ce n'est pas un manque: SwiftUI **est** la couche de composants. Une recherche GitHub des kits de composants macOS de plus de 300 ★ actifs depuis avril 2026 ne renvoie qu'un seul dépôt, et ce n'est pas un kit. Le plus proche récemment ([ShipSwift](https://github.com/signerlabs/ShipSwift), 2861 ★, MIT, actif) est **iOS uniquement**.

---

## 15. Prochaine étape

Lancer `/plan-eng-review` sur ce document depuis ce dossier.

Points à challenger en priorité:
- Le découpage en modules est-il « suffisamment ingénieré », ni fragile ni sur-abstrait ?
- La barrière Phase 1 est-elle au bon endroit ?
- Les deux gaps critiques sont-ils réellement couverts par les parades décrites ?
- La cible de 65 % de logique testable hors écran est-elle atteignable avec ce découpage ?
