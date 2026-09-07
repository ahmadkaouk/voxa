# Native Swift migration: stage 6

Completed on 2026-09-07 from `881b78f` on `codex/swift-native-migration`. The user
confirmed the corrected speaking animation, expected application behavior, and
permission recovery, then explicitly requested removal of the old infrastructure.
The original several-day/100-session target was not independently counted, and
remaining performance measurements are not represented as completed.

## Final implementation

The application has one Swift target and its existing test target. One
`DictationSession` owns workflow state and directly calls `AudioRecorder`,
`TranscriptionClient`, and `TranscriptOutput`. See [architecture.md](architecture.md).

Removed:

- `voxa-core`, `voxa-daemon`, `voxactl`, and Cargo manifests/lockfile.
- The unused Swift IPC client, connection/runtime snapshots, API-key wire model,
  and old connection-based popover action resolver.
- IPC timeout and obsolete resolver tests. Native session, setup, output, meter,
  and hotkey checks remain; the removed assertions referenced unused behavior.
- Rust/IPC baseline scripts and the temporary stage 2 recorder-preview tool.
- Rust commands from the main check script and IPC sources from test runners.

The daemon design, implementation plan, and CLI/protocol docs are archived with
historical labels. The last complete source/tools revision is `881b78f`. Native
architecture and usage documentation replace them as the current entry points.
The overlay preview, native measurements, installer recovery tests, and shared
Swift behavior tests remain useful development tools.

## Upgrade and rollback preservation

Settings import, native Keychain access, permission recovery, the competing-recorder
check, and the owned LaunchAgent migration helper are retained. Those helpers
support people upgrading from an old release even after backend source is removed.
The recording pipeline, animation correction, UI, and hotkey behavior are unchanged
in this stage.

Local signed app backups, original TOML, Keychain, old LaunchAgent archive, and
ignored measurement artifacts are preserved. The old `target/` directory remains
ignored locally; stage 6 does not delete unrelated build outputs or uninstall the
user's Rust toolchain. A source cleanup is separate from machine-wide cleanup.

## Verification

The fresh source copy under `dist/stage-6/source-checkout/` contains the current
worktree changes without prior build outputs or Rust source. Validation uses a
restricted PATH with failing `cargo`, `rustc`, and `rustup` stubs. The source
manifest and logs are saved under `dist/stage-6/`.

- `./scripts/check.sh` passed from that fresh copy: app build, five hotkey groups,
  eight clipboard/output groups, sound decoding/playback-level checks, 13 recorder
  groups, and 25 native pipeline/setup/upgrade groups. No Rust command ran.
- The XCTest target compiled and linked. A temporary unregistered test file was
  rejected by the standalone discovery guard before any checks ran, then removed.
- Fresh release packaging and DMG creation passed with Rust commands blocked.
  The bundle has one executable, no helper directory, and the existing identity,
  icon, sounds, notices, and macOS 13 target. DMG checksum verification passed.
- Installer fixtures passed for clean install, signed legacy upgrade/backup,
  simulated final-move failure with restoration, and running-app refusal.
- Shell syntax, local Markdown links, and removal of obsolete Swift IPC/model
  references passed. The release binary contains no retired IPC/connection-state
  symbols. App/test/script hashes match the fresh source manifest.

XCTest is unavailable on this Command Line Tools installation, so the shared
assertions execute through standalone harnesses. Fixtures use generated audio,
intercepted/loopback HTTP, isolated pasteboards, and a disposable Keychain item;
they do not record the user or send an external transcription request.

## Installed application

After the user finished their recording, the preceding app was quit at idle and
the stage 6 bundle installed at `/Applications/Voxa.app`. The installed executable
matches `dist/stage-6/product/apps.noindex/Voxa.app` with SHA-256
`73a19adbea6f19c3dc5af43acdd834dee092ff2f48d1e44640facec94f082c48`.
The signature and designated signing requirement are unchanged, and the Start
dictation overlay is enabled. Exactly the installed native Voxa process is
running; no legacy daemon or LaunchAgent is present. The original TOML hash is
unchanged.

The installer preserved the previous signed native app at
`dist/apps.noindex/backups/pre-native-20260907T110759Z-92041/Voxa.app`, verified to
match the user-accepted meter-fix build. Earlier legacy rollback copies remain
intact. The final DMG is `dist/stage-6/product/Voxa.dmg`.

The user confirmed a successful short dictation and paste using their usual
shortcut in the installed stage 6 build, with the animation still feeling right:
“Yes, everything works.” This completes the final live check alongside the fresh
build/tests, package, upgrade/recovery, and process verification. All six migration
stages are implemented; the unmeasured exposure/performance limits above remain
part of the historical evidence rather than claims of completed measurements.

Evidence: `check.log`, `test-build.log`, `discovery-guard.log`, `package.log`,
`install-checks.log`, `dmg-verification.log`, `install-live.log`, and `installed.json`
under `dist/stage-6/`. Keep these ignored artifacts and backups when preparing a
clean checkout; they are not runtime dependencies.
