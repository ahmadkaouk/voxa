# Voico Architecture (v1)

## Product Goal
Build a local macOS tool for personal dictation that converts speech to text with minimal setup.

## Scope
- `v1` is a terminal command.
- Foreground commands run one cycle: record -> transcribe -> output -> exit.
- Background daemon mode keeps running and listens for a global hotkey.
- Interaction modes:
  - `toggle`: press `Enter` to start, press `Enter` again to stop.
  - `hold`: hold `Space` to record, release to stop.
- If `hold` key-release is unsupported in the current terminal, return `INPUT_MODE_UNSUPPORTED` and suggest `toggle`.
- Output behavior:
  - Always print transcript to stdout.
  - Foreground mode copies transcript to clipboard by default.
  - Daemon mode supports `clipboard` and `autopaste` output targets.
- `v2` adds a menu bar UI over the same core modules.

## Locked Decisions (v1)
- Platform: macOS only.
- Provider: OpenAI speech-to-text.
- Default model: `gpt-4o-mini-transcribe`.
- Optional model override: `gpt-4o-transcribe`.
- Transcription mode: batch only (`record -> stop -> upload -> transcript`).
- Languages: `auto`, `en`, `fr`.
- Error policy: fail fast, no automatic retries.
- Data policy: no app-managed persistence for transcripts or audio.
- Packaging: installable binary command.

## High-Level Architecture
- `CLI Layer`
  - Parses commands and flags.
  - Emits mode-specific start/stop events.
- `Input Layer`
  - Captures microphone input from the default device.
  - Starts/stops capture based on interaction mode.
- `Audio Layer`
  - Normalizes captured audio for upload format.
- `Transcription Layer`
  - Sends audio to provider and parses transcript response.
  - Encapsulates provider behind a trait/interface.
- `Output Layer`
  - Prints transcript to stdout.
  - Copies transcript to clipboard when enabled.
- `Config Layer`
  - Resolves values from CLI, environment, and `.env`.

## Rust Module Layout
Current scaffold:
- `src/main.rs`: CLI entrypoint and exit code handling.
- `src/cli.rs`: command and flag definitions.
- `src/command.rs`: shared command execution path.
- `src/config.rs`: config loading and validation.
- `src/error.rs`: app error types and printable contract messages.

Planned `v1` expansion modules:
- `src/app.rs`: orchestration and state machine wiring.
- `src/audio.rs`: capture and WAV conversion.
- `src/stt/mod.rs`: STT trait and provider implementation.
- `src/output.rs`: stdout and clipboard output.

Candidate crates:
- `tokio`
- `clap`
- `cpal`
- `hound`
- `reqwest`
- `serde`
- `arboard` (or `pbcopy` fallback)
- `dotenvy`

## CLI Contract
### Commands
- `voico toggle [--language <auto|en|fr>] [--model <model>] [--max-seconds <n>] [--output <clipboard|stdout>]`
- `voico hold [--language <auto|en|fr>] [--model <model>] [--max-seconds <n>] [--output <clipboard|stdout>]`
- `voico daemon`
- `voico service <install|uninstall|status>`
- `voico config show`
- `voico config set hotkey <right_option|cmd_space|fn>`
- `voico config set mode <toggle|hold>`
- `voico config set output <clipboard|autopaste>`
- `voico --help`

### Defaults
- Default mode for onboarding/docs: `toggle`.
- Default model: `gpt-4o-mini-transcribe`.
- Default language: `auto`.
- Default max duration: `90`.
- Default output: `clipboard`.

### Exit Codes
- `0`: transcription completed.
- `1`: user/config/input failure.
- `2`: provider/network/transcription failure.

### Examples
- `voico toggle`
- `voico toggle --language fr`
- `voico hold --max-seconds 60`
- `voico toggle --model gpt-4o-transcribe --output stdout`

## Config Contract
Source priority (highest first):
1. CLI flags
2. Environment variables
3. `.env`

