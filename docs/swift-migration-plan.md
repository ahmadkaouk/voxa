**Voxa: migration to the minimal native Swift architecture**

Implementation plan for the agreed minimal architecture, updated 2026-09-06. The stage 1 baseline and preceding Rust fixes are committed as `ab12cf0` on `codex/swift-native-migration`. The user accepted the usual microphone/shortcut/autopaste baseline and requested proceeding to stage 2; remaining live measurements stay listed in [the baseline report](migration-baseline.md). The native recorder and development preview are implemented; automated fixtures and built-in microphone checks passed, including user-confirmed speech playback. [The recording proof report](native-recording-proof.md) tracks the remaining device, permission, sleep/wake, and duration checks. The everyday app still uses the daemon.

The target is one macOS menu bar application, one process, and one Swift application target, with the existing test target alongside it. One observable object owns the dictation workflow and calls three concrete components directly. The expected benefit is reduced maintenance and lifecycle complexity. Performance improvements must be measured.

The completed Rust fixes beyond commit `fe3af80` were preserved on the migration branch and included in an immutable source snapshot. The baseline report identifies that snapshot and distinguishes it from the installed signed release. Preserve those fixes and their tests throughout migration.

**Scope and architecture decisions**

Keep macOS 13 support and the existing Swift application target. Reuse the popover, overlay, sounds, hotkey bindings, and clipboard safeguards. Preserve the transcription provider, model selection, output modes, recording limits, and recording-only cancellation semantics. Retire `voxactl` with the daemon; this migration does not add a replacement external control protocol.

The final application has this structure:

```text
Voxa.app — one process, one Swift application target
├── UI and hotkeys
├── DictationSession       Owns state and coordinates the workflow
├── AudioRecorder          Captures audio
├── TranscriptionClient    Sends audio and returns text
└── TranscriptOutput       Handles clipboard and paste
```

| Component | Responsibility |
| --- | --- |
| UI and hotkeys | Display observed session state and send start, stop, and cancel actions to the session. Reuse existing views, overlay, sounds, and hotkey handling. |
| `DictationSession` | Main-actor observable session state, command ordering, duration limit, and active tasks. |
| `AudioRecorder` | AVAudioEngine capture, meter levels, audio conversion, and capture cleanup on a dedicated worker. |
| `TranscriptionClient` | Asynchronous URLSession upload, response decoding, and typed request errors. |
| `TranscriptOutput` | Existing serial output behavior exposed through an asynchronous interface. |

Keep construction, hotkey connections, and startup/shutdown wiring in the existing app entry point or a small lifecycle helper. Preferences, Keychain access, and permission checks are supporting functions or small concrete utility types. Files such as `Preferences.swift`, `Keychain.swift`, and `Permissions.swift` are sufficient; these helpers do not introduce service layers or additional owners of session state. They retain configuration import, validation, credential access, and permission recovery responsibilities.

Use concrete Swift types and constructor injection. Introduce a small protocol or injected closure only where a specific recording, transcription, output, or timing test needs a controllable substitute. Do not add a dependency-injection container, generic event bus, repository layer, plugin system, separate core package, or a general backend framework. Existing files can remain in the current target; new folders are optional organization, not module boundaries.

Views observe the same `DictationSession` instance and call it directly. The session calls the recorder, client, and output component directly and awaits results. Keep UI presentation details, such as an expanded settings menu, local to the view. Derive overlay and sound behavior from session changes without another copy of the workflow state.

Use `@MainActor` and `ObservableObject` for the session to retain macOS 13 support. Isolate audio control/conversion on its worker and retain the existing serial output queue behind an asynchronous API. URLSession handles asynchronous network transfers. Add actor or queue boundaries only where resource ownership or blocking work requires them; wrapping synchronous work in `Task` alone does not move it off the main thread.

