# Fixaro

**Private, AI-powered autocorrect for every app on your Mac.**

Fixaro fixes typos as you type, in any app, using an AI model that runs on your own Mac. It reads the words around a typo to pick the right fix, learns from you, and can rephrase any text with one shortcut. Nothing you type ever leaves your computer.

<p align="center">
  <img src="docs/demo-context.gif" width="800" alt="Typing 'I got the money frim the bank': Fixaro changes frim to from. Then 'The new frim policy': the same typo becomes firm, because Fixaro reads the words around it.">
</p>

## What it does

- **Fixes typos as you type, everywhere:** Mail, Notes, Slack, Chrome, WhatsApp, and more.
- **Understands context.** "the money **frim** the bank" → **from**, but "the new **frim** policy" → **firm**.
- **Rephrases on demand.** Select text and press **⌃⌥R** (Control-Option-R). Styles: Natural, Professional, Shorter, Friendly.

  <img src="docs/demo-rephrase.gif" width="700" alt="The sentence 'we was to busy to finish it yesterday' is selected, Control-Option-R is pressed, and it becomes 'We were too busy to finish it yesterday.'">

  In Apple Mail, with the Professional style:

  <img src="docs/demo-email.gif" width="700" alt="A casual email draft in Apple Mail, 'Hey, can you send me the sales numbers by tomorrow? ... thanks', is selected, Control-Option-R is pressed, and with the Professional style it becomes 'Could you please send me the sales numbers by tomorrow? I require them for the meeting on Thursday. Please let me know if this presents any issues. Thank you.'">
- **Learns from you.** Undo the same fix twice and Fixaro leaves that word alone; keep a fix twice and it's applied instantly next time.
- **Easy undo.** Press Backspace right after a fix, or **⌃⌥Z**.

## Privacy

- **Nothing leaves your Mac.** The AI runs locally through [Ollama](https://ollama.com). No account, no cloud, no tracking.
- **Passwords are hidden from it.** macOS hides password fields from all apps, Fixaro included.
- **It needs Accessibility permission,** the only way a Mac app can see what you type and replace a word in another app.
- **What's saved:** your word list and learned fixes (`~/Library/Application Support/Fixaro/`) and a log (`~/Library/Logs/Fixaro.log`). Delete them any time.

## Install

You need **macOS 14 or later** (Apple Silicon recommended) and **[Ollama](https://ollama.com)** (free).

1. **Install Ollama** and open it.
2. **Download a model** for your Mac's memory (Apple menu → About This Mac):

   | Your Mac's memory | Run this in Terminal |
   |---|---|
   | **8 GB** | `ollama pull nemotron-3-nano:4b` |
   | **16 GB** | `ollama pull qwen3.5:4b` |
   | **18 GB or more** | `ollama pull qwen3.5:4b` and `ollama pull gemma4:e4b` (for rephrasing) |

   Any model works. See [Choosing models](docs/MODELS.md) for test results and other options.
3. **Download and build Fixaro:**
   ```bash
   git clone https://github.com/Z2mjeed-prog/Fixaro.git
   bash Fixaro/build.sh
   ```
   This installs it into `~/Applications`. No git? Use **Code → Download ZIP**, unzip it, and run `bash Fixaro-main/build.sh`.
4. **Allow it:** when macOS asks, open **System Settings → Privacy & Security → Accessibility** and turn **Fixaro** on.

## Using it

| You want to… | Do this |
|---|---|
| Fix typos | Just type. Fixes happen after Space or Enter |
| Undo a fix | Backspace right after it, or **⌃⌥Z** |
| Rephrase text | Select it, then **⌃⌥R** |
| Change models | Menu → **Word-fix model** / **Rephrase model** |
| Never correct a word | Menu → **Edit word list…** |
| Turn it off in some apps | Menu → **Turn off in apps** |
| Pause everything | Menu → **Pause** |

Terminal and code editors are off by default. Fixaro also works with LM Studio, Jan and other local AI apps ([how](docs/MODELS.md#use-another-ai-app-instead-of-ollama-beta)).

## Troubleshooting

- **Turn off macOS's own autocorrect** (System Settings → Keyboard → Text Input → Edit), so two autocorrects don't clash.
- **Menu bar icon shows ⚠:** Fixaro lost its permission. After every rebuild, switch it off and on again under Accessibility.
- **Rephrase does nothing:** make sure Ollama is running and some text is selected.
- **Anything odd:** menu → **Open log** shows every fix and why it was made.

## Known limitations

- **English only.** Arabic and other non-Latin text is left alone.
- **Real-word mistakes aren't caught** (their/there). Use Rephrase for those.
- **The first word after you click somewhere** may be skipped in some apps.
- **No ready-made download yet.** You build it with `build.sh`.

## Uninstall

Quit Fixaro from its menu, delete `~/Applications/Fixaro.app`, and remove it from **Privacy & Security → Accessibility**. Optionally delete its data folders listed under Privacy.

## How it works

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/how-it-works-dark.png">
  <img src="docs/how-it-works-light.png" width="900" alt="Fixaro reads your keys, asks the Mac's spell checker whether a word is wrong, asks a local AI model which fix fits the words around it, and swaps the word in. Everything happens on your Mac; nothing is sent to the internet.">
</picture>

Fixaro is a single Swift file (`Sources/main.swift`). The macOS spell checker spots the typo, a local model picks the fix from the words around it (falling back to the spell checker if the model is slow), and the word is swapped in place, or retyped in Chrome and Electron apps.

## Roadmap

- Windows version (in progress)
- Catching real-word mistakes (their/there)
- Signed, ready-to-run download

## Contributing

Issues and pull requests are welcome. If something doesn't work, please open an issue with the relevant lines from the log.

## License

[MIT](LICENSE) © Z2mjeed-prog