Environment variables:
- `OPENAI_API_KEY` (required)
- `VOICO_MODEL` (optional, default `gpt-4o-mini-transcribe`)
- `VOICO_LANGUAGE` (optional, default `auto`)
- `VOICO_MAX_SECONDS` (optional, default `90`)
- `VOICO_OUTPUT` (optional, default `clipboard`, allowed: `clipboard|stdout`)

## Audio and Transcription Contract
- Capture source: default macOS input device.
- Upload encoding: WAV, mono, 16-bit PCM, target 16 kHz.
- Max recording duration: configurable, default `90` seconds.
- Batch flow: record -> stop -> upload -> final transcript.
- No streaming partial output in `v1`.

## Runtime State Machine
### States
- `Idle`
- `Recording`
- `Transcribing`
- `Completed`
- `Failed`

### Events
- `StartPressed`
- `StopPressed`
- `HoldPressed`
- `HoldReleased`
- `MaxDurationReached`
- `AudioCaptureError`
- `ApiSuccess`
- `ApiError`
- `ClipboardError`

### Transitions
| Current | Event | Next | Action |
|---|---|---|---|
| `Idle` | `StartPressed` | `Recording` | open stream, clear buffer, start timer |
| `Idle` | `HoldPressed` | `Recording` | open stream, clear buffer, start timer |
| `Recording` | `StopPressed` | `Transcribing` | stop stream, finalize WAV |
| `Recording` | `HoldReleased` | `Transcribing` | stop stream, finalize WAV |
| `Recording` | `MaxDurationReached` | `Transcribing` | stop stream, finalize WAV, emit warning |
| `Recording` | `AudioCaptureError` | `Failed` | emit input error, exit `1` |
| `Transcribing` | `ApiSuccess` | `Completed` | print transcript, attempt clipboard copy |
| `Transcribing` | `ApiError` | `Failed` | emit provider/network error, exit `2` |
| `Completed` | `ClipboardError` | `Completed` | emit warning, keep exit `0` |

### Invariants
- One active recording session per process.
- One transcription request per recording.
- Audio buffer cleared on `Completed` or `Failed`.
- No transcript or audio persistence by the app after command exit.

## Error Contract
### Message Format
- Error lines start with `ERROR`.
- Warning lines start with `WARN`.
- Success lines start with `OK`.
- IDs do not use one-letter type prefixes.
- Include one short remediation line when relevant.

### Fatal (`exit 1`: user/config/input)
| Error ID | Condition | Primary Message | Remediation Message |
|---|---|---|---|
| `OPENAI_API_KEY_MISSING` | `OPENAI_API_KEY` missing in env or `.env` | `ERROR OPENAI_API_KEY_MISSING: OPENAI_API_KEY is required.` | `Set OPENAI_API_KEY in your environment or .env file.` |
| `MODEL_INVALID` | model value empty/invalid | `ERROR MODEL_INVALID: model value is invalid.` | `Use gpt-4o-mini-transcribe or gpt-4o-transcribe.` |
| `LANGUAGE_INVALID` | unsupported language code | `ERROR LANGUAGE_INVALID: language must be auto, en, or fr.` | `Run voico --help for valid options.` |
| `MAX_SECONDS_INVALID` | non-numeric, zero, or negative max duration | `ERROR MAX_SECONDS_INVALID: max-seconds must be > 0.` | `Use --max-seconds <positive integer>.` |
| `OUTPUT_INVALID` | unsupported output target | `ERROR OUTPUT_INVALID: output must be clipboard or stdout.` | `Use --output <clipboard|stdout>.` |
| `INPUT_MODE_UNSUPPORTED` | `hold` mode key release unsupported | `ERROR INPUT_MODE_UNSUPPORTED: hold mode is not supported in this terminal.` | `Use voico toggle instead.` |
| `AUDIO_DEVICE_UNAVAILABLE` | no input device or device open failure | `ERROR AUDIO_DEVICE_UNAVAILABLE: microphone input is unavailable.` | `Check input device and retry.` |
| `AUDIO_PERMISSION_DENIED` | macOS microphone access denied | `ERROR AUDIO_PERMISSION_DENIED: microphone permission denied.` | `Allow microphone access for your terminal app in System Settings > Privacy & Security > Microphone.` |
| `AUDIO_CAPTURE_FAILED` | stream callback/read failure | `ERROR AUDIO_CAPTURE_FAILED: failed while capturing audio.` | `Check microphone device status and retry.` |
| `AUDIO_EMPTY_BUFFER` | no usable frames captured | `ERROR AUDIO_EMPTY_BUFFER: no audio captured.` | `Speak after recording starts and retry.` |

