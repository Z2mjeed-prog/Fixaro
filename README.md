# Fixaro

**Private, AI-powered autocorrect for every app on your Mac.**

Fixaro fixes typos as you type, in any app, using an AI model that runs on your own Mac. It reads the words around a typo to pick the right fix, learns from you, and can rephrase any text with one shortcut. Nothing you type ever leaves your computer.

> A free, open-source, fully local alternative to cloud writing assistants.

<p align="center">
  <img src="docs/demo-context.gif" width="800" alt="Typing 'I got the money frim the bank': Fixaro changes frim to from. Then 'The new frim policy': the same typo becomes firm, because Fixaro reads the words around it.">
</p>

## What it does

- **Fixes typos as you type, everywhere:** Mail, Notes, Slack, Chrome, WhatsApp, and more.
- **Understands context.** It reads the words *before and after* a typo:
  - "the money **frim** the bank" → **from**
  - "the new **frim** policy" → **firm**
- **Rephrases on demand.** Select text, press **⌃⌥R** (Control-Option-R), and it's rewritten in place. Styles: Natural, Professional, Shorter, Friendly.

  <img src="docs/demo-rephrase.gif" width="700" alt="The sentence 'we was to busy to finish it yesterday' is selected, Control-Option-R is pressed, and it becomes 'We were too busy to finish it yesterday.'">

  Works in any app, including your email. Here's a casual draft in Apple Mail, rewritten with the **Professional** style:

  <img src="docs/demo-email.gif" width="700" alt="A casual email draft in Apple Mail, 'Hey, can you send me the sales numbers by tomorrow? ... thanks', is selected, Control-Option-R is pressed, and it becomes 'Could you please send me the sales numbers by tomorrow? I require them for the meeting on Thursday. Please let me know if this presents any issues. Thank you.'">
- **Learns from you.**
  - Undo the same fix twice, and Fixaro leaves that word alone for good.
  - Keep a fix twice, and it's applied instantly next time.
- **Easy undo.** Press Backspace right after a fix, or **⌃⌥Z** within the next few words.
- **100% local.** No account, no cloud, no tracking.

## Privacy

Fixaro needs **Accessibility** permission. That's the only way a Mac app can see what you type and replace a word in another app. Here's what that means in practice:

