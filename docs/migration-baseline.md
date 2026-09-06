**Swift migration: stage 1 baseline**

Recorded 2026-09-06 on branch `codex/swift-native-migration`.

The automated baseline is established. The user confirmed that the installed application works normally with their usual microphone, hold/toggle shortcuts, and autopaste. Stage 1 remains open for actual capture/upload/startup timings and the live checks listed below. Native recording implementation has not started.

**Source and rollback evidence**

The source baseline is commit `fe3af80e99def6ee94be07725dcd7e93e9602d91` plus the completed, uncommitted Rust fixes from the earlier review and the agreed migration plan. Those changes were carried onto the migration branch. The snapshot predates this stage's test-harness and measurement additions.

| Evidence | Location or identity |
| --- | --- |
| Source archive, complete per-file hashes, binary Git diff, and environment metadata | `dist/migration-baseline/20260906T062128Z/` |
| Source manifest SHA-256 | `45ac463a5c2be427cf6cce0dcf47cd04286a59aecc03587d0521156180031a8b` |
| Signed rollback app | `dist/apps.noindex/backups/migration-20260906T062128Z/Voxa.app` |
| Legacy configuration backup | `dist/migration-baseline/20260906T062128Z/legacy-config.toml` |
| Full validation log | `dist/migration-baseline/20260906T062128Z/validation.log` |
| Raw samples and measurement-build provenance | `dist/migration-measurements/stage-1/` |

The rollback app passed `codesign --verify --deep --strict`. Its executable SHA-256 is `0d8395fda0e35d9c9afb95b3bdcf857e896c1e996a9cd2aec81162b6456de70e`; its bundled daemon SHA-256 is `9c6f4a9651a7729f72ac55de4d55dae87ecded19723c27f4ef3a6ca981687dc2`. The installed release's source revision is unknown. Treat installed-app observations and the newly built source fixtures as separate measurement groups.

The snapshot directory is private, the configuration backup is mode 0600, and the credential remains in Keychain. No API key was read for this work. Backups and raw measurements are local ignored artifacts under `dist`; preserve them before cleaning that directory. The source archive includes untracked source files that a Git diff alone would miss.

**Validation and test runner**

`./scripts/check.sh` passed formatting, Rust compilation, Clippy with warnings denied, 79 Rust tests, the Swift application build, and all available Swift assertion groups. The separate measurement test is intentionally ignored in ordinary correctness runs and passed when explicitly invoked in release mode.

This Mac has Command Line Tools, without XCTest. `scripts/test-swift.sh` now builds the application and selects XCTest when available; otherwise it runs shared assertions through standalone harnesses. It fails if an unregistered test file would be omitted. The XCTest wrappers remain for machines with a full runner.

| Checks executed here | Result |
| --- | --- |
| Rust core | 12 passed |
| Rust daemon | 56 passed; 1 opt-in measurement ignored in normal runs |
| CLI | 11 passed |
| Swift hotkey, IPC timeout, and popover action checks | 10 passed, preserving all 39 original assertions |
| Swift clipboard/output scenarios | 8 passed |
| Bundled start/stop/error sound decoding and levels | Passed |
| Release-mode fixture measurement | Passed separately |

The only production Swift change in this stage relocates the unchanged `PopoverPrimaryAction` enum into `Models.swift` so the existing assertions can run without launching the UI. The Rust fixture is compiled only for tests. The application still uses its existing daemon architecture.

Earlier standalone native-check crashes did not reproduce when the checks had normal macOS pasteboard/audio access. Native checks need that access; do not suppress their failures in a restricted runner. The earlier socket-startup failure also did not recur in the current 79-test suite after the preceding Rust fixes. This does not prove the absence of all intermittent failures.

**Measured values**

Environment: Mac14,6 / arm64, macOS 26.6.2 (25G83), Swift 6.3.3, Rust 1.87.0. Rust fixtures use an optimized release build; the Swift output fixture uses `swiftc -O`. Each timed metric has 30 measured samples after 3 warmups. Percentiles use nearest rank. Raw values and source hashes are preserved in the measurement directory.

| Metric | Median | p95 | What it measures |
| --- | --- | --- | --- |
| Normalize 10 seconds of synthetic audio | 1.231 ms | 1.753 ms | Existing Rust conversion: 48 kHz stereo to 16 kHz mono PCM16 WAV. |
| Upload fixture and decode a local response | 58.081 ms | 61.363 ms | Existing transcription client against loopback HTTP, including an intentional 50 ms response delay. |
| Fresh `health` request to installed daemon | 28.852 ms | 30.226 ms | Socket connect, handshake, request, and response from the Python measurement client. |
| Fresh `get_state` request to installed daemon | 29.763 ms | 30.382 ms | Same fresh-connection path, returning state. |
| Simulated pasteboard read and restoration | 505.495 ms | 507.414 ms | Existing Swift output code with an isolated pasteboard and the production 500 ms settling delay. |
| Combined installed-app and daemon RSS | 104.516 MiB | 104.516 MiB | 30 idle samples, one second apart plus sampling overhead. |
| Combined CPU between idle samples | 0.000% | 0.935% | 29 intervals, percent of one core, derived from cumulative process CPU time. |