### Fatal (`exit 2`: provider/network/transcription)
| Error ID | Condition | Primary Message | Remediation Message |
|---|---|---|---|
| `API_AUTH_FAILED` | invalid API key or unauthorized request | `ERROR API_AUTH_FAILED: authentication failed with STT provider.` | `Verify OPENAI_API_KEY and retry.` |
| `API_RATE_LIMITED` | provider rate limit response | `ERROR API_RATE_LIMITED: request was rate-limited.` | `Wait and retry.` |
| `API_REQUEST_FAILED` | provider returns non-auth request error | `ERROR API_REQUEST_FAILED: transcription request failed.` | `Check model/language/options and retry.` |
| `API_NETWORK_FAILED` | DNS/TLS/connectivity/timeout failure | `ERROR API_NETWORK_FAILED: network error during transcription.` | `Check internet connection and retry.` |
| `API_RESPONSE_INVALID` | malformed response or missing transcript field | `ERROR API_RESPONSE_INVALID: provider response could not be parsed.` | `Retry; if persistent, switch model and re-test.` |
| `API_EMPTY_TRANSCRIPT` | provider returns empty transcript | `ERROR API_EMPTY_TRANSCRIPT: transcript is empty.` | `Retry in a quieter environment or speak longer.` |

### Non-Fatal Warnings (`exit 0`)
| Warning ID | Condition | Primary Message | Behavior |
|---|---|---|---|
| `OUTPUT_CLIPBOARD_FAILED` | transcript exists but clipboard copy fails | `WARN OUTPUT_CLIPBOARD_FAILED: transcript created but clipboard copy failed.` | Print transcript to stdout and keep `exit 0`. |
| `AUDIO_MAX_DURATION_REACHED` | recording auto-stops at max duration | `WARN AUDIO_MAX_DURATION_REACHED: recording reached max duration and was stopped.` | Continue to transcription. |

### Success IDs
- `RECORDING_STARTED`
- `RECORDING_STOPPED`
- `TRANSCRIPTION_READY`
- `COPIED_TO_CLIPBOARD`

Runtime line format:
- `OK <SUCCESS_ID>`

## Privacy Contract
- The app does not persist transcript history or audio history.
- Audio stays in memory when possible.
- If a temp file is required for upload, delete it immediately after the request completes.
- The app does not send analytics or telemetry.

## Risks and Mitigations
- Terminal key-release behavior varies by terminal:
  - Mitigation: support `toggle` mode and return explicit unsupported error for `hold`.
- Network dependency can interrupt dictation:
  - Mitigation: clear fatal errors and immediate re-run workflow.
- Mixed-language dictation may reduce punctuation quality:
  - Mitigation: allow explicit `--language en|fr`.
- `.env` key storage risk:
  - Mitigation: local-use guidance; add optional Keychain support in `v1.1`.

## Implementation Milestones
1. Initialize Rust binary crate with CLI skeleton.
2. Implement config loading and validation.
3. Implement microphone capture and WAV normalization.
4. Implement OpenAI batch transcription integration.
5. Implement stdout and clipboard output.
6. Implement `hold` mode and unsupported-terminal handling.
7. Package as local binary command.
8. Add background daemon mode with global hotkey and LaunchAgent service controls.
9. Add a macOS menu bar controller app over existing daemon/config/service commands.

## v2 Menu Bar Preview
- Keep `audio`, `stt`, `output`, and `config` UI-agnostic.
- Add `ui-terminal` and `ui-menubar` adapters over shared app core.
- Preserve the same config contract across terminal and menu bar UIs.
