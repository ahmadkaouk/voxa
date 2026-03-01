# Voico Architecture

## Goals
- Keep the product simple: one reliable dictation app for macOS.
- Make the menu bar app the primary UX.
- Keep backend behavior deterministic and testable.
- Avoid duplicate logic across UI surfaces.

## Product Surfaces
- `voico-menubar` (primary): user-facing control and status UI.
- `voico-daemon` (core): always-on runtime for hotkeys, recording, transcription, output.
- `voicoctl` (optional/internal): thin troubleshooting client for support/dev/CI.

`voicoctl` is intentionally minimal and not the main user experience.

## Current System Architecture
Daemon-first, API-first architecture:

1. One daemon process owns runtime state and executes all recording/transcription work.
2. Clients (menu bar app, optional `voicoctl`) communicate with daemon over local IPC.
3. Logs are observability only, never an app control channel.
4. Shared domain logic lives in backend core, not in clients.

## Packaging Strategy
Use module boundaries first, crate boundaries second.

- Start with one backend library crate (`voico-core`) that contains domain, app, infra, and IPC modules.
- Add small binary crates for process entrypoints (`voico-daemon`, optional `voicoctl`).
- Split `voico-core` into multiple crates only when there is a concrete need:
  - dependency isolation
  - reuse outside this repo
  - separate ownership/release cadence

## Component Model
### 1) Clients
- `voico-menubar`
  - UI only.
  - Sends commands over IPC.
  - Subscribes to daemon events for live state.
- `voicoctl` (optional)
  - Small commands like `status`, `config get/set`, `health`, `logs`.
  - Uses the same IPC API as menu bar.

### 2) Daemon App Layer
- Request handlers:
  - `get_state`
  - `start_recording`
  - `stop_recording`
  - `set_hotkeys`
  - `set_output_mode`
  - `set_model`
  - `health`
- Event broadcaster:
  - Pushes runtime events to subscribed clients.

### 3) Domain Core
- Explicit state machine and invariants.
- Session lifecycle and transition rules.
- Error taxonomy mapped to user-facing messages.

### 4) Infrastructure Adapters
- `audio` adapter (mic capture + WAV normalization).
- `stt` adapter (OpenAI transcription).
- `hotkey` adapter (global key listener).
- `output` adapter (clipboard + autopaste).
- `storage` adapter (config + state snapshots).
- `launchd` adapter (install/uninstall/status).

## Runtime State Model
Primary states:
- `idle`
- `recording`
- `transcribing`
- `outputting`
- `error`

Core events:
- `toggle_pressed`
- `hold_pressed`
- `hold_released`
- `max_duration_reached`
- `recording_failed`
- `transcription_succeeded`
- `transcription_failed`
- `output_succeeded`
- `output_failed`

Required invariants:
- Exactly one active session at a time.
- Stop request is idempotent.
- State transitions are serialized (single writer model).
- UI state comes from daemon events/state snapshot, not local guesses.

## IPC Contract (Local Only)
Transport:
- Unix domain socket at app-support runtime path (for example `~/Library/Application Support/voico/run/daemon.sock`).

Protocol:
- JSON messages.
- Request/response for commands.
- Subscription stream for daemon events.

Message types:
- Requests: `get_state`, `command`, `set_config`, `health`.
- Responses: `ok`, `error`.
- Events: `state_changed`, `recording_started`, `recording_stopped`, `transcribing_started`, `transcription_ready`, `output_done`, `warning`, `error`.

Versioning:
- Include `api_version` in handshake.
- Backward-compatible additive changes by default.

## Data and Storage
Config:
- Path: `~/Library/Application Support/voico/config.toml`.
- Includes hotkeys, model, output behavior, limits.

Secrets:
- OpenAI API key in macOS Keychain (preferred).
- Environment variable fallback for development.

Runtime state:
- In-memory in daemon.
- Optional atomic state snapshot file only for crash recovery diagnostics, not primary UI sync.

Logs:
- Keep structured logs (`info`, `warn`, `error`) for observability.
- Do not parse logs for product state.

## Security and Privacy
- IPC socket permissions restricted to current user.
- No transcript/audio history persistence by default.
- Temporary audio files avoided; if needed, delete immediately after request.
- No telemetry by default.

## Failure Strategy
- Daemon remains alive after session-level failures.
- Error reported as event + recoverable state transition back to `idle`.
- Client reconnect strategy:
  - exponential backoff
  - re-issue `get_state` on reconnect
  - resume event subscription

## Testing Strategy
- Domain tests:
  - transition correctness
  - invariants
  - hold/toggle behavior
- Adapter tests:
  - provider mapping
  - output failures
  - config read/write
- IPC integration tests:
  - request/response contract
  - event ordering and reconnect behavior
- End-to-end smoke:
  - launch daemon
  - trigger start/stop
  - assert state and expected output events

## Repository Shape (Target)
```text
apps/
  voico-menubar/
crates/
  voico-core/                # library crate
    src/
      domain/                # state machine + domain types
      app/                   # use-cases/orchestration
      infra/                 # audio, stt, output, hotkey, storage, launchd
      ipc/                   # protocol and server/client primitives
  voico-daemon/              # daemon binary crate
  voicoctl/                  # optional thin client binary crate
```

Keep this flat and simple; prefer internal modules over many crates.

## Migration Plan
1. Introduce IPC server in current daemon process.
2. Add `get_state` + event subscription endpoints.
3. Move menu bar app from CLI subprocess calls to IPC client calls.
4. Replace log-based UI status with event-driven status.
5. Shrink CLI into optional `voicoctl` thin client using IPC.
6. Move API key storage from env-first to Keychain-first.
7. Remove legacy code paths that rely on parsing stdout/logs for state.
8. Re-evaluate crate splits only after real pressure appears.

## Non-Goals (For Now)
- Multi-device sync.
- Cloud transcript history.
- Multi-user service mode.
- Complex plugin systems.

## Decision Summary
- Keep daemon as the single runtime authority.
- Keep menu bar app thin and reactive.
- Keep CLI minimal and optional.
- Prefer simple local IPC over layered indirection.
