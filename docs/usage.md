# Voxa user guide

See the [README](../README.md) for a quick introduction to Voxa.

## Get started

Voxa is currently built from source. You'll need:

- **macOS 13 or later.**
- **Swift 6.0 or later**, provided by Xcode or the Xcode Command Line Tools.
- **An OpenAI API key and an internet connection** for transcription.

Check your compiler with `swift --version`. If the developer tools are missing,
install them with `xcode-select --install`.

### Install

```bash
git clone https://github.com/ahmadkaouk/voxa.git
cd voxa
./scripts/install.sh
open /Applications/Voxa.app
```

The installer builds and signs Voxa, installs it in `/Applications`, and creates
`dist/Voxa.dmg`. When updating an existing installation, finish your dictation
and quit Voxa first. The installer preserves a signed backup of the previous app.

### Set up Voxa

1. Open Voxa from the menu bar and choose **Settings… → API Key**. Save your OpenAI API
   key; Voxa stores it in macOS Keychain.
2. Open **Settings → General** and allow the permissions needed for the features you use:

   | Permission | Used for |
   | --- | --- |
   | Microphone | Recording your voice |
   | Accessibility | Pasting into another app; reading nearby text when automatic context is enabled |
   | Input Monitoring | Recognizing global shortcuts |

3. Focus a text field, press **Option + F**, and speak. Press it again to
   transcribe and paste your words.

In **General**, choose **Allow…** to respond to the first microphone prompt, or
**Open Settings…** to enable access in macOS System Settings. **Manage…** opens
permissions you have already enabled. Return to Voxa after making changes.
Missing permissions also have **Enable…** actions in Voxa's menu.

## Using Voxa

### Recording controls

| Action | Default control |
| --- | --- |
| Start / Stop | Press **Option + F** to start; press again to finish and paste |
| Record with the mouse | Choose Start Recording in the Voxa menu, then click the stop square on the bar to finish |
| Finish & Send | Press **Option + G** while recording in Autopaste mode |
| Discard a recording | Press **Esc** while recording (also cancels microphone startup) |

Choose the transcription model, output mode, and recording limit directly from
the menu bar's **Model**, **Output**, and **Max Recording** menus. Feedback and
nearby-text switches are under **English Learning**. Missing permissions have
**Enable…** actions in the menu bar that open macOS System Settings.

Settings contains **General** for permissions, **Shortcuts**, **Privacy**, and **API Key**.
Change shortcuts in **Settings… → Shortcuts**.
Click the displayed key combination to record a replacement; release the keys to save.
Start / Stop, Finish & Send, Save feedback and Cancel / Close are configurable.
Shortcuts cannot overlap. Save feedback requires a modifier and one key;
Cancel / Close accepts Escape or a modifier and one key.
Press **Esc** while capturing a shortcut to cancel without closing Settings,
or click the same control again. When editing Cancel / Close, Escape assigns Escape.
**Max Recording** sets the recording limit; the default is five minutes. Transcription begins after
recording finishes. Discarding a recording skips transcription and output.

The recording orb appears at the bottom center of the screen, above the Dock.
While you speak it is a small Liquid Glass circle with a red ring, a five-bar waveform and a
glow that follows your voice. Point at it and it opens into **×** on the left, the elapsed
time, and a red stop button on the right. The stop button finishes and inserts the text; **×** discards
the recording. Transcribing shows a turning ring and stays visible through text insertion. Once text is pasted or copied,
the orb goes directly to feedback or disappears, without a completion confirmation. If English
feedback is still being analysed after delivery, the orb shows three pulsing dots.
When ready, the full feedback popup opens above the Dock, aligned with the orb's bottom edge.

The orb uses clear native Liquid Glass on macOS 26 and later,
with translucent material on older systems.
Its controls adapt to the system appearance; Reduce Transparency and Increase Contrast use a solid surface.
Feedback follows the system appearance:
white in light mode and charcoal in dark mode, with green accents. Drag the orb to move it;
drag the feedback header to move the popup. Voxa remembers the shared position across recordings and app restarts.
Feedback grows to
fit its contents up to a screen-safe height; longer content remains scrollable without
visible scroll indicators. Click a fix to open its explanation and other ways to say it
directly below that fix. The popup grows upward from its bottom edge as you
open an explanation. Reduced Motion removes continuous
waveform motion. Increased Contrast strengthens the outline and secondary text.

Model, output, and recording-limit menus remain available during dictation.
Changes made while recording or processing are saved for the next recording.

