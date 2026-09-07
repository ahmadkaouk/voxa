# UI SFX — Zen

Original, unmodified Zen audio files from [UI SFX](https://uisfx.com/) by Yuki Capital.

- Source: https://github.com/romainsimon/uisfx/tree/a6958b1efd52ee2e430501ca44a5d6b174fa63e4/packages/uisfx/sounds/zen
- Upstream revision: `a6958b1efd52ee2e430501ca44a5d6b174fa63e4` (version 0.4.0)
- License: CC0-1.0; see `LICENSE-AUDIO`.
- `start.mp3`: recording begins.
- `stop.mp3`: recording ends, including cancellation.
- `error.mp3`: a runtime error occurs.

These assets are bundled for offline playback. SwiftPM copies `Sounds` into its
resource bundle; the macOS packager and overlay preview copy it into
`Contents/Resources/Sounds`. No JavaScript runtime or network access is needed.
