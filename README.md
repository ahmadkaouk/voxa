# Voxa

**Dictate on your Mac. Improve your English as you go.**

Voxa turns your voice into text in the app you’re using. Press a shortcut, speak,
and paste your words into messages, emails, notes, and more. Optional English
coaching helps you learn from what you say while you work.

## Speak instead of typing

- **Dictate from any app.** Start and stop with a customizable shortcut or the
  floating recording bar.
- **Put your words where you need them.** Paste into the active app, copy to the
  clipboard, or copy the result later. Automatic pasting restores your previous
  clipboard when safe.
- **Finish and send.** Use a separate shortcut to paste and press Return in the
  same app—handy for sending a message.
- **Stay in your flow.** Voxa lives in the menu bar, with a small recording bar
  and audio cues to keep you informed.

## Learn from your everyday English

Turn on **English coaching** to get feedback after dictation. Your words are
pasted as dictated; suggestions appear separately for you to review.

- **Understand corrections.** See what changed and why.
- **Find natural ways to say it.** Explore alternatives and reusable expressions,
  even when your grammar is already correct.
- **Make it stick.** Save useful lessons, practise by speaking or typing, and
  revisit them in a one-minute review.
- **Follow your progress.** Notice recurring patterns and see how your English
  expression develops over time. Level estimates are experimental.

<img src="assets/screenshots/english-feedback.png" alt="Voxa English feedback showing a past-tense correction, its explanation, an optional alternative, and actions to practise or save the lesson" width="542">

*Voxa’s feedback panel, shown with sample text.*
[See a practice example](assets/screenshots/english-practice.png).

Enable it in **Voxa Settings → English Learning → Feedback after dictation**.

## Get started

You’ll need **macOS 13 or later**, an **OpenAI API key**, and an internet connection.
OpenAI API usage is billed separately.

Voxa currently installs from source and requires Swift 6.0+ developer tools.
Follow the [installation guide](docs/usage.md#install), then:

1. Open **Voxa Settings…** from the menu bar and save your OpenAI API key.
2. Allow **Microphone**, **Accessibility**, and **Input Monitoring** when prompted.
3. Focus a text field, press **Option + F**, speak, and press it again to paste.

## Your data

Audio is sent to OpenAI for transcription. English coaching is off by default;
when enabled, it also sends your dictated text for feedback, with additional API
usage. Optional nearby-text context sends an excerpt from the active app to help
feedback fit what you’re working on.

Your API key is stored in macOS Keychain. Voxa doesn’t save an audio or full-dictation
history to disk; saved lessons and learning progress stay on your Mac.
[Usage and privacy details](docs/usage.md#audio-and-data).

---

[User guide](docs/usage.md) · [Development](docs/development.md) ·
[Architecture](docs/architecture.md) · [MIT License](LICENSE)

Bundled sounds are [CC0](Sources/Voxa/Resources/Sounds/Zen/LICENSE-AUDIO).
