# Fixaro

**Private, AI-powered autocorrect for every app on your Mac.**

Fixaro fixes typos as you type, in any app, using an AI model that runs on your own Mac. It reads the words around a typo to pick the right fix, learns from you, and can rephrase any text with one shortcut. Nothing you type ever leaves your computer.

> A free, open-source, fully local alternative to cloud writing assistants.

## What it does

- **Fixes typos as you type, everywhere:** Mail, Notes, Slack, Chrome, WhatsApp, and more.
- **Understands context.** It reads the words *before and after* a typo:
  - "the money **frim** the bank" → **from**
  - "the new **frim** policy" → **firm**
- **Rephrases on demand.** Select text, press **⌃⌥R** (Control-Option-R), and it's rewritten in place. Styles: Natural, Professional, Shorter, Friendly.
- **Learns from you.**
  - Undo the same fix twice, and Fixaro leaves that word alone for good.
  - Keep a fix twice, and it's applied instantly next time.
- **Easy undo.** Press Backspace right after a fix, or **⌃⌥Z** within the next few words.
- **100% local.** No account, no cloud, no tracking.

## Privacy

Fixaro needs **Accessibility** permission. That's the only way a Mac app can see what you type and replace a word in another app. Here's what that means in practice:

- **Nothing leaves your Mac.** All AI runs locally through [Ollama](https://ollama.com). Fixaro makes no other network connections.
- **Passwords are hidden from it.** macOS hides keystrokes in password fields (Secure Input) from all apps, Fixaro included.
- **What's saved, all on your Mac:**
  - your word list and learned fixes in `~/Library/Application Support/Fixaro/`
  - a log of corrections in `~/Library/Logs/Fixaro.log`

  You can delete them any time.
- **Open source**, so you can read exactly what it does.

## Requirements

- **macOS 14 or later.** Apple Silicon (M1 or newer) is recommended; Intel works, but the AI is slower.
- **[Ollama](https://ollama.com)** (free), plus one or two models (below).
- **Apple's free Command Line Tools.** The build script installs them if they're missing.

## Install

1. **Install Ollama** from [ollama.com](https://ollama.com) and open it.
2. **Download the models:**
   ```bash
   ollama pull qwen3.5:4b     # word fixes (4 GB)
   ollama pull gemma4:e4b     # optional: better rephrasing (9.6 GB, needs 16 GB+ memory)
   ```
3. **Download Fixaro:**
   ```bash
   git clone https://github.com/Z2mjeed-prog/Fixaro.git
   ```
   Or use **Code → Download ZIP** on this page.
4. **Build and install it** into `~/Applications`:
   ```bash
   bash Fixaro/build.sh
   ```
5. **Allow it:** when macOS asks, open **System Settings → Privacy & Security → Accessibility** and turn **Fixaro** on.
6. **Pick models** from the Fixaro menu bar icon:
   - **Word-fix model** → `qwen3.5:4b`
   - **Rephrase model** → `gemma4:e4b`, or `qwen3.5:4b` on 8 GB Macs

## Using it

| You want to… | Do this |
|---|---|
| Fix typos | Just type. Fixes happen after Space or Enter |
| Undo a fix | Backspace right after it, or **⌃⌥Z** |
| Rephrase text | Select it, then **⌃⌥R** (Control-Option-R) |
| Never correct a word | Menu → **Edit word list…**, or undo its fix twice |
| Turn it off in one app | Switch to that app, then menu → **Turn off in …** |
| Pause everything | Menu → **Pause** |

Terminal and code editors are off by default.

## Choosing models

Results from `tools/bench.py` on an M-series Mac with 18 GB of memory (18 real typos plus one rephrase):

| Model | Size | Typos fixed | Time per word | Rephrase quality |
|---|---|---|---|---|
| qwen3.5:2b | 3.1 GB | 17/18 | 0.16 s | OK |
| **qwen3.5:4b** | 4.0 GB | **18/18** | 0.31 s | Good |
| **gemma4:e4b** | 9.6 GB | **18/18** | 0.44 s | **Best** |

To test the models on your own Mac, run `python3 tools/bench.py`.

## Tips and troubleshooting

- **Turn off macOS's own autocorrect.** Go to System Settings → Keyboard → Text Input → Edit → *Correct spelling automatically*. Two autocorrects fixing the same word clash.
- **Menu bar icon shows ⚠:** Fixaro doesn't have permission. After every rebuild, switch Fixaro off and on again under Accessibility.
- **Words aren't fixed in one app:** check that the app isn't turned off in the menu.
- **Rephrase does nothing:** make sure Ollama is running and some text is selected.
- **Something odd:** menu → **Open log** shows every fix and why it was made.

## Known limitations

- **English only.** Arabic and other non-Latin text is left alone.
- **Real-word mistakes aren't caught yet** (their/there, meet/meat). Use Rephrase for those.
- **The first word after you click somewhere** may be skipped in some apps.
- **No ready-made download yet.** For now you build it from source with `build.sh`.

## Uninstall

1. Menu bar icon → **Quit Fixaro**.
2. Delete `~/Applications/Fixaro.app`.
3. Optionally delete `~/Library/Application Support/Fixaro` and `~/Library/Logs/Fixaro.log`.
4. Remove Fixaro from System Settings → Privacy & Security → Accessibility.

## How it works

Fixaro is a single Swift file (`Sources/main.swift`): a menu bar app with no Xcode project.

1. **Watching keys:** a keyboard event tap tracks the current word. On Space, the macOS spell checker decides whether the word is wrong and suggests candidates.
2. **Picking the fix:** Fixaro waits for the next word, then asks a local model (Ollama's HTTP API) to choose from the candidates using the sentence around the typo. The answer is validated; if the model is slow or unsure, the spell checker's own suggestion is used.
3. **Applying it:**
   - **Native Mac apps:** the word is replaced directly through the Accessibility API.
   - **Chrome and Electron apps:** it's retyped. Your own keystrokes are briefly held and re-sent in order, so nothing gets mixed in.
4. **Rephrase:** it copies the selection, rewrites it with the rephrase model, pastes the result, and restores your clipboard.

## Roadmap

- Windows version (in progress)
- Suggestions for real-word mistakes (their/there)
- Signed, ready-to-run download

## Contributing

Issues and pull requests are welcome. If something doesn't work, please open an issue with the relevant lines from the log.

## License

[MIT](LICENSE) © Z2mjeed-prog
