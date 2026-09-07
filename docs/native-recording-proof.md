**Stage 2: native recording proof**

Started on `codex/swift-native-migration` after checkpoint `ab12cf0` (the hardened daemon and stage 1 baseline). The user accepted the usual microphone, hold/toggle, and autopaste baseline and explicitly requested proceeding to stage 2. Unmeasured stage 1 hardware/performance items remain open; they are not recorded as passing.

The native recorder and development preview are implemented. Fixture validation and the built-in microphone checks below passed, including user-confirmed speech playback. External-device interruption, permission denial/recovery, sleep/wake, and long-duration validation remain pending before closing the hardware gate. The shipping app still uses its existing daemon.

**Implementation**

All production code stays in the existing `VoxaMenuBar` target:

| File | Purpose |
| --- | --- |
| `AudioRecorder.swift` | Own capture on one serial worker. Async start, stop, cancel, and meter snapshot; caller-provided session IDs reject stale commands. |
| `AudioCaptureDevice.swift` | AVAudioEngine input, configuration/sleep notifications, and a fixed four-slot audio handoff. A small capture-device protocol supports deterministic lifecycle tests. |
| `AudioWAVEncoder.swift` | Mix channels, meter, resample with AVAudioConverter, and encode 16 kHz mono PCM16 WAV on the same worker. |

Start succeeds after the first nonempty audio buffer. A three-second watchdog fails missing or stalled capture. Device-format changes and sleep terminate the recording with a recoverable error; the next attempt creates a fresh engine. Stop removes the tap, stops the engine, drains accepted buffers, and flushes the converter. Cancel releases capture and discards audio. Another start cannot pass a blocked engine operation because all device operations share one worker. There is no unsafe timeout that abandons an engine and permits a conflicting capture.

The input callback only copies Float32 samples into preallocated buffers and signals a coalescing dispatch source. A short mutex protects buffer ownership/copying; the worker never holds it while converting or controlling the engine. Four slots of 32,768 frames cap the handoff at 4 MiB for the maximum supported eight channels. A full slot pool or oversized buffer fails capture explicitly instead of silently losing audio. This is bounded buffering, not a claim of a lock-free real-time callback.

Supported input is noninterleaved Float32, 8–192 kHz, one to eight channels. The engine's format is validated before tap installation. Conversion handles mono/stereo downmix, sanitizes non-finite samples, clips output, and retains resampler state across buffers. End-of-stream flushes trailing conversion data. PCM is capped at the requested 1–3600 second limit (32,000 bytes per second), with fixed scratch buffers. WAV assembly temporarily copies the capped PCM; peak memory at the longest recording duration still needs measurement.

The caller requests microphone permission before starting. The recorder itself never displays permission prompts. Cancelling an awaiting Swift task does not cancel capture: the owner must call `cancel(id:)` and await cleanup, including at application shutdown. IDs must be unique per recording attempt. The future session coordinator will own workflow state; the recorder owns only capture state.

**Automated validation**

Run `./scripts/test-audio-recorder.sh` for the shared recorder assertions without opening a microphone. They are also registered as XCTest cases and included in `./scripts/test-swift.sh` and `./scripts/check.sh` through the Command Line Tools fallback.

- WAV header and independent AVAudioFile decoding; six input rates from 8 to 192 kHz, mono and stereo.
- Tone duration/frequency and beginning/end samples; identical conversion across irregular input chunks.
- Silence, opposing stereo channels, clipping, non-finite samples, invalid limits, and empty audio.
- Bounded input slots, copied buffer ownership, duration cap, and explicit overrun errors.
- Repeated start/stop, idempotent stop, cancellation during startup, stop during startup, and stale callbacks/commands.
- Injected permission/unavailable-device/startup failures, interruption, missing first buffer, stalled input, and restart after cleanup.
- Conflicting start and capture teardown before a successor, while main-actor work remains responsive.

These tests substitute the hardware boundary. They do not establish actual TCC behavior, device removal, sleep/wake recovery, speech quality, or microphone-release timing on real devices.

On 2026-09-06, the full `./scripts/check.sh` passed: formatting, Cargo check/clippy, 79 Rust tests (plus the intentionally ignored benchmark), the Swift app build, all existing Swift assertion groups, and 12 recorder groups. This machine used the Command Line Tools fallback because XCTest is unavailable. The local log is `dist/migration-measurements/stage-2/validation.log`. The preview compiled with warnings as errors for macOS 13, its plist/signature checks passed, and its actual UI blocked Start while the installed Voxa was running, before prompting for microphone access.

**Development preview**