The fixture is a generated 10-second, 440 Hz tone at amplitude 0.1. Its resulting WAV has 320044 bytes and SHA-256 `d0e38765916a951985dd8fec349c19925800f424f71421ccb56737a55d693e6b`. Use the saved `fixture.wav` for later client comparisons. The local HTTP fixture uses a dummy in-memory credential and does not contact the transcription provider.

These results do not measure hotkey latency, microphone quality, external API latency, real text insertion, or peak recording memory. Output uses a simulated immediate consumer and never sends a paste shortcut. Resource sampling adds read-only state polling and can double-count shared pages in summed RSS; CPU values are quantized by the process-time source. A zero median CPU value is not proof of zero CPU usage.

The roughly 30 ms fresh-request cost is a concrete comparison point for removing IPC. It is not a measured end-to-end dictation speedup. Likewise, the roughly 505 ms output result mostly reflects the deliberate settling interval; changing languages does not remove that behavior.

For future comparisons, preserve fixture bytes, response delay, build mode, hardware, output settings, and sample counts. Use this run to flag local regressions for investigation. Set final acceptance budgets after repeatability and missing live boundaries have been measured; do not turn this one run's timing values into brittle correctness assertions.

**Behavior to preserve**

| Behavior | Baseline evidence | Live work still needed |
| --- | --- | --- |
| Manual start, stop, and a single active recording | Rust state/runtime tests pass. | Signed-app manual-control exercise. |
| Toggle and hold semantics | Rust state tests and Swift binding tests pass; user reports normal use. | Trace rapid press/release and first/last word capture. |
| Hold release does not stop a toggle recording | Rust integration test passes. | Exercise actual overlapping bindings. |
| Repeated start/stop and concurrent stop/cancel | Rust integration tests pass. | Rapid physical-key/button trials. |
| Cancel discards recording; cancel during transcription does not abort it | Rust integration tests pass. | Overlay cancel and hold-release interaction. |
| Recording cap | Rust test auto-stops using a short configured cap. | Real microphone cap and peak-memory measurement. |
| Capture readiness, startup failure, worker failure, and recovery | Rust fake-worker/integration tests pass. | Permission denial, microphone removal, and reconnection. |
| Transcription success, empty text, and recoverable errors | Rust adapter/integration tests pass. | Live provider timing on an explicitly recorded test utterance. |
| Clipboard-only, autopaste, and disabled output | Swift routing checks pass; user reports normal autopaste. | Verify all modes in the signed app. |
| Rich clipboard restore, delayed reads, manual fallback, and newer copies | Eight isolated output checks pass. | Paste into representative foreground apps. |
| Copy Last Transcript serialized with output | Existing controller uses the same output queue. | Exercise copy during an actual paste; no new test claim. |
| Custom hotkeys and UI action selection | Shared Swift assertions pass. | Physical keys, conflicting bindings, and session resume. |
| Configuration validation/model migration and Keychain operations | Rust tests pass; legacy configuration preserved. | Signed-app credential access and preference-save check. |
| Start/stop/error sounds | Decode/format/level checks pass. | Listening test and check for cues captured by microphone. |
| Sleep/wake, logout/login, and permissions | Documented current lifecycle behavior. | Dedicated live baseline session. |

**Reproduction and remaining work**

Run the checks on macOS with native pasteboard/audio access:

```bash
./scripts/check.sh
./scripts/test-swift.sh
```

Collect another independent measurement run while the installed app and daemon are idle:

```bash
./scripts/measure-baseline.sh
```

The command creates a fresh private output directory. It runs the local Rust fixture, the isolated Swift pasteboard fixture, and read-only installed-app sampling. It does not record the microphone, read Keychain, restart Voxa, modify the system clipboard, or send audio externally. Missing or busy installed-app observations are explicitly marked incomplete in the JSON report. Source changes during measurement cause a failure instead of an ambiguous comparison.

Before closing stage 1, collect actual hotkey-to-first-buffer, stop-to-upload, cold/warm startup, and peak-recording-memory measurements with an opt-in signed tracing build. First-buffer timing needs a capture marker; neither a socket response nor the recording animation is a substitute. Separate provider time from local work and use monotonic clocks with explicit cross-process clock correlation where needed. Then run the live behavior cases above and record the results and any known defects. Use the user's normal-use confirmation as the basic starting reference, not as evidence that these edge cases were already exercised.

The user-facing microphone/paste confirmation is recorded; no native backend code or process replacement has been performed. The migration plan's stage 1 gate stays open until the remaining measurements and checks are recorded.
