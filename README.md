# Askme for macOS

An on-call “knowledge loading” assistant for macOS: **hold a key, point at a word you do not know, and see its essence in about a second**, then expand context meaning, analogies, key points, and prerequisites until it clicks.

Native menu-bar app built with Swift + AppKit / SwiftUI. Zero third-party dependencies — no Electron, WebView, database, or always-on service. Targets **macOS 14+**. The project builds and launches; core logic has unit tests. Cross-app text pickup still needs real-device validation.

## Getting started

Download the latest `Askme-x.y.z-macOS.dmg` from [Releases](https://github.com/wantongwangelec-source/askme/releases) and drag Askme into Applications. The package is a universal binary (Apple silicon and Intel), ad-hoc signed and not notarized by Apple. On first open, choose **Open Anyway** under System Settings → Privacy & Security, or run `xattr -dr com.apple.quarantine /Applications/Askme.app`.

Or build from source:

```bash
./scripts/build-app.sh
open dist/Askme.app
```

Copy `dist/Askme.app` somewhere stable (for example `~/Applications/`) before granting permissions. Default signing is ad-hoc; rebuilding may require re-approving permissions.

1. Menu bar **Askme → Settings & Permissions…**, grant **Accessibility** (required). Quit and reopen if it does not take effect.
2. Enter a full Chat Completions URL and model name; save the API key (Keychain, keyed by endpoint).
3. Optional: in “About you”, write one line of background, e.g. “front-end engineer, never systematically studied ML”.

### How to use

| Action | Effect |
| --- | --- |
| Hold `⌃` and point at text | Stream a concept card immediately; move to another word to switch; release to dismiss |
| While holding, move onto the card then release | Keep the card |
| Tap `⌃` | Explain the word under the pointer and keep the card; dismiss by clicking elsewhere, typing, scrolling, or `Esc` |
| Select text, then tap `⌃` | Explain the whole selection (uses the focused selection when the pointer is not on text) |
| `⇧` + tap `⌃` | **Preload the current window**: list prerequisites needed to understand this page, ordered by dependency |

The trigger key can be changed in Settings to `⌥`, right `⌘`, or `fn`. If another key, click, or scroll follows the press (for example `⌃Space` for IME), the gesture is treated as part of a shortcut and cancelled silently. The older “hover then show a button” mode remains optional and is off by default.

### Concept card

- **One-liner** first — readable as soon as streaming starts.
- **Here**: what it means in the nearby source text.
- **Analogy**: chosen from your background, with where the analogy breaks.
- **Expand**: points, examples, common pitfalls.
- **Prerequisites / related**: clickable; expands in the same card with a path you can step back along.
- **Follow-ups**: “simpler”, “example”, “deeper”, or a typed question. Answers auto-scroll into view; after you scroll manually, follow stops.
- **Pin / dock**: pinned cards stay when you click away; later lookups join the same path. Dock to the right edge for side-by-side reading.
- **⋯ menu**: copy card content, search the concept, or inspect exactly what was sent and to which endpoint.
- When the model is unsure (for example internal codenames), the card says so and offers Search via a configurable browser URL (can point at internal docs).

### Preload

On a hard article, paper, or doc, press `⇧` + tap `⌃` (or menu **Preload current window**). Askme reads **on-screen visible** text in the window (Accessibility first; if that fails and OCR is enabled, it OCRs the whole window locally), then returns the page gist, 3–8 prerequisites (basics first, skipping what you already know), and the hardest spots. Each concept opens with its page context.

### Learning log and review (optional, off by default)

When enabled, looked-up concepts are stored in `~/Library/Application Support/Askme/knowledge.json` (mode 0600): **concept name, one-liner, source app name, and review progress only** — never raw source text, window titles, or page bodies.

- Looking up the same concept again shows a banner like “seen 3 days ago · 2nd time”.
- Lookups enter spaced review automatically (1, 3, 7, 16, 35, 90 days). Remembering stretches the interval; forgetting or looking it up again resets. Mastery comes only from Remember / Forgot during review.
- Remembered concept names can be sent with later requests as analogy anchors so the model does not re-explain them.
- Menu **Knowledge & review…** supports review (“don’t keep this”), search, delete one, or clear all.

### Models

Supports OpenAI-compatible Chat Completions **streaming** (SSE) and services that return a full JSON body. HTTPS only; HTTP is allowed solely for localhost / loopback. Redirects are rejected; no cookies or cache. One shared connection for the app so back-to-back lookups skip repeated handshakes.

Snappy feel depends mainly on time-to-first-token: prefer fast models without deep reasoning, or disable reasoning in “extra request parameters”, e.g. `{"reasoning_effort": "low"}` (provider-specific). While a reasoning model thinks, the card shows a thinking state.

Local example: `http://localhost:11434/v1/chat/completions` (key optional). The app never installs or downloads models for you.

## Privacy and interaction

Askme is designed around intentional, high-frequency lookups without confirmation fatigue:

- **Intent is consent**: pressing the trigger while pointing at a word sends that word, nearby context (~1,200 characters), app name, and window title. Full-page / full-window text is sent only for explicit actions (Read Chrome page, Preload).
- **Quasi-mode**: hold to look, release to leave — no sticky mode to forget.
- **Calm defaults**: hover-button mode is off; passive triggers still require confirm before send.
- **Differentiated protection**: chat/mail-style apps default to confirm-first (editable); password managers are excluded; secure-input / password fields are skipped.
- **Data minimization**: learning log is off by default; when on, only concept name + one-liner are stored. Smoke tests stay in memory.

| Permission / data | When used | Required |
| --- | --- | --- |
| Accessibility | Pointer hit-testing, word/selection/visible text; global trigger key | Yes |
| Screen recording | Local OCR / images when enabled (full window for preload) | No |
| Chrome automation | “Read current Chrome page” | No |
| API key | Keychain entry for the configured endpoint at send time | Depends on service |
| Network | After an intentional trigger (or after Confirm on confirm-first apps) | Remote models |
| Local file | `knowledge.json` only if learning log is on | No |

Other boundaries: no clipboard-based pickup, no fake `⌘C`, no changing the host app’s selection (clipboard is written only on Copy). Keyboard monitoring is for the trigger, `Esc`, and “typing elsewhere” — not keystroke logging. Model inputs are JSON data; the system prompt treats that content as non-instructional. Links in answers are not clickable; code is not executed; images are not loaded. Server error bodies are not shown, to avoid echoing secrets.

## Architecture

```text
InputMonitor (NSEvent global/local; no polling)
  ├─ TriggerGesture: hold=look / tap=keep / chord=cancel
  └─ optional hover hint: DwellGate
LookupController (orchestration, privacy policy, drop stale results)
  ├─ AccessibilityReader (serial background queue, AX timeouts)
  ├─ ScreenReader: local OCR (ScreenCaptureKit + Vision)
  ├─ ChatClient: single-session streaming SSE, no redirects, 2 MB cap
  ├─ CardParser / PrimerParser: stream-parse structured sections
  └─ KnowledgeStore: local learning log + spaced review
Overlay: non-activating floating card (grows away from the target line; draggable; dockable)
```

## Build, test, release

```bash
swift test
./scripts/build-app.sh
./scripts/package-release.sh   # produces dist artifacts for GitHub Releases
```

`scripts/mock-llm.py` is a local fixture server for UI checks without a real model.

## License

Check the repository for license terms once published; source is provided as-is for building and study.
