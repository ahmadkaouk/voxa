# Voxa architecture

Voxa is one macOS application process. The root `voxa` Swift package contains the
`Voxa` application target in `Sources/Voxa` and the `VoxaTests` target in
`Tests/VoxaTests`, with `voxa` as the development executable. The deployment
target is macOS 13; development uses Swift 6.0+.

```text
Voxa.app
  UI and hotkeys
        │
  DictationSession (@MainActor)
        ├── AudioRecorder       serial capture/conversion worker
        ├── TranscriptionClient async URLSession
        └── TranscriptOutput    serial clipboard/paste worker
```

## Ownership and concurrency

`DictationSession` is the sole observable owner of the dictation workflow.
`AppController` connects setup, settings, hotkeys, permission recovery, sounds,
overlay presentation, and shutdown. Local view state controls presentation only.
The native menu observes `AppController`, which forwards workflow state changes.
Audio levels update only the overlay; rebuilding menus on each level sample
interrupts submenu tracking while recording.

Each recording has an ID and settings snapshot. The session checks both its ID
and expected state after suspension so a late callback cannot complete a newer
recording. States are `idle`, `starting`, `recording`, `finishing`, `transcribing`,
`delivering`, `restoringClipboard`, and `failed`. Stop or cancel during preparation
is remembered; stopping during a permission prompt cannot start capture later.
Cancellation is limited to recording. Normal Quit invalidates pending work and
awaits capture teardown and clipboard cleanup before the process exits.

Model, output, and recording-limit preferences can change during a workflow.
The active recording keeps its snapshot; the next recording uses the new defaults.
These edits do not rebind hotkeys or reset physical key tracking.

After a paste request is sent and its clipboard text is read, `restoringClipboard`
permits another recording while the output worker finishes its 500 ms settling
interval and restoration. The recorder is released before delivery begins.
Later pastes and copies remain queued behind cleanup, and its final result only
updates the session if no newer recording has started. The paste checkmark appears
on the read signal; restoration does not delay it or restart its display timer.

The configurable Finish & Send chord (Option+G by default) requests paste-and-submit
while recording in Autopaste mode. Plain Enter is never a built-in recording action.
The chord is swallowed only when the session accepts submission; repeats and the
key-up remain swallowed even if its modifier is released first. The non-consuming
global-monitor fallback never dispatches submission. Submit bindings require one
key plus a modifier and cannot overlap the toggle binding. Legacy `holdHotkey`
preferences migrate to `finishAndSubmitHotkey` when compatible, with a valid
non-overlapping fallback otherwise. Hold handlers and recording origin are removed.
This pins the
destination to the app active at the keypress and keeps the session busy until
Return is sent or skipped. Return follows the settling interval and is skipped
if delivery is unconfirmed, the clipboard changes, or a different app is active.
Its completion checkmark follows the submission outcome.

The three workers are constructed directly. Small protocols and injected closures
allow deterministic tests.

## Recording, transcription, and delivery

| Component | Behavior |
| --- | --- |
| `AudioRecorder` | Owns AVAudioEngine lifecycle on a serial worker. A four-slot bounded inbox copies tap buffers without resampling or allocating audio buffers in the callback. Stop drains accepted audio; cancellation discards it. A pre-audio configuration change gets one clean engine restart for Bluetooth profile switching; later changes, interruptions, overruns, and a stalled microphone fail the recording and clean up. |
| `AudioWAVEncoder` | Downmixes and streams conversion to 16 kHz mono PCM16 WAV, bounded by the configured 1–3,600-second limit. Meter sensitivity and smoothing affect the display only. |
| `TranscriptionClient` | Uploads WAV data with async URLSession, the configured model, and a Bearer credential. The request timeout is 60 seconds. Redirects and automatic retries are disabled; errors are typed and no transcript/key is logged. |
| `TranscriptOutput` | Serializes delivery and Copy Last Transcript. Autopaste saves all clipboard items/formats, sends paste, waits for consumption, and restores only if the clipboard still belongs to the operation. Clipboard Only intentionally replaces it; None skips automatic delivery. Explicit outcomes distinguish success from manual recovery. |

Audio and the latest transcript are held in memory. The app does not persist a
recording/full-transcript history. A failed paste can be recovered with Copy Last
Transcript while the app remains open. Clipboard reads are a best-effort delivery
signal; macOS does not acknowledge universal paste success.

## English feedback

`DictationSettings` snapshots the opt-in at recording start. After obtaining the
original text, `DictationSession` emits a synchronous callback that only enqueues
analysis; output never awaits it. A second callback marks delivery complete,
including clipboard restoration and any Return submission. `AppController`
connects these callbacks to a separate `FeedbackController` and nonactivating
`FeedbackPanelController`; feedback never changes dictation state or output.

