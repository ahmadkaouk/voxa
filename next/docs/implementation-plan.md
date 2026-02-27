# Voico v2 Implementation Plan (Greenfield in `next/`)

## Ground Rules
- [ ] Keep all new code in `next/`.
- [ ] Keep legacy code as behavior reference only; do not import runtime modules from legacy.
- [ ] Use isolated runtime identifiers from day one:
  - [ ] New LaunchAgent label (`com.voico.v2.daemon` or equivalent).
  - [ ] New socket path (`~/Library/Application Support/voico-v2/run/daemon.sock`).
  - [ ] New config path (`~/Library/Application Support/voico-v2/config.toml`).
  - [ ] New logs path (`~/Library/Logs/voico-v2/`).
- [ ] Reserve separate hotkeys for v2 during development.

## Phase 0: Workspace Bootstrap
### Tasks
- [x] Create workspace layout:
  - [x] `next/crates/voico-core`
  - [x] `next/crates/voico-daemon`
  - [x] `next/crates/voicoctl` (optional)
  - [x] `next/apps/voico-menubar-v2`
  - [x] `next/docs`
- [x] Add top-level workspace `Cargo.toml` under `next/`.
- [x] Add minimal CI/build scripts for v2-only targets.

### Deliverables
- [x] Workspace builds with placeholder binaries and library.

### Acceptance Criteria
- [x] `cargo check --workspace` succeeds from `next/`.
- [ ] No shared runtime artifacts with legacy.

## Phase 1: Contract-First Design
### Tasks
- [x] Write `next/docs/ipc.md` with JSON request/response/event schemas.
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

## Phase 4: Menubar v2 Client Integration
### Tasks
- [x] Build Swift IPC client for request/response + event stream.
- [x] Add reconnect loop with backoff and state resync.
- [x] Replace all log parsing with IPC-driven state.
- [x] Wire listening animation to daemon events only.

### Deliverables
- [ ] Fully functional `voico-menubar-v2` driven by daemon API.

### Acceptance Criteria
- [ ] UI state remains correct across daemon restart/reconnect.
- [x] Animation state changes only from IPC events.
- [x] No CLI subprocess dependency in v2 app runtime.

## Phase 5: Config + Secrets
### Tasks
- [ ] Implement config persistence for v2 paths.
- [ ] Add API key storage in macOS Keychain.
- [ ] Keep env fallback for local dev.
- [x] Add validation for hotkey conflicts and invalid model values.

### Deliverables
- [ ] Stable config/secrets flow through daemon API.

### Acceptance Criteria
- [ ] Config updates reflect in runtime without inconsistent state.
- [ ] API key retrieval works after app/daemon restart.
- [ ] Invalid config changes return stable contract errors.

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
- [ ] Create parity checklist against legacy behavior.
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
- [ ] All parity checklist items pass.
- [ ] No P0/P1 issues open.
- [ ] Stable daily dogfooding period completed.

## Phase 8: Cutover
### Tasks
- [ ] Package v2 daemon and menubar as default path.
- [ ] Keep legacy fallback for a defined transition window.
- [ ] Add migration notes and rollback instructions.
- [ ] After soak window, remove fallback and deprecate legacy path.

### Deliverables
- [ ] v2 as primary production architecture.

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
- [ ] Menubar v2 is the main UX and is IPC-driven.
- [ ] Daemon is sole runtime authority.
- [ ] Logging is observability-only (not state transport).
- [ ] Parity with legacy behavior is documented and passed.
- [ ] Legacy path is either removed or explicitly deprecated.