**Finish & Send** finishes recording, pastes, and sends Return to the same app. This submits
in chat apps and inserts a newline in editors. It requires Accessibility access
and is skipped if you switch apps. Plain Enter keeps its normal behavior in the app
you’re using. Other finish controls paste without pressing Return. Finish & Send
needs one key plus a modifier and cannot overlap Start / Stop.

### Choose where text goes

Select a mode under **Output**:

| Mode | Behavior |
| --- | --- |
| **Autopaste (Keep Clipboard)** | Pastes into the active app and restores the previous clipboard when safe. This is the default. |
| **Clipboard Only** | Replaces the clipboard with the transcript for you to paste. |
| **None** | Keeps the latest transcript in memory without automatically copying or pasting it. |

If automatic pasting doesn't work in a particular app, use **Output → Copy Last
Transcript** and paste manually. The latest transcript remains available until
you replace it with another dictation or quit Voxa.

## Audio and data

### English learning

Enable **English Learning → English feedback** in the menu bar for
background English coaching. Dictation is inserted normally and never rewritten;
feedback failures do not interrupt it.

Feedback covers your English only: grammar, word choice and natural phrasing. It never
judges or completes what you explain, and it keeps technical terms as you said them.
The review is built to read in a few seconds:

- The title counts the top fixes (at most four) and how many you've made before.
- Each fix is one **You said → Better** row. Unchanged words are grey, wrong words are
  struck through in red, and better words are bold green. A mistake you've made in
  earlier reviews carries a small amber **4th time** badge.
- Click a row for a one-line reason in plain words and, for important fixes, two or
  three other ways to say it, each labelled (“more precise”, “casual, shorter”).
- **+ N smaller fixes** shows the rest, most important first.
- Words that speech recognition probably misheard (for example “O and squared” for
  “O of n squared”) appear in one grey **Not counted** line, never as mistakes.
- **Said more naturally** sits beside the fixes and rewrites the whole dictation the way a
  fluent speaker would say it out loud: same ideas, same order, rewritten from scratch where
  needed. Opening a fix never pushes it out of view. **Compare** (⌘D) shows each of your
  sentences struck through above its natural version; **Clean** switches back.
- The footer says how many fixes **Got it** saves to your lessons.
  **Listen** reads the natural version with the system voice, on this Mac.

A dictation with no mistakes still gets a review when the natural version differs, and
none when it is already natural. Reviews are 460 points wide, follow the system light or
dark appearance, and grow before scrolling while the footer stays visible.

The panel appears after delivery without taking focus and stays open until you close
or save it. It has no countdown and does not disappear when you move the pointer or
click elsewhere. Starting a new recording hides the current review; **English Learning →
Show Latest Feedback** reopens an available review until another transcript replaces it.
A failed save keeps the review open for retry.

- **Got it / ⌘S:** save the fixes as lessons, then close. Misheard words are excluded.
  ⌘S also closes a review with nothing to save.
- **Close / Esc:** close without saving lessons. Local progress remains available.
- **Compare / ⌘D:** show or hide the sentence-by-sentence comparison. It only acts while
  a review with a natural version is open.

These are the default shortcuts. Customize them in **Settings → Shortcuts**;
the feedback buttons show your current combinations. Click a combination, press
the new keys, and release them to save. Escape can be assigned to Cancel / Close.

- **English Learning → Lessons & Progress…:** see the mistakes you repeat, review,
  practise or delete saved fixes, and clear the mistake history separately.
- **Practice this** on a saved fix or a repeated mistake: say the improved version, then try the pattern in a
  new sentence. Use **Record answer → Stop & check**, or **Type instead**. Recording
  stops automatically at 40 seconds. Each answer gets one short response about the
  target pattern. Practice never pastes or changes the last dictation. An unsaved
  review stays available while you practise.
- **English Learning → One-minute Review…:** revisit up to three due patterns
  from saved lessons, with recurring grammar errors first. Examples stay hidden until
  requested. Skip freely; no reminders or daily requirements. New examples must use
  the pattern, not simply repeat the supplied wording.

Successful reviews return after 1, 3, 7, 14 and then 30 days. A retry brings the pattern
back the next day; immediate repeats do not advance the interval. Recognition
uncertainty and skipped exercises do not count as mistakes. Practice is kept separate
from the mistake history.

Progress tracks up to 200 recent reviews automatically while feedback is enabled.
Repeated mistakes are counted by category, once per review; the counts are not a
mastery percentage.