`DictationSession` owns a state enum: `idle`, `starting`, `recording`, `finishing`, `transcribing`, `delivering`, and `failed`. Derive busy indicators and available actions from that state. Carry the active session ID and relevant context in the state model. Short preparation and finishing phases can reuse the existing recording/processing presentation.

Set the appropriate state before awaiting work, and validate the session ID and expected state after each suspension. Stop and cancel during startup must be remembered and resolved as capture starts or fails. Allow another capture only after the previous capture has released its resources. Preserve the rule that hold release stops only a hold-origin recording.

Preserve recording-only cancellation: cancel during transcription does not introduce a new user-facing network-cancellation feature. App shutdown invalidates pending completions, cancels outstanding tasks where supported, and stops capture. Once output has begun, complete its clipboard cleanup before normal app termination rather than abandoning borrowed clipboard state.

Settings changes remain restricted while busy for the initial migration. Each recording uses a settings snapshot. A later change to allow edits during dictation should be evaluated separately.

**Implementation sequence**

| Stage | Deliverable | Gate before advancing |
| --- | --- | --- |
| 1. Baseline | Behavior checklist, runnable tests, and timing/resource measurements. | Accepted baseline recorded, with existing failures distinguished from migration regressions. |
| 2. Native recording proof | Recording and metering through AVAudioEngine, exercised in a development harness. | Real microphone start/stop/cancel and interruption scenarios work. |
| 3. Native session pipeline | Session coordinator, transcription client, and output integration exercised with fakes and fixtures. | Ordering, cancellation, and output outcomes pass deterministic tests. |
| 4. Application integration | Existing UI/hotkeys drive the native pipeline; settings and credentials migrate. | Full dictation works in a signed app with the daemon stopped. |
| 5. Candidate validation | Native-only app bundle, parity checks, performance comparison, and rollback rehearsal. | Several days of daily use without unresolved capture, delivery, or migration regressions. |
| 6. Removal | Rust, IPC, any temporary integration code, and daemon build steps retired. | Swift-only build, tests, installation, update, and recovery checks pass. |

**Stage 1: establish the baseline**

Record the accepted source revision and preserve a working signed app bundle. Preserve the existing configuration file for rollback; leave the credential in Keychain. Finish or isolate concurrent work before changing shared files.

Run the Rust suite and discover and run the Swift suite. The earlier review found an unavailable XCTest runner and failures in standalone native checks. Establish a usable macOS test environment, including full Xcode if needed. A successful build or zero discovered tests is insufficient evidence. Record existing failures before adding migration code.

Document manual start/stop, toggle, hold, cancel, automatic stop, empty transcription, recoverable errors, all three output modes, Copy Last Transcript, custom hotkeys, sleep/wake, and permission handling. Preserve these behaviors even where implementations change.

Measure timing with a monotonic clock and session IDs, without recording transcript or credential content:

| Measurement | Boundary |
| --- | --- |
| Capture response | Hotkey handler entry to the first captured audio buffer. |
| Stop overhead | Stop action to upload initiation, including capture teardown and conversion. |
| Service latency | Upload initiation to decoded transcript. |
| Delivery latency | Transcript available to output outcome returned. |
| Startup | App launch to readiness for a first recording. |
| Resources | Combined app/daemon idle CPU and resident memory, plus peak memory during recording. |

Compare release builds on the same Mac, microphone, recording lengths, and output mode. Separate warm and cold startup. Use repeated samples and report sample counts, median, and tail timings. For latency distributions, aim for at least 30 repetitions where practical; avoid relying on a percentile from a handful of observations. Use an identical audio fixture and a controlled delayed response to distinguish local orchestration from external service variability. Treat live-provider measurements separately. Set regression budgets from baseline variability before evaluating the native candidate.

**Stage 2: prove native recording early**