- **Nothing leaves your Mac.** All AI runs locally through [Ollama](https://ollama.com) or another AI app on your Mac. Fixaro makes no other network connections.
- **Passwords are hidden from it.** macOS hides keystrokes in password fields (Secure Input) from all apps, Fixaro included.
- **What's saved, all on your Mac:**
  - your word list and learned fixes in `~/Library/Application Support/Fixaro/`
  - a log of corrections in `~/Library/Logs/Fixaro.log`

  You can delete them any time.
- **Open source**, so you can read exactly what it does.

## Requirements

- **macOS 14 or later.** Apple Silicon (M1 or newer) is recommended; Intel works, but the AI is slower.
- **[Ollama](https://ollama.com)** (free), plus one or two models (below). LM Studio, Jan, llama.cpp or MLX servers work too ([see below](#use-another-ai-app-instead-of-ollama-beta)).
- **Apple's free Command Line Tools.** The build script installs them if they're missing.

## Install

1. **Install Ollama** from [ollama.com](https://ollama.com) and open it.
2. **Download a model.** You can use any model you like (see [Choosing models](#choosing-models)). Recommended, by your Mac's memory (Apple menu → About This Mac):

   | Your Mac's memory | Word fixes | Rephrasing | Commands |
   |---|---|---|---|
   | **8 GB** | nemotron-3-nano:4b | nemotron-3-nano:4b | `ollama pull nemotron-3-nano:4b` |
   | **16 GB** | qwen3.5:4b | qwen3.5:4b | `ollama pull qwen3.5:4b` |
   | **18 GB or more** | qwen3.5:4b | gemma4:e4b | `ollama pull qwen3.5:4b`<br>`ollama pull gemma4:e4b` |

   One model can do both jobs. On 16 GB you can also use gemma4:e4b for rephrasing, but with both models loaded, other apps may slow down.
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
6. **Pick your models** from the Fixaro menu bar icon: **Word-fix model** and **Rephrase model**. Fixaro picks sensible defaults from what you've installed, and you can change them any time.

## Using it

| You want to… | Do this |
|---|---|
| Fix typos | Just type. Fixes happen after Space or Enter |
| Undo a fix | Backspace right after it, or **⌃⌥Z** |
| Rephrase text | Select it, then **⌃⌥R** (Control-Option-R) |
| Never correct a word | Menu → **Edit word list…**, or undo its fix twice |
| Turn it off in one app | Switch to that app, then menu → **Turn off in …** |
| Turn it off in several apps | Menu → **Turn off in apps**, then tick the apps |
| Use a different model | Menu → **Word-fix model** / **Rephrase model**, or **Download a model…** |
| Use LM Studio, Jan, MLX… | Menu → **AI app** |
| Pause everything | Menu → **Pause** |

Terminal and code editors are off by default.

## Choosing models

**Any model works.** Fixaro lists every text model you've installed in Ollama, and you choose one for each job in the menu bar:

- **Word-fix model:** runs on every typo, so pick something **small and fast** (about 4 GB or less).
- **Rephrase model:** runs only when you press ⌃⌥R, so a **bigger model** that writes better is fine, if your Mac has the memory.

**Getting a new model:** use **Download a model…** in the menu bar (or `ollama pull <name>` in Terminal). New models show up in the menu within seconds, with no restart needed. Embedding models are hidden because they can't write text.

### How the model changes Fixaro

| | Smaller model | Bigger model |
|---|---|---|
| **Speed** | Fixes in about 0.1–0.2 s | Fixes take longer |
| **Picking the right word** | Misses more often when the sentence matters ("frim" → from or firm?) | Reads the sentence better |
| **Rephrasing** | Fixes grammar, but the writing is plainer | Writes more naturally |
| **Memory** | Leaves more room for your other apps | Can slow other apps on smaller Macs |

What that means in practice:

- **Word fixes have 1.5 seconds.** If the model hasn't answered by then, Fixaro uses the spell checker's first guess instead, which ignores the sentence. A model that's too big for your Mac quietly makes your fixes worse, not better.
- **Models stay loaded while you use them:** the word-fix model for 30 minutes after its last fix, the rephrase model for 15. The model's size is roughly the memory it takes, and two models take both. Try to keep the total under about half your Mac's memory.
- **The first use after a break is slower** (a few seconds) while the model loads. After that it's fast.
- **Bigger models use more battery** for every fix.

### Suggested models

**Tested** with `tools/bench.py` on an M-series Mac with 18 GB of memory. Each model got 46 typos: 18 easy ones, and 28 where the right fix depends on the sentence ("money **frim** the bank" vs "new **frim** policy").

| Model | Size | Best for | Typos fixed | Need the sentence | Time per word | Rephrasing |
|---|---|---|---|---|---|---|
| **qwen3.5:4b** | 4.0 GB | **Word fixes** (default) | **46/46** | **28/28** | 0.21 s | Good, but sometimes adds small details |
| **gemma4:e4b** | 9.6 GB | **Rephrasing** on 18 GB+ | 45/46 | 27/28 | 0.36 s | **Best:** changes the tone well and sticks to your message |
| qwen3.5:9b | 7.6 GB | Rephrasing, if you want to save 2 GB | 46/46 | 28/28 | 0.30 s | Very good, but once added a sentence of its own |
| **nemotron-3-nano:4b** | 2.9 GB | **Word fixes on 8 GB Macs** | 43/46 | 25/28 | 0.20 s | Good, stays close to your words |
| qwen3.5:2b | 3.1 GB | Fastest | 39/46 | 22/28 | 0.12 s | OK, sometimes adds details |
| granite4.2:3b | 2.2 GB | Smallest | 39/46 | 21/28 | 0.15 s | OK, one grammar slip |

All six fixed nearly every easy typo, kept every name and number when rephrasing, and rewrote questions instead of answering them. The differences show up when the sentence matters, and in how well each one writes.

**Worth trying** (not tested with Fixaro yet):

| Model | Size | Try it for | Why |
|---|---|---|---|
| `lfm3:1.7b` | under 2 GB | Word fixes on 8 GB Macs | Very small and fast |
| `ministral-3:3b` | 3.0 GB | Word fixes | Small model from Mistral |
| `phi4-mini` | 2.5 GB | Word fixes | Older, well-known |
| `llama3.2:3b` | 2.0 GB | Word fixes | Older, well-known |
| `gemma4:12b` | 7.7 GB | Rephrasing on 18 GB+ | Bigger Gemma, better writing |

If you have **32 GB or more**, larger models (like `gemma4:26b` or `qwen3.6:27b`) can write even better rephrases. Keep them for rephrasing, and a small model for word fixes.

**Not a good fit:**

- **Reasoning models** (`deepseek-r1`, anything named `-reasoning` or `-thinking`): they "think" before answering, so they're slow. Fixaro switches thinking off where a model allows it.
- **Vision models** (names with `-vl` or `vision`): they work, but use extra memory for nothing. Fixaro prefers text-only models when it picks defaults.
- **Big models for word fixes** (9B and up): they're slower and take more memory, and a small model already gets almost every word right. If you try one, check the log for "LLM too slow".

### Model tips

- **Test before you choose.** Run `python3 tools/bench.py` to test every model you've installed, or name a few: `python3 tools/bench.py qwen3.5:4b nemotron-3-nano:4b`. It checks 46 typos (28 of them need the sentence to get right) and 5 rephrase jobs, and shows how fast each model is.
- **Check the log** (menu → **Open log**). Each fix says which model made it and how long it took:
  - Lots of **"LLM too slow"**: your word-fix model is too big for your Mac. Pick a smaller one.
  - Lots of **"LLM gave no usable answer"**: the model is chatty instead of answering with one word. Try another.
- **Short on memory?** Use the same model for both jobs, so only one is loaded.
- **Clean up** models you don't use: `ollama list` shows them with their sizes, and `ollama rm <name>` deletes one.
- **Keep Ollama updated.** New models often need the latest version.

### Use another AI app instead of Ollama (beta)

Already use **LM Studio**, **Jan**, a **llama.cpp** server or an **MLX** server? Fixaro works with any app that offers an OpenAI-compatible API:

1. Start the app's local server and load a model.
2. In Fixaro's menu bar icon, choose **AI app** and pick it (LM Studio, llama.cpp/MLX, Jan), or choose **Other app…** and enter its address, for example `http://localhost:1234/v1`.
3. Pick your **Word-fix model** and **Rephrase model** from the list.

If you enter an address that isn't on your Mac, Fixaro warns you first, because your text would then leave your computer.

This is new: if it doesn't work with your app, please [open an issue](https://github.com/Z2mjeed-prog/Fixaro/issues) and say which app and model you use.

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

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/how-it-works-dark.png">
  <img src="docs/how-it-works-light.png" width="900" alt="Fixaro reads your keys, asks the Mac's spell checker whether a word is wrong, asks a local AI model which fix fits the words around it, and swaps the word in. Everything happens on your Mac; nothing is sent to the internet.">
</picture>

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
