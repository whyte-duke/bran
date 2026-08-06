# bran

**Meeting recorder, dictation and on-screen text capture for macOS.** Free, open
source, fully local. No account, no subscription, no upload.

Three things, all of them computed on your Mac:

| | | |
|---|---|---|
| **Record** | a Meet window appears → bran offers → one `.mp4` | screen + mic |
| **Dictate** | hold ⌘ right → speak → the text is pasted where your cursor was | Parakeet TDT 0.6B v3 |
| **Read the screen** | ⌘⇧2 → drag a rectangle → the text is in your clipboard | macOS Vision |

Nothing is uploaded. The dictation model runs on the Neural Engine; the text
recognition ships with macOS. Neither one needs a network.

> The interesting problem here was never *recording* — the system does that. It
> was the **trigger** and the **library**: starting without being asked, and
> finding the meeting again three weeks later.

---

## What it does

- **Detects Google Meet automatically** by reading window titles — no browser
  extension, no Automation permission, no per-browser code.
- **Never records without asking.** A meeting appearing is a *proposal*, not a
  trigger. Joining a call ten minutes before your client arrives is the normal
  case, and that conversation has no business being in a file.
- **One file, three sources.** Screen, system audio and microphone, mixed by
  ScreenCaptureKit into a single track. No virtual audio device, no BlackHole,
  no manual sync.
- **Pause and resume.** ScreenCaptureKit has no pause, so bran closes the file
  and opens a new segment. Segments are merged back into one clean file at the
  end.
- **Merge and compress in a single encoding pass.** Merging then compressing
  would encode twice, and every lossy pass eats the on-screen text you actually
  want to read back.
- **Survives a crash.** The file is written by `replayd`, a system daemon
  outside bran's process. Force-quitting bran mid-recording leaves a complete,
  playable file — measured, not assumed.
- **A library that is just a folder.** Metadata lives in a `.json` next to each
  `.mp4`. Move the folder, copy it to another Mac, restore it from a backup —
  everything still works.