The English Learning window uses the same You said → Better rows as the review. Switch
pages at the top of the window:

- **Repeat mistakes:** what you keep getting wrong, most repeated first, with your latest
  saved example and how many reviews it came up in. Click a row for the reason, other
  ways to say it, earlier examples and **Practice this**.
- **Saved fixes:** every fix you kept with **Got it**, newest first. Click one for its
  reason, alternatives, **Practice this** and **Delete**. The search field matches
  wording, reasons and categories, and opens this page.
- **Practice:** start the one-minute review and see which fixes are due next.

**More** in the toolbar deletes all saved fixes or clears the mistake history.

Settings also has a sidebar search. Search for a page or a control, such as
“excluded apps”, “shortcuts” or “Keychain”, then choose the matching page.

A failed save keeps the review open. While feedback is visible, ⌘S saves it,
Esc closes it and ⌘D toggles the comparison. During recording, Esc discards the recording before transcription
and output. Outside these contexts, the shortcuts pass through normally. Plain
S and D always type normally. Global shortcuts require Accessibility access.

Feedback is off by default. Enabling it sends transcript text in an additional
OpenAI request using the same API key, with additional usage cost. It uses
`gpt-6-luna` with low reasoning effort and requests `store: false`, which does
not guarantee zero provider retention; see [OpenAI data controls](https://developers.openai.com/api/docs/guides/your-data).
Only accepted excerpts, suggestions, explanations, dates, and practice prompts
are stored in `~/Library/Application Support/Voxa/corrections.json`. Automatic
progress stores only review IDs, dates and mistake categories in
`~/Library/Application Support/Voxa/learning-progress.json`. Older files that also hold
scores and levels still load; those fields are ignored. Only category IDs, not saved lesson excerpts,
are reused from learning history for later dictation feedback. Explicit practice sends the
selected lesson and answer to the feedback service; speaking also sends audio to the
configured transcription service. Both incur additional API usage. Audio and answers
stay in memory and are cleared when practice closes; they are not written to history.
`~/Library/Application Support/Voxa/practice-history.json` stores up to 500 lesson IDs,
attempt IDs, counts and review dates. Deleting a saved lesson also removes its review
timing. Unsaved lessons and paired-alternative practice do not reschedule the saved
primary correction. Disabling feedback cancels pending requests and clears
unsaved findings; saved lessons and existing progress remain until deleted.

### Automatic text context

Enable **English Learning → Use Nearby Text Automatically** in the menu bar
to give English feedback more background while you work. It is off by default,
including after upgrading. English feedback must also be enabled.

At recording start, VOXA reads text around the cursor through macOS Accessibility.
For an empty or short multiline editor, it also looks for visible text immediately
above it in the same pane. It prioritises the nearest text, skips controls and
sidebars, and keeps at most 2,400 UTF-16 units. A **Context from…** label identifies
the source app in feedback. Editor and conversation support depends on the app;
the implementation uses bounded Accessibility reads rather than an app-specific
chat integration. It does not scroll or select text.

Capture runs alongside recording with a 450 ms budget and short per-read timeouts.
Dictation never waits for it. Missing Accessibility access, unsupported apps, a
changed app/window/focus, or a slow read simply means feedback proceeds without
context. Protected password/search fields are skipped. **Settings → Privacy →
Add App…** lets you disable capture for any app, including an entire browser.
Excluded apps appear directly on that page; remove an app with its minus button
to allow context again.

Only text is sent, in the existing feedback request: no screenshots, OCR, extra
model call, or change to the audio transcription/pasted output. The excerpt is
untrusted background for interpreting references and phrasing; every quoted fix and
natural-version sentence is checked against your original dictation. Raw context is kept only for
the current capture/request and is not written to history or logs. Provider data
retention still applies. Turning context off or changing exclusions clears an
in-progress capture and cancels pending feedback that used context; a request
already sent cannot be recalled. Practice never captures context.

The **Privacy** page keeps app exclusions and sending, storage, and practice
details together. Open **English Learning → Lessons & Progress…** in the menu
bar for your repeated mistakes, saved fixes and practice.

### Dictation data

Voxa records audio locally and sends the completed recording to OpenAI for
transcription. **Transcription requires internet access.**

The app holds recordings and the latest transcript in memory; it does not save
an audio or full-transcript history to disk. Explicitly saved English lessons and text-free learning progress
are persisted. API keys entered in the app are stored
in macOS Keychain, and preferences are saved locally. See the
[architecture guide](architecture.md) for details about data handling and
clipboard recovery.
