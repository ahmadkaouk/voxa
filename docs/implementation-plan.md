# Voico Implementation Plan

## Ground Rules
- [ ] Keep all current code in the main workspace.
- [ ] Keep legacy code as behavior reference only; do not import runtime modules from legacy.
- [ ] Use isolated runtime identifiers from day one:
  - [ ] New LaunchAgent label (`com.voico.daemon` or equivalent).
  - [ ] New socket path (`~/Library/Application Support/voico/run/daemon.sock`).
  - [ ] New config path (`~/Library/Application Support/voico/config.toml`).
  - [ ] New logs path (`~/Library/Logs/voico/`).
- [ ] Reserve separate hotkeys during development.

## Phase 0: Workspace Bootstrap
### Tasks
- [x] Create workspace layout:
  - [x] `crates/voico-core`
  - [x] `crates/voico-daemon`
  - [x] `crates/voicoctl` (optional)
  - [x] `apps/voico-menubar`
  - [x] `docs`
- [x] Add top-level workspace `Cargo.toml`.
- [x] Add minimal CI/build scripts for current targets.

### Deliverables
- [x] Workspace builds with placeholder binaries and library.

### Acceptance Criteria
- [x] `cargo check --workspace` succeeds from the repo root.
- [ ] No shared runtime artifacts with legacy.

## Phase 1: Contract-First Design
### Tasks
- [x] Write `docs/ipc.md` with JSON request/response/event schemas.
- [x] Define protocol versioning strategy (`api_version` handshake).
- [x] Define daemon error model (stable error codes + user-safe messages).
- [x] Define event ordering and reconnect semantics.

### Deliverables
- [ ] Frozen v1 IPC spec for implementation.

### Acceptance Criteria
- [ ] Team signoff on `ipc.md` before server/client coding.
- [ ] No ambiguous command or event fields.

## Phase 2: Domain Core (`voico-core`)
### Tasks
- [x] Implement runtime state machine (`idle`, `recording`, `transcribing`, `outputting`, `error`).
- [x] Implement transition inputs (toggle/hold, stop, max-duration, failures).
- [x] Define invariants and guardrails in code.
- [x] Add deterministic unit tests per transition path.

### Deliverables
- [x] Pure domain module with zero UI/transport coupling.

### Acceptance Criteria
- [x] Tests cover toggle and hold semantics.
- [x] Stop is idempotent.
- [x] Error paths recover to `idle` when expected.

## Phase 3: Daemon Runtime + IPC Server
### Tasks
- [x] Add daemon process entrypoint (`voico-daemon`).
- [ ] Integrate adapters: hotkey, audio capture, STT, output.
- [x] Expose IPC endpoints:
  - [x] `health`
  - [x] `get_state`
  - [x] `start_recording`
  - [x] `stop_recording`
  - [x] `set_config` / `get_config`
- [x] Add event broadcast subscription channel.

### Deliverables
- [x] Headless daemon that can be controlled entirely through IPC.

### Acceptance Criteria
- [x] Manual smoke: connect client, call `get_state`, start/stop recording.
- [x] Event stream emits lifecycle events in correct order.
- [x] Daemon remains alive after session-level failures.

## Phase 4: Menubar Client Integration
### Tasks
- [x] Build Swift IPC client for request/response + event stream.
- [x] Add reconnect loop with backoff and state resync.
- [x] Replace all log parsing with IPC-driven state.
- [x] Wire listening animation to daemon events only.

### Deliverables
- [ ] Fully functional `voico-menubar` driven by daemon API.

### Acceptance Criteria
- [ ] UI state remains correct across daemon restart/reconnect.
- [x] Animation state changes only from IPC events.
- [x] No CLI subprocess dependency in app runtime.

## Phase 5: Config + Secrets
### Tasks
- [x] Implement config persistence for the current app paths.
- [x] Add API key storage in macOS Keychain.
- [x] Keep env fallback for local dev.
- [x] Add validation for hotkey conflicts and invalid model values.

### Deliverables
- [ ] Stable config/secrets flow through daemon API.

### Acceptance Criteria
- [x] Config updates reflect in runtime without inconsistent state.
- [x] API key retrieval works after app/daemon restart.
- [x] Invalid config changes return stable contract errors.

## Phase 6: Thin `voicoctl` (Optional but Recommended)
### Tasks
- [x] Implement minimal commands: `status`, `health`, `config get/set`, `start`, `stop`.
- [x] Ensure `voicoctl` uses IPC only (no direct business logic).
- [x] Add short troubleshooting docs for this tool.

### Deliverables
- [x] Lightweight internal/debug control client.

### Acceptance Criteria
- [x] Every command maps to an IPC call.
- [x] No duplicate runtime logic in `voicoctl`.

## Phase 7: Parity + Hardening
### Tasks
- [x] Create parity validation coverage against legacy behavior.
- [ ] Add integration tests:
  - [ ] hotkey hold/toggle flow
  - [ ] recording cap behavior
  - [ ] transcription error handling
  - [ ] output/autopaste fallback behavior
- [ ] Add resilience tests:
  - [ ] daemon crash/restart
  - [ ] client reconnect
  - [ ] socket stale file handling

### Deliverables
- [ ] Verified parity report and stabilization fixes.

### Acceptance Criteria
- [ ] All parity validation items pass.
- [ ] No P0/P1 issues open.
- [ ] Stable daily dogfooding period completed.

## Phase 8: Cutover
### Tasks
- [ ] Package daemon and menubar as default path.
- [ ] Keep legacy fallback for a defined transition window.
- [ ] Add migration notes and rollback instructions.
- [ ] After soak window, remove fallback and deprecate legacy path.

### Deliverables
- [ ] Current architecture as primary production architecture.

### Acceptance Criteria
- [ ] Cutover checklist complete.
- [ ] Rollback path verified before final legacy deprecation.

## Suggested Milestone Sequence
1. M1: Phase 0 + Phase 1
2. M2: Phase 2 + basic Phase 3 (`health`, `get_state`, `start/stop`)
3. M3: Full Phase 3 + Phase 4
4. M4: Phase 5 + Phase 6
5. M5: Phase 7 + Phase 8

## Definition of Done (Project)
- [ ] Menubar app is the main UX and is IPC-driven.
- [ ] Daemon is sole runtime authority.
- [ ] Logging is observability-only (not state transport).
- [ ] Parity with legacy behavior is documented and passed.
- [ ] Legacy path is either removed or explicitly deprecated.
