# Voico Improvement Backlog

This file tracks future improvements we may implement.

## Accuracy and Latency

- [ ] Add adaptive language hinting (single-pass flow):
  - transcribe with auto
  - detect language from transcript locally
  - use detected language as hint for the next utterance
- [ ] Add two-pass language detection mode (higher accuracy):
  - pass 1: detect language
  - pass 2: transcribe with explicit language
- [ ] Add confidence threshold + fallback:
  - if language detection confidence is low, keep auto

## Recording and Input

- [ ] Add a short pre-stop grace window for hotkey toggle to reduce accidental stop.
- [ ] Add optional audible start/stop cues for recording.
- [ ] Add optional silence auto-stop (only if user asks for it).

## Daemon and Hotkey

- [ ] Simplify `src/daemon.rs` state handling (flatten start/stop/session transitions).
- [ ] Simplify `src/hotkey.rs` matcher logic while keeping current behavior.
- [ ] Add daemon integration tests for start/stop/session completion flow.

## Output

- [ ] Improve autopaste reliability with retry/backoff on failed synthetic key events.
- [ ] Add optional output mode: copy only when transcript is non-empty/non-whitespace.

## Docs and DX

- [ ] Keep CLI docs in sync with actual flags/commands via a generated help snapshot test.
- [ ] Add a short troubleshooting doc for mic/accessibility permissions and common failures.
