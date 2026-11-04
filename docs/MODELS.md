# Choosing models for Fixaro

**Any model works.** Fixaro lists every text model you've installed in Ollama, and you choose one for each job in the menu bar:

- **Word-fix model:** runs on every typo, so pick something **small and fast** (about 4 GB or less).
- **Rephrase model:** runs only when you press ⌃⌥R, so a **bigger model** that writes better is fine, if your Mac has the memory.

To get a new model, use **Download a model…** in the menu bar (or `ollama pull <name>` in Terminal). It shows up in the menu within seconds.

## How the model changes Fixaro

| | Smaller model | Bigger model |
|---|---|---|
| **Speed** | Fixes in about 0.1–0.2 s | Fixes take longer |
| **Picking the right word** | Misses more often when the sentence matters ("frim" → from or firm?) | Reads the sentence better |
| **Rephrasing** | Fixes grammar, but the writing is plainer | Writes more naturally |
| **Memory** | Leaves more room for your other apps | Can slow other apps on smaller Macs |

- **Word fixes have 1.5 seconds.** If the model hasn't answered by then, Fixaro uses the spell checker's first guess instead, which ignores the sentence. A model that's too big for your Mac quietly makes your fixes worse.
- **Models stay loaded while you use them:** the word-fix model for 30 minutes after its last fix, the rephrase model for 15. Try to keep the total under about half your Mac's memory.
- **The first use after a break is slower** (a few seconds) while the model loads.

## Test results

Tested with `tools/bench.py` on an M-series Mac with 18 GB of memory. Each model got 46 typos: 18 easy ones, and 28 where the right fix depends on the sentence ("money **frim** the bank" vs "new **frim** policy").

| Model | Size | Best for | Typos fixed | Need the sentence | Time per word | Rephrasing |
|---|---|---|---|---|---|---|
| **qwen3.5:4b** | 4.0 GB | **Word fixes** (default) | **46/46** | **28/28** | 0.21 s | Good, but sometimes adds small details |
| **gemma4:e4b** | 9.6 GB | **Rephrasing** on 18 GB+ | 45/46 | 27/28 | 0.36 s | **Best:** changes the tone well and sticks to your message |
| qwen3.5:9b | 7.6 GB | Rephrasing, if you want to save 2 GB | 46/46 | 28/28 | 0.30 s | Very good, but once added a sentence of its own |
| **nemotron-3-nano:4b** | 2.9 GB | **Word fixes on 8 GB Macs** | 43/46 | 25/28 | 0.20 s | Good, stays close to your words |
| qwen3.5:2b | 3.1 GB | Fastest | 39/46 | 22/28 | 0.12 s | OK, sometimes adds details |
| granite4.2:3b | 2.2 GB | Smallest | 39/46 | 21/28 | 0.15 s | OK, one grammar slip |

All six fixed nearly every easy typo, kept every name and number when rephrasing, and rewrote questions instead of answering them. The differences show up when the sentence matters, and in how well each one writes.

**Not tested yet, but worth trying:** `lfm3:1.7b` and `ministral-3:3b` for word fixes, `gemma4:12b` for rephrasing. With 32 GB or more, bigger models like `gemma4:26b` can write even better rephrases; keep a small model for word fixes.

**Not a good fit:**

- **Reasoning models** (`deepseek-r1`, names with `-reasoning` or `-thinking`): they "think" before answering, so they're slow.
- **Vision models** (names with `-vl` or `vision`): they work, but use extra memory for nothing.
- **Big models for word fixes** (9B and up): slower, with no gain in accuracy.

## Tips

- **Test on your own Mac:** `python3 tools/bench.py` tests every model you've installed, or name a few: `python3 tools/bench.py qwen3.5:4b nemotron-3-nano:4b`.
- **Check the log** (menu → **Open log**):
  - Lots of **"LLM too slow"**: your word-fix model is too big for your Mac. Pick a smaller one.
  - Lots of **"LLM gave no usable answer"**: the model is chatty instead of answering with one word. Try another.
- **Short on memory?** Use the same model for both jobs, so only one is loaded.
- **Clean up:** `ollama list` shows your models and sizes; `ollama rm <name>` deletes one.

## Use another AI app instead of Ollama (beta)

Fixaro also works with **LM Studio**, **Jan**, and **llama.cpp** or **MLX** servers (any app with an OpenAI-compatible API):

1. Start the app's local server and load a model.
2. In Fixaro's menu, choose **AI app** and pick it, or choose **Other app…** and enter its address (for example `http://localhost:1234/v1`).
3. Pick your **Word-fix model** and **Rephrase model**.

If the address isn't on your Mac, Fixaro warns you first, because your text would then leave your computer. If it doesn't work with your app, please [open an issue](https://github.com/Z2mjeed-prog/Fixaro/issues).
