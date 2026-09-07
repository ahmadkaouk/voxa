**Stage 3: native session pipeline**

> Historical checkpoint report. Implementation status and retired tool commands below refer to this stage. See [stage 6](native-migration-completion.md) for the final native application; pre-removal source/tools are preserved at `881b78f`.

Implemented on `codex/swift-native-migration` after the stage 2 checkpoint `8278249`, following the user's 2026-09-07 request to commit and continue. The remaining [recording hardware checks](native-recording-proof.md) stay open. This stage established the native workflow with fixtures and was committed as `cfefab6`. [Stage 4](native-application-integration.md) now connects it to the app; the preserved installed legacy app remains available for rollback.

**What owns the workflow**

`DictationSession` is one `@MainActor ObservableObject` in the existing Swift target. It directly calls `AudioRecorder`, `TranscriptionClient`, and `TranscriptOutput`. Three small protocols let tests pause those same operations; `DictationClock` provides clock closures. There are no new packages, production targets, runtime backend selectors, or event buses.

The session owns `idle → starting → recording → finishing → transcribing → delivering → idle`, with a recoverable `failed` state. Active states carry a UUID, recording origin, and immutable settings snapshot. The API key is a request argument retained by the active task, not published state or stored preferences.

| Command / event | Behavior |
| --- | --- |
| Start | Accepted from idle or failed; validates settings and a nonempty key, captures settings, and starts one workflow task. |
| Hold release | Stops only a hold-origin recording, including one still starting. |
| Toggle | Starts while idle/failed; requests stop while starting/recording; does nothing during processing. |
| Stop during startup | Remembers the request and finishes as soon as recorder startup resolves. |
| Cancel during capture | Discards audio and awaits cleanup before another recording is accepted. A cancel arriving while Stop is releasing capture still suppresses upload. |
| Cancel during transcription/output | Does nothing, preserving recording-only user cancellation. |
| Duration limit / recorder completion | Finishes once, using both recorder status and a monotonic deadline. The recorder retains its independent sample cap. |
| Settings update | Allowed while idle/failed and only when valid. Busy settings changes are rejected. |
| Copy Last Transcript | Returns an explicit result from the same serialized output worker. Does not overwrite session completion state. |
| Shutdown | Rejects new work, invalidates completions, cancels the workflow task, and awaits capture/output cleanup. |

After every suspension, the workflow checks cancellation and the active session ID before advancing. Stop requests are idempotent. Failure recovery waits for recorder cleanup; a cancel arriving during that cleanup is still honored. Only one upload and one delivery can occur for an accepted recording. Empty transcripts fail without output. A completed transcript remains available for explicit copy even when output fails.

Recorder snapshots are polled at 20 Hz while recording. A stop/cancel during that wait can take up to 50 ms to reach the worker. During startup it waits for the recorder's first-buffer readiness or startup failure; the recorder's existing three-second missing-buffer watchdog still applies. A blocked native engine operation is never abandoned to permit overlapping capture. Measure these boundaries during native app integration before drawing latency conclusions.

The recorder caches a completed WAV for repeatable Stop calls. The session releases that cache after delivery or on failure/cancel, before returning to idle. It retains the latest transcript, not a recording history.

**Transcription**

`TranscriptionClient` uses asynchronous URLSession and preserves the existing `gpt-transcribe` model, Bearer authorization, multipart `model` and `file` fields, `audio.wav` filename, `audio/wav` content type, and JSON `text` response. These match the [official transcription request documentation](https://developers.openai.com/api/reference/python/resources/audio/subresources/transcriptions/methods/create), checked on 2026-09-07, and the existing Rust request construction.

The default endpoint is `https://api.openai.com/v1/audio/transcriptions`. Endpoint and URLSession constructor injection support local fixtures and the existing development override when application wiring moves in stage 4. Both request and resource timeout defaults are 60 seconds. Multipart assembly and response decoding happen outside the main actor. The client uses an ephemeral session with no cookie, credential, or response-cache storage, adds no upload retries, and refuses HTTP redirects. It distinguishes authentication, rate limiting, request status, network, timeout, invalid response, and empty transcript errors. Errors exclude API keys, server response bodies, and transcript contents. Task cancellation propagates to URLSession.

Credential lookup, permission prompts, preferences import, and the development endpoint are connected by stage 4 application wiring. The model/provider remain unchanged.

**Output and clipboard ownership**

`TranscriptOutput` wraps the existing `ClipboardAutopaster` on one serial background queue. Its main-actor entry points enqueue delivery and explicit copies in command order. Clipboard access retains the existing main-thread routing; paste waits and settling remain off the main thread. A drain operation waits for queued output, including clipboard restoration, before normal termination.

Outcomes distinguish disabled output, copied text, manual-paste fallback, unconfirmed paste, a newer clipboard, and snapshot/write/restore failures. The session publishes completion only after output and cache cleanup finish. Fallbacks and a newer clipboard do not qualify for a success checkmark. Clipboard consumption remains a best-effort signal, not proof of insertion into another app. The legacy string-returning helper remains only for legacy test coverage until stage 6 removal. The native AppController uses the session output API.

**Validation recorded on 2026-09-07**

`./scripts/check.sh` passed formatting, Cargo check/clippy, all 79 Rust tests (plus the intentionally ignored benchmark), the Swift app build, all existing Swift assertions, 12 recorder groups, and 15 new pipeline groups. The machine uses the shared Command Line Tools runners because XCTest is unavailable. The pipeline runner compiles with warnings as errors and targets macOS 13. Its assertions are also registered as XCTest cases.

Run the new checks alone with `./scripts/test-native-pipeline.sh`. The full validation log is local at `dist/migration-measurements/stage-3/validation.log`.

- Workflow ordering, duplicate stop, hold/toggle origins, busy commands, startup stop/cancel, stop/cancel races, and cleanup before retry.
- Fake-clock duration boundary and immutable settings; automatic sample-cap completion.
- Capture, transcription, and output failures; empty transcript; recovery and Copy Last Transcript.
- Recording-only cancellation, late transcription completion after shutdown, and shutdown waiting for startup or output.
- Byte-for-byte multipart construction with binary audio, Unicode text, HTTP errors, malformed/empty JSON, timeout/network errors, invalid keys/audio/endpoints, and URLSession cancellation.
- Real recorder → real URLSession client → real output wrapper, using generated microphone buffers and an intercepted HTTP response.
- Actual isolated pasteboard restoration followed by queued Copy Last Transcript; cancelling the awaiting delivery task does not abandon cleanup or block the main run loop.

All HTTP requests were intercepted locally and used dummy keys. Audio input was generated. Clipboard integration used a uniquely named pasteboard, not the user's system clipboard. No live microphone, external transcription request, daemon shutdown, or installed-app replacement was needed for this stage.

**Next integration boundary**

Stage 4 connected the current UI, hotkeys, overlay, and sounds to this session, with preferences/Keychain/permission wiring and configuration import. The user confirmed successful live dictation through the signed native app on 2026-09-07; see the [stage 4 report](native-application-integration.md). Preserve the signed legacy rollback app and source checkpoints. Stage 5 retains the outstanding real-device, permission recovery, sleep/wake, long-duration, daily-use, performance, and upgrade/rollback checks.
