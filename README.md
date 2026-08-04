# bran

**Automatic Google Meet recorder for macOS.** Free, open source, fully local.
No account, no subscription, no upload.

bran watches for Google Meet windows, offers to record when one appears, and
captures your screen, the other participants' audio and your own microphone into
a single `.mp4` file that stays on your Mac.

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
| Screen Recording | yes | capture, and the window titles used for detection |
| Microphone | yes | your own voice |
| Notifications | recommended | the "record this meeting?" prompt |
| Calendar | no | names the recording after the calendar event |

macOS only applies the Screen Recording grant at the **next process start** —
quit and relaunch bran after granting it.

---

## How it works

```
┌─────────── detectors (report facts, never decide) ────────────┐
│  WindowTitleDetector          CalendarWatcher                 │
│  CGWindowListCopyWindowInfo   EventKit                        │
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

---

## Development

```bash
swift build          # builds everything
swift test           # ~35 tests, runs in about a millisecond
open Package.swift   # opens in Xcode, with SwiftUI previews
```

The package is split so that the interesting logic is testable without a screen,
a permission or a display server:

| Target | Contains |
|---|---|
| `BranCore` | pure logic — title matching, session resolution, state machine |
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
