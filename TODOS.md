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