Optionally, bran can push the audio of a call to a CRM for transcription and
summarisation. That part is specific to one deployment and entirely opt-in — see
[CRM integration](#optional-crm-integration).

---

## Local dictation

Hold a key, talk, and the text appears where your cursor was. Everything runs on
your Mac — no account, no API key, nothing leaves the machine.

- **NVIDIA Parakeet TDT 0.6B v3**, running on the Neural Engine through
  [FluidAudio](https://github.com/FluidInference/FluidAudio) (Apache 2.0).
  25 European languages, and you can pin one so it stops half-translating you.
- **Measured on a MacBook Pro M2 Pro:** 483 MB on disk, 42 MB of process
  footprint, **67× realtime** — 4 minutes of speech transcribed in ~3.6 s.
  Run `swift run BranSpike speech` to get the number on your own machine
  instead of taking ours.
- **No chunking.** At 67× realtime, splitting audio while you speak buys nothing
  on paste latency and costs correctness: sliding windows *revise* their output,
  so you would watch words change under your cursor.
- **The model loads while you talk.** Loading starts on key-down, in parallel
  with capture, so a cold start is hidden by the first two seconds of speech.
- **Right Command by default**, configurable, hold-to-talk or press-to-toggle.
  Escape cancels.
- **Notch overlay** on MacBooks that have one, a floating pill everywhere else —
  because the feature is useless if it goes silent the moment you plug in a
  monitor.
- **A correction dictionary.** Whisper-class models mangle your company and
  client names. Twenty entries fixes most of it.
- **History is a folder.** Text is kept forever, audio is purged after a week
  (configurable). Once the audio is gone, retry is *disabled with a reason*
  rather than failing.

Dictation needs the **Accessibility** permission — macOS requires it both to read
a global hotkey and to paste. Because bran is signed with a certificate you
generate locally, macOS will warn you before you can grant it. That is the
trade-off of an unnotarised app; see [Permissions](#permissions).

---

## On-screen text capture

Press ⌘⇧2 (configurable). The **system crosshair** opens — the one from ⌘⇧4,
with its magnifier, its live dimensions, space to move the selection, space
again for window mode, escape to cancel. Drag a rectangle, and its text is in
your clipboard.

Using `screencapture -i` rather than drawing our own selection UI is deliberate.
That crosshair is twenty years of muscle memory; a reimplementation missing the
magnifier, or with a slightly different escape, is noticed immediately.

**No new permission.** It reuses the Screen Recording grant already needed for
meetings.

### What it actually reads

Measured on real screenshots taken on the author's Mac, macOS 26.5, M2 Pro:

| | character error | latency |
|---|---|---|
| French prose | **0.7 %** | 349 ms |
| Swift source | **0.7 %** | 188 ms |
| terminal output (`ls -la`, permissions) | **4.5 %** | 256 ms |
| full screen, 2880×2416, 60 lines | — | 973 ms |

Zero download, zero resident memory, 30 languages.

Two pieces carry most of that, and both live in `Sources/BranVision/` where they
are tested without a screen:

**`TextAssembler`** — Vision returns *regions*, not lines. On `ls -la` output
every column is its own observation, and stacking them vertically produces text
that was never on screen. Grouping by baseline then sorting by x took a real
terminal capture from **34.6 % error to 3.7 %**. The same geometry restores code
indentation exactly, from `boundingBox.origin.x ÷ median character width`.

**`CharacterFixer`** — a bullet read in place of a period accounted for 70 % of
the remaining errors on Swift. Nine substitutions, each for a character that has
no business existing in code, take it from **2.4 % to 0.7 %**. Locked to
monospaced mode: in prose, `—` and `'` are correct spelling.

It deliberately does **not** fix `ls` → `1s` or `wc -l` → `wc -1`, which are the
errors that remain. A correction that guesses wrong produces text that is wrong
but plausible — and you would paste it without noticing. A visible error beats an
invisible one, especially in code you are about to run.

### Reading the same capture twice

The image is kept for 7 days (configurable, 0 disables it). Re-reading in the
*other* layout mode is the retry that matters: terminal output read as prose
loses its columns, and that is one click to repair. Re-running the same mode on a
deterministic engine would return the same text.

Real captures of text regions measure 150–270 KB each, so ten a day for a month
is about 75 MB.

### Why not a local vision model

Considered, and measured against. `MLXVLM` pulls **15 packages** — including a
full networking stack — where bran currently has one dependency. The download
path also failed silently in testing: 30 minutes, 2.6 GB received, 14 MB
persisted, no error. If that fails on a fast connection in development, it fails
for users.

The engine sits behind an `OCREngine` protocol, so a local model can be added if
a real case demands it. Handwriting, photographed text and languages outside the
supported 30 are where it would win.

---

## Naming the work behind an SSH session

The watcher tracks each parallel session as a **lane**. A Claude Code session
declares its own identity — the transcript carries the working directory and the
git branch — so that lane is exact and needs nothing from you. A terminal does
not: all bran has is the window title.

And a terminal title names the **machine**, never the work:

```
bran - root@kvm4: ~ - ssh castral-azure - 244x67
```

Everything in that line is about where you are, nothing about what you are
doing. Run three unrelated tasks on the same VM and they collapse into one lane,
which is exactly the situation the watcher exists to untangle.

bran does not guess its way out of this. Guessing produces lanes that merge and
split on their own, which is worse than one honest lane. The fix is to ask the
remote shell to write the truth, and that is opt-in.

### The snippet

Paste this into `~/.zshrc` **on the remote machine**, then open a new shell:

```zsh
# --- bran: name the work, not the machine ---------------------------------
# Writes "<folder> · <branch>" into the terminal title. Optional, reversible,
# and it never overwrites a title that something else already owns.
bran_title() {
  # tmux drives the title itself. Fighting it makes the lane flicker between
  # two identities, which is worse than the imprecise title we started from.
  [[ -n "$TMUX" ]] && return
  # The conventional opt-out. Anyone who sets terminal titles on purpose —
  # oh-my-zsh users especially — already sets this, and means it.
  [[ "$DISABLE_AUTO_TITLE" == true ]] && return
  # A per-shell escape hatch that needs no edit to this file.
  [[ -n "$BRAN_NO_TITLE" ]] && return

  local folder=${PWD:t}
  local branch
  branch=$(command git symbolic-ref --quiet --short HEAD 2>/dev/null)

  if [[ -n "$branch" ]]; then
    print -n "\e]0;${folder} · ${branch}\a"
  else
    print -n "\e]0;${folder}\a"
  fi
}
autoload -Uz add-zsh-hook
add-zsh-hook precmd bran_title
# --- end bran -------------------------------------------------------------
```

It writes one escape sequence per prompt and nothing else. No file is created,
no package installed, no daemon left running. On a detached HEAD, or outside a
git repository, the title falls back to the folder alone.

For bash, the same escape sequence from `PROMPT_COMMAND` does the same job — the
guards matter more than the shell.

### Turning it off

Three ways, in increasing permanence:

| | |
|---|---|
| This shell only | `add-zsh-hook -d precmd bran_title` |
| Every new shell | `export BRAN_NO_TITLE=1` in `~/.zshrc` |
| For good | delete the block between the two comment markers |

Nothing else needs undoing.

### What it actually changes

| | Without | With |
|---|---|---|
| Lane name | `root@kvm4` | `scanner · feat/ocr` |
| Lane precision | `.fragile` | `.stable` |
| Three tasks on one VM | one lane | three lanes |
| Switching branch | same lane | a new lane, correctly |
| Clicking the lane | brings up *a* terminal window | brings up the right one |

**You do not need this to survive a resize.** The `- 244x67` suffix is the
window size in columns by rows, and it used to fabricate a fresh lane every time
you dragged a corner or changed the font. bran now strips it on its own, along
with tmux's `[0]` index and activity flags, iTerm2's window number, and the
`— Edited` marker of document apps. The snippet buys precision, not stability —
see `Sources/BranWatch/TitleNoise.swift`, where each rule names the emulator it
targets and says why that part moves on its own.

---

## First launch

The welcome screen is organised by **what bran can do**, not by which system
checkbox it wants — and each capability says what it still needs:

```
bran
Trois choses, entièrement sur ce Mac.

⏺  Enregistrer vos réunions                        [Autoriser l'écran]
   bran repère une fenêtre Meet et propose.        [Autoriser le micro]
   ○ Écran et micro requis

🎙 Dicter dans n'importe quelle application         [Autoriser]
   ⌘ droite → vous parlez → le texte est collé.    [Télécharger le modèle]
   ○ Modèle à télécharger — 483 Mo, une seule fois

⧉  Récupérer le texte affiché à l'écran
   ⌘⇧2 → un rectangle → dans le presse-papiers.
   ✓ Aucune autorisation supplémentaire
```

The dictation model is downloaded from here, with its size stated before you
click and a progress bar in place. A feature whose engine is not installed does
not exist for someone who just opened the app, and they will not go looking for
it in a settings screen they do not know to open.

The third card is the one that matters most: text capture reuses the Screen
Recording grant already needed for meetings, so it is available the moment
recording is.

---

## Requirements

| | |
|---|---|
| macOS | 15 (Sequoia) or later — `SCRecordingOutput` does not exist before |
| Xcode | 16 or later (for the Swift 6.2 toolchain) |
| Cost | none |

---

## Install

```bash
git clone https://github.com/whyte-duke/bran.git
cd bran

zsh Scripts/make-signing-identity.sh   # one-off, creates a local signing certificate
zsh Scripts/build-app.sh               # builds, signs, installs to ~/Applications
open ~/Applications/bran.app
```

That's it. No Xcode project to open, no dependencies to resolve — bran uses only
Apple frameworks.

### Why the signing script

macOS ties the **Screen Recording** permission to an app's *code signature*.
With an ad-hoc signature, every rebuild changes that signature and silently
revokes the permission — which means bran would record a black screen without
telling you.

`Scripts/make-signing-identity.sh` creates a self-signed code-signing certificate
valid for ten years in your login keychain. It is idempotent: run it twice and
the second run does nothing. It is a script rather than a note saying "recreate
it in Keychain Access" precisely because the signature must be reproducible.

This certificate is for local development. **It does not let you distribute the
app** — Gatekeeper will block it on someone else's Mac. Building from source is
the supported path.

### Permissions

On first launch bran asks for:

| Permission | Required | Why |
|---|---|---|
| Screen Recording | yes | capture, on-screen text, and the window titles used for detection |
| Microphone | yes | your own voice, and dictation |
| Notifications | recommended | the "record this meeting?" prompt |
| Accessibility | dictation and text capture | reading the global hotkeys, and pasting |
| Calendar | no | names the recording after the calendar event |

macOS only applies the Screen Recording and Accessibility grants at the **next
process start** — quit and relaunch bran after granting them.

**What the keyboard access is used for.** The event tap is installed in
listen-only mode and inspects nothing but modifier flags and the two key codes
you bound. It never swallows an event, never logs a keystroke, and is only
installed when you turn dictation on. `Sources/BranApp/Dictation/HotkeyMonitor.swift`
is 200 lines — read it.

**One thing macOS will do to you.** When the cursor is in a password field, or
when Terminal's *Secure Keyboard Entry* is switched on, macOS disables every
event tap system-wide. Your hotkey stops responding and nothing explains why.
bran detects this and names the likely culprit instead of looking broken.

---

## How it works

```
┌─────────── detectors (report facts, never decide) ────────────┐
│  WindowTitleDetector                                          │
│  CGWindowListCopyWindowInfo                                   │
└───────────────────┬───────────────────────────────────────────┘
                    ▼
          ┌───────────────────┐
          │  SessionResolver  │  ◄── the only place that decides
          └─────────┬─────────┘
                    │  Intent (.start | .stop | .noop)
                    ▼
          ┌───────────────────┐        ┌──────────────────┐
          │  RecordingEngine  │───────►│  CaptureSession  │
          │  state machine    │        │  SCStream        │
          └─────────┬─────────┘        └──────────────────┘
                    ▼
       segments ──► PostProcessor ──► one compressed .mp4 ──► library
```

**Detectors report. `SessionResolver` decides. `RecordingEngine` executes.**
There is no `if meetDetected { startRecording() }` anywhere else — that
bottleneck is what makes double-recording impossible rather than merely unlikely.

The state machine guarantees, and tests prove:

- `.start` during `.starting`, `.recording` or `.paused` is ignored
- `.stop` during `.idle` is ignored
- every exit from `.recording` goes through `.finalizing`
- failures are loud: `.failed` with a reason, never a silent return to idle

### Things worth knowing if you build on this

Findings from building it, each verified on a real machine:

- **`stopCapture()` returns before the file exists.** `replayd` finalises the
  container asynchronously; you must wait for
  `recordingOutputDidFinishRecording`. Skipping this reports success on a file
  that isn't there.
- **`SCStream` and `SCRecordingOutput` hold their delegate weakly.** Let it go
  out of scope and no callback ever fires — including the finalisation one.
- **Never call `removeRecordingOutput()` before `stopCapture()`.** `stopCapture`
  removes it itself; doing both triggers a double `exportAndInvalidate` on the
  same asset writer, and the file is never written.
- **`SCRecordingOutput` exposes no bitrate control** — only codec and container.
  If you need a target file size, you must re-encode afterwards.
- **System audio and microphone arrive in different formats.** System audio uses
  the stream configuration's sample rate; the microphone uses the device's
  native format. `SCRecordingOutput` mixes them for you. An `AVAssetWriter`
  pipeline would leave you to do it by hand.
- **File size is content-dependent, wildly.** ScreenCaptureKit only delivers a
  frame when the screen changes. The same setting measured 0.23 GB/h on a static
  screen and 6 GB/h on a live video call.
- **macOS 15+ periodically re-asks for screen recording consent** for apps that
  capture without going through `SCContentSharingPicker`. There is nothing you
  can do about it in-app.

### What bran costs, and how you can check

A background app that watches your screen owes you a number. bran shows one: a
second menu bar item, separate from bran's own, reading `processor·memory` as
percentages. Open it and it names whatever is currently running — the dictation
model loading, the watcher sampling, a recording in progress — under the heading
"En ce moment", because those are simultaneous states and not a measured cause.

**Baseline, MacBook Pro M2 Pro (12 cores, 8P + 4E, 16 GB), bran idle**: watcher
on, nothing recording, no dictation, Parakeet on disk but not in memory. Sampled
every 2 s for 5 minutes with the same kernel counters the meter itself reads —
`proc_pid_rusage` for CPU, `phys_footprint` for memory.

| | reading | share of the machine |
|---|---|---|
| CPU | 0.01 % median, 0.05 % mean, 0.13 % peak | 0.001 % of 12 cores |
| Memory | 68.7 MB | 0.40 % of 16 GB |

So the menu bar item reads `<1·<1` at rest, and the meter's own loop — two
system calls every 2 s, off the main thread — measured **0.0001 % of one core**,
pushing one label update in 120 ticks. Idle really is idle. Constraint C10 says a
CPU/energy ceiling is a success criterion rather than a detail; this is the first
time it has had an instrument, and that table is its first entry.

Two conventions to know before comparing against anything else:

- **100 % = one core**, the Activity Monitor scale. On this machine the maximum
  is 1200 %, and `104 %` means one core and change, not a saturated laptop. The
  normalised reading sits right next to it in the dropdown so the big number is
  never read alone.
- **Memory is `phys_footprint`, not `resident_size`.** They are two different
  columns of Activity Monitor — "Memory" and "Real Memory" — and they disagree:
  68.7 MB against 74.4 MB for the same process at the same instant. The meter
  shows the one you would be comparing against.

---

## Development

```bash
swift build          # builds everything
swift test           # 322 tests, runs in about a millisecond
open Package.swift   # opens in Xcode, with SwiftUI previews
```

The package is split so that the interesting logic is testable without a screen,
a permission or a display server:

| Target | Contains |
|---|---|
| `BranCore` | pure logic — title matching, session resolution, state machine, the CPU/memory arithmetic |
| `BranSpeech` | pure logic for dictation — state machine, retention, corrections |
| `BranVision` | pure logic for on-screen text — line assembly, substitutions |
| `BranWatch` | pure logic for the watcher — lane identity, states, resolver, sampling cadence, motion arithmetic |
| `BranWindows` | the one deliberate exception — window enumeration and grayscale thumbnails, shared by both executables |
| `BranApp` | the app — capture, storage, SwiftUI |
| `BranSpike` | command-line tools used to de-risk the capture engine |

`BranSpike` is kept in the repository on purpose. Run it from a terminal, where
it inherits the terminal's TCC permissions:

```bash
swift run BranSpike titles                 # log window titles + match verdicts
swift run BranSpike record --duration 30   # capture, then report on the file
swift run BranSpike inspect file.mp4       # tracks, duration, bitrate
```

`BranSpike inspect` answers the question no amount of reasoning can: does the
resulting file have **one** audio track (mixed) or two (in which case QuickTime
plays only the first, and you never hear yourself)?

---

## Optional CRM integration

bran can extract the audio of a recording and push it to an HTTP endpoint for
transcription and summarisation. This targets one specific CRM and is **off
unless you configure it**. Nothing in the recording, compression or library
features depends on it.

If you want to point it at your own backend, the client is a single file —
`Sources/BranApp/CRM/CRMClient.swift` — and implements six calls: list targets,
open an upload, `PUT` the bytes to a signed URL, start processing, poll status,
retry.

Two design points that generalise:

- The API token lives in the **Keychain**, never in `UserDefaults` or a `.env`
  file. A token in preferences ends up in plain text in a `.plist` readable by
  any process in your session, and in every Time Machine backup.
- Audio is exported to **AAC mono, 16 kHz, 64 kbit/s** — roughly 29 MB per hour.
  Speech transcription runs at 16 kHz; going below that ceiling costs nothing in
  accuracy and keeps files under typical upload limits.

---

## What bran deliberately does not do

| | Why |
|---|---|
| Distribute a signed binary | self-signed certificate; build from source |
| Record a single window | full screen only, by design |
| Zoom / Teams | Meet first. `MeetTitleMatcher` is written to extend |
| Cloud storage | files stay on your Mac, by choice |
| Windows / Linux | ScreenCaptureKit is macOS-only |

---

## License

MIT — see [LICENSE](LICENSE).

Source comments are in French; documentation and public API are in English.
