# Voico Architecture (v1 Draft)

## 1) Product Goal
Build a local macOS app for personal use that converts voice to text with minimal setup.

## 2) Scope
- `v1`: terminal app with push-to-talk, sends audio to STT provider, copies transcript to clipboard.
- `v1.5`: supports both interaction styles in terminal:
  - hold-to-talk (press and hold key)
  - tap-to-start / tap-to-stop
- `v2` (later): menu bar app, same core engine.

## 3) Decisions Confirmed
- Platform: macOS only
- App mode: terminal now, menu bar later
- Trigger: hold-to-talk and tap-to-toggle
- Output target: clipboard copy
- Languages: English primary, French supported
- Data policy: no logs/history/audio persistence
- Error behavior: fail fast (no retries in v1)
- Packaging: installable binary command

## 4) Decisions Finalized

### 4.1 STT Provider (you wrote "SIT", assumed typo for STT)
What it means:
- STT provider is the external service that receives audio and returns transcript text.

Decision:
- Start with OpenAI speech-to-text API for fastest path and good multilingual quality.
- Default model is `gpt-4o-mini-transcribe`.
- Keep provider behind a trait/interface so swapping providers later is easy.

### 4.2 Transcription Mode
What "transcription mode" means:
- It defines when and how audio is sent for recognition.

Modes:
- Batch (`record -> stop -> upload -> transcript`): simplest and most reliable.
- Streaming (`capture chunks while speaking`): lower latency but more complexity.

Decision:
- Use batch mode for v1.
- Add streaming only after terminal UX is stable.

### 4.3 Config Style
Options:
- `.env` file: simplest local setup.
- macOS Keychain: better local secret storage.

Decision:
- v1 use `.env` (`OPENAI_API_KEY=...`) for speed.
- v1.1 add optional Keychain integration and prefer Keychain when available.

## 5) High-Level Architecture
- `CLI Layer`
  - Parses flags/commands.
  - Starts chosen interaction mode (`hold` or `toggle`).
- `Input Layer`
  - Captures microphone audio.
  - Stops capture based on mode/user action.
- `Audio Layer`
  - Normalizes to provider-required format (e.g., mono WAV/PCM).
- `Transcription Layer`
  - Sends audio to STT provider.
  - Returns final transcript string.
- `Output Layer`
  - Copies transcript to macOS clipboard.
- `Config Layer`
  - Loads env vars and runtime flags.
  - No persistent logs/history.

## 6) Rust Implementation Sketch

### 6.1 Candidate crates
- `tokio`: async runtime
- `clap`: CLI interface
- `cpal`: microphone capture
- `hound`: WAV writer
- `reqwest` + `serde`: HTTP + JSON
- `arboard` (or `pbcopy` shell fallback): clipboard output
- `dotenvy`: local env loading
- Later for hotkeys/global input: `rdev` or macOS-specific APIs

### 6.2 Suggested modules
- `src/main.rs`: CLI entrypoint
- `src/config.rs`: config loading/validation
- `src/audio.rs`: capture + WAV conversion
- `src/stt/mod.rs`: STT trait + provider impl
- `src/output.rs`: clipboard write
- `src/app.rs`: orchestration flow

## 7) CLI Spec (v1 Final)

### 7.1 Command Surface
- `voico toggle [--language <auto|en|fr>] [--model <model>] [--max-seconds <n>] [--output <clipboard|stdout>]`
- `voico hold [--language <auto|en|fr>] [--model <model>] [--max-seconds <n>] [--output <clipboard|stdout>]`
- `voico --help`

### 7.2 Default Behavior
- Default command mode for docs/onboarding: `toggle`
- Default model: `gpt-4o-mini-transcribe`
- Default language: `auto`
- Default max duration: `90` seconds
- Default output target: `clipboard`

### 7.3 Interaction Contract
- `toggle` mode:
  - Prompt: `Press Enter to start recording`
  - Prompt: `Press Enter again to stop`
  - On stop: transcribe and return final text
- `hold` mode:
  - Prompt: `Hold Space to record, release to stop`
  - On release: transcribe and return final text
  - If terminal key release events are not supported, show warning and recommend `toggle`

