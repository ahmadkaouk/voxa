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

1. Open Voxa from the menu bar and choose **Voxa Settings… → API Key**. Save your OpenAI API
   key; Voxa stores it in macOS Keychain.
2. Allow the permissions needed for the features you use:

   | Permission | Used for |
   | --- | --- |
   | Microphone | Recording your voice |
   | Accessibility | Pasting into another app; reading nearby text when automatic context is enabled |
   | Input Monitoring | Recognizing global shortcuts |

3. Focus a text field, press **Option + F**, and speak. Press it again to
   transcribe and paste your words.

If a permission is missing, use the **Enable…** actions in Voxa's menu to open
the relevant System Settings page. Return to Voxa after granting access.

## Using Voxa

### Recording controls

| Action | Default control |
| --- | --- |
| Start / Stop | Press **Option + F** to start; press again to finish and paste |
| Record with the mouse | Choose Start Recording in the Voxa menu, then click the stop square on the bar to finish |
| Finish & Send | Press **Option + G** while recording in Autopaste mode |
| Discard a recording | Press **Esc** while recording (also cancels microphone startup) |

Change shortcuts in **Voxa Settings… → Shortcuts**. **General** contains the
transcription model, output mode, recording limit and permission status.
Press **Esc** while capturing a shortcut to cancel without closing Settings.
**Max Recording** sets the recording limit; the default is five minutes. Transcription begins after
recording finishes. Discarding a recording skips transcription and output.

The compact black bar appears while recording or processing, then hides after a brief
completion checkmark. Its waveform responds to your microphone level. Drag the timer
or waveform area to move the bar; Voxa remembers its position across recordings and
relaunches. The stop button remains clickable. Reduced Motion removes continuous
waveform movement while keeping the microphone level visible.

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

Enable **Voxa Settings → English Learning → Feedback after dictation** for
background English coaching. Dictation is inserted normally and never rewritten;
feedback failures do not interrupt it.

Each correction shows its full **Before / After** sentence, with blue highlights
on changed words and a strike through removed wording. Click the correction or
**Why?** to reveal its explanation, **Remember** rule and **Try once** practice
action. Click again to hide those details; the full sentence stays visible.
Independent corrections in the same sentence share one comparison and keep their
explanations together. Conflicting suggestions remain separate comparisons.

**Optional wording** stays visible after the corrections, with a short explanation
and any reusable pattern. Short reviews fit their
content; longer reviews scroll above the fixed action bar. The panel uses one
uniform neutral background in light and dark appearance, with blue changes and Save.
Grammar confirmation and successful patterns stay in a quiet summary. The coach
preserves meaning, tone, uncertainty and technical terms, and ignores fillers and
clear self-corrections.

An **English-expression estimate** develops across dictations, covering accuracy,
vocabulary, natural phrasing, sentence range and clarity. Lessons & Progress shows a
provisional CEFR-style band once there are at least six qualifying samples,
300 words and two kinds of speech (such as requests and explanations). Individual
samples need at least 40 assessable English words and evidence for all five dimensions.
Short, narrow, non-English or uncertain samples do not lower the estimate. The profile
uses the latest 30 qualifying samples within 90 days; the coverage thresholds and
aggregation are product heuristics, not calibrated confidence. This experimental
estimate has not been validated against a language exam and cannot assess listening,
pronunciation or conversational fluency. A clean dictation can still show a brief
positive review. Old grammar-only observations stay saved but cannot be converted
into a broader level without their original text.

The panel appears after delivery without taking focus and hides automatically after
five seconds. Hovering pauses the countdown; the timer button pins the panel open.
Leaving the panel or unpinning resumes the remaining time. A new recording also hides it; **English Learning → Show Latest Feedback**
reopens the latest review for another five seconds until another transcript replaces it.
Saving lessons cancels the timer; a failed save keeps the review open for retry.

- **Save / ⌘S:** save all corrections and alternatives, then close.
  Recognition issues are excluded. ⌘S also closes a review with no lessons.
- **Close / Esc:** close without saving lessons. Local progress remains available.
- **English Learning → Lessons & Progress…:** review, practise, or delete saved
  lessons, and view or clear progress separately.