`FeedbackClient` sends a separate untrusted transcript message with fixed coaching
instructions, a strict `FeedbackAnalysis` schema, and `gpt-6-luna` with low reasoning effort.
It uses an ephemeral URLSession, `store: false`, a 60-second timeout, and no
tools, redirects, or retries.
Input above 40,000 characters is skipped. Truncated or invalid responses produce
a quiet menu status; each finding must quote an exact source excerpt. Duplicate
corrections are removed without capping the array. The output budget is 16,384 tokens.
Grammar findings may include a nullable spoken `alternative`, saved as part of
the same lesson. Optional `pattern` templates and stable `LearningFocus` categories
support reusable expressions and history; older saved lessons without these fields
remain compatible. The response also contains `GrammarAssessment` and grounded
`successfulPatterns` observations, plus `ExpressionAssessment`. Only category IDs
from prior reviews/saved lessons accompany the next dictation transcript, together
with ephemeral text context when separately enabled. Explicit
practice requests separately include the selected lesson and the submitted answer.

### Automatic text context

`AccessibilityTextContext` implements the injected `TextContextCapturing` boundary.
It checks opt-in exclusions, Accessibility trust, secure input and protected apps,
then freezes the foreground PID before overlay changes. AX IPC runs on a detached
utility task, with a 450 ms total budget, 35 ms per-call timeout, and bounded tree
depth/node/read counts. `ContextTextExtractor` reads a UTF-16 range around the caret,
constrained by the visible range when available. For short multiline editors it
walks a nearby containing pane and collects visible static text above the editor,
pruning controls, protected fields, off-column sidebars and other editable controls.
No screen images, OCR, pasteboard, scrolling or external retrieval is involved.
Foreground app, focused window and field must still match after the read.

`DictationSession` owns a cancellable `TextContextCapture` for one recording ID.
It only takes an already-completed snapshot when queuing feedback, never awaiting
capture. Discard, failed preparation, shutdown, disabling feedback/context and
changed exclusions clear it. A newer recording cannot consume an older result.
`FeedbackTextContext` is intentionally not Codable; its text is capped at 2,400
UTF-16 units and only serialized into the feedback request's untrusted `context`
field. The prompt limits it to interpretation/phrasing and all response evidence
remains validated against the original transcript. The feedback controller retains
only the source app name for its indicator after the request completes. No context
is attached to a lesson, progress record, practice check, transcription or timing log.
Changing context preferences cancels pending context-bearing feedback as well as
capture; already-transmitted input cannot be recalled.

The grammar rubric has fixed 2/4/6/8/10 bands, not model confidence or a deduction
per correction. Code suppresses scores under 20 words, for recognition issues, or
when the band contradicts the actual errors. The model must also abstain on
insufficient English or ambiguous transcripts. Optional phrasing cannot lower a
score. Success observations need exact source evidence and a previously encountered
category; same-category errors, uncertainty and duplicate observations are excluded.
These safeguards constrain the response, but do not establish linguistic accuracy.

`ExpressionAssessment` contains exactly one source-grounded observation for accuracy,
vocabulary, phrasing, range and coherence, with a provisional A1–C2 descriptor per
dimension and a speaking-purpose category. At least 40 words are required; limited,
uncertain and non-English speech abstains. A perfect grammar band is not a proficiency
level. `ExpressionSample` strips source evidence before persistence. Optional new
fields preserve v1 progress-file compatibility and the parser accepts legacy
grammar-only responses from older compatible services without inventing a level.
`ExpressionProfile` selects up to 30 qualifying samples in 90 days, requires six samples,
300 words and two speaking purposes, takes a median per dimension, then brackets their
mean with adjacent CEFR descriptors. It compares the latest six with the preceding six
for a cautious trend. These are documented product heuristics, not a validated test or
confidence interval. The UI states the calibration and modality limits explicitly.

See [feedback validation](english-feedback.md) for coaching quality checks.

`FeedbackController` owns the findings array, request generation, presentation,
and persistence. Delivery and recording IDs prevent premature or stale panels.
New transcripts cancel earlier analysis; disabling and shutdown invalidate it.
⌘S saves all lessons in one atomic write, excluding recognition issues; Esc clears
the review without saving lesson excerpts. Automatic progress is independent of ⌘S/Esc. Failed writes retain the review, and
a late save cannot dismiss a newer generation. Neither path changes inserted text.

Live reviews use `FeedbackWordDiff` to lead with individual changes and reusable rules.
`FeedbackSentence` expands excerpts to full sentences and combines compatible edits;
conflicting edits remain separate comparisons. The current transcript stays in memory
for this presentation and never enters saved lessons. Optional wording is always expanded.
`FeedbackLessonView` retains inline comparisons in saved details and recognition checks.
One neutral background covers the review; only Save is blue. A five-second presentation
timer pauses on hover or pin, is cancelled during saving, and cannot hide a newer review.