### 7.4 Output Contract
- Always print final transcript to stdout
- If output mode is `clipboard`, copy transcript to clipboard and print a confirmation line
- No auto-typing in v1

### 7.5 Error and Exit Contract
- `0`: transcription completed
- `1`: user/config/input error
- `2`: provider/network/transcription error

### 7.6 Usage Examples
- `voico toggle`
- `voico toggle --language fr`
- `voico hold --max-seconds 60`
- `voico toggle --model gpt-4o-transcribe --output stdout`

## 8) Failure Model (v1)
- Missing API key -> exit with clear message.
- Mic permission denied -> exit with remediation message.
- Network/API error -> fail current transcription and return error code.
- Empty transcript -> fail current transcription and return error code.

## 9) Privacy Model
- Audio kept in memory when possible.
- If temp file is required for provider upload, delete immediately after response.
- No history, no analytics, no telemetry.

## 10) Milestones
1. Bootstrap Rust CLI + config validation.
2. Add mic capture + manual stop.
3. Integrate STT batch transcription.
4. Add clipboard output.
5. Add dual terminal trigger modes.
6. Package as local binary command.
7. Later: migrate same core to menu bar wrapper.

## 11) v1 Decision Lock (Final)
These defaults are locked for implementation.

### 11.1 Provider + Model
- Provider: OpenAI Speech-to-Text
- Default model: `gpt-4o-mini-transcribe` (cost-first default)
- Optional model override: `gpt-4o-transcribe` (quality-first)

Reason:
- Keeps cost low for daily use while preserving a fast path to higher quality.

### 11.2 Transcription Mode
- v1 mode: batch only (`record -> stop -> upload -> transcript`)
- No partial streaming output in v1

Reason:
- Lowest complexity and most reliable for first usable release.

### 11.3 Terminal Input Behavior
- `voico toggle`: default mode
  - Press `Enter` to start
  - Press `Enter` again to stop and transcribe
- `voico hold`: secondary mode
  - Hold `Space` to record
  - Release to stop and transcribe
- If key-release events are unsupported in a terminal, print warning and suggest `toggle`.

Reason:
- Terminal key-release support can vary; `toggle` is robust everywhere.

### 11.4 Audio Format Contract
- Capture source: default input device from macOS
- Encoding for upload: WAV, mono, 16-bit PCM, target 16kHz
- Max recording duration: 90 seconds (configurable)

Reason:
- Compatible baseline for speech APIs and good enough quality for dictation.

### 11.5 Output Contract
- Always print transcript to terminal
- Copy transcript to clipboard by default
- No auto-typing in v1

Reason:
- Clipboard is stable and avoids Accessibility permission complexity in early versions.

### 11.6 Privacy Contract
- No persistent transcript storage
- No persistent audio storage
- If a temp file is needed for upload, delete immediately after request

### 11.7 Error Contract
- Fail fast for API/network/microphone errors
- No automatic retries in v1
- Exit codes:
  - `0`: success
  - `1`: user/config/input error
  - `2`: provider/network/transcription failure

## 12) Config Contract (v1)
- Source order (highest priority first):
  1. CLI flags
  2. environment variables
  3. `.env` defaults

Environment variables:
- `OPENAI_API_KEY` (required)
- `VOICO_MODEL` (optional, default `gpt-4o-mini-transcribe`)
- `VOICO_LANGUAGE` (optional, default `auto`; typical values `en`, `fr`)
- `VOICO_MAX_SECONDS` (optional, default `90`)
- `VOICO_OUTPUT` (optional, default `clipboard`; options `clipboard|stdout`)

CLI examples:
- `voico toggle --language en`
- `voico toggle --language fr --model gpt-4o-transcribe`
- `voico hold --max-seconds 60`

## 13) Architecture Notes For Menu Bar (v2 Preview)
- Keep `audio`, `stt`, `output`, and `config` modules UI-agnostic.
- Add `ui-terminal` and later `ui-menubar` as thin adapters over shared app core.
- Keep the same config contract between terminal and menu bar app.

## 14) Risks and Mitigations
- Terminal hold key may be inconsistent across terminal apps.
  - Mitigation: keep `toggle` as default and fallback path.
- Network dependency can interrupt dictation.
  - Mitigation: clear error messages and fast restart command flow.
