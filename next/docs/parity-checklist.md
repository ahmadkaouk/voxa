# Voico v2 Parity Checklist

This checklist tracks behavioral parity between legacy Voico and `next/` (v2).

Legacy behavior reference:
- `/Users/ahmadkaouk/projects/voico/README.md`
- `/Users/ahmadkaouk/projects/voico/docs/daemon.md`

Protocol reference:
- `/Users/ahmadkaouk/projects/voico/next/docs/ipc.md`

Status values:
- `done`: implemented and covered by existing tests
- `pending`: not yet fully validated
- `known-gap`: intentionally or currently not matching legacy behavior

## Core Recording Flow

| ID | Behavior | Verification | Status |
|---|---|---|---|
| P-01 | Toggle hotkey: idle -> recording | daemon integration tests (`daemon_handles_basic_start_stop_flow`) | done |
| P-02 | Toggle hotkey: recording -> stop/transcribe | daemon integration tests (`daemon_handles_basic_start_stop_flow`) | done |
| P-03 | Hold hotkey: press starts recording | domain tests (`hold_press_starts_recording_from_idle`) | done |
| P-04 | Hold release stops only hold-origin sessions | domain tests (`hold_release_requests_stop_only_for_hold_origin`) | done |
| P-05 | Toggle can stop active recording regardless origin | domain tests (`toggle_press_requests_stop_idempotently`) | done |
| P-06 | Max duration auto-stops and continues flow | daemon integration tests (`max_duration_enforcement_auto_stops_recording`) | done |
| P-07 | Redundant start/stop remain idempotent | daemon integration tests (`redundant_start_and_stop_are_idempotent`) | done |

## IPC and State Consistency

| ID | Behavior | Verification | Status |
|---|---|---|---|
| P-10 | `health`, `get_state`, `start_recording`, `stop_recording` contracts stable | daemon + `voicoctl` tests | done |
| P-11 | Event stream sequence is strictly increasing | daemon integration test (`subscriber_receives_ordered_events`) | done |
| P-12 | Session-level failures do not kill daemon | daemon integration test (`daemon_stays_alive_after_transcription_failure`) | done |
| P-13 | Menubar reconnect/resync after daemon restart | manual runbook needed | pending |

## Config and Secrets

| ID | Behavior | Verification | Status |
|---|---|---|---|
| P-20 | Distinct toggle/hold hotkeys enforced | daemon integration test (`set_config_failure_does_not_mutate_existing_config`) | done |
| P-21 | Invalid model/output values rejected | daemon integration test (`set_config_rejects_unsupported_model_and_output_mode`) | done |
| P-22 | Invalid max recording value rejected | daemon integration test (`set_config_rejects_zero_max_recording_seconds_with_stable_error`) | done |
| P-23 | API key set/status works | daemon integration test (`api_key_status_reflects_set_api_key`) | done |
| P-24 | API key survives daemon restart | daemon integration test (`api_key_store_survives_daemon_restart_with_shared_store`) | done |

## Output Behavior

| ID | Behavior | Verification | Status |
|---|---|---|---|
| P-30 | Transcript is copied to clipboard on success | manual + integration check needed | pending |
| P-31 | Menubar `clipboard_autopaste` sends Cmd+V after clipboard write | code + manual verification | pending |
| P-32 | Menubar `clipboard_only` writes clipboard and does not autopaste | manual + integration check needed | pending |
| P-33 | Menubar `none` disables output side effects | manual + integration check needed | pending |

## Lifecycle and Runtime

| ID | Behavior | Verification | Status |
|---|---|---|---|
| P-40 | One daemon instance per socket path | daemon integration test (`second_daemon_start_on_same_socket_is_rejected`) | done |
| P-41 | Menubar auto-starts daemon on launch | manual runbook needed | pending |
| P-42 | Re-launching daemon remains safe (no duplicate active daemon) | manual runbook needed | pending |
| P-43 | Stale socket recovery remains correct | resilience test needed | pending |

## UI and Hotkey Integration

| ID | Behavior | Verification | Status |
|---|---|---|---|
| P-50 | Menubar hotkeys forward start/stop commands via IPC | manual check needed | pending |
| P-51 | Listening animation driven only by runtime state (`recording`/`transcribing`) | code + manual check | done |
| P-52 | No log parsing used for runtime state | architecture check | done |

## Cutover Readiness

| ID | Behavior | Verification | Status |
|---|---|---|---|
| P-60 | Packaging/install story for v2 daemon + menubar | release checklist needed | pending |
| P-61 | Rollback instructions available | docs needed | pending |
| P-62 | Legacy fallback window defined | cutover plan needed | pending |

## Execution Order

1. Add integration coverage for output modes (`P-30`, `P-32`, `P-33`).
2. Add resilience coverage for reconnect/restart and stale socket (`P-13`, `P-43`).
3. Validate lifecycle manual checks (`P-41`, `P-42`, `P-50`) and mark them done.
4. Record macOS permission runbook for autopaste (Accessibility permission for menubar process).
