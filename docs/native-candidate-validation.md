**Stage 5: native candidate validation**

Started on 2026-09-07 after committing the user-tested stage 4 integration as `b054c4f` on `codex/swift-native-migration`. Native-only packaging, safe upgrade handling, installer recovery, and local fixture measurements are implemented. The user confirmed legacy rollback dictation, and the native candidate is now installed in `/Applications`, with real LaunchAgent retirement and relaunch verified. Stage 5 acceptance remains open for the broader behavior/hardware checklist and multi-day use. Stage 6 removal has not started.

**Native package and installation**

`package-macos.sh` now builds only the Swift app in a fresh SwiftPM scratch directory, signs one executable, and preserves the icon, sounds, licenses, bundle ID, microphone description, and macOS 13 deployment target. `verify-native-bundle.sh` checks the signature, required resources, and that the bundle contains exactly one Mach-O executable and no legacy helper directory.

The candidate was built with `cargo` and `rustc` deliberately replaced on PATH by commands that fail. The fresh native build and DMG creation succeeded. This verifies that packaging does not invoke Rust; the full repository regression script still runs the retained Rust tests until stage 6.

The stage 5 artifacts are `dist/native-candidate/apps.noindex/Voxa.app` and `dist/native-candidate/Voxa.dmg`. This separate output preserves the previous development candidate. `VOXA_DIST_DIR` selects an output directory, and packaging refuses to replace a running candidate's bundle. This is a build-path option, not a runtime backend choice.

`install.sh` now installs the native app. It can build/sign first or accept `--app /path/to/Voxa.app`. It verifies a staged copy, archives and verifies the existing signed app, then replaces it with moves on the installation volume. Failed replacement restores the previous app. It refuses to replace a running destination. `VOXA_INSTALL_DIR` supports isolated installation tests; the default is `/Applications`. Installation does not launch the app or modify its config or Keychain.

**Retiring the old LaunchAgent**

During setup, the native app first checks that no other Voxa app, Recorder Preview, or user-owned `voxa-daemon` process is active. It does not infer that a live orphan daemon is idle or force-stop it. Quit the older app and let it stop capture; if an orphan remains, finish any dictation and stop the old service before retrying setup.

Once stopped, the helper validates the exact per-user `~/Library/LaunchAgents/com.voxa.daemon.plist`: regular file, current-user ownership, size bound, expected label, and a recognized daemon executable without extra commands. It unregisters only `gui/<uid>/com.voxa.daemon`, verifies the registration and process are gone, checks that the plist has not changed, then moves the plist into `~/Library/Application Support/voxa/migration/` for preservation. Existing TOML, Keychain, logs, binaries, and unrelated LaunchAgents are retained. Failed or unrecognized migrations keep native capture disabled with a retryable error.

The migration helper uses no IPC. It remains after stage 6 to support upgrades from older installations. A rollback can recreate its LaunchAgent, and a subsequent native launch can retire it again.

**Checks completed**

- Full `./scripts/check.sh`: formatting, Cargo check/clippy, all 79 Rust tests, Swift app build, 10 legacy unit groups, eight clipboard groups, sound checks, 12 recorder groups, and 25 native pipeline/setup/upgrade groups passed.
- XCTest target compiled and linked with `swift build --build-tests`; shared assertions ran through the Command Line Tools standalone harness.
- Upgrade fixtures passed for owned-job unregister/archive, repeated startup, recreated rollback registrations, clean install, active-recorder blocking, unknown/foreign-owned/symlink plists, command failures, and concurrent changes. These fixtures never operate a real LaunchAgent.
- Installer checks passed in temporary directories: fresh install, signed legacy replacement and verified backup, simulated final-rename failure with rollback, and refusal to replace a running destination. The test path contains spaces and is normalized through macOS's `/var` → `/private/var` mapping.
- An accelerated one-hour encoder test reached the 3,600-second cap, rejected extra input, and produced exactly 115,200,044 WAV bytes. It took 2.574 seconds and peaked at 233.25 MiB process RSS. This measures the encoder harness and frameworks, including PCM/WAV data at finish; it is not an hour-long microphone run or full-app upload memory measurement.

**Exploratory performance comparison**

Thirty samples per metric after three warmups, optimized native Swift, on the same Mac as stage 1. Upload used the exact saved stage 1 WAV, a dummy credential, and a loopback server with a 50 ms response delay. Output used an isolated pasteboard with simulated consumption and the same 500 ms settling behavior. No real microphone, system clipboard, production key, or external API was used.

| Metric | Stage 1 median / p95 | Native median / p95 |
| --- | --- | --- |
| Convert 10 seconds of synthetic 48 kHz stereo audio | 1.231 / 1.753 ms | 7.165 / 7.388 ms |
| Loopback upload and response, including 50 ms delay | 58.081 / 61.363 ms | 58.009 / 60.163 ms |
| Pasteboard read and restoration | 505.495 / 507.414 ms | 506.662 / 507.690 ms |

Upload and output are close in these fixtures. Native conversion is slower in total CPU time; it also meters audio and uses AVAudioConverter's high-quality resampler, while the Rust fixture uses a different conversion algorithm. Native conversion is streamed on the capture worker during recording. The fixture's approximately 7 ms of work per 10 seconds of audio must not be presented as 7 ms of Stop latency or an end-to-end regression. This run does not establish a dictation speedup.

Limitations: conversion inputs have the same rate/channel count/amplitude but are not bit-identical; the native fixture repeats a short generated tone buffer. The loopback server implementations differ (Python here, mockito in stage 1). End-to-end capture/stop/startup timing and full-app idle/peak resource comparisons remain open because the corresponding baseline measurements were incomplete. No predeclared end-to-end regression budget was available for this exploratory comparison; do not treat it as release certification.