- English/French mixed dictation may reduce punctuation quality.
  - Mitigation: allow explicit `--language en|fr` override.
- API key exposure risk in plain `.env`.
  - Mitigation: document local-only use and add Keychain support in v1.1.

## 15) Immediate Next Implementation Steps
1. Initialize Rust binary crate and CLI skeleton with `toggle` command.
2. Implement `.env` + env loading and validation.
3. Add microphone capture to WAV buffer.
4. Add OpenAI batch transcription request.
5. Print transcript + copy to clipboard.
6. Add `hold` mode with fallback warning.

## 16) Runtime State Machine (v1 Final)

### 16.1 States
- `Idle`: ready to start recording.
- `Recording`: microphone stream active, audio buffer accumulating.
- `Transcribing`: recording stopped, upload in progress.
- `Completed`: transcript received and surfaced to user.
- `Failed`: unrecoverable error in current run.

### 16.2 Events
- `StartPressed`: start signal in `toggle` mode.
- `StopPressed`: stop signal in `toggle` mode.
- `HoldPressed`: start signal in `hold` mode.
- `HoldReleased`: stop signal in `hold` mode.
- `MaxDurationReached`: recording auto-stop at configured limit.
- `AudioCaptureError`: mic/input stream failure.
- `ApiSuccess`: STT response received with transcript payload.
- `ApiError`: STT/network/auth/request failure.
- `ClipboardError`: transcript exists but clipboard write failed.

### 16.3 Transition Rules
| Current | Event | Next | Action |
|---|---|---|---|
| `Idle` | `StartPressed` | `Recording` | open mic stream, reset buffer, start timer |
| `Idle` | `HoldPressed` | `Recording` | open mic stream, reset buffer, start timer |
| `Recording` | `StopPressed` | `Transcribing` | stop stream, finalize WAV bytes |
| `Recording` | `HoldReleased` | `Transcribing` | stop stream, finalize WAV bytes |
| `Recording` | `MaxDurationReached` | `Transcribing` | stop stream, finalize WAV bytes, print duration notice |
| `Recording` | `AudioCaptureError` | `Failed` | print capture error, return exit code `1` |
| `Transcribing` | `ApiSuccess` | `Completed` | print transcript, try clipboard write |
| `Transcribing` | `ApiError` | `Failed` | print provider/network error, return exit code `2` |
| `Completed` | `ClipboardError` | `Completed` | print warning only, keep success exit code `0` |

### 16.4 Mode-Specific Mapping
- `toggle` mode emits: `StartPressed`, `StopPressed`.
- `hold` mode emits: `HoldPressed`, `HoldReleased`.
- All downstream transitions from `Recording` onward are identical in both modes.

### 16.5 Invariants
- Only one active recording session per process.
- Only one transcription request per completed recording.
- Audio buffer is cleared when entering `Completed` or `Failed`.
- No transcript or audio persistence to disk after command exit.

### 16.6 Command Lifecycle
- Each command invocation processes exactly one record/transcribe cycle, then exits.
- Repeated dictation is done by re-running the command in v1.

## 17) Error Catalog (v1 Final)

### 17.1 Format Rules
- Error lines start with `ERROR`.
- Warning lines start with `WARN`.
- Success lines start with `OK`.
- Include one short remediation line when applicable.

### 17.2 Fatal Errors (`exit 1`: user/config/input)

