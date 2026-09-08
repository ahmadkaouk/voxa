# Voxa development

See the [README](../README.md) for installation, permissions, and everyday use,
and the [architecture guide](architecture.md) for component ownership and recovery
behavior. All commands below run from the repository root.

## Build and check

Open `Package.swift` in Xcode or use Swift 6.0+ from the command line:

```bash
swift build
swift run voxa
./scripts/check.sh
```

Quit other Voxa copies before running a development build. The check script uses
XCTest when available and otherwise runs the same assertions through standalone
harnesses. Unregistered test files fail the fallback path instead of being skipped.

Focused checks are available through `scripts/test-swift-unit.sh`,
`scripts/test-audio-recorder.sh`, `scripts/test-dictation-sounds.sh`,
`scripts/test-transcript-output.sh`, and `scripts/test-native-pipeline.sh`.
They use fixture audio and isolated pasteboards, with no microphone capture or
external API calls. The pipeline checks also exercise a disposable Keychain entry.

## Packaging and signing

`./scripts/package-macos.sh` creates a signed app under `dist/apps.noindex/`
and a distributable `dist/Voxa.dmg`. The `.noindex` directory keeps development
app copies out of macOS app search.

The packager uses `VOXA_CODESIGN_IDENTITY` when set. Otherwise, it prefers an
installed Apple Development or Developer ID Application identity. If neither is
available, it creates and reuses **Voxa Local Development** under
`~/Library/Application Support/Voxa/codesign/`.

Keep the same signing identity when replacing `/Applications/Voxa.app` so macOS
permissions can persist. Switching from an ad-hoc build to a stable identity may
require granting Accessibility and Input Monitoring again.

`./scripts/install.sh` builds and installs Voxa. To install an existing signed
candidate, use `./scripts/install.sh --app /path/to/Voxa.app`. It refuses to replace
a running destination and preserves a verified backup under
`dist/apps.noindex/backups/`. Preserve these backups before cleaning build outputs.

Test installation, backup, failed-replacement recovery, and the running-app guard
using temporary copies of a candidate and a previous signed app:

```bash
./scripts/test-install.sh dist/apps.noindex/Voxa.app /Applications/Voxa.app
```

This check does not replace or launch either supplied app.

## Development overrides

| Variable | Purpose |
| --- | --- |
| `VOXA_DIST_DIR` | Select a separate packaging output and backup directory. |
| `VOXA_INSTALL_DIR` | Change the installation directory; defaults to `/Applications`. |
| `VOXA_CODESIGN_IDENTITY` | Select the identity used to sign the app. |
| `VOXA_CONFIG_PATH` | Select the legacy TOML file imported before native settings have been saved. |
| `VOXA_OPENAI_TRANSCRIPTIONS_URL` | Override the transcription endpoint for development. |
| `OPENAI_API_KEY` | Supply a key for environment mode, or as a fallback when the Keychain item is missing. |

An imported `api_key_source = "env"` selects read-only environment mode. Native
settings and Keychain access are described in the [architecture guide](architecture.md).

## Manual checks

Build the overlay preview with `./scripts/preview-overlay.sh`, then open
`dist/apps.noindex/Voxa Overlay Preview.app`. It uses the production overlay and
sounds with simulated recording states and levels, without microphone access.

`./scripts/test-transcript-output.sh --live` opens a temporary text window to
check the actual paste shortcut, selection replacement, Unicode, and clipboard
restoration. It requires Accessibility permission for the test process and
saves/restores the system clipboard. Ordinary output checks use isolated
pasteboards and leave the system clipboard alone.