Build with `./scripts/preview-recorder.sh`, then open `dist/apps.noindex/Voxa Recorder Preview.app`. The script compiles a release-optimized preview for macOS 13 and signs it using `VOXA_CODESIGN_IDENTITY` when provided, otherwise an ad-hoc signature. It creates no new package or production target. A rebuilt ad-hoc preview may need microphone permission again; signed production permission migration is still stage 4/5 work.

Before testing, finish any dictation, quit the installed Voxa, and stop its existing service:

```bash
launchctl bootout "gui/$(id -u)/com.voxa.daemon"
```

The preview checks that the installed app and the current user's `voxa-daemon` are stopped before starting. Keep the legacy backend stopped throughout the test. The preview does not stop services, modify configuration, or access credentials. When finished, quit the preview and reopen `/Applications/Voxa.app`; the installed app recreates its daemon service.

Quitting the installed app may already unload the service. In that case `bootout` reports "No such process"; confirm `pgrep -x -u "$(id -u)" voxa-daemon` finds no process before proceeding.

Click Start to request microphone access and capture from the current default input. Stop creates a WAV; Cancel discards it. Play listens to the latest WAV, and Save WAV writes only to an explicitly selected location. Starting again clears the previous result. Audio otherwise stays in memory. No transcription, clipboard output, or upload is performed.

The preview shows captured duration, meter level, input format, start-call-to-first-buffer time, and stop-call-to-WAV-ready time. Cancel reports microphone-release time; automatic stop labels retrieval of the completed WAV separately. These are individual development observations, not a comparative performance result. Use repeated manual-stop samples for a later stop-overhead comparison.

**Outstanding hardware validation**

On 2026-09-07, the user requested committing this checkpoint and proceeding to stage 3. The recorder is committed as `8278249`. Native workflow implementation continues with fixtures; the checks below remain open and must be completed before enabling native capture for daily use.

| Scenario | Status / evidence required |
| --- | --- |
| Built-in mic: start, speech, stop, local playback | Passed on MacBook Pro Microphone; user confirmed the full sentence, including first/last words, was clear. Live meter observed. |
| Manual stop and cancel followed by a new recording | Passed: cancel discarded the result with Play/Save disabled, the next capture started successfully, and a separate short manual recording produced its own WAV. Sub-buffer rapid command races and stale audio are covered by fixtures; spoken-content isolation after cancel still needs a dedicated listening check. |
| Automatic stop | Passed at 15 seconds; 480,044-byte WAV and microphone inactive afterward. |
| Permission denied, then granted and retried | Pending through macOS privacy controls. |
| External mic / default-input change / disconnect during capture | Pending; capture must fail cleanly and a new attempt must work. |
| Sleep/wake during capture | Pending; interrupted audio must not become a successful WAV, then retry must work. |
| Quit while recording | Passed: preview process exited and Core Audio reported the default input inactive afterward. |
| Long recording / peak memory | Pending; investigate growth beyond capped PCM and fixed scratch space. |

Live observations on 2026-09-06: with the user's approval, the installed app was verified idle and quit, and its daemon was confirmed absent. The preview obtained microphone access and completed a 15-second automatic-stop recording using the default MacBook Pro Microphone (48 kHz, one channel). The user confirmed clear playback. Observed first-buffer times were 216.7, 162.8, 160.0, and 159.4 ms across four starts; these are too few samples for a performance conclusion. Cancel returned in 16.5 ms. A manual stop produced 3.10 seconds / 99,244 bytes in 14.4 ms. The older preview's 0.2 ms timing after automatic completion measured retrieval only; the final preview labels that separately.

A read-only Core Audio probe reported the default input active during capture, inactive after automatic completion, and inactive after quitting during capture. The preview blocked a start when the installed Voxa was running again during testing. At the end, the preview was confirmed stopped, `/Applications/Voxa.app` was reopened, and its recreated daemon returned `idle`. No captured speech was saved to the repository.

Do not advance into the larger UI migration on fixture results alone. Record hardware observations here and resolve capture failures before proceeding.

Implementation references checked against the installed Apple SDK headers: [AVAudioNode tap](https://developer.apple.com/documentation/avfaudio/avaudionode/installtap(onbus:buffersize:format:block:)), [AVAudioConverter](https://developer.apple.com/documentation/avfaudio/avaudioconverter), and [engine configuration notifications](https://developer.apple.com/documentation/foundation/nsnotification/name-swift.struct/avaudioengineconfigurationchange). Engine teardown is dispatched away from the configuration notification callback, as required by the AVAudioEngine header's deadlock warning.
