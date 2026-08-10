# TODOS

Deferred work, with enough context to pick it up in three months.

---

## Notarise the app (Apple Developer Program, 99 €/year)

**What:** join the Apple Developer Program, sign with a Developer ID certificate,
and notarise the `.app` in a release script.

**Why:** bran is signed with a certificate generated locally by
`Scripts/make-signing-identity.sh`. That works perfectly on the machine that
built it. For anyone downloading a release, macOS shows a security warning, and
granting **Accessibility** — which dictation cannot work without — means clicking
through it. The README promises "anyone can download a working app"; today that
promise is thinner for dictation than for recording.

Notarising also fixes a problem that already exists: the Screen Recording grant
is bound to the code signature, so regenerating the local certificate silently
loses it.

**Pros:** clean install for everyone; TCC grants survive rebuilds; no scary
dialog.

**Cons:** 99 €/year, an Apple account approval delay, and a release script that
now depends on a network round-trip to Apple.

**Decision (2026-08-05):** deferred. Nobody else uses bran yet, no CRM upload has
completed end to end, and the app icon does not exist. Documented in the README
instead.

**Where to start:** `Scripts/build-app.sh`, the `codesign` line. Add
`--options runtime`, then `xcrun notarytool submit --wait` and `xcrun stapler
staple`.

---

## Transcribe closings locally instead of uploading audio

**What:** reuse `SpeechModelHost` to transcribe a meeting recording on the Mac,
and send the CRM **text** instead of a 50 MiB audio file.

**Why:** Parakeet is already in the app for dictation, and it runs at 67× realtime
on an M2 Pro — a one-hour closing would transcribe in about a minute. Today the
audio is extracted to AAC, uploaded to Supabase storage, and transcribed by a
paid service. Doing it locally removes a per-call cost, removes the upload
entirely, and means a client's voice never leaves the machine.

**Pros:** cheaper, faster, and strictly better for confidentiality. The audio
extraction path (`CRM/AudioExporter.swift`) is already producing 16 kHz mono.

**Cons:** the CRM's summarisation step currently consumes a transcript produced
by its own pipeline — the contract would need a "text supplied" path. Diarisation
(who said what) is lost unless `VadManager` + FluidAudio's speaker diarisation is
added, and a closing summary probably wants to know who spoke.

**Depends on:** an end-to-end CRM upload succeeding at least once, so there is a
working baseline to compare against.

**Where to start:** `SpeechModelHost.transcribe(_:language:)` already takes
`[Float]`. `DictationStore.readSamples(from:)` shows how to get there from a file.

---

## Measure whether dictation degrades AirPods playback in practice

**What:** confirm, with a real measurement, that dictating over AirPods drops
playback to 16 kHz — and how audible it is.

**Why:** the default input device is the built-in microphone because macOS
switches AirPods to HFP when their microphone is opened, taking all playback down
with it. That is documented behaviour, not something measured on this machine. If
it turns out to be inaudible on AirPods Max specifically, the default could
follow the system device instead and one setting disappears.

**Where to start:** `Sources/BranApp/Dictation/DictationSettings.swift`,
`inputDeviceUID`.

---

## Keep a week of resource samples, so the Week pane can say what bran cost

**What:** write one CPU/RAM sample per minute to a day-scoped `.jsonl`, keep
seven days, and surface the shape in `WeekPane`.

**Why:** the resource meter added on 2026-08-06 answers "what is bran doing right
now". It cannot answer "what did bran cost me this week", and constraint C10 of
the watcher design — *"un plafond CPU/énergie est un critère de succès, pas un
détail"* — has never had a measurement over time. A ceiling you estimate is not a
ceiling. `WeekPane` already exists to bring the four sources together.

**Pros:** gives C10 a real number instead of an estimate; makes a regression in
idle cost visible the week it appears rather than the month someone notices the
fan. The retention pattern is written three times already (`SnapshotRetention`,
`WatchRetention`, `RecordingStore`) — this is the fourth application of a known
mould, not a new subsystem.

**Cons:** a fourth store to maintain and migrate. One sample per minute is ~1 440
lines a day, small, but it is one more file that has to survive a day change, a
sleep, and a crash. And nobody has yet looked at a single number from the meter,
so the shape of the useful summary is a guess.

**Depends on:** the resource meter shipping first, and a week of looking at the
live number to know which summary is worth keeping.

**Where to start:** `Sources/BranApp/Watch/WatchStore.swift` — day-scoped file,
retention and `flush()` on sleep are all already written there.

---

## Merge the two window-enumeration loops once the common event layer exists

**What:** a single `WindowFeed` that enumerates visible windows once per tick,
read by both `AppModel` (Meet detection) and `WatchController` (lane sampling).