Raw evidence is under `dist/migration-measurements/stage-5/`: `validation.log`, `test-build.log`, `package.log`, `install-checks.log`, `candidate.json`, `long-encoding.json`, and `fixtures/` (raw samples, summaries, source hashes, binary/fixture hashes, and environment provenance).

**Live validation status**

The preserved installed legacy app was found running again and showed its idle Start dictation overlay. A process check identified `/Applications/Voxa.app` and its bundled daemon. On 2026-09-07 the user confirmed the rollback sentence transcribed and pasted, and authorized replacing the installed app. The development copy launched during earlier inspection correctly blocked setup while legacy Voxa was active and was closed without recording.

After the user finished an active recording, legacy Voxa was quit at idle and both app and daemon were confirmed stopped. `install.sh --app` replaced `/Applications/Voxa.app` with the signed stage 5 candidate. The installer preserved another verified legacy copy at `dist/apps.noindex/backups/pre-native-20260907T101528Z-86309/Voxa.app`; the original stage 1 rollback copy also remains intact. Installed and candidate executable hashes match (`35e1138c906b358e7bed34f149b777d1e985fff9cd68bd075b7cb14ef03f7ce8`), and both installed and backup signatures pass strict verification.

Native startup reached the enabled Start dictation overlay and retired the actual `com.voxa.daemon` registration. Its plist was moved, byte-for-byte intact, to `~/Library/Application Support/voxa/migration/legacy-daemon-B150F4D7-F017-4C9F-AF4A-E3C2F67C92B8.plist`. The original TOML hash is unchanged. A native quit left no Voxa app or daemon process; the read-only microphone probe reported `running_somewhere=false`. Relaunch reached the ready overlay with exactly the installed native Voxa process, no daemon, and no remaining legacy LaunchAgent registration.

This verifies installation, startup, retirement, idle quit, and relaunch. A fresh dictated sentence in this installed stage 5 bundle has not yet been checked; the stage 4 live sentence and user-confirmed legacy rollback are separate evidence. Permission denial/recovery, broader output/capture behavior, and multi-day use remain below. Local evidence is saved in `install-live.log`, `live-upgrade-before.json`, `live-native-quit.json`, and `live-upgrade-after.json` alongside the candidate measurements.

**Remaining acceptance checks**

Meter regression follow-up (2026-09-07): the user reported shorter speaking-animation bars in the native candidate. The overlay drawing was unchanged, but the native encoder exposed raw RMS instead of the legacy speech/peak boost and attack/release smoothing. The Swift meter now restores those calculations over the input channels without changing captured PCM. A regression fixture failed before the fix and passes against reference levels generated by the retained Rust implementation; all 13 recorder and 25 native pipeline groups pass. This fixture also checks exact unamplified WAV samples. Live visual confirmation of the corrected meter remains pending.

The corrected signed build from `dist/meter-fix/apps.noindex/Voxa.app` replaced `/Applications/Voxa.app` and was observed running in the Listening state. Its executable SHA-256 is `3d4fe6a9f04b6f7a50167afd0c519952348b59592415baac0a5aa83eb1eb2b33`; the installed hash matches the candidate, the designated signing requirement is unchanged, and no daemon is running. The preceding native app is preserved at `dist/apps.noindex/backups/pre-native-20260907T103123Z-88828/Voxa.app`. Checks, build/install logs, reference levels, and source/binary hashes are saved under `dist/meter-fix/`. Earlier stage 5 measurements above describe the original candidate.

| Check | Status |
| --- | --- |
| Signed native package and fresh build without Rust commands | Passed |
| Isolated clean install, upgrade backup, and failed-install recovery | Passed |
| Real legacy restart and rollback dictation | Passed; user confirmed transcription and paste |
| Installed native upgrade, real LaunchAgent retirement, idle quit/relaunch | Passed; native ready, daemon absent, original plist archived and TOML unchanged |
| Manual, toggle, hold; rapid release/cancel; all three output modes; Copy Last Transcript | Full native candidate checklist pending |
| Microphone/Accessibility/Input Monitoring denial and recovery; external device/removal; sleep/wake | Pending |
| Real long recordings, sound leakage/clipped words, peak upload memory | Pending; accelerated encoder cap passed |
| Comparable capture/stop/startup timings and full-app idle resources | Pending |
| Several days and at least 100 representative native sessions | Not yet counted for this candidate |
| Rollback recording with original TOML/Keychain, then restore native candidate | Legacy dictation confirmed; native candidate restored and ready; post-install native sentence pending |

Keep a simple daily record of session counts by manual/toggle/hold, cancel/output coverage, and any failures—no transcript or credential content. Do not count a confirmed stage 4 sentence as evidence for 100 stage 5 sessions. Require no unresolved lost transcript, duplicate output, retained microphone, or destructive clipboard regression before stage 6.

**Reproducing local checks**

```bash
./scripts/test-swift.sh
VOXA_DIST_DIR="$PWD/dist/native-candidate" ./scripts/package-macos.sh
./scripts/native-validation/test-install.sh \
  "$PWD/dist/native-candidate/apps.noindex/Voxa.app" \
  "$PWD/dist/apps.noindex/backups/migration-20260906T062128Z/Voxa.app"
python3 scripts/native-validation/measure.py /tmp/voxa-native-measurements \
  --fixture dist/migration-measurements/stage-1/fixture.wav
./scripts/native-validation/test-long-encoding.sh /tmp/voxa-long-encoding.json
```

Use a new empty measurement directory for each run. Preserve the ignored `dist` rollback artifacts before cleaning build outputs.