Implement `AudioRecorder` in the existing Swift target and exercise it through a development harness. Use AVAudioEngine input capture and preserve the currently expected 16 kHz, mono, PCM16 WAV upload format. Keep conversion and blocking work off the main thread and out of the audio callback. Bound buffered audio by the recording limit, and avoid an unbounded task or queue per audio buffer.

Test valid WAV output using fixtures, including mono/stereo input, differing input rates, silence, and clipping. Exercise rapid start/stop, cancel followed by a new recording, unavailable or denied microphone access, built-in and external microphones, device removal, and sleep/wake. Failed capture must release resources or prevent a conflicting second capture.

Run native capture only when the legacy recorder is inactive. Do not run both backends against the microphone for a comparison. If native capture is unreliable, resolve it before undertaking the larger UI migration.

Implementation and validation details: [native recording proof](native-recording-proof.md). Build its isolated development preview with `./scripts/preview-recorder.sh`; the full check script includes the recorder's shared assertions.

**Stage 3: implement the native workflow**

Implement `DictationSession` with controllable recorder, transcriber, output, and clock substitutes using the smallest test boundaries needed. Wire the production recorder, transcription client, and output implementation directly through its initializer. Port behavioral assertions from the Rust domain and server tests; protocol-specific tests can remain with the legacy implementation until removal.

Add the URLSession client with fixture-based tests for request construction, successful and empty responses, authentication errors, rate limiting, network failure, timeout, and malformed responses. Preserve the current model and request behavior. Avoid adding automatic upload retries during migration.

Wrap the existing clipboard implementation in an asynchronous `TranscriptOutput` API while preserving its serial execution. Its blocking waits must remain off the main thread, and pasteboard operations must keep their existing main-thread routing. Serialize Copy Last Transcript with delivery. Return explicit outcomes for clipboard-only output, paste attempts, manual fallback, clipboard changes, and failures. A clipboard read remains a best-effort signal, not proof of text insertion.

Test stop twice, hold release during startup, cancel during startup, stop/cancel races, stale transcription completions, exact duration-limit behavior with a fake clock, empty transcripts, and recovery after failure. Verify a completed transcript is delivered once. Cancelled recordings must neither upload nor deliver text. A success indicator must follow the output outcome rather than transcription completion alone.

**Stage 4: connect the existing application**

After the native pipeline passes its tests, connect views and hotkeys directly to the shared `DictationSession` in one reviewable integration change. Keep the legacy signed app and source revision available for rollback. The default plan does not build a runtime backend selector or a legacy adapter.

If keeping intermediate changes buildable requires a temporary bridge, keep it local to the integration work and remove it before candidate validation. While the legacy path runs, its daemon remains authoritative for capture/transcription; a bridge must not predict the same transitions independently. Run one backend at a time and switch only after returning to idle and restarting. Never fail over automatically during an active session, because a repeated command could duplicate capture, upload, or output.

Connect the native recorder, transcriber, output, overlay, sounds, and hotkeys. Reduce `AppController` to wiring and lifecycle work, or replace it with those responsibilities in the app entry point. Native UI readiness derives from setup and session state; remove connection/reconnect controls from the native path. Keep native code free of IPC envelopes, event sequence numbers, and daemon config revisions.

Implement typed preference access as a small helper over UserDefaults. Import `~/Library/Application Support/voxa/config.toml` using a proper TOML parser. Preserve custom hotkeys, model migrations, output mode, recording duration, and development credential-source behavior. Validate the entire imported configuration before committing it. Mark the import complete only after successful persistence; repeated startup must not overwrite newer preferences. Preserve the original file and make import failures recoverable rather than silently marking them complete.

Keep Keychain lookup/update in a small native helper using the existing service `com.voxa` and account `OPENAI_API_KEY` through Security APIs. Keep secrets out of preferences and migration logs. Verify access from the signed app: changing the process accessing the entry can require authorization even when its identity is preserved.

