# Fixaro

**Private grammar fixing and rewriting for every app on your Mac. Your text never leaves your computer.**

Online writing assistants send what you write to their servers. Fixaro doesn't: its AI runs on your own Mac, so you can use it on confidential emails, client details, contracts and reports. Select text, press **⌃⌥R**, and get correct grammar in the style you choose. While you type, it fixes typos too.

<p align="center">
  <img src="docs/demo-email.gif" width="800" alt="A casual email draft in Apple Mail, 'Hey, can you send me the sales numbers by tomorrow? ... thanks', is selected, Control-Option-R is pressed, and with the Professional style it becomes 'Could you please send me the sales numbers by tomorrow? I require them for the meeting on Thursday. Please let me know if this presents any issues. Thank you.'">
</p>

## Private by design

Client details, account numbers, salaries: rewrite them without worrying, because they never leave your Mac.

<p align="center">
  <img src="docs/demo-private.gif" width="700" alt="A confidential note full of mistakes, 'the client in acount 48213 have missed two payment and owe 3,750 SAR. her salary went down to 9,000 so we need to restructure the loan befor it go to collections', is selected, Control-Option-R is pressed, and on the Mac it becomes 'The client in account 48213 has missed two payments and currently owes 3,750 SAR. Since her salary has decreased to 9,000, we need to restructure the loan before it goes to collections.'">
</p>

- **Your text stays on your Mac.** The AI runs locally through [Ollama](https://ollama.com). No account, no cloud, no tracking, and nothing is sent anywhere.
- **Works offline.** Once your model is downloaded, Fixaro works with the internet switched off.
- **Never sees passwords.** macOS hides password fields from all apps, Fixaro included.
- **Saves nothing you write.** It keeps only your word list, your styles, and a log of the typos it fixed (`~/Library/Application Support/Fixaro/`, `~/Library/Logs/Fixaro.log`). Rephrased text is never saved.
- **Open source.** Anyone can read the code and check exactly what it does.

| | Fixaro | Online writing assistants |
|---|---|---|
| **Where your text goes** | Stays on your Mac | Sent to their servers |
| **Account** | None | Usually required |
| **Works offline** | Yes | No |
| **Price** | Free and open source | Often a monthly subscription |

Good to know: Fixaro needs **Accessibility** permission, the only way a Mac app can read and replace text in other apps. To rephrase, it copies your selection through the clipboard and puts your clipboard back afterwards, so a clipboard manager may keep a copy.

## Better grammar with one shortcut

1. **Select text** in any app: Mail, Slack, Chrome, Notes…
2. **Press ⌃⌥R** (Control-Option-R). A menu of styles pops up next to your text.
3. **Pick a style** with its number key or a click. **Return** uses the one you used last; **Esc** cancels.

Fixaro corrects grammar, spelling and punctuation, rewrites the text in your chosen style, and puts it right back in place. **⌘Z** brings back the original.

<p align="center">
  <img src="docs/demo-rephrase.gif" width="700" alt="The sentence 'we was to busy to finish it yesterday' is selected, Control-Option-R is pressed, and it becomes 'We were too busy to finish it yesterday.'">
</p>

| Style | You wrote | Fixaro wrote |
|---|---|---|
| **Natural**: a grammar check that keeps your tone | i think we should of finished the report yesterday but we was to busy with other stuff | I think we should have finished the report yesterday, but we were too busy with other things. |
| **Professional** | hey can u send me the Q3 numbers by tmrw? need them for the 10am meeting with Sara | Could you please send me the Q3 numbers by tomorrow? I need them for the 10:00 AM meeting with Sara. |
| **Shorter** | I just wanted to reach out and let you know that I will not be able to attend the meeting that is scheduled for Thursday because I have a doctor's appointment that I cannot move. | I cannot attend Thursday's meeting due to an unavoidable doctor's appointment. |
| **Friendly** | Your payment of 450 SAR is overdue. Pay it by June 5 or your account will be suspended. | Just a friendly heads-up that your payment of 450 SAR is a little overdue. Could you please take care of it by June 5th so your account stays active? |

<sub>Real results from gemma4:e4b on a Mac with 18 GB of memory, about a second each.</sub>

It keeps your names, numbers and meaning, and won't answer your text: a question stays a question.

### Make your own styles

Menu bar icon → **Rephrase style → Add a style…**. Give it a name and say how it should sound. It shows up in the ⌃⌥R menu straight away. Some ideas:

| Name | How it should sound |
|---|---|
| Customer reply | Polite, warm and short, for replying to a customer |
| Slack message | Casual and brief, like a quick message to a teammate |
| Simple English | Clear and simple, easy for non-native speakers to read |

To change or delete styles, choose **Edit my styles…**. They're kept in one text file, one style per line: `Name: how it should sound`.

Prefer one style every time, with no menu? Pick it under **Rephrase style**.

## Fix typos as you type

<p align="center">
  <img src="docs/demo-context.gif" width="800" alt="Typing 'I got the money frim the bank': Fixaro changes frim to from. Then 'The new frim policy': the same typo becomes firm, because Fixaro reads the words around it.">
</p>

- **Works everywhere:** Mail, Notes, Slack, Chrome, WhatsApp, and more.
- **Understands context.** "the money **frim** the bank" → **from**, but "the new **frim** policy" → **firm**.
- **Learns from you.** Undo the same fix twice and Fixaro leaves that word alone; keep a fix twice and it's applied instantly next time.
- **Easy undo.** Press Backspace right after a fix, or **⌃⌥Z**.

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
| Rephrase text | Select it, press **⌃⌥R**, pick a style |
| Add your own style | Menu → **Rephrase style** → **Add a style…** |
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

Fixaro is a single Swift file (`Sources/main.swift`). The macOS spell checker spots the typo, a local model picks the fix from the words around it (falling back to the spell checker if the model is slow), and the word is swapped in place, or retyped in Chrome and Electron apps. Rephrase copies your selection, rewrites it with the rephrase model, pastes it back and restores your clipboard.

## Roadmap

- Windows version (in progress)
- Catching real-word mistakes (their/there)
- Signed, ready-to-run download

## Contributing

Issues and pull requests are welcome. If something doesn't work, please open an issue with the relevant lines from the log.

## License

[MIT](LICENSE) © Z2mjeed-prog