- **Try once:** beside a pattern, say the improved version,
  then try the pattern in a new sentence. Use **Record answer → Stop & check**, or
  **Type instead**. Recording stops automatically at 40 seconds. Each answer gets
  one short response about the target pattern. Practice never pastes or changes
  the last dictation. Each correction and alternative has its own practice action.
  Close practice to return to the review and save it
  if useful. Saved-lesson details also have individual practice links.
- **English Learning → One-minute Review…:** revisit up to three due patterns
  from saved lessons, with recurring grammar errors first. Examples stay hidden until
  requested. Skip freely; no reminders or daily requirements. New examples must use
  the pattern, not simply repeat the supplied wording.

Successful reviews return after 1, 3, 7, 14 and then 30 days. A retry brings the pattern
back the next day; immediate repeats do not advance the interval. Recognition
uncertainty and skipped exercises do not count as mistakes. Practice is kept separate
from the English-level estimate and correct uses observed during ordinary dictation.

Progress tracks up to 200 recent reviews automatically while feedback is enabled.
Repeated mistakes are counted by rule, and correct use of previously encountered
patterns is recognised in later dictations, including those with no corrections.
Absence of an error does not count as a success; an actual source example is
required. Counts are per review, not a mastery percentage. **Progress** in the sidebar shows
the broader expression profile, its coverage, and patterns to practise.

The English Learning window uses a Notes-style sidebar, lesson list and reading
pane. **All Lessons**, **Corrections**, and **Natural Phrasing** filter the library;
lessons with an optional alternative also appear under Natural Phrasing. Search
matches the wording, explanation and pattern. The reading pane keeps the full
original and corrected sentences available. **Practice** shows the next short
review, and **Progress** shows your expression profile. Resize the window or drag
the divider beside the lesson list to give the text more room.

A failed save keeps the review open. While feedback is visible, ⌘S saves it and
Esc closes it. During recording, Esc discards the recording before transcription
and output. Outside these contexts, the shortcuts pass through normally. Plain
S and D always type normally. Global shortcuts require Accessibility access.

Feedback is off by default. Enabling it sends transcript text in an additional
OpenAI request using the same API key, with additional usage cost. It uses
`gpt-6-luna` with low reasoning effort and requests `store: false`, which does
not guarantee zero provider retention; see [OpenAI data controls](https://developers.openai.com/api/docs/guides/your-data).
Only accepted excerpts, suggestions, explanations, dates, and practice prompts
are stored in `~/Library/Application Support/Voxa/corrections.json`. Automatic
progress stores only review IDs, dates, assessment bands, word counts, speaking-task
and pattern categories in
`~/Library/Application Support/Voxa/learning-progress.json`; source evidence is
validated in memory and discarded. Only category IDs, not saved lesson excerpts,
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

Enable **Voxa Settings → English Learning → Use nearby text automatically** once
to give English feedback more background while you work. It is off by default,
including after upgrading. English feedback must also be enabled. A menu toggle
is available under **English Learning**.

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
context. Protected password/search fields are skipped. **Manage exclusions… → Add App…** lets
you disable capture for any app, including an entire browser.

Only text is sent, in the existing feedback request: no screenshots, OCR, extra
model call, or change to the audio transcription/pasted output. The excerpt is
untrusted background for interpreting references and phrasing; all assessment
evidence is checked against your original dictation. Raw context is kept only for
the current capture/request and is not written to history or logs. Provider data
retention still applies. Turning context off or changing exclusions clears an
in-progress capture and cancels pending feedback that used context; a request
already sent cannot be recalled. Practice never captures context.

Settings group feedback and its optional context together. Short descriptions sit
beside the controls; **Data & privacy** contains the detailed sending, storage and
practice information without a disclosure control. **Open English Learning** opens
the library, practice and progress sidebar.

### Dictation data

Voxa records audio locally and sends the completed recording to OpenAI for
transcription. **Transcription requires internet access.**

The app holds recordings and the latest transcript in memory; it does not save
an audio or full-transcript history to disk. Explicitly saved English lessons and text-free learning progress
are persisted. API keys entered in the app are stored
in macOS Keychain, and preferences are saved locally. See the
[architecture guide](architecture.md) for details about data handling and
clipboard recovery.