Preserve bundle identifier `com.voxa.menubar`, signing identity, and microphone usage description. Exercise onboarding for microphone, Accessibility, and Input Monitoring; do not assume every permission transfers from daemon capture. Login registration for the main application, if offered, should follow an explicit user preference and use SMAppService.

**Stage 5: validate the native candidate and rollback**

Build a native-only candidate app bundle without an embedded daemon or temporary backend bridge while keeping legacy source available. Adapt the packaging script so the native build does not compile or sign a Rust helper. Preserve icons, sounds, the app signature, and DMG installation behavior.

On upgrade, stop the old `com.voxa.daemon` service at an idle point before native capture is enabled. If it cannot be stopped, keep capture disabled and show a recoverable explanation. Remove only the old Voxa-owned LaunchAgent registration/plist after the native path has been validated. Retain the old configuration and Keychain entry. Do not perform machine-wide process or file cleanup.

Run the full behavior checklist in the signed candidate. Verify clean installation, upgrade, relaunch, logout/login behavior where enabled, permission denial/recovery, device changes, and maximum recording duration. Watch for clipped first/last words and sound cues leaking into capture. Compare stage 1 measurements and investigate local regressions outside the agreed budgets. An external API speedup is not a release requirement; report measured improvements separately from architectural benefits.

Use the candidate for several days, targeting at least 100 representative sessions across hold, toggle, manual control, cancel, and supported output modes. Treat these as minimum exposure targets, not proof of reliability. Require no unresolved lost-transcript, duplicate-output, retained-microphone, or destructive clipboard regression.

Rehearse rollback: quit the native app, retain native preferences, restore the preserved signed legacy app, and confirm it can recreate its LaunchAgent, read its original configuration and credential, and complete a recording. Preferences changed only in the native version may revert to the preserved legacy values after rollback; document this explicitly.

**Stage 6: remove transitional infrastructure**

After the candidate and rollback gates pass, remove `IPCClient`, daemon connection state, IPC-only tests, daemon lifecycle code, and any remaining temporary integration scaffolding. Remove `voxa-core`, `voxa-daemon`, `voxactl`, Cargo manifests/lockfile, and Rust build requirements. Retain the Swift behavioral tests that replaced domain/server coverage.

Update `scripts/check.sh`, `scripts/install.sh`, `scripts/package-macos.sh`, and the root/app documentation. Keep test discovery checks so Swift validation cannot silently pass without executing tests. Replace the daemon-oriented architecture and implementation documents with the final native design and archive useful historical notes. Update or retire CLI/IPC documentation. Preserve signing and resource-packaging functionality.

The release gate is a checkout that builds and tests without Rust installed, produces a signed app containing no daemon, and completes dictation on clean install and upgrade with no running Voxa helper. The final architecture must contain one Swift application target, one session state owner, and direct calls to the three concrete worker components. Supporting preferences, Keychain, and permission helpers must not have grown into independent service layers. Keep the one-time configuration and owned-LaunchAgent migration helpers for upgrades from older releases even though the legacy backend source is removed.

**Suggested review boundaries**

Use separate, buildable changes for baseline instrumentation, native recording, session/client/output behavior, UI integration and storage migration, native packaging and upgrade handling, and final removal. Keep reviewable behavior assertions with the changes they validate. These stages manage the migration; they do not add permanent architectural layers. The native recording checkpoint is the first implementation milestone; defer a full migration estimate until that checkpoint establishes hardware and permission behavior.

Relevant sources already checked for this design: [AVAudioEngine input capture](https://developer.apple.com/documentation/AVFAudio/AVAudioEngine/inputNode), [URLSession](https://developer.apple.com/documentation/foundation/urlsession), [Swift actor reentrancy](https://forums.swift.org/t/accepted-with-modification-se-0306-actors/47662), [Keychain lookup](https://developer.apple.com/documentation/security/secitemcopymatching(_:_:)), and [main-app login registration](https://developer.apple.com/documentation/servicemanagement/smappservice/mainapp).
