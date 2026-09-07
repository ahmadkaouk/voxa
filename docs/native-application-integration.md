**Stage 4: native application integration**

> Historical checkpoint report. Implementation status and retired tool commands below refer to this stage. See [stage 6](native-migration-completion.md) for the final native application; pre-removal source/tools are preserved at `881b78f`.

Implemented on `codex/swift-native-migration` after committing stage 3 as `cfefab6` on 2026-09-07. The menu bar application now runs the native Swift pipeline. The installed `/Applications/Voxa.app` and the [stage 1 rollback copy](migration-baseline.md) remain the preserved legacy build.

**Application wiring**

The popover observes the same `DictationSession` that receives manual, toggle, hold, stop, and cancel commands. AppController is reduced from 1,361 to 283 lines: setup, settings, OS lifecycle, and presentation effects. It contains no IPC transport, command queue, event sequence, config revision, reconnect loop, or daemon bootstrap. The old IPC source and tests remain until stage 6.

Session state drives the overlay, menu bar symbol, and sounds. Starting remains stoppable. Finishing, transcription, and delivery show processing; the completion check appears only after an output result that qualifies as success. Fallback messages remain visible and the last transcript can be copied. General settings and shortcut editing are disabled during an active workflow.

Recording preparation runs inside the session's `starting` state. It checks for an existing Voxa capture process, requests microphone access if necessary, reads the key on a dedicated serial worker, and checks the legacy guard again. A Stop/hold release or Cancel during a permission or Keychain prompt prevents capture after the prompt closes. Once capture has started, existing recorder startup/stop ordering still applies.

`VoxaAppDelegate` uses `applicationShouldTerminate` / `terminateLater` to await capture release and queued clipboard restoration. A pending OS authorization prompt may still need to be answered before that awaited shutdown can finish. Sleep/session interruption cancels recording and resets held shortcuts; wake and app activation refresh permissions and re-register the hotkey bridge.

**Settings and credentials**

`PreferencesStore` imports the complete old TOML document with [TOMLDecoder](https://github.com/dduan/TOMLDecoder), pinned at 0.4.5 (`a2bbd2796fe3064e107de18cb56031052c4fa899`). Its MIT notice is bundled. This dependency raises the compiler requirement to Swift 6.0; the deployment target remains macOS 13, with one app target and its existing test target.

The import preserves custom shortcut JSON strings, both old GPT-4o model aliases, output mode, recording limits, and credential-source behavior. Parsing and validation happen before any write. A single versioned UserDefaults payload (`nativePreferences.v1`) contains the settings and completed-import marker. Failed writes restore the previous value; malformed imports stay retryable. A subsequent launch reads native preferences instead of overwriting them from TOML. The original TOML is never modified.

The default import path is `~/Library/Application Support/voxa/config.toml`; `VOXA_CONFIG_PATH` overrides the initial source. `VOXA_OPENAI_TRANSCRIPTIONS_URL` continues to support a development transcription endpoint. Invalid endpoints fail without uploading; empty overrides use the production endpoint.

The native Keychain helper uses Security's SecItem APIs and the existing service `com.voxa` / account `OPENAI_API_KEY`. Lookup searches the user's Keychain search list; updating targets the exact item returned via its persistent reference, retaining its access control. This differs from the old CLI helper's explicit default-Keychain-only lookup if a user has duplicate matching items across custom keychains. The standard existing login-Keychain entry is reused. No credential is put in UserDefaults or logs.

`api_key_source = "env"` remains read-only. In Keychain mode a missing/empty entry falls back to `OPENAI_API_KEY`; an authorization failure remains an error. The menu provides retry and individual Microphone, Accessibility, and Input Monitoring recovery actions. Permission status is refreshed after returning from System Settings.

**Automated validation**

`./scripts/check.sh` passes Rust formatting/check/clippy and all 79 Rust tests, the Swift app build, 10 legacy Swift unit groups, eight clipboard integration groups, bundled sound checks, 12 native recorder groups, and 22 native pipeline/setup groups. The new coverage includes:

- Stop, hold release, Cancel, failure, retry, and shutdown during asynchronous preparation.
- Complete TOML syntax with comments, quoted keys, multiline/literal strings, Unicode, custom hotkey JSON, integer separators, and unrelated tables.
- Invalid/duplicate keys, unsupported values, conflicting shortcuts, and invalid field types rejected before persistence.
- Import-once behavior, relaunch, preserved original bytes, clean install, malformed storage, and simulated persistence failures with recovery.
- Environment-only credentials, missing-entry fallback, access denial without fallback, worker isolation, and key validation.
- Actual Security API add/read/update against a unique disposable test item; the production credential is not touched by tests.

`swift build --build-tests` also compiled and linked the XCTest target successfully. The installed Command Line Tools still lack the XCTest runner, so the shared assertions were executed through the standalone harness.

Local logs: `dist/migration-measurements/stage-4/validation.log`, `test-build.log`, and `package.log`. Fixture checks use no microphone or external API and do not change the system clipboard. The standalone harness executes the same assertions when the XCTest runner is unavailable.

**Signed candidate and live gate**

`./scripts/package-macos.sh` produced `dist/apps.noindex/Voxa.app` and `dist/Voxa.dmg`. The candidate passed deep/strict code-signature verification. Bundle ID `com.voxa.menubar`, microphone usage description, and the designated signing requirement match the installed legacy app (certificate fingerprint `356b3bedff753e8cf3fd07f1e4d7302940e40ae3`). Packaging still builds and embeds an unused daemon; native-only packaging and LaunchAgent retirement belong to stage 5.

The installed legacy app was idle, then quit for testing. A process check confirmed its daemon stopped before the signed candidate launched. The candidate initially waited for macOS Keychain authorization. On the follow-up status check, its Start dictation overlay was visible, confirming setup and credential lookup had completed. A process check identified the running native candidate and no legacy daemon. The candidate has not replaced the installed application. The legacy configuration SHA-256 remains `ef70f65ca2654d8b879d91443819e5f823509542d3aedd9922c551ae77a7a33b`, unchanged before and after native startup.

**Stage 4 gate passed — user-confirmed live dictation**

On 2026-09-07, after being asked whether a sentence transcribed and pasted correctly, the user confirmed: “I have tried it and it's working.” This records a successful live dictation through the signed native candidate, alongside the preceding process check showing no legacy daemon. The automated suite, signed build, and user-confirmed recording/transcription/output satisfy the stage 4 integration gate.

This confirmation does not establish coverage of every shortcut, cancellation, or interruption scenario. Stage 5 still needs the full manual/toggle/hold checklist, cancel and normal quit, external-device removal, permission denial/regrant, sleep/wake, long recordings, daily-use parity, performance comparison, and upgrade/rollback rehearsal. Carry the remaining [recording checks](native-recording-proof.md) forward. Do not remove the legacy source or rollback artifacts before that validation.