`CorrectionStore` is an actor that stores a versioned JSON file in Application
Support/Voxa. A failed load blocks mutations to protect unreadable data. Only
explicitly accepted lessons reach disk; full transcripts and practice answers do
not. `LearningProgressStore` separately persists bounded, versioned metadata for up
to 200 reviews: ID, date, grammar band, unique mistake/suggestion/success categories,
and optional expression dimensions, word count and speaking-purpose category.
It never persists the source evidence. `LearningProgress` queues serial writes,
deduplicates recording IDs, protects corrupt files, and offers retry and clear.
Recording progress requires validated analysis plus the delivery callback; it never
waits on lesson acceptance. Failed progress writes do not hide feedback. Disabling
cancels pending analysis, while already queued metadata writes finish. Shutdown
waits for local writes, never for the feedback service. Files use mode 0600 and
atomic replacement; application-support directories are created with mode 0700.

Existing v1 preferences default a missing `englishFeedbackEnabled` to false.
A custom transcription endpoint requires an explicit `VOXA_OPENAI_FEEDBACK_URL`
(HTTPS, or HTTP loopback for fixtures), avoiding an implicit fallback to OpenAI.

## Small practice and reviews

`PracticeController` owns a separate, explicitly opened interaction: repeat a supplied
sentence, then produce a new example. Short reviews start directly at the new-example
step, using up to three due saved patterns. It has no transcript-output dependency.
`AppController` shares one `AudioRecorder` between dictation and practice, prevents
opening practice until dictation/clipboard cleanup completes, suspends feedback panels
and normal dictation shortcuts while practice is open, and leaves the recording overlay hidden
only after microphone cleanup. Window close, sleep and quit cancel practice; generation
checks discard late permission, transcription and evaluator completions. Capture is
capped at 40 seconds. Typed practice bypasses microphone permission and transcription.

`PracticeClient` shares the feedback endpoint and ephemeral transport, using a smaller
strict schema and a 2,048-token output budget. It checks only the chosen pattern, grounds
success in an answer excerpt, rejects exact copied examples in the new-sentence step,
and abstains on uncertainty. It cannot judge pronunciation from transcribed text. API
keys stay scoped to the request workflow. No original dictation, screen context, other
lessons or practice history accompany the request.

`PracticeHistory` serializes metadata-only writes through `PracticeHistoryStore` with
the same atomic-file/0600/load-failure protections as other stores. Up to 500 primary
lesson records contain IDs, attempts, streak and review dates, never answers/audio.
One scheduling observation is committed per lesson interaction; a retry during that
interaction prevents a later correction from boosting a success streak. Only new-sentence
success/retry affects scheduling; repetition, uncertainty, off-topic answers and skips
do not. Saved paired alternatives do not reschedule their primary correction. Intervals
are 1/3/7/14/30 days, with one day after retry, and early repeated practice cannot advance
them. Due selection groups duplicate patterns and respects their latest spacing.
Practice results never enter `LearningProgress` or the expression profile. Deleting
lessons queues removal of their review records and cancels an affected active exercise.

## Settings, credentials, and permissions

`PreferencesStore` validates and saves one versioned UserDefaults value under
`nativePreferences.v1`. Existing settings keep the same format and storage key.
A first launch saves the defaults; invalid saved settings produce a recoverable
setup error. Failed saves restore the previous value.

`Keychain` uses native Security APIs for service `com.voxa`, account
`OPENAI_API_KEY`. The environment source is read-only. Keychain mode retains the
environment fallback for a missing/empty item; denied Keychain access is an error.
Credentials are not written to preferences or diagnostic logs.

`Permissions` handles microphone, Accessibility, and Input Monitoring checks and
recovery. The installed app keeps bundle ID `com.voxa.menubar` and a stable signing
identity independently of the Swift target and executable names, so existing
permissions and UserDefaults remain associated with Voxa. Microphone access is
requested before capture. Permission state and hotkeys refresh when returning to
the app or waking the Mac.

## Installation and recovery

`scripts/package-macos.sh` builds and signs the Swift executable, icons, and sounds
with their license, then creates a DMG. `scripts/verify-native-bundle.sh` checks
the signature, identity, resources, deployment target, and exactly one executable.
`scripts/install.sh` verifies a staged copy and backs up the existing signed app
before replacement. A failed final move restores the previous app. Replacing a
running app is refused.

`CaptureGuard` blocks setup and recording if another Voxa copy is running.
It checks through AppKit before and after permission/credential work, so a copy
launched while a prompt is open is also detected.

Signed backups stay under `dist/apps.noindex/backups/`; preserve that directory
before cleaning build artifacts. To roll back, quit Voxa and restore the entire
preserved signed app bundle to `/Applications/Voxa.app`.

## Validation

`./scripts/check.sh` builds the app and runs Swift tests. XCTest is used when
available; Command Line Tools run the same shared assertions through standalone
harnesses. Discovery guards reject unregistered test files instead of silently
skipping them. Fixtures cover capture/conversion, session ordering and cleanup,
HTTP errors, output/clipboard recovery, settings/Keychain, and duplicate-app protection.

`scripts/test-install.sh` exercises clean installation, signed updates/backups,
failure recovery, and the running-app guard in temporary directories. See the
[development guide](development.md) for development commands and
the optional live clipboard and overlay checks.