| Error ID | Condition | Primary Message | Remediation Message |
|---|---|---|---|
| `E_CFG_API_KEY_MISSING` | `OPENAI_API_KEY` not found in flags/env/.env | `ERROR E_CFG_API_KEY_MISSING: OPENAI_API_KEY is required.` | `Set OPENAI_API_KEY in your environment or .env file.` |
| `E_CFG_INVALID_MODEL` | `--model` or `VOICO_MODEL` empty/invalid | `ERROR E_CFG_INVALID_MODEL: model value is invalid.` | `Use gpt-4o-mini-transcribe or gpt-4o-transcribe.` |
| `E_CFG_INVALID_LANGUAGE` | unsupported language code | `ERROR E_CFG_INVALID_LANGUAGE: language must be auto, en, or fr.` | `Run voico --help for valid options.` |
| `E_CFG_INVALID_MAX_SECONDS` | non-numeric, zero, or negative max duration | `ERROR E_CFG_INVALID_MAX_SECONDS: max-seconds must be > 0.` | `Use --max-seconds <positive integer>.` |
| `E_INPUT_MODE_UNSUPPORTED` | hold mode cannot capture key-release in current terminal | `ERROR E_INPUT_MODE_UNSUPPORTED: hold mode is not supported in this terminal.` | `Use voico toggle instead.` |
| `E_AUDIO_DEVICE_UNAVAILABLE` | no input device or device open failure | `ERROR E_AUDIO_DEVICE_UNAVAILABLE: microphone input is unavailable.` | `Check input device and retry.` |
| `E_AUDIO_PERMISSION_DENIED` | macOS denies microphone permission | `ERROR E_AUDIO_PERMISSION_DENIED: microphone permission denied.` | `Allow microphone access for your terminal app in System Settings > Privacy & Security > Microphone.` |
| `E_AUDIO_CAPTURE_FAILED` | stream start/read/write callback failure | `ERROR E_AUDIO_CAPTURE_FAILED: failed while capturing audio.` | `Check microphone device status and retry.` |
| `E_AUDIO_EMPTY_BUFFER` | no usable audio frames captured | `ERROR E_AUDIO_EMPTY_BUFFER: no audio captured.` | `Speak after recording starts and retry.` |

### 17.3 Fatal Errors (`exit 2`: provider/network/transcription)

| Error ID | Condition | Primary Message | Remediation Message |
|---|---|---|---|
| `E_API_AUTH_FAILED` | invalid API key or unauthorized request | `ERROR E_API_AUTH_FAILED: authentication failed with STT provider.` | `Verify OPENAI_API_KEY and retry.` |
| `E_API_RATE_LIMITED` | provider rate limit response | `ERROR E_API_RATE_LIMITED: request was rate-limited.` | `Wait and retry.` |
| `E_API_REQUEST_FAILED` | non-auth provider error or bad request | `ERROR E_API_REQUEST_FAILED: transcription request failed.` | `Check model/language/options and retry.` |
| `E_API_NETWORK_FAILED` | DNS/TLS/connectivity/timeout failure | `ERROR E_API_NETWORK_FAILED: network error during transcription.` | `Check internet connection and retry.` |
| `E_API_RESPONSE_INVALID` | malformed response or missing transcript field | `ERROR E_API_RESPONSE_INVALID: provider response could not be parsed.` | `Retry; if persistent, switch model and re-test.` |
| `E_API_EMPTY_TRANSCRIPT` | provider returns empty transcript | `ERROR E_API_EMPTY_TRANSCRIPT: transcript is empty.` | `Retry in a quieter environment or speak longer.` |

### 17.4 Non-Fatal Warnings (`exit 0`)

| Warning ID | Condition | Primary Message | Behavior |
|---|---|---|---|
| `W_OUTPUT_CLIPBOARD_FAILED` | transcript exists but clipboard write fails | `WARN W_OUTPUT_CLIPBOARD_FAILED: transcript created but clipboard copy failed.` | Print transcript to stdout and keep `exit 0`. |
| `W_AUDIO_MAX_DURATION_REACHED` | recording auto-stops at max seconds | `WARN W_AUDIO_MAX_DURATION_REACHED: recording reached max duration and was stopped.` | Continue to transcription. |

### 17.5 Success Messages
- `OK RECORDING_STARTED`
- `OK RECORDING_STOPPED`
- `OK TRANSCRIPTION_READY`
- `OK COPIED_TO_CLIPBOARD`

### 17.6 Message Sequence Examples

Successful default flow:
```text
OK RECORDING_STARTED
OK RECORDING_STOPPED
OK TRANSCRIPTION_READY
<transcript text...>
OK COPIED_TO_CLIPBOARD
```

Mic permission denied:
```text
ERROR E_AUDIO_PERMISSION_DENIED: microphone permission denied.
Allow microphone access for your terminal app in System Settings > Privacy & Security > Microphone.
```

Clipboard failure with transcript success:
```text
OK TRANSCRIPTION_READY
<transcript text...>
WARN W_OUTPUT_CLIPBOARD_FAILED: transcript created but clipboard copy failed.
```