**Why:** at idle, two independent loops call `CGWindowListCopyWindowInfo` — every
5 s in `AppModel.swift:516`, every 4 s in `WatchController.swift:165`. On
2026-08-06 they were aligned to 4 s so they stop drifting against each other,
which cut ~27 enumerations a minute to ~15. It did not remove the duplicate work:
the window server is still asked twice per tick. `BranWindows` unified the *call*
(it existed in five copies); nothing has unified the *schedule*.

**Pros:** halves the idle enumeration cost, and gives one place to change the
cadence instead of two that must be kept in step by hand.

**Cons:** a shared feed is a dependency between two modules that
`AppModel.swift` documents three times as deliberately autonomous — *"la dictée,
volontairement autonome"*, *"même autonomie"*, *"le seul lien est le dossier de
destination"*. Wiring them directly buys performance with the property that keeps
this codebase at 25k lines instead of 40k.

**Depends on:** the common event layer accepted in the CEO plan of 2026-08-06
(scope decision #1). That layer is what lets both modules read the same feed
without knowing about each other — producers emit, readers subscribe. Doing the
merge before it exists means doing it the wrong way.

**Also depends on:** a measured number. The resource meter shipping in the same
tranche is the instrument; take an idle baseline before and after so the change is
justified by a delta rather than by intuition.

**Where to start:** `Sources/BranWindows/` — the shared enumeration API is
already there. The missing piece is a scheduler in front of it, not a new call.

---

## Give Design.swift a width scale, or decide it should not have one

**What:** decide whether component and sheet widths belong in `Design.swift`
alongside `Space`, `Radius` and `Type`, and if so, add the scale.

**Why:** migrating the views to the design tokens on 2026-08-06 closed three
missing typographic steps but exposed a fourth gap that is still open. `Space` is
a spacing scale; widths are a different decision and have no home. What exists
today, decided one call site at a time:

```
  BookingPickerSheet          680 × 620
  VocabularySheet             560 × 480
  sidebar column              200 / 224 / 280   (min / ideal / max)
  download ProgressView       90
  HotkeyField                 minWidth 130
```

Five widths, five independent decisions, no rule connecting them. The two sheets
in particular are the same kind of object at two different sizes, and nothing
says which is right.

**Pros:** the two sheets stop disagreeing, and the next sheet has an answer
before someone has to invent one. It is also the last category of literal number
left in the views after the migration — `Design.swift` opens on "a view contains
no number", and widths are the remaining exception.

**Cons:** a scale invented from five samples is a guess wearing a token's
clothes, which is worse than five honest literals. Component widths are also
genuinely content-driven in a way spacing is not: `HotkeyField`'s 130 exists
because "⌃⌥⌘Space" has to fit, not because 130 is a good number.

**Depends on:** nothing technically. It needs a judgement call, and probably one
more sheet before there is enough evidence to generalise from.

**Where to start:** the `TODO(design)` comments left in place by the migration —
`LibraryView.swift`, `CRM/BookingPickerSheet.swift`,
`Dictation/DictationSettingsSection.swift`. Each one names the width it wanted
and why the existing scale did not fit.

---

## Stop bran opening a window at login

**What:** distinguish "launched by the user" from "launched at login", and only
present the main window in the first case.

**Why:** `BranApp.swift` declares the library window
`.defaultLaunchBehavior(.presented)`. That exists for a good reason, fixed in
commit `558e42c`: an app whose only entry point is a menu bar item has no usable
first launch, because nothing announces the menu bar item. But the flag does not
distinguish a deliberate launch from a login launch. So someone with "launch at
login" enabled now gets a bran window in their face every time they log in.

This was masked until 2026-08-06, when `LSUIElement` flipped to false. As an
agent, the app had no Dock presence and the behaviour was less visible. It is
visible now.

**Pros:** removes the one thing that would make someone turn launch-at-login back
off. Login is exactly the moment bran should be invisible and just start
watching — the whole product promise is "the user never opens bran".

**Cons:** there is no clean public API for "was I launched at login". The
candidates are all somewhat indirect: `NSApplication.delegate`'s launch
notification `userInfo`, checking whether the process was started by `launchd`
via the parent PID, or having `SMAppService` write a marker. Each needs testing
across a real logout/login cycle, which is slow to iterate on.

**Depends on:** nothing. But it needs a real login cycle to verify, so it is not
a change that can be checked from a build alone.

**Where to start:** `Sources/BranApp/BranApp.swift`, the
`.defaultLaunchBehavior(.presented)` on the `library` window, and
`Sources/BranApp/LoginItemService.swift`, whose doc comment now names this as the
open question.

---

## Persist the day summary before retention eats the history

**What:** write one immutable per-day summary — a few hundred bytes: attributed
work, machine time, waiting, breaks, context switches, top projects — at the day
rollover, in a file the retention policy never purges.

**Why:** the month view can show 30 days, but it cannot show *last* month next to
this one, and that comparison is the only thing a month view adds over a week
view. `WatchRetention` deletes the detail at 30 days by default, so the trend can
never exist. Every day that passes without this is a day of history that cannot
be recovered later.

**Pros:** unlocks "Focus 56%, last month 62%, change ↓6%", which is what makes a
month view worth opening. Cheap: measured at 257 bytes per journal line today, a
rolled summary is smaller than a single day's raw log.

**Cons:** the summary's shape depends on decisions not yet made — categories in
particular. Writing it too early means either migrating it or carrying a version
that answers a question nobody asks any more.

**Depends on:** the category taxonomy (`Docs/ANALYSEUR.md` section 4), because a
summary without categories would need rewriting the day they land.

**Where to start:** `Sources/BranApp/Watch/WatchController.swift`, the day-change
branch in `tick()` — it already flushes, reloads and purges there.

---

## Read the active tab's domain through AXUIElement

**What:** read the frontmost browser window's address bar via the accessibility
API, and put the domain in `WatchEvent` so a browser lane is identified by site
rather than by window title.

**Why:** measured on the real journal, the git rule categorises 38% of tracked
time — 45 lines out of 536 carry a `cwd`. Almost all the rest is a browser, and a
window title does not give a domain: "Inbox — unread" could be work or not, and
`hub.castral.fr` is indistinguishable from `youtube.com` once the title is
stripped. Without the domain, category rules cannot cover the majority of the
day, and the AI would be asked to guess from exactly the signal that is missing.

bran already holds the Accessibility permission — dictation cannot work without
it (`Dictation/HotkeyMonitor.swift`, `isTrusted`). So this costs **no new TCC
prompt**. The AppleScript alternative would need the Automation permission, with
its own dialog.

**Pros:** unblocks categories for the majority of tracked time. No new
permission. Also fixes lane identity for browser tabs, which is currently the
`.fragile` precision case.

**Cons:** the traversal has to be written from scratch. `LaneReturn.accessibleWindows`
reads `kAXWindowsAttribute` and titles, with no recursive descent and no
`AXWebArea` handling; only `AXUIElementSetMessagingTimeout` is reusable. Each
browser exposes its address bar differently, and Safari, Chrome and Arc will each
need a probe.

**Depends on:** nothing technically. But it should land before the category
rules, otherwise those rules get written against a signal that is about to
change.

**Where to start:** `Sources/BranWindows/`, alongside `LaneReturn.swift`, and
`Sources/BranApp/Watch/WindowSampler.swift` where the identity is built.

---

## Offer a "do not log window titles" setting

**What:** a switch in the Veille settings that stops `WatchEvent.name` from being
written to disk, keeping only the lane key and the state.

**Why:** the watcher journal writes raw window titles. Counted on two days of the
owner's real journal: 165 distinct names, including three PDFs named after
individuals (internship agreements), several search queries, and a fragment of an
OAuth URL. `WatchRetention` exists precisely because of this and its comment says
so — "you can delete a folder, you cannot un-write it" — but deleting after 30
days is not the same as never writing.

The presence journal added in this branch needs no such switch: it carries four
fields, three of which are instants, and no title at all.

**Pros:** makes the journal safe to keep for a year, which is what a month-over-
month comparison wants. Costs one `if` at the write site.

**Cons:** the week view groups projects by folder, and falls back to the
application when there is no folder — both survive. But the lane list in Veille
becomes unreadable, since it names lanes by title. The setting would have to say
plainly that it trades the Veille section for privacy.

**Where to start:** `Sources/BranApp/Watch/WatchStore.swift`, the `append`
method, and `Sources/BranApp/Watch/WatchSettings.swift`, which has no privacy
setting today.

---

## Extract the shared *row* from Dictées and Captures

> **Revised 2026-08-10 by the clipboard eng review.** This entry used to cover
> "the duplication between Dictées and Captures" as one thing. It is two things,
> and only one of them is still open.
>
> The **store** half is being closed: `SnapshotStore.swift` (250 lines) and
> `DictationStore.swift` (280 lines) are the same store copied — sixteen methods,
> same order, same names modulo the payload word. That is 530 duplicated lines,
> five times heavier than the row, and nobody had noticed it. The clipboard work
> extracts a generic `ContentStore` into `BranCore`, which also gives those lines
> their first test: `grep -rln "SnapshotStore|DictationStore|RecordingStore" Tests/`
> returns nothing today, because `BranApp` is an `.executableTarget` with no test
> target (`Package.swift:53`, `:80-83`).
>
> The **row** half below is unchanged and still open. Note that the clipboard row
> may not be the third caller this entry was waiting for: it carries a thumbnail
> and a source app, where a dictation carries a duration and a word count. Decide
> on the evidence, not on the count of callers.

**What:** the two panes carry the same figures — a card header, an action strip,
a footer of facts — written twice, with the same unnamed sub-scale of spacings
(5, 6, 7, 9, 11 points) in both.

**Why:** those ten values are the last ones in the app that sit off the 4-point
scale. Renaming them onto it would shift layouts by one to three points with no
visible gain and a real regression risk, because the two panes are already
internally consistent with each other. The number is not the problem; the
duplication is. Extract the row and the sub-scale disappears with it, replaced by
whatever the shared component decides once.

**Pros:** closes the design-system adoption gap for real instead of cosmetically.
Any later change to a card row — a hover state, a keyboard affordance, a new
action — lands in both sections at once instead of drifting.

**Cons:** the two rows are similar, not identical: a dictation has a duration and
a word count, a snippet has a region count and a confidence. A component that
takes eight optional parameters is worse than two honest copies, so the
extraction has to find the actual shared shape rather than union the two.

**Depends on:** nothing. But it is worth doing right after a third section needs
the same row, because two callers is the minimum for knowing what to share and
three is where the shape becomes obvious.

**Where to start:** `Sources/BranApp/Dictation/DictationPane.swift:234` and
`Sources/BranApp/Snapshot/SnapshotPane.swift:210` — the same `VStack(spacing: 9)`
in both, with the same children.

---

## Decide whether RecordingStore joins the generic ContentStore

**What:** `RecordingStore.swift` is the fourth `@MainActor` store, and the
clipboard eng review of 2026-08-10 deliberately left it **outside** the generic
`ContentStore` extracted from `SnapshotStore` and `DictationStore`. Write down
the condition under which it should join, so the next session does not redo the
reasoning from scratch.

**Why it was left out.** It is the same *idea* — a folder is the library, a
`.json` sidecar next to each file — but not the same *shape*:

| | Snapshot / Dictation / Clipboard | RecordingStore |
|---|---|---|
| retention | a policy, purges the blob and keeps the text | none — a recording is never auto-deleted |
| identity | `UUID` in the entry | `UUID` in the *file name*, parsed back |
| scan | list the folder, read sidecars | `nonisolated static func scan` (`:62`), async, also probes durations with AVFoundation |
| lifecycle | save once, mutate rarely | `beginSession` → `completeSession` → `completeProcessing`, a real state machine |

A generic that swallowed all four would need retention to be optional, identity
to be pluggable, and scanning to be overridable. Three escape hatches for one
caller is how a generic becomes worse than the duplication it replaced.

**Pros of doing it later:** one store instead of two shapes; `RecordingStore`
gets the tests it has never had.
**Cons:** the recording lifecycle is the only path in bran where losing data
means losing a client meeting. It is the worst possible place to discover that a
generic leaked.

**The condition to revisit:** if a *fifth* store appears and it looks like
`RecordingStore` rather than like `SnapshotStore`, then the recording shape is a
real second family and deserves its own generic. Until then, one honest copy.

**Where to start:** `Sources/BranCore/ContentStore.swift` once it exists, and
`Sources/BranApp/RecordingStore.swift:62` for the scan that would have to become
a customisation point.

---

## Move the content stores off the MainActor

**What:** `SnapshotStore`, `DictationStore` and the extracted `ContentStore` are
`@MainActor` (`SnapshotStore.swift:21`, `DictationStore.swift:20`). Make the
generic an `actor` and migrate all callers.

**Why:** this is not a theoretical improvement, it is an existing defect. A PNG
is written on the main thread at `SnapshotStore.swift:236` (`writePNG`) and a WAV
at `DictationStore.swift:221` (`writeWave`). A full-screen capture at 2880×2416
measures 150–270 KB as a text region but a whole screen is megabytes, and the
interface has nothing to do during that write except wait. Nobody has complained,
which most likely means nobody has looked — there is no measurement of main-thread
stalls anywhere in the project.

**Decided against, for now (2026-08-10, D4 of the clipboard eng review):** the
clipboard work already carries one structural refactor, the `ContentStore`
extraction. Stacking a concurrency migration on top breaks the rule the whole
plan is built on — never a structural and a behavioural change at the same time.
The clipboard therefore stays `@MainActor` like its siblings and offloads only
its heavy writes through `nonisolated static` funcs, which is the pattern already
in place at `RecordingStore.swift:62`.

**Pros:** no disk write can ever stall the interface again, for any of the three
libraries; the pattern stops being decided per call site.
**Cons:** a concurrency refactor on code that has no tests until the
`ContentStore` extraction gives it some. Doing it before those tests exist means
changing untested behaviour twice.

**Depends on:** the `ContentStore` extraction landing first, with its regression
tests. That is what makes this migration verifiable instead of hopeful.

**Where to start:** measure before deciding. A main-thread stall has no number in
this project yet — take one with `ResourceProbe` or Instruments on a full-screen
capture, and only migrate if the number is visible to a human.
