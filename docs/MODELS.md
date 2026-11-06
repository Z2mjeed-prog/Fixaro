# Choosing models for Fixaro

**Any model works.** Fixaro lists every text model you've installed in Ollama, and you choose one for each job in the menu bar:

- **Word-fix model:** runs on every typo, so pick something **small and fast** (about 4 GB or less).
- **AI model** (for Polish and Rewrite as…): runs only when you press ⌃⌥R or ⌃⌥S, so a **bigger model** that writes better is fine, if your Mac has the memory. This is the one that matters most, since typo fixing is off unless you turn it on.

To get a new model, use **Download a model…** in the menu bar (or `ollama pull <name>` in Terminal). It shows up in the menu within seconds.

## How the model changes Fixaro

| | Smaller model | Bigger model |
|---|---|---|
| **Speed** | Fixes in about 0.1–0.2 s | Fixes take longer |
| **Picking the right word** | Misses more often when the sentence matters ("frim" → from or firm?) | Reads the sentence better |
| **Rephrasing** | Fixes grammar, but the writing is plainer | Writes more naturally |
| **Memory** | Leaves more room for your other apps | Can slow other apps on smaller Macs |

- **Word fixes have 1.5 seconds.** If the model hasn't answered by then, Fixaro uses the spell checker's first guess instead, which ignores the sentence. A model that's too big for your Mac quietly makes your fixes worse.
- **Models stay loaded while you use them:** Fixaro frees a model's memory 5 minutes after you last use it (change it under **Settings → Free AI memory**). Try to keep what's loaded under about half your computer's memory.
- **The first use after a break is slower** (a few seconds) while the model loads.

## Rephrase test

Tested with `tools/rephrase_test.py` on an M-series Mac with 18 GB of memory, using Fixaro's own prompts. Each model got 12 rewrite jobs and was checked for keeping every fact, adding nothing, staying a question, getting shorter, keeping paragraphs, rewriting (not obeying) text that looks like an order, and following ⌃⌥S instructions (a deadline, bullet points, simple English).

| Model | Size | Passed | Time per rewrite | Notes |
|---|---|---|---|---|
| **qwen3.5:9b** | 7.6 GB | **11/12** | 1.4 s | **Best writing.** Kept greetings and paragraphs, and the most natural Shorter and simple-English rewrites. Its one flag: it wrote "250k" as "$250,000" |
| **gemma4:e4b** | 9.6 GB | 11/12 | 1.4 s | Very careful with facts. Once dropped a greeting and a paragraph break |
| gemma4:12b-it-qat | 7.2 GB | 11/12 | 3.0 s | Writes well, but twice as slow. Its bullet points lost their markers |
| qwen3.5:4b | 4.0 GB | 9/12 | 1.2 s | Great for typos. Given text that looked like an order, it replied with a refusal instead of rewriting it |
| ministral-3:8b | 6.0 GB | 8/12 | 2.2 s | **Not a good fit:** wrote a poem when the text looked like an order, added filler, and once changed a fact |

Run it on your Mac: `python3 tools/rephrase_test.py qwen3.5:9b gemma4:e4b`, then `open tools/rephrase-report.html` to read every rewrite side by side.

## Typo test

Tested with `tools/bench.py` on an M-series Mac with 18 GB of memory. Each model got 46 typos: 18 easy ones, and 28 where the right fix depends on the sentence ("money **frim** the bank" vs "new **frim** policy").

| Model | Size | Best for | Typos fixed | Need the sentence | Time per word | Rephrasing |
|---|---|---|---|---|---|---|
| **qwen3.5:4b** | 4.0 GB | **Word fixes** (default) | **46/46** | **28/28** | 0.21 s | Good, but sometimes adds small details |
| **qwen3.5:9b** | 7.6 GB | **Rephrasing** on 16 GB+ | 46/46 | 28/28 | 0.30 s | **Best** in the rephrase test above |
| gemma4:e4b | 9.6 GB | Rephrasing, very careful with facts | 45/46 | 27/28 | 0.36 s | Changes the tone well and sticks to your message |
| **nemotron-3-nano:4b** | 2.9 GB | **Word fixes on 8 GB Macs** | 43/46 | 25/28 | 0.20 s | Good, stays close to your words |
| qwen3.5:2b | 3.1 GB | Fastest | 39/46 | 22/28 | 0.12 s | OK, sometimes adds details |
| granite4.2:3b | 2.2 GB | Smallest | 39/46 | 21/28 | 0.15 s | OK, one grammar slip |

All six fixed nearly every easy typo, kept every name and number when rephrasing, and rewrote questions instead of answering them. The differences show up when the sentence matters, and in how well each one writes.

**Not tested yet, but worth trying:** `lfm3:1.7b` and `ministral-3:3b` for word fixes, `ministral-3:14b` and `phi4:14b` for rephrasing. With 32 GB or more, bigger models like `gemma4:26b` can write even better rephrases; keep a small model for word fixes.

**Not a good fit:**

- **Reasoning models** (`deepseek-r1`, names with `-reasoning` or `-thinking`): they "think" before answering, so they're slow.
- **Vision models** (names with `-vl` or `vision`): they work, but use extra memory for nothing.
- **Big models for word fixes** (9B and up): slower, with no gain in accuracy.

## Tips

- **Test on your own Mac:** `python3 tools/rephrase_test.py` for rewriting and `python3 tools/bench.py` for typos. Each tests every model you've installed, or name a few: `python3 tools/rephrase_test.py qwen3.5:9b gemma4:e4b`.
- **Check the log** (menu → **Open log**):
  - Lots of **"LLM too slow"**: your word-fix model is too big for your Mac. Pick a smaller one.
  - Lots of **"LLM gave no usable answer"**: the model is chatty instead of answering with one word. Try another.
- **Short on memory?** Use the same model for both jobs, so only one is loaded.
- **Clean up:** `ollama list` shows your models and sizes; `ollama rm <name>` deletes one.

## Use another AI app instead of Ollama (beta)

Fixaro also works with **LM Studio**, **Jan**, and **llama.cpp** or **MLX** servers (any app with an OpenAI-compatible API):

1. Start the app's local server and load a model.
2. In Fixaro's menu, choose **AI app** and pick it, or choose **Other app…** and enter its address (for example `http://localhost:1234/v1`).
3. Pick your **AI model** (and **Typo model**, if typo fixing is on).

If the address isn't on your Mac, Fixaro warns you first, because your text would then leave your computer. If it doesn't work with your app, please [open an issue](https://github.com/Z2mjeed-prog/Fixaro/issues).
